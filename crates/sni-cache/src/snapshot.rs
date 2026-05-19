//! Immutable snapshot of all watched memory at a point in time.
//!
//! The poll engine builds a fresh `Snapshot` each cycle and publishes it via
//! `ArcSwap`. Scripts read from whatever the latest published snapshot is —
//! a lock-free atomic load, never blocking on SNI I/O. A script reading the
//! "current" value is really reading "the value as of the last completed
//! poll cycle", which is the only honest thing we can offer on a
//! latency-bound link, and is what keeps the overlay smooth.

use std::collections::HashMap;

use sni_client::MemRegion;

use crate::watch::WatchId;

#[derive(Debug, Default, Clone)]
pub struct Snapshot {
    /// Watch id -> last-known bytes for that region.
    data: HashMap<WatchId, Vec<u8>>,
    /// Region metadata keyed by watch id (debugging / write-back).
    regions: HashMap<WatchId, MemRegion>,
    /// Per-watch age: poll cycles since this watch's bytes were last refreshed.
    /// 0 = refreshed this cycle. Lets scripts/HUD show staleness for Low-prio
    /// watches that aren't read every cycle.
    age_cycles: HashMap<WatchId, u32>,
    /// Monotonic poll-cycle counter at which this snapshot was published.
    pub cycle: u64,
    /// Wall-clock age of the freshest data in this snapshot, milliseconds.
    pub age_ms: u32,
    /// Round-trip time of the poll cycle that produced this snapshot.
    pub last_rtt_ms: u32,
}

impl Snapshot {
    pub fn bytes(&self, id: WatchId) -> Option<&[u8]> {
        self.data.get(&id).map(|v| v.as_slice())
    }

    pub fn region(&self, id: WatchId) -> Option<MemRegion> {
        self.regions.get(&id).copied()
    }

    /// Poll cycles since this watch was last refreshed (`None` if never read).
    pub fn watch_age(&self, id: WatchId) -> Option<u32> {
        self.age_cycles.get(&id).copied()
    }

    pub fn has(&self, id: WatchId) -> bool {
        self.data.contains_key(&id)
    }

    // --- typed little-endian accessors (SNES is little-endian) ---

    pub fn u8(&self, id: WatchId) -> Option<u8> {
        self.bytes(id).and_then(|b| b.first().copied())
    }

    pub fn u16(&self, id: WatchId) -> Option<u16> {
        self.bytes(id)
            .filter(|b| b.len() >= 2)
            .map(|b| u16::from_le_bytes([b[0], b[1]]))
    }

    /// 24-bit little-endian (common for SNES pointers / 3-byte values).
    pub fn u24(&self, id: WatchId) -> Option<u32> {
        self.bytes(id)
            .filter(|b| b.len() >= 3)
            .map(|b| u32::from_le_bytes([b[0], b[1], b[2], 0]))
    }

    pub fn u32(&self, id: WatchId) -> Option<u32> {
        self.bytes(id)
            .filter(|b| b.len() >= 4)
            .map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
    }

    /// Signed 8-bit.
    pub fn i8(&self, id: WatchId) -> Option<i8> {
        self.u8(id).map(|v| v as i8)
    }

    /// Signed 16-bit — SNES coordinates/velocities are frequently signed.
    pub fn i16(&self, id: WatchId) -> Option<i16> {
        self.u16(id).map(|v| v as i16)
    }

    /// Signed 32-bit.
    pub fn i32(&self, id: WatchId) -> Option<i32> {
        self.u32(id).map(|v| v as i32)
    }
}

/// Builder used by the poll engine to assemble the next snapshot, carrying
/// forward unchanged bytes for watches not refreshed this cycle (so a Low
/// priority watch keeps its last value instead of vanishing).
#[derive(Default)]
pub struct SnapshotBuilder {
    data: HashMap<WatchId, Vec<u8>>,
    regions: HashMap<WatchId, MemRegion>,
    age_cycles: HashMap<WatchId, u32>,
}

impl SnapshotBuilder {
    /// Seed from the previous snapshot so untouched watches retain their data.
    pub fn from_prev(prev: &Snapshot) -> Self {
        Self {
            data: prev.data.clone(),
            regions: prev.regions.clone(),
            // Everything ages by one cycle unless refreshed below.
            age_cycles: prev
                .age_cycles
                .iter()
                .map(|(k, v)| (*k, v.saturating_add(1)))
                .collect(),
        }
    }

    pub fn set(&mut self, id: WatchId, region: MemRegion, bytes: Vec<u8>) {
        self.data.insert(id, bytes);
        self.regions.insert(id, region);
        self.age_cycles.insert(id, 0);
    }

    /// Drop watches that no longer exist so the snapshot doesn't grow forever.
    pub fn retain_only(&mut self, live: &std::collections::HashSet<WatchId>) {
        self.data.retain(|k, _| live.contains(k));
        self.regions.retain(|k, _| live.contains(k));
        self.age_cycles.retain(|k, _| live.contains(k));
    }

    pub fn build(self, cycle: u64, age_ms: u32, last_rtt_ms: u32) -> Snapshot {
        Snapshot {
            data: self.data,
            regions: self.regions,
            age_cycles: self.age_cycles,
            cycle,
            age_ms,
            last_rtt_ms,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn region() -> MemRegion {
        MemRegion::fxpak(0xF5_0AF6, 2)
    }

    #[test]
    fn typed_accessors_are_little_endian() {
        let mut b = SnapshotBuilder::default();
        b.set(7, region(), vec![0x34, 0x12]);
        let snap = b.build(1, 0, 5);
        assert_eq!(snap.u8(7), Some(0x34));
        assert_eq!(snap.u16(7), Some(0x1234));
        assert_eq!(snap.watch_age(7), Some(0));
    }

    #[test]
    fn unrefreshed_watches_age_but_keep_value() {
        let mut b = SnapshotBuilder::default();
        b.set(7, region(), vec![0x01, 0x00]);
        let s1 = b.build(1, 0, 5);

        // Next cycle refreshes nothing.
        let b2 = SnapshotBuilder::from_prev(&s1);
        let s2 = b2.build(2, 0, 5);
        assert_eq!(s2.u16(7), Some(1), "stale value retained");
        assert_eq!(s2.watch_age(7), Some(1), "aged by one cycle");
    }

    #[test]
    fn retain_drops_dead_watches() {
        let mut b = SnapshotBuilder::default();
        b.set(1, region(), vec![0, 0]);
        b.set(2, region(), vec![0, 0]);
        let mut live = std::collections::HashSet::new();
        live.insert(1);
        b.retain_only(&live);
        let snap = b.build(1, 0, 0);
        assert!(snap.has(1));
        assert!(!snap.has(2));
    }
}
