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

## Features

- **SNI gRPC client** — connect, enumerate devices, memory-mapping
  detection; works against real hardware (FXPAK/SD2SNES) or any
  SNI-compatible emulator.
- **Async poll engine** — watch registry, immutable snapshot cache, batched
  `MultiRead`, per-watch priority, demand-based eviction, adaptive bandwidth
  budget. Scripts never block on I/O.
- **Full Lua scripting API** — memory (`snes.*`, typed/signed reads,
  controller decode), retained drawing (`gfx.*`: text with bg/outline,
  shapes incl. circle/triangle/poly/arc, origin stack, colour lerp),
  persistence (`store.*`), async HTTP (`http.*`), timing (`time.*`),
  logging (`log.*`), tweening (`anim.*`), and a script-declared settings
  panel (`ui.*`). See [`docs/SCRIPTING.md`](docs/SCRIPTING.md).
- **Overlay renderer** — crisp pixel-art text (5×7 + 8×8 fonts),
  script-controlled or app-forced canvas resolution.
- **Output modes** — composited (capture device drawn in-app with the
  overlay on top) or an integer-scaled chroma-key view for OBS, in a
  detached window or the main window.
- **Tabbed desktop UI** — native file dialog, live memory probe, poll-engine
  telemetry, and the per-script settings panel.

## Install

Pre-built, ready-to-run archives for Windows, macOS, and Linux are attached
to each [GitHub Release](../../releases): unzip/untar and run the `sni-lua`
binary — the `examples/` and `docs/` it ships with sit next to it.

## Build from source

Use the wrapper scripts — they set the one environment bit the vendored
LuaJIT build needs on Windows (see `build.cmd` header for why):

```sh
.\build.ps1 run --release      # PowerShell
.\build.cmd run --release      # cmd
```

On macOS/Linux just use `cargo` directly (see build-time system deps in
[`docs/PACKAGING.md`](docs/PACKAGING.md)). Requires the MSVC toolchain on
Windows (the `cc` crate finds it via the registry; no vcvars shell needed).
First build is slow (gRPC + eframe + LuaJIT); subsequent builds are
incremental.

To produce a distributable archive yourself, run `scripts/package.ps1`
(Windows) or `scripts/package.sh` (macOS/Linux); see
[`docs/PACKAGING.md`](docs/PACKAGING.md) for the release process and
platform caveats.

### Using the app

The left panel is tabbed so the everyday view stays uncluttered:

* **Setup** — pick a script (**Browse…** opens a native file dialog), Load /
  Reload, choose the SNI device, the common Overlay knobs (text size,
  canvas), and the **Output** mode (composited vs. streaming window). This
  is all most users ever need.
* **Script** — appears only when the loaded script declared a settings panel
  via `ui.*` (see below); auto-selected on load.
* **Output** — tuning for the chosen output mode: capture device / input /
  crop (composited), or key colour and window scale (streaming).
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

### Output modes

**Setup → Output → Mode** selects how the overlay reaches the screen; the
**Output** tab tunes the active mode.

* **Composited** — the app opens a capture device (HDMI/USB capture card;
  these enumerate as webcam-class devices) and draws the overlay on top
  in-window. Pick the device under **Output → Device**; *Rescan* re-enumerates.
  The **Input** controls request a width, height, and FPS from the capture
  card (`0` means auto), and **Crop** trims source pixels before the video is
  scaled into the active canvas.
  Capture runs on a background thread holding only the newest frame
  (latest-wins, stale dropped) so a slow device read never stalls the
  overlay — the same non-blocking philosophy as the SNI pipeline.
* **Streaming window** — the overlay is rendered over a solid
  user-selectable key colour (default `#FF00FF`) for chroma-keying in OBS.
  By default this goes to a detached `sni-lua stream output` window sized to
  an **integer multiple of the script's canvas** (pixel-perfect for the
  keyer); under **Output → Stream window** you can fix the scale manually
  (still integer — a fractional scale would blur the pixel-art overlay) and
  optionally hide the in-app preview. Or untick **Detached window** to skip
  the extra window entirely and capture the keyed output straight from the
  main app window.

Some capture cards expose only certain resolutions/FPS; when a requested
input format is not available, the closest compatible decoded format is
selected.

### The Super Hitbox script

`examples/super_hitbox_sni.lua` is a fully featured, 4500-line Super Metroid hitbox and route-assist script running natively over SNI. 

It exposes a rich, async-optimized integration with Super Metroid:
- **Read-Through Cache**: Operates cleanly within the script body by hitting a high-performance read-through cache backed by the `sni-cache` background poll engine, ensuring lag-free execution.
- **Interactive Settings Panel**: Surfaces the most-used Any% Glitched toggles (RAM dashboard, route highlights, warnings, PLM/freeze, etc.) plus overlay opacity as `ui.*` controls, which appear dynamically in the app's **Script** tab and can be flipped live without editing the script file.

## Layout

```
crates/
  sni-client/      gRPC client + MemRegion abstraction
  sni-cache/       watch registry, snapshot, poll engine
  sni-lua-api/     LuaJIT host + snes/gfx/ui/store/http API
  sni-render/      retained draw-list + egui painter
  sni-capture/     capture device backends
  sni-lua-app/     binary: wires it all together + UI
proto/sni.proto    vendored SNI protocol definition
docs/SCRIPTING.md  complete Lua scripting API reference
examples/          example overlay scripts (Super Metroid)
```

## License

MIT — see [`LICENSE`](LICENSE).
