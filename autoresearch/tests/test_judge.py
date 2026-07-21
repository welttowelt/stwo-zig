import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "autoresearch" / "bots"))
sys.path.insert(0, str(ROOT / "autoresearch" / "cli"))

import judge_action  # noqa: E402
from stwo_perf.manifest import Manifest  # noqa: E402
from test_runner_groups import make_raw  # noqa: E402


class ClaimedBoardTest(unittest.TestCase):
    def setUp(self):
        raw = make_raw(riscv_enabled=True)
        raw["workload_registry"]["groups"]["native"]["promotion_eligible"] = True
        raw["workload_registry"]["groups"]["riscv"]["promotion_eligible"] = False
        self.manifest = Manifest(ROOT, raw)

    def test_known_manifest_board_is_preserved(self):
        self.assertEqual(
            judge_action.claimed_board(self.manifest, {"board": "core_cpu"}),
            "core_cpu",
        )
        with self.assertRaisesRegex(SystemExit, "not promotion eligible"):
            judge_action.claimed_board(self.manifest, {"board": "riscv"})

    def test_disabled_board_is_rejected_even_if_marked_promotion_eligible(self):
        raw = make_raw(riscv_enabled=False)
        raw["workload_registry"]["groups"]["riscv"]["promotion_eligible"] = True
        manifest = Manifest(ROOT, raw)
        with self.assertRaisesRegex(SystemExit, "disabled"):
            judge_action.claimed_board(manifest, {"board": "riscv"})

    def test_missing_board_is_rejected(self):
        with self.assertRaises(SystemExit):
            judge_action.claimed_board(self.manifest, {})

    def test_ledger_board_without_workload_group_is_rejected(self):
        with self.assertRaises(SystemExit) as ctx:
            judge_action.claimed_board(self.manifest, {"board": "core_metal"})
        self.assertIn("not registered for promotion", str(ctx.exception))

    def test_unknown_board_is_rejected(self):
        with self.assertRaises(SystemExit) as ctx:
            judge_action.claimed_board(self.manifest, {"board": "invented"})
        self.assertIn("unsupported board", str(ctx.exception))


class ClaimedDivergenceTest(unittest.TestCase):
    def test_uses_portfolio_ci_instead_of_first_workload_ci(self):
        claimed = {"score": {"R_geomean": 0.90}}
        judged = {
            "score": {
                "R_geomean": 1.00,
                "portfolio": {"ci": [0.80, 1.20]},
                "per_workload": {
                    "fast_first": {"ci": [0.99, 1.01]},
                    "slow_second": {"ci": [0.70, 1.30]},
                },
            },
        }
        self.assertIsNone(judge_action.claimed_divergence(claimed, judged))

        judged["score"]["portfolio"]["ci"] = [0.98, 1.02]
        finding = judge_action.claimed_divergence(claimed, judged)
        self.assertEqual(finding["judged_ci_half_width"], 0.02)
        self.assertEqual(finding["gap"], 0.1)

    def test_missing_portfolio_ci_fails_closed(self):
        with self.assertRaisesRegex(SystemExit, "portfolio"):
            judge_action.claimed_divergence(
                {"score": {"R_geomean": 0.9}},
                {"score": {"R_geomean": 1.0, "per_workload": {}}},
            )


if __name__ == "__main__":
    unittest.main()
