#!/usr/bin/env bash
# Official SWE-bench evaluation (scoring) for a predictions.jsonl produced by run_inference.py.
# Requires: pip install swebench ; Docker running.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PREDICTIONS="${1:-$HERE/predictions.jsonl}"
RUN_ID="${2:-pi-smoke}"

echo "Evaluating $PREDICTIONS (run_id=$RUN_ID)..."
python3 -m swebench.harness.run_evaluation \
  --dataset_name princeton-nlp/SWE-bench_Lite \
  --predictions_path "$PREDICTIONS" \
  --run_id "$RUN_ID" \
  --max_workers 1 \
  --cache_level env

# Report is written to <model_name>.<run_id>.json in the CWD.
echo "Done. See *.${RUN_ID}.json for the resolved report."
