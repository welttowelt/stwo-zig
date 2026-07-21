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
    "submissions", "notes_count", "search_health",
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

    def test_legacy_search_health_is_honestly_unavailable(self):
        health = self.feed["search_health"]
        self.assertEqual(health["policy"]["gradient_snr_threshold"], 2.0)
        legacy_points = [
            point
            for board in health["boards"].values()
            for cls in board["classes"].values()
            for point in cls["time_series"]
        ]
        self.assertTrue(legacy_points)
        self.assertTrue(all(not point["available"] for point in legacy_points))
        self.assertEqual(
            {point["unavailable_reason"] for point in legacy_points},
            {"legacy_row_has_no_search_health_evidence"},
        )

    def test_provenance_digests_verify(self):
        import hashlib
        for rel, digest in self.feed["provenance"]["inputs_sha256"].items():
            actual = hashlib.sha256((REPO_ROOT / rel).read_bytes()).hexdigest()
            self.assertEqual(actual, digest, rel)

    def test_boards_cover_all_declared(self):
        from stwo_perf import ledger
        self.assertEqual(set(self.feed["boards"]), set(ledger.BOARDS))

    def test_v3_promotion_scope_partitions_the_board_universe(self):
        from stwo_perf import ledger
        self.assertEqual(self.feed["feed_schema_version"], 3)
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
                self.assertIn(workload["class"], scope["class_registry"])

    def test_scored_classes_and_suite_score_are_manifest_owned(self):
        expected_native = ["small", "wide", "deep", "xlarge", "huge"]
        self.assertEqual(self.feed["boards"]["core_cpu"]["scored_classes"], expected_native)
        self.assertEqual(self.feed["boards"]["core_metal"]["scored_classes"], expected_native)
        self.assertEqual(
            self.feed["boards"]["riscv"]["scored_classes"],
            ["small", "wide", "deep"],
        )
        for board in ("core_cpu", "core_metal", "riscv"):
            score = self.feed["boards"][board]["suite_score"]
            self.assertEqual(score["classes"], self.feed["boards"][board]["scored_classes"])
            self.assertEqual(score["epoch"], self.feed["epoch"]["number"])

    def test_empty_boards_render_empty_not_invented(self):
        for board, data in self.feed["boards"].items():
            for entry in data["entries"]:
                self.assertIn(entry["outcome"], ("promoted", "neutral", "rejected"))

    def test_baseline_matrix_is_the_earliest_run(self):
        baseline = self.feed["baseline_matrix"]
        latest = self.feed["latest_matrix"]
        self.assertIsNotNone(baseline)
        self.assertLessEqual(baseline["run_id"], latest["run_id"])
        self.assertTrue(baseline["rows"])

    def test_submissions_carry_attribution_and_record(self):
        for sub in self.feed["submissions"]:
            self.assertIn("solver", sub)
            self.assertIn("verdict_kind", sub)
            self.assertIn("note", sub)
            self.assertIn("transcripts", sub)
            for ref in sub["transcripts"]:
                self.assertTrue(ref["label"])
                self.assertTrue(ref["sha256"])
                self.assertIn(ref["captured_by"], ("harness", "submitter"))

    def test_latest_matrix_rows_have_lane_medians(self):
        latest = self.feed["latest_matrix"]
        if latest is None:
            self.skipTest("no matrix runs archived")
        self.assertGreater(len(latest["rows"]), 0)
        row = latest["rows"][0]
        self.assertIn("cpu", row["lanes"])
        self.assertIsNotNone(row["lanes"]["cpu"]["prove_ms"])
        self.assertIsNotNone(row["native_unit"])

    def test_reference_backends_are_distinct_and_peer_series_is_discoverable(self):
        references = self.feed["references"]
        scalar = references["peer_rust_scalar"]
        simd = references["peer_rust_simd"]
        self.assertEqual(
            scalar["rust_reference"]["backend_type"],
            "stwo::prover::backend::cpu::CpuBackend",
        )
        self.assertEqual(
            simd["rust_reference"]["backend_type"],
            "stwo::prover::backend::simd::SimdBackend",
        )
        self.assertTrue(scalar["proof_equivalence_receipt"]["all_equal"])
        self.assertTrue(simd["proof_equivalence_receipt"]["all_equal"])
        self.assertEqual(
            references["peer_relative_series"]["peer_source"]["commit"],
            "07ea1ccca13351028da94e66babf79e7ce91437f",
        )

    def test_reference_files_are_bound_into_feed_provenance(self):
        inputs = self.feed["provenance"]["inputs_sha256"]
        self.assertIn("autoresearch/reference/peer-rust-scalar.json", inputs)
        self.assertIn("autoresearch/reference/peer-rust-simd.json", inputs)
        self.assertIn("autoresearch/reference/peer-relative-series.json", inputs)

    def test_reference_discovery_rejects_scalar_labeled_as_simd(self):
        import tempfile
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            references = root / "autoresearch/reference"
            references.mkdir(parents=True)
            (references / "peer-rust-simd.json").write_text(json.dumps({
                "schema": "autoresearch-reference-v2",
                "reference_kind": "upstream-rust-backend",
                "name": "peer-rust-simd",
                "rust_reference": {
                    "backend_id": "simd",
                    "backend_type": "stwo::prover::backend::cpu::CpuBackend",
                },
            }))
            with self.assertRaisesRegex(feed.FeedError, "backend identity mismatch"):
                feed._references(root)


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
