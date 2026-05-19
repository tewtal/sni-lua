#!/usr/bin/env bash
# Build and package a ready-to-run sni-lua release for the host OS.
#
# Produces  dist/sni-lua-<version>-<os>-<arch>.tar.gz  containing the
# stripped release binary plus examples, docs, README and LICENSE.
#
# Usage (from anywhere; runs against the repo root):
#   ./scripts/package.sh
#   ./scripts/package.sh 0.1.0          # override the inferred version
#
# Build-time system deps:
#   Linux:  libgtk-3-dev (rfd file dialog) and libv4l-dev / libudev-dev
#           (nokhwa V4L2 capture). Install before running, e.g.:
#             sudo apt-get install -y libgtk-3-dev libv4l-dev libudev-dev
#   macOS:  Xcode command-line tools (AVFoundation ships with the SDK).
#
# This builds natively for the host; cross-compiling is intentionally not
# attempted (vendored LuaJIT + native capture/GTK make it unreliable).

set -euo pipefail

# cd to the repo root (parent of scripts/).
cd "$(dirname "$0")/.."

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    # First top-level version = "x.y.z" in Cargo.toml ([workspace.package]).
    VERSION="$(grep -m1 -E '^\s*version\s*=\s*"' Cargo.toml | sed -E 's/.*"([^"]+)".*/\1/')"
    [[ -n "$VERSION" ]] || { echo "could not infer version; pass it as arg 1" >&2; exit 1; }
fi

case "$(uname -s)" in
    Darwin) OS="macos" ;;
    Linux)  OS="linux" ;;
    *)      echo "unsupported OS: $(uname -s) (use package.ps1 on Windows)" >&2; exit 1 ;;
esac

case "$(uname -m)" in
    x86_64|amd64)  ARCH="x86_64" ;;
    arm64|aarch64) ARCH="aarch64" ;;
    *)             ARCH="$(uname -m)" ;;
esac

NAME="sni-lua-${VERSION}-${OS}-${ARCH}"
STAGING="dist/${NAME}"

echo "Building sni-lua ${VERSION} (release, host ${OS}/${ARCH})..."
cargo build --release --bin sni-lua

BIN="target/release/sni-lua"
[[ -f "$BIN" ]] || { echo "expected binary not found: $BIN" >&2; exit 1; }

echo "Staging ${STAGING} ..."
rm -rf "$STAGING"
mkdir -p "$STAGING/docs"

cp "$BIN"               "$STAGING/sni-lua"
cp README.md LICENSE    "$STAGING/"
cp -R examples          "$STAGING/examples"
cp docs/SCRIPTING.md    "$STAGING/docs/"

# Ship only runnable scripts. The verbatim upstream source and compat/
# re-sync tooling are maintenance artifacts; users run super_hitbox_sni.lua.
rm -f  "$STAGING/examples/Super_Hitbox_Mesen2_AnyG_route_assist_polished.lua"
rm -rf "$STAGING/examples/compat"

chmod +x "$STAGING/sni-lua"

TARBALL="dist/${NAME}.tar.gz"
echo "Compressing ${TARBALL} ..."
rm -f "$TARBALL"
# -C so the archive has a single top-level NAME/ directory.
tar -czf "$TARBALL" -C dist "$NAME"

SIZE="$(du -h "$TARBALL" | cut -f1)"
echo "Done: ${TARBALL} (${SIZE})"
