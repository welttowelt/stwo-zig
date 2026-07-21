import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "autoresearch" / "cli"))

from stwo_perf import ledger  # noqa: E402
from test_ledger import row_line_v2  # noqa: E402


HEADER = "\t".join(ledger.COLUMNS)


def v3_values(**overrides) -> dict:
    values = {
        "schema_version": 3,
        "harness_commit": "abc123",
        "epoch": 2,
        "judged_at_utc": "2026-07-21T16:01:00Z",
        "commit": "1" * 40,
        "scope": "s3",
        "board": "core_cpu",
        "workload_class": "small",
        "outcome": "promoted",
        "judged_r": 0.95,
        "ci_low": 0.93,
        "ci_high": 0.97,
        "prove_ms": 3.0,
        "native_mhz": 1.0,
        "peak_rss_mib": 20.0,
        "waits": None,
        "dispatches": None,
        "energy_j": None,
        "gates": "G1..G5:pass",
        "holdout": "none",
        "submission_id": "submission-a",
        "predecessor": "0" * 40,
        "supersedes": "",
        "verdict_kind": "judged",
        "row_id": "",
        "observation_id": "",
        "evidence_kind": "promotion",
        "covers": [],
        "credit_replaces": [],
        "evidence_sha256": "sha256:" + "e" * 64,
        "proof_bytes": 4096,
        "measurement_seconds": 12.5,
        "measurement_rounds": 9,
    }
    values.update(overrides)
    if not values["observation_id"]:
        values["observation_id"] = ledger.observation_id(
            values["submission_id"], values["board"], values["workload_class"]
        )
    values["row_id"] = ledger.compute_row_id(values)
    return values


def v3_line(**overrides) -> str:
    return ledger.serialize_row(v3_values(**overrides))


def parsed(*lines: str) -> list[ledger.Row]:
    return ledger.parse(HEADER + "\n" + "\n".join(lines) + "\n")


