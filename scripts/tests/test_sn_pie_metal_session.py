from __future__ import annotations

import hashlib
import io
import importlib.util
import json
import os
from pathlib import Path
import shutil
import struct
import sys
import tempfile
import textwrap
import types
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "sn_pie_metal_session.py"
SPEC = importlib.util.spec_from_file_location("sn_pie_metal_session", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)

TEST_PROOF_LAYOUT = {
    "interaction_claim_words": 232,
    "sampled_value_words": 24_440,
    "decommitment_capacity_words": 2_077_800,
}


def rust_verifier_evidence(proof: bytes = b"proof") -> dict[str, object]:
    return {
        "schema_version": 1,
        "status": "passed",
        "verified": True,
        "envelope_abi": "STWZCVE/1",
        "adapter_version": "0.1.0",
        "verification_mode": "compact_metal_proof_v1",
        "protocol_digest": MODULE._compact_protocol_digest(TEST_PROOF_LAYOUT).hex(),
        "statement_digest": "11" * 32,
        "proof_digest": hashlib.sha256(proof).hexdigest(),
        "provenance_digest": "22" * 32,
        "executable_sha256": "33" * 32,
        "cargo_lock_sha256": "72ee6a80235ff78a6e2c1724a8c6d1c45798c2a11c1c1539bc675af066b0e31c",
        "stwo_cairo_revision": "dcd5834565b7a26a27a614e353c9c60109ebc1d9",
        "stwo_revision": "9d7e3d6fa0fc64a0d143a8b2fcb8ee952f4de8f2",
        "wall_time_ns": 70_000_000,
        "service_wall_time_ns": 75_000_000,
        "result_sha256": "55" * 32,
    }


def rust_verifier_identity() -> dict[str, object]:
    evidence = rust_verifier_evidence()
    return {
        "required": True,
        "schema_version": evidence["schema_version"],
        "envelope_abi": evidence["envelope_abi"],
        "adapter_version": evidence["adapter_version"],
        "executable_sha256": evidence["executable_sha256"],
        "cargo_lock_sha256": evidence["cargo_lock_sha256"],
        "stwo_cairo_revision": evidence["stwo_cairo_revision"],
        "stwo_revision": evidence["stwo_revision"],
        "verification_mode": evidence["verification_mode"],
    }


