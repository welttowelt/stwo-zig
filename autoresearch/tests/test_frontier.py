import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "cli"))
from stwo_perf import frontier, ledger
from test_ledger import HEADER, row_line


def rows(*lines: str) -> list[ledger.Row]:
    return ledger.parse(HEADER + "\n" + "\n".join(lines) + "\n")


class FrontierTest(unittest.TestCase):
    def test_dominated_row_excluded(self):
        data = rows(
            row_line(commit="a", prove_ms="4.0", peak_rss_mib="30"),
            row_line(commit="b", prove_ms="3.0", peak_rss_mib="25",
                     judged_at_utc="2026-07-18T02:00:00Z", submission_id="s2"),
        )
        v = frontier.view(data, "small")
        self.assertEqual([r.commit for r in v.frontier], ["b"])
        self.assertEqual(v.head.commit, "b")

    def test_tradeoff_rows_both_on_frontier(self):
        data = rows(
            row_line(commit="a", prove_ms="3.0", peak_rss_mib="40"),
            row_line(commit="b", prove_ms="4.0", peak_rss_mib="20",
                     judged_at_utc="2026-07-18T02:00:00Z", submission_id="s2"),
        )
        v = frontier.view(data, "small")
        self.assertEqual(len(v.frontier), 2)

    def test_gate_failing_row_excluded(self):
        data = rows(row_line(commit="a", gates="G3:fail", outcome="rejected"))
        v = frontier.view(data, "small")
        self.assertIsNone(v.head)

    def test_neutral_row_excluded_from_frontier(self):
        data = rows(row_line(commit="a", outcome="neutral"))
        v = frontier.view(data, "small")
        self.assertIsNone(v.head)

    def test_superseded_row_excluded(self):
        # supersedes key must match judged_at+commit of the first row
        first = row_line(commit="a", judged_at_utc="2026-07-18T01:00:00Z")
        correction = row_line(
            commit="a2", judged_at_utc="2026-07-18T03:00:00Z", submission_id="s2",
            supersedes="2026-07-18T01:00:00Z+a",
        )
        data = rows(first, correction)
        v = frontier.view(data, "small")
        self.assertEqual([r.commit for r in v.frontier], ["a2"])

    def test_drift_budget_vs_anchor(self):
        data = rows(row_line(commit="a", prove_ms="4.2"))
        drift = frontier.drift_vs_anchor(data, "small", anchor_prove_ms=4.0,
                                         matrix_budget=1.05, targeted_budget=1.02)
        self.assertFalse(drift["within_targeted"])
        self.assertTrue(drift["within_matrix"])


if __name__ == "__main__":
    unittest.main()
