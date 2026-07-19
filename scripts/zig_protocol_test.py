#!/usr/bin/env python3
"""Run `zig test` with the canonical named Stwo protocol modules."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

from zig_protocol_lib.command import test_command


ROOT = Path(__file__).resolve().parents[1]


def main(argv: list[str] | None = None) -> int:
    arguments = list(sys.argv[1:] if argv is None else argv)
    if not arguments:
        print("usage: zig_protocol_test.py <root-source> [zig-test-arguments...]", file=sys.stderr)
        return 2
    root_source = arguments.pop(0)
    return subprocess.run(test_command(root_source, *arguments), cwd=ROOT, check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
