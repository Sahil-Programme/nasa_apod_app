#!/usr/bin/env python3
"""Run Flutter commands with hard timeouts and log capture.

Usage examples:
  python scripts/flutter_guard.py run -d windows --timeout 120
  python scripts/flutter_guard.py test --timeout 90
  python scripts/flutter_guard.py build windows --debug --timeout 180
"""

from __future__ import annotations

import argparse
import pathlib
import subprocess
import sys
import time


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "flutter_args",
        nargs="+",
        help="Arguments passed to flutter (for example: run -d windows)",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=120,
        help="Max runtime in seconds before the command is terminated.",
    )
    parser.add_argument(
        "--log-dir",
        default="logs",
        help="Directory where stdout/stderr logs are written.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    log_dir = pathlib.Path(args.log_dir)
    log_dir.mkdir(parents=True, exist_ok=True)

    ts = time.strftime("%Y%m%d_%H%M%S")
    out_path = log_dir / f"flutter_{ts}.out.log"
    err_path = log_dir / f"flutter_{ts}.err.log"

    cmd = ["flutter", *args.flutter_args]
    print("Running:", " ".join(cmd))
    print(f"Timeout: {args.timeout}s")
    print(f"Stdout: {out_path}")
    print(f"Stderr: {err_path}")

    with out_path.open("w", encoding="utf-8") as out, err_path.open(
        "w",
        encoding="utf-8",
    ) as err:
        proc = subprocess.Popen(cmd, stdout=out, stderr=err)
        try:
            code = proc.wait(timeout=args.timeout)
            print(f"Exit code: {code}")
            return code
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)
            print(f"Timed out after {args.timeout}s. Process was killed.")
            return 124


if __name__ == "__main__":
    sys.exit(main())
