#!/usr/bin/env bash
# Cross-compile a standalone linux `pi` binary for injection into SWE-bench containers.
# Output: eval/swe-bench/bin/pi-linux-<arch>
#
# Note: the build is judged by the emitted artifact, not the exit code — tsgo emits JS even
# when it reports a type error (returns 1). A fresh `npm install` resolves the known type
# warnings; if dist/bun/cli.js is missing afterwards, that's a real failure.
set -uo pipefail

ARCH="${1:-arm64}"   # arm64 | x86_64
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
CA="$REPO_ROOT/packages/coding-agent"
OUT_DIR="$HERE/bin"
mkdir -p "$OUT_DIR"

case "$ARCH" in
  x86_64|amd64)  TARGET="bun-linux-x64";   OUT="$OUT_DIR/pi-linux-x86_64" ;;
  arm64|aarch64) TARGET="bun-linux-arm64"; OUT="$OUT_DIR/pi-linux-arm64" ;;
  *) echo "unknown arch: $ARCH (use x86_64 or arm64)"; exit 1 ;;
esac

echo "Building pi (npm run build)..."
( cd "$REPO_ROOT" && npm run build ) || echo "[warn] npm run build returned non-zero; verifying emitted output..."
[ -f "$CA/dist/bun/cli.js" ] || {
  echo "ERROR: build did not emit dist/bun/cli.js."
  echo "  Run 'npm install' at the repo root and retry."
  exit 1
}

echo "Cross-compiling $ARCH ($TARGET) -> $OUT"
( cd "$CA" && bun build --compile --target="$TARGET" ./dist/bun/cli.js --outfile "$OUT" )
[ -f "$OUT" ] || { echo "ERROR: bun compile did not produce $OUT"; exit 1; }
echo "Wrote $OUT"
file "$OUT" || true
