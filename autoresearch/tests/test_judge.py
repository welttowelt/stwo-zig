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
        self.manifest = Manifest(ROOT, make_raw(riscv_enabled=False))

    def test_known_manifest_board_is_preserved(self):
        self.assertEqual(
            judge_action.claimed_board(self.manifest, {"board": "core_cpu"}),
            "core_cpu",
        )
        self.assertEqual(
            judge_action.claimed_board(self.manifest, {"board": "riscv"}),
            "riscv",
        )

    def test_missing_board_is_rejected(self):
        with self.assertRaises(SystemExit):
            judge_action.claimed_board(self.manifest, {})

    def test_ledger_board_without_workload_group_is_rejected(self):
        with self.assertRaises(SystemExit) as ctx:
            judge_action.claimed_board(self.manifest, {"board": "core_metal"})
        self.assertIn("not runnable", str(ctx.exception))

    def test_unknown_board_is_rejected(self):
        with self.assertRaises(SystemExit) as ctx:
            judge_action.claimed_board(self.manifest, {"board": "invented"})
        self.assertIn("unsupported board", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()
