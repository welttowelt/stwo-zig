import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "autoresearch" / "backend"))
sys.path.insert(0, str(ROOT / "autoresearch" / "cli"))

import canonical  # noqa: E402
from stwo_perf import qualification  # noqa: E402
from stwo_perf.manifest import Manifest  # noqa: E402


def git(repo, *args):
    return subprocess.run(
        ["git", *args], cwd=repo, check=True, capture_output=True, text=True,
    ).stdout.strip()


def person(github_id, login, name):
    return {
        "github_id": github_id, "login": login, "name": name,
        "profile_url": f"https://github.com/{login}",
        "noreply_email": f"{github_id}+{login}@users.noreply.github.com",
    }


class CanonicalCommitTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name)
        self.repo = self.base / "repo"
        self.repo.mkdir()
        git(self.repo, "init")
        git(self.repo, "config", "user.name", "Test")
        git(self.repo, "config", "user.email", "test@example.test")
        (self.repo / "src/core/fields").mkdir(parents=True)
        (self.repo / "autoresearch").mkdir()
        (self.repo / "src/core/fields/value.zig").write_text("const value = 1;\n")
        (self.repo / "autoresearch/policy.txt").write_text("locked\n")
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-m", "frontier")
        self.frontier = git(self.repo, "rev-parse", "HEAD")
        self.manifest = Manifest(self.repo, {
            "editable_paths": [{"glob": "src/core/fields/**", "min_rung": "s3"}],
            "locked_paths": ["autoresearch/**"],
        })
        (self.repo / "src/core/fields/value.zig").write_text("const value = 2;\n")
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-m", "untrusted source metadata")
        self.source = git(self.repo, "rev-parse", "HEAD")
        self.source_ref = "refs/autoresearch/source/sub-1"
        git(self.repo, "update-ref", self.source_ref, self.source)
        claim = {"board": "core_cpu", "workload_class": "small",
                 "dimension": "time", "shipping_index": 0.9}
        self.receipt = qualification.build_receipt(
            self.repo, self.manifest, self.frontier, "alice",
            {name: True for name in qualification.REQUIRED_CHECKS}, claim,
        )
        git(self.repo, "checkout", "--detach", self.frontier)

    def tearDown(self):
        subprocess.run(
            ["git", "worktree", "remove", "--force", str(self.base / "candidate")],
            cwd=self.repo, capture_output=True,
        )
        self.tmp.cleanup()

    def test_exact_tree_is_bot_committed_with_verified_coauthors(self):
        record = {
            "id": "sub-1",
            "author": person(1, "alice", "Alice Example"),
            "coauthors": [{
                "login": "bob", "status": "accepted",
                "identity": person(2, "bob", "Bob Example"),
            }],
            "source": {
                "repository": "https://github.com/alice/fork",
                "commit": self.source, "frontier_commit": self.frontier,
            },
            "qualification": {"receipt": self.receipt},
            "intake_evidence": {"source_ref": self.source_ref},
        }
        destination = self.base / "candidate"
        commit = canonical.materialize_candidate(
            self.repo, self.manifest, record, destination,
        )
        self.assertEqual(git(destination, "rev-parse", "HEAD^"), self.frontier)
        self.assertEqual(git(destination, "rev-parse", "HEAD^{tree}"),
                         self.receipt["candidate_tree"])
        self.assertEqual(git(destination, "show", "-s", "--format=%an", commit),
                         canonical.BOT_NAME)
        message = git(destination, "show", "-s", "--format=%B", commit)
        self.assertIn("Co-authored-by: Alice Example <1+alice@users.noreply.github.com>", message)
        self.assertIn("Co-authored-by: Bob Example <2+bob@users.noreply.github.com>", message)


if __name__ == "__main__":
    unittest.main()
