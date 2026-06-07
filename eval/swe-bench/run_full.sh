#!/usr/bin/env bash
# Full (or subset) SWE-bench Lite run: inference over many instances, then ONE official scoring pass.
#
#   ./run_full.sh                              # ALL 300 instances, qwen/qwen3.6-27b
#   ./run_full.sh anthropic/claude-opus-4.8    # ALL 300 with a different model
#   LIMIT=20 ./run_full.sh                     # first 20 instances only (recommended first)
#   IDS_FILE=my_ids.txt ./run_full.sh          # explicit instance-id list (one per line)
#
# Env overrides: PROVIDER, RUN_ID, MODEL_NAME, PRED, MAX_WORKERS, LIMIT, IDS_FILE.
# Resumable: re-running skips instances already present in the predictions file.
#
# Prereqs: Docker running, ./setup.sh done, OpenRouter key in ~/.pi/agent/auth.json.
#
# ⚠️ Cost/disk: each instance builds a multi-GB Docker image and calls the model.
#    All 300 = many hours + tens of GB of disk. Start with LIMIT=20.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

MODEL="${1:-qwen/qwen3.6-27b}"
PROVIDER="${PROVIDER:-openrouter}"
RUN_ID="${RUN_ID:-pi-full}"
LIMIT="${LIMIT:-0}"                 # 0 = all
IDS_FILE="${IDS_FILE:-}"
MAX_WORKERS="${MAX_WORKERS:-4}"     # parallelism for the SCORING pass (inference stays sequential)
MODEL_NAME="${MODEL_NAME:-pi-$(echo "${PROVIDER}-${MODEL}" | tr '/:' '--')}"
PRED="${PRED:-predictions-${RUN_ID}.jsonl}"

# --- host arch -> image/binary arch -----------------------------------------
case "$(uname -m)" in
  arm64|aarch64) ARCH="arm64" ;;
  x86_64|amd64)  ARCH="x86_64" ;;
  *) echo "Unsupported arch: $(uname -m)"; exit 1 ;;
esac
PI_BIN="bin/pi-linux-$ARCH"

# --- preflight --------------------------------------------------------------
[ -x "$PI_BIN" ] || { echo "ERROR: pi binary not found: $PI_BIN — run ./setup.sh first."; exit 1; }
docker info >/dev/null 2>&1 || { echo "ERROR: Docker daemon not running."; exit 1; }

# --- 1. resolve instance id list --------------------------------------------
echo "==> Loading instance list (model=$PROVIDER/$MODEL, arch=$ARCH, run_id=$RUN_ID)"
# bash 3.2 compatible (no mapfile): fill array via while-read
IDS=()
while IFS= read -r line; do
  [ -n "$line" ] && IDS+=("$line")
done < <(LIMIT="$LIMIT" IDS_FILE="$IDS_FILE" python3 - <<'PY'
import os
ids = []
f = os.environ.get("IDS_FILE", "")
if f:
    ids = [l.strip() for l in open(f) if l.strip()]
else:
    from datasets import load_dataset
    ds = load_dataset("princeton-nlp/SWE-bench_Lite", split="test")
    ids = [r["instance_id"] for r in ds]
lim = int(os.environ.get("LIMIT", "0") or 0)
if lim > 0:
    ids = ids[:lim]
print("\n".join(ids))
PY
)
TOTAL=${#IDS[@]}
[ "$TOTAL" -gt 0 ] || { echo "ERROR: no instances resolved."; exit 1; }

# --- 2. resume: list already-done instance ids (no associative array; bash 3.2 ok) ---
DONE_LIST="$(mktemp)"
trap 'rm -f "$DONE_LIST"' EXIT
if [ -f "$PRED" ]; then
  python3 -c "import json
[print(json.loads(l).get('instance_id','')) for l in open('$PRED') if l.strip()]" > "$DONE_LIST" 2>/dev/null || true
  echo "==> Resuming: $(grep -c . "$DONE_LIST" 2>/dev/null || echo 0) instances already in $PRED will be skipped."
fi

# --- 3. inference loop (sequential; per-instance failures are tolerated) -----
i=0; ok=0; fail=0; skip=0
for iid in "${IDS[@]}"; do
  i=$((i+1))
  if grep -Fxq "$iid" "$DONE_LIST" 2>/dev/null; then
    echo "[$i/$TOTAL] skip  $iid (already done)"; skip=$((skip+1)); continue
  fi
  echo "[$i/$TOTAL] infer $iid"
  if python3 run_inference.py \
        --instance-id "$iid" \
        --arch "$ARCH" --pi-binary "$PI_BIN" \
        --provider "$PROVIDER" --model "$MODEL" \
        --model-name "$MODEL_NAME" --run-id "$RUN_ID" --output "$PRED"; then
    ok=$((ok+1))
  else
    echo "  [warn] inference failed for $iid — continuing"; fail=$((fail+1))
  fi
done
echo "==> Inference done: ok=$ok fail=$fail skip=$skip (total=$TOTAL)"

# --- 4. official scoring over the whole predictions file --------------------
echo "==> Scoring $PRED with $MAX_WORKERS workers"
python3 run_eval.py --predictions-path "$PRED" --run-id "$RUN_ID" --max-workers "$MAX_WORKERS"

# --- 5. summary -------------------------------------------------------------
REPORT="${MODEL_NAME}.${RUN_ID}.json"
if [ -f "$REPORT" ]; then
  echo "==> Report: $REPORT"
  python3 -c "import json;d=json.load(open('$REPORT'));r=d.get('resolved_instances');t=d.get('total_instances') or d.get('submitted_instances');print(f'    RESOLVED: {r}/{t}' + (f'  ({100*r/t:.1f}%)' if r is not None and t else ''))"
else
  echo "==> Scoring finished; see report json in this directory."
fi
