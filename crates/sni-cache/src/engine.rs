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
    /// Latency target for the *bulk* read: the adaptive budget grows/shrinks
    /// to keep each bulk MultiRead's round trip at or under this. This is the
    /// "read as much as we can without exceeding one frame" knob.
    pub frame_budget_ms: u32,
    /// Hard floor/ceiling for the adaptive budget (bytes). The floor keeps
    /// high-priority data flowing even on a bad link; the ceiling caps
    /// worst-case memory/latency.
    pub min_byte_budget: u32,
    pub max_byte_budget: u32,
    /// Coalescing gap: merge same-space reads within this many bytes.
    pub coalesce_gap: u32,
    /// EWMA smoothing for the reported RTT (0..1; higher = snappier).
    pub rtt_alpha: f32,
}

impl Default for PollConfig {
    fn default() -> Self {
        // Tuned for the 5-20ms (fast emulator) class measured on this setup,
        // while staying safe on a real FXPAK: the budget self-tunes from
        // observed throughput + RTT so it never knowingly overruns a frame.
        Self {
            target_period: Duration::from_millis(16),
            frame_budget_ms: 16,
            min_byte_budget: 256,
            max_byte_budget: 64 * 1024,
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
    /// Watches in the Realtime tier and the RTT of their dedicated sub-poll
    /// (the controller-input fast path). Distinct from the bulk RTT so the
    /// HUD can show how fresh inputs really are.
    pub realtime_watches: usize,
    pub realtime_rtt_ms: u32,
    /// True if the last cycle hit the byte budget and deferred some watches.
    pub budget_capped: bool,
    /// Current adaptive bulk-read budget (bytes) and the throughput estimate
    /// (bytes/ms) it's derived from — so the HUD shows the self-tuning.
    pub byte_budget: u32,
    pub throughput_bpms: f32,
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
        // Adaptive bulk-read budget state, carried across cycles.
        //   `budget`     — current cap on bytes per bulk MultiRead.
        //   `throughput` — EWMA of observed bytes/ms (drives the estimate;
        //                  None until the first non-trivial measurement).
        // AIMD on the observed bulk RTT vs the frame budget: a fast
        // multiplicative cut on overrun (kills the spikes you saw), a slow
        // additive grow when we have headroom (reclaims bandwidth). Deferred
        // low-priority reads naturally spread over later cycles.
        let mut budget: u32 = {
            let c = config.lock();
            c.min_byte_budget.max(2048).min(c.max_byte_budget)
        };
        let mut throughput: Option<f32> = None;
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

            // Build the next snapshot on top of the previous one so watches
            // not refreshed this cycle keep their last value (just age).
            let prev = current.load_full();
            let mut builder = SnapshotBuilder::from_prev(&prev);
            builder.retain_only(&live_ids);
            let mut last_error: Option<&'static str> = None;

            // --- Tier 1: Realtime sub-poll --------------------------------
            // A tiny, dedicated MultiRead issued FIRST every cycle for the
            // latency-critical bytes (controller state). Kept separate so it
            // is never queued behind the large block/level batch — the whole
            // point of the Realtime tier.
            let realtime: Vec<_> = watches
                .iter()
                .filter(|w| w.priority.is_realtime())
                .cloned()
                .collect();
            let realtime_count = realtime.len();
            let mut realtime_rtt = 0u32;
            if !realtime.is_empty() {
                let rt_reads = coalesce(&realtime, cfg.coalesce_gap);
                let rt_regions: Vec<_> =
                    rt_reads.iter().map(|r| r.region).collect();
                let t0 = Instant::now();
                match client.multi_read(&uri, &rt_regions).await {
                    Ok(blobs) => {
                        realtime_rtt = t0.elapsed().as_millis() as u32;
                        apply_reads(&rt_reads, &blobs, &mut builder);
                    }
                    Err(e) => {
                        realtime_rtt = t0.elapsed().as_millis() as u32;
                        last_error = Some(classify_err(&e));
                        tracing::debug!("realtime sub-poll failed: {e}");
                    }
                }
            }

            // --- Tier 2: bulk batch ---------------------------------------
            // Non-realtime watches whose priority period divides this cycle.
            // High every cycle, Normal every 3, Low every 12 — spends the
            // byte budget on what changes fast / what's due.
            let due: Vec<_> = watches
                .iter()
                .filter(|w| {
                    !w.priority.is_realtime()
                        && cycle % w.priority.period() == 0
                })
                .cloned()
                .collect();

            let mut reads = coalesce(&due, cfg.coalesce_gap);

            // Enforce the *adaptive* byte budget. coalesce preserves registry
            // id order and the prelude registers hotter data earlier, so
            // trimming the tail sheds the lowest-priority bulk reads first;
            // those deferred reads are simply picked up on later cycles
            // (this is what spreads block-data streaming over time instead
            // of one frame-blowing burst).
            let mut remaining = budget;
            let mut budget_capped = false;
            reads.retain(|r| {
                if r.region.size <= remaining {
                    remaining -= r.region.size;
                    true
                } else {
                    budget_capped = true;
                    false
                }
            });

            let regions: Vec<_> = reads.iter().map(|r| r.region).collect();
            let bytes_requested: u32 = regions.iter().map(|r| r.size).sum();
            let rtt_ms;

            if regions.is_empty() {
                rtt_ms = 0;
            } else {
                let t0 = Instant::now();
                match client.multi_read(&uri, &regions).await {
                    Ok(blobs) => {
                        rtt_ms = t0.elapsed().as_millis() as u32;
                        apply_reads(&reads, &blobs, &mut builder);
                    }
                    Err(e) => {
                        rtt_ms = t0.elapsed().as_millis() as u32;
                        last_error = Some(classify_err(&e));
                        tracing::debug!("poll multi_read failed: {e}");
                    }
                }
            }

            // --- Adaptive budget update (AIMD against the frame target) ----
            // Only adjust on a real measurement (bytes actually moved). The
            // realtime sub-poll's RTT is excluded — its cost is tiny and
            // attributing it here would shrink the bulk budget for no reason.
            if bytes_requested > 0 && last_error.is_none() {
                let inst_bpms =
                    bytes_requested as f32 / rtt_ms.max(1) as f32;
                throughput = Some(match throughput {
                    Some(t) => cfg.rtt_alpha * inst_bpms
                        + (1.0 - cfg.rtt_alpha) * t,
                    None => inst_bpms,
                });
                budget = next_budget(budget, rtt_ms, throughput, &cfg);
            }

            let snap = builder.build(cycle, rtt_ms, rtt_ms);
            current.store(Arc::new(snap));

            {
                let mut st = stats.lock();
                st.cycle = cycle;
                st.watches = watches.len();
                st.reads_last_cycle = reads.len();
                st.bytes_last_cycle = bytes_requested;
                st.byte_budget = budget;
                st.throughput_bpms = throughput.unwrap_or(0.0);
                st.realtime_watches = realtime_count;
                st.realtime_rtt_ms = realtime_rtt;
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

/// One AIMD step for the adaptive bulk-read budget.
///
/// * **Overran the frame** (`rtt > frame_budget_ms`): multiplicative cut,
///   scaled by how badly we overshot — a big spike drops the budget hard so
///   the next bulk read fits, instead of repeating the stall.
/// * **Under budget**: additive grow, capped at what the measured throughput
///   says fits in 80% of a frame — probe bandwidth back gently rather than
///   jumping straight back to a spike.
///
/// Pure so it can be unit-tested for convergence and backoff.
fn next_budget(
    budget: u32,
    rtt_ms: u32,
    throughput: Option<f32>,
    cfg: &PollConfig,
) -> u32 {
    let frame_ms = cfg.frame_budget_ms.max(1) as f32;
    let b = budget as f32;
    let next = if rtt_ms > cfg.frame_budget_ms {
        let overshoot = (rtt_ms.max(1) as f32 / frame_ms).min(4.0);
        (b * (0.5 / overshoot).max(0.2)).max(0.0)
    } else {
        let ceil = throughput.map(|t| t * frame_ms * 0.8).unwrap_or(b);
        let step = (cfg.max_byte_budget as f32 * 0.05).max(256.0);
        // Grow additively toward the throughput ceiling; never shrink here.
        (b + step).min(ceil.max(b))
    };
    (next as u32).clamp(cfg.min_byte_budget, cfg.max_byte_budget)
}

/// Slice each coalesced blob back to its member watches and write them into
/// the snapshot builder. Shared by the Realtime sub-poll and the bulk batch.
fn apply_reads(
    reads: &[crate::watch::CoalescedRead],
    blobs: &[Vec<u8>],
    builder: &mut SnapshotBuilder,
) {
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

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg() -> PollConfig {
        PollConfig {
            frame_budget_ms: 16,
            min_byte_budget: 256,
            max_byte_budget: 64 * 1024,
            ..PollConfig::default()
        }
    }

    #[test]
    fn overrun_cuts_budget_hard() {
        let c = cfg();
        // 40ms RTT on a 16ms frame: ~2.5x overshoot -> sharp cut.
        let next = next_budget(16_000, 40, Some(400.0), &c);
        assert!(next < 16_000 / 2, "spike must drop budget hard: {next}");
        assert!(next >= c.min_byte_budget);
    }

    #[test]
    fn bigger_overshoot_cuts_harder() {
        let c = cfg();
        let mild = next_budget(16_000, 20, Some(800.0), &c);
        let severe = next_budget(16_000, 64, Some(250.0), &c);
        assert!(
            severe < mild,
            "worse overshoot should cut more: {severe} vs {mild}"
        );
    }

    #[test]
    fn under_budget_grows_but_capped_by_throughput() {
        let c = cfg();
        // Comfortably under frame; throughput ~500 B/ms -> ceil =
        // 500 * 16 * 0.8 = 6400 bytes. From 4000 it grows toward that.
        let next = next_budget(4000, 8, Some(500.0), &c);
        assert!(next > 4000, "should grow when we have headroom");
        assert!(next <= 6400, "must not exceed throughput ceiling: {next}");
    }

    #[test]
    fn converges_and_is_stable_at_the_throughput_point() {
        let c = cfg();
        // Simulate: link does ~500 B/ms, frame target 16ms. Steady state
        // should settle near the 80%-frame ceiling (~6400) and not oscillate
        // wildly. Model rtt = bytes / throughput.
        let tput = 500.0;
        let mut budget = 2048u32;
        for _ in 0..200 {
            let rtt = (budget as f32 / tput).ceil() as u32;
            budget = next_budget(budget, rtt, Some(tput), &c);
        }
        // At ~6400 bytes, rtt ≈ 13ms (< 16) so it stays; allow some band.
        assert!(
            (4000..=9000).contains(&budget),
            "should converge near throughput point, got {budget}"
        );
    }

    #[test]
    fn budget_respects_floor_and_ceiling() {
        let c = cfg();
        // Catastrophic RTT from min: clamps at floor, never 0.
        let lo = next_budget(c.min_byte_budget, 500, Some(1.0), &c);
        assert_eq!(lo, c.min_byte_budget);
        // Huge throughput can't push past the ceiling.
        let hi = next_budget(
            c.max_byte_budget,
            1,
            Some(1_000_000.0),
            &c,
        );
        assert_eq!(hi, c.max_byte_budget);
    }
}
