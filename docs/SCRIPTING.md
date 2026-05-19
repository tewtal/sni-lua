# sni-lua scripting API reference

The complete API available to overlay scripts. A script is a Lua (LuaJIT)
file with optional lifecycle functions; the host calls them and exposes the
tables documented here as globals.

- [Execution model](#execution-model)
- [Lifecycle functions](#lifecycle-functions)
- [`snes` — memory & input](#snes--memory--input)
- [`gfx` — drawing](#gfx--drawing)
- [`ui` — settings panel](#ui--settings-panel)
- [`store` — persistence](#store--persistence)
- [`http` — networking](#http--networking)
- [`time` — clock](#time--clock)
- [`log` / `print` — console](#log--print--console)
- [`anim` — tweening & oscillators](#anim--tweening--oscillators)
- [Conventions](#conventions)

Notation: `name(req, opt?)` — `?` marks an optional argument. `0xAARRGGBB`
is a packed color int (see [Conventions](#conventions)). "frame" means one
overlay render tick, distinct from the SNES console's own frame.

---

## Execution model

SNI talks to FXPAK hardware with **real latency and limited bandwidth**, so
there is **no synchronous memory read**. Instead:

1. A script **declares watches** (`snes.watch`) — regions it cares about.
2. A background poll engine batches all watches into `MultiRead` calls and
   publishes immutable **snapshots**.
3. Script reads (`snes.u16`, …) return the **latest cached snapshot** — a
   lock-free load, never I/O. They return `nil` until the first poll for
   that watch lands (guard the opening frames).
4. Reading a watch is also a **demand signal**: a watch the script stops
   reading goes dormant (cached, not refreshed) so the polled set can't
   grow without bound. Pin important watches with a priority / `snes.tier`.

Everything that could block a frame is async and non-re-entrant: `http`
callbacks and the `ui` panel run between frames on the UI thread with the
Lua VM idle, never inside your `on_frame`.

---

## Lifecycle functions

Define any of these as globals; all are optional.

| Function | When | Notes |
|---|---|---|
| `on_init()` | Once, right after the script loads. | Declare `ui.*` controls, read `store`, register watches. Errors here abort the load. |
| `on_frame()` | Every overlay frame. | Read cached memory, emit `gfx.*` draw calls. An error disables the script (reported to the console) rather than crashing the app. |
| `on_unload()` | Before a reload, and at app exit. | Final cleanup / `store.save`. Errors are logged, never fatal. |

```lua
function on_init()  print("loaded") end
function on_frame() gfx.text(8, 8, "hello") end
function on_unload() store.set("ran_ok", true) end
```

Per-frame draw state (current font, origin stack) is **reset at the start of
every `on_frame`**, so a leaked `gfx.font` or missing `gfx.pop_origin` can't
bleed into the next frame.

---

## `snes` — memory & input

### Declaring watches

| Call | Returns | Description |
|---|---|---|
| `snes.watch(offset, size, priority?)` | watch id (int) | Watch `size` bytes at a **WRAM offset** (e.g. `0x0AF6`, the form SM authors use — not `0xF50AF6`). |
| `snes.watch_abs(fxpak_addr, size, priority?)` | watch id (int) | Watch a raw **FxPakPro address**, for ROM/SRAM outside WRAM. |

`priority?` is a string (default `"normal"`):

| Priority | Refresh | Use for |
|---|---|---|
| `"realtime"` (alias `"input"`) | dedicated tight sub-poll | controller, frame counter |
| `"high"` | every poll cycle | fast-moving values (position) |
| `"normal"` | ~every 3 cycles | health, ammo |
| `"low"` (alias `"prefetch"`) | ~every 12 cycles | rarely-changing room data |

Register watches **once** (in `on_init` or at file top level), never per
frame — re-registering each frame churns the registry.

### Reading watches

All readers take a watch id and return the value from the **latest
snapshot**, or `nil` if that watch hasn't been polled yet. Little-endian
(SNES native).

| Call | Returns |
|---|---|
| `snes.u8(id)` / `u16` / `u24` / `u32` | unsigned int, or `nil` |
| `snes.i8(id)` / `i16` / `i32` | signed int, or `nil` |
| `snes.bytes(id)` | array table `{ b0, b1, … }` (1-based), or `nil` |
| `snes.age(id)` | poll cycles since this watch last refreshed, or `nil` (never). Dim/flag stale data with it. |

```lua
local hp = snes.watch(0x09C2, 2, "normal")
function on_frame()
  local v = snes.u16(hp)
  if v then gfx.text(8, 8, ("Energy %d"):format(v)) end
end
```

### Controller input

`snes.buttons(watch_id)` decodes a 2-byte watch as a standard SNES pad.
Register a watch on the joypad-state address for your game (Super Metroid's
held-buttons mirror is WRAM `0x008B`) and tier it `"realtime"`.

Returns `nil` until the watch has data, else a table:

```
{ A, B, X, Y, L, R, Start, Select, Up, Down, Left, Right,  -- booleans
  raw }                                                     -- the u16
```

`raw` is provided for your own edge detection (compare to last frame's
`raw`). Bit layout decoded: bit 15..8 = `B Y Select Start Up Down Left
Right`, bit 7..4 = `A X L R`.

```lua
local pad = snes.watch(0x008B, 2, "realtime")
snes.tier(pad, "realtime")
function on_frame()
  local b = snes.buttons(pad)
  if b and b.Start then ... end
end
```

### Other

| Call | Description |
|---|---|
| `snes.tier(id, class)` | Raise a watch's priority (`"realtime"`/`"high"`/`"normal"`/`"low"`). Only ever *raises* urgency — an explicit hint wins over auto-classification. |
| `snes.write(fxpak_addr, value, size?)` | **Fire-and-forget** write. `size?` 1–4 (default 1), little-endian. Returns immediately; never blocks the frame; failures are logged, not surfaced per-call. |

---

## `gfx` — drawing

Retained mode: `gfx.*` calls push into a per-frame draw list the renderer
consumes. All coordinates are in the **active canvas** space (see
[canvas](#canvas--coordinate-space)); always read `gfx.width()` /
`gfx.height()` for layout — never hardcode 256/224. Colors are
`0xAARRGGBB` (see [Conventions](#conventions)); a `?` color defaults to
white for text/lines, green for shapes.

### Text

| Call | Description |
|---|---|
| `gfx.text(x, y, str, color?, opts?)` | Draw `str` at `(x, y)`. `\n` starts a new line at the original `x`. |
| `gfx.text_width(str)` | Pixel width of `str` in the current font (widest line). |
| `gfx.text_height(str?)` | Pixel height (line count × line advance; `nil`/omitted = one line). |
| `gfx.font(name)` | Typeface for subsequent `gfx.text` this frame: `"small"` (5×7, default) or `"normal"` (8×8). Resets to `"small"` each frame. |
| `gfx.text_sizing(mode, size)` | Request the app's initial Overlay text sizing for this script. `mode` is `"game"` or `"screen"`; `size` is the same value as the app's Text size slider. |

`gfx.text_sizing` is applied by the app once after the script loads. It gives a
script a sane default for its designed layout; users can still adjust the
Overlay controls afterwards.

`opts?` is **either a number** (per-label scale — the legacy 5th arg, still
works) **or a table**:

| Field | Meaning |
|---|---|
| `scale` | size multiplier (on top of the global overlay size) |
| `bg` | `0xAARRGGBB` — solid backing rect, auto-sized to the text + 1px pad |
| `outline` | `0xAARRGGBB` — 1px halo around every glyph (replaces the manual shadow double-draw) |

```lua
gfx.text(8, 8, "HP 99", 0xFFFFFFFF, { bg = 0xA0000000, outline = 0xFF000000 })
gfx.text(8, 8, "big", 0xFFFFFFFF, 2)   -- numeric = scale (back-compat)
gfx.text_sizing("game", 1.0)            -- script load default
local x = gfx.width() - gfx.text_width("right") - 4   -- right-align
```

### Shapes

`fill?` is an optional `0xAARRGGBB`; absent = outline only. `thickness?`
defaults to `1.0`.

| Call | Description |
|---|---|
| `gfx.pixel(x, y, color?)` | One canvas pixel (drawn as a scaled quad so it stays visible zoomed). |
| `gfx.line(x1, y1, x2, y2, color?, thickness?)` | Line segment. |
| `gfx.box(x, y, w, h, color?, fill?, thickness?)` | Rectangle (the hitbox primitive). |
| `gfx.circle(x, y, radius, color?, fill?, thickness?)` | `(x, y)` is the **centre**. |
| `gfx.triangle(x1, y1, x2, y2, x3, y3, color?, fill?, thickness?)` | Three points. |
| `gfx.poly(points, color?, fill?, thickness?, closed?)` | Polyline/polygon. `points` = `{ {x,y}, … }` or `{ {x=,y=}, … }`. `closed?` default `true` (joins last→first). `fill` requires `closed` and assumes **convex**. |
| `gfx.arc(x, y, radius, start_deg, end_deg, color?, fill?, thickness?)` | Arc centred at `(x, y)`. **Clockwise, 0° = east.** Full sweep (0→360) is a ring; with `fill` it's a pie slice from the centre. Good for radial timers / range cones. |

```lua
gfx.box(sx-8, sy-16, 16, 32, 0xFF00FF00, 0x2000FF00)   -- outlined + faint fill
gfx.poly({ {0,0}, {10,0}, {5,10} }, 0xFFFFFFFF, 0x40FFFFFF)
gfx.arc(40, 40, 16, -90, -90 + 360*frac, 0xFF40FF40, nil, 2)  -- progress ring
```

### Color

| Call | Returns |
|---|---|
| `gfx.argb(a, r, g, b)` | Pack four 0–255 channels → `0xAARRGGBB` int. |
| `gfx.color_lerp(a, b, t)` | Blend two packed colors per-channel (incl. alpha) by `t` (clamped 0..1). For health bars fading green→red, staleness dimming. |

### Canvas / coordinate space

The *canvas* is the script coordinate space, decoupled from on-screen size.
Default is native **256×224**. A higher-res canvas places sub-pixel detail
in the same screen area (only precision changes). The app may override the
script's request (user setting) — so always read the effective size back.

| Call | Description |
|---|---|
| `gfx.scale(n)` | Request native × `n` (e.g. `gfx.scale(2)` → 512×448). `n` clamped 1–8. |
| `gfx.canvas(w, h)` | Request an arbitrary canvas (clamped 16–4096). |
| `gfx.width()` / `gfx.height()` | The **effective** canvas size (after any app override). Always use these for layout. |

### Origin stack

`gfx.push_origin(x, y)` / `gfx.pop_origin()` — a nesting translate stack.
Every subsequent `gfx.*` coordinate is offset by the current origin
(nested pushes accumulate). Lets a widget be drawn in local coords and
placed once. The stack **resets every frame**, so a missing pop can't leak.

```lua
gfx.push_origin(100, 50)
  gfx.text(0, 0, "panel")          -- drawn at (100, 50)
  gfx.box(0, 10, 40, 8)            -- drawn at (100, 60)
gfx.pop_origin()
```

---

## `ui` — settings panel

A script can expose its own settings; the app renders them in a **Script**
tab (shown only when controls were declared, auto-selected on load).
Declare controls **once** (typically in `on_init`). Every control value
**auto-persists** via the per-script `store` and restores on reload — no
extra code.

### Declaring controls

| Call | Notes |
|---|---|
| `ui.header(text)` | Section heading (layout only). |
| `ui.label(text)` | Dimmed helper text (layout only). |
| `ui.checkbox(id, label, default?)` | Boolean. |
| `ui.slider(id, label, min, max, default?)` | Number; integer slider if bounds are whole. |
| `ui.text(id, label, default?)` | Single-line string. |
| `ui.color(id, label, default?)` | `0xAARRGGBB`, edited with a color picker. |
| `ui.select(id, label, options, default?)` | One-of. `options` is a string array; `default?` is a **1-based** index. |
| `ui.button(id, label)` | Momentary action. |

### Reading / writing

| Call | Returns / effect |
|---|---|
| `ui.get(id)` | Current value: bool / number / string per control; `select` returns its **1-based** index; `nil` if no such control. |
| `ui.pressed(id)` | `true` exactly once per click of button `id` (drains the latch). |
| `ui.set(id, value)` | Programmatically update a control (kept in sync with the panel; re-persisted). |
| `ui.exists(id)` | `true` if a control with `id` was declared. |

```lua
function on_init()
  ui.header("Hitbox")
  ui.checkbox("show", "Show box", true)
  ui.slider("thick", "Line width", 1, 6, 2)
  ui.color("col", "Box color", 0xFF40FF40)
  ui.select("mode", "Mode", { "off", "lo", "hi" }, 2)
  ui.button("reset", "Recenter")
end

function on_frame()
  if ui.get("show") then
    gfx.box(x, y, w, h, ui.get("col"), nil, ui.get("thick"))
  end
  if ui.pressed("reset") then cx, cy = 128, 112 end
end
```

---

## `store` — persistence

A per-script JSON document, **auto-saved** by the app (debounced, and on
exit) to a file keyed by the script's path so two scripts never collide.
Values must be JSON-able: nil / boolean / number / string / (nested)
table. `ui.*` control values live here too (under a reserved key — they
won't collide with your own keys).

| Call | Description |
|---|---|
| `store.get(key)` | Value, or `nil` if unset. |
| `store.set(key, value)` | Set a key. `value = nil` deletes it. |
| `store.delete(key)` | Remove a key. |
| `store.load()` | The whole document as a table. |
| `store.save(table)` | Replace the whole document. |

```lua
store.set("pb", 5423)
local pb = store.get("pb")               -- nil if unset
store.save({ pb = 5423, splits = { 61, 122 } })
```

Tables round-trip as JSON: a table with keys exactly `1..n` becomes a JSON
array, otherwise an object (non-string keys stringified). Numbers with no
fractional part come back as integers.

---

## `http` — networking

Async REST client. The call **returns immediately**; the optional callback
runs on a **later frame** (UI thread, VM idle — no re-entrancy). Any
method / host / headers are allowed (scripts are local and trusted).

| Call | Description |
|---|---|
| `http.get(url, opts_or_cb?, cb?)` | GET. |
| `http.delete(url, opts_or_cb?, cb?)` | DELETE. |
| `http.post(url, body?, opts?, cb?)` | POST; `body` is a string. |
| `http.put(url, body?, opts?, cb?)` | PUT; `body` is a string. |
| `http.request(method, url, opts?)` | Generic; the others wrap this. |
| `http.json(value)` | Encode a Lua value to a JSON string. |
| `http.parse(str)` | Decode a JSON string to a Lua value. |

`opts` table (all optional): `headers` (string→string table), `body`
(string), `timeout_ms` (default **15000**), `callback` (function). For
`get`/`delete` you may pass the callback function directly in place of
`opts`.

The callback receives one response table:

| Field | Meaning |
|---|---|
| `ok` | `false` only on transport/timeout failure; a 4xx/5xx is still `ok = true`. |
| `status` | HTTP status int (when `ok`). |
| `headers` | response headers (string→string table). |
| `body` | response body (string). |
| `error` | failure message (when `not ok`). |

```lua
http.get("https://api.example.com/run", function(r)
  if r.ok then
    local data = http.parse(r.body)
    log.info("run", data.id)
  else
    log.warn("fetch failed:", r.error)
  end
end)

http.post(url, http.json({ run = 1 }),
          { headers = { ["content-type"] = "application/json" } },
          function(r) ... end)
```

Concurrency is capped at **16 in-flight requests**; calls past the cap are
dropped with a console warning rather than spawning unbounded sockets.

---

## `time` — clock

Monotonic only — no wall clock or date (the sandbox stays tight; use
`http` to a server if you need real timestamps).

| Call | Returns |
|---|---|
| `time.now()` | Seconds (float) since the script loaded. |
| `time.frame()` | Overlay frame counter (increments once per `on_frame`; `0` before the first). |
| `time.dt()` | Wall seconds since the previous frame (for velocity / frame-rate-independent motion). |

```lua
local v = dist / time.dt()
if time.frame() % 30 == 0 then blink() end
```

---

## `log` / `print` — console

Output to the in-app console (collapsible bottom panel). Multiple args are
tab-joined; non-strings are debug-formatted.

| Call | Console line |
|---|---|
| `print(...)` | same as `log.info` |
| `log.info(...)` | `…` |
| `log.warn(...)` | `[warn] …` |
| `log.error(...)` | `[error] …` |

---

## `anim` — tweening & oscillators

Pure-Lua helpers so scripts stop hand-rolling `math.sin(time.now()*k)`.
`t` is a 0..1 progress (clamped where noted).

| Call | Returns |
|---|---|
| `anim.lerp(a, b, t)` | `a + (b-a)*t`, `t` clamped 0..1. |
| `anim.clamp(v, lo, hi)` | `v` clamped to `[lo, hi]`. |
| `anim.ease(t, name)` | Shaped `t` (clamped 0..1). `name`: `linear`, `in_quad`, `out_quad`, `inout_quad`, `in_cubic`, `out_cubic`, `smooth`. Unknown name = linear. |
| `anim.pulse(hz?, phase?)` | 0..1 sine, `hz` cycles/sec (default 1). |
| `anim.blink(period?)` | `true` for the first half of each `period`-sec cycle (default 1). |
| `anim.saw(period?)` | 0..1 sawtooth over `period` sec (default 1). |

```lua
local x = anim.lerp(8, 200, anim.ease(anim.saw(2), "inout_quad"))
local r = 6 + 5 * anim.pulse(1.5)
if anim.blink(0.5) then gfx.text(8, 8, "!", 0xFFFF4040) end
```

---

## Conventions

- **Colors** are packed `0xAARRGGBB` ints: `0xFF` alpha = opaque, `0x00` =
  transparent. `0xFF40FF40` is opaque light green. Build them with
  `gfx.argb(a,r,g,b)`, blend with `gfx.color_lerp`.
- **Coordinates** are floats in the active canvas space. `(0,0)` is
  top-left. Drawing is **clipped to the canvas rect** (matching emulator
  Lua surfaces — scripts may deliberately over-draw the edges).
- **Watch ids** are opaque ints from `snes.watch*`; pass them to the
  readers. Don't synthesize them.
- **Reads can be `nil`** until the first poll for that watch — always guard
  the opening frames.
- **Nothing blocks the frame.** `snes.write` and `http.*` are
  fire-and-forget / async; reads are cached. There is no synchronous SNI
  call by design.

### Example scripts

| File | Shows |
|---|---|
| `examples/sm_hud.lua` | watches, cached reads, basic HUD + hitbox |
| `examples/hires_grid.lua` | `gfx.scale` higher-res canvas |
| `examples/controls_demo.lua` | full `ui.*` settings panel |
| `examples/store_http_demo.lua` | `store` + async `http` |
| `examples/new_api_demo.lua` | `time`, `log`, `snes.buttons`, signed reads, origin, `on_unload` |
| `examples/draw_anim_demo.lua` | text bg/outline, `poly`, `arc`, `color_lerp`, `anim.*` |
| `examples/animated_input_viewer.lua` | animated SNES controller/input viewer with glow, ripples, history, and settings |
| `examples/sm_stream_overlay.lua` | viewer-facing stream telemetry: room splits, boss timers, RNG proxy |
| `examples/super_hitbox_sni.lua` | a real 4500-line ported Super Metroid script |
