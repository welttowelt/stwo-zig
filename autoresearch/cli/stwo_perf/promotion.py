"""Promotion decisions and ledger rows, shared by the promote bot and the CLI.

Two adjudication paths write rows through this module:

- the promote bot (bots/promote_action.py), from an HMAC-signed judged
  verdict — rows carry ``verdict_kind=judged``;
- ``stwo-perf promote-claimed``, the maintainer-as-judge interim path: after
  a human merges a submission PR, the merged submission's claimed verdict is
  recorded optimistically — rows carry ``verdict_kind=claimed`` and are
  expected to be superseded by a judged row when the judge host activates.

A claimed row is never upgraded: the kind travels through the ledger, the
feed, and every consumer (site-feed contract), so optimism stays labeled.
"""

from __future__ import annotations

import datetime as dt
import json
import subprocess
from pathlib import Path

from . import frontier, ledger


class PromotionError(RuntimeError):
    pass


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


def row_from_verdict(submission_id: str, verdict: dict, epoch: int, outcome: str,
                     gates_cell: str, verdict_kind: str,
                     commit: str | None = None) -> dict:
    """Build a ledger row; ``commit`` overrides the verdict's repo_commit
    (the claimed path records the commit that landed the submission)."""
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
        "commit": commit or verdict["repo_commit"],
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
        "submission_id": submission_id,
        "predecessor": verdict["predecessor_commit"],
        "supersedes": "",
        "verdict_kind": verdict_kind,
    }


def _git(repo: Path, *args: str) -> str:
    proc = subprocess.run(
        ["git", *args], cwd=repo, capture_output=True, text=True,
    )
    if proc.returncode != 0:
        raise PromotionError(f"git {' '.join(args)} failed: {proc.stderr.strip()}")
    return proc.stdout


def landing_commit(repo: Path, submission_id: str) -> str:
    """The first commit that introduced the submission directory — the merged
    change itself, reachable on the mainline forever (merge commits only)."""
    out = _git(
        repo, "log", "--reverse", "--format=%H", "--",
        f"autoresearch/submissions/{submission_id}",
    ).strip().splitlines()
    if not out:
        raise PromotionError(
            f"submission {submission_id} has no landing commit in this history"
        )
    return out[0]


def claimed_verdict_files(sub_dir: Path) -> list[Path]:
    """A submission's verdicts: the primary verdict.json plus one
    verdict-<class>.json per additional workload class the change moved."""
    primary = sub_dir / "verdict.json"
    extras = sorted(sub_dir.glob("verdict-*.json"))
    return [p for p in [primary, *extras] if p.is_file()]


def promote_claimed(repo: Path, submission_id: str,
                    verdict_name: str = "verdict.json") -> dict:
    """Maintainer-as-judge: record one of a merged submission's claimed
    verdicts as an optimistic ledger row (one row per moved class). Returns
    the appended row. Refuses anything that is not a merged, schema-clean
    claimed submission or whose (submission, class) is already recorded."""
    if _git(repo, "status", "--porcelain").strip():
        raise PromotionError(
            "working tree is not clean; promote from a clean checkout of the "
            "merged history"
        )
    sub_dir = repo / "autoresearch" / "submissions" / submission_id
    verdict_path = sub_dir / verdict_name
    if not verdict_path.is_file():
        raise PromotionError(f"no verdict at {verdict_path}")
    verdict = json.loads(verdict_path.read_text())
    if verdict.get("kind") != "claimed":
        raise PromotionError(
            "promote-claimed records claimed verdicts only; judged verdicts "
            "arrive via the signed promote path"
        )
    verdict_class = (verdict.get("declared_objective") or {}).get("workload_class")
    if any(
        r.submission_id == submission_id and r.workload_class == verdict_class
        for r in ledger.load(repo)
    ):
        raise PromotionError(
            f"{submission_id} already has a ledger row for class {verdict_class}"
        )

    objective = verdict["declared_objective"]
    head = frontier.view(
        ledger.load(repo), objective.get("board", "core_cpu"),
        objective["workload_class"],
    ).head
    outcome, gates_cell = decide_outcome(
        verdict, float(head.prove_ms) if head is not None else None
    )
    row = row_from_verdict(
        submission_id, verdict, ledger.current_epoch(repo)["epoch"],
        outcome, gates_cell, verdict_kind="claimed",
        commit=landing_commit(repo, submission_id),
    )
    ledger.append(repo, row)
    _git(repo, "add", str(ledger.ledger_path(repo)))
    _git(
        repo, "commit",
        "-m", f"Ledger: {outcome} (claimed) — {submission_id}",
        "-m", "Optimistic maintainer-adjudicated row from the merged claimed "
              "verdict; a judged run supersedes it. [skip ci]",
    )
    return row
