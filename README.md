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
| M6 | Capture modes: composited + transparent click-through | ✅ |

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

### Capture background

**Capture → Mode** selects how the game video gets behind the overlay:

* **Composited** — the app opens a capture device (HDMI/USB capture card;
  these enumerate as webcam-class devices) and draws the overlay on top
  in-window. Pick the device under **Capture → Device**; *Rescan* re-enumerates.
  Capture runs on a background thread holding only the newest frame
  (latest-wins, stale dropped) so a slow device read never stalls the
  overlay — the same non-blocking philosophy as the SNI pipeline.
* **Transparent overlay** — the app becomes a borderless, transparent,
  always-on-top, **click-through** window. Place it over your own capture
  software (OBS, etc.); no device is opened. Switching mode is live, but the
  borderless/transparent *window style* is decided at launch, so **restart
  the app after switching to/from transparent mode** for the window itself to
  change (click-through styling is applied live).

Caveats: click-through uses Win32 `WS_EX_TRANSPARENT|WS_EX_LAYERED` and is
**Windows-only** — other platforms run composited fine but the transparent
window won't be click-through (logged on startup). Some capture cards expose
only certain resolutions/FPS; the highest-FPS format is requested.

### Running existing Mesen2 scripts

`examples/compat/mesen2_prelude.lua` is a compatibility shim that defines a
fake Mesen2 `emu` API on top of sni-lua's async `snes`/`gfx` API, so an
**unmodified Mesen2 SNES script** can run over SNI. The interesting part is
the *read-through cache*: Mesen2's `emu.read()` is synchronous and instant,
but sni-lua has no synchronous read (the FXPAK is latency-bound). The shim
turns each `emu.read(addr)` into a cache lookup that, on a miss, lazily
registers a watch — so within a few frames every address the script touches
is being batched by the poll engine automatically. The foreign script's
synchronous-looking code "just works" on the async model.

`examples/super_hitbox_sni.lua` is a real 4500-line Mesen2 hitbox/route
script ported this way (prelude + the original body, with its six Lua-5.3
bitwise-operator helper lines rewritten to LuaJIT's `bit.*` — LuaJIT is
5.1-based). Regenerate it with `examples/compat/build_super_hitbox.lua` if
you update the upstream script.

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
