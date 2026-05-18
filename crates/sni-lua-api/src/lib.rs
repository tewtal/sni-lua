//! LuaJIT scripting host and the unified, async-aware overlay API.
//!
//! Design constraints this API encodes:
//!
//! * **Scripts never block on SNI.** There is no synchronous "read memory"
//!   call. Scripts *declare watches* once, then read the latest cached
//!   snapshot every frame. The poll engine (M3) hides FXPAK latency behind
//!   batched `MultiRead`s.
//! * **Drawing is retained, not immediate.** `gfx.*` calls push into a
//!   per-frame [`DrawList`]; the renderer (M5) consumes it. Script frame rate
//!   and screen refresh are decoupled.
//! * **Writes are fire-and-forget.** `snes.write` queues a command on the SNI
//!   actor and returns immediately; it never stalls the frame.
//!
//! ```lua
//! local hp  = snes.watch(0x09C2, 2, "normal")  -- WRAM offset, size, priority
//! local x   = snes.watch(0x0AF6, 2, "high")
//! local y   = snes.watch(0x0AFA, 2, "high")
//!
//! function on_init()
//!   print("script loaded")
//! end
//!
//! function on_frame()
//!   gfx.text(8, 8, ("Energy %d"):format(snes.u16(hp)), 0xFFFFFFFF)
//!   local sx, sy = snes.u16(x), snes.u16(y)
//!   gfx.box(sx-8, sy-16, 16, 32, 0xFF00FF00)   -- crude Samus hitbox
//! end
//! ```

use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;

use mlua::{Lua, MultiValue, Value};
use parking_lot::Mutex;
use sni_cache::{PollEngine, WatchPriority};
use sni_client::MemRegion;
use sni_render::{Color, DrawCmd, DrawList};

/// Script-facing error. `mlua::Error` is not `Send + Sync` when mlua is
/// built without its `send` feature (which we deliberately don't enable, so
/// the host can stay single-threaded). We stringify at the boundary so the
/// app gets a plain, displayable, thread-safe error.
#[derive(Debug, Clone)]
pub struct ScriptError(pub String);

impl std::fmt::Display for ScriptError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}
impl std::error::Error for ScriptError {}

impl From<mlua::Error> for ScriptError {
    fn from(e: mlua::Error) -> Self {
        ScriptError(e.to_string())
    }
}

pub type ScriptResult<T> = std::result::Result<T, ScriptError>;

/// Where script `snes.write(...)` calls go. The app implements this by
/// forwarding to the SNI actor; kept as a trait so the Lua crate doesn't
/// depend on the app. `Send + Sync` because the host is shared.
pub trait WriteSink: Send + Sync {
    fn queue_write(&self, region: MemRegion, data: Vec<u8>);
}

/// A no-op sink (writes silently dropped) — used in tests / before connect.
pub struct NullWriteSink;
impl WriteSink for NullWriteSink {
    fn queue_write(&self, _region: MemRegion, _data: Vec<u8>) {}
}

/// Captured `print()` / error output for the in-app console.
#[derive(Default)]
pub struct Console {
    pub lines: Mutex<Vec<String>>,
}

impl Console {
    pub fn push(&self, s: impl Into<String>) {
        let mut l = self.lines.lock();
        l.push(s.into());
        // Bound the buffer so a chatty script can't grow it forever.
        let len = l.len();
        if len > 500 {
            l.drain(0..len - 500);
        }
    }
    pub fn snapshot(&self) -> Vec<String> {
        self.lines.lock().clone()
    }
}

/// Owns the Lua VM for one loaded script and the bridges into the rest of the
/// app. Lives on the UI thread; `on_frame` is driven from egui's update.
pub struct ScriptHost {
    lua: Lua,
    engine: Arc<PollEngine>,
    write_sink: Arc<dyn WriteSink>,
    console: Arc<Console>,
    /// The frame's draw list. Shared with the renderer; swapped each frame.
    /// `Rc<RefCell>` because all access is single-threaded (UI thread) and we
    /// need it captured into Lua closures.
    draw: Rc<RefCell<DrawList>>,
    /// True once a script has been loaded without error.
    loaded: bool,
}

