#!/usr/bin/env python3
"""
SWE-bench (Lite) inference harness for the `pi` coding agent — Method B (run inside Docker).

For each instance:
  1. Build the official SWE-bench instance image (repo checked out at base_commit in /testbed).
  2. Start a container, copy the prebuilt linux `pi` binary into it.
  3. Run `pi -p "<problem_statement + instructions>"` inside /testbed (calls OpenRouter).
  4. Extract `git diff` as the model_patch.
  5. Append a prediction record to predictions.jsonl.

The official evaluation (scoring) is a separate step — see run_eval.sh.

Usage:
  python run_inference.py --instance-id pallets__flask-4992 \
      --provider openrouter --model anthropic/claude-haiku-4.5 \
      --pi-binary /tmp/pi-linux-test --model-name pi-openrouter-haiku
"""
import argparse
import json
import logging
import os
import sys
import time
from pathlib import Path

import io
import tarfile

import docker
from datasets import load_dataset
from swebench.harness.test_spec.test_spec import make_test_spec
from swebench.harness.docker_build import (
    build_env_images,
    build_instance_image,
    build_container,
    setup_logger,
    cleanup_container,
)

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent.parent
THEME_SRC = REPO_ROOT / "packages" / "coding-agent" / "src" / "modes" / "interactive" / "theme"
PI_DIR = "/opt/pi"  # bun binary loads assets (theme/) relative to its own directory

AGENT_INSTRUCTIONS = """\
You are fixing a bug in a Python repository located at /testbed (your current working directory).

The issue to resolve:
<issue>
{problem}
</issue>

Instructions:
- Investigate the codebase to locate the root cause (use read/grep/find/bash).
- Make the MINIMAL code change to existing source files that fixes the issue.
- Do NOT modify test files. Do NOT add unrelated changes.
- When done, ensure your edits are saved to disk. Do not commit.
"""


def read_openrouter_key() -> str:
    auth = Path.home() / ".pi" / "agent" / "auth.json"
    key = os.environ.get("OPENROUTER_API_KEY", "")
    if not key and auth.exists():
        d = json.loads(auth.read_text())
        entry = d.get("openrouter", {})
        key = entry.get("key", "") if isinstance(entry, dict) else ""
    if key.startswith("$"):
        key = os.environ.get(key[1:].strip("{}"), "")
    if not key:
        sys.exit("ERROR: no OpenRouter API key found (env OPENROUTER_API_KEY or ~/.pi/agent/auth.json).")
    return key


