//! Watch registry, snapshot cache, and async poll engine.
//!
//! This crate is the bandwidth strategy. Scripts declare [`WatchRegistry`]
//! entries; [`PollEngine`] coalesces them into batched `MultiRead` calls on a
//! background task and publishes immutable [`Snapshot`]s via `ArcSwap`.
//! Readers (the Lua API, the HUD) load the latest snapshot lock-free and
//! never block on SNI I/O.

mod engine;
mod snapshot;
mod watch;

pub use engine::{spawn, PollConfig, PollEngine, PollStats};
pub use snapshot::Snapshot;
pub use watch::{coalesce, CoalescedRead, WatchHandle, WatchId, WatchPriority, WatchRegistry};
