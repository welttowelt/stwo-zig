import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "cli"))
from stwo_perf import workspace
from stwo_perf.manifest import Manifest


def _git(cwd, *args):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True)


MANIFEST_RAW = {
    "manifest_version": 2,
    "harness": {"anchor_commit": None},
    "editable_paths": [{"glob": "src/kernel/**", "min_rung": "s3"}],
    "locked_paths": ["harness/**"],
    "workload_registry": {
        "groups": {
            "native": {
                "enabled": True,
                "promotion_eligible": True,
                "board": "core_cpu",
                "build_step": "true",
                "binary": "true",
                "report_schema": "native_proof_v7",
                "workloads": {},
            },
        },
    },
    "gates_policy": {
        "max_rounds": 1,
        "search_health": {
            "trailing_window": 1,
            "gradient_snr_threshold": 2.0,
            "auto_boost_rounds": 1,
            "maximum_rounds": 2,
        },
    },
}


class RestoreTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        _git(self.root, "init", "-q", "-b", "main")
        _git(self.root, "config", "user.email", "t@t")
        _git(self.root, "config", "user.name", "t")
        (self.root / "src" / "kernel").mkdir(parents=True)
        (self.root / "src" / "kernel" / "a.zig").write_text("v1")
        _git(self.root, "add", "-A")
        _git(self.root, "commit", "-qm", "c1")
        self.c1 = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=self.root, capture_output=True, text=True
        ).stdout.strip()
        # tip adds a new file and edits the old one
        (self.root / "src" / "kernel" / "a.zig").write_text("v2")
        (self.root / "src" / "kernel" / "b.zig").write_text("new at tip")
        _git(self.root, "add", "-A")
        _git(self.root, "commit", "-qm", "c2")
        self.manifest = Manifest(root=self.root, raw=MANIFEST_RAW)

    def tearDown(self):
        self.tmp.cleanup()

    def test_restore_is_exact_not_hybrid(self):
        """Files present at tip but absent in the source commit must vanish."""
        workspace.restore_editable_from(self.root, self.manifest, self.c1)
        self.assertEqual((self.root / "src" / "kernel" / "a.zig").read_text(), "v1")
        self.assertFalse((self.root / "src" / "kernel" / "b.zig").exists())

    def test_dirty_worktree_refused_without_force(self):
        (self.root / "src" / "kernel" / "a.zig").write_text("dirty")
        with self.assertRaises(workspace.WorkspaceError):
            workspace.restore_editable_from(self.root, self.manifest, self.c1)

    def test_missing_pathspec_reported_not_silently_ok(self):
        raw = dict(MANIFEST_RAW)
        raw["editable_paths"] = [{"glob": "src/nonexistent/**", "min_rung": "s3"}]
        m = Manifest(root=self.root, raw=raw)
        restored = workspace.restore_editable_from(self.root, m, self.c1)
        self.assertTrue(any("absent in source" in r for r in restored))


if __name__ == "__main__":
    unittest.main()
