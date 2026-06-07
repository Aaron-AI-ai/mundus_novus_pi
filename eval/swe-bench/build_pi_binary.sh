#!/usr/bin/env bash
# Cross-compile a standalone linux `pi` binary for injection into SWE-bench Docker containers.
# Output: eval/swe-bench/bin/pi-linux-<arch>
#
# SWE-bench official images are x86_64, and run_evaluation defaults to x86_64, so we build
# x86_64 by default (it runs under emulation on Apple Silicon, consistent with the eval step).
set -euo pipefail

ARCH="${1:-x86_64}"   # x86_64 | arm64
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CA="$REPO_ROOT/packages/coding-agent"
OUT_DIR="$(dirname "$0")/bin"
mkdir -p "$OUT_DIR"

case "$ARCH" in
  x86_64) TARGET="bun-linux-x64";   OUT="$OUT_DIR/pi-linux-x86_64" ;;
  arm64)  TARGET="bun-linux-arm64"; OUT="$OUT_DIR/pi-linux-arm64" ;;
  *) echo "unknown arch: $ARCH (use x86_64 or arm64)"; exit 1 ;;
esac

echo "Building pi for $ARCH ($TARGET)..."
( cd "$REPO_ROOT" && npm run build )                 # ensure dist/bun/cli.js is fresh
( cd "$CA" && bun build --compile --target="$TARGET" ./dist/bun/cli.js --outfile "$REPO_ROOT/eval/swe-bench/${OUT#./}" 2>/dev/null \
  || bun build --compile --target="$TARGET" ./dist/bun/cli.js --outfile "$OUT" )
echo "Wrote $OUT"
file "$OUT" || true
