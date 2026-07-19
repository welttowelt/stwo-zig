"""Fast-forward a signed canonical candidate and publish its research record."""

from __future__ import annotations

import datetime as dt
import json
import os
import subprocess
from pathlib import Path
from typing import Callable

from canonical import BOT_EMAIL, BOT_NAME, CanonicalError, current_commit
from store import Store

import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "cli"))
from stwo_perf import ledger, qualification, signing  # noqa: E402


class PromotionError(RuntimeError):
    pass


def _git(repo: Path, *args: str, env: dict | None = None) -> str:
    proc = subprocess.run(
        ["git", *args], cwd=repo, capture_output=True, text=True, env=env,
    )
    if proc.returncode != 0:
        raise PromotionError(f"git {' '.join(args)} failed: {proc.stderr.strip()}")
    return proc.stdout.strip()


def _row(record: dict) -> dict:
    verdict = record["judged_verdict"]
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
        "epoch": 0,  # replaced from the canonical repository immediately before append
        "judged_at_utc": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "commit": verdict["repo_commit"],
        "scope": verdict["scope"],
        "board": objective["board"],
        "workload_class": objective["workload_class"],
        "outcome": "promoted",
        "judged_r": float(score["R_geomean"]),
        "ci_low": float(first["ci"][0]),
        "ci_high": float(first["ci"][1]),
        "prove_ms": float(first["b_median_ms"]),
        "native_mhz": 0.0,
        "peak_rss_mib": 0.0,
        "waits": None,
        "dispatches": None,
        "energy_j": None,
        "gates": record["gates_cell"],
        "holdout": holdout_cell,
        "submission_id": record["id"],
        "predecessor": verdict["predecessor_commit"],
        "supersedes": "",
    }


def _write_record(repo: Path, record: dict) -> Path:
    sub = repo / "autoresearch" / "submissions" / record["id"]
    if sub.exists():
        raise PromotionError(f"research record already exists: {sub}")
    sub.mkdir(parents=True)
    (sub / "note.md").write_text(record["note"])
    public = {
        "schema_version": 2,
        "id": record["id"],
        "author": record["author"],
        "coauthors": record.get("coauthors", []),
        "source": record["source"],
        "claim": record["claim"],
        "canonical_commit": record["canonical_commit"],
        "qualification": record["qualification"],
    }
    (sub / "remote.json").write_text(json.dumps(public, indent=2, sort_keys=True) + "\n")
    (sub / "judged-verdict.json").write_text(
        json.dumps(record["judged_verdict"], indent=2, sort_keys=True) + "\n"
    )
    delta = {
        "schema_version": 2,
        "predecessor_commit": record["source"]["frontier_commit"],
        "source_commit": record["source"]["commit"],
        "canonical_commit": record["canonical_commit"],
        "candidate_tree": record["qualification"]["receipt"]["candidate_tree"],
        "patch_bytes": record["qualification"]["receipt"]["patch_bytes"],
        "patch_digest": record["qualification"]["receipt"]["patch_digest"],
        "changed_paths": record["qualification"]["receipt"]["changed_paths"],
        "qualification_receipt": qualification.receipt_digest(
            record["qualification"]["receipt"]
        ),
    }
    (sub / "delta.json").write_text(json.dumps(delta, indent=2, sort_keys=True) + "\n")
    return sub


def _push(repo: Path, remote: str, branch: str, expected_commit: str) -> None:
    if current_commit(repo) != expected_commit:
        raise PromotionError("local promotion tip changed before push")
    _git(repo, "push", remote, f"HEAD:refs/heads/{branch}")


