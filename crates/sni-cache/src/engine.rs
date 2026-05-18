//! The poll engine: one async task that turns active watches into batched
//! `MultiRead` calls and publishes immutable snapshots.
//!
//! Per cycle:
//!   1. retain set = all registered watches (dormant ones keep their cache)
//!   2. poll set = active watches (pinned + within the demand window)
//!   3. Realtime sub-poll first (controller path), kept off the bulk batch
//!   4. bulk DRAIN LOOP: repeatedly select (urgent-first, then stalest Low),
//!      excluding watches already refreshed this cycle, issuing batches
//!      back-to-back until the frame-time window is spent or all caught up
//!   5. slice results back to each member watch, carry stale data forward
//!   6. publish via `ArcSwap` (lock-free for readers)
//!   7. adaptive byte budget (AIMD vs frame target); sleep only the unused
//!      remainder of the window
//!
//! This is the whole bandwidth strategy in one place: scripts read the
//! published snapshot instantly; the cost of talking to the FXPAK is paid
//! here, amortized across every active watch, off the render thread.

use std::collections::{HashMap, HashSet};
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
    /// Demand window: an auto-registered watch the script hasn't read within
    /// this long stops being actively polled (goes dormant — its last value
    /// stays cached, but it costs no bandwidth until the script reads it
    /// again). Stops the watched set growing without bound as the script
    /// roams (e.g. block data from rooms ago). Pinned watches (controller,
    /// frame counter, explicit snes.tier) ignore this.
    pub demand_window: Duration,
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
            // ~1s: a watch unread for a full second of frames is almost
            // certainly no longer wanted (the script roamed away). Long
            // enough that briefly-not-read data (every-few-frames logic)
            // doesn't thrash dormant/active.
            demand_window: Duration::from_millis(1000),
        }
    }
}