def find_instance(instance_id: str) -> dict:
    ds = load_dataset("princeton-nlp/SWE-bench_Lite", split="test")
    for r in ds:
        if r["instance_id"] == instance_id:
            return r
    sys.exit(f"ERROR: instance_id {instance_id} not found in SWE-bench_Lite test split.")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--instance-id", required=True)
    ap.add_argument("--provider", default="openrouter")
    ap.add_argument("--model", default="anthropic/claude-haiku-4.5")
    ap.add_argument("--model-name", default=None, help="model_name_or_path in predictions (defaults to provider/model)")
    ap.add_argument("--pi-binary", default=str(HERE / "bin" / "pi-linux-arm64"),
                    help="prebuilt linux pi binary (must match --arch)")
    ap.add_argument("--arch", default="arm64", choices=["arm64", "x86_64"],
                    help="image/build arch. Use arm64 on Apple Silicon (x86_64 emulation crashes conda installs).")
    ap.add_argument("--run-id", default="pi-smoke")
    ap.add_argument("--timeout", type=int, default=1200, help="per-instance agent timeout (seconds)")
    ap.add_argument("--output", default=str(HERE / "predictions.jsonl"))
    args = ap.parse_args()

    model_name = args.model_name or f"{args.provider}/{args.model}"
    pi_binary = Path(args.pi_binary)
    if not pi_binary.exists():
        sys.exit(f"ERROR: pi binary not found: {pi_binary}")
    key = read_openrouter_key()

    instance = find_instance(args.instance_id)
    test_spec = make_test_spec(instance, arch=args.arch)  # arm64 native on Apple Silicon

    log_file = HERE / "logs" / f"{args.instance_id}.log"
    logger = setup_logger(args.instance_id, log_file)
    client = docker.from_env()

    container = None
    try:
        print(f"[{args.instance_id}] building env image (arch={args.arch})...", flush=True)
        build_env_images(client, [test_spec], force_rebuild=False, max_workers=1, namespace=None)
        print(f"[{args.instance_id}] building instance image...", flush=True)
        build_instance_image(test_spec, client, logger, nocache=False)

        print(f"[{args.instance_id}] starting container...", flush=True)
        container = build_container(test_spec, client, args.run_id, logger, nocache=False)
        container.start()

        # Inject the pi binary + theme assets into PI_DIR. The bun-compiled binary resolves
        # built-in assets (theme/dark.json, theme/light.json) relative to its own directory.
        container.exec_run(f"mkdir -p {PI_DIR}/theme", user="root")
        tar_stream = io.BytesIO()
        with tarfile.open(fileobj=tar_stream, mode="w") as tar:
            tar.add(str(pi_binary), arcname="pi")
            for name in ("dark.json", "light.json", "theme-schema.json"):
                src = THEME_SRC / name
                if src.exists():
                    tar.add(str(src), arcname=f"theme/{name}")
        tar_stream.seek(0)
        container.put_archive(PI_DIR, tar_stream.read())
        container.exec_run(f"chmod +x {PI_DIR}/pi", user="root")

        # Write the prompt to a file inside the container (avoids shell-escaping issues)
        prompt = AGENT_INSTRUCTIONS.format(problem=instance["problem_statement"])
        tar_stream = io.BytesIO()
        with tarfile.open(fileobj=tar_stream, mode="w") as tar:
            data = prompt.encode("utf-8")
            ti = tarfile.TarInfo(name="prompt.txt")
            ti.size = len(data)
            tar.addfile(ti, io.BytesIO(data))
        tar_stream.seek(0)
        container.put_archive("/tmp", tar_stream.read())

        # Run the agent
        print(f"[{args.instance_id}] running pi agent ({model_name})...", flush=True)
        t0 = time.time()
        cmd = (
            f'timeout {args.timeout} {PI_DIR}/pi -p "$(cat /tmp/prompt.txt)" '
            f'--provider {args.provider} --model {args.model}'
        )
        exec_res = container.exec_run(
            ["/bin/bash", "-lc", cmd],
            workdir="/testbed",
            environment={"OPENROUTER_API_KEY": key, "HOME": "/root"},
            user="root",
        )
        dt = time.time() - t0
        out = exec_res.output.decode("utf-8", errors="replace")
        print(f"[{args.instance_id}] agent finished in {dt:.0f}s (exit={exec_res.exit_code})", flush=True)
        (HERE / "logs" / f"{args.instance_id}.agent.out").write_text(out)

        # Extract patch (tracked-file edits vs base_commit)
        diff_res = container.exec_run(
            ["/bin/bash", "-lc", "git -C /testbed add -A >/dev/null 2>&1; git -C /testbed diff --cached"],
            user="root",
        )
        patch = diff_res.output.decode("utf-8", errors="replace")
        print(f"[{args.instance_id}] patch size: {len(patch)} bytes", flush=True)

        rec = {
            "instance_id": args.instance_id,
            "model_name_or_path": model_name,
            "model_patch": patch,
        }
        with open(args.output, "a") as f:
            f.write(json.dumps(rec) + "\n")
        print(f"[{args.instance_id}] wrote prediction -> {args.output}", flush=True)

    finally:
        if container is not None:
            cleanup_container(client, container, logger)


if __name__ == "__main__":
    main()
