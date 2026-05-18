//! Immutable snapshot of all watched memory at a point in time.
//!
//! The poll engine publishes a fresh `Snapshot` via `ArcSwap`; scripts read
//! from whatever the latest published snapshot is, never blocking on I/O.
//! Placeholder for M3.

use std::collections::HashMap;

use sni_client::MemRegion;

#[derive(Debug, Default, Clone)]
pub struct Snapshot {
    /// Watch id -> last-known bytes for that region.
    pub(crate) data: HashMap<u64, Vec<u8>>,
    /// Region metadata keyed by watch id (for write-back / debugging).
    pub(crate) regions: HashMap<u64, MemRegion>,
    /// Monotonic frame counter at which this snapshot was published.
    pub frame: u64,
    /// Wall-clock age of the data in this snapshot, in milliseconds.
    pub age_ms: u32,
}

impl Snapshot {
    pub fn bytes(&self, watch_id: u64) -> Option<&[u8]> {
        self.data.get(&watch_id).map(|v| v.as_slice())
    }
}