class SnPieMetalSessionTest(unittest.TestCase):
    def make_request(
        self,
        root: Path,
        sequence: int = 0,
        *,
        diagnostic_references: bool = True,
    ):
        input_root = root / "inputs"
        output_root = root / "outputs"
        input_root.mkdir()
        output_root.mkdir()
        paths = {}
        for name in MODULE.SessionArtifacts.__dataclass_fields__:
            if not diagnostic_references and name in {
                "transcript_reference",
                "quotient_reference",
            }:
                paths[name] = None
                continue
            if name == "preprocessed_tree0_merkle":
                path = Path(f"{paths['preprocessed_evaluations']}.tree0-merkle")
            else:
                path = input_root / name
            path.write_bytes(b"input")
            paths[name] = path.resolve()
        return MODULE.ProveRequest(
            sequence=sequence,
            request_id=f"block-{sequence:04d}-sn2",
            artifacts=MODULE.SessionArtifacts(**paths),
            proof_output=(output_root / "block.proof").resolve(),
            report_output=(output_root / "block.report.json").resolve(),
            budget_gib="29",
            tree0_root_hex="ab" * 32,
        )

    def artifact_evidence(self, request):
        entries = []
        encoded_entries = []
        artifact_objects = {}
        for role, path in request.artifacts.__dict__.items():
            if path is None:
                continue
            data = path.read_bytes()
            digest = hashlib.sha256(data).hexdigest()
            entry = {
                "role": role,
                "logical_name": "",
                "format_version": 1,
                "provenance": "proof_derived",
                "bytes": len(data),
                "sha256": digest,
                "source_chain_complete": False,
                "source_digests": [],
                "generator": None,
            }
            entries.append(entry)
            encoded = bytearray(struct.pack("<HH", MODULE.ARTIFACT_ROLES[role], 0))
            encoded.extend(struct.pack(
                "<IBQ",
                1,
                MODULE.ARTIFACT_PROVENANCE["proof_derived"],
                len(data),
            ))
            encoded.extend(bytes.fromhex(digest))
            encoded.extend(struct.pack("<BH", 0, 0))
            encoded.extend(b"\x00")
            encoded_entries.append((MODULE.ARTIFACT_ROLES[role], bytes(encoded)))
            artifact_objects[role] = {
                "object_id": digest,
                "bytes": len(data),
                "diagnostic_path": str(path),
            }

        encoded_manifest = bytearray(MODULE.ARTIFACT_MANIFEST_DOMAIN)
        encoded_manifest.extend(struct.pack("<I", 1))
        protocol_digest = MODULE._canonical_protocol_digest()
        encoded_manifest.extend(protocol_digest)
        encoded_manifest.extend(struct.pack("<H", len(encoded_entries)))
        for _, encoded_entry in sorted(encoded_entries):
            encoded_manifest.extend(encoded_entry)
        manifest_digest = hashlib.sha256(encoded_manifest).hexdigest()
        manifest = {
            "schema_version": 1,
            "canonical_encoding": "STWZAM/1-little-endian",
            "protocol_sha256": protocol_digest.hex(),
            "sha256": manifest_digest,
            "classification": {
                "production_source_chain_complete": False,
                "parity_fixture_used": False,
                "proof_derived_artifact_used": True,
            },
            "entries": entries,
        }
        return manifest_digest, manifest, artifact_objects

    def request_with_same_artifacts(self, request, root: Path, sequence: int):
        output_root = root / f"outputs-{sequence}"
        output_root.mkdir()
        return MODULE.ProveRequest(
            sequence=sequence,
            request_id=f"block-{sequence:04d}-sn2",
            artifacts=request.artifacts,
            proof_output=(output_root / "block.proof").resolve(),
            report_output=(output_root / "block.report.json").resolve(),
            budget_gib=request.budget_gib,
            tree0_root_hex=request.tree0_root_hex,
        )

    def result_document(self, request, proof: bytes = b"proof"):
        request.proof_output.write_bytes(proof)
        adapted_input_sha256 = MODULE.sha256_file(request.artifacts.adapted_input)
        cycles = 8_000_000
        prove_wall_s = 4.0
        prove_mhz = 2.0
        executable_sha256 = "de" * 32
        rust_verifier = rust_verifier_evidence(proof)
        manifest_digest, manifest, artifact_objects = self.artifact_evidence(request)
        request.report_output.write_text(json.dumps({
            "status": "completed",
            "proof_verified": True,
            "proving_speed_verified": True,
            "self_contained": False,
            "parity_fixture_used": False,
            "proof_derived_artifact_used": True,
            "statement_self_derived": True,
            "artifact_manifest_digest": manifest_digest,
            "artifact_manifest": manifest,
            "artifact_objects": artifact_objects,
            "provenance_complete": True,
            "protocol": dict(MODULE.CANONICAL_PROOF_PROTOCOL),
            "protocol_complete": True,
            "daemon_executable_sha256": executable_sha256,
            "runner_executable_sha256": executable_sha256,
            "runner_linkage": MODULE.IN_PROCESS_RUNNER_LINKAGE,
            "rust_verifier": rust_verifier,
            "cli_report": {"proof_layout": dict(TEST_PROOF_LAYOUT)},
            "prove_timing_scope": MODULE.PROVE_TIMING_SCOPE,
            "prove_wall_s": prove_wall_s,
            "prove_mhz": prove_mhz,
            "reuse": {
                "runtime": True,
                "resident_arena": False,
                "preprocessed_state": False,
            },
            "input": {
                "path": str(request.artifacts.adapted_input),
                "sha256": adapted_input_sha256,
                "adapted_cycles": cycles,
            },
        }))
        return {
            "protocol": MODULE.PROTOCOL,
            "version": MODULE.VERSION,
            "type": "result",
            "status": "verified",
            "sequence": request.sequence,
            "request_id": request.request_id,
            "proof_verified": True,
            "outputs_committed": True,
            "adapted_cycles": cycles,
            "prove_wall_s": prove_wall_s,
            "prove_timing_scope": MODULE.PROVE_TIMING_SCOPE,
            "prove_mhz": prove_mhz,
            "session_block_wall_s": 4.25,
            "proof_bytes": len(proof),
            "proof_sha256": hashlib.sha256(proof).hexdigest(),
            "adapted_input_sha256": adapted_input_sha256,
            "self_contained": False,
            "parity_fixture_used": False,
            "proof_derived_artifact_used": True,
            "statement_self_derived": True,
            "artifact_manifest_digest": manifest_digest,
            "artifact_objects": artifact_objects,
            "provenance_complete": True,
            "proof_protocol": dict(MODULE.CANONICAL_PROOF_PROTOCOL),
            "protocol_complete": True,
            "daemon_executable_sha256": executable_sha256,
            "runner_executable_sha256": executable_sha256,
            "runner_linkage": MODULE.IN_PROCESS_RUNNER_LINKAGE,
            "rust_verifier": rust_verifier,
            "reuse": {
                "runtime": True,
                "resident_arena": False,
                "preprocessed_state": False,
            },
        }

    def test_validated_result_checks_committed_artifacts(self):
        with tempfile.TemporaryDirectory() as directory:
            request = self.make_request(Path(directory))
            result = MODULE.validate_verified_result(self.result_document(request), request)
            self.assertEqual(result.adapted_cycles, 8_000_000)
            self.assertEqual(result.prove_mhz, 2.0)
            self.assertTrue(result.runtime_reused)
            self.assertFalse(result.self_contained)
            self.assertFalse(result.parity_fixture_used)
            self.assertTrue(result.proof_derived_artifact_used)
            self.assertTrue(result.statement_self_derived)
            self.assertRegex(result.artifact_manifest_digest, r"^[0-9a-f]{64}$")
            self.assertTrue(result.provenance_complete)
            self.assertEqual(set(result.artifact_objects), {
                name for name, path in request.artifacts.__dict__.items()
                if path is not None
            })
            self.assertEqual(result.proof_protocol, MODULE.CANONICAL_PROOF_PROTOCOL)
            self.assertTrue(result.protocol_complete)
            self.assertEqual(result.daemon_executable_sha256, "de" * 32)
            self.assertEqual(result.runner_executable_sha256, "de" * 32)
            self.assertEqual(result.runner_linkage, MODULE.IN_PROCESS_RUNNER_LINKAGE)
            self.assertEqual(result.rust_verifier, rust_verifier_evidence())
            self.assertEqual(result.adapted_input_sha256, MODULE.sha256_file(request.artifacts.adapted_input))

    def test_rejects_inexact_drifting_or_unbound_rust_verifier_evidence(self):
        def remove_from_response(response, report):
            del response["rust_verifier"]

        def remove_from_report(response, report):
            del report["rust_verifier"]

        def add_unknown_field(response, report):
            response["rust_verifier"]["unexpected"] = True
            report["rust_verifier"]["unexpected"] = True

        def remove_required_field(response, report):
            del response["rust_verifier"]["verification_mode"]
            del report["rust_verifier"]["verification_mode"]

        def drift_report(response, report):
            report["rust_verifier"]["statement_digest"] = "66" * 32

        def drift_proof_digest(response, report):
            response["rust_verifier"]["proof_digest"] = "66" * 32
            report["rust_verifier"]["proof_digest"] = "66" * 32

        def drift_protocol_digest(response, report):
            response["rust_verifier"]["protocol_digest"] = "66" * 32
            report["rust_verifier"]["protocol_digest"] = "66" * 32

        def false_success(response, report):
            response["rust_verifier"]["verified"] = False
            report["rust_verifier"]["verified"] = False

        def boolean_wall_time(response, report):
            response["rust_verifier"]["wall_time_ns"] = True
            report["rust_verifier"]["wall_time_ns"] = True

        def uppercase_digest(response, report):
            response["rust_verifier"]["result_sha256"] = "AA" * 32
            report["rust_verifier"]["result_sha256"] = "AA" * 32

        mutations = {
            "response missing": remove_from_response,
            "report missing": remove_from_report,
            "unknown field": add_unknown_field,
            "missing field": remove_required_field,
            "report drift": drift_report,
            "proof digest drift": drift_proof_digest,
            "protocol digest drift": drift_protocol_digest,
            "verified false": false_success,
            "boolean wall time": boolean_wall_time,
            "uppercase digest": uppercase_digest,
        }
        for label, mutate in mutations.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as directory:
                request = self.make_request(Path(directory))
                response = self.result_document(request)
                report = json.loads(request.report_output.read_text())
                mutate(response, report)
                request.report_output.write_text(json.dumps(report))
                with self.assertRaises(MODULE.SessionProtocolError):
                    MODULE.validate_verified_result(response, request)

    def test_prepared_state_report_distinguishes_miss_and_reuse(self):
        with tempfile.TemporaryDirectory() as directory:
            request = self.make_request(Path(directory))
            response = self.result_document(request)
            report = json.loads(request.report_output.read_text())
            report["reuse"] = dict(response["reuse"])
            report["prepared_state_cache_hit"] = False
            report["prepared_state"] = {
                "cache_hit": False,
                "arena_bytes": 4096,
                "snapshot_bytes": 1024,
                "clear_bytes": 0,
                "capture_gpu_ms": 0.25,
                "restore_gpu_ms": 0.0,
            }
            report["cli_report"] = {
                "proof_layout": dict(TEST_PROOF_LAYOUT),
                "prepared_state_cache_hit": False,
                "resident_arena_bytes": 4096,
                "prepared_state_snapshot_bytes": 1024,
                "prepared_state_clear_bytes": 0,
                "prepared_state_capture_gpu_ms": 0.25,
                "prepared_state_restore_gpu_ms": 0.0,
            }
            request.report_output.write_text(json.dumps(report))
            first = MODULE.validate_verified_result(response, request)
            self.assertFalse(first.resident_arena_reused)
            self.assertFalse(first.preprocessed_state_reused)

            response["reuse"]["resident_arena"] = True
            response["reuse"]["preprocessed_state"] = True
            report["reuse"] = dict(response["reuse"])
            report["prepared_state_cache_hit"] = True
            report["prepared_state"].update({
                "cache_hit": True,
                "clear_bytes": 4096,
                "capture_gpu_ms": 0.0,
                "restore_gpu_ms": 0.1,
            })
            report["cli_report"].update({
                "prepared_state_cache_hit": True,
                "prepared_state_clear_bytes": 4096,
                "prepared_state_capture_gpu_ms": 0.0,
                "prepared_state_restore_gpu_ms": 0.1,
            })
            request.report_output.write_text(json.dumps(report))
            second = MODULE.validate_verified_result(response, request)
            self.assertTrue(second.resident_arena_reused)
            self.assertTrue(second.preprocessed_state_reused)

            report["prepared_state_cache_hit"] = False
            request.report_output.write_text(json.dumps(report))
            with self.assertRaises(MODULE.SessionProtocolError):
                MODULE.validate_verified_result(response, request)

    def test_prepared_state_evidence_exactly_matches_embedded_runner_report(self):
        mutations = {
            "cache hit": lambda cli: cli.__setitem__("prepared_state_cache_hit", False),
            "arena bytes": lambda cli: cli.__setitem__("resident_arena_bytes", 4095),
            "snapshot bytes": lambda cli: cli.__setitem__("prepared_state_snapshot_bytes", 1023),
            "clear bytes": lambda cli: cli.__setitem__("prepared_state_clear_bytes", 4095),
            "capture time": lambda cli: cli.__setitem__("prepared_state_capture_gpu_ms", 0.25),
            "restore time": lambda cli: cli.__setitem__("prepared_state_restore_gpu_ms", 0.2),
        }
        for label, mutate in mutations.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as directory:
                request = self.make_request(Path(directory))
                response = self.result_document(request)
                response["reuse"].update({
                    "resident_arena": True,
                    "preprocessed_state": True,
                })
                report = json.loads(request.report_output.read_text())
                report["reuse"] = dict(response["reuse"])
                report["prepared_state_cache_hit"] = True
                report["prepared_state"] = {
                    "cache_hit": True,
                    "arena_bytes": 4096,
                    "snapshot_bytes": 1024,
                    "clear_bytes": 4096,
                    "capture_gpu_ms": 0.0,
                    "restore_gpu_ms": 0.1,
                }
                report["cli_report"] = {
                    "proof_layout": dict(TEST_PROOF_LAYOUT),
                    "prepared_state_cache_hit": True,
                    "resident_arena_bytes": 4096,
                    "prepared_state_snapshot_bytes": 1024,
                    "prepared_state_clear_bytes": 4096,
                    "prepared_state_capture_gpu_ms": 0.0,
                    "prepared_state_restore_gpu_ms": 0.1,
                }
                mutate(report["cli_report"])
                request.report_output.write_text(json.dumps(report))
                with self.assertRaisesRegex(
                    MODULE.SessionProtocolError,
                    "embedded runner evidence",
                ):
                    MODULE.validate_verified_result(response, request)

    def test_warm_reuse_requires_committed_prepared_state_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            request = self.make_request(Path(directory))
            response = self.result_document(request)
            response["reuse"].update({
                "resident_arena": True,
                "preprocessed_state": True,
            })
            report = json.loads(request.report_output.read_text())
            report["reuse"] = dict(response["reuse"])
            request.report_output.write_text(json.dumps(report))
            with self.assertRaisesRegex(
                MODULE.SessionProtocolError,
                "missing prepared-state evidence",
            ):
                MODULE.validate_verified_result(response, request)

    def test_committed_report_reuse_exactly_matches_response_booleans(self):
        mutations = {
            "boolean alias": {"runtime": 1, "resident_arena": 0, "preprocessed_state": 0},
            "different value": {"runtime": True, "resident_arena": True, "preprocessed_state": True},
        }
        for label, report_reuse in mutations.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as directory:
                request = self.make_request(Path(directory))
                response = self.result_document(request)
                report = json.loads(request.report_output.read_text())
                report["reuse"] = report_reuse
                request.report_output.write_text(json.dumps(report))
                with self.assertRaisesRegex(
                    MODULE.SessionProtocolError,
                    "reuse fields must be boolean|does not match the response",
                ):
                    MODULE.validate_verified_result(response, request)

    def test_ready_requires_v4_equal_in_process_executable_identity(self):
        identity = "ab" * 32
        ready = {
            "protocol": MODULE.PROTOCOL,
            "version": MODULE.VERSION,
            "type": "ready",
            "session_id": "identity-test",
            "daemon_executable_sha256": identity,
            "runner_executable_sha256": identity,
            "runner_linkage": MODULE.IN_PROCESS_RUNNER_LINKAGE,
            "rust_verifier": rust_verifier_identity(),
            "capabilities": {
                "strict_order": True,
                "atomic_outputs": True,
                "verified_proofs": True,
                "runtime_reuse": True,
                "resident_arena_reuse": False,
                "preprocessed_state_reuse": False,
            },
        }
        self.assertEqual(MODULE.validate_ready(ready), ready)

        mutations = {
            "old version": lambda value: value.__setitem__("version", 1),
            "missing digest": lambda value: value.pop("daemon_executable_sha256"),
            "different runner": lambda value: value.__setitem__(
                "runner_executable_sha256", "cd" * 32
            ),
            "external linkage": lambda value: value.__setitem__(
                "runner_linkage", "subprocess"
            ),
            "missing Rust verifier": lambda value: value.pop("rust_verifier"),
            "unrequired Rust verifier": lambda value: value["rust_verifier"].__setitem__(
                "required", False
            ),
            "Rust verifier unknown field": lambda value: value["rust_verifier"].__setitem__(
                "extra", True
            ),
        }
        for label, mutate in mutations.items():
            with self.subTest(label=label):
                candidate = json.loads(json.dumps(ready))
                mutate(candidate)
                with self.assertRaises(MODULE.SessionProtocolError):
                    MODULE.validate_ready(candidate)

    def test_rejects_result_or_report_executable_identity_drift(self):
        with tempfile.TemporaryDirectory() as directory:
            request = self.make_request(Path(directory))
            document = self.result_document(request)
            document["runner_executable_sha256"] = "ef" * 32
            with self.assertRaisesRegex(MODULE.SessionProtocolError, "identities differ"):
                MODULE.validate_verified_result(document, request)

        with tempfile.TemporaryDirectory() as directory:
            request = self.make_request(Path(directory))
            document = self.result_document(request)
            report = json.loads(request.report_output.read_text())
            report["daemon_executable_sha256"] = "ef" * 32
            report["runner_executable_sha256"] = "ef" * 32
            request.report_output.write_text(json.dumps(report))
            with self.assertRaisesRegex(
                MODULE.SessionProtocolError, "does not match the response"
            ):
                MODULE.validate_verified_result(document, request)

    def test_rejects_inexact_or_drifting_proof_protocol(self):
        mutations = {
            "unknown field": lambda value: value.__setitem__("extra", 0),
            "missing field": lambda value: value.pop("channel"),
            "boolean integer": lambda value: value.__setitem__("channel_salt", False),
            "value drift": lambda value: value.__setitem__("n_queries", 71),
            "non-null lifting": lambda value: value.__setitem__("fri_lifting", 0),
        }
        for label, mutate in mutations.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as directory:
                request = self.make_request(Path(directory))
                document = self.result_document(request)
                mutate(document["proof_protocol"])
                with self.assertRaisesRegex(
                    MODULE.SessionProtocolError,
                    "non-canonical|unknown|missing",
                ):
                    MODULE.validate_verified_result(document, request)

        with tempfile.TemporaryDirectory() as directory:
            request = self.make_request(Path(directory))
            document = self.result_document(request)
            document["protocol_complete"] = False
            with self.assertRaisesRegex(MODULE.SessionProtocolError, "protocol_complete"):
                MODULE.validate_verified_result(document, request)

        with tempfile.TemporaryDirectory() as directory:
            request = self.make_request(Path(directory))
            document = self.result_document(request)
            report = json.loads(request.report_output.read_text())
            report["protocol"]["query_pow_bits"] = 25
            request.report_output.write_text(json.dumps(report))
            with self.assertRaisesRegex(MODULE.SessionProtocolError, "non-canonical"):
                MODULE.validate_verified_result(document, request)

    def test_rejects_contradictory_or_report_mismatched_provenance(self):
        with tempfile.TemporaryDirectory() as directory:
            request = self.make_request(Path(directory))
            document = self.result_document(request)
            document["self_contained"] = True
            with self.assertRaisesRegex(MODULE.SessionProtocolError, "contradictory"):
                MODULE.validate_verified_result(document, request)

        with tempfile.TemporaryDirectory() as directory:
            request = self.make_request(Path(directory))
            document = self.result_document(request)
            report = json.loads(request.report_output.read_text())
            report["parity_fixture_used"] = True
            request.report_output.write_text(json.dumps(report))
            with self.assertRaisesRegex(MODULE.SessionProtocolError, "does not match"):
                MODULE.validate_verified_result(document, request)

    def test_reference_parser_rejects_unknown_fields(self):
        with tempfile.TemporaryDirectory() as directory:
            request = self.make_request(Path(directory))
            document = request.document()
            parsed = MODULE.parse_request_document(document)
            self.assertEqual(parsed, request)
            document["unexpected"] = True
            with self.assertRaisesRegex(MODULE.SessionProtocolError, "unknown fields"):
                MODULE.parse_request_document(document)

    def test_v4_request_artifacts_are_exact_path_or_service_object_frames(self):
        with tempfile.TemporaryDirectory() as directory:
            request = self.make_request(Path(directory))
            document = request.document()
            self.assertEqual(document["version"], 4)
            self.assertEqual(document["expected_tree0_root_hex"], "ab" * 32)
            self.assertNotIn("tree0_root_hex", document)
            self.assertEqual(
                document["artifacts"]["composition_program"],
                {"path": str(request.artifacts.composition_program)},
            )
            self.assertTrue(all(
                set(reference) == {"path"}
                for reference in document["artifacts"].values()
            ))

            schedule_path = request.artifacts.schedule
            schedule_bytes = schedule_path.stat().st_size
            schedule_id = MODULE.sha256_file(schedule_path)
            document["artifacts"]["schedule"] = {
                "object_id": schedule_id,
                "bytes": schedule_bytes,
                "diagnostic_path": str(schedule_path),
            }
            schedule_path.unlink()
            self.assertEqual(MODULE.parse_request_document(document), request)

            invalid_references = (
                {"path": str(schedule_path), "bytes": schedule_bytes},
                {
                    "object_id": schedule_id,
                    "bytes": True,
                    "diagnostic_path": str(schedule_path),
                },
                {
                    "object_id": schedule_id,
                    "bytes": 1 << 64,
                    "diagnostic_path": str(schedule_path),
                },
                {
                    "object_id": schedule_id,
                    "bytes": schedule_bytes,
                    "diagnostic_path": str(schedule_path),
                    "extra": False,
                },
            )
            for invalid in invalid_references:
                with self.subTest(invalid=invalid):
                    document["artifacts"]["schedule"] = invalid
                    with self.assertRaises(MODULE.SessionProtocolError):
                        MODULE.parse_request_document(document)

    def test_diagnostic_references_may_both_be_absent(self):
        with tempfile.TemporaryDirectory() as directory:
            request = self.make_request(
                Path(directory),
                diagnostic_references=False,
            )
            document = request.document()
            self.assertNotIn("transcript_reference", document["artifacts"])
            self.assertNotIn("quotient_reference", document["artifacts"])
            self.assertEqual(MODULE.parse_request_document(document), request)

    def test_diagnostic_references_must_be_paired(self):
        with tempfile.TemporaryDirectory() as directory:
            request = self.make_request(Path(directory))
            request = MODULE.ProveRequest(
                sequence=request.sequence,
                request_id=request.request_id,
                artifacts=MODULE.SessionArtifacts(
                    **{
                        **request.artifacts.__dict__,
                        "quotient_reference": None,
                    }
                ),
                proof_output=request.proof_output,
                report_output=request.report_output,
                budget_gib=request.budget_gib,
                tree0_root_hex=request.tree0_root_hex,
            )
            with self.assertRaisesRegex(ValueError, "must be provided together"):
                request.document()

            second_root = Path(directory) / "second"
            second_root.mkdir()
            document = self.make_request(second_root).document()
            del document["artifacts"]["quotient_reference"]
            with self.assertRaisesRegex(
                MODULE.SessionProtocolError,
                "must be provided together",
            ):
                MODULE.parse_request_document(document)

    def test_diagnostic_references_are_serialized_when_present(self):
        with tempfile.TemporaryDirectory() as directory:
            request = self.make_request(Path(directory))
            document = request.document()
            self.assertEqual(
                document["artifacts"]["transcript_reference"],
                {"path": str(request.artifacts.transcript_reference)},
            )
            self.assertEqual(
                document["artifacts"]["quotient_reference"],
                {"path": str(request.artifacts.quotient_reference)},
            )
            self.assertEqual(MODULE.parse_request_document(document), request)

    def test_rejects_stale_output_before_request(self):
        with tempfile.TemporaryDirectory() as directory:
            request = self.make_request(Path(directory))
            request.proof_output.write_bytes(b"stale")
            with self.assertRaisesRegex(ValueError, "stale output"):
                request.document()

    def test_rejects_wrong_proof_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            request = self.make_request(Path(directory))
            document = self.result_document(request)
            document["proof_sha256"] = "00" * 32
            with self.assertRaisesRegex(MODULE.SessionProtocolError, "SHA-256"):
                MODULE.validate_verified_result(document, request)

    def test_rejects_result_for_different_adapted_input(self):
        with tempfile.TemporaryDirectory() as directory:
            request = self.make_request(Path(directory))
            document = self.result_document(request)
            document["adapted_input_sha256"] = "00" * 32
            with self.assertRaisesRegex(MODULE.SessionProtocolError, "adapted input SHA-256"):
                MODULE.validate_verified_result(document, request)

    def test_rejects_report_for_different_input_path(self):
        with tempfile.TemporaryDirectory() as directory:
            request = self.make_request(Path(directory))
            document = self.result_document(request)
            report = json.loads(request.report_output.read_text())
            report["input"]["path"] = str(request.artifacts.schedule)
            request.report_output.write_text(json.dumps(report))
            with self.assertRaisesRegex(MODULE.SessionProtocolError, "input path"):
                MODULE.validate_verified_result(document, request)

    def test_rejects_mhz_outside_verified_timing_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            request = self.make_request(Path(directory))
            document = self.result_document(request)
            document["prove_mhz"] = 5.0
            with self.assertRaisesRegex(MODULE.SessionProtocolError, "does not match"):
                MODULE.validate_verified_result(document, request)

    def test_result_artifact_objects_are_bound_to_report_and_manifest(self):
        mutations = {
            "response digest": lambda response, report: response["artifact_objects"][
                "schedule"
            ].__setitem__("object_id", "00" * 32),
            "response bytes": lambda response, report: response["artifact_objects"][
                "schedule"
            ].__setitem__("bytes", 6),
            "response path": lambda response, report: response["artifact_objects"][
                "schedule"
            ].__setitem__("diagnostic_path", "/different"),
            "report drift": lambda response, report: report["artifact_objects"][
                "schedule"
            ].__setitem__("object_id", "00" * 32),
            "unknown role": lambda response, report: response["artifact_objects"].__setitem__(
                "extra", response["artifact_objects"]["schedule"]
            ),
        }
        for label, mutate in mutations.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as directory:
                request = self.make_request(Path(directory))
                response = self.result_document(request)
                report = json.loads(request.report_output.read_text())
                mutate(response, report)
                request.report_output.write_text(json.dumps(report))
                with self.assertRaises(MODULE.SessionProtocolError):
                    MODULE.validate_verified_result(response, request)

    def test_client_learns_only_validated_objects_and_reuses_without_path_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = self.make_request(root)
            second = self.request_with_same_artifacts(first, root, 1)
            requests = (first, second)
            client = MODULE.PersistentSessionClient([sys.executable])
            client.process = types.SimpleNamespace(
                stdin=io.BytesIO(), stdout=None, poll=lambda: 0
            )
            client.executable_sha256 = "de" * 32
            documents = []

            def response(_timeout):
                encoded = client.process.stdin.getvalue().splitlines()[-1]
                documents.append(json.loads(encoded))
                return self.result_document(requests[len(documents) - 1])

            with mock.patch.object(client, "_read_message", side_effect=response), mock.patch.object(
                client, "_require_executable_unchanged"
            ):
                client.prove(first, timeout_s=1.0)
                for path in first.artifacts.__dict__.values():
                    if path is not None:
                        os.utime(path, None)
                client.prove(second, timeout_s=1.0)

            self.assertTrue(all(
                set(reference) == {"path"}
                for reference in documents[0]["artifacts"].values()
            ))
            self.assertTrue(all(
                set(reference) == {"object_id", "bytes", "diagnostic_path"}
                for reference in documents[1]["artifacts"].values()
            ))
            self.assertEqual(
                documents[1]["artifacts"]["composition_program"]["diagnostic_path"],
                str(first.artifacts.composition_program),
            )

    def test_validated_warm_adapted_object_requires_no_source_read(self):
        with tempfile.TemporaryDirectory() as directory:
            request = self.make_request(Path(directory))
            response = self.result_document(request)
            document = response["artifact_objects"]["adapted_input"]
            reference = MODULE.ArtifactObjectReference(
                object_id=document["object_id"],
                bytes=document["bytes"],
                diagnostic_path=Path(document["diagnostic_path"]),
            )
            request.artifacts.adapted_input.unlink()

            result = MODULE.validate_verified_result(
                response,
                request,
                sent_artifact_objects={"adapted_input": reference},
            )

            self.assertEqual(result.adapted_input_sha256, reference.object_id)

    def test_client_does_not_cache_failed_or_changed_object_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            request = self.make_request(root)
            client = MODULE.PersistentSessionClient([sys.executable])
            client.process = types.SimpleNamespace(
                stdin=io.BytesIO(), stdout=None, poll=lambda: 0
            )
            client.executable_sha256 = "de" * 32

            def invalid_response(_timeout):
                response = self.result_document(request)
                response["artifact_objects"]["schedule"]["bytes"] += 1
                return response

            with mock.patch.object(client, "_read_message", side_effect=invalid_response), mock.patch.object(
                client, "_require_executable_unchanged"
            ):
                with self.assertRaises(MODULE.SessionProtocolError):
                    client.prove(request, timeout_s=1.0)
            self.assertEqual(client._artifact_object_cache, {})

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = self.make_request(root)
            second = self.request_with_same_artifacts(first, root, 1)
            client = MODULE.PersistentSessionClient([sys.executable])
            client.process = types.SimpleNamespace(
                stdin=io.BytesIO(), stdout=None, poll=lambda: 0
            )
            client.executable_sha256 = "de" * 32
            calls = 0

            def changed_response(_timeout):
                nonlocal calls
                current = (first, second)[calls]
                calls += 1
                if calls == 2:
                    second.artifacts.schedule.write_bytes(b"changed")
                return self.result_document(current)

            with mock.patch.object(client, "_read_message", side_effect=changed_response), mock.patch.object(
                client, "_require_executable_unchanged"
            ):
                client.prove(first, timeout_s=1.0)
                with self.assertRaisesRegex(
                    MODULE.SessionProtocolError, "changed the service object"
                ):
                    client.prove(second, timeout_s=1.0)
            self.assertEqual(client._artifact_object_cache, {})

    def test_client_processes_strict_sequence_and_clean_shutdown(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            request = self.make_request(root, diagnostic_references=False)
            manifest_digest, manifest, artifact_objects = self.artifact_evidence(request)
            daemon = root / "fake_daemon.py"
            daemon.write_text(textwrap.dedent(f"""
                import hashlib, json, pathlib, sys
                protocol = {MODULE.PROTOCOL!r}
                version = {MODULE.VERSION!r}
                scope = {MODULE.PROVE_TIMING_SCOPE!r}
                proof_protocol = {MODULE.CANONICAL_PROOF_PROTOCOL!r}
                manifest_digest = {manifest_digest!r}
                artifact_manifest = {manifest!r}
                artifact_objects = {artifact_objects!r}
                executable_sha256 = hashlib.sha256(pathlib.Path(sys.executable).resolve().read_bytes()).hexdigest()
                print(json.dumps({{
                    "protocol": protocol, "version": version, "type": "ready", "session_id": "test-session",
                    "daemon_executable_sha256": executable_sha256,
                    "runner_executable_sha256": executable_sha256,
                    "runner_linkage": "in_process",
                    "rust_verifier": {rust_verifier_identity()!r},
                    "capabilities": {{"strict_order": True, "atomic_outputs": True,
                        "verified_proofs": True, "runtime_reuse": True,
                        "resident_arena_reuse": False, "preprocessed_state_reuse": False}}
                }}), flush=True)
                request = json.loads(sys.stdin.readline())
                assert "transcript_reference" not in request["artifacts"]
                assert "quotient_reference" not in request["artifacts"]
                assert all(set(value) == {{"path"}} for value in request["artifacts"].values())
                adapted_path = request["artifacts"]["adapted_input"]["path"]
                proof = b"verified-proof"
                rust_verifier = {rust_verifier_evidence(b"verified-proof")!r}
                proof_path = pathlib.Path(request["outputs"]["proof"])
                report_path = pathlib.Path(request["outputs"]["report"])
                proof_path.write_bytes(proof)
                report_path.write_text(json.dumps({{
                    "status": "completed", "proof_verified": True, "proving_speed_verified": True,
                    "self_contained": False, "parity_fixture_used": False,
                    "proof_derived_artifact_used": True, "statement_self_derived": True,
                    "artifact_manifest_digest": manifest_digest,
                    "artifact_manifest": artifact_manifest,
                    "artifact_objects": artifact_objects,
                    "provenance_complete": True,
                    "protocol": proof_protocol, "protocol_complete": True,
                    "daemon_executable_sha256": executable_sha256,
                    "runner_executable_sha256": executable_sha256,
                    "runner_linkage": "in_process",
                    "rust_verifier": rust_verifier,
                    "cli_report": {{"proof_layout": {TEST_PROOF_LAYOUT!r}}},
                    "prove_timing_scope": scope, "prove_wall_s": 4.0, "prove_mhz": 2.0,
                    "reuse": {{"runtime": True, "resident_arena": False,
                        "preprocessed_state": False}},
                    "input": {{"path": adapted_path,
                        "sha256": hashlib.sha256(pathlib.Path(adapted_path).read_bytes()).hexdigest(),
                        "adapted_cycles": 8000000}}
                }}))
                print(json.dumps({{
                    "protocol": protocol, "version": version, "type": "result", "status": "verified",
                    "sequence": request["sequence"], "request_id": request["request_id"],
                    "proof_verified": True, "outputs_committed": True, "adapted_cycles": 8000000,
                    "prove_wall_s": 4.0, "prove_timing_scope": scope, "prove_mhz": 2.0,
                    "session_block_wall_s": 4.1, "proof_bytes": len(proof),
                    "proof_sha256": hashlib.sha256(proof).hexdigest(),
                    "adapted_input_sha256": hashlib.sha256(pathlib.Path(adapted_path).read_bytes()).hexdigest(),
                    "self_contained": False, "parity_fixture_used": False,
                    "proof_derived_artifact_used": True, "statement_self_derived": True,
                    "artifact_manifest_digest": manifest_digest,
                    "artifact_objects": artifact_objects,
                    "provenance_complete": True,
                    "proof_protocol": proof_protocol, "protocol_complete": True,
                    "daemon_executable_sha256": executable_sha256,
                    "runner_executable_sha256": executable_sha256,
                    "runner_linkage": "in_process",
                    "rust_verifier": rust_verifier,
                    "reuse": {{"runtime": True, "resident_arena": False, "preprocessed_state": False}}
                }}), flush=True)
                shutdown = json.loads(sys.stdin.readline())
                print(json.dumps({{"protocol": protocol, "version": version, "type": "closed",
                    "completed": shutdown["next_sequence"]}}), flush=True)
            """))
            client = MODULE.PersistentSessionClient([sys.executable, "-u", str(daemon)])
            ready = client.start()
            self.assertEqual(ready["session_id"], "test-session")
            result = client.prove(request, timeout_s=2.0)
            self.assertEqual(result.proof_bytes, len(b"verified-proof"))
            client.close()

    def test_client_can_preserve_daemon_stderr_without_wrapping_executable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            daemon = root / "diagnostic_daemon.py"
            daemon.write_text(textwrap.dedent(f"""
                import hashlib, json, pathlib, sys
                executable_sha256 = hashlib.sha256(pathlib.Path(sys.executable).resolve().read_bytes()).hexdigest()
                print("diagnostic before ready", file=sys.stderr, flush=True)
                print(json.dumps({{
                    "protocol": {MODULE.PROTOCOL!r},
                    "version": {MODULE.VERSION!r},
                    "type": "ready",
                    "session_id": "diagnostic-test",
                    "daemon_executable_sha256": executable_sha256,
                    "runner_executable_sha256": executable_sha256,
                    "runner_linkage": "in_process",
                    "rust_verifier": {rust_verifier_identity()!r},
                    "capabilities": {{"strict_order": True, "atomic_outputs": True,
                        "verified_proofs": True, "runtime_reuse": True,
                        "resident_arena_reuse": False, "preprocessed_state_reuse": False}}
                }}), flush=True)
                shutdown = json.loads(sys.stdin.readline())
                print("diagnostic before close", file=sys.stderr, flush=True)
                print(json.dumps({{"protocol": {MODULE.PROTOCOL!r},
                    "version": {MODULE.VERSION!r}, "type": "closed",
                    "completed": shutdown["next_sequence"]}}), flush=True)
            """))
            stderr_path = root / "daemon.stderr"
            with stderr_path.open("w+b") as daemon_stderr:
                client = MODULE.PersistentSessionClient(
                    [sys.executable, "-u", str(daemon)],
                    daemon_stderr=daemon_stderr,
                )
                self.assertEqual(client.command[0], str(Path(sys.executable).resolve()))
                client.start()
                client.close()
                self.assertFalse(daemon_stderr.closed)
                daemon_stderr.seek(0)
                self.assertEqual(
                    daemon_stderr.read().decode().splitlines(),
                    ["diagnostic before ready", "diagnostic before close"],
                )

    def test_client_aborts_on_mismatched_sequence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            request = self.make_request(root)
            daemon = root / "bad_daemon.py"
            daemon.write_text(textwrap.dedent(f"""
                import hashlib, json, pathlib, sys
                protocol = {MODULE.PROTOCOL!r}
                version = {MODULE.VERSION!r}
                executable_sha256 = hashlib.sha256(pathlib.Path(sys.executable).resolve().read_bytes()).hexdigest()
                print(json.dumps({{
                    "protocol": protocol, "version": version, "type": "ready", "session_id": "bad-session",
                    "daemon_executable_sha256": executable_sha256,
                    "runner_executable_sha256": executable_sha256,
                    "runner_linkage": "in_process",
                    "rust_verifier": {rust_verifier_identity()!r},
                    "capabilities": {{"strict_order": True, "atomic_outputs": True,
                        "verified_proofs": True, "runtime_reuse": True,
                        "resident_arena_reuse": False, "preprocessed_state_reuse": False}}
                }}), flush=True)
                request = json.loads(sys.stdin.readline())
                print(json.dumps({{
                    "protocol": protocol, "version": version, "type": "error",
                    "sequence": request["sequence"] + 1, "request_id": request["request_id"],
                    "code": "proof_failed", "message": "deliberate"
                }}), flush=True)
            """))
            client = MODULE.PersistentSessionClient([sys.executable, "-u", str(daemon)])
            client.start()
            with self.assertRaisesRegex(MODULE.SessionProtocolError, "does not match"):
                client.prove(request, timeout_s=2.0)
            self.assertIsNone(client.process)

    def test_client_rejects_executable_path_replacement_before_proof(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            request = self.make_request(root)
            executable = root / "python-copy"
            shutil.copy2(Path(sys.executable).resolve(strict=True), executable)
            daemon = root / "identity_daemon.py"
            daemon.write_text(textwrap.dedent(f"""
                import hashlib, json, pathlib, sys
                executable_sha256 = hashlib.sha256(pathlib.Path(sys.executable).resolve().read_bytes()).hexdigest()
                print(json.dumps({{
                    "protocol": {MODULE.PROTOCOL!r},
                    "version": {MODULE.VERSION!r},
                    "type": "ready",
                    "session_id": "mutation-test",
                    "daemon_executable_sha256": executable_sha256,
                    "runner_executable_sha256": executable_sha256,
                    "runner_linkage": "in_process",
                    "rust_verifier": {rust_verifier_identity()!r},
                    "capabilities": {{"strict_order": True, "atomic_outputs": True,
                        "verified_proofs": True, "runtime_reuse": True,
                        "resident_arena_reuse": False, "preprocessed_state_reuse": False}}
                }}), flush=True)
                sys.stdin.read()
            """))
            client = MODULE.PersistentSessionClient([str(executable), "-u", str(daemon)])
            client.start()

            replacement = root / "replacement"
            replacement.write_bytes(b"different executable bytes")
            replacement.chmod(0o755)
            os.replace(replacement, executable)
            with self.assertRaisesRegex(MODULE.SessionProtocolError, "changed after startup"):
                client.prove(request, timeout_s=2.0)
            self.assertIsNone(client.process)


if __name__ == "__main__":
    unittest.main()
