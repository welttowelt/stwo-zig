import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "cli"))
from stwo_perf import update  # noqa: E402


def _git(cwd: Path, *args: str) -> str:
    return subprocess.run(
        ["git", *args], cwd=cwd, check=True, capture_output=True, text=True,
    ).stdout.strip()


class UpdateTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        base = Path(self._tmp.name)
        self.origin = base / "origin"
        self.origin.mkdir()
        _git(self.origin, "init", "-q", "-b", "main")
        _git(self.origin, "config", "user.email", "t@example.invalid")
        _git(self.origin, "config", "user.name", "t")
        (self.origin / "autoresearch").mkdir()
        (self.origin / "autoresearch" / "MANIFEST.json").write_text("{}\n")
        (self.origin / "src.zig").write_text("v1\n")
        _git(self.origin, "add", "-A")
        _git(self.origin, "commit", "-q", "-m", "init")
        self.clone = base / "clone"
        _git(base, "clone", "-q", str(self.origin), str(self.clone))
        _git(self.clone, "config", "user.email", "t@example.invalid")
        _git(self.clone, "config", "user.name", "t")

    def _advance_origin(self, path: str, content: str):
        (self.origin / path).write_text(content)
        _git(self.origin, "add", "-A")
        _git(self.origin, "commit", "-q", "-m", f"advance {path}")

    def test_already_current(self):
        result = update.update(self.clone)
        self.assertEqual(result["commits"], 0)
        self.assertFalse(result["harness_changed"])

    def test_fast_forwards_and_reports_harness_change(self):
        self._advance_origin("autoresearch/MANIFEST.json", '{"v": 2}\n')
        result = update.update(self.clone)
        self.assertEqual(result["commits"], 1)
        self.assertTrue(result["harness_changed"])
        self.assertEqual(_git(self.clone, "rev-parse", "HEAD"), result["new"])

    def test_source_only_update_is_not_harness_change(self):
        self._advance_origin("src.zig", "v2\n")
        result = update.update(self.clone)
        self.assertEqual(result["commits"], 1)
        self.assertFalse(result["harness_changed"])

    def test_dirty_tree_refused(self):
        (self.clone / "loose.txt").write_text("dirty")
        with self.assertRaisesRegex(update.UpdateError, "not clean"):
            update.update(self.clone)

    def test_workspace_refused_with_sync_guidance(self):
        ws = Path(self._tmp.name) / "ws"
        _git(self.clone, "worktree", "add", "-q", str(ws), "-b", "effort")
        with self.assertRaisesRegex(update.UpdateError, "sync"):
            update.update(ws)

    def test_harness_drift_detects_stale_rules(self):
        self.assertEqual(update.harness_drift(self.clone), [])
        self._advance_origin("autoresearch/MANIFEST.json", '{"v": 3}\n')
        drift = update.harness_drift(self.clone)
        self.assertEqual(drift, ["autoresearch/MANIFEST.json"])

    def test_harness_drift_ignores_source_divergence(self):
        self._advance_origin("src.zig", "v3\n")
        self.assertEqual(update.harness_drift(self.clone), [])


if __name__ == "__main__":
    unittest.main()
