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
| M8 | API round-out: `time.*`, `log.*`, `snes.buttons`/signed reads, `gfx` circle/triangle/metrics/origin, `on_unload` | ✅ |
| M9 | Drawing/anim helpers: text bg+outline, `gfx.poly`/`arc`/`color_lerp`, `anim.*` easing/oscillators | ✅ |

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

### Overlay text & canvas (app side)

The app has global overrides that sit on top of what a script requests
(API details for the script side are in [`docs/SCRIPTING.md`](docs/SCRIPTING.md)):

* **Overlay → Text size** + sizing mode: *game-scaled* (zooms with the view,
  pixel-aligned) or *fixed screen px* (constant on-screen size). Scripts can
  request their intended load-time default with `gfx.text_sizing(...)`; the
  app controls still let the user adjust it afterwards.
* **Overlay → Canvas**: *Script-controlled* (honor the script's
  `gfx.scale`/`canvas`) or a forced *Native / 2x / 3x / 4x*. The *canvas* is
  the script's coordinate space, decoupled from on-screen size — a higher-res
  canvas adds precision in the same screen area.

Both persist. There is intentionally no supersampling/AA knob — the overlay
is deliberately crisp pixel art; canvas resolution is the higher-res lever.

### Writing scripts

A script is a Lua file with optional `on_init` / `on_frame` / `on_unload`
functions. It declares **watches** on memory, reads the latest cached
snapshot each frame, and emits retained `gfx.*` draw calls — nothing ever
blocks the frame (see [why](#why-this-is-non-trivial)).

**→ The complete, precise API reference is [`docs/SCRIPTING.md`](docs/SCRIPTING.md).**

It documents every call with signatures, defaults and return types:

| Table | What |
|---|---|
| `snes` | declare watches, typed/signed reads, `snes.buttons` input, `snes.write` |
| `gfx` | text (with bg/outline), box/line/circle/triangle/poly/arc, canvas, origin stack, `color_lerp` |
| `ui` | script-declared settings panel (auto-persisted, shown in the **Script** tab) |
| `store` | per-script JSON persistence (auto-saved) |
| `http` | async REST (`get/post/put/delete`, JSON helpers, callback on a later frame) |
| `time` | monotonic clock / frame counter / dt |
| `log` | levelled console output |
| `anim` | tweening + easing + time-driven oscillators |

A short tour by example:

```lua
local hp = snes.watch(0x09C2, 2, "normal")   -- WRAM offset, size, priority

function on_init()
  ui.slider("scale", "HUD size", 1, 4, 1)    -- a user-tweakable setting
end

function on_frame()
  local v = snes.u16(hp)                      -- cached read; nil until polled
  if v then
    gfx.text(8, 8, ("Energy %d"):format(v), 0xFFFFFFFF,
             { bg = 0xA0000000, scale = ui.get("scale") })
  end
end
```

The runnable demos in `examples/` each focus on one area — see the table at
the bottom of [`docs/SCRIPTING.md`](docs/SCRIPTING.md#example-scripts).

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

Part 2 also surfaces the most-used Any% Glitched toggles (RAM dashboard,
route highlights, warnings, PLM/freeze, etc.) plus overlay opacity as `ui.*`
controls, so they appear in the app's **Script** tab and can be flipped live
without editing the file. Only settings the body reads fresh each frame are
exposed; the block-viewer scale/layout (captured into body-locals once at
load) stays file-edited. Defaults mirror the verbatim upstream `CONFIG`; the
user's saved choices override on reload.

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
docs/SCRIPTING.md  complete Lua scripting API reference
examples/        Super Metroid scripts
```
