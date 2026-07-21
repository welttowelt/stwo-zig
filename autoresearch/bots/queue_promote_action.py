#!/usr/bin/env python3
"""Promote or resume one signed canonical autoresearch candidate."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT))
sys.path.insert(0, str(REPO_ROOT / "autoresearch" / "backend"))
from promotion import process_one  # noqa: E402
from store import Store  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--store", required=True)
    parser.add_argument("--push-remote", help="e.g. origin; omit for a local promotion")
    parser.add_argument("--branch", default="main")
    args = parser.parse_args()
    item = process_one(
        Store(Path(args.store).resolve()), Path(args.repo).resolve(),
        push_remote=args.push_remote, branch=args.branch,
    )
    if item is None:
        print("promotion queue empty")
        return 0
    print(f"promotion {item['id']}: {item['state']}")
    return 0 if item["state"] in {"promoted", "stale"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
