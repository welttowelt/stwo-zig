import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "autoresearch" / "cli"))

from stwo_perf import dimensions  # noqa: E402


class RatioEstimateTest(unittest.TestCase):
    def test_paired_estimate_is_deterministic(self):
        first = dimensions.paired_ratio_estimate(
            [10.0, 11.0, 9.0], [9.0, 9.9, 8.1], ci_level=0.95, seed=44,
        )
        second = dimensions.paired_ratio_estimate(
            [10.0, 11.0, 9.0], [9.0, 9.9, 8.1], ci_level=0.95, seed=44,
        )
        self.assertEqual(first, second)
        self.assertAlmostEqual(first.ratio, 0.9)

    def test_exact_proof_size_ratio_has_zero_dispersion(self):
        estimate = dimensions.exact_ratio(1000, 900)
        self.assertEqual(estimate.ratio, 0.9)
        self.assertEqual(estimate.ci, (0.9, 0.9))

    def test_invalid_or_unpaired_samples_fail_closed(self):
        with self.assertRaises(dimensions.DimensionError):
            dimensions.paired_ratio_estimate([1.0], [], ci_level=0.95, seed=1)
        with self.assertRaises(dimensions.DimensionError):
            dimensions.paired_ratio_estimate([0.0], [1.0], ci_level=0.95, seed=1)


class BudgetTest(unittest.TestCase):
    def estimates(self):
        return {
            "peak_rss_mib": dimensions.RatioEstimate(1.01, (0.99, 1.03), 5),
            "energy_j": dimensions.RatioEstimate(0.95, (0.90, 0.99), 5),
            "proof_bytes": dimensions.exact_ratio(1024, 1024),
        }

    def test_complete_vector_within_budget_passes(self):
        result = dimensions.assess_budgets(
            self.estimates(),
            {"peak_rss_mib": 1.05, "energy_j": 1.05, "proof_bytes": 1.0},
        )
        self.assertTrue(result.passed)

    def test_faster_but_fatter_candidate_names_failed_dimension(self):
        estimates = self.estimates()
        estimates["peak_rss_mib"] = dimensions.RatioEstimate(1.08, (1.06, 1.10), 5)
        result = dimensions.assess_budgets(
            estimates,
            {"peak_rss_mib": 1.05, "energy_j": 1.05, "proof_bytes": 1.0},
        )
        self.assertFalse(result.passed)
        self.assertEqual(len(result.failures), 1)
        self.assertEqual(result.failures[0].dimension, "peak_rss_mib")
        self.assertEqual(result.failures[0].reason, "budget_exceeded")

    def test_missing_measurement_and_missing_budget_fail_closed_by_name(self):
        estimates = self.estimates()
        estimates["energy_j"] = None
        result = dimensions.assess_budgets(
            estimates, {"peak_rss_mib": 1.05, "energy_j": 1.05},
        )
        self.assertEqual(
            [(failure.dimension, failure.reason) for failure in result.failures],
            [("energy_j", "measurement_missing"), ("proof_bytes", "budget_missing")],
        )


class ParetoTest(unittest.TestCase):
    def point(self, **overrides):
        value = {
            "prove_ms": 10.0,
            "peak_rss_mib": 100.0,
            "energy_j": 2.0,
            "proof_bytes": 1024.0,
        }
        value.update(overrides)
        return value

    def test_complete_vector_dominates_only_with_one_strict_improvement(self):
        self.assertTrue(dimensions.pareto_dominates(
            self.point(prove_ms=9.0), self.point(),
        ))
        self.assertFalse(dimensions.pareto_dominates(self.point(), self.point()))

    def test_incomplete_vector_cannot_claim_dominance(self):
        incomplete = self.point(energy_j=None)
        self.assertFalse(dimensions.pareto_dominates(incomplete, self.point()))
        self.assertFalse(dimensions.pareto_dominates(self.point(), incomplete))


if __name__ == "__main__":
    unittest.main()