impl ScriptHost {
    pub fn new(engine: Arc<PollEngine>) -> ScriptResult<Self> {
        Self::with_sink(engine, Arc::new(NullWriteSink))
    }

    pub fn with_sink(
        engine: Arc<PollEngine>,
        write_sink: Arc<dyn WriteSink>,
    ) -> ScriptResult<Self> {
        let lua = Lua::new();
        let host = Self {
            lua,
            engine,
            write_sink,
            console: Arc::new(Console::default()),
            draw: Rc::new(RefCell::new(DrawList::default())),
            loaded: false,
        };
        host.install_api()?;
        Ok(host)
    }

    pub fn console(&self) -> Arc<Console> {
        self.console.clone()
    }

    /// Smoke test retained from M1 (used by the app's LuaJIT health check).
    pub fn eval_number(&self, src: &str) -> ScriptResult<f64> {
        Ok(self.lua.load(src).eval::<f64>()?)
    }

    /// Install the `snes`, `gfx`, and global helpers into the VM.
    fn install_api(&self) -> ScriptResult<()> {
        let globals = self.lua.globals();

        // --- print -> console ---
        {
            let console = self.console.clone();
            let print = self.lua.create_function(move |_, args: MultiValue| {
                let parts: Vec<String> = args
                    .iter()
                    .map(|v| match v {
                        Value::String(s) => s.to_string_lossy().to_string(),
                        other => format!("{other:?}"),
                    })
                    .collect();
                console.push(parts.join("\t"));
                Ok(())
            })?;
            globals.set("print", print)?;
        }

        // --- snes table ---
        let snes = self.lua.create_table()?;

        // snes.watch(offset, size, priority?) -> watch id (WRAM offset form,
        // matching how SM script authors think: 0x0AF6 not 0xF50AF6).
        {
            let engine = self.engine.clone();
            let f = self.lua.create_function(
                move |_, (offset, size, prio): (u32, u32, Option<String>)| {
                    let pr = prio
                        .as_deref()
                        .map(WatchPriority::parse)
                        .unwrap_or(WatchPriority::Normal);
                    let h = engine
                        .registry()
                        .register(MemRegion::wram(offset, size), pr);
                    Ok(h.id)
                },
            )?;
            snes.set("watch", f)?;
        }

        // snes.watch_abs(fxpak_addr, size, priority?) -> watch id, for memory
        // outside WRAM (ROM/SRAM) where the author wants a raw FxPakPro addr.
        {
            let engine = self.engine.clone();
            let f = self.lua.create_function(
                move |_, (addr, size, prio): (u32, u32, Option<String>)| {
                    let pr = prio
                        .as_deref()
                        .map(WatchPriority::parse)
                        .unwrap_or(WatchPriority::Normal);
                    let h = engine
                        .registry()
                        .register(MemRegion::fxpak(addr, size), pr);
                    Ok(h.id)
                },
            )?;
            snes.set("watch_abs", f)?;
        }

        // Typed cached reads. These read the latest published snapshot — a
        // lock-free load, never a round trip. Return nil if the watch hasn't
        // been populated yet (so scripts can guard the first few frames).
        macro_rules! reader {
            ($name:literal, $method:ident, $ty:ty) => {{
                let engine = self.engine.clone();
                let f = self.lua.create_function(move |_, id: u64| {
                    Ok(engine.snapshot().$method(id).map(|v| v as $ty))
                })?;
                snes.set($name, f)?;
            }};
        }
        reader!("u8", u8, i64);
        reader!("u16", u16, i64);
        reader!("u24", u24, i64);
        reader!("u32", u32, i64);
        reader!("i16", i16, i64);

        // snes.bytes(id) -> { b0, b1, ... } or nil
        {
            let engine = self.engine.clone();
            let f = self.lua.create_function(move |lua, id: u64| {
                let snap = engine.snapshot();
                match snap.bytes(id) {
                    Some(b) => {
                        let t = lua.create_table()?;
                        for (i, byte) in b.iter().enumerate() {
                            t.set(i + 1, *byte)?;
                        }
                        Ok(Value::Table(t))
                    }
                    None => Ok(Value::Nil),
                }
            })?;
            snes.set("bytes", f)?;
        }

        // snes.age(id) -> poll cycles since last refresh (nil if never).
        // Lets scripts dim/flag stale data instead of trusting it blindly.
        {
            let engine = self.engine.clone();
            let f = self.lua.create_function(move |_, id: u64| {
                Ok(engine.snapshot().watch_age(id))
            })?;
            snes.set("age", f)?;
        }

        // snes.write(fxpak_addr, value, size?) -> fire-and-forget.
        {
            let sink = self.write_sink.clone();
            let f = self.lua.create_function(
                move |_, (addr, value, size): (u32, i64, Option<u32>)| {
                    let size = size.unwrap_or(1).clamp(1, 4);
                    let v = value as u32;
                    let data: Vec<u8> = (0..size)
                        .map(|i| ((v >> (8 * i)) & 0xFF) as u8) // little-endian
                        .collect();
                    sink.queue_write(MemRegion::fxpak(addr, size), data);
                    Ok(())
                },
            )?;
            snes.set("write", f)?;
        }

        globals.set("snes", snes)?;

        // --- gfx table (pushes into the per-frame draw list) ---
        let gfx = self.lua.create_table()?;

        // gfx.text(x, y, str, color?, scale?)
        {
            let draw = self.draw.clone();
            let f = self.lua.create_function(
                move |_,
                      (x, y, text, color, scale): (
                    f32,
                    f32,
                    String,
                    Option<u32>,
                    Option<f32>,
                )| {
                    draw.borrow_mut().push(DrawCmd::Text {
                        x,
                        y,
                        text,
                        color: argb(color, 0xFFFFFFFF),
                        scale: scale.unwrap_or(1.0),
                    });
                    Ok(())
                },
            )?;
            gfx.set("text", f)?;
        }

        // gfx.box(x, y, w, h, color?, fill?, thickness?) — outline + optional
        // fill. The bread-and-butter hitbox primitive.
        {
            let draw = self.draw.clone();
            let f = self.lua.create_function(
                move |_,
                      (x, y, w, h, color, fill, thickness): (
                    f32,
                    f32,
                    f32,
                    f32,
                    Option<u32>,
                    Option<u32>,
                    Option<f32>,
                )| {
                    draw.borrow_mut().push(DrawCmd::Rect {
                        x,
                        y,
                        w,
                        h,
                        color: argb(color, 0xFF00FF00),
                        fill: fill.map(|c| Color::from_argb(c)),
                        thickness: thickness.unwrap_or(1.0),
                    });
                    Ok(())
                },
            )?;
            gfx.set("box", f)?;
        }

        // gfx.line(x1, y1, x2, y2, color?, thickness?)
        {
            let draw = self.draw.clone();
            let f = self.lua.create_function(
                move |_,
                      (x1, y1, x2, y2, color, thickness): (
                    f32,
                    f32,
                    f32,
                    f32,
                    Option<u32>,
                    Option<f32>,
                )| {
                    draw.borrow_mut().push(DrawCmd::Line {
                        x1,
                        y1,
                        x2,
                        y2,
                        color: argb(color, 0xFFFFFFFF),
                        thickness: thickness.unwrap_or(1.0),
                    });
                    Ok(())
                },
            )?;
            gfx.set("line", f)?;
        }

        // gfx.pixel(x, y, color?)
        {
            let draw = self.draw.clone();
            let f = self.lua.create_function(
                move |_, (x, y, color): (f32, f32, Option<u32>)| {
                    draw.borrow_mut().push(DrawCmd::Pixel {
                        x,
                        y,
                        color: argb(color, 0xFFFFFFFF),
                    });
                    Ok(())
                },
            )?;
            gfx.set("pixel", f)?;
        }

        // gfx.argb(a,r,g,b) -> packed color int helper.
        {
            let f = self.lua.create_function(
                move |_, (a, r, g, b): (u8, u8, u8, u8)| {
                    Ok(((a as u32) << 24)
                        | ((r as u32) << 16)
                        | ((g as u32) << 8)
                        | b as u32)
                },
            )?;
            gfx.set("argb", f)?;
        }

        globals.set("gfx", gfx)?;
        Ok(())
    }

