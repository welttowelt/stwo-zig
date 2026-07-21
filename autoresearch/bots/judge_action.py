#!/usr/bin/env python3
"""Judge bot: run the paired evaluation for a submission PR and comment.

Runs on the designated self-hosted judge runner (judge.yml). The submitter's
claimed verdict is advisory; this run is the one that counts. Environment:
GITHUB_TOKEN, GITHUB_REPOSITORY, PR_NUMBER, BASE_SHA (paired A arm).
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT))
sys.path.insert(0, str(REPO_ROOT / "autoresearch" / "cli"))
from stwo_perf import ledger, manifest as manifest_mod, promotion, render, runner, signing  # noqa: E402


def comment(body: str) -> None:
    """Best-effort PR comment; never allowed to fail the judge run —
    the signed verdict must reach the judge-verdicts branch regardless."""
    token = os.environ.get("GITHUB_TOKEN")
    repo = os.environ.get("GITHUB_REPOSITORY")
    pr = os.environ.get("PR_NUMBER")
    if not (token and repo and pr):
        print(body)
        return
    req = urllib.request.Request(
        f"https://api.github.com/repos/{repo}/issues/{pr}/comments",
        data=json.dumps({"body": body}).encode(),
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        urllib.request.urlopen(req, timeout=30)
    except OSError as exc:
        print(f"[judge] PR comment failed ({exc}); verdict body follows:\n{body}")


def find_submission() -> Path:
    """The submission added by THIS PR, derived from the diff vs base —
    never `latest directory in the tree` (which could re-judge old merges)."""
    base_sha = os.environ.get("BASE_SHA", "origin/main")
    merge_base = subprocess.run(
        ["git", "merge-base", base_sha, "HEAD"], capture_output=True, text=True
    ).stdout.strip() or base_sha
    diff = subprocess.run(
        ["git", "diff", "--name-only", merge_base, "HEAD", "--",
         "autoresearch/submissions/"],
        capture_output=True, text=True,
    ).stdout
    names = {
        Path(p).parts[2] for p in diff.splitlines()
        if p.strip() and len(Path(p).parts) > 3
    }
    if len(names) != 1:
        raise SystemExit(
            f"expected exactly one submission directory in this PR, found {sorted(names)}"
        )
    sub = Path("autoresearch/submissions") / names.pop()
    if not (sub / "verdict.json").exists():
        raise SystemExit(f"{sub.name}: missing claimed verdict.json")
    return sub


def claimed_board(manifest: manifest_mod.Manifest, objective: dict) -> str:
    board = objective.get("board")
    if not isinstance(board, str):
        raise SystemExit("claimed verdict must declare a string board")
    if board not in ledger.BOARDS:
        raise SystemExit(f"claimed verdict names unsupported board: {board}")
    try:
        promotion.require_board_promotion_eligible(manifest, board)
    except promotion.PromotionError as exc:
        raise SystemExit(f"claimed board is not admissible: {exc}") from exc
    return board


def claimed_divergence(claimed: dict, judged: dict) -> dict | None:
    claimed_r = claimed.get("score", {}).get("R_geomean")
    if claimed_r is None:
        return None
    score = judged.get("score", {})
    portfolio = score.get("portfolio")
    if not isinstance(portfolio, dict):
        raise SystemExit("judged verdict is missing portfolio confidence evidence")
    ci = portfolio.get("ci")
    if not isinstance(ci, list) or len(ci) != 2:
        raise SystemExit("judged verdict portfolio CI is malformed")
    judged_r = float(score["R_geomean"])
    gap = abs(float(claimed_r) - judged_r)
    judged_half_ci = (float(ci[1]) - float(ci[0])) / 2.0
    if gap <= judged_half_ci:
        return None
    return {
        "claimed_r": float(claimed_r),
        "judged_r": judged_r,
        "gap": round(gap, 6),
        "judged_ci_half_width": round(judged_half_ci, 6),
    }


def main() -> int:
    m = manifest_mod.load(Path.cwd())
    sub = find_submission()
    claimed = json.loads((sub / "verdict.json").read_text())
    objective = claimed.get("declared_objective", {})
    wl_class = objective.get("workload_class", "small")
    dimension = objective.get("dimension", "time")
    scope = claimed.get("scope", "s3")
    board = claimed_board(m, objective)

    base_sha = os.environ.get("BASE_SHA", "origin/main")
    with tempfile.TemporaryDirectory(prefix="stwo-perf-judge-") as tmp:
        pred = Path(tmp) / "predecessor"
        subprocess.run(
            ["git", "worktree", "add", "--detach", str(pred), base_sha],
            check=True, capture_output=True, text=True,
        )
        lock = runner.acquire_judge_lock(m.root)
        try:
            verdict = runner.evaluate(
                m.root, pred, m, wl_class, dimension, scope,
                judged=True, out_dir=Path(tmp) / "runs", board=board,
            )
        finally:
            lock.unlink(missing_ok=True)
            subprocess.run(["git", "worktree", "remove", "--force", str(pred)],
                           capture_output=True)

    # Judged verdicts never live on the searcher's branch: sign, then write to
    # the judge-only verdicts area (published to the judge-verdicts branch by
    # the workflow). The signature — not the location — is the trust anchor.
    verdict["submission_id"] = sub.name
    divergence_finding = claimed_divergence(claimed, verdict)
    verdict["claimed_divergence"] = divergence_finding
    signed = signing.sign(verdict)

    out_dir = Path("judge-out")
    out_dir.mkdir(exist_ok=True)
    (out_dir / f"{sub.name}.json").write_text(json.dumps(signed, indent=2) + "\n")

    text = render.verdict(verdict)
    note = ""
    if divergence_finding:
        note = (
            f"\n\n⚠ claimed R {divergence_finding['claimed_r']} vs judged "
            f"{divergence_finding['judged_r']}: gap {divergence_finding['gap']} exceeds "
            "the judged CI half-width — recorded in the signed verdict."
        )
    gates_ok = all(g["pass"] for g in verdict["gates"].values())
    outcome = "PASS" if gates_ok and verdict["score"]["significant"] else "NO PROMOTION"
    comment(f"### stwo-perf judged verdict — {outcome}\n```\n{text}\n```{note}")
    print(text)
    # Always exit 0: pass/fail is data in the signed verdict, and the verdict
    # (including rejections) must always be published (playbook F.5).
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
