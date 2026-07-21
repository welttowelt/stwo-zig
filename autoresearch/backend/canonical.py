"""Canonicalize, judge, sign, and classify one centrally queued candidate."""

from __future__ import annotations

import hashlib
import hmac
import os
import subprocess
import tempfile
from pathlib import Path
from typing import Callable

from identity import author_env, coauthor_trailer
from store import Store

import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "cli"))
from stwo_perf import frontier, ledger, manifest as manifest_mod, promotion, qualification, runner, signing  # noqa: E402


class CanonicalError(RuntimeError):
    pass


BOT_NAME = "autoresearch-judge"
BOT_EMAIL = "autoresearch-judge@users.noreply.github.com"


def _run(args: list[str], cwd: Path, data: bytes | None = None,
         env: dict[str, str] | None = None) -> str:
    proc = subprocess.run(
        args, cwd=cwd, input=data, capture_output=True,
        env=env,
    )
    if proc.returncode != 0:
        detail = proc.stderr.decode(errors="replace").strip()
        raise CanonicalError(f"git operation failed ({' '.join(args[:2])}): {detail}")
    return proc.stdout.decode().strip()


def _git(repo: Path, *args: str) -> str:
    return _run(["git", *args], repo)


def current_commit(repo: Path, ref: str = "HEAD") -> str:
    return _git(repo, "rev-parse", f"{ref}^{{commit}}")


def materialize_candidate(repo: Path, manifest: manifest_mod.Manifest,
                          record: dict, destination: Path) -> str:
    """Create one bot-authored commit crediting every verified participant."""
    frontier_commit = record["source"]["frontier_commit"]
    source_ref = record.get("intake_evidence", {}).get("source_ref")
    if not source_ref:
        raise CanonicalError("submission has no centrally pinned source ref")
    if current_commit(repo, source_ref) != record["source"]["commit"]:
        raise CanonicalError("centrally pinned source ref does not match submission")
    try:
        qualification.verify_receipt(
            repo, manifest, record["qualification"]["receipt"],
        )
    except qualification.QualificationError as exc:
        raise CanonicalError(str(exc)) from exc

    _git(repo, "worktree", "add", "--detach", str(destination), frontier_commit)
    patch = subprocess.run(
        ["git", "diff", "--binary", "--full-index", "--no-renames",
         frontier_commit, source_ref],
        cwd=repo, capture_output=True, check=True,
    ).stdout
    _run(["git", "apply", "--index", "--whitespace=nowarn", "-"], destination, patch)
    candidate_tree = _git(destination, "write-tree")
    expected_tree = record["qualification"]["receipt"]["candidate_tree"]
    if candidate_tree != expected_tree:
        raise CanonicalError("canonicalized patch tree does not match qualified source tree")

    coauthors = [
        record["author"],
        *[
            co["identity"] for co in record.get("coauthors", [])
            if co.get("status") == "accepted" and isinstance(co.get("identity"), dict)
        ],
    ]
    if any(co.get("status") != "accepted" for co in record.get("coauthors", [])):
        raise CanonicalError("requested co-author consent is incomplete")
    trailers = "\n".join(coauthor_trailer(person) for person in coauthors)
    message = (
        f"perf(autoresearch): promote submission {record['id']}\n\n"
        f"Source-Repository: {record['source']['repository']}\n"
        f"Source-Commit: {record['source']['commit']}\n"
        f"Frontier-Parent: {frontier_commit}\n"
        f"Qualification-Receipt: {qualification.receipt_digest(record['qualification']['receipt'])}\n"
        f"{trailers}\n"
    )
    # The bot owns the canonical commit; every verified participant receives a
    # GitHub-recognized Co-authored-by trailer. The submitter identity came from
    # GitHub OAuth, never from the submitted note or git metadata.
    env = {
        **os.environ,
        **author_env(
            {"name": BOT_NAME, "noreply_email": BOT_EMAIL},
            BOT_NAME, BOT_EMAIL,
        ),
    }
    _run(["git", "commit", "--no-gpg-sign", "-F", "-"], destination,
         message.encode(), env)
    canonical_commit = current_commit(destination)
    if _git(destination, "rev-parse", "HEAD^{tree}") != expected_tree:
        raise CanonicalError("canonical commit tree changed during commit")
    _git(repo, "update-ref", f"refs/autoresearch/candidates/{record['id']}",
         canonical_commit)
    return canonical_commit


