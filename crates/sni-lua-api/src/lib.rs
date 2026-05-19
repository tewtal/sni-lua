//! LuaJIT scripting host and the unified, async-aware overlay API.
//!
//! Design constraints this API encodes:
//!
//! * **Scripts never block on SNI.** There is no synchronous "read memory"
//!   call. Scripts *declare watches* once, then read the latest cached
//!   snapshot every frame. The poll engine hides FXPAK latency behind
//!   batched `MultiRead`s.
//! * **Drawing is retained, not immediate.** `gfx.*` calls push into a
//!   per-frame [`DrawList`]; the renderer consumes it. Script frame rate
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

mod controls;
mod runtime;

use std::cell::{Cell, RefCell};
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::Arc;

use mlua::{Lua, MultiValue, Value};
use parking_lot::Mutex;
use sni_cache::{PollEngine, WatchPriority};
use sni_client::MemRegion;
use sni_render::{Canvas, Color, DrawCmd, DrawList, Font};

pub use controls::{Control, Controls, SharedControls};
pub use runtime::{HttpBridge, Store};

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

/// Script-requested app text sizing. The app applies this once after load as
/// an initial default; users can still adjust the Overlay controls afterwards.
#[derive(Debug, Clone, PartialEq)]
pub struct TextSizingRequest {
    pub mode: String,
    pub size: f32,
}

/// Backs the `time.*` table. `Cell`s because access is single-threaded
/// (UI thread). `frame_start` is updated each `run_frame`; the gap to the
/// previous one is `dt`.
struct TimeState {
    start: std::time::Instant,
    frame: Cell<u64>,
    frame_start: Cell<std::time::Instant>,
    dt: Cell<f64>,
}

impl TimeState {
    fn new() -> Rc<Self> {
        let now = std::time::Instant::now();
        Rc::new(Self {
            start: now,
            frame: Cell::new(0),
            frame_start: Cell::new(now),
            dt: Cell::new(0.0),
        })
    }

    /// Advance one frame: bump the counter and measure the gap since the
    /// previous frame for `time.dt()`.
    fn tick(&self) {
        let now = std::time::Instant::now();
        self.dt
            .set(now.duration_since(self.frame_start.get()).as_secs_f64());
        self.frame_start.set(now);
        self.frame.set(self.frame.get() + 1);
    }
}

/// One frame's raw pointer reading, pushed by the app before `run_frame`.
/// `pos` is in the script's canvas coordinate space, or `None` when the
/// pointer is outside the canvas (or there is no pointer).
#[derive(Clone, Copy, Default)]
pub struct MouseFrame {
    pub pos: Option<(f32, f32)>,
    /// `[left, right, middle]` currently held.
    pub buttons: [bool; 3],
    /// Scroll delta this frame (lines/units, positive = up/away).
    pub wheel: f32,
}

/// Backs the `mouse.*` table. Holds the latest [`MouseFrame`] plus the
/// previous frame's held buttons so press/release edges can be derived.
/// `Cell`/`RefCell` because all access is single-threaded (UI thread).
#[derive(Default)]
struct MouseState {
    cur: RefCell<MouseFrame>,
    prev_buttons: Cell<[bool; 3]>,
}

impl MouseState {
    fn new() -> Rc<Self> {
        Rc::new(Self::default())
    }

    /// Take the app's reading for this frame. Called once just before
    /// `on_frame`; edge queries compare against the buttons stored here.
    fn feed(&self, f: MouseFrame) {
        self.prev_buttons.set(self.cur.borrow().buttons);
        *self.cur.borrow_mut() = f;
    }

    fn pressed(&self, btn: usize) -> bool {
        btn < 3 && self.cur.borrow().buttons[btn] && !self.prev_buttons.get()[btn]
    }

    fn released(&self, btn: usize) -> bool {
        btn < 3 && !self.cur.borrow().buttons[btn] && self.prev_buttons.get()[btn]
    }
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
    /// Active typeface for subsequent `gfx.text` calls. Set by `gfx.font`;
    /// reset to the default at the start of each frame so a script can't
    /// leave it in a surprising state. `Cell` since access is single-threaded.
    current_font: Rc<Cell<Font>>,
    /// Canvas the script has requested via `gfx.canvas`/`gfx.scale`. The app
    /// reads this each frame to build the viewport (and may override it with
    /// a user setting). Shared so `gfx.width()`/`height()` and the app agree.
    requested_canvas: Rc<Cell<Canvas>>,
    /// Optional text sizing default requested by the script at load time.
    /// The app reads this after `load_script` and seeds its Overlay controls.
    requested_text_sizing: Rc<RefCell<Option<TextSizingRequest>>>,
    /// `gfx.push_origin`/`pop_origin` translate stack. Coords are absolute
    /// SNES space, so a translate is just an offset added at emit time —
    /// resolved here, the renderer stays origin-agnostic. The current origin
    /// is the last entry (0,0 when empty). Reset at the top of every frame.
    origin_stack: Rc<RefCell<Vec<(f32, f32)>>>,
    /// Frame timing for the `time.*` table. `start` is script-load instant;
    /// `frame` increments per `run_frame`; `last_frame` feeds `time.dt()`.
    time: Rc<TimeState>,
    /// Pointer state behind `mouse.*`. The app feeds one [`MouseFrame`] per
    /// frame (canvas-space coords) before `run_frame`; the script reads it.
    mouse: Rc<MouseState>,
    /// Controls the script declared via `ui.*`. The app renders these and
    /// writes user edits back into the same values the script reads with
    /// `ui.get`. `Rc<RefCell>` — single-threaded, captured into Lua closures.
    controls: SharedControls,
    /// Persistent per-script document behind `store.*`.
    store: Arc<Store>,
    /// Async HTTP worker behind `http.*`. `None` when constructed outside a
    /// Tokio runtime (tests) — `http.*` calls then no-op with a console note.
    http: Option<Arc<HttpBridge>>,
    /// True once a script has been loaded without error.
    loaded: bool,
}

impl ScriptHost {
    /// Host without HTTP. Used by tests and any caller not inside a Tokio
    /// runtime; `http.*` calls degrade to a console warning.
    pub fn new(engine: Arc<PollEngine>) -> ScriptResult<Self> {
        Self::build(engine, Arc::new(NullWriteSink), None)
    }

    /// Full host as the app uses it: a write sink for `snes.write` and an
    /// HTTP worker on the current Tokio runtime for `http.*`. Call inside
    /// `rt.enter()`.
    pub fn with_sink(
        engine: Arc<PollEngine>,
        write_sink: Arc<dyn WriteSink>,
    ) -> ScriptResult<Self> {
        let http = Some(HttpBridge::spawn());
        Self::build(engine, write_sink, http)
    }

    fn build(
        engine: Arc<PollEngine>,
        write_sink: Arc<dyn WriteSink>,
        http: Option<Arc<HttpBridge>>,
    ) -> ScriptResult<Self> {
        let lua = Lua::new();
        let host = Self {
            lua,
            engine,
            write_sink,
            console: Arc::new(Console::default()),
            draw: Rc::new(RefCell::new(DrawList::default())),
            current_font: Rc::new(Cell::new(Font::default())),
            requested_canvas: Rc::new(Cell::new(Canvas::default())),
            requested_text_sizing: Rc::new(RefCell::new(None)),
            origin_stack: Rc::new(RefCell::new(Vec::new())),
            time: TimeState::new(),
            mouse: MouseState::new(),
            controls: Controls::shared(),
            store: Store::new(),
            http,
            loaded: false,
        };
        host.install_api()?;
        Ok(host)
    }

    /// The persistent store, so the app can flush it each frame / on exit.
    pub fn store(&self) -> Arc<Store> {
        self.store.clone()
    }

    /// Push this frame's pointer reading. The app calls this once per frame
    /// just before [`Self::run_frame`], with the position already mapped into
    /// the script's canvas coordinate space (`None` = pointer off-canvas).
    pub fn feed_mouse(&self, frame: MouseFrame) {
        self.mouse.feed(frame);
    }

    /// Point the store at this script's save file and load it. The app calls
    /// this right before `load_script` (it owns the path; the host only sees
    /// source + name). Pass `None` to disable persistence.
    pub fn bind_store(&self, path: Option<PathBuf>) {
        match path {
            Some(p) => self.store.bind(p),
            None => self.store.unbind(),
        }
    }

    pub fn console(&self) -> Arc<Console> {
        self.console.clone()
    }

