#!/usr/bin/env python3
"""Regression tests for the curated repository documentation layout."""

from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]

ACTIVE_CONFORMANCE_DOCS = {
    "api-parity.md",
    "contract.md",
    "divergence-log.md",
    "upstream.md",
}

RETIRED_ROOT_DOCS = {
    "API_PARITY.md",
    "CONFORMANCE.md",
    "HANDOVER-2026-07-15.md",
    "Original-Scope-of-Work.md",
    "SPEC.md",
    "UPSTREAM.md",
    "handoff.md",
}

RETIRED_ROOT_BINARIES = {
    "cairo_bench",
    "riscv_bench",
    "riscv_trace_cli",
}


class DocumentationLayoutTests(unittest.TestCase):
    def test_active_conformance_documents_are_compartmentalized(self) -> None:
        conformance_dir = ROOT / "docs" / "conformance"
        actual = {path.name for path in conformance_dir.glob("*.md")}
        self.assertEqual(actual, ACTIVE_CONFORMANCE_DOCS)

    def test_retired_documents_do_not_return_to_root(self) -> None:
        present = {name for name in RETIRED_ROOT_DOCS if (ROOT / name).exists()}
        self.assertEqual(present, set())

    def test_machine_local_binaries_do_not_return_to_root(self) -> None:
        present = {name for name in RETIRED_ROOT_BINARIES if (ROOT / name).exists()}
        self.assertEqual(present, set())

    def test_documentation_index_and_entrypoints_exist(self) -> None:
        required = {
            ROOT / "README.md",
            ROOT / "CONTRIBUTING.md",
            ROOT / "docs" / "README.md",
        }
        self.assertEqual({path for path in required if not path.is_file()}, set())


if __name__ == "__main__":
    unittest.main()
