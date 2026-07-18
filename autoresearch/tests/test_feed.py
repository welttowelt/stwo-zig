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
        self.feed = feed.build_feed(self.m)

    def test_required_keys_present(self):
        self.assertEqual(REQUIRED_KEYS - set(self.feed), set())

    def test_deterministic(self):
        again = feed.build_feed(self.m)
        self.assertEqual(feed.encode(self.feed), feed.encode(again))

    def test_provenance_digests_verify(self):
        import hashlib
        for rel, digest in self.feed["provenance"]["inputs_sha256"].items():
            actual = hashlib.sha256((REPO_ROOT / rel).read_bytes()).hexdigest()
            self.assertEqual(actual, digest, rel)

    def test_boards_cover_all_declared(self):
        from stwo_perf import ledger
        self.assertEqual(set(self.feed["boards"]), set(ledger.BOARDS))

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


if __name__ == "__main__":
    unittest.main()
