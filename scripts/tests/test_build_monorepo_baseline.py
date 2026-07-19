from __future__ import annotations

import copy
import json
import tempfile
import unittest
from pathlib import Path

from scripts import check_build_monorepo_baseline as baseline


class BuildMonorepoBaselineTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.receipt = baseline.load(baseline.DEFAULT_BASELINE)

    def test_checked_in_baseline_is_valid(self) -> None:
        self.assertEqual([], baseline.validate(baseline.ROOT, self.receipt))

    def test_tree_substitution_is_rejected(self) -> None:
        changed = copy.deepcopy(self.receipt)
        changed["source"]["tree"] = "0" * 40
        errors = baseline.validate(baseline.ROOT, changed)
        self.assertIn("source tree does not match source commit", errors)

    def test_statistical_policy_substitution_is_rejected(self) -> None:
        changed = copy.deepcopy(self.receipt)
        changed["statistical_policy"]["bootstrap_iterations"] = 100
        errors = baseline.validate(baseline.ROOT, changed)
        self.assertIn("statistical_policy.bootstrap_iterations must be 4000", errors)

    def test_cross_backend_proof_substitution_is_rejected(self) -> None:
        changed = copy.deepcopy(self.receipt)
        changed["benchmark_baselines"]["metal"]["proof_artifact_sha256"] = "f" * 64
        errors = baseline.validate(baseline.ROOT, changed)
        self.assertIn("CPU and Metal baseline rows do not retain the same proof artifact", errors)

    def test_duplicate_json_key_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "duplicate.json"
            path.write_text('{"schema":"a","schema":"b"}', encoding="utf-8")
            with self.assertRaises(baseline.DuplicateKeyError):
                baseline.load(path)


if __name__ == "__main__":
    unittest.main()
