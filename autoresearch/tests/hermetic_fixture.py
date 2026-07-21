"""Hermetic Git/API fixtures shared by backend integration tests."""

from __future__ import annotations

import hashlib
import json
import subprocess
from pathlib import Path

from stwo_perf import ledger, manifest as manifest_mod, qualification


ALICE = {
    "github_id": 101,
    "login": "alice",
    "name": "Alice Example",
    "profile_url": "https://github.com/alice",
    "noreply_email": "101+alice@users.noreply.github.com",
}
BOB = {
    "github_id": 202,
    "login": "bob",
    "name": "Bob Example",
    "profile_url": "https://github.com/bob",
    "noreply_email": "202+bob@users.noreply.github.com",
}
CLAIM = {
    "board": "core_cpu",
    "workload_class": "small",
    "dimension": "time",
    "shipping_index": 0.9,
}
NOTE = """# Faster field loop

## Model and harness
Hermetic integration judge.
## Hypothesis
Fewer loads.
## Changes
Loop change.
## Results
Public qualification passed.
## Caveats
Central judgment pending.
"""


def git(repo: Path, *args: str) -> str:
    return subprocess.run(
        ["git", *args], cwd=repo, check=True, capture_output=True, text=True,
    ).stdout.strip()


def manifest_document() -> dict:
    return {
        "manifest_version": 2,
        "harness": {"name": "hermetic", "anchor_commit": None},
        "editable_paths": [{"glob": "src/core/fields/**", "min_rung": "s3"}],
        "locked_paths": ["autoresearch/**", ".github/**"],
        "workload_registry": {
            "classes": {
                "small": {
                    "scored": True,
                    "resource": {
                        "profile": "standard",
                        "command_timeout_seconds": 1,
                        "wall_clock_cap_seconds": 1,
                    },
                    "sampling": {
                        "warmups": 1,
                        "samples_per_round": 1,
                        "min_rounds": 1,
                        "max_rounds": 1,
                    },
                },
            },
            "groups": {
                "native": {
                    "enabled": True,
                    "promotion_eligible": True,
                    "board": "core_cpu",
                    "build_step": "true",
                    "binary": "bin/hermetic-bench",
                    "report_schema": "native_proof_v7",
                    "workloads": {
                        "wf": {
                            "class": "small",
                            "args": "--warmups {warmups} --samples {samples}",
                            "native_unit": "rows",
                        },
                    },
                },
            },
            "holdout_generator": {
                "small": {"log_n_rows": [9, 11], "sequence_len": [4, 16]},
            },
        },
        "gates_policy": {
            "ci_level": 0.95,
            "theta_floor": 0.01,
            "dispersion_multiplier": 2.0,
            "targeted_class_budget": 1.02,
            "matrix_row_budget": 1.05,
            "warmups": 1,
            "samples_per_round": 1,
            "min_rounds": 1,
            "max_rounds": 1,
            "search_health": {
                "trailing_window": 1,
                "gradient_snr_threshold": 2.0,
                "auto_boost_rounds": 1,
                "maximum_rounds": 2,
            },
            "wall_clock_cap_seconds": {"small": 1, "wide": 1, "deep": 1},
        },
        "qualification_policy": {
            "schema_version": 1,
            "max_active_per_user": 1,
            "required_checks": list(qualification.REQUIRED_CHECKS),
            "source_commit_must_descend_from_frontier": True,
            "source_modes": ["100644"],
            "max_changed_paths": 10,
            "max_patch_bytes": 100_000,
            "require_github_artifact_attestation": True,
            "central_reverification_required": True,
        },
        "scopes": {"s3": "complete proof transaction"},
    }


