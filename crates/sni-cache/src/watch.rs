//! Watch registry: scripts declare regions of interest; the poll engine
//! coalesces them into batched `MultiRead` calls.
//!
//! A *watch* is a `(MemRegion, priority)` a script cares about. Scripts never
//! read SNI directly — they register watches and read the latest published
//! [`crate::Snapshot`]. Watches can be added/removed between frames (scripts
//! may change what they care about, e.g. only watch an enemy table when in a
//! room with enemies).

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;

use parking_lot::RwLock;
use sni_client::MemRegion;

pub type WatchId = u64;

/// How often a watch is refreshed relative to others — the lever that spends
/// the per-cycle bandwidth budget where it matters.
/// Ordered most-urgent first so `min()` upgrades a watch correctly when a
/// script hints a higher tier for an address that's already registered.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum WatchPriority {
    /// The freshest tier. Polled every cycle in its OWN tiny coalesced read,
    /// kept separate from the bulk batch so a few latency-critical bytes
    /// (controller state) are never queued behind block/level data.
    Realtime,
    /// Refresh every poll cycle (in the bulk batch). Fast-moving visuals:
    /// Samus position, camera, projectile coordinates.
    High,
    /// Refresh every few cycles. Item counts, health, room flags.
    Normal,
    /// Refresh rarely. Static-ish room/level/block data; good prefetch
    /// candidate so it's already cached the moment a script needs it.
    Low,
}

impl WatchPriority {
    /// Refresh period in poll cycles. Realtime/High = every cycle.
    pub fn period(self) -> u64 {
        match self {
            WatchPriority::Realtime => 1,
            WatchPriority::High => 1,
            WatchPriority::Normal => 3,
            WatchPriority::Low => 12,
        }
    }

    /// Realtime is served by a separate, tight sub-poll rather than the
    /// bulk MultiRead batch.
    pub fn is_realtime(self) -> bool {
        matches!(self, WatchPriority::Realtime)
    }

    pub fn parse(s: &str) -> WatchPriority {
        match s.to_ascii_lowercase().as_str() {
            "realtime" | "input" => WatchPriority::Realtime,
            "high" => WatchPriority::High,
            "low" | "prefetch" => WatchPriority::Low,
            _ => WatchPriority::Normal,
        }
    }
}

#[derive(Debug, Clone)]
pub struct WatchHandle {
    pub id: WatchId,
    pub region: MemRegion,
    pub priority: WatchPriority,
}

/// Internal registry entry: the handle plus demand-tracking state. The
/// read-through cache registers a watch on first touch and never explicitly
/// unregisters, so without this the polled set only grows — eventually the
/// budget is saturated refreshing data the script no longer reads. Instead
/// each watch records when the script last *requested* it; the engine only
/// actively polls watches touched within a demand window. Dormant watches
/// keep their last cached value (the script can still read stale data) but
/// cost no bandwidth until touched again.
struct WatchEntry {
    handle: WatchHandle,
    /// Last time a Lua accessor read this watch's value.
    last_touch: Instant,
    /// Monotonic request marker. Incremented when the script asks for this
    /// watch's cached value; the poll engine fulfils the latest marker after
    /// it successfully refreshes the watch from SNI.
    request_seq: u64,
    /// Declared watches (controller mirror, frame counter, explicit
    /// snes.tier) are pinned: never demand-evicted. Non-realtime pinned
    /// watches are still bulk-fetched only when requested; realtime active
    /// watches are read every cycle.
    pinned: bool,
}

/// Registry shared between the script host (writers) and the poll engine
/// (reader). Cheap reads of the full set each cycle via a snapshot clone;
/// registration is rare relative to polling.
#[derive(Default)]
pub struct WatchRegistry {
    next_id: AtomicU64,
    next_request: AtomicU64,
    inner: RwLock<BTreeMap<WatchId, WatchEntry>>,
}

