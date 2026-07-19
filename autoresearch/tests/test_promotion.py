import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "autoresearch" / "backend"))
sys.path.insert(0, str(ROOT / "autoresearch" / "cli"))

import promotion  # noqa: E402
from store import Store  # noqa: E402
from stwo_perf import ledger, signing  # noqa: E402


def git(repo, *args):
    return subprocess.run(
        ["git", *args], cwd=repo, check=True, capture_output=True, text=True,
    ).stdout.strip()


NOTE = """# Faster field loop

## Model and harness
Agent and stwo-perf.
## Hypothesis
Fewer loads.
## Changes
Loop change.
## Results
Judged improvement.
## Caveats
None known.
"""


class PromotionIntegrationTest(unittest.TestCase):
    def test_signed_exact_tree_fast_forwards_and_records_research(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            repo.mkdir()
            git(repo, "init")
            git(repo, "config", "user.name", "Test")
            git(repo, "config", "user.email", "test@example.test")
            (repo / "src/core/fields").mkdir(parents=True)
            (repo / "autoresearch/ledger").mkdir(parents=True)
            (repo / "autoresearch/submissions").mkdir()
            (repo / "src/core/fields/value.zig").write_text("one\n")
            (repo / "autoresearch/ledger/promotions.tsv").write_text(
                "\t".join(ledger.COLUMNS) + "\n"
            )
            (repo / "autoresearch/ledger/epochs.json").write_text(json.dumps({
                "epochs": [{"epoch": 1, "aa_dispersion": {}}],
            }) + "\n")
            git(repo, "add", ".")
            git(repo, "commit", "-m", "frontier")
            frontier = git(repo, "rev-parse", "HEAD")
            (repo / "src/core/fields/value.zig").write_text("two\n")
            git(repo, "add", ".")
            git(repo, "commit", "-m", "canonical candidate")
            candidate = git(repo, "rev-parse", "HEAD")
            candidate_tree = git(repo, "rev-parse", "HEAD^{tree}")
            git(repo, "branch", "candidate", candidate)
            git(repo, "checkout", "-B", "main", frontier)

            author = {
                "github_id": 1, "login": "alice", "name": "Alice",
                "profile_url": "https://github.com/alice",
                "noreply_email": "1+alice@users.noreply.github.com",
            }
            receipt = {
                "schema_version": 1, "candidate_commit": "b" * 40,
                "frontier_commit": frontier, "candidate_tree": candidate_tree,
                "changed_paths": ["src/core/fields/value.zig"],
                "patch_bytes": 123,
                "patch_digest": "sha256:" + "d" * 64,
                "locked_tree_digest": "sha256:" + "e" * 64,
                "submitter_login": "alice", "checks": {}, "claim": {}, "workflow": {},
            }
            base_record = {
                "id": "sub-1", "author": author, "coauthors": [],
                "source": {
                    "repository": "https://github.com/alice/fork",
                    "commit": "b" * 40, "frontier_commit": frontier,
                    "ref": "refs/heads/feature",
                },
                "qualification": {"receipt": receipt},
                "claim": {"board": "core_cpu", "workload_class": "small",
                          "dimension": "time", "shipping_index": 0.9},
                "note": NOTE,
            }
            verdict = {
                "schema_version": 1, "kind": "judged", "submission_id": "sub-1",
                "canonical_commit": candidate, "harness_commit": "1" * 12,
                "repo_commit": candidate[:12], "predecessor_commit": frontier[:12],
                "scope": "s3",
                "declared_objective": {
                    "board": "core_cpu", "workload_class": "small", "dimension": "time",
                },
                "gates": {name: {"pass": True} for name in ("G1", "G2", "G3", "G4", "G5")},
                "score": {
                    "R_geomean": 0.9, "significant": True, "neutral": False,
                    "per_workload": {"wf": {
                        "ci": [0.88, 0.92], "b_median_ms": 9.0,
                    }},
                },
                "holdout": {"pass": True, "seed": 7, "r": 0.95},
            }
            with mock.patch.dict(os.environ, {"JUDGE_HMAC_SECRET": "test-signing-secret"}):
                signed = signing.sign(verdict)
                store = Store(root / "store.json")
                item = store.create_submission(base_record)
                item = store.transition(item["id"], {"received"}, "validating", "test")
                item = store.transition(item["id"], {"validating"}, "queued", "test")
                item = store.transition(item["id"], {"queued"}, "judging", "test")
                store.transition(
                    item["id"], {"judging"}, "promotable", "test",
                    {
                        "canonical_commit": candidate, "judged_frontier": frontier,
                        "judged_verdict": signed, "gates_cell": "G1..G5:pass",
                    },
                )
                promoted = promotion.process_one(store, repo)

            self.assertEqual(promoted["state"], "promoted")
            self.assertEqual(git(repo, "rev-parse", "HEAD^"), candidate)
            sub = repo / "autoresearch/submissions/sub-1"
            self.assertTrue((sub / "remote.json").is_file())
            self.assertTrue((sub / "judged-verdict.json").is_file())
            rows = ledger.load(repo)
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0].submission_id, "sub-1")
            self.assertEqual(rows[0].outcome, "promoted")


if __name__ == "__main__":
    unittest.main()
