# sni-lua

Lua overlay scripting for SNES games over **SNI** (Super Nintendo Interface) /
USB2SNES — like the Lua scripting in Mesen or BizHawk, but driving real
hardware (FXPAK/SD2SNES) or emulators through SNI's gRPC API.

A capture device provides the video background; Lua scripts draw text labels,
hitboxes, and other overlays on top.

## Why this is non-trivial

SNI talking to FXPAK hardware has **limited bandwidth and real latency**. You
cannot synchronously read memory every frame like an emulator Lua script does.
sni-lua is built around that constraint:

- Scripts declare **watches** (regions of interest) instead of reading inline.
- A background poll engine **coalesces all watches into batched `MultiRead`**
  gRPC calls and publishes immutable **snapshots**.
- Script reads hit the **latest cached snapshot** and never block on I/O.
- Per-watch **priority** spends the bandwidth budget where it matters
  (high-rate hitbox data vs. rarely-changing room metadata / prefetch).

## Stack

- **Rust** + **egui/wgpu** (low-latency native rendering)
- **tonic** gRPC client generated from SNI's `sni.proto` (vendored `protoc`,
  no system dependency)
- **LuaJIT** via `mlua` (vendored)
- Demo target: **Super Metroid**

## Status — incremental build

| Milestone | Scope | State |
|-----------|-------|-------|
| M1 | Workspace, egui/wgpu window, config, LuaJIT smoke test | ✅ |
| M2 | SNI gRPC client: connect, list devices, single/multi read | ✅ |
| M3 | Watch registry, snapshot cache, async poll engine | ✅ |
| M4 | Unified async-aware Lua API (`snes.*`, `gfx.*`, lifecycle) | ✅ |
| M5 | Overlay renderer (text, rect, line, hitbox; 5x7 + 8x8 fonts) | ✅ |
| M6 | Capture modes: composited + transparent click-through + streaming output | ✅ |
| M7 | Tabbed UI + file dialog; script `store.*` / async `http.*` / `ui.*` settings panel | ✅ |

## Build & run

Use the wrapper scripts — they set the one environment bit the vendored
LuaJIT build needs on Windows (see `build.cmd` header for why):

```sh
.\build.ps1 run --release      # PowerShell
.\build.cmd run --release      # cmd
```

Requires the MSVC toolchain (the `cc` crate finds it via the registry; no
vcvars shell needed). First build is slow (gRPC + eframe + LuaJIT);
subsequent builds are incremental.

### Using the app

The left panel is tabbed so the everyday view stays uncluttered:

* **Setup** — pick a script (**Browse…** opens a native file dialog), Load /
  Reload, choose the SNI device, and the common Overlay knobs (text size,
  canvas). This is all most users ever need.
* **Script** — appears only when the loaded script declared a settings panel
  via `ui.*` (see below); auto-selected on load.
* **Capture** — the capture mode/device/crop/streaming controls.
* **Debug** — the live memory probe and the full poll-engine telemetry. Hidden
  by default; nothing here is required for normal use.

The console (script `print` + errors) is a collapsible bottom panel toggled
from **Setup → Show console**.

### Overlay text

Scripts draw with two embedded pixel fonts: a compact **5x7** (default) and
the classic **8x8** (`gfx.font("normal")`). Size is controlled per-label via
the `gfx.text` scale arg, and globally via **Overlay → Text size** plus a
sizing mode: *game-scaled* (zooms with the view, pixel-aligned) or *fixed
screen px* (constant on-screen size). Settings persist.

### Render resolution (canvas)

The *canvas* is the coordinate space scripts draw into, decoupled from
on-screen size. Default is native 256x224; a higher-res canvas lets scripts
place sub-SNES-pixel detail and crisper HUDs (it occupies the same screen
area — only precision changes).

* Scripts: `gfx.scale(2)` (→512x448), `gfx.canvas(w, h)` (custom).
  Always read `gfx.width()` / `gfx.height()` for layout — never hardcode
  256/224, since the app may override the canvas.
* App: **Overlay → Canvas** = *Script-controlled* (honor the script) or a
  forced *Native / 2x / 3x / 4x*. Persisted.

See `examples/hires_grid.lua` for a 2x demo.

> Note: there is intentionally no supersampling/AA knob — the overlay is
> deliberately crisp pixel art; canvas resolution is the higher-res lever.

### Persistence & HTTP (`store.*`, `http.*`)

Scripts can keep state across runs and talk to a REST API without ever
blocking the frame — the same async discipline as `snes.*`.

**`store`** — a per-script JSON document, auto-saved by the app (debounced,
and on exit) to a file keyed by the script's path, so two scripts never
collide:

```lua
store.set("pb", 5423)          -- key/value; value is any JSON-able Lua value
local pb = store.get("pb")     -- nil if unset
store.delete("pb")
local all = store.load()       -- whole document as a table
store.save({ pb = 5423, splits = { 61, 122 } })   -- replace it wholesale
```

**`http`** — async; the call returns immediately and your callback runs on a
later frame (UI thread, VM idle — no re-entrancy):

```lua
http.get("https://api.example.com/runs", function(r)
  if r.ok then print(r.status, r.body) end   -- r: { ok,status,headers,body,error }
end)
http.post(url, http.json({ run = 1 }),
          { headers = { ["content-type"] = "application/json" } },
          function(r) ... end)
-- http.put / http.delete likewise; http.parse(str) decodes JSON to a table.
```

