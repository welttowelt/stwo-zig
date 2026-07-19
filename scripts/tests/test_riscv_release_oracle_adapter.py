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
    @staticmethod
    def public_data() -> dict:
        return {
            "initial_pc": 0x10000,
            "final_pc": 0x10004,
            "clock": 1,
            "initial_regs": [0] * 32,
            "final_regs": [0] * 32,
            "reg_last_clock": [0] * 32,
            "program_root": 1,
            "initial_rw_root": 2,
            "final_rw_root": 3,
            "io_entries": {
                "input_start": 0x100000,
                "input_len": 0,
                "input_words": [],
                "output_len": 0,
                "output_len_addr": 0x100004,
                "output_data_addr": 0x100008,
                "output_words": [{"addr": 0x100004, "value": 0, "clock": 1}],
            },
        }

    @classmethod
    def public_diagnostic(cls, *, dirty: bool = False) -> str:
        digest = "d" * 64
        return json.dumps({
            "schema": ORACLE.PUBLIC_VALUES_SCHEMA,
            "derivation": ORACLE.PUBLIC_VALUES_DERIVATION,
            "provenance": {
                "implementation_commit": "a" * 40,
                "implementation_dirty": dirty,
                "oracle_commit": ORACLE.PINNED,
                "witness_layout_sha256": digest,
            },
            "source": {
                "elf_sha256": "e" * 64,
                "input_sha256": hashlib.sha256(b"").hexdigest(),
            },
            "public_data": cls.public_data(),
        })

    @classmethod
    def proof_artifact(cls, *, dirty: bool = False) -> str:
        public = cls.public_data()
        flat_public = {
            **{field: public[field] for field in ORACLE.PUBLIC_DATA_FIELDS[:-1]},
            **public["io_entries"],
        }
        return json.dumps({
            "artifact_kind": "stwo_riscv_proof",
            "schema_version": 3,
            "exchange_mode": "riscv_proof_json_wire_v3",
            "release_status": "not_release_gated",
            "generator": "zig",
            "air": "stark_v_rv32im",
            "backend": "cpu",
            "protocol": "functional",
            "source": {
                "elf_sha256": "e" * 64,
                "input_sha256": hashlib.sha256(b"").hexdigest(),
            },
            "provenance": {
                "oracle_repository": "https://github.com/ClementWalter/stark-v",
                "oracle_commit": ORACLE.PINNED,
                "implementation_repository": ORACLE.IMPLEMENTATION_REPOSITORY,
                "implementation_commit": "a" * 40,
                "implementation_dirty": dirty,
                "witness_layout_sha256": "d" * 64,
            },
            "pcs_config": {},
            "statement": {
                "segment_ordinal": 0,
                "segment_count": 1,
                "initial_pc": public["initial_pc"],
                "final_pc": public["final_pc"],
                "total_steps": public["clock"],
                "components": [],
                "infrastructure": [],
                "public_data": flat_public,
            },
            "interaction_claim": {},
            "proof_bytes_hex": "00",
        })

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

    def test_public_diagnostic_requires_exact_schema_and_clean_candidate_provenance(self) -> None:
        kwargs = {
            "candidate": "a" * 40,
            "witness_layout_sha256": "d" * 64,
            "elf_sha256": "e" * 64,
            "input_sha256": hashlib.sha256(b"").hexdigest(),
        }
        parsed = ORACLE.parse_public_values_diagnostic(self.public_diagnostic(), **kwargs)
        self.assertEqual(1, len(parsed["io_entries"]["output_words"]))
        with self.assertRaisesRegex(ValueError, "implementation_dirty differs"):
            ORACLE.parse_public_values_diagnostic(
                self.public_diagnostic(dirty=True),
                **kwargs,
            )
        with self.assertRaisesRegex(ValueError, "fields differ"):
            payload = json.loads(self.public_diagnostic())
            payload["unexpected"] = True
            ORACLE.parse_public_values_diagnostic(json.dumps(payload), **kwargs)
        with self.assertRaisesRegex(ValueError, "provenance fields differ"):
            payload = json.loads(self.public_diagnostic())
            payload["provenance"]["unexpected"] = "not-bound"
            ORACLE.parse_public_values_diagnostic(json.dumps(payload), **kwargs)
        with self.assertRaisesRegex(ValueError, "source fields differ"):
            payload = json.loads(self.public_diagnostic())
            del payload["source"]["input_sha256"]
            ORACLE.parse_public_values_diagnostic(json.dumps(payload), **kwargs)

    def test_proof_artifact_public_data_requires_strict_nested_binding(self) -> None:
        kwargs = {
            "candidate": "a" * 40,
            "witness_layout_sha256": "d" * 64,
            "elf_sha256": "e" * 64,
            "input_sha256": hashlib.sha256(b"").hexdigest(),
        }
        parsed = ORACLE.parse_proof_artifact_public_data(self.proof_artifact(), **kwargs)
        self.assertEqual(self.public_data(), parsed)
        with self.assertRaisesRegex(ValueError, "provenance.implementation_dirty differs"):
            ORACLE.parse_proof_artifact_public_data(
                self.proof_artifact(dirty=True),
                **kwargs,
            )
        with self.assertRaisesRegex(ValueError, "provenance fields differ"):
            payload = json.loads(self.proof_artifact())
            payload["provenance"]["unexpected"] = "not-bound"
            ORACLE.parse_proof_artifact_public_data(json.dumps(payload), **kwargs)
        with self.assertRaisesRegex(ValueError, "statement fields differ"):
            payload = json.loads(self.proof_artifact())
            payload["statement"]["unexpected"] = True
            ORACLE.parse_proof_artifact_public_data(json.dumps(payload), **kwargs)

    def test_public_boundary_uses_artifacts_and_typed_fail_closed_diagnostics(self) -> None:
        public = self.public_data()
        oracle = Path("/oracle/cp11_dump")
        run_calls: list[list[str]] = []
        process_calls: list[list[str]] = []

        def run(command, cwd=None):
            del cwd
            run_calls.append(command)
            if command[0] == str(oracle):
                return json.dumps({"trace": {}, "public_data": public})
            if "--public-values" in command:
                return self.public_diagnostic()
            output = Path(command[command.index("--output") + 1])
            output.write_text(self.proof_artifact(), encoding="utf-8")
            return ""

        def process(command, **kwargs):
            del kwargs
            process_calls.append(command)
            if command[:3] == ["zig", "build", "stwo-zig"]:
                return subprocess.CompletedProcess(command, 0, "", "")
            return subprocess.CompletedProcess(
                command,
                1,
                "",
                ORACLE.UNSUPPORTED_PROOF_FAMILY_STDERR,
            )

        receipt = {
            "candidate_commit": "a" * 40,
            "witness_layout_digest_sha256": "d" * 64,
            "boundaries": {"public_values": {"status": "unimplemented"}},
        }
        manifest = {
            "vectors": [
                {
                    "name": "alu_test",
                    "elf": "vectors/riscv_elfs/alu_test.elf",
                    "elf_sha256": "e" * 64,
                    "proof_admission": {"status": "supported"},
                },
                {
                    "name": "mul_div",
                    "elf": "vectors/riscv_elfs/mul_div.elf",
                    "elf_sha256": "e" * 64,
                    "proof_admission": {
                        "status": "fail_closed_known_limitation",
                        "known_limitation": "stark-v-signed-mulh",
                    },
                },
                {
                    "name": "mulhu_only",
                    "elf": "vectors/riscv_elfs/mulhu_only.elf",
                    "elf_sha256": "e" * 64,
                    "proof_admission": {
                        "status": "diagnostic_balanced_family_fail_closed",
                        "known_limitation": "stark-v-signed-mulh",
                    },
                },
            ],
        }
        with mock.patch.object(ORACLE, "_run", side_effect=run), \
                mock.patch.object(ORACLE, "load_trace_vectors", return_value=manifest), \
                mock.patch.object(ORACLE, "record_implementation_executable") as record, \
                mock.patch.object(ORACLE.subprocess, "run", side_effect=process):
            ORACLE.compare_public_values(oracle, receipt)

        self.assertEqual("pass", receipt["boundaries"]["public_values"]["status"])
        cases = {
            case["name"]: case
            for case in receipt["boundaries"]["public_values"]["corpus"]
        }
        self.assertEqual("production_proof_artifact", cases["alu_test"]["mode"])
        for name in ("mul_div", "mulhu_only"):
            self.assertEqual(
                "tree_builder_diagnostic_and_production_rejection",
                cases[name]["mode"],
            )
            self.assertEqual(
                "statement_validation_before_first_commitment",
                cases[name]["production_rejection"]["stage"],
            )
            self.assertFalse(cases[name]["production_rejection"]["proof_artifact_published"])
            self.assertFalse(cases[name]["production_rejection"]["report_published"])
            self.assertTrue(cases[name]["production_rejection"]["stdout_empty"])
            self.assertTrue(cases[name]["production_rejection"]["stderr_exact"])
            self.assertEqual([], cases[name]["production_rejection"]["temporary_residue"])
        self.assertEqual(1, sum("prove" in command for command in run_calls))
        self.assertEqual(2, sum("--public-values" in command for command in run_calls))
        self.assertEqual(1, sum(command[:3] == ["zig", "build", "stwo-zig"]
                                for command in process_calls))
        self.assertEqual(2, sum("--report-out" in command for command in process_calls))
        record.assert_called_once()

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
