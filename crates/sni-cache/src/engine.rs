//! The poll engine: one async task that turns declared watches into batched
//! `MultiRead` calls and publishes immutable snapshots.
//!
//! Per cycle:
//!   1. snapshot the watch registry
//!   2. select watches due this cycle by priority period
//!   3. coalesce due watches into the fewest reads (subject to a byte budget)
//!   4. issue a single `MultiRead`
//!   5. slice results back to each member watch, carry stale data forward
//!   6. publish via `ArcSwap` (lock-free for readers)
//!   7. adapt cycle pacing to measured RTT
//!
//! This is the whole bandwidth strategy in one place: scripts read the
//! published snapshot instantly; the cost of talking to the FXPAK is paid
//! here, amortized across every active watch, off the render thread.

use std::collections::HashSet;
use std::sync::Arc;
use std::time::{Duration, Instant};

use arc_swap::ArcSwap;
use parking_lot::Mutex;
use sni_client::SniClient;

use crate::snapshot::{Snapshot, SnapshotBuilder};
use crate::watch::{coalesce, WatchPriority, WatchRegistry};

#[derive(Debug, Clone)]
pub struct PollConfig {
    /// Target cycle period. The engine sleeps to hit this; if a cycle's RTT
    /// already exceeds it, the next cycle starts immediately (latency-bound).
    pub target_period: Duration,
    /// Max bytes to request in a single cycle. Caps worst-case round-trip
    /// size so a script registering huge watches can't stall the overlay.
    pub byte_budget: u32,
    /// Coalescing gap: merge same-space reads within this many bytes.
    pub coalesce_gap: u32,
    /// EWMA smoothing for the reported RTT (0..1; higher = snappier).
    pub rtt_alpha: f32,
}

impl Default for PollConfig {
    fn default() -> Self {
        // Tuned for the 5-20ms (fast emulator) class measured on this setup,
        // while staying safe if pointed at a real FXPAK: budget + coalescing
        // keep round trips small, adaptive pacing absorbs higher RTT.
        Self {
            target_period: Duration::from_millis(16),
            byte_budget: 16 * 1024,
            coalesce_gap: 16,
            rtt_alpha: 0.25,
        }
    }
}

/// Live engine stats for the UI/HUD.
#[derive(Debug, Default, Clone, Copy)]
pub struct PollStats {
    pub cycle: u64,
    pub watches: usize,
    pub reads_last_cycle: usize,
    pub bytes_last_cycle: u32,
    pub rtt_ms_ewma: f32,
    pub last_rtt_ms: u32,
    /// True if the last cycle hit the byte budget and deferred some watches.
    pub budget_capped: bool,
    pub last_error: Option<&'static str>,
}

/// Handle the rest of the app holds. Snapshot reads are lock-free.
pub struct PollEngine {
    registry: Arc<WatchRegistry>,
    current: Arc<ArcSwap<Snapshot>>,
    stats: Arc<Mutex<PollStats>>,
    config: Arc<Mutex<PollConfig>>,
}

impl PollEngine {
    pub fn registry(&self) -> Arc<WatchRegistry> {
        self.registry.clone()
    }

    /// Lock-free load of the latest snapshot. This is what scripts read every
    /// frame; it never blocks and never waits on SNI.
    pub fn snapshot(&self) -> Arc<Snapshot> {
        self.current.load_full()
    }

    pub fn stats(&self) -> PollStats {
        *self.stats.lock()
    }

    pub fn set_config(&self, cfg: PollConfig) {
        *self.config.lock() = cfg;
    }
}

