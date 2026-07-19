#!/usr/bin/env python3
"""Judge one centrally queued remote autoresearch submission."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
from canonical import process_one  # noqa: E402
from store import Store  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--store", required=True)
    args = parser.parse_args()
    item = process_one(Store(Path(args.store).resolve()), Path(args.repo).resolve())
    if item is None:
        print("judge queue empty")
        return 0
    print(f"judge {item['id']}: {item['state']}")
    return 0 if item["state"] in {"promotable", "neutral", "stale"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
