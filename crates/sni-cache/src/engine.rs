//! The poll engine: one async task that turns active watches into batched
//! `MultiRead` calls and publishes immutable snapshots.
//!
//! Per cycle:
//!   1. retain set = all registered watches (dormant ones keep their cache)
//!   2. poll set = active watches plus their latest script request marker
//!   3. Realtime sub-poll first (controller path), kept off the bulk batch
//!   4. bulk DRAIN LOOP: repeatedly select pending non-realtime requests
//!      round-robin by oldest refresh, issuing batches until the shared
//!      frame-time window is spent or all requested data is caught up
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
use crate::watch::{coalesce, CoalescedRead, WatchId, WatchPriority, WatchRegistry};

const THROUGHPUT_HEADROOM: f32 = 0.8;

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
    /// Watches active this cycle (pinned + within demand window).
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
    /// Active non-realtime requested data still waiting for a successful SNI
    /// refresh after the last cycle.
    pub deferred_watches: usize,
    pub deferred_bytes: u32,
    pub deferred_oldest_cycles: u32,
    pub deferred_avg_cycles: f32,
    /// Bulk deferred data refreshed last cycle, plus an EWMA of the drain
    /// rate in bytes/ms.
    pub deferred_bytes_processed_last_cycle: u32,
    pub deferred_drain_bpms_ewma: f32,
    /// Poll-cycle wall time before inter-cycle sleep, and frame-budget
    /// overrun counters.
    pub cycle_elapsed_ms: u32,
    pub frame_budget_ms: u32,
    pub frame_budget_overran: bool,
    pub frame_budget_overrun_ms: u32,
    pub frame_budget_overruns: u64,
    pub frame_budget_overrun_rate: f32,
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
        let mut deferred_drain_bpms_ewma = 0.0f32;
        let mut frame_budget_overruns = 0u64;
        let mut frame_budget_overrun_rate = 0.0f32;
        // Per-watch fulfilment state. A Lua cached read bumps the registry's
        // request marker; a successful SNI refresh copies that marker here.
        // Bulk polling then handles only active watches with unfulfilled
        // requests, ordered by oldest refresh so cold/pending data streams in
        // round-robin instead of repeatedly restarting at the same prefix.
        let mut read_state: HashMap<WatchId, ReadState> = HashMap::new();
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
            let live_ids: HashSet<u64> = all_watches.iter().map(|w| w.id).collect();

            // Poll set = only ACTIVE watches: pinned + read by the script
            // within the demand window. Alongside each handle we snapshot
            // the latest request marker so bulk polling can fetch only data
            // the script has requested since the last successful refresh.
            let active = registry.active_with_requests(cfg.demand_window);
            let request_seq: HashMap<WatchId, u64> =
                active.iter().map(|(w, seq)| (w.id, *seq)).collect();
            let watches: Vec<_> = active.into_iter().map(|(w, _)| w).collect();

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
                let rt_regions: Vec<_> = rt_reads.iter().map(|r| r.region).collect();
                let t0 = Instant::now();
                match client.multi_read(&uri, &rt_regions).await {
                    Ok(blobs) => {
                        realtime_rtt = t0.elapsed().as_millis() as u32;
                        apply_reads(&rt_reads, &blobs, &mut builder);
                        mark_fulfilled(&rt_reads, &request_seq, cycle, &mut read_state);
                    }
                    Err(e) => {
                        realtime_rtt = t0.elapsed().as_millis() as u32;
                        last_error = Some(classify_err(&e));
                        tracing::debug!("realtime sub-poll failed: {e}");
                    }
                }
            }

            // --- Tier 2: bulk DRAIN LOOP ----------------------------------
            // Bulk drain: after realtime, spend whatever remains of this
            // frame's time budget on active watches whose latest script
            // request has not been fulfilled yet.
            //
            // Selection is round-robin by oldest successful refresh across
            // all non-realtime priorities. Priority only breaks ties, so High
            // data wins when equally stale, but a constantly-requested High
            // set cannot permanently starve Low pending data.
            //
            // Each admitted watch is marked fulfilled for the request marker
            // observed at cycle start. If Lua requests it again while the SNI
            // read is in flight, that newer marker remains pending for a
            // later cycle.
            let bulk_eligible: Vec<_> = watches
                .iter()
                .filter(|w| !w.priority.is_realtime())
                .cloned()
                .collect();

            // One frame budget covers both tiers. Realtime is issued first;
            // if it consumes the window, bulk waits for a later cycle rather
            // than getting a second full budget.
            let frame_ms = cfg.frame_budget_ms.max(1) as u128;
            let mut bytes_requested: u32 = 0;
            let mut reads_issued: usize = 0;
            let mut budget_capped = false;
            let mut worst_rtt: u32 = 0;
            // Watches already refreshed in THIS cycle's drain loop. Each
            // iteration excludes them, so successive batches advance through
            // the pending set instead of re-selecting the same stalest prefix.
            let mut done_this_cycle: HashSet<u64> = HashSet::new();
            // Coalesce once per cycle; re-filter the cheap members list each
            // iteration rather than re-coalescing.
            let coalesced_all = coalesce(&bulk_eligible, cfg.coalesce_gap);
            loop {
                // Stop once the shared frame window is spent. A read can
                // still overrun on transport jitter, but after the first
                // throughput sample we also shrink this iteration's byte cap
                // to the time actually left in the frame.
                let elapsed_ms = cycle_start.elapsed().as_millis();
                if elapsed_ms >= frame_ms {
                    break;
                }
                let Some(iter_budget) =
                    budget_for_remaining_time(budget, throughput, elapsed_ms, frame_ms)
                else {
                    break;
                };

                // Eligible = budget-sized coalesced reads with at least one
                // member whose latest request marker is still unfulfilled
                // and has not already been serviced in this cycle.
                let chunked = split_reads_to_budget(&coalesced_all, iter_budget);
                let pending: Vec<_> = chunked
                    .iter()
                    .filter(|r| read_is_pending(r, &request_seq, &read_state, &done_this_cycle))
                    .cloned()
                    .collect();
                if pending.is_empty() {
                    break; // all currently requested data is fulfilled
                }

                let sel = select_bulk(pending, iter_budget, &read_state, cycle);
                if sel.reads.is_empty() {
                    break;
                }
                budget_capped |= sel.capped;

                let regions: Vec<_> = sel.reads.iter().map(|r| r.region).collect();
                let bytes: u32 = regions.iter().map(|r| r.size).sum();
                if !batch_fits_remaining_time(bytes, throughput, elapsed_ms, frame_ms) {
                    break;
                }

                let t0 = Instant::now();
                match client.multi_read(&uri, &regions).await {
                    Ok(blobs) => {
                        let rtt = t0.elapsed().as_millis() as u32;
                        worst_rtt = worst_rtt.max(rtt);
                        apply_reads(&sel.reads, &blobs, &mut builder);
                        mark_fulfilled(&sel.reads, &request_seq, cycle, &mut read_state);
                        mark_done(&sel.reads, &mut done_this_cycle);
                        bytes_requested = bytes_requested.saturating_add(bytes);
                        reads_issued += 1;

                        // Adaptive byte budget: converge so a single batch
                        // fits the frame. Driven by the per-batch RTT.
                        let inst_bpms = bytes as f32 / rtt.max(1) as f32;
                        throughput = Some(match throughput {
                            Some(tp) => cfg.rtt_alpha * inst_bpms + (1.0 - cfg.rtt_alpha) * tp,
                            None => inst_bpms,
                        });
                        budget = next_budget(budget, rtt, throughput, &cfg);

                        // Don't start another batch that would clearly spend
                        // past the shared frame window, estimating the next
                        // cost from this batch's RTT.
                        if cycle_start.elapsed().as_millis() + rtt as u128 >= frame_ms {
                            break;
                        }
                    }
                    Err(e) => {
                        worst_rtt = worst_rtt.max(t0.elapsed().as_millis() as u32);
                        last_error = Some(classify_err(&e));
                        tracing::debug!("bulk multi_read failed: {e}");
                        break;
                    }
                }
            }

            let pending_after = pending_summary(
                &split_reads_to_budget(&coalesced_all, budget),
                &request_seq,
                &read_state,
                cycle,
            );
            let cycle_elapsed_ms = cycle_start.elapsed().as_millis() as u32;
            let frame_budget_ms = cfg.frame_budget_ms.max(1);
            let frame_budget_overran = cycle_elapsed_ms > frame_budget_ms;
            let frame_budget_overrun_ms = cycle_elapsed_ms.saturating_sub(frame_budget_ms);
            if frame_budget_overran {
                frame_budget_overruns += 1;
            }
            let overrun_sample = if frame_budget_overran { 1.0 } else { 0.0 };
            frame_budget_overrun_rate = if cycle <= 1 {
                overrun_sample
            } else {
                0.05 * overrun_sample + 0.95 * frame_budget_overrun_rate
            };
            let drain_sample = bytes_requested as f32 / cycle_elapsed_ms.max(1) as f32;
            deferred_drain_bpms_ewma = if cycle <= 1 {
                drain_sample
            } else {
                0.20 * drain_sample + 0.80 * deferred_drain_bpms_ewma
            };

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
                    cfg.rtt_alpha * rtt_ms as f32 + (1.0 - cfg.rtt_alpha) * st.rtt_ms_ewma
                };
                st.budget_capped = budget_capped;
                st.deferred_watches = pending_after.watches;
                st.deferred_bytes = pending_after.bytes;
                st.deferred_oldest_cycles = pending_after.oldest_cycles;
                st.deferred_avg_cycles = pending_after.avg_cycles;
                st.deferred_bytes_processed_last_cycle = bytes_requested;
                st.deferred_drain_bpms_ewma = deferred_drain_bpms_ewma;
                st.cycle_elapsed_ms = cycle_elapsed_ms;
                st.frame_budget_ms = frame_budget_ms;
                st.frame_budget_overran = frame_budget_overran;
                st.frame_budget_overrun_ms = frame_budget_overrun_ms;
                st.frame_budget_overruns = frame_budget_overruns;
                st.frame_budget_overrun_rate = frame_budget_overrun_rate;
                st.last_error = last_error;
            }

            // Garbage-collect read-state entries for watches that no longer
            // exist so it can't grow unbounded across room/script changes.
            if cycle.is_multiple_of(256) {
                read_state.retain(|id, _| live_ids.contains(id));
            }

            // Inter-cycle pacing: only sleep the UNUSED remainder of the
            // window. If the drain loop already consumed it (or overran —
            // latency-bound), continue immediately.
            let elapsed = cycle_start.elapsed();
            let target = cfg
                .target_period
                .min(Duration::from_millis(cfg.frame_budget_ms.max(1) as u64));
            if elapsed < target {
                tokio::time::sleep(target - elapsed).await;
            } else {
                tokio::task::yield_now().await;
            }
        }
    });

    engine
}

