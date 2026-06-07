#!/usr/bin/env bash
# End-to-end run for ONE SWE-bench Lite instance: inference (patch) + official evaluation (score).
#
#   ./run_smoke.sh                                   # defaults: flask-4992 + qwen3.6-27b
#   ./run_smoke.sh <instance_id> <model>             # e.g. ./run_smoke.sh psf__requests-3362 anthropic/claude-opus-4.8
#   PROVIDER=openrouter RUN_ID=mytry ./run_smoke.sh  # override via env
#
# Prereqs: Docker running, ./setup.sh done (pi binary built), OpenRouter key in ~/.pi/agent/auth.json.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

INSTANCE="${1:-pallets__flask-4992}"
MODEL="${2:-qwen/qwen3.6-27b}"
PROVIDER="${PROVIDER:-openrouter}"
RUN_ID="${RUN_ID:-pi-smoke}"
PRED="${PRED:-predictions.jsonl}"

# --- host arch -> image/binary arch -----------------------------------------
case "$(uname -m)" in
  arm64|aarch64) ARCH="arm64" ;;
  x86_64|amd64)  ARCH="x86_64" ;;
  *) echo "Unsupported arch: $(uname -m)"; exit 1 ;;
esac
PI_BIN="bin/pi-linux-$ARCH"

# --- preflight --------------------------------------------------------------
if [ ! -x "$PI_BIN" ]; then
  echo "ERROR: pi binary not found: $PI_BIN"
  echo "  run ./setup.sh  (or ./build_pi_binary.sh $ARCH) first."
  exit 1
fi
docker info >/dev/null 2>&1 || { echo "ERROR: Docker daemon not running — start Docker first."; exit 1; }

MODEL_NAME="${MODEL_NAME:-pi-$(echo "${PROVIDER}-${MODEL}" | tr '/:' '--')}"

echo "==> [1/2] Inference  instance=$INSTANCE  model=$PROVIDER/$MODEL  arch=$ARCH"
: > "$PRED"   # fresh single-instance predictions file
python3 run_inference.py \
  --instance-id "$INSTANCE" \
  --arch "$ARCH" --pi-binary "$PI_BIN" \
  --provider "$PROVIDER" --model "$MODEL" \
  --model-name "$MODEL_NAME" --run-id "$RUN_ID" --output "$PRED"

echo "==> [2/2] Evaluation  predictions=$PRED"
python3 run_eval.py --predictions-path "$PRED" --run-id "$RUN_ID" --instance-ids "$INSTANCE"

echo "==> Done. Resolved report: ${MODEL_NAME}.${RUN_ID}.json (this directory)"
