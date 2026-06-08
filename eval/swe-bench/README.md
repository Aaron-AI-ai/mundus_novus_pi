# SWE-bench Lite harness for `pi` (Method B — run agent inside Docker)

Evaluate the `pi` coding agent on [SWE-bench Lite](https://www.swebench.com/) (300 instances).
Two stages: **inference** (this repo produces patches) and **evaluation** (official `swebench`
harness scores them).

```
inference (run_inference.py)                 evaluation (run_eval.py)
  build instance image (repo @ base_commit)    apply model_patch in a fresh container
  start container, inject pi binary            run FAIL_TO_PASS + PASS_TO_PASS
  pi -p "<problem_statement>"  → edits repo     → resolved / not-resolved report
  git diff → model_patch
  append to predictions.jsonl
```

## Quick start (new machine)

```bash
git clone <repo> && cd <repo>/eval/swe-bench
./setup.sh        # npm install + build pi + cross-compile the linux binary + pip install swebench
```

`setup.sh` detects the host architecture and builds the matching binary, so it works on both
Apple Silicon (arm64) and Intel/Linux (x86_64). The compiled binaries (~200MB) are **not** in git
— this script regenerates them per machine. After it finishes, provide an OpenRouter key
(`pi /login openrouter` or `export OPENROUTER_API_KEY=...`) and ensure Docker is running.

## Prerequisites

- **Docker** running (Docker Desktop).
- **Python** + `pip install swebench` (v4.x) and `datasets`.
- **bun** + **node** (to build the pi binary) — `bun build --compile` cross-compiles a single
  static linux binary, so no Node is needed inside the container.
- **OpenRouter** credentials: `~/.pi/agent/auth.json` (`openrouter` entry) or `OPENROUTER_API_KEY`.

## ⚠️ Apple Silicon (arm64) note

`swebench` 4.1.0 hardcodes `arch="x86_64"` and has no `--arch` flag. On Apple Silicon, building
x86_64 images runs the conda installer under emulation, which **crashes (exit 133 / SIGTRAP)**.
This harness therefore forces **native arm64** for both stages:

- `run_inference.py --arch arm64` (default) + an **arm64** pi binary.
- `run_eval.py` monkeypatches `make_test_spec` to arm64 and builds images locally (`namespace=None`).

Pure-Python repos (flask, requests, pytest, …) build cleanly on arm64. A few heavy-native repos
may need x86_64 on an Intel/Linux host instead.

## Build the pi binary

```bash
./build_pi_binary.sh arm64     # → bin/pi-linux-arm64   (Apple Silicon)
./build_pi_binary.sh x86_64    # → bin/pi-linux-x86_64  (Intel/Linux host)
```

## Run

### One-command smoke (inference + evaluation)

```bash
./run_smoke.sh                                    # defaults: pallets__flask-4992 + qwen/qwen3.6-27b
./run_smoke.sh psf__requests-3362 anthropic/claude-opus-4.8   # pick instance + model
```

Auto-detects host arch, runs inference then official scoring for one instance, and writes the
resolved report. Override with env vars: `PROVIDER=`, `RUN_ID=`, `MODEL_NAME=`.

### Manual (two steps)

```bash
# 1) Inference — one instance (smoke)
python3 run_inference.py \
  --instance-id pallets__flask-4992 \
  --provider openrouter --model anthropic/claude-haiku-4.5 \
  --arch arm64 --pi-binary bin/pi-linux-arm64 \
  --model-name pi-openrouter-haiku --run-id pi-smoke \
  --output predictions.jsonl

# 2) Evaluation (scoring)
python3 run_eval.py --predictions-path predictions.jsonl --run-id pi-smoke
# → writes <model_name>.<run_id>.json with resolved_instances count
```

## Swapping the model (OpenRouter → Ollama later)

`pi` treats both as OpenAI-compatible providers, so switching is a flag change — no code edits:

- **OpenRouter** (built-in): `--provider openrouter --model anthropic/claude-opus-4.8`
- **Ollama** (later): add an entry to `~/.pi/agent/models.json` (`api: openai-completions`,
  `baseUrl: http://host.docker.internal:11434/v1`), then `--provider ollama --model <id>`.

## Full / subset run (official scoring)

`run_full.sh` runs inference over many instances, then one official scoring pass, and prints the
resolved %. It is **resumable** (re-running skips instances already in the predictions file) and
tolerates per-instance failures.

```bash
LIMIT=20 ./run_full.sh                         # first 20 instances (recommended first)
./run_full.sh                                  # ALL 300, qwen/qwen3.6-27b
./run_full.sh anthropic/claude-opus-4.8        # ALL 300 with another model
IDS_FILE=my_ids.txt ./run_full.sh              # explicit instance-id list (one per line)
```

Env overrides: `PROVIDER`, `RUN_ID`, `MODEL_NAME`, `PRED`, `MAX_WORKERS` (scoring parallelism), `LIMIT`.

> ⚠️ Each instance builds a multi-GB image and calls the model. All 300 = many hours + tens of GB
> of disk. Inference runs sequentially; only the scoring pass parallelizes (`MAX_WORKERS`).
> Reclaim space afterwards with `docker system prune -a` (this deletes the cached instance images).

## Files

| File | Purpose |
|------|---------|
| `setup.sh` | One-command bootstrap on a fresh machine (install + build + compile binary) |
| `run_smoke.sh` | End-to-end run for one instance (inference + evaluation) |
| `run_full.sh` | Full/subset run: inference over many instances + one scoring pass (resumable) |
| `run_inference.py` | Build image, run pi in container, extract patch → predictions.jsonl |
| `run_eval.py` | Official swebench scoring, forced arm64-native |
| `build_pi_binary.sh` | Cross-compile the linux pi binary |
| `rebuild.sh` | After editing pi source: rebuild pi + regenerate the injected binary |
| `run_eval.sh` | Thin wrapper for the official CLI (x86_64 hosts only) |
| `bin/` | Prebuilt pi binaries |
| `logs/` | Per-instance build + agent logs |
