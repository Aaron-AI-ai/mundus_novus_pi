#!/usr/bin/env python3
"""
SWE-bench Lite official evaluation, forced to arm64-native images.

swebench 4.1.0 hardcodes arch="x86_64" in make_test_spec and exposes no --arch flag, so on
Apple Silicon the official CLI tries to build/run x86_64 images under emulation, which crashes
conda installs (exit 133 / SIGTRAP). This wrapper monkeypatches make_test_spec to default to
arm64 and builds images locally (namespace=None), matching run_inference.py --arch arm64.

Usage:
  python run_eval.py --predictions-path predictions.jsonl --run-id pi-smoke
"""
import argparse

import swebench.harness.test_spec.test_spec as ts_mod
import swebench.harness.docker_build as db_mod
import swebench.harness.run_evaluation as re_mod

_orig_make_test_spec = ts_mod.make_test_spec


def _arm64_make_test_spec(instance, namespace=None, base_image_tag="latest",
                          env_image_tag="latest", instance_image_tag="latest", arch="arm64"):
    return _orig_make_test_spec(
        instance, namespace=namespace, base_image_tag=base_image_tag,
        env_image_tag=env_image_tag, instance_image_tag=instance_image_tag, arch=arch,
    )


# Replace every bound reference to make_test_spec so all call sites build arm64.
ts_mod.make_test_spec = _arm64_make_test_spec
db_mod.make_test_spec = _arm64_make_test_spec
re_mod.make_test_spec = _arm64_make_test_spec


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--predictions-path", default="predictions.jsonl")
    ap.add_argument("--run-id", default="pi-smoke")
    ap.add_argument("--dataset-name", default="princeton-nlp/SWE-bench_Lite")
    ap.add_argument("--split", default="test")
    ap.add_argument("--instance-ids", nargs="*", default=None)
    ap.add_argument("--max-workers", type=int, default=1)
    ap.add_argument("--timeout", type=int, default=1800)
    args = ap.parse_args()

    re_mod.main(
        dataset_name=args.dataset_name,
        split=args.split,
        instance_ids=args.instance_ids,
        predictions_path=args.predictions_path,
        max_workers=args.max_workers,
        force_rebuild=False,
        cache_level="env",
        clean=False,
        open_file_limit=4096,
        run_id=args.run_id,
        timeout=args.timeout,
        namespace=None,        # build images locally (arm64-native)
        rewrite_reports=False,
        modal=False,
    )


if __name__ == "__main__":
    main()
