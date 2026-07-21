#!/usr/bin/env python3
"""Promotion bot: after a submission PR merges, append the judged ledger row.

Runs on merge to main (promote.yml). Trust chain: the judged verdict is
fetched from the judge-only `judge-verdicts` branch, its HMAC signature is
verified (JUDGE_HMAC_SECRET), and only then does a row enter the ledger.
A searcher-supplied file can never be promoted — the signature, not the file
location, is the authority. Outcome logic (playbook F.5/F.6):

  promoted  — all gates pass, significant, holdout pass, improves class HEAD
  neutral   — gates pass but the result sits in the neutral band
  rejected  — any gate failed, holdout failed, or no improvement vs HEAD
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "cli"))
from stwo_perf import frontier, ledger, signing  # noqa: E402
from stwo_perf.promotion import decide_outcome  # noqa: E402  (re-export; tests import it here)
from stwo_perf import promotion  # noqa: E402

VERDICTS_BRANCH = "judge-verdicts"


def _git(*args: str, check: bool = True) -> str:
    proc = subprocess.run(["git", *args], capture_output=True, text=True)
    if check and proc.returncode != 0:
        raise SystemExit(f"git {' '.join(args)} failed: {proc.stderr.strip()}")
    return proc.stdout


def fetch_signed_verdict(submission_name: str) -> dict:
    _git("fetch", "origin", VERDICTS_BRANCH, check=False)
    blob = _git(
        "show", f"origin/{VERDICTS_BRANCH}:verdicts/{submission_name}.json",
        check=False,
    )
    if not blob:
        raise SystemExit(
            f"no signed judged verdict for {submission_name} on {VERDICTS_BRANCH}; "
            "the judge must run before promotion"
        )
    verdict = json.loads(blob)
    signing.verify(verdict)  # raises on forgery
    if verdict.get("kind") != "judged":
        raise SystemExit(f"{submission_name}: signed verdict is not kind=judged")
    if verdict.get("submission_id") != submission_name:
        raise SystemExit(f"{submission_name}: signed verdict names a different submission")
    return verdict


def unrecorded_submissions(repo: Path) -> list[Path]:
    """All merged submissions without a ledger row, oldest first — a skipped
    judge run on one must not block older recordable ones."""
    recorded = {r.submission_id for r in ledger.load(repo)}
    return [
        p for p in sorted((repo / "autoresearch" / "submissions").iterdir())
        if p.is_dir() and p.name not in recorded
    ]


def require_current_promotion_authority(repo: Path, verdict: dict) -> None:
    try:
        promotion.require_verdict_promotion_eligible(repo, verdict)
    except promotion.PromotionError as exc:
        raise SystemExit(f"promotion authority rejected the verdict: {exc}") from exc


# Outcome and row construction live in stwo_perf.promotion, shared with the
# maintainer-as-judge `stwo-perf promote-claimed` path; this bot is the only
# writer of verdict_kind=judged rows.


def main() -> int:
    repo = Path.cwd()
    pending = unrecorded_submissions(repo)
    if not pending:
        print("no unrecorded submission; nothing to promote")
        return 0
    sub = None
    verdict = None
    for candidate in pending:
        try:
            verdict = fetch_signed_verdict(candidate.name)
            sub = candidate
            break
        except SystemExit as exc:
            print(f"[promote] skipping {candidate.name}: {exc}")
    if sub is None or verdict is None:
        print("no unrecorded submission has a signed judged verdict yet")
        return 0
    require_current_promotion_authority(repo, verdict)
    objective_class = verdict["declared_objective"]["workload_class"]
    objective_board = verdict["declared_objective"]["board"]
    head = frontier.view(ledger.load(repo), objective_board, objective_class).head
    outcome, gates_cell = decide_outcome(
        verdict, promotion.predecessor_is_fresh(repo, verdict, head)
    )
    epoch = ledger.current_epoch(repo)["epoch"]
    row = promotion.row_from_verdict(
        sub.name, verdict, epoch, outcome, gates_cell, verdict_kind="judged"
    )
    ledger.append(repo, row)
    subprocess.run(["git", "add", str(ledger.ledger_path(repo))], check=True)
    subprocess.run(
        ["git", "commit", "-m", f"Ledger: {outcome} — {sub.name}",
         "-m", "Appended by the promotion bot from the signed judged verdict. [skip ci]"],
        check=True,
        env={"PROMOTION_BOT": "1", **os.environ},
    )
    print(f"✓ ledger row appended: {sub.name} outcome={outcome} R={row['judged_r']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