/// Live engine stats for the UI/HUD.
#[derive(Debug, Default, Clone, Copy)]
pub struct PollStats {
    pub cycle: u64,
    /// Watches actively polled this cycle (pinned + within demand window).
    pub watches: usize,
    /// Total registered watches incl. dormant (still cached, not polled).
    pub watches_total: usize,
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
        // Per-watch last-refreshed cycle. Drives stalest-first Low selection
        // so deferred block/level data streams in completely and evenly, and
        // stays correct as the registry grows mid-stream (a new watch has no
        // entry → treated as maximally stale → read promptly). GC'd
        // periodically against the live set so it can't grow unbounded.
        let mut last_read: HashMap<u64, u64> = HashMap::new();
        loop {
            let cfg = config.lock().clone();
            let cycle_start = Instant::now();

            // No device yet — idle at the target period and try again.
            let Some((mut client, uri)) = get_client() else {
                tokio::time::sleep(cfg.target_period).await;
                continue;
            };

            cycle += 1;
            // Retention set = ALL registered watches: dormant (demand-evicted)
            // ones must keep their last cached value so the script can still
            // read stale data without it vanishing.
            let all_watches = registry.all();
            let live_ids: HashSet<u64> =
                all_watches.iter().map(|w| w.id).collect();

            // Poll set = only ACTIVE watches: pinned + read by the script
            // within the demand window. This is the fix for the watched set
            // growing without bound — data the script stopped caring about
            // (blocks from rooms ago) is no longer fetched, freeing the
            // budget for what's actually wanted.
            let watches = registry.active(cfg.demand_window);

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

            // --- Tier 2: bulk DRAIN LOOP ----------------------------------
            // The previous design issued ONE bulk read then slept the rest of
            // the frame — wasting the whole window while deferred reads
            // starved. Instead we keep issuing reads back-to-back until the
            // frame-time budget for this cycle is spent:
            //
            //   * High/Normal are always eligible (no fixed cadence; the
            //     staleness ordering paces Normal naturally — it's just less
            //     stale than Low after a recent read).
            //   * Within Low, stalest-first (longest since last refreshed),
            //     so block/level data streams in completely and evenly; new
            //     watches (registry grows as the script touches addresses)
            //     are maximally stale and picked up promptly.
            //   * Each admitted watch's last-read cycle is recorded so the
            //     next selection skips what we just got and advances to the
            //     next stalest — no index cursor to smear.
            //
            // Time budget for the whole cycle: frame_budget_ms, minus what
            // the realtime sub-poll already spent. We stop issuing once
            // we've used it (or there's nothing left / a single read would
            // clearly overrun), then the adaptive byte budget is updated
            // from the aggregate so it converges on "as much as fits".
            let bulk_eligible: Vec<_> = watches
                .iter()
                .filter(|w| !w.priority.is_realtime())
                .cloned()
                .collect();

            let frame_ms = cfg.frame_budget_ms.max(1) as u128;
            let mut bytes_requested: u32 = 0;
            let mut reads_issued: usize = 0;
            let mut budget_capped = false;
            let mut worst_rtt: u32 = 0;
            // Watches already refreshed in THIS cycle's drain loop. Each
            // iteration excludes them, so successive batches advance through
            // the deferred set instead of re-selecting the same stalest
            // prefix every time (the "fills then restarts" bug: the old
            // `!capped` break stopped the loop the moment the remaining
            // stale set fit one budget, so the tail never got read and the
            // next cycle just re-read the front).
            let mut done_this_cycle: HashSet<u64> = HashSet::new();
            // Coalesce once per cycle; re-filter the cheap members list each
            // iteration rather than re-coalescing.
            let coalesced_all =
                coalesce(&bulk_eligible, cfg.coalesce_gap);

            loop {
                // Stop if the cycle's time window is spent.
                if cycle_start.elapsed().as_millis() >= frame_ms {
                    break;
                }

                // Eligible = coalesced reads with at least one member not yet
                // refreshed this cycle. When none remain, every eligible
                // watch has been read once this cycle — we're caught up.
                let pending: Vec<_> = coalesced_all
                    .iter()
                    .filter(|r| {
                        r.members
                            .iter()
                            .any(|&(id, _, _)| !done_this_cycle.contains(&id))
                    })
                    .cloned()
                    .collect();
                if pending.is_empty() {
                    break; // fully drained this cycle
                }

                let sel =
                    select_bulk(pending, budget, &last_read, cycle);
                if sel.reads.is_empty() {
                    break;
                }
                budget_capped |= sel.capped;

                let regions: Vec<_> =
                    sel.reads.iter().map(|r| r.region).collect();
                let bytes: u32 = regions.iter().map(|r| r.size).sum();

                let t0 = Instant::now();
                match client.multi_read(&uri, &regions).await {
                    Ok(blobs) => {
                        let rtt = t0.elapsed().as_millis() as u32;
                        worst_rtt = worst_rtt.max(rtt);
                        apply_reads(&sel.reads, &blobs, &mut builder);
                        for r in &sel.reads {
                            for &(id, _, _) in &r.members {
                                last_read.insert(id, cycle);
                                done_this_cycle.insert(id);
                            }
                        }
                        bytes_requested =
                            bytes_requested.saturating_add(bytes);
                        reads_issued += 1;

                        // Adaptive byte budget: converge so a single batch
                        // fits the frame. Driven by the per-batch RTT.
                        let inst_bpms = bytes as f32 / rtt.max(1) as f32;
                        throughput = Some(match throughput {
                            Some(tp) => cfg.rtt_alpha * inst_bpms
                                + (1.0 - cfg.rtt_alpha) * tp,
                            None => inst_bpms,
                        });
                        budget =
                            next_budget(budget, rtt, throughput, &cfg);

                        // Don't start another batch that would clearly
                        // overrun the window (use measured RTT as the
                        // estimate for the next one).
                        if cycle_start.elapsed().as_millis() + rtt as u128
                            >= frame_ms
                        {
                            break;
                        }
                        // NOTE: deliberately NO `!capped` break here. capped
                        // just means "budget was full this batch" — exactly
                        // when we MUST keep going to drain the rest within
                        // the time window. We stop only on time or when
                        // nothing pending remains.
                    }
                    Err(e) => {
                        worst_rtt = worst_rtt
                            .max(t0.elapsed().as_millis() as u32);
                        last_error = Some(classify_err(&e));
                        tracing::debug!("bulk multi_read failed: {e}");
                        break;
                    }
                }
            }

            let rtt_ms = worst_rtt;
            let snap = builder.build(cycle, rtt_ms, rtt_ms);
            current.store(Arc::new(snap));

            {
                let mut st = stats.lock();
                st.cycle = cycle;
                st.watches = watches.len();
                st.watches_total = all_watches.len();
                st.reads_last_cycle = reads_issued;
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

            // Garbage-collect last_read entries for watches that no longer
            // exist so it can't grow unbounded across room/script changes.
            if cycle % 256 == 0 {
                last_read.retain(|id, _| live_ids.contains(id));
            }

            // Inter-cycle pacing: only sleep the UNUSED remainder of the
            // window. If the drain loop already consumed it (or overran —
            // latency-bound), continue immediately.
            let elapsed = cycle_start.elapsed();
            let target = cfg.target_period.min(Duration::from_millis(
                cfg.frame_budget_ms.max(1) as u64,
            ));
            if elapsed < target {
                tokio::time::sleep(target - elapsed).await;
            } else {
                tokio::task::yield_now().await;
            }
        }
    });

    engine
}