#[derive(Debug, Default, Clone, Copy)]
struct ReadState {
    /// Latest registry request marker fulfilled by a successful SNI read.
    request_seq: u64,
    /// Poll cycle when this watch was last refreshed.
    refresh_cycle: u64,
}

#[derive(Debug, Default, Clone, Copy)]
struct PendingSummary {
    watches: usize,
    bytes: u32,
    oldest_cycles: u32,
    avg_cycles: f32,
}

/// Result of selecting the bulk reads for one drain-loop iteration.
struct BulkSelection {
    /// Reads admitted for this batch.
    reads: Vec<CoalescedRead>,
    /// True if the budget trimmed at least one read (more deferred work
    /// remains for the next drain iteration / cycle).
    capped: bool,
}

/// Pick this iteration's pending reads, round-robin by oldest successful
/// refresh and trimmed to `budget`. Priority is only a tie-breaker after
/// staleness; realtime has already been removed into its own first tier.
fn select_bulk(
    mut reads: Vec<CoalescedRead>,
    budget: u32,
    read_state: &HashMap<WatchId, ReadState>,
    cycle: u64,
) -> BulkSelection {
    // Staleness of a coalesced read = the oldest member refresh cycle;
    // never-refreshed => 0 => maximally stale.
    let staleness = |r: &CoalescedRead| -> u64 {
        let oldest = r
            .members
            .iter()
            .map(|&(id, _, _)| read_state.get(&id).map(|s| s.refresh_cycle).unwrap_or(0))
            .min()
            .unwrap_or(0);
        cycle.saturating_sub(oldest)
    };

    // Stalest first; priority and address only make ties deterministic.
    reads.sort_by(|a, b| {
        staleness(b)
            .cmp(&staleness(a))
            .then_with(|| a.priority.cmp(&b.priority))
            .then_with(|| a.region.address.cmp(&b.region.address))
    });

    let mut remaining = budget;
    let mut capped = false;
    let mut selected = Vec::new();
    for r in reads {
        if r.region.size <= remaining {
            remaining -= r.region.size;
            selected.push(r);
        } else {
            capped = true;
            if selected.is_empty() {
                // A single watch can be larger than the adaptive byte budget.
                // Admit one oversized read so it cannot starve forever; the
                // AIMD step will react to any RTT overshoot.
                selected.push(r);
                break;
            }
        }
    }

    BulkSelection {
        reads: selected,
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
fn next_budget(budget: u32, rtt_ms: u32, throughput: Option<f32>, cfg: &PollConfig) -> u32 {
    let frame_ms = cfg.frame_budget_ms.max(1) as f32;
    let b = budget as f32;
    let next = if rtt_ms > cfg.frame_budget_ms {
        let overshoot = (rtt_ms.max(1) as f32 / frame_ms).min(4.0);
        (b * (0.5 / overshoot).max(0.2)).max(0.0)
    } else {
        let ceil = throughput
            .map(|t| t * frame_ms * THROUGHPUT_HEADROOM)
            .unwrap_or(b);
        let step = (cfg.max_byte_budget as f32 * 0.05).max(256.0);
        // Grow additively toward the throughput ceiling; never shrink here.
        (b + step).min(ceil.max(b))
    };
    (next as u32).clamp(cfg.min_byte_budget, cfg.max_byte_budget)
}

/// Trim a full-frame byte budget to what the measured throughput says still
/// fits in the current frame remainder.
fn budget_for_remaining_time(
    budget: u32,
    throughput: Option<f32>,
    elapsed_ms: u128,
    frame_ms: u128,
) -> Option<u32> {
    if elapsed_ms >= frame_ms {
        return None;
    }
    let Some(tp) = throughput.filter(|tp| tp.is_finite() && *tp > 0.0) else {
        return Some(budget);
    };

    let remaining_ms = (frame_ms - elapsed_ms) as f32;
    let capped = (tp * remaining_ms * THROUGHPUT_HEADROOM).floor() as u32;
    if capped == 0 {
        None
    } else {
        Some(budget.min(capped.max(1)))
    }
}

fn predicted_rtt_ms(bytes: u32, throughput: Option<f32>) -> Option<u128> {
    let tp = throughput.filter(|tp| tp.is_finite() && *tp > 0.0)?;
    Some((bytes as f32 / tp).ceil().max(1.0) as u128)
}

fn batch_fits_remaining_time(
    bytes: u32,
    throughput: Option<f32>,
    elapsed_ms: u128,
    frame_ms: u128,
) -> bool {
    predicted_rtt_ms(bytes, throughput)
        .map(|predicted| elapsed_ms.saturating_add(predicted) <= frame_ms)
        .unwrap_or(true)
}

/// Slice each coalesced blob back to its member watches and write them into
/// the snapshot builder. Shared by the Realtime sub-poll and the bulk batch.
fn apply_reads(reads: &[CoalescedRead], blobs: &[Vec<u8>], builder: &mut SnapshotBuilder) {
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

fn read_is_pending(
    read: &CoalescedRead,
    request_seq: &HashMap<WatchId, u64>,
    read_state: &HashMap<WatchId, ReadState>,
    done_this_cycle: &HashSet<WatchId>,
) -> bool {
    read.members.iter().any(|&(id, _, _)| {
        !done_this_cycle.contains(&id)
            && request_seq.get(&id).copied().unwrap_or(0)
                > read_state.get(&id).map(|s| s.request_seq).unwrap_or(0)
    })
}

fn mark_fulfilled(
    reads: &[CoalescedRead],
    request_seq: &HashMap<WatchId, u64>,
    cycle: u64,
    read_state: &mut HashMap<WatchId, ReadState>,
) {
    for read in reads {
        for &(id, _, _) in &read.members {
            if let Some(seq) = request_seq.get(&id).copied() {
                read_state.insert(
                    id,
                    ReadState {
                        request_seq: seq,
                        refresh_cycle: cycle,
                    },
                );
            }
        }
    }
}

fn mark_done(reads: &[CoalescedRead], done_this_cycle: &mut HashSet<WatchId>) {
    for read in reads {
        for &(id, _, _) in &read.members {
            done_this_cycle.insert(id);
        }
    }
}

fn pending_summary(
    reads: &[CoalescedRead],
    request_seq: &HashMap<WatchId, u64>,
    read_state: &HashMap<WatchId, ReadState>,
    cycle: u64,
) -> PendingSummary {
    let mut pending_ids = HashSet::new();
    let mut bytes = 0u32;
    let mut oldest = 0u64;
    let mut age_sum = 0u64;

    for read in reads {
        let mut read_pending = false;
        for &(id, _, _) in &read.members {
            let Some(seq) = request_seq.get(&id).copied() else {
                continue;
            };
            let state = read_state.get(&id).copied().unwrap_or_default();
            if seq <= state.request_seq || !pending_ids.insert(id) {
                continue;
            }
            let age = cycle.saturating_sub(state.refresh_cycle);
            oldest = oldest.max(age);
            age_sum = age_sum.saturating_add(age);
            read_pending = true;
        }
        if read_pending {
            bytes = bytes.saturating_add(read.region.size);
        }
    }

    let watches = pending_ids.len();
    PendingSummary {
        watches,
        bytes,
        oldest_cycles: oldest.min(u32::MAX as u64) as u32,
        avg_cycles: if watches == 0 {
            0.0
        } else {
            age_sum as f32 / watches as f32
        },
    }
}

fn split_reads_to_budget(reads: &[CoalescedRead], budget: u32) -> Vec<CoalescedRead> {
    let budget = budget.max(1);
    let mut out = Vec::new();
    for read in reads {
        if read.region.size <= budget {
            out.push(read.clone());
            continue;
        }

        let mut members = read.members.clone();
        members.sort_by_key(|&(_, off, _)| off);

        let mut i = 0;
        while i < members.len() {
            let (first_id, first_off, first_size) = members[i];
            let chunk_start = read.region.address + first_off;
            let mut chunk_end = chunk_start + first_size;
            let mut chunk_members = vec![(first_id, 0, first_size)];
            i += 1;

            while i < members.len() {
                let (id, off, size) = members[i];
                let member_start = read.region.address + off;
                let member_end = member_start + size;
                let candidate_end = chunk_end.max(member_end);
                if candidate_end - chunk_start > budget {
                    break;
                }
                chunk_members.push((id, member_start - chunk_start, size));
                chunk_end = candidate_end;
                i += 1;
            }

            out.push(CoalescedRead {
                region: sni_client::MemRegion {
                    address: chunk_start,
                    size: chunk_end - chunk_start,
                    space: read.region.space,
                    mapping: read.region.mapping,
                },
                members: chunk_members,
                priority: read.priority,
            });
        }
    }
    out
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

    fn request_seq_for(reads: &[CoalescedRead], seq: u64) -> HashMap<WatchId, u64> {
        reads
            .iter()
            .flat_map(|r| r.members.iter().map(move |&(id, _, _)| (id, seq)))
            .collect()
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
        read_state: &mut HashMap<WatchId, ReadState>,
        cycle: u64,
        max_batches: usize,
    ) -> Vec<u32> {
        let request_seq = request_seq_for(all_reads, cycle);
        let mut done: HashSet<WatchId> = HashSet::new();
        let mut refreshed = Vec::new();
        for _ in 0..max_batches {
            let chunked = split_reads_to_budget(all_reads, budget);
            let pending: Vec<_> = chunked
                .iter()
                .filter(|r| read_is_pending(r, &request_seq, read_state, &done))
                .cloned()
                .collect();
            if pending.is_empty() {
                break; // fully drained this cycle
            }
            let sel = select_bulk(pending, budget, read_state, cycle);
            if sel.reads.is_empty() {
                break;
            }
            for r in &sel.reads {
                refreshed.push(r.region.address);
            }
            mark_fulfilled(&sel.reads, &request_seq, cycle, read_state);
            mark_done(&sel.reads, &mut done);
        }
        refreshed
    }

    // Mirrors the real loop's shared time guard: realtime spends from the
    // same frame budget, and bulk starts only while time remains.
    fn batches_issued(
        frame_ms: u128,
        realtime_cost_ms: u128,
        per_batch_ms: u128,
        pending_batches: usize,
    ) -> usize {
        let mut issued = 0usize;
        let mut elapsed = realtime_cost_ms;
        for _ in 0..pending_batches {
            if elapsed >= frame_ms {
                break;
            }
            issued += 1;
            elapsed += per_batch_ms;
        }
        issued
    }

    #[test]
    fn realtime_poll_spends_the_shared_frame_budget() {
        // Realtime is always first. If it consumes the whole 16ms window,
        // bulk does not get an extra private budget.
        assert_eq!(batches_issued(16, 20, 4, 100), 0);
        assert_eq!(batches_issued(16, 16, 4, 100), 0);

        // If realtime leaves 8ms and batches cost ~4ms, two bulk batches fit.
        assert_eq!(batches_issued(16, 8, 4, 100), 2);
    }

    #[test]
    fn bulk_only_reads_unfulfilled_requests() {
        let reads = vec![
            cr(0x1000, 64, WatchPriority::Normal),
            cr(0x2000, 64, WatchPriority::Normal),
        ];
        let mut state = HashMap::new();
        state.insert(
            0x1000,
            ReadState {
                request_seq: 5,
                refresh_cycle: 1,
            },
        );
        let mut request_seq = HashMap::new();
        request_seq.insert(0x1000, 5); // already fulfilled
        request_seq.insert(0x2000, 6); // pending
        let done = HashSet::new();

        let pending: Vec<_> = reads
            .iter()
            .filter(|r| read_is_pending(r, &request_seq, &state, &done))
            .cloned()
            .collect();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].region.address, 0x2000);
    }

    #[test]
    fn oversized_coalesced_reads_are_split_to_budget() {
        let read = CoalescedRead {
            region: sni_client::MemRegion::fxpak(0x2000, 1000),
            members: vec![(1, 0, 200), (2, 300, 200), (3, 700, 200)],
            priority: WatchPriority::Low,
        };

        let chunks = split_reads_to_budget(&[read], 500);
        assert_eq!(chunks.len(), 2);
        assert_eq!(chunks[0].region.address, 0x2000);
        assert_eq!(chunks[0].region.size, 500);
        assert_eq!(chunks[0].members, vec![(1, 0, 200), (2, 300, 200)]);
        assert_eq!(chunks[1].region.address, 0x2000 + 700);
        assert_eq!(chunks[1].region.size, 200);
        assert_eq!(chunks[1].members, vec![(3, 0, 200)]);
    }

    #[test]
    fn pending_summary_reports_backlog_and_staleness() {
        let reads = vec![
            cr(0x1000, 64, WatchPriority::Normal),
            cr(0x2000, 128, WatchPriority::Low),
            cr(0x3000, 256, WatchPriority::Low),
        ];
        let mut request_seq = HashMap::new();
        request_seq.insert(0x1000, 2);
        request_seq.insert(0x2000, 2);
        request_seq.insert(0x3000, 2);

        let mut state = HashMap::new();
        state.insert(
            0x1000,
            ReadState {
                request_seq: 2,
                refresh_cycle: 7,
            },
        );
        state.insert(
            0x2000,
            ReadState {
                request_seq: 1,
                refresh_cycle: 4,
            },
        );

        let summary = pending_summary(&reads, &request_seq, &state, 10);
        assert_eq!(summary.watches, 2);
        assert_eq!(summary.bytes, 128 + 256);
        assert_eq!(summary.oldest_cycles, 10);
        assert!((summary.avg_cycles - 8.0).abs() < f32::EPSILON);
    }

    #[test]
    fn high_priority_is_never_starved_by_low() {
        // Small High + big Low, budget fits only one big Low per batch.
        // High must still fit into each batch even as older Low reads rotate.
        let mut lr = HashMap::new();
        for cycle in 1..8 {
            let reads = vec![
                cr(0x1000, 64, WatchPriority::High),
                cr(0x2000, 4096, WatchPriority::Low),
                cr(0x3000, 4096, WatchPriority::Low),
                cr(0x4000, 4096, WatchPriority::Low),
            ];
            // Even with a single batch this cycle, High is not squeezed out.
            let refreshed = step_drain(&reads, 4096 + 64, &mut lr, cycle, 1);
            assert!(refreshed.contains(&0x1000), "High starved at cycle {cycle}");
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
        // registered watch has no read state -> maximally stale -> must be
        // picked up promptly, and existing ones must not starve.
        let budget = 3000;
        let mut lr = HashMap::new();
        let mut seen = std::collections::HashSet::new();
        let mut addrs: Vec<u32> = (0..5).map(|i| 0x2000 + i * 0x1000).collect();
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
    fn remaining_time_caps_iteration_budget_by_throughput() {
        // 8ms left at ~500 B/ms with 20% headroom -> 3200 bytes.
        let capped = budget_for_remaining_time(6400, Some(500.0), 8, 16);
        assert_eq!(capped, Some(3200));
    }

    #[test]
    fn unknown_throughput_keeps_full_iteration_budget() {
        assert_eq!(budget_for_remaining_time(4096, None, 12, 16), Some(4096));
    }

    #[test]
    fn predicted_overrun_defers_late_batch() {
        // 4000 bytes at ~500 B/ms predicts ~8ms RTT, which does not fit in
        // the last 4ms of a 16ms frame.
        assert!(!batch_fits_remaining_time(4000, Some(500.0), 12, 16));
        assert!(batch_fits_remaining_time(1600, Some(500.0), 12, 16));
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
        let hi = next_budget(c.max_byte_budget, 1, Some(1_000_000.0), &c);
        assert_eq!(hi, c.max_byte_budget);
    }
}
