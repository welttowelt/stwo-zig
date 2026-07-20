"""Self-update: the CLI ships inside the repository, so updating the checkout
IS updating the CLI — there is no separate build, install script, or remote
fetch. `stwo-perf update` fast-forwards a clean canonical checkout and reports
whether harness policy (autoresearch/**) changed; workspaces stay pinned and
use `stwo-perf sync` instead. Submission paths call harness_drift() so a
checkout running stale rules warns before it packages anything."""

from __future__ import annotations

import subprocess
from pathlib import Path


class UpdateError(RuntimeError):
    pass


def _git(repo: Path, *args: str, timeout: float | None = None) -> str:
    proc = subprocess.run(
        ["git", *args], cwd=repo, capture_output=True, text=True, timeout=timeout,
    )
    if proc.returncode != 0:
        raise UpdateError(f"git {' '.join(args)} failed: {proc.stderr.strip()}")
    return proc.stdout.strip()


def is_workspace(repo: Path) -> bool:
    """True when this checkout is a linked worktree (a searcher workspace)."""
    git_dir = _git(repo, "rev-parse", "--git-dir")
    common = _git(repo, "rev-parse", "--git-common-dir")
    return (repo / git_dir).resolve() != (repo / common).resolve()


def update(repo: Path) -> dict:
    """Fast-forward a clean canonical checkout to origin/main. Returns
    {old, new, commits, harness_changed}."""
    if _git(repo, "status", "--porcelain"):
        raise UpdateError(
            "working tree is not clean; commit or stash before updating"
        )
    if is_workspace(repo):
        raise UpdateError(
            "this is a searcher workspace (git worktree): update the canonical "
            "checkout with `stwo-perf update` there, then `stwo-perf sync` here"
        )
    branch = _git(repo, "rev-parse", "--abbrev-ref", "HEAD")
    if branch != "main":
        raise UpdateError(
            f"update fast-forwards main only (currently on {branch}); switch to "
            "main or pull the branch yourself"
        )
    old = _git(repo, "rev-parse", "HEAD")
    _git(repo, "fetch", "origin", "main")
    _git(repo, "merge", "--ff-only", "origin/main")
    new = _git(repo, "rev-parse", "HEAD")
    commits = int(_git(repo, "rev-list", "--count", f"{old}..{new}") or "0")
    harness_changed = bool(
        _git(repo, "diff", "--name-only", old, new, "--", "autoresearch/")
    )
    return {"old": old, "new": new, "commits": commits,
            "harness_changed": harness_changed}


def harness_drift(repo: Path, timeout: float = 8.0) -> list[str] | None:
    """Best-effort: harness files that differ between this checkout and
    origin/main. Source divergence is normal mid-effort; autoresearch/**
    divergence means this checkout runs stale rules. None = could not check
    (offline); never raises."""
    try:
        _git(repo, "fetch", "--quiet", "origin", "main", timeout=timeout)
        changed = _git(
            repo, "diff", "--name-only", "HEAD", "origin/main", "--",
            "autoresearch/",
        )
        return [line for line in changed.splitlines() if line]
    except (UpdateError, subprocess.TimeoutExpired, OSError):
        return None
