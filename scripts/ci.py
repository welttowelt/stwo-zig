#!/usr/bin/env python3
"""Run the repository CI entrypoint used locally and by hosted automation."""

from __future__ import annotations

import argparse
import shlex
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def command_plan(strict: bool, optimize: str) -> list[list[str]]:
    gate = "release-gate-strict" if strict else "release-gate"
    return [
        [
            sys.executable,
            "-m",
            "unittest",
            "discover",
            "-s",
            "scripts/tests",
            "-p",
            "test_*.py",
        ],
        ["zig", "build", gate, f"-Doptimize={optimize}"],
    ]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--strict", action="store_true", help="run the strict release gate")
    parser.add_argument(
        "--optimize",
        choices=("Debug", "ReleaseSafe", "ReleaseFast", "ReleaseSmall"),
        default="ReleaseFast",
    )
    args = parser.parse_args(argv)

    for command in command_plan(args.strict, args.optimize):
        print(f"+ {shlex.join(command)}", flush=True)
        try:
            completed = subprocess.run(command, cwd=ROOT, check=False)
        except OSError as error:
            print(f"unable to run {command[0]}: {error}", file=sys.stderr)
            return 127
        if completed.returncode != 0:
            return completed.returncode
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
