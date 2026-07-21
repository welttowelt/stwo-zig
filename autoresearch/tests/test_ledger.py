import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "cli"))
from stwo_perf import ledger

HEADER = "\t".join(ledger.COLUMNS)


def row_line(**overrides) -> str:
    values = {
        "schema_version": "1", "harness_commit": "abc123", "epoch": "1",
        "judged_at_utc": "2026-07-18T01:00:00Z", "commit": "deadbeef",
        "scope": "s3", "board": "core_cpu", "workload_class": "small", "outcome": "promoted",
        "judged_r": "0.97", "ci_low": "0.96", "ci_high": "0.98", "prove_ms": "3.9",
        "native_mhz": "0.26", "peak_rss_mib": "24.9", "waits": "", "dispatches": "",
        "energy_j": "", "gates": "G1..G5:pass", "holdout": "pass;seed=1",
        "submission_id": "s1", "predecessor": "cafebabe", "supersedes": "",
    }
    values.update({k: str(v) for k, v in overrides.items()})
    return "\t".join(values[c] for c in ledger.COLUMNS)


class ParseTest(unittest.TestCase):
    def test_header_only(self):
        self.assertEqual(ledger.parse(HEADER + "\n"), [])

    def test_roundtrip_row(self):
        rows = ledger.parse(HEADER + "\n" + row_line() + "\n")
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0].commit, "deadbeef")
        self.assertAlmostEqual(rows[0].judged_r, 0.97)
        self.assertIsNone(rows[0].energy_j)
        self.assertTrue(rows[0].gates_passed)

    def test_wrong_column_count_rejected(self):
        with self.assertRaises(ledger.LedgerError):
            ledger.parse(HEADER + "\nnot\tenough\tcolumns\n")

    def test_wrong_header_rejected(self):
        with self.assertRaises(ledger.LedgerError):
            ledger.parse("a\tb\tc\n")


class AppendOnlyTest(unittest.TestCase):
    def test_pure_append_accepted(self):
        base = HEADER + "\n" + row_line() + "\n"
        head = base + row_line(judged_at_utc="2026-07-18T02:00:00Z", commit="feedf00d") + "\n"
        ledger.verify_append_only(base, head)  # must not raise

    def test_edited_row_rejected(self):
        base = HEADER + "\n" + row_line() + "\n"
        head = HEADER + "\n" + row_line(judged_r="0.5") + "\n"
        with self.assertRaises(ledger.LedgerError):
            ledger.verify_append_only(base, head)

    def test_removed_row_rejected(self):
        base = HEADER + "\n" + row_line() + "\n"
        with self.assertRaises(ledger.LedgerError):
            ledger.verify_append_only(base, HEADER + "\n")


def row_line_v2(**overrides) -> str:
    values = {
        "schema_version": "2", "harness_commit": "abc123", "epoch": "1",
        "judged_at_utc": "2026-07-18T01:00:00Z", "commit": "deadbeef",
        "scope": "s3", "board": "core_cpu", "workload_class": "small", "outcome": "promoted",
        "judged_r": "0.97", "ci_low": "0.96", "ci_high": "0.98", "prove_ms": "3.9",
        "native_mhz": "0.26", "peak_rss_mib": "24.9", "waits": "", "dispatches": "",
        "energy_j": "", "gates": "G1..G5:pass", "holdout": "pass;seed=1",
        "submission_id": "s2", "predecessor": "cafebabe", "supersedes": "",
        "verdict_kind": "claimed",
    }
    values.update({k: str(v) for k, v in overrides.items()})
    return "\t".join(values[c] for c in ledger.COLUMNS_V2)


class ParseV2Test(unittest.TestCase):
    def test_v1_rows_read_as_judged(self):
        rows = ledger.parse(HEADER + "\n" + row_line() + "\n")
        self.assertEqual(rows[0].verdict_kind, "judged")

    def test_v2_roundtrip_keeps_kind(self):
        rows = ledger.parse(HEADER + "\n" + row_line_v2() + "\n")
        self.assertEqual(rows[0].verdict_kind, "claimed")
        self.assertEqual(rows[0].schema_version, 2)

    def test_mixed_versions_parse_per_row(self):
        text = HEADER + "\n" + row_line() + "\n" + row_line_v2(
            judged_at_utc="2026-07-18T02:00:00Z", verdict_kind="judged"
        ) + "\n"
        rows = ledger.parse(text)
        self.assertEqual([r.verdict_kind for r in rows], ["judged", "judged"])
        self.assertEqual([r.schema_version for r in rows], [1, 2])

    def test_unknown_verdict_kind_rejected(self):
        with self.assertRaises(ledger.LedgerError):
            ledger.parse(HEADER + "\n" + row_line_v2(verdict_kind="hopeful") + "\n")

    def test_unknown_schema_version_rejected(self):
        with self.assertRaises(ledger.LedgerError):
            ledger.parse(HEADER + "\n" + row_line_v2(schema_version="9") + "\n")

    def test_v1_append_after_v2_row_stays_appendable(self):
        base = HEADER + "\n" + row_line_v2() + "\n"
        head = base + row_line(judged_at_utc="2026-07-18T03:00:00Z") + "\n"
        ledger.verify_append_only(base, head)  # must not raise


class SerializeTest(unittest.TestCase):
    def test_separator_injection_rejected(self):
        values = dict(zip(ledger.COLUMNS, [""] * len(ledger.COLUMNS)))
        values["schema_version"] = "1"
        values["submission_id"] = "evil\tinjection"
        with self.assertRaises(ledger.LedgerError):
            ledger.serialize_row(values)

    def test_missing_schema_version_rejected(self):
        values = dict(zip(ledger.COLUMNS, [""] * len(ledger.COLUMNS)))
        with self.assertRaises(ledger.LedgerError):
            ledger.serialize_row(values)


class CanonicalLedgerTest(unittest.TestCase):
    """Regression for issue #22: the production backend serves whatever the
    committed ledger contains, so every change must keep the current parser
    and the canonical promotions.tsv in agreement — the July 20 outage was
    exactly this pair drifting (v2 rows landing while a pre-v2 parser served)."""

    def test_current_parser_reads_committed_ledger(self):
        repo_root = Path(__file__).resolve().parents[2]
        rows = ledger.load(repo_root)
        self.assertGreater(len(rows), 0)
        for row in rows:
            self.assertIn(row.outcome, ("promoted", "neutral", "rejected"))
            self.assertIn(row.board, ledger.BOARDS)


if __name__ == "__main__":
    unittest.main()