    /// Load (or reload) a script from source. Replaces any previously loaded
    /// chunk's globals-defined callbacks. Runs the chunk once (top level),
    /// then calls `on_init()` if defined.
    pub fn load_script(&mut self, src: &str, name: &str) -> ScriptResult<()> {
        self.loaded = false;
        if let Err(e) = self.lua.load(src).set_name(name).exec() {
            self.console.push(format!("[load error] {e}"));
            return Err(e.into());
        }
        if let Ok(init) = self.lua.globals().get::<mlua::Function>("on_init") {
            if let Err(e) = init.call::<()>(()) {
                self.console.push(format!("[on_init error] {e}"));
                return Err(e.into());
            }
        }
        self.loaded = true;
        self.console.push(format!("[loaded] {name}"));
        Ok(())
    }

    pub fn is_loaded(&self) -> bool {
        self.loaded
    }

    /// Run one frame: clears the draw list, calls the script's `on_frame()`,
    /// and returns the produced commands for the renderer. A script error is
    /// reported to the console and disables the script (returns empty) so a
    /// bad frame doesn't spam or crash the app.
    pub fn run_frame(&mut self) -> DrawList {
        if !self.loaded {
            return DrawList::default();
        }
        self.draw.borrow_mut().clear();

        if let Ok(on_frame) =
            self.lua.globals().get::<mlua::Function>("on_frame")
        {
            if let Err(e) = on_frame.call::<()>(()) {
                self.console.push(format!("[on_frame error] {e}"));
                self.loaded = false; // stop running the broken script
                return DrawList::default();
            }
        }
        // Hand the renderer a clone; keep our buffer for reuse next frame.
        self.draw.borrow().clone()
    }
}

