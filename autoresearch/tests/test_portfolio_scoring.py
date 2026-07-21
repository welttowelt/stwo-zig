import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "cli"))

from stwo_perf import runner  # noqa: E402
from stwo_perf.manifest import Manifest, Workload  # noqa: E402
from test_runner_groups import GATES_POLICY, make_raw  # noqa: E402


class PortfolioScoringTest(unittest.TestCase):
    @staticmethod
    def score(workload_id: str, ratio: float) -> runner.WorkloadScore:
        return runner.WorkloadScore(
            workload=Workload(
                workload_id, "small", "--x", "rows", "native"
            ),
            ratios=[ratio, ratio, ratio],
            r=ratio,
            ci=(ratio, ratio),
            a_median_ms=10.0,
            b_median_ms=10.0 * ratio,
            rss_ratio=None,
            proof_bytes=4096,
            measurement_seconds=1.0,
        )

    def test_fast_first_row_cannot_hide_regressing_portfolio_member(self):
        scores = [self.score("fast_first", 0.50), self.score("regressing", 2.20)]
        portfolio = runner.portfolio_summary(scores, 0.95)
        self.assertGreater(portfolio["ci"][0], 1.0)
        self.assertAlmostEqual(portfolio["r"], 1.048808848, places=8)
        significant, neutral, _ = runner.portfolio_promotion_status(
            "time", portfolio["ci"], 0.01
        )
        self.assertFalse(significant)
        self.assertFalse(neutral)

        manifest = Manifest(Path.cwd(), make_raw(riscv_enabled=False))
        with mock.patch.object(runner, "changed_paths", return_value=[]):
            gates = runner._gates(
                Path.cwd(), manifest, scores, GATES_POLICY, False, None,
                "small", "core_cpu",
            )
        self.assertFalse(gates["G4"]["pass"])
        self.assertIn("regressing", gates["G4"]["detail"])
        self.assertIn("matrix row upper CIs 1/2", gates["G4"]["detail"])

    def test_portfolio_seed_is_independent_of_input_order(self):
        scores = [self.score("a", 0.9), self.score("b", 1.1)]
        self.assertEqual(
            runner.portfolio_summary(scores, 0.95),
            runner.portfolio_summary(list(reversed(scores)), 0.95),
        )

    def test_rss_objective_is_explicitly_diagnostic_without_a_portfolio_ci(self):
        significant, neutral, status = runner.portfolio_promotion_status(
            "rss", (0.5, 0.6), 0.01
        )
        self.assertFalse(significant)
        self.assertFalse(neutral)
        self.assertFalse(status["eligible"])
        self.assertIn("dimension-specific portfolio CI", status["reason"])

    def test_aa_can_explicitly_calibrate_a_staged_board(self):
        raw = make_raw(riscv_enabled=False)
        manifest = Manifest(Path.cwd(), raw)
        workload = manifest.workloads(
            "wide", board="riscv", include_disabled=True
        )[0]
        score = runner.WorkloadScore(
            workload=workload,
            ratios=[1.0, 1.0, 1.0],
            r=1.0,
            ci=(0.99, 1.01),
            a_median_ms=12.0,
            b_median_ms=12.5,
            rss_ratio=None,
            proof_bytes=4096,
            measurement_seconds=1.0,
        )
        with (
            mock.patch.object(runner, "build_arm"),
            mock.patch.object(runner, "paired_rounds", return_value=score),
        ):
            receipt = runner.evaluate_aa(
                Path.cwd(), manifest, "wide", Path.cwd(), board="riscv",
                allow_staged=True,
            )
        self.assertEqual(receipt["anchor_prove_ms"], 12.5)
        self.assertEqual(receipt["dispersion"], 0.0)
        self.assertEqual(receipt["portfolio"]["b_median_ms_geomean"], 12.5)
        self.assertEqual(receipt["per_workload"]["riscv_alu"]["b_median_ms"], 12.5)

    def test_aa_dispersion_covers_center_bias_as_well_as_half_width(self):
        self.assertAlmostEqual(
            runner.aa_dispersion([0.991176, 0.999841]), 0.008824,
        )


if __name__ == "__main__":
    unittest.main()
