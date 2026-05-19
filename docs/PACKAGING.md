# Packaging & releases

How `sni-lua` is built into a distributable, ready-to-run archive for
Windows, macOS, and Linux.

## What a release archive contains

```
sni-lua-<version>-<os>-<arch>/
  sni-lua[.exe]        stripped release binary
  README.md
  LICENSE
  docs/SCRIPTING.md    full scripting API reference
  examples/            runnable overlay scripts
```

Users run the `examples/super_hitbox_sni.lua` script natively.

Archive format: `.zip` on Windows, `.tar.gz` on macOS/Linux. The binary is
stripped (`strip = true` in the release profile) with thin LTO.

## Cutting a release (CI — recommended)

Releases build natively on a GitHub Actions runner per OS (cross-compiling
the vendored LuaJIT plus native capture/GTK is unreliable, so it isn't
attempted).

```sh
# from a clean main with the version bumped in Cargo.toml:
git tag v0.1.0
git push origin v0.1.0
```

`.github/workflows/release.yml` then:

1. builds + packages on `windows-latest`, `macos-latest`, `ubuntu-latest`
   (Linux installs `libgtk-3-dev libv4l-dev libudev-dev` first),
2. attaches all three archives to a single GitHub Release for the tag,
   with auto-generated release notes.

`.github/workflows/ci.yml` runs `fmt --check`, `clippy -D warnings`, the
test suite, and a release build on every push/PR across all three OSes, so a
tag should only ever be cut from already-green `main`.

## Cutting a release (local — no GitHub needed)

Run the script for your OS from the repo root. It builds `--release` and
writes the archive to `dist/`.

**Windows** (MSVC toolchain; no vcvars shell needed):

```powershell
.\scripts\package.ps1
.\scripts\package.ps1 -Version 0.1.0   # override inferred version
```

**macOS / Linux**:

```sh
./scripts/package.sh
./scripts/package.sh 0.1.0             # override inferred version
```

To produce all three you must run the matching script on each OS (a
Windows machine/VM, a Mac, and a Linux box) — there is no cross-compile path.

## Build-time system dependencies

| OS | Needs | Notes |
|---|---|---|
| Windows | MSVC toolchain | The `cc` crate finds it via the registry; the scripts/`build.*` wrappers unset `NoDefaultCurrentDirectoryInExePath` so the vendored LuaJIT build can run its freshly built `minilua`. |
| macOS | Xcode command-line tools | AVFoundation (capture) ships with the SDK. |
| Linux | `libgtk-3-dev`, `libv4l-dev`, `libudev-dev` | GTK3 backs the `rfd` file dialog; V4L2/udev back `nokhwa` capture. `sudo apt-get install -y libgtk-3-dev libv4l-dev libudev-dev` |

The Rust toolchain is stable (workspace MSRV `1.80`).

## Platform support & known limitations

`sni-lua` runs on all three platforms with no by-design feature gaps —
both output modes (composited capture and the detached streaming window)
work everywhere. The only platform differences are capture-runtime deps:

- **Linux capture** needs `libv4l` present at runtime (in addition to the
  build-time dev package) for HDMI/USB capture cards to enumerate.
- **macOS** may prompt for camera permission the first time a capture
  device is opened (capture cards appear as webcam-class devices).
- The vendored LuaJIT and SNI gRPC pipeline are identical across all
  platforms — scripts behave the same everywhere.

## Versioning

The version comes from `[workspace.package].version` in the root
`Cargo.toml`. Bump it there before tagging; the packaging scripts and the
release archive name derive from it (override with the script argument only
for ad-hoc local builds).
