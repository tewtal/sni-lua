//! Watch registry, snapshot cache, and async poll engine.
//!
//! Filled out in milestone M3. For now this defines the public shape the Lua
//! API and app will depend on so the workspace builds end-to-end.

#![allow(dead_code)]

mod snapshot;
mod watch;

pub use snapshot::Snapshot;
pub use watch::{WatchHandle, WatchId, WatchRegistry};
