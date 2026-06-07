#!/usr/bin/env bash
# One-command bootstrap for the SWE-bench Lite harness on a fresh machine.
#
#   git clone <repo> && cd <repo>/eval/swe-bench && ./setup.sh
#
# Builds pi, cross-compiles a linux pi binary matching THIS host's architecture
# (so it runs inside the native SWE-bench containers), and installs the python deps.
# Binaries are intentionally NOT committed — this script regenerates them per machine.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn] %s\033[0m\n' "$*"; }

# --- map host arch to swebench/bun arch -------------------------------------
case "$(uname -m)" in
  arm64|aarch64) ARCH="arm64" ;;
  x86_64|amd64)  ARCH="x86_64" ;;
  *) echo "Unsupported arch: $(uname -m)"; exit 1 ;;
esac
say "Host arch: $(uname -m) -> building for: $ARCH"

# --- prerequisite checks (non-fatal warnings) -------------------------------
say "Checking prerequisites"
command -v node   >/dev/null || warn "node not found (need >=22.19). https://nodejs.org"
command -v bun    >/dev/null || warn "bun not found (needed to compile the binary). https://bun.sh"
command -v docker >/dev/null || warn "docker not found (needed to run instances). https://docker.com"
command -v python3>/dev/null || warn "python3 not found (needed for swebench)."
docker info >/dev/null 2>&1 || warn "Docker daemon not running — start Docker before running the harness."

# --- 1. install JS deps & build pi ------------------------------------------
say "Installing npm dependencies (repo root)"
( cd "$REPO_ROOT" && npm install )

say "Building pi (tui -> ai -> agent -> coding-agent)"
( cd "$REPO_ROOT" && npm run build )

# --- 2. cross-compile the linux pi binary for this host's arch --------------
say "Cross-compiling linux pi binary ($ARCH)"
"$HERE/build_pi_binary.sh" "$ARCH"

# --- 3. python deps for the official evaluation -----------------------------
say "Installing python deps (swebench, datasets)"
python3 -m pip install --user --upgrade swebench datasets

# --- done -------------------------------------------------------------------
say "Setup complete."
cat <<EOF

Next steps:
  1. Make sure Docker is running.
  2. Provide an OpenRouter key (one-time, stored in ~/.pi/agent/auth.json):
        $REPO_ROOT/packages/coding-agent/dist/cli.js   # then run: /login openrouter
     or: export OPENROUTER_API_KEY=sk-or-...
  3. Run a smoke instance:
        cd "$HERE"
        python3 run_inference.py --instance-id pallets__flask-4992 \\
          --arch $ARCH --pi-binary bin/pi-linux-$ARCH \\
          --provider openrouter --model qwen/qwen3.6-27b \\
          --model-name pi-openrouter-qwen3.6-27b --run-id pi-smoke
        python3 run_eval.py --predictions-path predictions.jsonl --run-id pi-smoke
EOF
