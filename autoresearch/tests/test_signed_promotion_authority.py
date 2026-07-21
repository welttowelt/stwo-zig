import importlib.util
import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "autoresearch" / "cli"))

_spec = importlib.util.spec_from_file_location(
    "promote_action_authority", ROOT / "autoresearch" / "bots" / "promote_action.py"
)
promote_action = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(promote_action)


class SignedPromotionAuthorityTest(unittest.TestCase):
    def test_fabricated_riscv_verdict_cannot_reach_ledger_append(self):
        verdict = {
            "declared_objective": {
                "board": "riscv",
                "workload_class": "wide",
            },
        }
        with (
            mock.patch.object(
                promote_action,
                "unrecorded_submissions",
                return_value=[ROOT / "autoresearch" / "submissions" / "fabricated"],
            ),
            mock.patch.object(promote_action, "fetch_signed_verdict", return_value=verdict),
            mock.patch.object(
                promote_action.promotion,
                "require_verdict_promotion_eligible",
                side_effect=promote_action.promotion.PromotionError(
                    "board is not promotion eligible: riscv"
                ),
            ),
            mock.patch.object(promote_action.ledger, "append") as append,
        ):
            with self.assertRaisesRegex(SystemExit, "not promotion eligible"):
                promote_action.main()
        append.assert_not_called()


if __name__ == "__main__":
    unittest.main()
