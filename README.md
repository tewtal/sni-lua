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
| M2 | SNI gRPC client: connect, list devices, single/multi read | ⏳ |
| M3 | Watch registry, snapshot cache, async poll engine | ⏳ |
| M4 | Unified async-aware Lua API (`snes.*`, `gfx.*`, `frame`) | ⏳ |
| M5 | Overlay renderer (text, rect, line, hitbox) | ⏳ |
| M6 | Capture modes: composited + transparent click-through | ⏳ |

## Build & run

```sh
cargo run --release
```

Requires a C compiler/toolchain for the vendored LuaJIT build (MSVC on
Windows). First build is slow (gRPC + eframe + LuaJIT); subsequent builds are
incremental.

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
