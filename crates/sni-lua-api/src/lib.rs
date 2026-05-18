//! LuaJIT scripting host and the unified async-aware API.
//!
//! Surface scripts will target (implemented in M4):
//!
//! ```lua
//! local hp = snes.watch(0x09C2, 2, "high")  -- register a batched watch
//! frame(function()
//!     local cur = snes.u16(hp)               -- read from cached snapshot
//!     gfx.text(8, 8, ("Energy: %d"):format(cur))
//! end)
//! ```
//!
//! `snes.watch` registers a region with the cache engine; `snes.*` accessors
//! read from the latest published snapshot (never blocking); `gfx.*` pushes
//! into the retained draw list. Placeholder until M4.

#![allow(dead_code)]

use mlua::Lua;

/// Owns the Lua VM for one loaded script.
pub struct ScriptHost {
    lua: Lua,
}

impl ScriptHost {
    pub fn new() -> anyhow::Result<Self> {
        // LuaJIT VM. `unsafe_new` is not needed; default is sandbox-friendly.
        Ok(Self { lua: Lua::new() })
    }

    /// Smoke test used by M1 to prove the LuaJIT vendored build links.
    pub fn eval_number(&self, src: &str) -> anyhow::Result<f64> {
        Ok(self.lua.load(src).eval::<f64>()?)
    }
}
