#!/usr/bin/env python3
"""Validate the static RISC-V registry, artifact, and CLI release contract."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

try:
    from riscv_release_gate_lib.contract import repository_contract_errors
except ModuleNotFoundError:  # Imported through the repository package in tests.
    from scripts.riscv_release_gate_lib.contract import repository_contract_errors


ROOT = Path(__file__).resolve().parent.parent


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--all", action="store_true", help="validate every static release surface")
    parser.add_argument("--phase", choices=("candidate", "promoted"), default="candidate")
    args = parser.parse_args(argv)
    if not args.all:
        parser.error("--all is required; partial release-contract validation is forbidden")
    errors = repository_contract_errors(ROOT, args.phase)
    for error in errors:
        print(f"riscv release contract: {error}", file=sys.stderr)
    if not errors:
        print(f"riscv release contract: {args.phase} phase is internally consistent")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