/// Result of selecting the bulk reads for one drain-loop iteration.
struct BulkSelection {
    /// Reads admitted, priority-ordered (urgent first, then stalest Low).
    reads: Vec<crate::watch::CoalescedRead>,
    /// True if the budget trimmed at least one read (more deferred work
    /// remains for the next drain iteration / cycle).
    capped: bool,
}

/// Pick this iteration's reads from `reads`, urgent-first then *stalest Low
/// first*, trimmed to `budget`.
///
/// `coalesce` returns address order (unrelated to priority); trimming that by
/// size starves arbitrary reads. We sort High→Normal→Low so fast data is
/// never starved, and within Low we order by **how long since each read's
/// watches were last refreshed** (oldest first), using `last_read` keyed by
/// watch id. That is robust to the registry growing mid-stream (new watches
/// have no entry → treated as maximally stale → read promptly) and
/// guarantees every Low watch is refreshed within a bounded number of
/// iterations — no index cursor to smear when the set changes.
fn select_bulk(
    mut reads: Vec<crate::watch::CoalescedRead>,
    budget: u32,
    last_read: &HashMap<crate::watch::WatchId, u64>,
    cycle: u64,
) -> BulkSelection {
    use crate::watch::WatchPriority;

    // Staleness of a coalesced read = the oldest (smallest) last-read cycle
    // among its members; never-read => 0 => maximally stale.
    let staleness = |r: &crate::watch::CoalescedRead| -> u64 {
        let oldest = r
            .members
            .iter()
            .map(|&(id, _, _)| *last_read.get(&id).unwrap_or(&0))
            .min()
            .unwrap_or(0);
        cycle.saturating_sub(oldest)
    };

    // Urgent tier first; within Low, stalest first (largest staleness).
    reads.sort_by(|a, b| {
        a.priority.cmp(&b.priority).then_with(|| {
            if a.priority == WatchPriority::Low {
                staleness(b).cmp(&staleness(a))
            } else {
                std::cmp::Ordering::Equal
            }
        })
    });

    let mut remaining = budget;
    let mut capped = false;
    reads.retain(|r| {
        if r.region.size <= remaining {
            remaining -= r.region.size;
            true
        } else {
            capped = true;
            false
        }
    });

    BulkSelection {
        reads,
        capped,
    }
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

    use crate::watch::{CoalescedRead, WatchId, WatchPriority};

    fn cr(addr: u32, size: u32, p: WatchPriority) -> CoalescedRead {
        CoalescedRead {
            region: sni_client::MemRegion::fxpak(addr, size),
            members: vec![(addr as WatchId, 0, size)],
            priority: p,
        }
    }

    // Faithfully model the engine's per-cycle DRAIN LOOP: repeatedly select
    // within budget, marking admitted watches done-this-cycle and EXCLUDING
    // them from later iterations, until either nothing pending remains or the
    // batch cap is hit (`max_batches` stands in for the wall-clock frame
    // window — a finite number of budget-sized round trips fit per cycle).
    // Returns every address refreshed during the whole cycle.
    fn step_drain(
        all_reads: &[CoalescedRead],
        budget: u32,
        last_read: &mut HashMap<WatchId, u64>,
        cycle: u64,
        max_batches: usize,
    ) -> Vec<u32> {
        let mut done: HashSet<WatchId> = HashSet::new();
        let mut refreshed = Vec::new();
        for _ in 0..max_batches {
            let pending: Vec<_> = all_reads
                .iter()
                .filter(|r| {
                    r.members.iter().any(|&(id, _, _)| !done.contains(&id))
                })
                .cloned()
                .collect();
            if pending.is_empty() {
                break; // fully drained this cycle
            }
            let sel = select_bulk(pending, budget, last_read, cycle);
            if sel.reads.is_empty() {
                break;
            }
            for r in &sel.reads {
                refreshed.push(r.region.address);
                for &(id, _, _) in &r.members {
                    last_read.insert(id, cycle);
                    done.insert(id);
                }
            }
        }
        refreshed
    }

    #[test]
    fn high_priority_is_never_starved_by_low() {
        // Small High + big Low, budget fits only one big Low per batch.
        // High must always get in regardless of how stale the Low reads are.
        let mut lr = HashMap::new();
        for cycle in 1..8 {
            let reads = vec![
                cr(0x1000, 64, WatchPriority::High),
                cr(0x2000, 4096, WatchPriority::Low),
                cr(0x3000, 4096, WatchPriority::Low),
                cr(0x4000, 4096, WatchPriority::Low),
            ];
            // Even with a single batch this cycle, High is admitted first.
            let refreshed = step_drain(&reads, 4096 + 64, &mut lr, cycle, 1);
            assert!(
                refreshed.contains(&0x1000),
                "High starved at cycle {cycle}"
            );
        }
    }

    #[test]
    fn drain_loop_refreshes_everything_within_the_window() {
        // The "fills then restarts" bug: the loop stopped the moment the
        // remaining stale set fit one budget (!capped break), so the tail
        // never streamed and each cycle re-read the front. With the
        // exclude-and-continue drain, given enough batches for the window,
        // EVERY watch is refreshed EVERY cycle — no perpetual front-restart.
        let lows: Vec<u32> = (0..10).map(|i| 0x2000 + i * 0x1000).collect();
        let budget = 64 + 2100; // ~2 Low (1000 each) admitted per batch
        let mut lr = HashMap::new();
        for cycle in 1..=30 {
            let mut reads = vec![cr(0x1000, 64, WatchPriority::High)];
            for &a in &lows {
                reads.push(cr(a, 1000, WatchPriority::Low));
            }
            // 10 lows at ~2/batch => ~5 batches needed; window allows 8.
            let refreshed = step_drain(&reads, budget, &mut lr, cycle, 8);
            // Every Low (and the High) refreshed THIS cycle.
            for &a in &lows {
                assert!(
                    refreshed.contains(&a),
                    "Low {a:#06x} NOT refreshed in cycle {cycle} \
                     (drain loop restarting / stalling)"
                );
            }
            assert!(refreshed.contains(&0x1000), "High missed");
        }
    }

    #[test]
    fn tight_window_still_makes_forward_progress_every_cycle() {
        // When the window only allows ONE batch/cycle, the drain must still
        // advance through the deferred set (stalest-first) cycle over cycle
        // and cover everything within a bounded number of cycles — never
        // re-reading the same prefix forever.
        let lows: Vec<u32> = (0..10).map(|i| 0x2000 + i * 0x1000).collect();
        let budget = 2100; // ~2 lows per (single) batch
        let mut lr = HashMap::new();
        let mut last_seen: HashMap<u32, u64> = HashMap::new();
        for cycle in 1..=40 {
            let reads: Vec<_> = lows
                .iter()
                .map(|&a| cr(a, 1000, WatchPriority::Low))
                .collect();
            for a in step_drain(&reads, budget, &mut lr, cycle, 1) {
                last_seen.insert(a, cycle);
            }
            if cycle > 10 {
                for &a in &lows {
                    let seen = *last_seen.get(&a).unwrap_or(&0);
                    assert!(
                        cycle - seen <= 8,
                        "Low {a:#06x} starved {} cyc at cycle {cycle} \
                         (no forward progress — the restart bug)",
                        cycle - seen
                    );
                }
            }
        }
    }

    #[test]
    fn registry_growth_midstream_still_streams_all() {
        // New watches appear as the script touches addresses. A freshly
        // registered watch has no last_read entry -> maximally stale ->
        // must be picked up promptly, and existing ones must not starve.
        let budget = 3000;
        let mut lr = HashMap::new();
        let mut seen = std::collections::HashSet::new();
        let mut addrs: Vec<u32> =
            (0..5).map(|i| 0x2000 + i * 0x1000).collect();
        for cycle in 1..=40 {
            // Grow the set partway through (simulates lazy registration).
            if cycle == 10 {
                for i in 5..15 {
                    addrs.push(0x2000 + i * 0x1000);
                }
            }
            let reads: Vec<_> = addrs
                .iter()
                .map(|&a| cr(a, 1000, WatchPriority::Low))
                .collect();
            for a in step_drain(&reads, budget, &mut lr, cycle, 6) {
                seen.insert(a);
            }
        }
        assert_eq!(
            seen.len(),
            addrs.len(),
            "not all (incl. late-registered) watches streamed: {}/{}",
            seen.len(),
            addrs.len()
        );
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
