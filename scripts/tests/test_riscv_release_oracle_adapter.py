"""Structural checks for the checked-in pinned Rust CP-11 overlays."""

from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


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


class ProducerProvenanceTest(unittest.TestCase):
    def test_candidate_must_be_the_clean_repository_head(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            subprocess.run(["git", "config", "user.email", "cp11@example.invalid"], cwd=root, check=True)
            subprocess.run(["git", "config", "user.name", "CP11 Test"], cwd=root, check=True)
            subprocess.run(["git", "commit", "--allow-empty", "-qm", "candidate"], cwd=root, check=True)
            head = subprocess.run(
                ["git", "rev-parse", "HEAD"], cwd=root, check=True,
                capture_output=True, text=True,
            ).stdout.strip()
            ORACLE.require_clean_candidate(root, head)
            with self.assertRaisesRegex(SystemExit, "does not match HEAD"):
                ORACLE.require_clean_candidate(root, "0" * 40)
            (root / "untracked").write_text("dirty", encoding="utf-8")
            with self.assertRaisesRegex(SystemExit, "not clean"):
                ORACLE.require_clean_candidate(root, head)

    def test_receipt_loader_rejects_duplicate_fields_at_any_depth(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            receipt = Path(directory) / "receipt.json"
            receipt.write_text(
                '{"oracle":{"commit":"a","commit":"b"}}',
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "duplicate JSON field: commit"):
                ORACLE.load_receipt(receipt)

    def test_release_corpus_cannot_be_empty_or_reuse_case_names(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            vector_dir = root / "vectors/riscv_elfs"
            vector_dir.mkdir(parents=True)
            elf = vector_dir / "case.elf"
            elf.write_bytes(b"elf")
            digest = hashlib.sha256(b"elf").hexdigest()
            manifest = {
                "stark_v_commit": ORACLE.PINNED,
                "vectors": [],
                "negative_vectors": [],
            }
            path = vector_dir / "trace_vectors.json"
            path.write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaisesRegex(SystemExit, "no positive release vectors"):
                ORACLE.load_trace_vectors(root, ORACLE.PINNED, {})

            case = {"name": "same", "elf": "vectors/riscv_elfs/case.elf", "elf_sha256": digest}
            manifest["vectors"] = [case, dict(case)]
            path.write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaisesRegex(SystemExit, "invalid or duplicate name"):
                ORACLE.load_trace_vectors(root, ORACLE.PINNED, {})

    def test_executable_evidence_rejects_self_comparison_and_mid_run_drift(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            rust = root / "rust"
            zig = root / "zig"
            rust.write_bytes(b"rust executable")
            zig.write_bytes(b"zig executable")
            receipt = {"candidate_commit": "a" * 40}
            ORACLE.record_implementation_executable(receipt, "riscv-trace-dump", zig, rust)
            self.assertIn("riscv-trace-dump", receipt["implementation"]["executables"])
            with self.assertRaisesRegex(SystemExit, "self-comparison"):
                ORACLE.record_implementation_executable(receipt, "stwo-zig", rust, rust)
            zig.write_bytes(b"changed Zig executable")
            with self.assertRaisesRegex(SystemExit, "changed during one CP-11 run"):
                ORACLE.record_implementation_executable(receipt, "riscv-trace-dump", zig, rust)

    def test_prescribed_validator_rejects_a_legacy_pass_bit_receipt(self) -> None:
        payload = {
            "schema": "riscv-oracle-receipt-v1",
            "candidate_commit": "a" * 40,
            "oracle": {"commit": ORACLE.PINNED},
            "boundaries": {name: {"status": "pass"} for name in ORACLE.BOUNDARIES},
            "verdict": "PASS",
        }
        with tempfile.TemporaryDirectory() as directory:
            receipt = Path(directory) / "receipt.json"
            receipt.write_text(json.dumps(payload), encoding="utf-8")
            with mock.patch.object(ORACLE, "_run", return_value="a" * 40 + "\n"), \
                    mock.patch.object(ORACLE, "require_clean_candidate"), \
                    contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(1, ORACLE.validate(SimpleNamespace(receipt=receipt)))


if __name__ == "__main__":
    unittest.main()
