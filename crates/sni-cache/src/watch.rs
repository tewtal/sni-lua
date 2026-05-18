//! Watch registry: scripts declare regions of interest; the poll engine
//! coalesces them into batched MultiRead calls. Placeholder for M3.

use std::sync::atomic::{AtomicU64, Ordering};

use parking_lot::RwLock;
use sni_client::MemRegion;

pub type WatchId = u64;

#[derive(Debug, Clone)]
pub struct WatchHandle {
    pub id: WatchId,
    pub region: MemRegion,
}

/// Priority controls how often a watch is refreshed relative to others —
/// the lever that lets scripts spend the bandwidth budget where it matters.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WatchPriority {
    /// Refresh every poll cycle (e.g. Samus position for a hitbox).
    High,
    /// Refresh every few cycles (e.g. item counts).
    Normal,
    /// Refresh rarely (e.g. static room metadata); good prefetch candidate.
    Low,
}

#[derive(Default)]
pub struct WatchRegistry {
    next_id: AtomicU64,
    inner: RwLock<Vec<WatchHandle>>,
}

impl WatchRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn register(&self, region: MemRegion) -> WatchHandle {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let handle = WatchHandle { id, region };
        self.inner.write().push(handle.clone());
        handle
    }

    pub fn all(&self) -> Vec<WatchHandle> {
        self.inner.read().clone()
    }
}