def _resume(store: Store, repo: Path, record: dict,
            push_remote: str | None, branch: str,
            push_fn: Callable[[Path, str, str, str], None] | None = None,
            ) -> dict:
    promotion_commit = record.get("promotion_commit")
    try:
        at_recorded_tip = bool(promotion_commit) and current_commit(repo) == promotion_commit
    except RuntimeError:
        at_recorded_tip = False
    if not at_recorded_tip:
        return store.transition(
            record["id"], {"promoting"}, "promotion_error",
            "cannot resume: canonical checkout is not at recorded promotion tip",
        )
    if push_remote:
        try:
            (push_fn or _push)(repo, push_remote, branch, promotion_commit)
        except PromotionError as exc:
            return store.transition(
                record["id"], {"promoting"}, "promoting",
                "canonical commits ready; remote push will be retried",
                {"worker_error": str(exc)},
            )
    return store.transition(
        record["id"], {"promoting"}, "promoted",
        "canonical source and research record published",
        {"promoted_commit": record["canonical_commit"], "ledger_commit": promotion_commit},
    )


def process_one(store: Store, repo: Path, push_remote: str | None = None,
                branch: str = "main", *,
                push_fn: Callable[[Path, str, str, str], None] | None = None,
                record_writer: Callable[[Path, dict], Path] | None = None,
                ) -> dict | None:
    # A failed network push is resumable without rewriting either canonical
    # commit; retry it before claiming another candidate.
    promoting = sorted(
        (s for s in store.snapshot()["submissions"] if s["state"] == "promoting"),
        key=lambda item: (item["created_utc"], item["id"]),
    )
    if promoting:
        return _resume(store, repo, promoting[0], push_remote, branch, push_fn)

    record = store.claim_next({"promotable"}, "promoting", "claimed by promotion worker")
    if record is None:
        return None
    try:
        signing.verify(record["judged_verdict"])
        if record["judged_verdict"].get("canonical_commit") != record["canonical_commit"]:
            raise PromotionError("signed verdict names a different canonical commit")
        if current_commit(repo) != record["judged_frontier"]:
            return store.transition(
                record["id"], {"promoting"}, "stale",
                "frontier moved before promotion",
            )
        if _git(repo, "status", "--porcelain"):
            raise PromotionError("canonical checkout is dirty")
        parent = _git(repo, "rev-parse", f"{record['canonical_commit']}^")
        if parent != record["judged_frontier"]:
            raise PromotionError("canonical candidate is not a one-commit frontier child")
        expected_tree = record["qualification"]["receipt"]["candidate_tree"]
        actual_tree = _git(repo, "rev-parse", f"{record['canonical_commit']}^{{tree}}")
        if actual_tree != expected_tree:
            raise PromotionError("canonical candidate tree no longer matches receipt")
        _git(repo, "merge", "--ff-only", record["canonical_commit"])
        sub = (record_writer or _write_record)(repo, record)
        row = _row(record)
        row["epoch"] = ledger.current_epoch(repo)["epoch"]
        ledger.append(repo, row)
        _git(repo, "add", str(sub), str(ledger.ledger_path(repo)))
        env = {
            **os.environ,
            "GIT_AUTHOR_NAME": BOT_NAME,
            "GIT_AUTHOR_EMAIL": BOT_EMAIL,
            "GIT_COMMITTER_NAME": BOT_NAME,
            "GIT_COMMITTER_EMAIL": BOT_EMAIL,
            "PROMOTION_BOT": "1",
        }
        _git(
            repo, "commit", "--no-gpg-sign", "-m",
            f"autoresearch: record promoted submission {record['id']}", env=env,
        )
        promotion_commit = current_commit(repo)
        record = store.transition(
            record["id"], {"promoting"}, "promoting",
            "canonical source and ledger commits prepared",
            {"promotion_commit": promotion_commit},
        )
        return _resume(store, repo, record, push_remote, branch, push_fn)
    except (PromotionError, CanonicalError, signing.SigningError, ledger.LedgerError,
            OSError, subprocess.SubprocessError) as exc:
        # Keep only a fully materialized promotion automatically resumable.
        # Partial worktree mutations need explicit repair, never a guessed reset.
        try:
            latest = store.get_submission(record["id"]) or record
            retryable = bool(latest.get("promotion_commit"))
            return store.transition(
                record["id"], {"promoting"},
                "promoting" if retryable else "promotion_error",
                "promotion paused for operator-safe retry",
                {"worker_error": str(exc)},
            )
        except Exception:
            raise PromotionError(str(exc)) from exc