def holdout_seed(record: dict) -> int:
    secret = os.environ.get("JUDGE_HOLDOUT_SECRET") or os.environ.get("JUDGE_HMAC_SECRET")
    if not secret:
        raise CanonicalError("JUDGE_HOLDOUT_SECRET or JUDGE_HMAC_SECRET is required")
    material = (
        record["qualification"]["receipt"]["candidate_tree"] + ":" + record["id"]
    ).encode()
    digest = hmac.new(secret.encode(), material, hashlib.sha256).digest()
    return int.from_bytes(digest[:8], "big")


def decide_outcome(repo: Path, verdict: dict) -> tuple[str, str]:
    gates_ok = all(g["pass"] for g in verdict["gates"].values())
    if not gates_ok:
        failing = ",".join(g for g, value in verdict["gates"].items() if not value["pass"])
        return "rejected", f"{failing}:fail"
    if verdict.get("holdout") is not None and not verdict["holdout"].get("pass"):
        return "rejected", "G1..G5:pass"
    if not verdict["score"]["significant"]:
        outcome = "neutral" if verdict["score"]["neutral"] else "rejected"
        return outcome, "G1..G5:pass"
    objective = verdict["declared_objective"]
    head = frontier.view(
        ledger.load(repo), objective["board"], objective["workload_class"],
    ).head
    # Same rule as promotion.decide_outcome: never compare absolute ms across
    # runs/hosts — a significant claim measured against a stale predecessor
    # is recorded (neutral) until re-measured on top of the current frontier.
    if not promotion.predecessor_is_fresh(repo, verdict, head):
        return "neutral", "G1..G5:pass"
    return "promoted", "G1..G5:pass"


def process_one(store: Store, repo: Path, *,
                evaluator: Callable[..., dict] | None = None,
                lock_acquirer: Callable[[Path], Path] | None = None,
                ) -> dict | None:
    record = store.claim_next({"queued"}, "judging", "claimed by canonical judge")
    if record is None:
        return None
    frontier_commit = record["source"]["frontier_commit"]
    if current_commit(repo) != frontier_commit:
        return store.transition(
            record["id"], {"judging"}, "stale",
            "canonical frontier moved after qualification",
            {"judged_frontier": current_commit(repo)},
        )

    manifest = manifest_mod.load(repo)
    try:
        with tempfile.TemporaryDirectory(prefix="autoresearch-judge-") as tmp:
            tmp_root = Path(tmp)
            candidate = tmp_root / "candidate"
            predecessor = tmp_root / "predecessor"
            try:
                canonical_commit = materialize_candidate(repo, manifest, record, candidate)
                _git(repo, "worktree", "add", "--detach", str(predecessor), frontier_commit)
                lock = (lock_acquirer or runner.acquire_judge_lock)(repo)
                try:
                    claim = record["claim"]
                    verdict = (evaluator or runner.evaluate)(
                        candidate, predecessor, manifest_mod.load(candidate),
                        claim["workload_class"], claim["dimension"], "s3",
                        judged=True, out_dir=tmp_root / "runs", board=claim["board"],
                        holdout_seed=holdout_seed(record),
                    )
                finally:
                    lock.unlink(missing_ok=True)
                verdict.update({
                    "submission_id": record["id"],
                    "canonical_commit": canonical_commit,
                    "source_commit": record["source"]["commit"],
                    "qualification_receipt": qualification.receipt_digest(
                        record["qualification"]["receipt"]
                    ),
                })
                signed = signing.sign(verdict)
                outcome, gates_cell = decide_outcome(repo, verdict)
            finally:
                for worktree in (predecessor, candidate):
                    subprocess.run(
                        ["git", "worktree", "remove", "--force", str(worktree)],
                        cwd=repo, capture_output=True,
                    )
    except (CanonicalError, runner.RunError, signing.SigningError,
            manifest_mod.ManifestError, ledger.LedgerError,
            OSError, subprocess.SubprocessError) as exc:
        return store.transition(
            record["id"], {"judging"}, "rejected", "central judge rejected candidate",
            {"worker_error": str(exc)},
        )

    state = "promotable" if outcome == "promoted" else outcome
    return store.transition(
        record["id"], {"judging"}, state,
        f"central judged outcome: {outcome}",
        {
            "outcome": outcome,
            "gates_cell": gates_cell,
            "canonical_commit": canonical_commit,
            "judged_frontier": frontier_commit,
            "judged_verdict": signed,
        },
    )
