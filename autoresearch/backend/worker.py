#!/usr/bin/env python3
"""Low-cost queue worker for intake, controlled judging, and promotion."""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT))
sys.path.insert(0, str(REPO_ROOT / "autoresearch" / "backend"))

from canonical import process_one as judge_one
from intake import process_one as intake_one
from promotion import process_one as promote_one
from store import Store, StoreError


def cycle(store: Store, repo: Path, verify_attestation: bool,
          push_remote: str | None, branch: str) -> int:
    states = {item["state"] for item in store.snapshot()["submissions"]}
    if "promotion_error" in states:
        raise RuntimeError("promotion_error requires repository repair before more judging")
    if "promoting" in states or "promotable" in states:
        promoted = promote_one(store, repo, push_remote, branch)
        if promoted is not None:
            print(f"promotion {promoted['id']}: {promoted['state']}", flush=True)
            return 1
    activity = 0
    intake = intake_one(store, repo, verify_attestation)
    if intake is not None:
        print(f"intake {intake['id']}: {intake['state']}", flush=True)
        activity += 1
    judged = judge_one(store, repo)
    if judged is not None:
        print(f"judge {judged['id']}: {judged['state']}", flush=True)
        activity += 1
    promoted = promote_one(store, repo, push_remote, branch)
    if promoted is not None:
        print(f"promotion {promoted['id']}: {promoted['state']}", flush=True)
        activity += 1
    return activity


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--store", required=True)
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--poll-seconds", type=float, default=5.0)
    parser.add_argument("--skip-attestation", action="store_true")
    parser.add_argument("--push-remote")
    parser.add_argument("--branch", default="main")
    args = parser.parse_args()
    if args.poll_seconds < 1:
        parser.error("--poll-seconds must be at least 1")

    repo = Path(args.repo).resolve()
    store = Store(Path(args.store).resolve())
    while True:
        try:
            activity = cycle(
                store, repo, not args.skip_attestation,
                args.push_remote, args.branch,
            )
        except (StoreError, OSError, RuntimeError) as exc:
            print(f"worker cycle failed safely: {exc}", flush=True)
            activity = 0
            if args.once:
                return 1
        if args.once:
            blocked = {
                item["state"] for item in store.snapshot()["submissions"]
            } & {"promoting", "promotion_error"}
            return 1 if blocked else 0
        # Drain bursts without delay; idle polling is cheap and local.
        if activity == 0:
            time.sleep(args.poll_seconds)


if __name__ == "__main__":
    raise SystemExit(main())
