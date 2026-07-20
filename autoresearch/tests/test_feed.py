import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "cli"))
from stwo_perf import feed, manifest as manifest_mod

REPO_ROOT = Path(__file__).resolve().parents[2]

REQUIRED_KEYS = {
    "feed_schema_version", "project", "provenance", "anchor", "epoch",
    "boards", "metal_resident_progress", "latest_matrix", "history",
    "submissions", "notes_count",
}


class FeedTest(unittest.TestCase):
    def setUp(self):
        self.m = manifest_mod.load(REPO_ROOT)
        self.feed = feed.build_feed(self.m, allow_dirty=True)

    def test_required_keys_present(self):
        self.assertEqual(REQUIRED_KEYS - set(self.feed), set())

    def test_deterministic(self):
        again = feed.build_feed(self.m, allow_dirty=True)
        self.assertEqual(feed.encode(self.feed), feed.encode(again))

    def test_provenance_digests_verify(self):
        import hashlib
        for rel, digest in self.feed["provenance"]["inputs_sha256"].items():
            actual = hashlib.sha256((REPO_ROOT / rel).read_bytes()).hexdigest()
            self.assertEqual(actual, digest, rel)

    def test_boards_cover_all_declared(self):
        from stwo_perf import ledger
        self.assertEqual(set(self.feed["boards"]), set(ledger.BOARDS))

    def test_v2_promotion_scope_partitions_the_board_universe(self):
        from stwo_perf import ledger
        self.assertEqual(self.feed["feed_schema_version"], 2)
        scope = self.feed["promotion_scope"]
        owned = set(scope["owned_boards"])
        future = set(scope["future_boards"])
        self.assertEqual(owned | future, set(ledger.BOARDS))
        self.assertEqual(owned & future, set())
        # Every owned board is owned by exactly the manifest's groups.
        self.assertEqual(owned, {g["board"] for g in scope["groups"].values()})
        for group in scope["groups"].values():
            self.assertIn("enabled", group)
            self.assertTrue(group["workloads"])
            for workload in group["workloads"].values():
                self.assertIn(workload["class"], ("small", "wide", "deep"))

    def test_empty_boards_render_empty_not_invented(self):
        for board, data in self.feed["boards"].items():
            for entry in data["entries"]:
                self.assertIn(entry["outcome"], ("promoted", "neutral", "rejected"))

    def test_latest_matrix_rows_have_lane_medians(self):
        latest = self.feed["latest_matrix"]
        if latest is None:
            self.skipTest("no matrix runs archived")
        self.assertGreater(len(latest["rows"]), 0)
        row = latest["rows"][0]
        self.assertIn("cpu", row["lanes"])
        self.assertIsNotNone(row["lanes"]["cpu"]["prove_ms"])
        self.assertIsNotNone(row["native_unit"])


class FeedGuaranteeTest(unittest.TestCase):
    """Fixture-based tests that exercise the contract, not the happy path."""

    def _bootstrap(self, tmp: Path) -> Path:
        import subprocess
        subprocess.run(["git", "init", "-q", "-b", "main"], cwd=tmp, check=True)
        subprocess.run(["git", "config", "user.email", "t@t"], cwd=tmp, check=True)
        subprocess.run(["git", "config", "user.name", "t"], cwd=tmp, check=True)
        ar = tmp / "autoresearch"
        (ar / "ledger").mkdir(parents=True)
        manifest_raw = json.loads((REPO_ROOT / "autoresearch/MANIFEST.json").read_text())
        (ar / "MANIFEST.json").write_text(json.dumps(manifest_raw))
        header = (REPO_ROOT / "autoresearch/ledger/promotions.tsv").read_text().splitlines()[0]
        (ar / "ledger" / "promotions.tsv").write_text(header + "\n")
        (ar / "ledger" / "epochs.json").write_text(
            (REPO_ROOT / "autoresearch/ledger/epochs.json").read_text()
        )
        subprocess.run(["git", "add", "-A"], cwd=tmp, check=True)
        subprocess.run(["git", "commit", "-qm", "bootstrap"], cwd=tmp, check=True)
        return tmp

    def test_bootstrap_project_builds_a_feed(self):
        """The generic-contract claim: no history, submissions, or notes."""
        import tempfile
        from stwo_perf.manifest import Manifest
        with tempfile.TemporaryDirectory() as raw:
            root = self._bootstrap(Path(raw))
            m = Manifest(root=root, raw=json.loads((root / "autoresearch/MANIFEST.json").read_text()))
            built = feed.build_feed(m)
            self.assertIsNone(built["latest_matrix"])
            self.assertEqual(built["submissions"], [])
            self.assertEqual(built["notes_count"], 0)
            self.assertEqual(built["history"]["runs"], [])
            self.assertEqual(built["provenance"]["dirty_inputs"], [])

    def test_dirty_input_refused(self):
        """Guarantee 1: uncommitted input changes must not publish under HEAD."""
        import tempfile
        from stwo_perf.manifest import Manifest
        with tempfile.TemporaryDirectory() as raw:
            root = self._bootstrap(Path(raw))
            epochs = root / "autoresearch/ledger/epochs.json"
            epochs.write_text(epochs.read_text() + "\n")  # valid but uncommitted
            m = Manifest(root=root, raw=json.loads((root / "autoresearch/MANIFEST.json").read_text()))
            with self.assertRaises(feed.FeedError):
                feed.build_feed(m)
            dirty = feed.build_feed(m, allow_dirty=True)
            self.assertEqual(
                dirty["provenance"]["dirty_inputs"],
                ["autoresearch/ledger/epochs.json"],
            )

    def test_matrix_report_is_digested_and_verified(self):
        """Guarantee 3: the rendered report is in inputs_sha256."""
        m = manifest_mod.load(REPO_ROOT)
        built = feed.build_feed(m, allow_dirty=True)
        latest = built["latest_matrix"]
        if latest is None:
            self.skipTest("no matrix runs archived")
        report_inputs = [k for k in built["provenance"]["inputs_sha256"]
                         if k.endswith("/report.json")]
        self.assertEqual(len(report_inputs), 1)


if __name__ == "__main__":
    unittest.main()
