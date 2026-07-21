#!/usr/bin/env python3
"""Consume one remote submission and cheaply revalidate its fork source."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT))
sys.path.insert(0, str(REPO_ROOT / "autoresearch" / "backend"))
from intake import process_one  # noqa: E402
from store import Store  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, help="canonical repository checkout")
    parser.add_argument("--store", required=True, help="backend store JSON")
    parser.add_argument("--skip-attestation", action="store_true",
                        help="do not invoke gh attestation verify when an attestation is supplied")
    args = parser.parse_args()
    item = process_one(
        Store(Path(args.store).resolve()), Path(args.repo).resolve(),
        verify_attestation=not args.skip_attestation,
    )
    if item is None:
        print("intake queue empty")
        return 0
    print(f"intake {item['id']}: {item['state']}")
    return 0 if item["state"] == "queued" else 1


if __name__ == "__main__":
    raise SystemExit(main())