impl WatchRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn register(&self, region: MemRegion, priority: WatchPriority) -> WatchHandle {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let request_seq = self.next_request.fetch_add(1, Ordering::Relaxed) + 1;
        let handle = WatchHandle {
            id,
            region,
            priority,
        };
        self.inner.write().insert(
            id,
            WatchEntry {
                handle: handle.clone(),
                last_touch: Instant::now(), // just-registered counts as wanted
                request_seq,
                pinned: false,
            },
        );
        handle
    }

    /// Mark a watch as requested by the script *now*. Called by the Lua value
    /// accessors so the engine knows the script still cares; resets the
    /// demand-eviction timer. Cheap (write lock, O(log n)) and only on actual
    /// reads.
    pub fn touch(&self, id: WatchId) {
        let request_seq = self.next_request.fetch_add(1, Ordering::Relaxed) + 1;
        if let Some(e) = self.inner.write().get_mut(&id) {
            e.last_touch = Instant::now();
            e.request_seq = request_seq;
        }
    }

    /// Pin a watch so it stays active regardless of demand. For declared
    /// watches (controller mirror, frame counter, explicit `snes.tier`) that
    /// should not go dormant just because the script skips reading them for a
    /// few frames.
    pub fn pin(&self, id: WatchId) {
        let request_seq = self.next_request.fetch_add(1, Ordering::Relaxed) + 1;
        if let Some(e) = self.inner.write().get_mut(&id) {
            e.pinned = true;
            e.last_touch = Instant::now();
            e.request_seq = request_seq;
        }
    }

    /// Raise a watch to at least `priority` (never downgrades). Used by
    /// `snes.tier` so an explicit hint can upgrade an address that was
    /// already auto-registered, without a later auto-classify clobbering it.
    /// `WatchPriority` is ordered most-urgent-first, so the upgrade is `min`.
    /// An explicit tier hint also pins the watch (it's now declared, not
    /// demand-driven).
    pub fn upgrade_priority(&self, id: WatchId, priority: WatchPriority) {
        let request_seq = self.next_request.fetch_add(1, Ordering::Relaxed) + 1;
        if let Some(e) = self.inner.write().get_mut(&id) {
            if priority < e.handle.priority {
                e.handle.priority = priority;
            }
            e.pinned = true;
            e.last_touch = Instant::now();
            e.request_seq = request_seq;
        }
    }

    pub fn unregister(&self, id: WatchId) {
        self.inner.write().remove(&id);
    }

    pub fn clear(&self) {
        self.inner.write().clear();
    }

    /// All watches, ordered by id. Used for snapshot retention so dormant
    /// (demand-evicted) watches keep their last cached value — the script can
    /// still read stale data, it just isn't refreshed.
    pub fn all(&self) -> Vec<WatchHandle> {
        self.inner
            .read()
            .values()
            .map(|e| e.handle.clone())
            .collect()
    }

    /// Watches the engine should actively poll this cycle: pinned ones, plus
    /// auto-registered ones the script has read within `window`. This is the
    /// demand filter that stops us spending bandwidth on data the script
    /// stopped caring about (e.g. blocks from rooms ago).
    pub fn active(&self, window: std::time::Duration) -> Vec<WatchHandle> {
        self.active_with_requests(window)
            .into_iter()
            .map(|(handle, _)| handle)
            .collect()
    }

    /// Active watches plus their latest request marker. The engine uses this
    /// to distinguish active-but-already-fulfilled cache entries from data
    /// the script has requested since the last successful SNI refresh.
    pub(crate) fn active_with_requests(
        &self,
        window: std::time::Duration,
    ) -> Vec<(WatchHandle, u64)> {
        let now = Instant::now();
        self.inner
            .read()
            .values()
            .filter(|e| e.pinned || now.duration_since(e.last_touch) < window)
            .map(|e| (e.handle.clone(), e.request_seq))
            .collect()
    }

    pub fn len(&self) -> usize {
        self.inner.read().len()
    }

    /// Count of watches currently active for a given demand window (HUD).
    pub fn active_len(&self, window: std::time::Duration) -> usize {
        let now = Instant::now();
        self.inner
            .read()
            .values()
            .filter(|e| e.pinned || now.duration_since(e.last_touch) < window)
            .count()
    }

    pub fn is_empty(&self) -> bool {
        self.inner.read().is_empty()
    }
}

