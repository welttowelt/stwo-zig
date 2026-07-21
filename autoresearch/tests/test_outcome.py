import importlib.util
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "cli"))

_spec = importlib.util.spec_from_file_location(
    "promote_action", Path(__file__).resolve().parents[1] / "bots" / "promote_action.py"
)
promote_action = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(promote_action)

from stwo_perf import runner  # noqa: E402


def verdict(significant=True, neutral=False, gates_ok=True, holdout_pass=True,
            b_median=3.0) -> dict:
    return {
        "gates": {g: {"pass": gates_ok or g != "G3"} for g in ("G1", "G2", "G3", "G4", "G5")},
        "holdout": {"pass": holdout_pass, "seed": 7, "r": 1.0},
        "score": {
            "significant": significant,
            "neutral": neutral,
            "per_workload": {"wf": {"b_median_ms": b_median, "ci": [0.9, 0.95]}},
        },
        "declared_objective": {"workload_class": "small"},
    }


class DecideOutcomeTest(unittest.TestCase):
    def test_promoted_when_all_clear(self):
        outcome, gates = promote_action.decide_outcome(verdict(), predecessor_fresh=True)
        self.assertEqual(outcome, "promoted")
        self.assertEqual(gates, "G1..G5:pass")

    def test_gate_failure_rejected(self):
        outcome, gates = promote_action.decide_outcome(
            verdict(gates_ok=False), predecessor_fresh=True
        )
        self.assertEqual(outcome, "rejected")
        self.assertIn("G3", gates)

    def test_holdout_failure_rejected(self):
        outcome, _ = promote_action.decide_outcome(
            verdict(holdout_pass=False), predecessor_fresh=True
        )
        self.assertEqual(outcome, "rejected")

    def test_neutral_recorded_not_promoted(self):
        outcome, _ = promote_action.decide_outcome(
            verdict(significant=False, neutral=True), predecessor_fresh=True
        )
        self.assertEqual(outcome, "neutral")

    def test_stale_predecessor_neutral_never_absolute_ms(self):
        # A significant claim measured against a stale predecessor is
        # recorded without credit — never rejected by comparing absolute
        # milliseconds against a head measured in another run or host.
        outcome, _ = promote_action.decide_outcome(verdict(), predecessor_fresh=False)
        self.assertEqual(outcome, "neutral")


class HoldoutHelpersTest(unittest.TestCase):
    def test_replace_flag(self):
        args = "--example wf --log-n-rows 10 --sequence-len 8"
        out = runner._replace_flag(args, "--log-n-rows", "12")
        self.assertIn("--log-n-rows 12", out)
        self.assertIn("--sequence-len 8", out)

    def test_replace_flag_absent_is_noop(self):
        args = "--example wf"
        self.assertEqual(runner._replace_flag(args, "--log-n-rows", "12"), args)

    def test_seed_is_deterministic(self):
        self.assertEqual(runner._seed("wf", 3), runner._seed("wf", 3))
        self.assertNotEqual(runner._seed("wf", 3), runner._seed("wf", 4))


if __name__ == "__main__":
    unittest.main()
