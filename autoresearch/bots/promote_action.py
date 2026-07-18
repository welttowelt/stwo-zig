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

import datetime as dt
import json
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "cli"))
from stwo_perf import frontier, ledger, signing  # noqa: E402

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


def decide_outcome(verdict: dict, head_prove_ms: float | None) -> tuple[str, str]:
    """Pure outcome decision (playbook F.5); head_prove_ms is the current
    promoted class HEAD's prove time, or None when the class has no HEAD."""
    gates_ok = all(g["pass"] for g in verdict["gates"].values())
    if not gates_ok:
        failing = ",".join(g for g, v in verdict["gates"].items() if not v["pass"])
        return "rejected", f"{failing}:fail"
    holdout = verdict.get("holdout")
    if holdout is not None and not holdout.get("pass"):
        return "rejected", "G1..G5:pass"
    if not verdict["score"]["significant"]:
        return ("neutral" if verdict["score"]["neutral"] else "rejected"), "G1..G5:pass"
    if head_prove_ms is not None:
        first = next(iter(verdict["score"]["per_workload"].values()))
        if float(first["b_median_ms"]) >= head_prove_ms:
            return "rejected", "G1..G5:pass"
    return "promoted", "G1..G5:pass"


def row_from_verdict(sub: Path, verdict: dict, epoch: int, outcome: str,
                     gates_cell: str) -> dict:
    score = verdict["score"]
    objective = verdict["declared_objective"]
    first = next(iter(score["per_workload"].values()))
    holdout = verdict.get("holdout")
    holdout_cell = (
        f"{'pass' if holdout['pass'] else 'fail'};seed={holdout['seed']}"
        if holdout else "none"
    )
    return {
        "schema_version": ledger.SCHEMA_VERSION,
        "harness_commit": verdict["harness_commit"],
        "epoch": epoch,
        "judged_at_utc": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "commit": verdict["repo_commit"],
        "scope": verdict["scope"],
        "board": objective.get("board", "core_cpu"),
        "workload_class": objective["workload_class"],
        "outcome": outcome,
        "judged_r": float(score["R_geomean"]),
        "ci_low": float(first["ci"][0]),
        "ci_high": float(first["ci"][1]),
        "prove_ms": float(first["b_median_ms"]),
        "native_mhz": 0.0,
        "peak_rss_mib": 0.0,
        "waits": None,
        "dispatches": None,
        "energy_j": None,
        "gates": gates_cell,
        "holdout": holdout_cell,
        "submission_id": sub.name,
        "predecessor": verdict["predecessor_commit"],
        "supersedes": "",
    }


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
    objective_class = verdict["declared_objective"]["workload_class"]
    head = frontier.view(ledger.load(repo), objective_class).head
    outcome, gates_cell = decide_outcome(
        verdict, float(head.prove_ms) if head is not None else None
    )
    epoch = ledger.current_epoch(repo)["epoch"]
    row = row_from_verdict(sub, verdict, epoch, outcome, gates_cell)
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