class LedgerV3Test(unittest.TestCase):
    def test_header_stays_byte_identical_and_v3_roundtrips(self):
        row = parsed(v3_line())[0]
        self.assertEqual(HEADER, (ROOT / "autoresearch/ledger/promotions.tsv").read_text().splitlines()[0])
        self.assertEqual(row.schema_version, 3)
        self.assertEqual(row.evidence_kind, "promotion")
        self.assertEqual(row.covers, ())
        self.assertEqual(row.proof_bytes, 4096)
        self.assertEqual(row.measurement_seconds, 12.5)
        self.assertEqual(row.measurement_rounds, 9)
        self.assertTrue(row.row_id.startswith("sha256:"))

    def test_physical_metadata_does_not_leak_into_values(self):
        row = parsed(v3_line())[0]
        self.assertEqual(row.physical_index, 1)
        self.assertEqual(row.raw_line, v3_line())
        self.assertNotIn("physical_index", row.values)
        self.assertNotIn("raw_line", row.values)
        self.assertNotIn("supersedes_row_id", row.values)

    def test_row_digest_tampering_is_rejected(self):
        cells = v3_line().split("\t")
        cells[ledger.COLUMNS_V3.index("row_id")] = "sha256:" + "0" * 64
        with self.assertRaisesRegex(ledger.LedgerError, "row_id does not match"):
            parsed("\t".join(cells))

    def test_observation_is_bound_to_submission_board_and_class(self):
        cells = v3_line().split("\t")
        cells[ledger.COLUMNS_V3.index("observation_id")] = "sha256:" + "0" * 64
        with self.assertRaisesRegex(ledger.LedgerError, "observation_id does not match"):
            parsed("\t".join(cells))

    def test_list_cells_require_compact_canonical_json(self):
        cells = v3_line().split("\t")
        cells[ledger.COLUMNS_V3.index("covers")] = "[ ]"
        with self.assertRaisesRegex(ledger.LedgerError, "not canonical JSON"):
            parsed("\t".join(cells))

    def test_duplicate_list_ids_are_rejected(self):
        observation = "sha256:" + "a" * 64
        values = v3_values(
            evidence_kind="span_audit", covers=[observation, observation]
        )
        with self.assertRaisesRegex(ledger.LedgerError, "duplicate IDs"):
            parsed(ledger.serialize_row(values))

    def test_resource_and_measurement_cells_are_strictly_positive(self):
        for field, value, message in (
            ("proof_bytes", 0, "proof_bytes"),
            ("measurement_seconds", 0.0, "measurement_seconds"),
            ("measurement_rounds", 0, "measurement_rounds"),
        ):
            with self.subTest(field=field):
                values = v3_values(**{field: value})
                with self.assertRaisesRegex(ledger.LedgerError, message):
                    parsed(ledger.serialize_row(values))

    def test_later_correction_preserves_logical_scope(self):
        first = v3_values()
        correction = v3_values(
            judged_at_utc="2026-07-21T16:02:00Z",
            supersedes=first["row_id"],
            judged_r=0.94,
        )
        rows = parsed(ledger.serialize_row(first), ledger.serialize_row(correction))
        active = ledger.resolve_corrections(rows)
        self.assertEqual([row.row_id for row in active], [correction["row_id"]])
        self.assertEqual(active[0].supersedes_row_id, first["row_id"])

    def test_correction_cannot_cross_board_or_class(self):
        first = v3_values()
        correction = v3_values(
            board="core_metal",
            supersedes=first["row_id"],
            judged_at_utc="2026-07-21T16:02:00Z",
        )
        with self.assertRaisesRegex(ledger.LedgerError, "crosses epoch/board/class"):
            parsed(ledger.serialize_row(first), ledger.serialize_row(correction))

    def test_correction_cannot_fork_an_inactive_target(self):
        first = v3_values()
        correction = v3_values(
            judged_at_utc="2026-07-21T16:02:00Z",
            supersedes=first["row_id"], judged_r=0.94,
        )
        fork = v3_values(
            judged_at_utc="2026-07-21T16:03:00Z",
            supersedes=first["row_id"], judged_r=0.93,
        )
        with self.assertRaisesRegex(ledger.LedgerError, "no longer active"):
            parsed(*(ledger.serialize_row(row) for row in (first, correction, fork)))

    def test_forward_correction_is_rejected(self):
        future = v3_values(judged_at_utc="2026-07-21T16:02:00Z")
        earlier = v3_values(supersedes=future["row_id"])
        with self.assertRaisesRegex(ledger.LedgerError, "one earlier physical row"):
            parsed(ledger.serialize_row(earlier), ledger.serialize_row(future))

    def test_legacy_collision_resolves_only_inside_exact_class(self):
        key = "2026-07-18T01:00:00Z+deadbeef"
        small = row_line_v2(workload_class="small")
        wide = row_line_v2(
            workload_class="wide", submission_id="wide",
        )
        correction = row_line_v2(
            workload_class="small", judged_at_utc="2026-07-18T02:00:00Z",
            submission_id="small-correction", supersedes=key,
        )
        active = ledger.resolve_corrections(parsed(small, wide, correction))
        self.assertEqual(
            [(row.workload_class, row.submission_id) for row in active],
            [("wide", "wide"), ("small", "small-correction")],
        )


class CurrentLedgerGoldenTest(unittest.TestCase):
    def test_legacy_physical_identity_and_current_bytes_are_stable(self):
        rows = ledger.load(ROOT)
        self.assertEqual(len(rows), 85)
        self.assertEqual(
            rows[0].row_id,
            "sha256:1bcba7b980d90e3fe73eed780b90c3fdcb7f750b946c1c6f51c58fffdd1925df",
        )
        self.assertEqual(
            rows[-1].row_id,
            "sha256:0efb2dad7d0fd61298c10a22b01150d3217d3dff8dfcb6d89fff96d70d063201",
        )
        self.assertEqual(len(ledger.resolve_corrections(rows)), 80)


if __name__ == "__main__":
    unittest.main()