/// A merged read covering one or more watches that are adjacent/overlapping
/// in the same address space. Issued as a single `MultiRead` sub-request;
/// results are sliced back to each member watch.
#[derive(Debug, Clone)]
pub struct CoalescedRead {
    pub region: MemRegion,
    /// (watch id, byte offset within `region`, watch size).
    pub members: Vec<(WatchId, u32, u32)>,
    /// Most-urgent priority among the members. The budgeter sorts by this so
    /// trimming sheds genuinely-lowest-priority reads (not just high
    /// addresses, which `coalesce` happens to order by).
    pub priority: WatchPriority,
}

/// Merge the given watches into the fewest read requests. Watches in the same
/// address space whose ranges are within `gap` bytes of each other are fused
/// into one read — fewer round-trip bytes for the same data, which is the
/// whole point on a latency-bound link.
///
/// `gap` lets us bridge small holes (e.g. two 2-byte watches 4 bytes apart)
/// rather than paying for two separate sub-requests; tune per latency class.
pub fn coalesce(watches: &[WatchHandle], gap: u32) -> Vec<CoalescedRead> {
    if watches.is_empty() {
        return Vec::new();
    }

    // Group by address space + mapping; only same-space regions can merge.
    let mut by_space: BTreeMap<(i32, i32), Vec<&WatchHandle>> = BTreeMap::new();
    for w in watches {
        by_space
            .entry((w.region.space as i32, w.region.mapping as i32))
            .or_default()
            .push(w);
    }

    let mut out = Vec::new();
    for (_, mut group) in by_space {
        group.sort_by_key(|w| w.region.address);

        let mut cur_start = group[0].region.address;
        let mut cur_end = cur_start + group[0].region.size; // exclusive
        let mut cur_members: Vec<&WatchHandle> = vec![group[0]];

        for w in &group[1..] {
            let ws = w.region.address;
            let we = ws + w.region.size;
            if ws <= cur_end.saturating_add(gap) {
                // Overlaps or close enough — extend the current run.
                cur_end = cur_end.max(we);
                cur_members.push(w);
            } else {
                out.push(finish_run(cur_start, cur_end, &cur_members));
                cur_start = ws;
                cur_end = we;
                cur_members = vec![w];
            }
        }
        out.push(finish_run(cur_start, cur_end, &cur_members));
    }
    out
}