`r.ok` is false only on a transport/timeout failure (see `r.error`); a 4xx/5xx
response still has `ok = true` with `r.status` set. Any method/host/headers are
allowed — scripts are local and trusted. See `examples/store_http_demo.lua`.

### Script settings panel (`ui.*`)

A script can expose its own settings so users tweak behaviour without editing
Lua. Declare controls once (typically in `on_init`); the app renders them in a
**Script** tab that appears *only* when a script declares some (and is
auto-selected on load). Read the live value any frame with `ui.get(id)`. Every
value auto-persists via the per-script store and restores on reload — no extra
code.

```lua
function on_init()
  ui.header("Hitbox")
  ui.checkbox("show",  "Show box",   true)
  ui.slider("thick",   "Line width", 1, 6, 2)        -- min, max, default
  ui.color("col",      "Box color",  0xFF40FF40)     -- 0xAARRGGBB
  ui.select("mode",    "Mode", { "off", "lo", "hi" }, 2)  -- 1-based
  ui.text("label",     "Caption",    "hello")
  ui.button("reset",   "Recenter")
  ui.label("Free-standing helper text.")
end

function on_frame()
  if ui.get("show") then
    gfx.box(x, y, w, h, ui.get("col"), nil, ui.get("thick"))
  end
  if ui.pressed("reset") then ... end   -- true once per click
end
```

`ui.get(id)` returns bool / number / string per control (`select` returns its
1-based index); `ui.pressed(id)` drains a button's one-shot click; `ui.set(id,
v)` updates a control programmatically. Header/label are layout-only. See
`examples/controls_demo.lua`.

### Capture background

**Capture → Mode** selects how the game video gets behind the overlay:

* **Composited** — the app opens a capture device (HDMI/USB capture card;
  these enumerate as webcam-class devices) and draws the overlay on top
  in-window. Pick the device under **Capture → Device**; *Rescan* re-enumerates.
  The **Input** controls request a width, height, and FPS from the capture
  card (`0` means auto), and **Crop** trims source pixels before the video is
  scaled into the active canvas.
  Capture runs on a background thread holding only the newest frame
  (latest-wins, stale dropped) so a slow device read never stalls the
  overlay — the same non-blocking philosophy as the SNI pipeline.
* **Transparent overlay** — the app becomes a borderless, transparent,
  always-on-top window. Place it over your own capture software (OBS, etc.);
  no device is opened. Click-through mouse input is optional and can be turned
  off with `Ctrl+Shift+F10` if the window needs to become interactive again.
* **Streaming output** — the app keeps its normal controls window, and also
  opens a detached `sni-lua stream output` window containing only the overlay
  over a solid user-selectable key color (default `#FF00FF`). Capture that
  window directly in OBS (or similar) and chroma-key the background out. You
  can also hide the in-app preview while leaving the detached output live. No
  capture device is opened in this mode.

Caveats: the explicit click-through fallback uses Win32
`WS_EX_TRANSPARENT|WS_EX_LAYERED` and is **Windows-only**. Some capture cards
expose only certain resolutions/FPS; when a requested input format is not
available, the closest compatible decoded format is selected.

### The ported Super Hitbox script

`examples/super_hitbox_sni.lua` is a real 4500-line Super Metroid
hitbox/route-assist script (originally a Mesen2 script) running natively over
SNI. It is a **single hand-maintained file**: edit it (or the two adapter
parts) directly.

The script's body already abstracts every emulator touchpoint behind its own
`xemu` table. A thin sni-lua-native **adapter** binds that table *directly* to
sni-lua's async `snes`/`gfx` API — one honest SNES-CPU→memory-region address
map and one colour conversion, no fake-`emu` indirection. The essential part
is the *read-through cache*: the body reads synchronously thousands of times
per frame, but sni-lua has no synchronous read (the FXPAK is latency-bound).
The adapter turns each read into a cache lookup that, on a miss, lazily
registers a watch — so within a few frames every address the script touches
is batched by the poll engine automatically, and the synchronous-looking code
"just works" on the async model.

The adapter has two parts in `examples/compat/`
(`super_hitbox_adapter.lua` = pre-CONFIG: address map, cache, reads/writes,
tiers, minimal `emu`; `super_hitbox_adapter_part2.lua` = post-CONFIG: colour +
draw + draw-surface). The body routes its bit ops through `xemu.*`, which the
adapter points at LuaJIT's `bit.*`, so the body needs **no source patching**.
`examples/compat/build_super_hitbox.lua` re-assembles the single file from
`[adapter part 1] + [upstream CONFIG] + [adapter part 2] + [upstream body]`
when you re-sync an upstream drop; it fails loudly if upstream moved a splice
boundary.

## Layout

```
crates/
  sni-client/    gRPC client + MemRegion abstraction        (M2)
  sni-cache/     watch registry, snapshot, poll engine       (M3)
  sni-lua-api/   LuaJIT host + snes/gfx API                  (M4)
  sni-render/    retained draw-list + egui painter           (M5)
  sni-capture/   capture device backends                     (M6)
  sni-lua-app/   binary: wires it all together + UI
proto/sni.proto  vendored SNI protocol definition
examples/        Super Metroid scripts
```