class HermeticRepos:
    """A canonical repo plus a local GitHub-fork stand-in and real receipt."""

    def __init__(self, root: Path):
        self.root = root
        self.canonical = root / "canonical"
        self.fork = root / "fork"
        self.canonical.mkdir()
        git(self.canonical, "init", "-b", "main")
        git(self.canonical, "config", "user.name", "Test")
        git(self.canonical, "config", "user.email", "test@example.test")
        (self.canonical / "src/core/fields").mkdir(parents=True)
        (self.canonical / "autoresearch/ledger").mkdir(parents=True)
        (self.canonical / ".github/workflows").mkdir(parents=True)
        (self.canonical / "src/core/fields/value.zig").write_text("one\n")
        (self.canonical / "autoresearch/MANIFEST.json").write_text(
            json.dumps(manifest_document(), indent=2, sort_keys=True) + "\n"
        )
        (self.canonical / "autoresearch/ledger/promotions.tsv").write_text(
            "\t".join(ledger.COLUMNS) + "\n"
        )
        (self.canonical / "autoresearch/ledger/epochs.json").write_text(
            json.dumps({"epochs": [{"epoch": 1, "aa_dispersion": {}}]}) + "\n"
        )
        (self.canonical / ".github/workflows/qualify-fork.yml").write_text(
            "name: locked qualification\n"
        )
        git(self.canonical, "add", ".")
        git(self.canonical, "commit", "-m", "frontier")
        self.frontier = git(self.canonical, "rev-parse", "HEAD")

        git(root, "clone", str(self.canonical), str(self.fork))
        git(self.fork, "config", "user.name", "Alice")
        git(self.fork, "config", "user.email", "alice@example.test")
        git(self.fork, "checkout", "-b", "feature")
        (self.fork / "src/core/fields/value.zig").write_text("two\n")
        git(self.fork, "add", "src/core/fields/value.zig")
        git(self.fork, "commit", "-m", "candidate")
        self.candidate = git(self.fork, "rev-parse", "HEAD")
        self.candidate_tree = git(self.fork, "rev-parse", "HEAD^{tree}")
        self.receipt = qualification.build_receipt(
            self.fork,
            manifest_mod.load(self.fork),
            self.frontier,
            "alice",
            {name: True for name in qualification.REQUIRED_CHECKS},
            dict(CLAIM),
            {"run_id": "hermetic-1", "workflow_ref": "qualify-fork.yml@main"},
        )
        encoded = (json.dumps(self.receipt, indent=2, sort_keys=True) + "\n").encode()
        self.artifact_digest = "sha256:" + hashlib.sha256(encoded).hexdigest()

    def source_url(self, repository: str) -> str:
        if repository != "https://github.com/alice/fork":
            raise AssertionError(f"unexpected repository: {repository}")
        return str(self.fork)

    def verify_attestation(self, receipt_file: Path, source: dict) -> None:
        actual = "sha256:" + hashlib.sha256(receipt_file.read_bytes()).hexdigest()
        if actual != self.artifact_digest:
            raise AssertionError("intake reconstructed the wrong receipt artifact")
        if source["commit"] != self.candidate or source["ref"] != "refs/heads/feature":
            raise AssertionError("attestation verifier received unpinned source identity")

    def payload(self, coauthors: list[str] | None = None) -> dict:
        return {
            "schema_version": 2,
            "source": {
                "repository": "https://github.com/alice/fork",
                "commit": self.candidate,
                "frontier_commit": self.frontier,
                "ref": "refs/heads/feature",
            },
            "qualification": {
                "receipt": self.receipt,
                "attestation": {
                    "artifact_digest": self.artifact_digest,
                    "url": "https://github.com/alice/fork/attestations/hermetic-1",
                },
            },
            "claim": dict(CLAIM),
            "note": NOTE,
            "coauthors": list(coauthors or []),
        }


def passing_verdict(candidate: Path, predecessor: Path, _manifest,
                    workload_class: str, dimension: str, scope: str, *,
                    judged: bool, out_dir: Path, board: str,
                    holdout_seed: int) -> dict:
    """Deterministic benchmark double; Git canonicalization remains real."""
    assert judged is True
    assert workload_class == "small"
    assert dimension == "time"
    assert scope == "s3"
    assert board == "core_cpu"
    assert (candidate / "src/core/fields/value.zig").read_text() == "two\n"
    assert (predecessor / "src/core/fields/value.zig").read_text() == "one\n"
    out_dir.mkdir(parents=True, exist_ok=True)
    candidate_commit = git(candidate, "rev-parse", "HEAD")
    predecessor_commit = git(predecessor, "rev-parse", "HEAD")
    return {
        "schema_version": 1,
        "kind": "judged",
        "harness_commit": "1" * 12,
        "repo_commit": candidate_commit[:12],
        "predecessor_commit": predecessor_commit[:12],
        "scope": scope,
        "declared_objective": {
            "board": board,
            "workload_class": workload_class,
            "dimension": dimension,
        },
        "environment": {"fixture": "hermetic"},
        "search_health": {"measurement_wall_seconds": 25.0},
        "gates": {
            name: {"pass": True}
            for name in ("G1", "G2", "G3", "G4", "G5")
        },
        "score": {
            "R_geomean": 0.9,
            "theta": 0.01,
            "significant": True,
            "neutral": False,
            "per_workload": {
                "wf": {
                    "r": 0.9,
                    "ci": [0.88, 0.92],
                    "a_median_ms": 10.0,
                    "b_median_ms": 9.0,
                    "rounds": 9,
                    "proof_bytes": 4096,
                    "measurement_seconds": 12.5,
                },
            },
        },
        "holdout": {"pass": True, "seed": holdout_seed, "r": 0.95},
    }


class FakeLock:
    def __init__(self):
        self.released = False

    def unlink(self, missing_ok: bool = False) -> None:
        del missing_ok
        self.released = True