fn finish_run(start: u32, end: u32, members: &[&WatchHandle]) -> CoalescedRead {
    // All members share space+mapping (grouped above); take it from the first.
    let proto = members[0].region;
    let region = MemRegion {
        address: start,
        size: end - start,
        space: proto.space,
        mapping: proto.mapping,
    };
    // Most-urgent member wins (WatchPriority is ordered urgent-first, so min).
    let priority = members
        .iter()
        .map(|w| w.priority)
        .min()
        .unwrap_or(WatchPriority::Low);
    let members = members
        .iter()
        .map(|w| (w.id, w.region.address - start, w.region.size))
        .collect();
    CoalescedRead {
        region,
        members,
        priority,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn h(id: WatchId, addr: u32, size: u32) -> WatchHandle {
        WatchHandle {
            id,
            region: MemRegion::fxpak(addr, size),
            priority: WatchPriority::High,
        }
    }

    #[test]
    fn adjacent_watches_merge_into_one_read() {
        // Two 2-byte watches 4 bytes apart (Samus X @ 0AF6, Y @ 0AFA in SM).
        let ws = vec![h(1, 0xF5_0AF6, 2), h(2, 0xF5_0AFA, 2)];
        let reads = coalesce(&ws, 8);
        assert_eq!(reads.len(), 1, "should fuse into a single read");
        let r = &reads[0];
        assert_eq!(r.region.address, 0xF5_0AF6);
        assert_eq!(r.region.size, 0x0AFC - 0x0AF6); // covers both
        assert_eq!(r.members.len(), 2);
        assert_eq!(r.members[0], (1, 0, 2));
        assert_eq!(r.members[1], (2, 4, 2)); // offset 4 within merged region
    }

    #[test]
    fn distant_watches_stay_separate() {
        let ws = vec![h(1, 0xF5_0000, 2), h(2, 0xF5_8000, 2)];
        let reads = coalesce(&ws, 8);
        assert_eq!(reads.len(), 2, "far-apart watches must not fuse");
    }

    #[test]
    fn overlapping_watches_merge_and_cover_union() {
        let ws = vec![h(1, 0xF5_0100, 8), h(2, 0xF5_0104, 8)];
        let reads = coalesce(&ws, 0);
        assert_eq!(reads.len(), 1);
        assert_eq!(reads[0].region.size, 12); // 0x0100..0x010C
    }

    #[test]
    fn different_address_spaces_never_merge() {
        let mut a = h(1, 0x0000, 4);
        a.region.space = sni_client::AddressSpace::FxPakPro;
        let mut b = h(2, 0x0000, 4);
        b.region.space = sni_client::AddressSpace::SnesABus;
        let reads = coalesce(&[a, b], 64);
        assert_eq!(reads.len(), 2);
    }

    #[test]
    fn priority_order_is_realtime_first() {
        // Ordered most-urgent-first so the engine can split realtime out and
        // `upgrade_priority` (a min) raises urgency correctly.
        assert!(WatchPriority::Realtime < WatchPriority::High);
        assert!(WatchPriority::High < WatchPriority::Normal);
        assert!(WatchPriority::Normal < WatchPriority::Low);
        assert!(WatchPriority::Realtime.is_realtime());
        assert!(!WatchPriority::High.is_realtime());
        assert_eq!(WatchPriority::parse("input"), WatchPriority::Realtime);
        assert_eq!(WatchPriority::parse("prefetch"), WatchPriority::Low);
    }

    #[test]
    fn upgrade_only_raises_urgency() {
        let reg = WatchRegistry::new();
        let w = reg.register(MemRegion::fxpak(0xF5_008B, 1), WatchPriority::Low);
        // Low -> Realtime: upgrades.
        reg.upgrade_priority(w.id, WatchPriority::Realtime);
        assert_eq!(reg.all()[0].priority, WatchPriority::Realtime);
        // Realtime -> Normal: must NOT downgrade (explicit hint stays).
        reg.upgrade_priority(w.id, WatchPriority::Normal);
        assert_eq!(reg.all()[0].priority, WatchPriority::Realtime);
    }

    #[test]
    fn unread_watch_goes_dormant_but_stays_cached() {
        use std::time::Duration;
        let reg = WatchRegistry::new();
        let a = reg.register(MemRegion::fxpak(0xF5_0AF6, 2), WatchPriority::High);
        let b = reg.register(MemRegion::fxpak(0xF5_8000, 16), WatchPriority::Low);

        // Fresh registrations are active under a generous window.
        let active: Vec<_> = reg
            .active(Duration::from_secs(3600))
            .iter()
            .map(|w| w.id)
            .collect();
        assert!(
            active.contains(&a.id) && active.contains(&b.id),
            "fresh registrations are active"
        );

        // Let time pass, then touch only `a`. With a sub-elapsed window,
        // `a` (touched just now) survives; `b` (untouched) goes dormant.
        std::thread::sleep(Duration::from_millis(5));
        reg.touch(a.id);
        let win = Duration::from_millis(2);
        let active: Vec<_> = reg.active(win).iter().map(|w| w.id).collect();
        assert!(active.contains(&a.id), "touched watch stays active");
        assert!(!active.contains(&b.id), "unread watch goes dormant");

        // Dormant != gone: it's still registered (cache retained via all()).
        assert!(
            reg.all().iter().any(|w| w.id == b.id),
            "dormant watch keeps its cached value"
        );

        // Pinning overrides demand: pin b, it's active despite being unread.
        reg.pin(b.id);
        let active: Vec<_> = reg.active(win).iter().map(|w| w.id).collect();
        assert!(active.contains(&b.id), "pinned watch ignores demand window");
    }
}