/// Resolve an optional packed ARGB int to a [`Color`], falling back to a
/// default. Centralised so every primitive treats color args the same way.
fn argb(c: Option<u32>, default: u32) -> Color {
    Color::from_argb(c.unwrap_or(default))
}

#[cfg(test)]
mod tests {
    use super::*;

    // The poll engine spawns a Tokio task, so tests need an ambient runtime
    // (the real app runs inside one). Leak a runtime for the test process so
    // the engine task has a reactor for its lifetime.
    fn host() -> ScriptHost {
        use std::sync::OnceLock;
        static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
        let rt = RT.get_or_init(|| {
            tokio::runtime::Runtime::new().expect("test runtime")
        });
        let _g = rt.enter();
        // Engine with no client: snapshots are empty, watches still register.
        let engine = sni_cache::spawn(|| None, sni_cache::PollConfig::default());
        ScriptHost::new(engine).unwrap()
    }

    #[test]
    fn script_can_register_watch_and_draw() {
        let mut h = host();
        h.load_script(
            r#"
            local hp = snes.watch(0x09C2, 2, "high")
            assert(type(hp) == "number")
            function on_frame()
              gfx.text(8, 8, "Energy", 0xFFFFFFFF)
              gfx.box(10, 20, 16, 32, 0xFF00FF00)
            end
            "#,
            "test",
        )
        .unwrap();
        let dl = h.run_frame();
        assert_eq!(dl.cmds.len(), 2, "text + box pushed");
    }

    #[test]
    fn cached_read_is_nil_before_first_poll() {
        let mut h = host();
        h.load_script(
            r#"
            local w = snes.watch(0x0AF6, 2, "high")
            result = snes.u16(w)         -- no poll has run -> nil
            "#,
            "t",
        )
        .unwrap();
        let v: Option<i64> =
            h.lua.globals().get("result").unwrap();
        assert_eq!(v, None);
    }

    #[test]
    fn script_error_disables_frame_not_crashes() {
        let mut h = host();
        h.load_script(
            r#"function on_frame() error("boom") end"#,
            "t",
        )
        .unwrap();
        let dl = h.run_frame();
        assert!(dl.cmds.is_empty());
        assert!(!h.is_loaded(), "broken script disabled");
        assert!(h
            .console()
            .snapshot()
            .iter()
            .any(|l| l.contains("boom")));
    }

    #[test]
    fn print_routes_to_console() {
        let mut h = host();
        h.load_script(r#"print("hello", 42)"#, "t").unwrap();
        assert!(h
            .console()
            .snapshot()
            .iter()
            .any(|l| l.contains("hello")));
    }
}