/// Spawn the poll loop on the current Tokio runtime. The engine drives reads
/// through `client` against `device_uri`; both can change between cycles via
/// the supplied accessors so reconnect/device-switch doesn't restart polling.
pub fn spawn(
    mut get_client: impl FnMut() -> Option<(SniClient, String)> + Send + 'static,
    config: PollConfig,
) -> Arc<PollEngine> {
    let engine = Arc::new(PollEngine {
        registry: Arc::new(WatchRegistry::new()),
        current: Arc::new(ArcSwap::from_pointee(Snapshot::default())),
        stats: Arc::new(Mutex::new(PollStats::default())),
        config: Arc::new(Mutex::new(config)),
    });

    let registry = engine.registry.clone();
    let current = engine.current.clone();
    let stats = engine.stats.clone();
    let config = engine.config.clone();

    tokio::spawn(async move {
        let mut cycle: u64 = 0;
        loop {
            let cfg = config.lock().clone();
            let cycle_start = Instant::now();

            // No device yet — idle at the target period and try again.
            let Some((mut client, uri)) = get_client() else {
                tokio::time::sleep(cfg.target_period).await;
                continue;
            };

            cycle += 1;
            let watches = registry.all();
            let live_ids: HashSet<u64> = watches.iter().map(|w| w.id).collect();

            // Select watches whose priority period divides this cycle. High
            // every cycle, Normal every 3, Low every 12 — spends the budget
            // on what changes fast.
            let due: Vec<_> = watches
                .iter()
                .filter(|w| cycle % w.priority.period() == 0)
                .cloned()
                .collect();

            let mut reads = coalesce(&due, cfg.coalesce_gap);

            // Enforce the byte budget: keep reads (already sorted High-ish by
            // registry id order within coalesce) until the budget is spent.
            // High-priority data tends to be small and registered early.
            let mut budget = cfg.byte_budget;
            let mut budget_capped = false;
            reads.retain(|r| {
                if r.region.size <= budget {
                    budget -= r.region.size;
                    true
                } else {
                    budget_capped = true;
                    false
                }
            });

            let regions: Vec<_> = reads.iter().map(|r| r.region).collect();
            let bytes_requested: u32 = regions.iter().map(|r| r.size).sum();

            // Build the next snapshot on top of the previous one so watches
            // not due this cycle keep their last value (just age).
            let prev = current.load_full();
            let mut builder = SnapshotBuilder::from_prev(&prev);
            builder.retain_only(&live_ids);

            let mut last_error: Option<&'static str> = None;
            let rtt_ms;

            if regions.is_empty() {
                rtt_ms = 0;
            } else {
                let t0 = Instant::now();
                match client.multi_read(&uri, &regions).await {
                    Ok(blobs) => {
                        rtt_ms = t0.elapsed().as_millis() as u32;
                        // Slice each coalesced blob back to its member watches.
                        for (read, blob) in reads.iter().zip(blobs.iter()) {
                            for &(wid, off, sz) in &read.members {
                                let (o, s) = (off as usize, sz as usize);
                                if blob.len() >= o + s {
                                    let region = sni_client::MemRegion {
                                        address: read.region.address + off,
                                        size: sz,
                                        space: read.region.space,
                                        mapping: read.region.mapping,
                                    };
                                    builder.set(wid, region, blob[o..o + s].to_vec());
                                }
                            }
                        }
                    }
                    Err(e) => {
                        rtt_ms = t0.elapsed().as_millis() as u32;
                        last_error = Some(classify_err(&e));
                        tracing::debug!("poll multi_read failed: {e}");
                    }
                }
            }

            let snap = builder.build(cycle, rtt_ms, rtt_ms);
            current.store(Arc::new(snap));

            {
                let mut st = stats.lock();
                st.cycle = cycle;
                st.watches = watches.len();
                st.reads_last_cycle = reads.len();
                st.bytes_last_cycle = bytes_requested;
                st.last_rtt_ms = rtt_ms;
                st.rtt_ms_ewma = if st.rtt_ms_ewma == 0.0 {
                    rtt_ms as f32
                } else {
                    cfg.rtt_alpha * rtt_ms as f32
                        + (1.0 - cfg.rtt_alpha) * st.rtt_ms_ewma
                };
                st.budget_capped = budget_capped;
                st.last_error = last_error;
            }

            // Adaptive pacing: aim for target_period measured wall-to-wall.
            // If the round trip already blew the budget (FXPAK under load),
            // don't sleep — we're latency-bound, just go again.
            let elapsed = cycle_start.elapsed();
            if elapsed < cfg.target_period {
                tokio::time::sleep(cfg.target_period - elapsed).await;
            } else {
                tokio::task::yield_now().await;
            }
        }
    });

    engine
}

fn classify_err(e: &sni_client::SniError) -> &'static str {
    use sni_client::SniError::*;
    match e {
        Transport(_) => "transport",
        Status(_) => "rpc",
        NoDevices => "no devices",
        DeviceNotFound(_) => "device gone",
        EmptyResponse => "empty response",
    }
}

#[allow(unused)]
fn _priority_doc(p: WatchPriority) -> u64 {
    p.period()
}
