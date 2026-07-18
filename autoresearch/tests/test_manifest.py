import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "cli"))
from stwo_perf import manifest as manifest_mod

REPO_ROOT = Path(__file__).resolve().parents[2]


class ManifestTest(unittest.TestCase):
    def setUp(self):
        self.m = manifest_mod.load(REPO_ROOT)

    def test_locked_paths(self):
        self.assertTrue(self.m.is_locked("autoresearch/ledger/promotions.tsv"))
        self.assertTrue(self.m.is_locked("scripts/ci.py"))
        self.assertTrue(self.m.is_locked("build.zig"))
        self.assertFalse(self.m.is_locked("src/prover/fri.zig"))

    def test_editable_rungs(self):
        self.assertEqual(self.m.path_rung("src/backends/cpu_scalar/mod.zig"), "s3")
        self.assertEqual(self.m.path_rung("src/prover/work_pool.zig"), "s4")
        self.assertIsNone(self.m.path_rung("README.md"))

    def test_judged_rung_is_mechanical_max(self):
        rung = self.m.judged_rung("s3", ["src/prover/work_pool.zig"])
        self.assertEqual(rung, "s4")
        rung = self.m.judged_rung("s1", ["src/core/fields/m31.zig"])
        self.assertEqual(rung, "s3")  # acceptance floor

    def test_classify_touched(self):
        violations, strays = self.m.classify_touched(
            ["vectors/reports/x.json", "src/prover/fri.zig", "docs/random.md"]
        )
        self.assertEqual(violations, ["vectors/reports/x.json"])
        self.assertEqual(strays, ["docs/random.md"])

    def test_workload_registry(self):
        small = self.m.workloads("small")
        self.assertTrue(small)
        self.assertTrue(all(w.workload_class == "small" for w in small))


if __name__ == "__main__":
    unittest.main()
