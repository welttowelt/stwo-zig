#!/usr/bin/env python3
"""Post-merge recorder: the human merge is the adjudication; this bot only
records it. For every merged submission carrying a claimed verdict and no
ledger row, append the maintainer-adjudicated optimistic row
(verdict_kind=claimed), then regenerate the committed site feed so the
website and backend update within their one-minute windows — no manual
promote/feed/push steps.

Runs on hosted CI (record.yml) after a push to main that touches
autoresearch/submissions/**. Judged verdicts never pass through here; they
arrive via the signed promote path.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "cli"))
from stwo_perf import ledger, promotion  # noqa: E402


def record_pending(repo: Path) -> list[str]:
    """Append optimistic rows for merged, unrecorded claimed verdicts — one
    row per (submission, moved class); returns 'id[name]' entries recorded."""
    recorded_pairs = {
        (r.submission_id, r.workload_class) for r in ledger.load(repo)
    }
    recorded: list[str] = []
    subs_dir = repo / "autoresearch" / "submissions"
    for sub in sorted(p for p in subs_dir.iterdir() if p.is_dir()):
        for verdict_path in promotion.claimed_verdict_files(sub):
            try:
                verdict = json.loads(verdict_path.read_text())
            except json.JSONDecodeError:
                print(f"[record] skipping {sub.name}/{verdict_path.name}: invalid JSON")
                continue
            if verdict.get("kind") != "claimed":
                continue
            cls = (verdict.get("declared_objective") or {}).get("workload_class")
            if (sub.name, cls) in recorded_pairs:
                continue
            try:
                row = promotion.promote_claimed(repo, sub.name, verdict_path.name)
            except promotion.PromotionError as exc:
                print(f"[record] skipping {sub.name}/{verdict_path.name}: {exc}")
                continue
            print(
                f"[record] ✓ {sub.name} [{row['workload_class']}]: "
                f"outcome={row['outcome']} R={row['judged_r']}"
            )
            recorded.append(f"{sub.name}[{verdict_path.name}]")
    return recorded


def refresh_feed(repo: Path) -> bool:
    """Regenerate the committed site feed; returns True when it changed."""
    subprocess.run(
        [str(repo / "autoresearch" / "cli" / "stwo-perf"), "feed"],
        cwd=repo, check=True,
    )
    dirty = subprocess.run(
        ["git", "status", "--porcelain", "autoresearch/site/feed.json"],
        cwd=repo, capture_output=True, text=True, check=True,
    ).stdout.strip()
    if not dirty:
        return False
    subprocess.run(["git", "add", "autoresearch/site/feed.json"], cwd=repo, check=True)
    subprocess.run(
        ["git", "commit", "-m", "Feed: refresh after recorded promotion [skip ci]"],
        cwd=repo, check=True,
    )
    return True


def main() -> int:
    repo = Path.cwd()
    recorded = record_pending(repo)
    if not recorded:
        print("[record] no unrecorded claimed submissions; nothing to do")
        return 0
    refresh_feed(repo)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
