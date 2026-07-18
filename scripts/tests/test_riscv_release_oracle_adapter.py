"""Structural checks for the checked-in pinned Rust CP-11 overlays."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "riscv_release_oracle.py"
sys.path.insert(0, str(SCRIPT.parent))
SPEC = importlib.util.spec_from_file_location("riscv_release_oracle", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
ORACLE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ORACLE)


class AdapterOverlayTest(unittest.TestCase):
    def test_every_overlay_is_checked_in_and_has_a_unique_destination(self) -> None:
        destinations = [destination for destination, _ in ORACLE.ADAPTER_OVERLAYS]
        self.assertEqual(len(destinations), len(set(destinations)))
        for _destination, source in ORACLE.ADAPTER_OVERLAYS:
            self.assertTrue(source.is_file(), source)

    def test_relation_evidence_calls_pinned_production_apis(self) -> None:
        adapter = ORACLE.ADAPTER_SOURCE_PATH.read_text(encoding="utf-8")
        tuples = ORACLE.ADAPTER_TUPLES_SOURCE_PATH.read_text(encoding="utf-8")
        self.assertIn("components.relation_entries(&trace_refs)", adapter)
        self.assertIn("components::gen_interaction_trace(&traces, &relations)", adapter)
        self.assertIn("components.visit_components(&claimed_sum", adapter)
        self.assertIn("public.logup_sum(&relations)", adapter)
        self.assertIn("components.relation_entries(&trace_refs)", tuples)
        self.assertIn("components.visit_components(&claimed_sum", tuples)
        self.assertIn("schema=riscv-relation-tuples-v2", tuples)
        self.assertIn("aggregate_relation=", tuples)
        self.assertNotIn("Relations::dummy()", adapter)
        self.assertNotIn("Relations::dummy()", tuples)


if __name__ == "__main__":
    unittest.main()
