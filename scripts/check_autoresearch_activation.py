#!/usr/bin/env python3
"""Check whether an autoresearch board has earned activation (BA-03)."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from autoresearch_activation_lib import activation_errors


ROOT = Path(__file__).resolve().parent.parent


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--board", required=True, choices=("riscv",))
    parser.add_argument("--github-settings-receipt", type=Path)
    parser.add_argument("--repository", default="teddyjfpender/stwo-zig")
    parser.add_argument(
        "--audit-pending",
        action="store_true",
        help="report blockers without requiring the disabled board to be active",
    )
    args = parser.parse_args(argv)
    errors = activation_errors(
        ROOT,
        board=args.board,
        settings_receipt=args.github_settings_receipt,
        repository=args.repository,
        require_active=not args.audit_pending,
    )
    for error in errors:
        print(f"autoresearch activation: {error}", file=sys.stderr)
    if errors:
        print(f"autoresearch activation: {len(errors)} blocker(s)", file=sys.stderr)
        return 1
    print(f"autoresearch activation: {args.board} is eligible")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
