import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "cli"))
from stwo_perf import frontier, ledger
from test_ledger import HEADER, row_line


def rows(*lines: str) -> list[ledger.Row]:
    return ledger.parse(HEADER + "\n" + "\n".join(lines) + "\n")


class FrontierTest(unittest.TestCase):
    SCORED_CLASSES = ["small", "wide", "deep", "xlarge", "huge"]

    def test_dominated_row_excluded(self):
        data = rows(
            row_line(commit="a", prove_ms="4.0", peak_rss_mib="30"),
            row_line(commit="b", prove_ms="3.0", peak_rss_mib="25",
                     judged_at_utc="2026-07-18T02:00:00Z", submission_id="s2"),
        )
        v = frontier.view(data, "core_cpu", "small")
        self.assertEqual([r.commit for r in v.frontier], ["b"])
        self.assertEqual(v.head.commit, "b")

    def test_tradeoff_rows_both_on_frontier(self):
        data = rows(
            row_line(commit="a", prove_ms="3.0", peak_rss_mib="40"),
            row_line(commit="b", prove_ms="4.0", peak_rss_mib="20",
                     judged_at_utc="2026-07-18T02:00:00Z", submission_id="s2"),
        )
        v = frontier.view(data, "core_cpu", "small")
        self.assertEqual(len(v.frontier), 2)

    def test_gate_failing_row_excluded(self):
        data = rows(row_line(commit="a", gates="G3:fail", outcome="rejected"))
        v = frontier.view(data, "core_cpu", "small")
        self.assertIsNone(v.head)

    def test_neutral_row_excluded_from_frontier(self):
        data = rows(row_line(commit="a", outcome="neutral"))
        v = frontier.view(data, "core_cpu", "small")
        self.assertIsNone(v.head)

    def test_superseded_row_excluded(self):
        # supersedes key must match judged_at+commit of the first row
        first = row_line(commit="a", judged_at_utc="2026-07-18T01:00:00Z")
        correction = row_line(
            commit="a2", judged_at_utc="2026-07-18T03:00:00Z", submission_id="s2",
            supersedes="2026-07-18T01:00:00Z+a",
        )
        data = rows(first, correction)
        v = frontier.view(data, "core_cpu", "small")
        self.assertEqual([r.commit for r in v.frontier], ["a2"])

    def test_drift_budget_vs_anchor(self):
        data = rows(row_line(commit="a", prove_ms="4.2"))
        drift = frontier.drift_vs_anchor(data, "core_cpu", "small", anchor_prove_ms=4.0,
                                         matrix_budget=1.05, targeted_budget=1.02)
        self.assertFalse(drift["within_targeted"])
        self.assertTrue(drift["within_matrix"])

    def test_same_class_on_another_board_never_changes_head(self):
        data = rows(
            row_line(commit="native", board="core_cpu", prove_ms="4.0"),
            row_line(
                commit="riscv", board="riscv", prove_ms="1.0",
                judged_at_utc="2026-07-18T02:00:00Z", submission_id="s2",
            ),
        )
        self.assertEqual(frontier.view(data, "core_cpu", "small").head.commit, "native")
        self.assertEqual(frontier.view(data, "riscv", "small").head.commit, "riscv")

    def test_new_five_class_epoch_starts_at_identity(self):
        old = rows(
            row_line(workload_class="small", judged_r="0.5", epoch="1"),
            row_line(
                workload_class="xlarge", judged_r="0.2", epoch="1",
                commit="old-large", judged_at_utc="2026-07-18T02:00:00Z",
                submission_id="old-large",
            ),
        )
        score = frontier.board_suite_score(
            old, "core_cpu", self.SCORED_CLASSES, epoch=2,
        )
        self.assertEqual(score["ratio_geomean"], 1.0)
        self.assertEqual(score["index"], 100.0)
        self.assertEqual(score["class_ratios"], {
            name: 1.0 for name in self.SCORED_CLASSES
        })

    def test_only_effective_current_epoch_large_promotions_move_suite(self):
        data = rows(
            row_line(
                epoch="2", workload_class="xlarge", judged_r="0.9",
                commit="xl-old", judged_at_utc="2026-07-21T01:00:00Z",
                submission_id="xl-old",
            ),
            row_line(
                epoch="2", workload_class="xlarge", judged_r="0.8",
                commit="xl-judged", judged_at_utc="2026-07-21T02:00:00Z",
                submission_id="xl-judged",
                supersedes="2026-07-21T01:00:00Z+xl-old",
            ),
            row_line(
                epoch="2", workload_class="huge", judged_r="0.5",
                commit="huge", judged_at_utc="2026-07-21T03:00:00Z",
                submission_id="huge",
            ),
            row_line(
                epoch="2", workload_class="deep", judged_r="0.1",
                outcome="neutral", commit="neutral",
                judged_at_utc="2026-07-21T04:00:00Z", submission_id="neutral",
            ),
            row_line(
                epoch="2", workload_class="wide", judged_r="0.1",
                outcome="rejected", commit="rejected",
                judged_at_utc="2026-07-21T05:00:00Z", submission_id="rejected",
            ),
            row_line(
                epoch="2", board="riscv", workload_class="small", judged_r="0.1",
                commit="other-board", judged_at_utc="2026-07-21T06:00:00Z",
                submission_id="other-board",
            ),
            row_line(
                epoch="1", workload_class="small", judged_r="0.1",
                commit="old-epoch", judged_at_utc="2026-07-21T07:00:00Z",
                submission_id="old-epoch",
            ),
        )
        score = frontier.board_suite_score(
            data, "core_cpu", self.SCORED_CLASSES, epoch=2,
        )
        self.assertEqual(score["class_ratios"]["xlarge"], 0.8)
        self.assertEqual(score["class_ratios"]["huge"], 0.5)
        self.assertEqual(score["promoted_rows"]["xlarge"], 1)
        self.assertAlmostEqual(score["ratio_geomean"], 0.4 ** (1.0 / 5.0))


if __name__ == "__main__":
    unittest.main()
