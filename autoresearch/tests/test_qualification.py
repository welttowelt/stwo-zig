import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "autoresearch" / "cli"))

from stwo_perf.manifest import Manifest  # noqa: E402
from stwo_perf import qualification  # noqa: E402


def git(repo, *args):
    return subprocess.run(
        ["git", *args], cwd=repo, check=True, capture_output=True, text=True,
    ).stdout.strip()


class QualificationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
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

    def tearDown(self):
        self.tmp.cleanup()

    def _commit_edit(self):
        (self.repo / "src/core/fields/value.zig").write_text("const value = 2;\n")
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-m", "candidate")

    def test_receipt_roundtrip_recomputes_git_evidence(self):
        self._commit_edit()
        claim = {"board": "core_cpu", "workload_class": "small",
                 "dimension": "time", "shipping_index": 0.9}
        receipt = qualification.build_receipt(
            self.repo, self.manifest, self.frontier, "alice",
            {name: True for name in qualification.REQUIRED_CHECKS}, claim,
        )
        evidence = qualification.verify_receipt(self.repo, self.manifest, receipt)
        self.assertEqual(evidence.candidate_tree, receipt["candidate_tree"])
        self.assertEqual(receipt["changed_paths"], ["src/core/fields/value.zig"])

    def test_locked_change_is_rejected(self):
        (self.repo / "autoresearch/policy.txt").write_text("tampered\n")
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-m", "bad")
        with self.assertRaises(qualification.QualificationError):
            qualification.inspect_tree(self.repo, self.manifest, self.frontier)

    def test_executable_editable_file_is_rejected(self):
        self._commit_edit()
        path = self.repo / "src/core/fields/value.zig"
        path.chmod(0o755)
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-m", "mode")
        with self.assertRaises(qualification.QualificationError):
            qualification.inspect_tree(self.repo, self.manifest, self.frontier)


if __name__ == "__main__":
    unittest.main()
