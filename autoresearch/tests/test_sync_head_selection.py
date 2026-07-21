import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "cli"))
from stwo_perf import ledger  # noqa: E402
from stwo_perf.__main__ import latest_promoted_commit  # noqa: E402


def row(board, cls, outcome, judged_at, commit, prove_ms=10.0):
    return ledger.Row(values={
        "board": board,
        "workload_class": cls,
        "outcome": outcome,
        "judged_at_utc": judged_at,
        "commit": commit,
        "prove_ms": prove_ms,
        "peak_rss_mib": 0.0,
        "supersedes": "",
    })


class LatestPromotedCommitTest(unittest.TestCase):
    """Regression for issue #21: cmd_sync's head scan must be board-aware.

    The pre-board call frontier.view(rows, cls) crashed with TypeError the
    moment the frontier became board-aware; this pins the fixed selection
    across empty, single-board, and multi-board ledgers."""

    def test_empty_ledger_selects_none(self):
        self.assertIsNone(latest_promoted_commit([]))

    def test_single_board_selects_newest_head(self):
        rows = [
            row("core_cpu", "small", "promoted", "2026-07-20T10:00:00Z", "aaa"),
            row("core_cpu", "deep", "promoted", "2026-07-20T12:00:00Z", "bbb"),
            row("core_cpu", "wide", "rejected", "2026-07-20T13:00:00Z", "ccc"),
        ]
        self.assertEqual(latest_promoted_commit(rows), "bbb")

    def test_newest_promotion_on_other_board_wins(self):
        rows = [
            row("core_cpu", "small", "promoted", "2026-07-20T10:00:00Z", "aaa"),
            row("core_metal", "wide", "promoted", "2026-07-21T09:00:00Z", "ddd"),
        ]
        self.assertEqual(latest_promoted_commit(rows), "ddd")

    def test_only_non_promoted_rows_selects_none(self):
        rows = [
            row("core_metal", "small", "rejected", "2026-07-21T09:00:00Z", "eee"),
            row("core_cpu", "deep", "neutral", "2026-07-21T10:00:00Z", "fff"),
        ]
        self.assertIsNone(latest_promoted_commit(rows))


if __name__ == "__main__":
    unittest.main()
