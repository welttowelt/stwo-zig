from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parents[1]
REPOSITORY_ROOT = SCRIPT_DIR.parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from cairo_program_benchmark_lib.catalog import (  # noqa: E402
    COMPILER,
    PROGRAMS,
    SOURCE_REPOSITORY,
    resolve_cases,
)
from cairo_program_benchmark_lib.matrix import (  # noqa: E402
    CASE_COUNT,
    MATRIX,
    PROGRAM_COUNT,
    TIER_NAMES,
)


DOCUMENT_PATH = REPOSITORY_ROOT / "docs/design/2026-07-17-cairo-program-matrix.md"


def table_rows(header: str) -> list[list[str]]:
    lines = DOCUMENT_PATH.read_text().splitlines()
    start = lines.index(header)
    rows: list[list[str]] = []
    for line in lines[start + 2 :]:
        if not line.startswith("|"):
            break
        rows.append([cell.strip() for cell in line.strip("|").split("|")])
    return rows


def unquote_code(value: str) -> str:
    if not value.startswith("`") or not value.endswith("`"):
        raise AssertionError(f"expected Markdown code span: {value}")
    return value[1:-1]


def size_and_cycles(value: str) -> tuple[int, int]:
    size, separator, cycles = value.partition(" / ")
    if not separator:
        raise AssertionError(f"expected SIZE / CYCLES cell: {value}")
    return int(size.replace(",", "")), int(cycles.replace(",", ""))


class MatrixAuthorityTests(unittest.TestCase):
    def test_matrix_has_exactly_27_unique_program_tier_identities(self) -> None:
        programs = MATRIX["programs"]
        cases = MATRIX["cases"]
        self.assertEqual(len(programs), PROGRAM_COUNT)
        self.assertEqual(len(cases), CASE_COUNT)
        self.assertEqual(len({record["slug"] for record in programs}), PROGRAM_COUNT)
        self.assertEqual(len({record["identity"] for record in cases}), CASE_COUNT)
        self.assertEqual(
            {(record["program"], record["tier"]) for record in cases},
            {
                (program["slug"], tier)
                for program in programs
                for tier in TIER_NAMES
            },
        )

    def test_source_and_compiler_identity_are_complete(self) -> None:
        self.assertEqual(COMPILER["version"], "0.14.0.1")
        self.assertEqual(COMPILER["profile"], "proof_mode")
        self.assertEqual(COMPILER["arguments"], ["--proof_mode"])
        self.assertEqual(
            SOURCE_REPOSITORY["url"],
            "https://github.com/zksecurity/zkvm-benchmarks.git",
        )
        self.assertRegex(SOURCE_REPOSITORY["commit"], r"^[0-9a-f]{40}$")
        for program in PROGRAMS:
            self.assertRegex(program.source_sha256, r"^[0-9a-f]{64}$")

    def test_catalog_defaults_are_the_manifest_tiers(self) -> None:
        cases = resolve_cases(None)
        manifest_cases = {
            (case["program"], case["tier"]): case for case in MATRIX["cases"]
        }
        self.assertEqual(len(cases), PROGRAM_COUNT)
        for program, sizes in cases:
            expected = tuple(
                manifest_cases[(program.slug, tier)]["size"] for tier in TIER_NAMES
            )
            self.assertEqual(sizes, expected)
            for tier, size in zip(program.tiers, sizes, strict=True):
                record = manifest_cases[(program.slug, tier.name)]
                self.assertEqual(tier.expected_cycles, record["expected_cycles"])
                self.assertEqual(program.expected_cycle_count(size), record["expected_cycles"])
        self.assertNotIn(25_000, dict((program.slug, sizes) for program, sizes in cases)["fib"])

    def test_document_program_table_matches_the_manifest(self) -> None:
        rows = table_rows("| Program | Size unit | Input meaning | Primary stress |")
        expected = {
            record["slug"]: record for record in MATRIX["programs"]
        }
        self.assertEqual(len(rows), PROGRAM_COUNT)
        self.assertEqual({unquote_code(row[0]) for row in rows}, set(expected))
        for row in rows:
            record = expected[unquote_code(row[0])]
            self.assertEqual(unquote_code(row[1]), record["size_unit"])
            self.assertEqual(row[2], record["size_semantics"])
            self.assertEqual(row[3], record["primary_stress"])

    def test_document_geometry_table_matches_all_27_cells(self) -> None:
        rows = table_rows(
            "| Program | Small input / cycles | Medium input / cycles | Large input / cycles |"
        )
        manifest_cases = {
            (case["program"], case["tier"]): case for case in MATRIX["cases"]
        }
        self.assertEqual(len(rows), PROGRAM_COUNT)
        for row in rows:
            slug = unquote_code(row[0])
            for index, tier in enumerate(TIER_NAMES, start=1):
                case = manifest_cases[(slug, tier)]
                self.assertEqual(size_and_cycles(row[index]), (case["size"], case["expected_cycles"]))

    def test_document_names_the_same_source_and_compiler_contract(self) -> None:
        document = DOCUMENT_PATH.read_text()
        self.assertIn(SOURCE_REPOSITORY["url"], document)
        self.assertIn(SOURCE_REPOSITORY["commit"], document)
        self.assertIn(f"`{COMPILER['version']}`", document)
        self.assertRegex(document, re.escape("Fib25k is a separate implementation bring-up"))


if __name__ == "__main__":
    unittest.main()
