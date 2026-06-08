#!/usr/bin/env bash
# Rebuild pi after editing its source, so the next run uses the new code.
#
#   ./rebuild.sh            # rebuild for THIS host's arch (auto-detected)
#   ./rebuild.sh x86_64     # force a specific arch (arm64 | x86_64)
#
# Recompiles pi (npm run build) and regenerates the injected linux binary
# (bin/pi-linux-<arch>). SWE-bench Docker images are NOT rebuilt — pi is injected
# fresh on every run, so the image cache is reused.
#
# After this, re-run ./run_smoke.sh, or for a full re-run use a NEW RUN_ID
# (or delete predictions-<run_id>.jsonl) so run_full.sh does not skip done instances.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

if [ "${1:-}" = "" ]; then
  case "$(uname -m)" in
    arm64|aarch64) ARCH="arm64" ;;
    x86_64|amd64)  ARCH="x86_64" ;;
    *) echo "Unsupported arch: $(uname -m) — pass arm64|x86_64 explicitly."; exit 1 ;;
  esac
else
  ARCH="$1"
fi

printf '\n\033[1;36m==> Rebuilding pi (arch=%s)\033[0m\n' "$ARCH"

# build_pi_binary.sh runs `npm run build` (tui->ai->agent->coding-agent) then compiles the binary.
"$HERE/build_pi_binary.sh" "$ARCH"

printf '\n\033[1;32m==> Done. bin/pi-linux-%s updated. Re-run ./run_smoke.sh (or ./run_full.sh with a new RUN_ID).\033[0m\n' "$ARCH"