    /// Evaluate a Lua expression to a number. Used by the app's startup
    /// LuaJIT health check.
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
                    let h = engine.registry().register(MemRegion::fxpak(addr, size), pr);
                    Ok(h.id)
                },
            )?;
            snes.set("watch_abs", f)?;
        }

        // Typed cached reads. These read the latest published snapshot — a
        // lock-free load, never a round trip. Return nil if the watch hasn't
        // been populated yet (so scripts can guard the first few frames).
        // Each value read is also the script's *demand signal*: touching the
        // watch resets its demand-eviction timer so the engine keeps polling
        // it. Watches the script stops reading go dormant (cached, not
        // refreshed) — that's what stops the polled set growing forever.
        macro_rules! reader {
            ($name:literal, $method:ident, $ty:ty) => {{
                let engine = self.engine.clone();
                let f = self.lua.create_function(move |_, id: u64| {
                    engine.registry().touch(id);
                    Ok(engine.snapshot().$method(id).map(|v| v as $ty))
                })?;
                snes.set($name, f)?;
            }};
        }
        reader!("u8", u8, i64);
        reader!("u16", u16, i64);
        reader!("u24", u24, i64);
        reader!("u32", u32, i64);
        reader!("i8", i8, i64);
        reader!("i16", i16, i64);
        reader!("i32", i32, i64);

        // snes.buttons(watch_id) -> decoded SNES controller table, or nil
        // until the watch has data. The script registers a 2-byte watch on
        // whatever address holds the joypad state for its game (e.g. the SM
        // mirror $7E:008B) and tiers it "realtime"; this just decodes the
        // standard 16-bit SNES pad layout into named fields:
        //
        //   bit 15..8 : B Y Select Start Up Down Left Right
        //   bit  7..4 : A X L R
        //
        // Returns booleans plus `.raw` (the u16) so a script can also do
        // edge detection itself (compare against last frame's `.raw`).
        {
            let engine = self.engine.clone();
            let f = self.lua.create_function(move |lua, id: u64| {
                engine.registry().touch(id);
                let Some(v) = engine.snapshot().u16(id) else {
                    return Ok(Value::Nil);
                };
                let t = lua.create_table()?;
                let bit = |b: u32| (v & (1 << b)) != 0;
                t.set("B", bit(15))?;
                t.set("Y", bit(14))?;
                t.set("Select", bit(13))?;
                t.set("Start", bit(12))?;
                t.set("Up", bit(11))?;
                t.set("Down", bit(10))?;
                t.set("Left", bit(9))?;
                t.set("Right", bit(8))?;
                t.set("A", bit(7))?;
                t.set("X", bit(6))?;
                t.set("L", bit(5))?;
                t.set("R", bit(4))?;
                t.set("raw", v)?;
                Ok(Value::Table(t))
            })?;
            snes.set("buttons", f)?;
        }

        // snes.bytes(id) -> { b0, b1, ... } or nil
        {
            let engine = self.engine.clone();
            let f = self.lua.create_function(move |lua, id: u64| {
                engine.registry().touch(id);
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
                // Checking staleness implies interest -> keep it active.
                engine.registry().touch(id);
                Ok(engine.snapshot().watch_age(id))
            })?;
            snes.set("age", f)?;
        }

        // snes.tier(watch_id, "realtime"|"high"|"normal"|"low") -> upgrade a
        // watch's priority. Only ever *raises* urgency (never downgrades), so
        // an explicit hint wins over later auto-classification. "realtime"
        // moves the watch into the dedicated fast sub-poll (controller path).
        {
            let engine = self.engine.clone();
            let f = self
                .lua
                .create_function(move |_, (id, class): (u64, String)| {
                    engine
                        .registry()
                        .upgrade_priority(id, WatchPriority::parse(&class));
                    Ok(())
                })?;
            snes.set("tier", f)?;
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

        // Current translate from the push_origin stack (0,0 if empty). Every
        // primitive offsets its coords by this, so a script can draw a whole
        // group in local coords and place it once.
        let origin = self.origin_stack.clone();
        let offset =
            move || -> (f32, f32) { origin.borrow().last().copied().unwrap_or((0.0, 0.0)) };

        // gfx.text(x, y, str, color?, opts?)
        //
        // `opts` is either a number (the per-label scale — the original
        // signature, kept working) or a table:
        //   { scale = n, bg = 0xAARRGGBB, outline = 0xAARRGGBB }
        // `bg` draws a solid backing rect (auto-sized, 1px pad); `outline`
        // draws a 1px halo around every glyph (replaces the manual shadow
        // double-draw scripts used to do).
        {
            let draw = self.draw.clone();
            let cur_font = self.current_font.clone();
            let off = offset.clone();
            let f =
                self.lua.create_function(
                    move |_,
                          (x, y, text, color, opts): (
                        f32,
                        f32,
                        String,
                        Option<u32>,
                        Option<Value>,
                    )| {
                        let (mut scale, mut bg, mut outline) = (1.0, None, None);
                        match opts {
                            Some(Value::Number(n)) => scale = n as f32,
                            Some(Value::Integer(n)) => scale = n as f32,
                            Some(Value::Table(t)) => {
                                if let Ok(s) = t.get::<f32>("scale") {
                                    if s > 0.0 {
                                        scale = s;
                                    }
                                }
                                if let Ok(c) = t.get::<u32>("bg") {
                                    bg = Some(Color::from_argb(c));
                                }
                                if let Ok(c) = t.get::<u32>("outline") {
                                    outline = Some(Color::from_argb(c));
                                }
                            }
                            _ => {}
                        }
                        let (ox, oy) = off();
                        draw.borrow_mut().push(DrawCmd::Text {
                            x: x + ox,
                            y: y + oy,
                            text,
                            color: argb(color, 0xFFFFFFFF),
                            scale,
                            font: cur_font.get(),
                            bg,
                            outline,
                        });
                        Ok(())
                    },
                )?;
            gfx.set("text", f)?;
        }

        // gfx.text_width(str) / gfx.text_height() — pixel size of a string in
        // the *current* font's coordinate space (before viewport scaling), so
        // scripts can centre/right-align without hardcoding glyph widths.
        // Multi-line aware: width = widest line, height = line count * advance.
        {
            let cur_font = self.current_font.clone();
            let f = self.lua.create_function(move |_, s: String| {
                let fnt = cur_font.get();
                let adv = fnt.advance() as f32;
                let widest = s
                    .split('\n')
                    .map(|line| line.chars().count())
                    .max()
                    .unwrap_or(0) as f32;
                Ok(widest * adv)
            })?;
            gfx.set("text_width", f)?;
        }
        {
            let cur_font = self.current_font.clone();
            let f = self.lua.create_function(move |_, s: Option<String>| {
                let fnt = cur_font.get();
                let lines = s
                    .as_deref()
                    .map(|t| t.split('\n').count())
                    .unwrap_or(1)
                    .max(1) as f32;
                Ok(lines * fnt.line_advance() as f32)
            })?;
            gfx.set("text_height", f)?;
        }

        // gfx.push_origin(x, y) / gfx.pop_origin() — translate stack. Nested
        // pushes accumulate (child origin is parent + local). The stack is
        // cleared at the top of every frame so a missing pop can't leak.
        {
            let origin = self.origin_stack.clone();
            let f = self.lua.create_function(move |_, (x, y): (f32, f32)| {
                let mut st = origin.borrow_mut();
                let (px, py) = st.last().copied().unwrap_or((0.0, 0.0));
                st.push((px + x, py + y));
                Ok(())
            })?;
            gfx.set("push_origin", f)?;
        }
        {
            let origin = self.origin_stack.clone();
            let f = self.lua.create_function(move |_, ()| {
                origin.borrow_mut().pop();
                Ok(())
            })?;
            gfx.set("pop_origin", f)?;
        }

        // gfx.font("small"|"normal") — selects the typeface for subsequent
        // gfx.text calls this frame. "small" (5x7) is the default and is
        // noticeably more compact than "normal" (8x8).
        {
            let cur_font = self.current_font.clone();
            let f = self.lua.create_function(move |_, name: String| {
                cur_font.set(Font::parse(&name));
                Ok(())
            })?;
            gfx.set("font", f)?;
        }

        // gfx.text_sizing("game"|"screen", size) — request the app's
        // Overlay text defaults when this script loads. This is intentionally
        // separate from per-label `scale`: scripts use this for a sane initial
        // global fit, and users may still adjust the app controls afterwards.
        {
            let requested = self.requested_text_sizing.clone();
            let f = self
                .lua
                .create_function(move |_, (mode, size): (String, f32)| {
                    if !size.is_finite() || size <= 0.0 {
                        return Err(mlua::Error::external(
                            "gfx.text_sizing size must be a positive number",
                        ));
                    }
                    let mode = match mode.as_str() {
                        "game" | "game_scaled" | "game-scaled" | "scaled" => "game",
                        "screen" | "fixed" | "fixed_screen" | "fixed-screen" => "screen",
                        _ => {
                            return Err(mlua::Error::external(
                                "gfx.text_sizing mode must be \"game\" or \"screen\"",
                            ))
                        }
                    };
                    *requested.borrow_mut() = Some(TextSizingRequest {
                        mode: mode.to_string(),
                        size: size.clamp(0.1, 8.0),
                    });
                    Ok(())
                })?;
            gfx.set("text_sizing", f)?;
        }

        // gfx.canvas(w, h) — request a custom coordinate space. The app may
        // override (user setting); gfx.width()/height() always report the
        // effective canvas so positioning code stays correct either way.
        {
            let canvas = self.requested_canvas.clone();
            let f = self.lua.create_function(move |_, (w, h): (f32, f32)| {
                canvas.set(Canvas::custom(w, h));
                Ok(())
            })?;
            gfx.set("canvas", f)?;
        }

        // gfx.scale(n) — request an integer multiple of native 256x224
        // (e.g. 2 -> 512x448) for higher-res overlays.
        {
            let canvas = self.requested_canvas.clone();
            let f = self.lua.create_function(move |_, n: u32| {
                canvas.set(Canvas::scaled(n));
                Ok(())
            })?;
            gfx.set("scale", f)?;
        }

        // gfx.width() / gfx.height() — the ACTIVE canvas size. Always read
        // these for layout; never assume 256x224.
        {
            let canvas = self.requested_canvas.clone();
            let f = self.lua.create_function(move |_, ()| Ok(canvas.get().w))?;
            gfx.set("width", f)?;
        }
        {
            let canvas = self.requested_canvas.clone();
            let f = self.lua.create_function(move |_, ()| Ok(canvas.get().h))?;
            gfx.set("height", f)?;
        }

        // gfx.box(x, y, w, h, color?, fill?, thickness?) — outline + optional
        // fill. The bread-and-butter hitbox primitive.
        {
            let draw = self.draw.clone();
            let off = offset.clone();
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
                    let (ox, oy) = off();
                    draw.borrow_mut().push(DrawCmd::Rect {
                        x: x + ox,
                        y: y + oy,
                        w,
                        h,
                        color: argb(color, 0xFF00FF00),
                        fill: fill.map(Color::from_argb),
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
            let off = offset.clone();
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
                    let (ox, oy) = off();
                    draw.borrow_mut().push(DrawCmd::Line {
                        x1: x1 + ox,
                        y1: y1 + oy,
                        x2: x2 + ox,
                        y2: y2 + oy,
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
            let off = offset.clone();
            let f =
                self.lua
                    .create_function(move |_, (x, y, color): (f32, f32, Option<u32>)| {
                        let (ox, oy) = off();
                        draw.borrow_mut().push(DrawCmd::Pixel {
                            x: x + ox,
                            y: y + oy,
                            color: argb(color, 0xFFFFFFFF),
                        });
                        Ok(())
                    })?;
            gfx.set("pixel", f)?;
        }

        // gfx.circle(x, y, radius, color?, fill?, thickness?) — (x,y) is the
        // centre. Handy for radii / range indicators.
        {
            let draw = self.draw.clone();
            let off = offset.clone();
            let f = self.lua.create_function(
                move |_,
                      (x, y, radius, color, fill, thickness): (
                    f32,
                    f32,
                    f32,
                    Option<u32>,
                    Option<u32>,
                    Option<f32>,
                )| {
                    let (ox, oy) = off();
                    draw.borrow_mut().push(DrawCmd::Circle {
                        x: x + ox,
                        y: y + oy,
                        radius,
                        color: argb(color, 0xFF00FF00),
                        fill: fill.map(Color::from_argb),
                        thickness: thickness.unwrap_or(1.0),
                    });
                    Ok(())
                },
            )?;
            gfx.set("circle", f)?;
        }

        // gfx.triangle(x1,y1, x2,y2, x3,y3, color?, fill?, thickness?) —
        // arrows / directional markers.
        {
            let draw = self.draw.clone();
            let off = offset.clone();
            let f = self.lua.create_function(
                move |_, (x1, y1, x2, y2, x3, y3, color, fill, thickness): TriArgs| {
                    let (ox, oy) = off();
                    draw.borrow_mut().push(DrawCmd::Triangle {
                        x1: x1 + ox,
                        y1: y1 + oy,
                        x2: x2 + ox,
                        y2: y2 + oy,
                        x3: x3 + ox,
                        y3: y3 + oy,
                        color: argb(color, 0xFF00FF00),
                        fill: fill.map(Color::from_argb),
                        thickness: thickness.unwrap_or(1.0),
                    });
                    Ok(())
                },
            )?;
            gfx.set("triangle", f)?;
        }

        // gfx.poly(points, color?, fill?, thickness?, closed?)
        //   points = { {x,y}, {x,y}, ... } (table of 2-tuples / {x,y} pairs)
        // `closed` (default true) joins last->first; `fill` (convex) needs
        // closed. Open polyline: closed=false, no fill.
        {
            let draw = self.draw.clone();
            let off = offset.clone();
            let f = self.lua.create_function(
                move |_,
                      (points, color, fill, thickness, closed): (
                    mlua::Table,
                    Option<u32>,
                    Option<u32>,
                    Option<f32>,
                    Option<bool>,
                )| {
                    let (ox, oy) = off();
                    let mut pts = Vec::new();
                    for pair in points.sequence_values::<mlua::Table>() {
                        let p = pair?;
                        // Accept {x=,y=} or {[1]=x,[2]=y}.
                        let px: f32 = p.get("x").or_else(|_| p.get(1))?;
                        let py: f32 = p.get("y").or_else(|_| p.get(2))?;
                        pts.push((px + ox, py + oy));
                    }
                    draw.borrow_mut().push(DrawCmd::Poly {
                        points: pts,
                        closed: closed.unwrap_or(true),
                        color: argb(color, 0xFF00FF00),
                        fill: fill.map(Color::from_argb),
                        thickness: thickness.unwrap_or(1.0),
                    });
                    Ok(())
                },
            )?;
            gfx.set("poly", f)?;
        }

        // gfx.arc(x, y, radius, start_deg, end_deg, color?, fill?, thickness?)
        // Clockwise, 0° = east. Full sweep (start=0,end=360) is a ring;
        // `fill` makes it a pie slice from the centre.
        {
            let draw = self.draw.clone();
            let off = offset.clone();
            let f = self.lua.create_function(
                move |_, (x, y, radius, start_deg, end_deg, color, fill, thickness): ArcArgs| {
                    let (ox, oy) = off();
                    draw.borrow_mut().push(DrawCmd::Arc {
                        x: x + ox,
                        y: y + oy,
                        radius,
                        start_deg,
                        end_deg,
                        color: argb(color, 0xFF00FF00),
                        fill: fill.map(Color::from_argb),
                        thickness: thickness.unwrap_or(1.0),
                    });
                    Ok(())
                },
            )?;
            gfx.set("arc", f)?;
        }

        // gfx.color_lerp(a, b, t) -> packed 0xAARRGGBB blended a..b by
        // t (clamped 0..1), per channel including alpha. For health bars
        // fading green->red, staleness dimming, etc. In Rust because the
        // ARGB packing is the renderer's convention and LuaJIT's signed
        // 32-bit bitops make this error-prone in script.
        {
            let f = self
                .lua
                .create_function(move |_, (a, b, t): (u32, u32, f32)| {
                    let t = t.clamp(0.0, 1.0);
                    let lerp = |shift: u32| -> u32 {
                        let ca = ((a >> shift) & 0xFF) as f32;
                        let cb = ((b >> shift) & 0xFF) as f32;
                        let v = (ca + (cb - ca) * t).round().clamp(0.0, 255.0) as u32;
                        v << shift
                    };
                    Ok(lerp(24) | lerp(16) | lerp(8) | lerp(0))
                })?;
            gfx.set("color_lerp", f)?;
        }

        // gfx.argb(a,r,g,b) -> packed color int helper.
        {
            let f = self
                .lua
                .create_function(move |_, (a, r, g, b): (u8, u8, u8, u8)| {
                    Ok(((a as u32) << 24) | ((r as u32) << 16) | ((g as u32) << 8) | b as u32)
                })?;
            gfx.set("argb", f)?;
        }

        globals.set("gfx", gfx)?;

        // --- time table (monotonic; no wall clock — sandbox stays tight) ---
        let time_tbl = self.lua.create_table()?;
        {
            let time = self.time.clone();
            // Seconds since the script loaded (float, monotonic).
            let f = self
                .lua
                .create_function(move |_, ()| Ok(time.start.elapsed().as_secs_f64()))?;
            time_tbl.set("now", f)?;
        }
        {
            let time = self.time.clone();
            // Overlay frames since load (increments once per on_frame).
            let f = self
                .lua
                .create_function(move |_, ()| Ok(time.frame.get()))?;
            time_tbl.set("frame", f)?;
        }
        {
            let time = self.time.clone();
            // Wall seconds between the last two frames — for velocity /
            // frame-rate-independent animation.
            let f = self.lua.create_function(move |_, ()| Ok(time.dt.get()))?;
            time_tbl.set("dt", f)?;
        }
        globals.set("time", time_tbl)?;

        // --- mouse.* (pointer over the canvas, in canvas coordinates) ------
        // Position is `nil` when the pointer is outside the script's canvas
        // (or there's no pointer). Buttons: "left" (default), "right",
        // "middle". `pressed`/`released` are one-frame edges.
        let mouse_tbl = self.lua.create_table()?;
        // "left"|"right"|"middle" -> 0..2, default left, anything else left.
        fn btn_index(name: Option<String>) -> usize {
            match name.as_deref() {
                Some("right") => 1,
                Some("middle") => 2,
                _ => 0,
            }
        }
        {
            let mouse = self.mouse.clone();
            // mouse.pos() -> x, y  (two nils when off-canvas)
            let f = self.lua.create_function(move |_, ()| {
                Ok(match mouse.cur.borrow().pos {
                    Some((x, y)) => (Some(x), Some(y)),
                    None => (None, None),
                })
            })?;
            mouse_tbl.set("pos", f)?;
        }
        {
            let mouse = self.mouse.clone();
            let f = self
                .lua
                .create_function(move |_, ()| Ok(mouse.cur.borrow().pos.map(|p| p.0)))?;
            mouse_tbl.set("x", f)?;
        }
        {
            let mouse = self.mouse.clone();
            let f = self
                .lua
                .create_function(move |_, ()| Ok(mouse.cur.borrow().pos.map(|p| p.1)))?;
            mouse_tbl.set("y", f)?;
        }
        {
            let mouse = self.mouse.clone();
            // mouse.over() -> true while the pointer is on the canvas.
            let f = self
                .lua
                .create_function(move |_, ()| Ok(mouse.cur.borrow().pos.is_some()))?;
            mouse_tbl.set("over", f)?;
        }
        {
            let mouse = self.mouse.clone();
            let f = self.lua.create_function(move |_, b: Option<String>| {
                Ok(mouse.cur.borrow().buttons[btn_index(b)])
            })?;
            mouse_tbl.set("down", f)?;
        }
        {
            let mouse = self.mouse.clone();
            let f = self
                .lua
                .create_function(move |_, b: Option<String>| Ok(mouse.pressed(btn_index(b))))?;
            mouse_tbl.set("pressed", f)?;
        }
        {
            let mouse = self.mouse.clone();
            let f = self
                .lua
                .create_function(move |_, b: Option<String>| Ok(mouse.released(btn_index(b))))?;
            mouse_tbl.set("released", f)?;
        }
        {
            let mouse = self.mouse.clone();
            let f = self
                .lua
                .create_function(move |_, ()| Ok(mouse.cur.borrow().wheel))?;
            mouse_tbl.set("wheel", f)?;
        }
        globals.set("mouse", mouse_tbl)?;

        // --- anim.* (pure Lua; tweening + time-driven oscillators) ---------
        // Small stdlib-style helpers so scripts stop hand-rolling
        // math.sin(time.now()*k). Pure Lua: trivial, safe, easy to extend.
        // `t` is a 0..1 progress for lerp/ease; pulse/blink read time.now().
        self.lua
            .load(
                r#"
                anim = {}
                local function clamp01(t)
                  if t < 0 then return 0 elseif t > 1 then return 1 end
                  return t
                end
                function anim.clamp(v, lo, hi)
                  if v < lo then return lo elseif v > hi then return hi end
                  return v
                end
                function anim.lerp(a, b, t) return a + (b - a) * clamp01(t) end
                -- Common easings; name -> shaped t (0..1).
                local E = {
                  linear    = function(t) return t end,
                  in_quad   = function(t) return t * t end,
                  out_quad  = function(t) return 1 - (1 - t) * (1 - t) end,
                  inout_quad= function(t)
                                if t < 0.5 then return 2*t*t end
                                return 1 - ((-2*t + 2)^2) / 2
                              end,
                  in_cubic  = function(t) return t * t * t end,
                  out_cubic = function(t) return 1 - (1 - t)^3 end,
                  smooth    = function(t) return t * t * (3 - 2 * t) end,
                }
                function anim.ease(t, name)
                  return (E[name] or E.linear)(clamp01(t))
                end
                -- 0..1 sine, `hz` cycles/sec (default 1). phase optional.
                function anim.pulse(hz, phase)
                  hz = hz or 1
                  return 0.5 + 0.5 * math.sin(
                    (time.now() * hz + (phase or 0)) * 2 * math.pi)
                end
                -- Square wave: true for the first half of each `period` sec.
                function anim.blink(period)
                  period = period or 1
                  return (time.now() % period) < (period / 2)
                end
                -- Sawtooth 0..1 over `period` sec (handy for sweeps).
                function anim.saw(period)
                  period = period or 1
                  return (time.now() % period) / period
                end
                "#,
            )
            .set_name("=[anim prelude]")
            .exec()?;

        // --- log table (levelled console output; print() == log.info) ------
        let log_tbl = self.lua.create_table()?;
        {
            let fmt = |args: &MultiValue| -> String {
                args.iter()
                    .map(|v| match v {
                        Value::String(s) => s.to_string_lossy().to_string(),
                        other => format!("{other:?}"),
                    })
                    .collect::<Vec<_>>()
                    .join("\t")
            };
            for (name, prefix) in [("info", ""), ("warn", "[warn] "), ("error", "[error] ")] {
                let console = self.console.clone();
                // `fmt` captures nothing, so it's Copy — the move closure
                // takes its own copy; no per-iteration rebind needed.
                let f = self.lua.create_function(move |_, args: MultiValue| {
                    console.push(format!("{prefix}{}", fmt(&args)));
                    Ok(())
                })?;
                log_tbl.set(name, f)?;
            }
        }
        globals.set("log", log_tbl)?;

        // --- store table (persistent per-script JSON) ---
        let store_tbl = self.lua.create_table()?;

        // store.get(key) -> value | nil
        {
            let store = self.store.clone();
            let f = self
                .lua
                .create_function(move |lua, key: String| match store.get(&key) {
                    Some(j) => json_to_lua(lua, &j),
                    None => Ok(Value::Nil),
                })?;
            store_tbl.set("get", f)?;
        }
        // store.set(key, value) — value must be JSON-able (nil/bool/number/
        // string/table). Setting nil removes the key.
        {
            let store = self.store.clone();
            let f = self
                .lua
                .create_function(move |_, (key, value): (String, Value)| {
                    if let Value::Nil = value {
                        store.remove(&key);
                    } else {
                        store.set(key, lua_to_json(&value)?);
                    }
                    Ok(())
                })?;
            store_tbl.set("set", f)?;
        }
        // store.delete(key)
        {
            let store = self.store.clone();
            let f = self.lua.create_function(move |_, key: String| {
                store.remove(&key);
                Ok(())
            })?;
            store_tbl.set("delete", f)?;
        }
        // store.load() -> table  (the whole document)
        {
            let store = self.store.clone();
            let f = self.lua.create_function(move |lua, ()| {
                json_to_lua(lua, &serde_json::Value::Object(store.snapshot()))
            })?;
            store_tbl.set("load", f)?;
        }
        // store.save(table) — replace the whole document.
        {
            let store = self.store.clone();
            let f = self
                .lua
                .create_function(move |_, t: Value| match lua_to_json(&t)? {
                    serde_json::Value::Object(m) => {
                        store.replace(m);
                        Ok(())
                    }
                    _ => Err(mlua::Error::RuntimeError(
                        "store.save expects a table".into(),
                    )),
                })?;
            store_tbl.set("save", f)?;
        }
        globals.set("store", store_tbl)?;

        // --- ui table (script-declared settings panel) ---
        //
        // Controls are declared once (typically in on_init); the app renders
        // them and writes edits back into these same Control values. Each
        // control's value is seeded from the persisted store so settings
        // survive reloads with zero extra script code.
        let ui_tbl = self.lua.create_table()?;

        // Look up a previously-persisted value for `id` (returns the JSON the
        // store holds under __ui_controls.<id>, if any).
        let store_for_seed = self.store.clone();
        let seed = move |id: &str| -> Option<serde_json::Value> {
            match store_for_seed.get(controls::STORE_KEY) {
                Some(serde_json::Value::Object(m)) => m.get(id).cloned(),
                _ => None,
            }
        };

        // ui.header(text) / ui.label(text) — layout-only.
        {
            let controls = self.controls.clone();
            let f = self.lua.create_function(move |_, text: String| {
                controls.borrow_mut().items.push(Control::Header { text });
                Ok(())
            })?;
            ui_tbl.set("header", f)?;
        }
        {
            let controls = self.controls.clone();
            let f = self.lua.create_function(move |_, text: String| {
                controls.borrow_mut().items.push(Control::Label { text });
                Ok(())
            })?;
            ui_tbl.set("label", f)?;
        }

        // ui.checkbox(id, label, default)
        {
            let controls = self.controls.clone();
            let seed = seed.clone();
            let f = self.lua.create_function(
                move |_, (id, label, default): (String, String, Option<bool>)| {
                    let value = seed(&id)
                        .and_then(|j| j.as_bool())
                        .unwrap_or(default.unwrap_or(false));
                    controls
                        .borrow_mut()
                        .items
                        .push(Control::Checkbox { id, label, value });
                    Ok(())
                },
            )?;
            ui_tbl.set("checkbox", f)?;
        }

        // ui.slider(id, label, min, max, default)
        {
            let controls = self.controls.clone();
            let seed = seed.clone();
            let f =
                self.lua.create_function(
                    move |_,
                          (id, label, min, max, default): (
                        String,
                        String,
                        f64,
                        f64,
                        Option<f64>,
                    )| {
                        let value = seed(&id)
                            .and_then(|j| j.as_f64())
                            .unwrap_or(default.unwrap_or(min))
                            .clamp(min.min(max), min.max(max));
                        controls.borrow_mut().items.push(Control::Slider {
                            id,
                            label,
                            min,
                            max,
                            value,
                        });
                        Ok(())
                    },
                )?;
            ui_tbl.set("slider", f)?;
        }

        // ui.text(id, label, default)
        {
            let controls = self.controls.clone();
            let seed = seed.clone();
            let f = self.lua.create_function(
                move |_, (id, label, default): (String, String, Option<String>)| {
                    let value = seed(&id)
                        .and_then(|j| j.as_str().map(str::to_owned))
                        .unwrap_or_else(|| default.unwrap_or_default());
                    controls
                        .borrow_mut()
                        .items
                        .push(Control::Text { id, label, value });
                    Ok(())
                },
            )?;
            ui_tbl.set("text", f)?;
        }

        // ui.color(id, label, default)  — default is 0xAARRGGBB
        {
            let controls = self.controls.clone();
            let seed = seed.clone();
            let f = self.lua.create_function(
                move |_, (id, label, default): (String, String, Option<u32>)| {
                    let value = seed(&id)
                        .and_then(|j| j.as_u64())
                        .map(|v| v as u32)
                        .unwrap_or(default.unwrap_or(0xFFFFFFFF));
                    controls
                        .borrow_mut()
                        .items
                        .push(Control::Color { id, label, value });
                    Ok(())
                },
            )?;
            ui_tbl.set("color", f)?;
        }

        // ui.select(id, label, {options...}, default_index)  — 1-based index
        // in/out to match Lua convention; stored 0-based internally.
        {
            let controls = self.controls.clone();
            let seed = seed.clone();
            let f = self.lua.create_function(
                move |_,
                      (id, label, options, default): (
                    String,
                    String,
                    Vec<String>,
                    Option<usize>,
                )| {
                    let n = options.len().max(1);
                    let value = seed(&id)
                        .and_then(|j| j.as_u64())
                        .map(|v| v as usize)
                        .unwrap_or_else(|| default.unwrap_or(1).saturating_sub(1))
                        .min(n - 1);
                    controls.borrow_mut().items.push(Control::Select {
                        id,
                        label,
                        options,
                        value,
                    });
                    Ok(())
                },
            )?;
            ui_tbl.set("select", f)?;
        }

        // ui.button(id, label)
        {
            let controls = self.controls.clone();
            let f = self
                .lua
                .create_function(move |_, (id, label): (String, String)| {
                    controls.borrow_mut().items.push(Control::Button {
                        id,
                        label,
                        pressed: false,
                    });
                    Ok(())
                })?;
            ui_tbl.set("button", f)?;
        }

        // ui.get(id) -> current value (bool/number/string per control type;
        // select returns its 1-based index; nil if no such control).
        {
            let controls = self.controls.clone();
            let f = self.lua.create_function(move |lua, id: String| {
                let c = controls.borrow();
                Ok(match c.get(&id) {
                    Some(Control::Checkbox { value, .. }) => Value::Boolean(*value),
                    Some(Control::Slider { value, .. }) => Value::Number(*value),
                    Some(Control::Text { value, .. }) => Value::String(lua.create_string(value)?),
                    Some(Control::Color { value, .. }) => Value::Integer(*value as i64),
                    Some(Control::Select { value, .. }) => Value::Integer(*value as i64 + 1),
                    _ => Value::Nil,
                })
            })?;
            ui_tbl.set("get", f)?;
        }

        // ui.pressed(id) -> true once per click (drains the latch).
        {
            let controls = self.controls.clone();
            let f = self.lua.create_function(move |_, id: String| {
                let mut c = controls.borrow_mut();
                if let Some(Control::Button { pressed, .. }) =
                    c.items.iter_mut().find(|c| c.id() == Some(&id))
                {
                    let was = *pressed;
                    *pressed = false;
                    Ok(was)
                } else {
                    Ok(false)
                }
            })?;
            ui_tbl.set("pressed", f)?;
        }

        // ui.set(id, value) — script-side programmatic update (kept in sync
        // with what the app shows; also re-persisted on the next frame).
        {
            let controls = self.controls.clone();
            let f = self
                .lua
                .create_function(move |_, (id, value): (String, Value)| {
                    let mut c = controls.borrow_mut();
                    if let Some(ctrl) = c.items.iter_mut().find(|c| c.id() == Some(&id)) {
                        match ctrl {
                            Control::Checkbox { value: v, .. } => {
                                *v = matches!(value, Value::Boolean(true))
                            }
                            Control::Slider {
                                value: v, min, max, ..
                            } => {
                                if let Some(n) = value.as_f64() {
                                    *v = n.clamp(min.min(*max), min.max(*max));
                                }
                            }
                            Control::Text { value: v, .. } => {
                                if let Value::String(s) = &value {
                                    *v = s.to_string_lossy().to_string();
                                }
                            }
                            Control::Color { value: v, .. } => {
                                if let Some(n) = value.as_u64() {
                                    *v = n as u32;
                                }
                            }
                            Control::Select {
                                value: v, options, ..
                            } => {
                                if let Some(n) = value.as_u64() {
                                    *v = (n as usize)
                                        .saturating_sub(1)
                                        .min(options.len().saturating_sub(1));
                                }
                            }
                            _ => {}
                        }
                    }
                    Ok(())
                })?;
            ui_tbl.set("set", f)?;
        }

        // ui.exists(id) -> true if a control with that id was declared.
        {
            let controls = self.controls.clone();
            let f = self
                .lua
                .create_function(move |_, id: String| Ok(controls.borrow().get(&id).is_some()))?;
            ui_tbl.set("exists", f)?;
        }
        globals.set("ui", ui_tbl)?;

        // --- http table (async; callback fires on a later frame) ---
        let http_tbl = self.lua.create_table()?;
        {
            // One generic request fn; http.get/post/etc. are thin wrappers
            // defined in Lua below so the call sites read naturally.
            let http = self.http.clone();
            let console = self.console.clone();
            let f = self.lua.create_function(
                move |lua, (method, url, opts): (String, String, Option<mlua::Table>)| {
                    let Some(bridge) = http.as_ref() else {
                        console.push(
                            "[http] unavailable (no async runtime) — request dropped".to_string(),
                        );
                        return Ok(());
                    };
                    let mut headers = Vec::new();
                    let mut body = None;
                    let mut timeout_ms = 15_000u64;
                    let mut cb: Option<mlua::Function> = None;
                    if let Some(o) = opts {
                        if let Ok(h) = o.get::<mlua::Table>("headers") {
                            h.pairs::<String, String>().for_each(|p| {
                                if let Ok((k, v)) = p {
                                    headers.push((k, v));
                                }
                            });
                        }
                        if let Ok(b) = o.get::<String>("body") {
                            body = Some(b.into_bytes());
                        }
                        if let Ok(t) = o.get::<u64>("timeout_ms") {
                            if t > 0 {
                                timeout_ms = t;
                            }
                        }
                        cb = o.get::<mlua::Function>("callback").ok();
                    }
                    let Some(id) = bridge.submit(runtime::HttpRequest {
                        method,
                        url,
                        headers,
                        body,
                        timeout_ms,
                        id: 0, // assigned by submit()
                    }) else {
                        // Concurrency cap hit — drop the request and the
                        // callback (never registered), warn the script.
                        console.push(format!(
                            "[http] too many in-flight requests (max {}) — dropped",
                            runtime::HTTP_MAX_IN_FLIGHT
                        ));
                        return Ok(());
                    };
                    // Stash the callback on the UI side keyed by id. mlua
                    // values never cross to the Tokio worker.
                    if let Some(cb) = cb {
                        if let Ok(key) = lua.create_registry_value(cb) {
                            bridge.pending.lock().insert(id, key);
                        }
                    }
                    Ok(())
                },
            )?;
            http_tbl.set("request", f)?;
        }
        globals.set("http", http_tbl)?;
        // Convenience wrappers. `opts` may be a table or, for get/delete, the
        // callback function directly. Response table: {status, headers, body,
        // ok, error}. `ok` is false on transport failure (error set).
        self.lua
            .load(
                r#"
                local function norm(opts, cb)
                  if type(opts) == "function" then return { callback = opts } end
                  opts = opts or {}
                  if cb then opts.callback = cb end
                  return opts
                end
                function http.get(url, opts, cb)
                  http.request("GET", url, norm(opts, cb))
                end
                function http.delete(url, opts, cb)
                  http.request("DELETE", url, norm(opts, cb))
                end
                function http.post(url, body, opts, cb)
                  opts = norm(opts, cb); opts.body = body
                  http.request("POST", url, opts)
                end
                function http.put(url, body, opts, cb)
                  opts = norm(opts, cb); opts.body = body
                  http.request("PUT", url, opts)
                end
                function http.json(t) return _sni_json_encode(t) end
                function http.parse(s) return _sni_json_decode(s) end
                "#,
            )
            .set_name("=[http prelude]")
            .exec()?;

        // JSON helpers backing http.json / http.parse (and usable directly).
        {
            let f = self
                .lua
                .create_function(|_, v: Value| match lua_to_json(&v) {
                    Ok(j) => Ok(serde_json::to_string(&j).unwrap_or_else(|_| "null".into())),
                    Err(e) => Err(e),
                })?;
            globals.set("_sni_json_encode", f)?;
        }
        {
            let f = self.lua.create_function(|lua, s: String| {
                match serde_json::from_str::<serde_json::Value>(&s) {
                    Ok(j) => json_to_lua(lua, &j),
                    Err(e) => Err(mlua::Error::RuntimeError(format!("json parse: {e}"))),
                }
            })?;
            globals.set("_sni_json_decode", f)?;
        }

        Ok(())
    }

    /// Deliver completed HTTP responses to their script callbacks. Runs at the
    /// top of each frame (before `on_frame`) so callbacks execute on the UI
    /// thread with the Lua VM idle — no re-entrancy, no locking across `await`.
    fn pump_http(&self) {
        let Some(bridge) = self.http.as_ref() else {
            return;
        };
        // Drain without holding the receiver lock across Lua calls.
        let mut done = Vec::new();
        {
            let mut rx = bridge.resp_rx.lock();
            while let Ok(resp) = rx.try_recv() {
                done.push(resp);
            }
        }
        for resp in done {
            let Some(key) = bridge.pending.lock().remove(&resp.id) else {
                continue; // no callback (fire-and-forget) or script reloaded
            };
            let cb: mlua::Function = match self.lua.registry_value(&key) {
                Ok(f) => f,
                Err(_) => continue,
            };
            let _ = self.lua.remove_registry_value(key);
            let tbl = match self.lua.create_table() {
                Ok(t) => t,
                Err(_) => continue,
            };
            match resp.result {
                Ok(ok) => {
                    let _ = tbl.set("ok", true);
                    let _ = tbl.set("status", ok.status);
                    let _ = tbl.set("body", ok.body);
                    if let Ok(h) = self.lua.create_table() {
                        for (k, v) in ok.headers {
                            let _ = h.set(k, v);
                        }
                        let _ = tbl.set("headers", h);
                    }
                }
                Err(e) => {
                    let _ = tbl.set("ok", false);
                    let _ = tbl.set("error", e);
                }
            }
            if let Err(e) = cb.call::<()>(tbl) {
                self.console.push(format!("[http callback error] {e}"));
            }
        }
    }

    /// Load (or reload) a script from source. Replaces any previously loaded
    /// chunk with a fresh Lua global environment, clears all watches from the
    /// previous script, runs the chunk once (top level), then calls
    /// `on_init()` if defined.
    pub fn load_script(&mut self, src: &str, name: &str) -> ScriptResult<()> {
        // Give the outgoing script a chance to flush/clean up before its VM
        // is dropped (reload counts as an unload).
        self.fire_unload();
        self.loaded = false;
        self.engine.registry().clear();
        self.draw.borrow_mut().clear();
        self.current_font.set(Font::default());
        self.requested_canvas.set(Canvas::default());
        *self.requested_text_sizing.borrow_mut() = None;
        self.origin_stack.borrow_mut().clear();
        self.time = TimeState::new();
        self.mouse = MouseState::new();
        // Drop the previous script's declared panel; the new script will
        // re-declare its own (seeding values from the persisted store).
        self.controls.borrow_mut().items.clear();
        // The old Lua VM (and its registry) is about to be dropped; any
        // in-flight HTTP callbacks belonged to it, so forget them. Late
        // responses will find no pending entry and be discarded.
        if let Some(h) = &self.http {
            h.pending.lock().clear();
        }
        self.lua = Lua::new();
        self.install_api()?;
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
        // Persist whatever the script declared: first run writes the defaults,
        // later runs round-trip the seeded (saved) values back. Cheap; the
        // store only actually flushes if anything changed.
        self.persist_controls();
        self.loaded = true;
        self.console.push(format!("[loaded] {name}"));
        Ok(())
    }

    pub fn is_loaded(&self) -> bool {
        self.loaded
    }

    /// Call the script's `on_unload()` (if defined and a script is loaded),
    /// then mark unloaded. Used on reload and at app exit so a script can do
    /// a final `store.save`, cancel timers, etc. Errors go to the console;
    /// teardown never aborts the host. Idempotent — safe to call twice.
    fn fire_unload(&mut self) {
        if !self.loaded {
            return;
        }
        if let Ok(cb) = self.lua.globals().get::<mlua::Function>("on_unload") {
            if let Err(e) = cb.call::<()>(()) {
                self.console.push(format!("[on_unload error] {e}"));
            }
        }
        self.loaded = false;
    }

    /// Public teardown for the app to call on exit (after the last frame).
    /// Fires `on_unload` so the script can persist before the process ends.
    pub fn unload(&mut self) {
        self.fire_unload();
    }

    /// The script's declared settings panel, for the app to render. Empty
    /// (per [`Controls::is_empty`]) when the script declared no controls.
    pub fn controls(&self) -> SharedControls {
        self.controls.clone()
    }

    /// Mirror the current control values into the persistent store under the
    /// reserved [`controls::STORE_KEY`] key. The app calls this after a user
    /// edits a widget; also called once after `on_init`. The store's own
    /// dirty check keeps this from writing the disk when nothing changed.
    pub fn persist_controls(&self) {
        let mut map = serde_json::Map::new();
        for c in &self.controls.borrow().items {
            let Some(id) = c.id() else { continue };
            let v = match c {
                Control::Checkbox { value, .. } => serde_json::Value::Bool(*value),
                Control::Slider { value, .. } => serde_json::json!(*value),
                Control::Text { value, .. } => serde_json::Value::String(value.clone()),
                Control::Color { value, .. } => serde_json::json!(*value),
                Control::Select { value, .. } => serde_json::json!(*value),
                // Buttons are momentary — nothing to persist.
                Control::Header { .. } | Control::Label { .. } | Control::Button { .. } => continue,
            };
            map.insert(id.to_string(), v);
        }
        if !map.is_empty() {
            self.store.set(
                controls::STORE_KEY.to_string(),
                serde_json::Value::Object(map),
            );
        }
    }

    /// The canvas the script currently wants (its last `gfx.canvas`/`scale`,
    /// or native by default). The app reads this to decide the effective
    /// canvas (it may honor or override it).
    pub fn requested_canvas(&self) -> Canvas {
        self.requested_canvas.get()
    }

    /// Text sizing defaults the script requested via `gfx.text_sizing`, if
    /// any. The app applies this after load; it is not a per-frame override.
    pub fn requested_text_sizing(&self) -> Option<TextSizingRequest> {
        self.requested_text_sizing.borrow().clone()
    }

    /// Force the active canvas (app override). Call before `run_frame` so the
    /// script's `gfx.width()`/`height()` report the size actually in use.
    pub fn set_canvas(&self, c: Canvas) {
        self.requested_canvas.set(c);
    }

    /// Run one frame: clears the draw list, calls the script's `on_frame()`,
    /// and returns the produced commands for the renderer. A script error is
    /// reported to the console and disables the script (returns empty) so a
    /// bad frame doesn't spam or crash the app.
    pub fn run_frame(&mut self) -> DrawList {
        if !self.loaded {
            return DrawList::default();
        }
        // Advance the frame clock (drives time.frame/now/dt).
        self.time.tick();
        self.draw.borrow_mut().clear();
        // Reset per-frame draw state so a script can't leak font selection
        // or a missing pop_origin from a previous frame.
        self.current_font.set(Font::default());
        self.origin_stack.borrow_mut().clear();

        // Deliver any HTTP responses first so a callback can stage data the
        // same frame's `on_frame` then draws.
        self.pump_http();

        if let Ok(on_frame) = self.lua.globals().get::<mlua::Function>("on_frame") {
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

/// `gfx.triangle` args: three points plus optional color/fill/thickness.
/// Named so the closure signature stays readable (and clippy-quiet).
type TriArgs = (
    f32,
    f32,
    f32,
    f32,
    f32,
    f32,
    Option<u32>,
    Option<u32>,
    Option<f32>,
);

/// `gfx.arc` args: centre, radius, start/end angle, optional
/// color/fill/thickness.
type ArcArgs = (
    f32,
    f32,
    f32,
    f32,
    f32,
    Option<u32>,
    Option<u32>,
    Option<f32>,
);

/// Resolve an optional packed ARGB int to a [`Color`], falling back to a
/// default. Centralised so every primitive treats color args the same way.
fn argb(c: Option<u32>, default: u32) -> Color {
    Color::from_argb(c.unwrap_or(default))
}

/// Convert a Lua value to JSON for the store / HTTP-JSON helpers. A Lua table
/// becomes a JSON array iff its keys are exactly `1..=n` (Lua's array part);
/// otherwise an object with stringified keys. Functions/userdata are rejected.
fn lua_to_json(v: &Value) -> mlua::Result<serde_json::Value> {
    use serde_json::Value as J;
    Ok(match v {
        Value::Nil => J::Null,
        Value::Boolean(b) => J::Bool(*b),
        Value::Integer(i) => J::Number((*i).into()),
        Value::Number(n) => serde_json::Number::from_f64(*n)
            .map(J::Number)
            .unwrap_or(J::Null),
        Value::String(s) => J::String(s.to_string_lossy().to_string()),
        Value::Table(t) => {
            let len = t.raw_len();
            let mut is_array = len > 0;
            // Confirm keys are a clean 1..=len sequence before treating it as
            // an array (a sparse/mixed table must serialize as an object).
            if is_array {
                for i in 1..=len {
                    if t.raw_get::<Value>(i as i64)?.is_nil() {
                        is_array = false;
                        break;
                    }
                }
            }
            if is_array {
                let mut arr = Vec::with_capacity(len);
                for i in 1..=len {
                    arr.push(lua_to_json(&t.raw_get::<Value>(i as i64)?)?);
                }
                J::Array(arr)
            } else {
                let mut map = serde_json::Map::new();
                for pair in t.clone().pairs::<Value, Value>() {
                    let (k, val) = pair?;
                    let key = match k {
                        Value::String(s) => s.to_string_lossy().to_string(),
                        Value::Integer(i) => i.to_string(),
                        Value::Number(n) => n.to_string(),
                        _ => continue, // skip non-stringable keys
                    };
                    map.insert(key, lua_to_json(&val)?);
                }
                J::Object(map)
            }
        }
        other => {
            return Err(mlua::Error::RuntimeError(format!(
                "cannot serialize {} to JSON",
                other.type_name()
            )))
        }
    })
}

/// Inverse of [`lua_to_json`]. JSON objects/arrays become Lua tables; numbers
/// stay integers when they have no fractional part (so `store` round-trips
/// addresses and counts cleanly).
fn json_to_lua(lua: &Lua, j: &serde_json::Value) -> mlua::Result<Value> {
    use serde_json::Value as J;
    Ok(match j {
        J::Null => Value::Nil,
        J::Bool(b) => Value::Boolean(*b),
        J::Number(n) => {
            if let Some(i) = n.as_i64() {
                Value::Integer(i)
            } else {
                Value::Number(n.as_f64().unwrap_or(0.0))
            }
        }
        J::String(s) => Value::String(lua.create_string(s)?),
        J::Array(a) => {
            let t = lua.create_table()?;
            for (i, v) in a.iter().enumerate() {
                t.set(i + 1, json_to_lua(lua, v)?)?;
            }
            Value::Table(t)
        }
        J::Object(m) => {
            let t = lua.create_table()?;
            for (k, v) in m {
                t.set(k.as_str(), json_to_lua(lua, v)?)?;
            }
            Value::Table(t)
        }
    })
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
        let rt = RT.get_or_init(|| tokio::runtime::Runtime::new().expect("test runtime"));
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
    fn reload_clears_watches_and_old_callbacks() {
        let mut h = host();
        h.load_script(
            r#"
            local hp = snes.watch(0x09C2, 2, "realtime")
            gfx.scale(3)
            function on_frame()
              gfx.text(1, 2, "old")
            end
            "#,
            "old",
        )
        .unwrap();
        assert_eq!(h.engine.registry().len(), 1);
        assert_eq!(h.requested_canvas(), Canvas::scaled(3));
        assert_eq!(h.run_frame().cmds.len(), 1);

        h.load_script("-- deliberately empty replacement", "new")
            .unwrap();

        assert_eq!(h.engine.registry().len(), 0, "old watches cleared");
        assert_eq!(h.requested_canvas(), Canvas::default());
        assert!(
            h.run_frame().cmds.is_empty(),
            "old on_frame must not survive reload"
        );
    }

    #[test]
    fn ported_super_hitbox_loads_and_runs() {
        // The real test: a 4800-line Mesen2 script ported via the compat
        // prelude must load and survive several frames on the async model
        // (no SNI client -> all reads return the cache default of 0, which
        // the script's guards must tolerate).
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../examples/super_hitbox_sni.lua"
        );
        let src = std::fs::read_to_string(path).expect("ported script present");
        let mut h = host();
        h.load_script(&src, "super_hitbox_sni.lua")
            .expect("ported script loads without error");
        // The adapter now surfaces the key AnyG toggles as ui.* controls.
        assert!(
            h.controls().borrow().get("anyg_dashboard").is_some(),
            "hitbox adapter should declare the AnyG settings panel"
        );
        let mut last = DrawList::default();
        for _ in 0..8 {
            last = h.run_frame();
            assert!(
                h.is_loaded(),
                "script disabled itself: {:?}",
                h.console().snapshot()
            );
        }
        // It should draw *something* even with no game data (the block
        // viewer frame / status text). Count by kind for diagnosis.
        let (mut t, mut r, mut l, mut p) = (0, 0, 0, 0);
        for c in &last.cmds {
            match c {
                DrawCmd::Text { .. } => t += 1,
                DrawCmd::Rect { .. } => r += 1,
                DrawCmd::Line { .. } => l += 1,
                DrawCmd::Pixel { .. } => p += 1,
                DrawCmd::Circle { .. }
                | DrawCmd::Triangle { .. }
                | DrawCmd::Poly { .. }
                | DrawCmd::Arc { .. } => {}
            }
        }
        eprintln!(
            "super_hitbox draw: {} cmds (text={t} rect={r} line={l} pixel={p})",
            last.cmds.len()
        );
        assert!(
            !last.cmds.is_empty(),
            "ported script produced NO draw commands — console: {:?}",
            h.console().snapshot()
        );
    }

    #[test]
    fn gfx_scale_changes_reported_canvas() {
        let mut h = host();
        h.load_script(
            r#"
            gfx.scale(2)
            cw, ch = gfx.width(), gfx.height()
            "#,
            "t",
        )
        .unwrap();
        let cw: f32 = h.lua.globals().get("cw").unwrap();
        let ch: f32 = h.lua.globals().get("ch").unwrap();
        assert_eq!((cw, ch), (512.0, 448.0));
        assert_eq!(h.requested_canvas().w, 512.0);
    }

    #[test]
    fn app_can_override_script_canvas() {
        let mut h = host();
        h.load_script(r#"gfx.scale(4)"#, "t").unwrap();
        assert_eq!(h.requested_canvas().w, 1024.0);
        // App forces native; gfx.width() inside a later frame must follow.
        h.set_canvas(Canvas::native());
        h.load_script(r#"w = gfx.width()"#, "t2").unwrap();
        let w: f32 = h.lua.globals().get("w").unwrap();
        assert_eq!(w, 256.0);
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
        let v: Option<i64> = h.lua.globals().get("result").unwrap();
        assert_eq!(v, None);
    }

    #[test]
    fn script_error_disables_frame_not_crashes() {
        let mut h = host();
        h.load_script(r#"function on_frame() error("boom") end"#, "t")
            .unwrap();
        let dl = h.run_frame();
        assert!(dl.cmds.is_empty());
        assert!(!h.is_loaded(), "broken script disabled");
        assert!(h.console().snapshot().iter().any(|l| l.contains("boom")));
    }

    #[test]
    fn print_routes_to_console() {
        let mut h = host();
        h.load_script(r#"print("hello", 42)"#, "t").unwrap();
        assert!(h.console().snapshot().iter().any(|l| l.contains("hello")));
    }

    #[test]
    fn store_get_set_and_blob_roundtrip() {
        let mut h = host();
        h.load_script(
            r#"
            store.set("hp", 99)
            store.set("name", "samus")
            store.set("flags", { a = true, list = {1, 2, 3} })
            got_hp   = store.get("hp")
            got_name = store.get("name")
            blob     = store.load()
            got_list = blob.flags.list[2]
            store.delete("name")
            after_del = store.get("name")
            "#,
            "t",
        )
        .unwrap();
        let g = h.lua.globals();
        assert_eq!(g.get::<i64>("got_hp").unwrap(), 99);
        assert_eq!(g.get::<String>("got_name").unwrap(), "samus");
        assert_eq!(g.get::<i64>("got_list").unwrap(), 2);
        assert!(g.get::<Value>("after_del").unwrap().is_nil());
    }

    #[test]
    fn store_persists_across_rebind() {
        let dir = std::env::temp_dir().join(format!("snilua_store_{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let file = dir.join("test.json");
        let _ = std::fs::remove_file(&file);

        let mut h = host();
        h.bind_store(Some(file.clone()));
        h.load_script(r#"store.set("runs", 1)"#, "t").unwrap();
        h.store().flush_if_dirty();
        assert!(file.exists(), "store flushed a file");

        // Fresh host + same file: the value comes back.
        let mut h2 = host();
        h2.bind_store(Some(file.clone()));
        h2.load_script(r#"loaded = store.get("runs")"#, "t")
            .unwrap();
        assert_eq!(h2.lua.globals().get::<i64>("loaded").unwrap(), 1);

        let _ = std::fs::remove_file(&file);
    }

    #[test]
    fn json_encode_decode_roundtrip() {
        let mut h = host();
        h.load_script(
            r#"
            s = _sni_json_encode({ x = 1, y = { "a", "b" } })
            back = _sni_json_decode(s)
            rx, ry2 = back.x, back.y[2]
            "#,
            "t",
        )
        .unwrap();
        let g = h.lua.globals();
        assert_eq!(g.get::<i64>("rx").unwrap(), 1);
        assert_eq!(g.get::<String>("ry2").unwrap(), "b");
    }

    #[test]
    fn http_unavailable_without_runtime_is_graceful() {
        // `host()` builds via ScriptHost::new -> no HTTP bridge. A request
        // must not panic; it logs to the console and is dropped.
        let mut h = host();
        h.load_script(
            r#"http.get("http://example.invalid/", function(r) end)"#,
            "t",
        )
        .unwrap();
        h.run_frame();
        assert!(
            h.is_loaded(),
            "script survived an http call with no runtime"
        );
        assert!(h
            .console()
            .snapshot()
            .iter()
            .any(|l| l.contains("[http] unavailable")));
    }

    #[test]
    fn ui_controls_declare_and_read_back() {
        let mut h = host();
        h.load_script(
            r#"
            function on_init()
              ui.header("Hitbox")
              ui.checkbox("show", "Show box", true)
              ui.slider("thick", "Width", 1, 5, 3)
              ui.select("mode", "Mode", { "a", "b", "c" }, 2)
              ui.color("col", "Color", 0xFF112233)
              ui.button("reset", "Reset")
            end
            function on_frame()
              got_show  = ui.get("show")
              got_thick = ui.get("thick")
              got_mode  = ui.get("mode")     -- 1-based
              got_col   = ui.get("col")
            end
            "#,
            "t",
        )
        .unwrap();
        h.run_frame();
        let g = h.lua.globals();
        assert!(g.get::<bool>("got_show").unwrap());
        assert_eq!(g.get::<f64>("got_thick").unwrap(), 3.0);
        assert_eq!(g.get::<i64>("got_mode").unwrap(), 2);
        assert_eq!(g.get::<i64>("got_col").unwrap(), 0xFF112233);

        // The app sees the declared panel; layout-only items don't make a
        // panel "non-empty" on their own but the real controls do.
        let c = h.controls();
        assert!(!c.borrow().is_empty());
        assert_eq!(c.borrow().items.len(), 6);
    }

    #[test]
    fn settings_panel_example_loads_and_declares_panel() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../examples/settings_panel.lua"
        );
        let src = std::fs::read_to_string(path).expect("settings_panel present");
        let mut h = host();
        h.load_script(&src, "settings_panel.lua")
            .expect("settings_panel loads");
        h.run_frame();
        assert!(h.is_loaded(), "console: {:?}", h.console().snapshot());
        assert!(
            !h.controls().borrow().is_empty(),
            "example should declare a settings panel"
        );
    }

    #[test]
    fn animated_input_viewer_example_loads_and_runs() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../examples/animated_input_viewer.lua"
        );
        let src = std::fs::read_to_string(path).expect("animated input viewer present");
        let mut h = host();
        h.load_script(&src, "animated_input_viewer.lua")
            .expect("animated input viewer loads");
        for _ in 0..4 {
            h.run_frame();
            assert!(h.is_loaded(), "console: {:?}", h.console().snapshot());
        }
        assert!(
            !h.controls().borrow().is_empty(),
            "input viewer should declare a settings panel"
        );
        let dl = h.run_frame();
        assert!(!dl.cmds.is_empty(), "input viewer should draw something");
    }

    #[test]
    fn ui_button_press_latches_once() {
        let mut h = host();
        h.load_script(
            r#"
            function on_init() ui.button("go", "Go") end
            function on_frame() fired = ui.pressed("go") end
            "#,
            "t",
        )
        .unwrap();
        h.run_frame();
        assert!(!h.lua.globals().get::<bool>("fired").unwrap());

        // Simulate the app handling a click: flip the latch.
        if let Some(Control::Button { pressed, .. }) = h
            .controls()
            .borrow_mut()
            .items
            .iter_mut()
            .find(|c| c.id() == Some("go"))
        {
            *pressed = true;
        }
        h.run_frame();
        assert!(h.lua.globals().get::<bool>("fired").unwrap());
        h.run_frame(); // drained — must not re-fire
        assert!(!h.lua.globals().get::<bool>("fired").unwrap());
    }

    #[test]
    fn ui_control_values_persist_across_reload() {
        let dir = std::env::temp_dir().join(format!("snilua_ui_{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let file = dir.join("ui.json");
        let _ = std::fs::remove_file(&file);

        let script = r#"
            function on_init()
              ui.slider("vol", "Volume", 0, 100, 50)
            end
        "#;

        let mut h = host();
        h.bind_store(Some(file.clone()));
        h.load_script(script, "t").unwrap();
        // User drags the slider to 80; app mirrors + persists.
        if let Some(Control::Slider { value, .. }) = h
            .controls()
            .borrow_mut()
            .items
            .iter_mut()
            .find(|c| c.id() == Some("vol"))
        {
            *value = 80.0;
        }
        h.persist_controls();
        h.store().flush_if_dirty();

        // Fresh host, same store file, same script: the seeded value is 80,
        // not the script's default of 50.
        let mut h2 = host();
        h2.bind_store(Some(file.clone()));
        h2.load_script(script, "t").unwrap();
        let v = match h2.controls().borrow().get("vol").cloned() {
            Some(Control::Slider { value, .. }) => value,
            _ => panic!("slider missing"),
        };
        assert_eq!(v, 80.0);

        let _ = std::fs::remove_file(&file);
    }

    #[test]
    fn time_table_advances_per_frame() {
        let mut h = host();
        h.load_script(
            r#"
            f0 = time.frame()
            function on_frame()
              fr = time.frame()
              t  = time.now()
              d  = time.dt()
            end
            "#,
            "t",
        )
        .unwrap();
        // Frame counter starts at 0 (no run_frame yet).
        assert_eq!(h.lua.globals().get::<i64>("f0").unwrap(), 0);
        h.run_frame();
        assert_eq!(h.lua.globals().get::<i64>("fr").unwrap(), 1);
        h.run_frame();
        assert_eq!(h.lua.globals().get::<i64>("fr").unwrap(), 2);
        assert!(h.lua.globals().get::<f64>("t").unwrap() >= 0.0);
        assert!(h.lua.globals().get::<f64>("d").unwrap() >= 0.0);
    }

    #[test]
    fn signed_readers_and_buttons_decode() {
        let mut h = host();
        // No SNI client -> snapshots empty, so reads are nil; we only assert
        // the functions exist and tolerate the cold cache without erroring.
        h.load_script(
            r#"
            local w = snes.watch(0x008B, 2, "realtime")
            i8v   = snes.i8(w)        -- nil (cold)
            i32v  = snes.i32(w)       -- nil (cold)
            btns  = snes.buttons(w)   -- nil (cold)
            has_fns = (snes.i8 ~= nil) and (snes.i32 ~= nil)
                      and (snes.buttons ~= nil)
            "#,
            "t",
        )
        .unwrap();
        let g = h.lua.globals();
        assert!(g.get::<bool>("has_fns").unwrap());
        assert!(g.get::<Value>("btns").unwrap().is_nil());
    }

    #[test]
    fn gfx_origin_offsets_subsequent_draws() {
        let mut h = host();
        h.load_script(
            r#"
            function on_frame()
              gfx.box(10, 10, 4, 4)              -- absolute
              gfx.push_origin(100, 200)
              gfx.box(1, 2, 4, 4)                -- -> (101, 202)
              gfx.push_origin(10, 10)            -- nested -> +110,+210
              gfx.pixel(0, 0)                    -- -> (110, 210)
              gfx.pop_origin()
              gfx.pop_origin()
              gfx.box(5, 5, 4, 4)               -- back to absolute
            end
            "#,
            "t",
        )
        .unwrap();
        let dl = h.run_frame();
        let rects: Vec<(f32, f32)> = dl
            .cmds
            .iter()
            .filter_map(|c| match c {
                DrawCmd::Rect { x, y, .. } => Some((*x, *y)),
                _ => None,
            })
            .collect();
        assert_eq!(rects, vec![(10.0, 10.0), (101.0, 202.0), (5.0, 5.0)]);
        let px: Vec<(f32, f32)> = dl
            .cmds
            .iter()
            .filter_map(|c| match c {
                DrawCmd::Pixel { x, y, .. } => Some((*x, *y)),
                _ => None,
            })
            .collect();
        assert_eq!(px, vec![(110.0, 210.0)]);
    }

    #[test]
    fn gfx_circle_triangle_and_text_metrics() {
        let mut h = host();
        h.load_script(
            r#"
            function on_frame()
              gfx.circle(50, 50, 8, 0xFFFF0000, 0x4000FF00, 2)
              gfx.triangle(0,0, 10,0, 5,10, 0xFFFFFFFF)
              tw = gfx.text_width("ABCD")     -- 4 glyphs * advance
              th = gfx.text_height("a\nb\nc") -- 3 lines
            end
            "#,
            "t",
        )
        .unwrap();
        let dl = h.run_frame();
        assert!(dl.cmds.iter().any(|c| matches!(c, DrawCmd::Circle { .. })));
        assert!(dl
            .cmds
            .iter()
            .any(|c| matches!(c, DrawCmd::Triangle { .. })));
        let g = h.lua.globals();
        assert!(g.get::<f32>("tw").unwrap() > 0.0);
        // 3 lines must be taller than a single line.
        assert!(g.get::<f32>("th").unwrap() > g.get::<f32>("tw").unwrap() / 4.0);
    }

    #[test]
    fn log_levels_route_to_console_with_prefix() {
        let mut h = host();
        h.load_script(
            r#"log.info("hi"); log.warn("careful"); log.error("boom")"#,
            "t",
        )
        .unwrap();
        let lines = h.console().snapshot();
        assert!(lines.iter().any(|l| l == "hi"));
        assert!(lines.iter().any(|l| l == "[warn] careful"));
        assert!(lines.iter().any(|l| l == "[error] boom"));
    }

    #[test]
    fn on_unload_fires_on_reload_and_can_persist() {
        let dir = std::env::temp_dir().join(format!("snilua_unload_{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let file = dir.join("u.json");
        let _ = std::fs::remove_file(&file);

        let mut h = host();
        h.bind_store(Some(file.clone()));
        h.load_script(
            r#"
            function on_unload()
              store.set("saved_on_unload", 7)
            end
            "#,
            "a",
        )
        .unwrap();
        // Reloading a different script must fire the old on_unload first.
        h.load_script(r#"-- empty"#, "b").unwrap();
        h.store().flush_if_dirty();

        let mut h2 = host();
        h2.bind_store(Some(file.clone()));
        h2.load_script(r#"v = store.get("saved_on_unload")"#, "c")
            .unwrap();
        assert_eq!(h2.lua.globals().get::<i64>("v").unwrap(), 7);
        let _ = std::fs::remove_file(&file);
    }

    #[test]
    fn http_concurrency_cap_rejects_overflow() {
        use std::sync::OnceLock;
        static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
        let rt = RT.get_or_init(|| tokio::runtime::Runtime::new().unwrap());
        let _g = rt.enter();
        let bridge = crate::runtime::HttpBridge::spawn();
        let mk = || crate::runtime::HttpRequest {
            // Unroutable: the request stays in-flight (connect timeout) long
            // enough that the in-flight count doesn't drain during the test,
            // so the cap is observed synchronously — no network needed.
            method: "GET".into(),
            url: "http://10.255.255.1:9/".into(),
            headers: vec![],
            body: None,
            timeout_ms: 30_000,
            id: 0,
        };
        // First MAX submissions reserve their slot and succeed.
        for _ in 0..crate::runtime::HTTP_MAX_IN_FLIGHT {
            assert!(bridge.submit(mk()).is_some());
        }
        // The next one is over the cap -> dropped.
        assert!(
            bridge.submit(mk()).is_none(),
            "request past the concurrency cap must be rejected"
        );
    }

    #[test]
    fn ui_exists_reports_declared_controls() {
        let mut h = host();
        h.load_script(
            r#"
            function on_init() ui.checkbox("flag", "Flag", true) end
            function on_frame()
              a = ui.exists("flag")
              b = ui.exists("nope")
            end
            "#,
            "t",
        )
        .unwrap();
        h.run_frame();
        assert!(h.lua.globals().get::<bool>("a").unwrap());
        assert!(!h.lua.globals().get::<bool>("b").unwrap());
    }

    #[test]
    fn gfx_text_options_table_and_back_compat_scale() {
        let mut h = host();
        h.load_script(
            r#"
            function on_frame()
              gfx.text(1, 1, "plain")
              gfx.text(1, 9, "scaled", 0xFFFFFFFF, 3)              -- numeric 5th = scale
              gfx.text(1, 17, "fancy", 0xFFFFFFFF,
                       { scale = 2, bg = 0xA0000000, outline = 0xFF000000 })
            end
            "#,
            "t",
        )
        .unwrap();
        let dl = h.run_frame();
        let texts: Vec<_> = dl
            .cmds
            .iter()
            .filter_map(|c| match c {
                DrawCmd::Text {
                    text,
                    scale,
                    bg,
                    outline,
                    ..
                } => Some((text.clone(), *scale, bg.is_some(), outline.is_some())),
                _ => None,
            })
            .collect();
        assert_eq!(texts[0], ("plain".into(), 1.0, false, false));
        assert_eq!(texts[1], ("scaled".into(), 3.0, false, false));
        assert_eq!(texts[2], ("fancy".into(), 2.0, true, true));
    }

    #[test]
    fn gfx_text_sizing_request_is_recorded_and_resets_on_reload() {
        let mut h = host();
        h.load_script(r#"gfx.text_sizing("screen", 1.25)"#, "t")
            .unwrap();
        assert_eq!(
            h.requested_text_sizing(),
            Some(TextSizingRequest {
                mode: "screen".into(),
                size: 1.25,
            })
        );

        h.load_script("-- no text sizing request", "t2").unwrap();
        assert_eq!(h.requested_text_sizing(), None);
    }

    #[test]
    fn gfx_poly_and_arc_emit_commands() {
        let mut h = host();
        h.load_script(
            r#"
            function on_frame()
              gfx.poly({ {x=0,y=0}, {x=10,y=0}, {5,10} }, 0xFFFFFFFF,
                       0x4000FF00, 1)                 -- closed (default), filled
              gfx.poly({ {0,0}, {20,20} }, 0xFFFFFFFF, nil, 1, false)  -- open
              gfx.arc(50, 50, 12, 0, 270, 0xFFFFFFFF, nil, 2)
            end
            "#,
            "t",
        )
        .unwrap();
        let dl = h.run_frame();
        let polys: Vec<_> = dl
            .cmds
            .iter()
            .filter_map(|c| match c {
                DrawCmd::Poly {
                    points,
                    closed,
                    fill,
                    ..
                } => Some((points.len(), *closed, fill.is_some())),
                _ => None,
            })
            .collect();
        assert_eq!(polys, vec![(3, true, true), (2, false, false)]);
        let arc = dl
            .cmds
            .iter()
            .find_map(|c| match c {
                DrawCmd::Arc {
                    start_deg, end_deg, ..
                } => Some((*start_deg, *end_deg)),
                _ => None,
            })
            .expect("arc emitted");
        assert_eq!(arc, (0.0, 270.0));
    }

    #[test]
    fn gfx_poly_respects_origin_offset() {
        let mut h = host();
        h.load_script(
            r#"
            function on_frame()
              gfx.push_origin(100, 200)
              gfx.poly({ {1,2}, {3,4}, {5,6} })
              gfx.pop_origin()
            end
            "#,
            "t",
        )
        .unwrap();
        let dl = h.run_frame();
        let pts = dl
            .cmds
            .iter()
            .find_map(|c| match c {
                DrawCmd::Poly { points, .. } => Some(points.clone()),
                _ => None,
            })
            .unwrap();
        assert_eq!(pts, vec![(101.0, 202.0), (103.0, 204.0), (105.0, 206.0)]);
    }

    #[test]
    fn gfx_color_lerp_blends_channels() {
        let mut h = host();
        h.load_script(
            r#"
            a    = gfx.color_lerp(0xFF000000, 0xFFFFFFFF, 0.0)
            b    = gfx.color_lerp(0xFF000000, 0xFFFFFFFF, 1.0)
            mid  = gfx.color_lerp(0xFF000000, 0xFFFFFFFF, 0.5)
            clamp= gfx.color_lerp(0xFF000000, 0xFFFFFFFF, 5.0)   -- clamps to 1
            "#,
            "t",
        )
        .unwrap();
        let g = h.lua.globals();
        assert_eq!(g.get::<i64>("a").unwrap() as u32, 0xFF000000);
        assert_eq!(g.get::<i64>("b").unwrap() as u32, 0xFFFFFFFF);
        // Halfway: each RGB channel ~0x80, alpha stays 0xFF.
        assert_eq!(g.get::<i64>("mid").unwrap() as u32, 0xFF808080);
        assert_eq!(g.get::<i64>("clamp").unwrap() as u32, 0xFFFFFFFF);
    }

    #[test]
    fn drawing_example_loads_and_runs() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../examples/drawing.lua");
        let src = std::fs::read_to_string(path).expect("drawing example present");
        let mut h = host();
        h.load_script(&src, "drawing.lua")
            .expect("drawing example loads");
        for _ in 0..4 {
            h.run_frame();
            assert!(h.is_loaded(), "console: {:?}", h.console().snapshot());
        }
        let dl = h.run_frame();
        // Should exercise text(bg/outline) + poly + arc + box.
        assert!(dl.cmds.iter().any(|c| matches!(c, DrawCmd::Poly { .. })));
        assert!(dl.cmds.iter().any(|c| matches!(c, DrawCmd::Arc { .. })));
    }

    /// Every shipped example must at least load and survive a few frames, so
    /// an API change can't silently break the docs-by-example.
    fn smoke_example(file: &str) {
        let path = format!("{}/../../examples/{file}", env!("CARGO_MANIFEST_DIR"));
        let src = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{file}: {e}"));
        let mut h = host();
        h.load_script(&src, file)
            .unwrap_or_else(|e| panic!("{file} failed to load: {e}"));
        for _ in 0..4 {
            h.run_frame();
            assert!(
                h.is_loaded(),
                "{file} disabled itself: {:?}",
                h.console().snapshot()
            );
        }
    }

    #[test]
    fn sm_hud_example_loads_and_runs() {
        smoke_example("sm_hud.lua");
    }

    #[test]
    fn hires_canvas_example_loads_and_runs() {
        smoke_example("hires_canvas.lua");
    }

    #[test]
    fn store_and_http_example_loads_and_runs() {
        smoke_example("store_and_http.lua");
    }

    #[test]
    fn toast_example_loads_and_runs() {
        smoke_example("toast.lua");
    }

    #[test]
    fn toast_example_handles_mouse_clicks() {
        // Drive the toast example with a click so its mouse-driven paths
        // (push on click, hover highlight, dismiss) actually execute.
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../examples/toast.lua");
        let src = std::fs::read_to_string(path).expect("toast example present");
        let mut h = host();
        h.load_script(&src, "toast.lua").expect("toast loads");
        h.feed_mouse(MouseFrame {
            pos: Some((80.0, 60.0)),
            buttons: [true, false, false],
            wheel: 0.0,
        });
        h.run_frame();
        for _ in 0..6 {
            h.feed_mouse(MouseFrame {
                pos: Some((80.0, 60.0)),
                buttons: [false, false, false],
                wheel: 0.0,
            });
            h.run_frame();
            assert!(h.is_loaded(), "console: {:?}", h.console().snapshot());
        }
        let dl = h.run_frame();
        assert!(!dl.cmds.is_empty(), "toast should draw a notification");
    }

    #[test]
    fn toast_example_ignores_off_canvas_clicks() {
        // Regression: a left-click while the pointer is OUTSIDE the canvas
        // (mouse.pos() == nil) must not spawn a toast.
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../examples/toast.lua");
        let src = std::fs::read_to_string(path).expect("toast example present");
        let mut h = host();
        h.load_script(&src, "toast.lua").expect("toast loads");
        h.run_frame(); // settle (initial "Click the canvas" toast logs once)
        let before = h
            .console()
            .snapshot()
            .iter()
            .filter(|l| l.contains("toast [ok] Clicked at"))
            .count();
        // Click with no canvas position (pointer off-canvas).
        h.feed_mouse(MouseFrame {
            pos: None,
            buttons: [true, false, false],
            wheel: 0.0,
        });
        h.run_frame();
        let after = h
            .console()
            .snapshot()
            .iter()
            .filter(|l| l.contains("toast [ok] Clicked at"))
            .count();
        assert_eq!(before, after, "off-canvas click must not spawn a toast");
    }

    #[test]
    fn toast_example_demo_button_uses_selected_kind() {
        // Regression: ui.get on a select returns a 1-based index, not the
        // option string. The Demo button must map it back to the kind name
        // so a non-default selection actually changes the toast.
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../examples/toast.lua");
        let src = std::fs::read_to_string(path).expect("toast example present");
        let mut h = host();
        h.load_script(&src, "toast.lua").expect("toast loads");
        h.run_frame();

        // Select "error" (4th option, 1-based index 4) and press Demo.
        {
            let controls = h.controls();
            let mut c = controls.borrow_mut();
            for item in c.items.iter_mut() {
                match item {
                    Control::Select { id, value, .. } if id == "kind" => *value = 3, // 0-based
                    Control::Button { id, pressed, .. } if id == "demo" => *pressed = true,
                    _ => {}
                }
            }
        }
        h.run_frame();
        // notify() logs the *resolved* kind, so the console shows which
        // kind the Demo button actually used. The buggy path (passing the
        // raw select index) would always resolve to "info".
        let log = h.console().snapshot().join("\n");
        assert!(
            log.contains("toast [error] Hello from sni-lua"),
            "Demo with 'error' selected must use that kind; console was: {log}"
        );
    }

    #[test]
    fn anim_prelude_helpers_work() {
        let mut h = host();
        h.load_script(
            r#"
            lerp_mid = anim.lerp(0, 100, 0.5)
            lerp_clamp = anim.lerp(0, 100, 2.0)        -- t clamps to 1
            ease_lin = anim.ease(0.5, "linear")
            ease_oq  = anim.ease(0.5, "out_quad")      -- > linear at 0.5
            pulse    = anim.pulse(2)                   -- in 0..1
            blink    = anim.blink(1)                   -- boolean
            saw      = anim.saw(2)                      -- in 0..1
            clamped  = anim.clamp(150, 0, 100)
            "#,
            "t",
        )
        .unwrap();
        let g = h.lua.globals();
        assert_eq!(g.get::<f64>("lerp_mid").unwrap(), 50.0);
        assert_eq!(g.get::<f64>("lerp_clamp").unwrap(), 100.0);
        assert_eq!(g.get::<f64>("ease_lin").unwrap(), 0.5);
        assert!(g.get::<f64>("ease_oq").unwrap() > 0.5);
        let p = g.get::<f64>("pulse").unwrap();
        assert!((0.0..=1.0).contains(&p));
        assert!(g.get::<bool>("blink").unwrap()); // t≈0 -> first half
        let s = g.get::<f64>("saw").unwrap();
        assert!((0.0..=1.0).contains(&s));
        assert_eq!(g.get::<f64>("clamped").unwrap(), 100.0);
    }

    #[test]
    fn mouse_position_and_over_reflect_fed_frame() {
        let mut h = host();
        h.load_script(
            r#"
            function on_frame()
              ox, oy = mouse.pos()
              over   = mouse.over()
              mx, my = mouse.x(), mouse.y()
            end
            "#,
            "t",
        )
        .unwrap();

        // No frame fed yet -> off-canvas.
        h.run_frame();
        let g = h.lua.globals();
        assert!(g.get::<Value>("ox").unwrap().is_nil());
        assert!(!g.get::<bool>("over").unwrap());

        h.feed_mouse(MouseFrame {
            pos: Some((40.0, 22.0)),
            buttons: [false; 3],
            wheel: 0.0,
        });
        h.run_frame();
        assert_eq!(h.lua.globals().get::<f32>("mx").unwrap(), 40.0);
        assert_eq!(h.lua.globals().get::<f32>("my").unwrap(), 22.0);
        assert!(h.lua.globals().get::<bool>("over").unwrap());

        // Pointer leaves the canvas.
        h.feed_mouse(MouseFrame::default());
        h.run_frame();
        assert!(h.lua.globals().get::<Value>("mx").unwrap().is_nil());
        assert!(!h.lua.globals().get::<bool>("over").unwrap());
    }

    #[test]
    fn mouse_button_edges_fire_once() {
        let mut h = host();
        h.load_script(
            r#"
            function on_frame()
              down  = mouse.down("left")
              press = mouse.pressed("left")
              rel   = mouse.released("left")
              rdown = mouse.down("right")
            end
            "#,
            "t",
        )
        .unwrap();
        let lmb = |b| MouseFrame {
            pos: Some((1.0, 1.0)),
            buttons: [b, false, false],
            wheel: 0.0,
        };

        // Press: down + pressed-edge true, released false.
        h.feed_mouse(lmb(true));
        h.run_frame();
        let g = h.lua.globals();
        assert!(g.get::<bool>("down").unwrap());
        assert!(g.get::<bool>("press").unwrap());
        assert!(!g.get::<bool>("rel").unwrap());
        assert!(!g.get::<bool>("rdown").unwrap());

        // Held: still down, but the pressed edge is consumed.
        h.feed_mouse(lmb(true));
        h.run_frame();
        assert!(h.lua.globals().get::<bool>("down").unwrap());
        assert!(!h.lua.globals().get::<bool>("press").unwrap());

        // Release: released-edge true exactly one frame.
        h.feed_mouse(lmb(false));
        h.run_frame();
        assert!(!h.lua.globals().get::<bool>("down").unwrap());
        assert!(h.lua.globals().get::<bool>("rel").unwrap());
        h.feed_mouse(lmb(false));
        h.run_frame();
        assert!(!h.lua.globals().get::<bool>("rel").unwrap());
    }

    #[test]
    fn mouse_wheel_and_reset_on_reload() {
        let mut h = host();
        h.load_script(r#"function on_frame() w = mouse.wheel() end"#, "t")
            .unwrap();
        h.feed_mouse(MouseFrame {
            pos: None,
            buttons: [false; 3],
            wheel: -3.5,
        });
        h.run_frame();
        assert_eq!(h.lua.globals().get::<f32>("w").unwrap(), -3.5);

        // Reloading a script must clear stale pointer state.
        h.load_script(r#"function on_frame() w = mouse.wheel() end"#, "t2")
            .unwrap();
        h.run_frame();
        assert_eq!(h.lua.globals().get::<f32>("w").unwrap(), 0.0);
    }
}
