#!/usr/bin/env python3
"""Run Flutter release checks indirectly and emit a structured report.

This script avoids direct shell invocation in the assistant workflow by
executing Flutter commands through Python subprocess calls, capturing logs,
and printing a compact summary.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import shutil
import subprocess
import sys
import time
from dataclasses import asdict, dataclass


@dataclass
class StepResult:
    name: str
    command: list[str]
    exit_code: int
    duration_seconds: float
    stdout_log: str
    stderr_log: str

    @property
    def ok(self) -> bool:
        return self.exit_code == 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--project-root",
        default=".",
        help="Flutter project root directory (defaults to current directory).",
    )
    parser.add_argument(
        "--log-dir",
        default="logs/flutter_release_check",
        help="Directory where per-step logs and JSON report are written.",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=1200,
        help="Per-command timeout in seconds (default: 1200).",
    )
    parser.add_argument(
        "--skip-build",
        action="store_true",
        help="Skip `flutter build appbundle --release`.",
    )
    parser.add_argument(
        "--continue-on-error",
        action="store_true",
        help="Continue running later steps after a failed step.",
    )
    return parser.parse_args()


def resolve_flutter_bin() -> str:
    override = os.environ.get("FLUTTER_BIN", "").strip()
    if override:
        return override

    found = shutil.which("flutter")
    if found:
        return found

    raise FileNotFoundError(
        "Could not find `flutter` in PATH. Set FLUTTER_BIN to the Flutter executable path."
    )


def run_step(
    *,
    name: str,
    cmd: list[str],
    cwd: pathlib.Path,
    timeout_seconds: int,
    log_root: pathlib.Path,
) -> StepResult:
    safe_name = name.lower().replace(" ", "_")
    out_path = log_root / f"{safe_name}.stdout.log"
    err_path = log_root / f"{safe_name}.stderr.log"

    started = time.monotonic()
    try:
        proc = subprocess.run(
            cmd,
            cwd=str(cwd),
            capture_output=True,
            text=True,
            timeout=timeout_seconds,
            check=False,
            encoding="utf-8",
            errors="replace",
        )
        exit_code = proc.returncode
        stdout = proc.stdout
        stderr = proc.stderr
    except subprocess.TimeoutExpired as exc:
        exit_code = 124
        stdout = (exc.stdout or "") if isinstance(exc.stdout, str) else ""
        stderr = (exc.stderr or "") if isinstance(exc.stderr, str) else ""
        stderr += f"\nTimed out after {timeout_seconds}s.\n"

    duration = round(time.monotonic() - started, 2)
    out_path.write_text(stdout, encoding="utf-8")
    err_path.write_text(stderr, encoding="utf-8")

    return StepResult(
        name=name,
        command=cmd,
        exit_code=exit_code,
        duration_seconds=duration,
        stdout_log=str(out_path),
        stderr_log=str(err_path),
    )


def main() -> int:
    args = parse_args()
    project_root = pathlib.Path(args.project_root).resolve()
    log_root = pathlib.Path(args.log_dir).resolve()
    log_root.mkdir(parents=True, exist_ok=True)

    flutter = resolve_flutter_bin()
    steps: list[tuple[str, list[str]]] = [
        ("Flutter Version", [flutter, "--version"]),
        ("Pub Get", [flutter, "pub", "get"]),
        ("Analyze", [flutter, "analyze"]),
        ("Test", [flutter, "test"]),
    ]
    if not args.skip_build:
        steps.append(("Build AppBundle", [flutter, "build", "appbundle", "--release"]))

    results: list[StepResult] = []
    overall_ok = True

    print(f"Project root: {project_root}")
    print(f"Logs: {log_root}")
    print(f"Flutter bin: {flutter}")

    for name, cmd in steps:
        print(f"\n==> {name}")
        print(" ".join(cmd))
        result = run_step(
            name=name,
            cmd=cmd,
            cwd=project_root,
            timeout_seconds=args.timeout,
            log_root=log_root,
        )
        results.append(result)
        status = "OK" if result.ok else f"FAIL ({result.exit_code})"
        print(f"Status: {status} in {result.duration_seconds:.2f}s")
        print(f"stdout: {result.stdout_log}")
        print(f"stderr: {result.stderr_log}")

        if not result.ok:
            overall_ok = False
            if not args.continue_on_error:
                break

    report = {
        "project_root": str(project_root),
        "flutter_bin": flutter,
        "generated_at_epoch_seconds": int(time.time()),
        "overall_ok": overall_ok,
        "steps": [asdict(r) | {"ok": r.ok} for r in results],
    }
    report_path = log_root / "report.json"
    report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(f"\nReport: {report_path}")
    print("Overall:", "PASS" if overall_ok else "FAIL")
    return 0 if overall_ok else 1


if __name__ == "__main__":
    sys.exit(main())
