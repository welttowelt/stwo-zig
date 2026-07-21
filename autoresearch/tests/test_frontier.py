import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "cli"))
from stwo_perf import frontier, ledger
from test_ledger import HEADER, row_line
from test_ledger_v3 import v3_values


def rows(*lines: str) -> list[ledger.Row]:
    return ledger.parse(HEADER + "\n" + "\n".join(lines) + "\n")


def complete_row(name: str, index: int, **overrides) -> str:
    fields = {
        "submission_id": name,
        "commit": f"{index:040x}",
        "judged_at_utc": f"2026-07-21T16:{index:02d}:00Z",
        "peak_rss_mib": 20.0,
        "energy_j": 2.0,
        "proof_bytes": 4096,
    }
    fields.update(overrides)
    values = v3_values(**fields)
    return ledger.serialize_row(values)


class FrontierTest(unittest.TestCase):
    SCORED_CLASSES = ["small", "wide", "deep", "xlarge", "huge"]

    def test_dominated_row_excluded(self):
        data = rows(
            complete_row("a", 1, prove_ms=4.0, peak_rss_mib=30.0),
            complete_row("b", 2, prove_ms=3.0, peak_rss_mib=25.0),
        )
        v = frontier.view(data, "core_cpu", "small")
        self.assertEqual([r.commit for r in v.frontier], [f"{2:040x}"])
        self.assertEqual(v.head.commit, f"{2:040x}")

    def test_tradeoff_rows_both_on_frontier(self):
        data = rows(
            complete_row("a", 1, prove_ms=3.0, peak_rss_mib=40.0),
            complete_row("b", 2, prove_ms=4.0, peak_rss_mib=20.0),
        )
        v = frontier.view(data, "core_cpu", "small")
        self.assertEqual(len(v.frontier), 2)

    def test_incomplete_legacy_row_cannot_dominate_complete_vector(self):
        data = rows(
            row_line(commit="legacy", prove_ms="1.0", peak_rss_mib="10"),
            complete_row("complete", 2, prove_ms=3.0, peak_rss_mib=20.0),
        )
        view = frontier.view(data, "core_cpu", "small")
        self.assertEqual(len(view.frontier), 2)

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

if __name__ == "__main__":
    unittest.main()
