import importlib.util
from dataclasses import replace
import hashlib
import io
import json
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "sn_pie_metal_queue.py"
EXAMPLE_MANIFEST = Path(__file__).resolve().parents[1] / "sn_pie_metal_queue.example.json"
SPEC = importlib.util.spec_from_file_location("sn_pie_metal_queue", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
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
        "protocol_digest": "44" * 32,
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


class StepClock:
    def __init__(self):
        self.value = 0.0

    def __call__(self):
        value = self.value
        self.value += 1.0
        return value


class FakeAdapter:
    name = "fake_adapter"

    def prepare(self, pie, destination, production):
        return MODULE.AdaptationResult(
            status="completed",
            adapted_input=pie.adapted_input,
            wall_s=0.25,
            cache_hit=not production,
        )


class FakeExecutor:
    name = "fake_executor"

    def __init__(self, fail_at=None):
        self.calls = 0
        self.fail_at = fail_at

    def execute(self, request):
        request.proof_output.write_bytes(b"proof")
        verified = self.calls != self.fail_at
        rust_verifier = rust_verifier_evidence()
        if not verified:
            rust_verifier.update({"status": "failed", "verified": False})
        self.calls += 1
        return MODULE.ExecutionResult(
            launch_status="completed",
            returncode=0,
            executor_wall_s=2.7,
            report={
                "status": "completed",
                "proof_verified": verified,
                "proving_speed_verified": verified,
                "self_contained": True,
                "parity_fixture_used": False,
                "proof_derived_artifact_used": False,
                "statement_self_derived": True,
                "rust_verifier": rust_verifier,
                "artifact_manifest_digest": "ab" * 32,
                "provenance_complete": True,
                "protocol": MODULE.PROTOCOL_PARAMETERS.copy(),
                "pow_telemetry": {
                    "scope": "cpu_nonce_search_or_fixture_validation_only",
                    "complete": True,
                    "interaction": {
                        "nonce": 11,
                        "wall_s": 0.25,
                        "mode": "self_ground",
                        "bits": 24,
                        "invocations": 1,
                    },
                    "query": {
                        "nonce": 12,
                        "wall_s": 0.5,
                        "mode": "self_ground",
                        "bits": 26,
                        "invocations": 1,
                    },
                },
                "prove_timing_scope": MODULE.SESSION_PROTOCOL.PROVE_TIMING_SCOPE,
                "prove_wall_s": 2.0,
                "prove_mhz": 4.0,
                "wall_s": 2.5,
                "input": {
                    "path": str(request.adapted_input.resolve()),
                    "sha256": hashlib.sha256(request.adapted_input.read_bytes()).hexdigest(),
                    "adapted_cycles": 8_000_000,
                },
                "resource_usage": {
                    "max_rss_bytes": 1000 + self.calls,
                    "peak_footprint_bytes": 2000 + self.calls,
                },
                "pipeline_cache_delta": {
                    "library_cache_hits": 1,
                    "library_cache_misses": 2,
                    "pipeline_cache_hits": 3,
                    "binary_archive_hits": 4,
                    "binary_archive_misses": 5,
                    "direct_compiles": 6,
                    "archive_populations": 7,
                    "archive_serializations": 8,
                    "pipeline_preparation_seconds": 0.125,
                    "library_preparation_seconds": 0.25,
                },
            },
        )


def generated_adaptation(destination, wall_s=0.25):
    destination.write_bytes(b"STWZCPI\0payload")
    return MODULE.AdaptationResult(
        status="completed",
        adapted_input=destination,
        wall_s=wall_s,
        cache_hit=False,
    )


class TrackingPrefetchAdapter:
    name = "tracking_prefetch"

    def __init__(self, delay_s=0.0):
        self.delay_s = delay_s
        self.started = {position: threading.Event() for position in range(128)}
        self.calls = []

    @staticmethod
    def position(destination):
        return int(destination.name.split("-")[1])

    def prepare(self, pie, destination, production):
        position = self.position(destination)
        self.calls.append(("foreground", position, pie.index))
        self.started[position].set()
        return generated_adaptation(destination)

    def prepare_prefetch(self, pie, destination, production, cancel_event):
        position = self.position(destination)
        self.calls.append(("prefetch", position, pie.index))
        self.started[position].set()
        if self.delay_s:
            time.sleep(self.delay_s)
        if cancel_event.is_set():
            return MODULE.AdaptationResult(
                "cancelled", None, self.delay_s, False, failure_reason="adapter_cancelled"
            )
        return generated_adaptation(destination, max(0.25, self.delay_s))


class OrderedOverlapExecutor(FakeExecutor):
    def __init__(self, adapter, wait_for_position=1, fail_at=None):
        super().__init__(fail_at=fail_at)
        self.adapter = adapter
        self.wait_for_position = wait_for_position
        self.positions = []
        self.max_staged_inputs = 0

    def execute(self, request):
        self.positions.append(request.queue_position)
        if request.queue_position == 0:
            if not self.adapter.started[self.wait_for_position].wait(timeout=2.0):
                raise AssertionError("next adaptation did not overlap the current proof")
            time.sleep(0.01)
        self.max_staged_inputs = max(
            self.max_staged_inputs,
            len(list(request.adapted_input.parent.glob("*.adapted.stwzcpi"))),
        )
        return super().execute(request)


class SnPieMetalQueueTest(unittest.TestCase):
    def make_config(self, root: Path, adapter_command=None):
        files = {}
        for name in (
            "runner",
            "benchmark.py",
            "witness.bin",
            "feeds.bin",
            "relations.bin",
            "fixed.bin",
            "preprocessed.spill",
            "preprocessed.stwzppc",
        ):
            files[name] = root / name
            files[name].write_bytes(b"fixture")
        Path(f"{files['preprocessed.spill']}{MODULE.TREE0_MERKLE_SUFFIX}").write_bytes(b"fixture")
        pies = []
        for index in MODULE.PIE_INDICES:
            source = root / f"source-{index}"
            source.mkdir()
            adapted = root / f"adapted-{index}.stwzcpi"
            adapted.write_bytes(b"STWZCPI\0payload")
            per_pie = []
            for kind in ("schedule", "composition", "transcript", "quotient"):
                path = root / f"{kind}-{index}.bin"
                path.write_bytes(b"fixture")
                per_pie.append(path)
            per_pie[1].with_suffix(".metal").write_bytes(b"fixture")
            pies.append(
                MODULE.PieArtifacts(
                    index=index,
                    name=f"SN{index + 1}",
                    source_pie=source,
                    adapted_input=adapted,
                    schedule=per_pie[0],
                    witness_programs=None,
                    multiplicity_feeds=None,
                    composition=per_pie[1],
                    transcript_reference=per_pie[2],
                    quotient_reference=per_pie[3],
                )
            )
        shared = MODULE.SharedArtifacts(
            witness_programs=files["witness.bin"],
            multiplicity_feeds=files["feeds.bin"],
            relation_templates=files["relations.bin"],
            fixed_tables=files["fixed.bin"],
            preprocessed_evaluations=files["preprocessed.spill"],
            preprocessed_coefficients=files["preprocessed.stwzppc"],
            tree0_root_hex="ab" * 32,
        )
        return MODULE.QueueConfig(
            runner=files["runner"],
            benchmark_script=files["benchmark.py"],
            budget_gib="52",
            timeout_s=30.0,
            shared=shared,
            pies=tuple(pies),
            adapter_command=adapter_command,
            adapter_timeout_s=10.0,
        )

    def write_session_daemon(self, root: Path, *, result_runtime_reuse: bool = True) -> Path:
        daemon = root / "fake_session_daemon.py"
        daemon.write_text(f"""
import hashlib
import json
from pathlib import Path
import struct
import sys

protocol = {MODULE.SESSION_PROTOCOL.PROTOCOL!r}
version = {MODULE.SESSION_PROTOCOL.VERSION!r}
scope = {MODULE.SESSION_PROTOCOL.PROVE_TIMING_SCOPE!r}
session_id = "queue-test-session"
executable_sha256 = hashlib.sha256(Path(sys.executable).resolve().read_bytes()).hexdigest()
protocol_document = {MODULE.PROTOCOL_PARAMETERS!r}
channel = protocol_document["channel"].encode()
protocol_encoding = bytearray(b"stwo-zig-proof-protocol\\x00")
protocol_encoding.extend(struct.pack("<IH", 1, len(channel)))
protocol_encoding.extend(channel)
for field in ("channel_salt", "log_blowup_factor", "n_queries", "interaction_pow_bits", "query_pow_bits", "fri_fold_step"):
    protocol_encoding.extend(struct.pack("<I", protocol_document[field]))
protocol_encoding.extend(b"\\x00")
protocol_encoding.extend(struct.pack("<I", protocol_document["fri_log_last_layer_degree_bound"]))
protocol_sha256 = hashlib.sha256(protocol_encoding).digest()
role_codes = {MODULE.SESSION_PROTOCOL.ARTIFACT_ROLES!r}
object_cache = {{}}
prepared_identity_cache = None
print(json.dumps({{
    "protocol": protocol,
    "version": version,
    "type": "ready",
    "session_id": session_id,
    "daemon_executable_sha256": executable_sha256,
    "runner_executable_sha256": executable_sha256,
    "runner_linkage": "in_process",
    "rust_verifier": {rust_verifier_identity()!r},
    "capabilities": {{
        "strict_order": True,
        "atomic_outputs": True,
        "verified_proofs": True,
        "runtime_reuse": True,
        "resident_arena_reuse": True,
        "preprocessed_state_reuse": True,
    }},
}}), flush=True)

expected = 0
while True:
    message = json.loads(sys.stdin.readline())
    if message["type"] == "shutdown":
        print(json.dumps({{
            "protocol": protocol,
            "version": version,
            "type": "closed",
            "completed": expected,
        }}), flush=True)
        break
    if message["sequence"] != expected:
        raise SystemExit("out-of-order request")
    artifact_objects = {{}}
    artifact_entries = []
    encoded_entries = []
    for role, reference in message["artifacts"].items():
        if set(reference) == {{"path"}}:
            diagnostic_path = reference["path"]
            payload = Path(diagnostic_path).read_bytes()
            object_id = hashlib.sha256(payload).hexdigest()
            byte_count = len(payload)
            object_cache[(role, diagnostic_path)] = (object_id, byte_count)
        else:
            object_id = reference["object_id"]
            byte_count = reference["bytes"]
            diagnostic_path = reference["diagnostic_path"]
            if object_cache.get((role, diagnostic_path)) != (object_id, byte_count):
                raise SystemExit("invalid cached artifact object")
        artifact_objects[role] = {{
            "object_id": object_id,
            "bytes": byte_count,
            "diagnostic_path": diagnostic_path,
        }}
        artifact_entries.append({{
            "role": role,
            "logical_name": "",
            "format_version": 1,
            "provenance": "raw",
            "bytes": byte_count,
            "sha256": object_id,
            "source_chain_complete": True,
            "source_digests": [],
            "generator": None,
        }})
        encoded = bytearray(struct.pack("<HH", role_codes[role], 0))
        encoded.extend(struct.pack("<IBQ", 1, 5, byte_count))
        encoded.extend(bytes.fromhex(object_id))
        encoded.extend(struct.pack("<BH", 1, 0))
        encoded.extend(b"\\x00")
        encoded_entries.append((role_codes[role], encoded))
    prepared_identity = tuple(
        (role, artifact_objects[role]["object_id"], artifact_objects[role]["bytes"])
        for role in sorted(artifact_objects)
        if role not in {{"adapted_input", "transcript_reference", "quotient_reference"}}
    )
    prepared_state_cache_hit = prepared_identity == prepared_identity_cache
    encoded_entries.sort(key=lambda item: item[0])
    manifest_encoding = bytearray(b"stwo-zig-artifact-manifest\\x00")
    manifest_encoding.extend(struct.pack("<I", 1))
    manifest_encoding.extend(protocol_sha256)
    manifest_encoding.extend(struct.pack("<H", len(encoded_entries)))
    for _, encoded in encoded_entries:
        manifest_encoding.extend(encoded)
    manifest_digest = hashlib.sha256(manifest_encoding).hexdigest()
    artifact_manifest = {{
        "schema_version": 1,
        "canonical_encoding": "STWZAM/1-little-endian",
        "protocol_sha256": protocol_sha256.hex(),
        "sha256": manifest_digest,
        "classification": {{
            "production_source_chain_complete": True,
            "parity_fixture_used": False,
            "proof_derived_artifact_used": False,
        }},
        "entries": artifact_entries,
    }}
    proof = f"proof-{{expected}}".encode()
    rust_verifier = {rust_verifier_evidence()!r}
    rust_verifier["proof_digest"] = hashlib.sha256(proof).hexdigest()
    proof_output = Path(message["outputs"]["proof"])
    report_output = Path(message["outputs"]["report"])
    proof_temporary = proof_output.with_suffix(".proof.tmp")
    report_temporary = report_output.with_suffix(".json.tmp")
    proof_temporary.write_bytes(proof)
    report = {{
        "schema_version": 2,
        "status": "completed",
        "proof_verified": True,
        "proving_speed_verified": True,
        "self_contained": True,
        "parity_fixture_used": False,
        "proof_derived_artifact_used": False,
        "statement_self_derived": True,
        "artifact_manifest_digest": manifest_digest,
        "artifact_manifest": artifact_manifest,
        "artifact_objects": artifact_objects,
        "provenance_complete": True,
        "protocol": {MODULE.PROTOCOL_PARAMETERS!r},
        "protocol_complete": True,
        "daemon_executable_sha256": executable_sha256,
        "runner_executable_sha256": executable_sha256,
        "runner_linkage": "in_process",
        "rust_verifier": rust_verifier,
        "pow_telemetry": {{
            "scope": "cpu_nonce_search_or_fixture_validation_only",
            "complete": True,
            "interaction": {{"nonce": 11, "wall_s": 0.25,
                "mode": "self_ground", "bits": 24, "invocations": 1}},
            "query": {{"nonce": 12, "wall_s": 0.5,
                "mode": "self_ground", "bits": 26, "invocations": 1}},
        }},
        "prove_timing_scope": scope,
        "prove_wall_s": 2.0,
        "prove_mhz": 4.0,
        "reuse": {{
            "runtime": {result_runtime_reuse!r},
            "resident_arena": prepared_state_cache_hit,
            "preprocessed_state": prepared_state_cache_hit,
        }},
        "prepared_state_cache_hit": prepared_state_cache_hit,
        "prepared_state": {{
            "cache_hit": prepared_state_cache_hit,
            "arena_bytes": 4096,
            "snapshot_bytes": 1024,
            "clear_bytes": 4096 if prepared_state_cache_hit else 0,
            "capture_gpu_ms": 0.0 if prepared_state_cache_hit else 0.25,
            "restore_gpu_ms": 0.1 if prepared_state_cache_hit else 0.0,
        }},
        "cli_report": {{
            "proof_layout": {TEST_PROOF_LAYOUT!r},
            "prepared_state_cache_hit": prepared_state_cache_hit,
            "resident_arena_bytes": 4096,
            "prepared_state_snapshot_bytes": 1024,
            "prepared_state_clear_bytes": 4096 if prepared_state_cache_hit else 0,
            "prepared_state_capture_gpu_ms": 0.0 if prepared_state_cache_hit else 0.25,
            "prepared_state_restore_gpu_ms": 0.1 if prepared_state_cache_hit else 0.0,
        }},
        "input": {{"path": artifact_objects["adapted_input"]["diagnostic_path"],
            "sha256": artifact_objects["adapted_input"]["object_id"],
            "adapted_cycles": 8000000}},
        "resource_usage": {{}},
        "pipeline_cache_delta": {{
            "library_cache_hits": 1,
            "library_cache_misses": 2,
            "pipeline_cache_hits": 3,
            "binary_archive_hits": 4,
            "binary_archive_misses": 5,
            "direct_compiles": 6,
            "archive_populations": 7,
            "archive_serializations": 8,
            "pipeline_preparation_seconds": 0.125,
            "library_preparation_seconds": 0.25,
        }},
    }}
    report_temporary.write_text(json.dumps(report))
    proof_temporary.replace(proof_output)
    report_temporary.replace(report_output)
    print(json.dumps({{
        "protocol": protocol,
        "version": version,
        "type": "result",
        "status": "verified",
        "sequence": expected,
        "request_id": message["request_id"],
        "proof_verified": True,
        "outputs_committed": True,
        "adapted_cycles": 8000000,
        "prove_wall_s": 2.0,
        "prove_timing_scope": scope,
        "prove_mhz": 4.0,
        "session_block_wall_s": 2.1,
        "proof_bytes": len(proof),
        "proof_sha256": hashlib.sha256(proof).hexdigest(),
        "adapted_input_sha256": artifact_objects["adapted_input"]["object_id"],
        "self_contained": True,
        "parity_fixture_used": False,
        "proof_derived_artifact_used": False,
        "statement_self_derived": True,
        "artifact_manifest_digest": manifest_digest,
        "artifact_objects": artifact_objects,
        "provenance_complete": True,
        "proof_protocol": {MODULE.PROTOCOL_PARAMETERS!r},
        "protocol_complete": True,
        "daemon_executable_sha256": executable_sha256,
        "runner_executable_sha256": executable_sha256,
        "runner_linkage": "in_process",
        "rust_verifier": rust_verifier,
        "reuse": {{
            "runtime": {result_runtime_reuse!r},
            "resident_arena": prepared_state_cache_hit,
            "preprocessed_state": prepared_state_cache_hit,
        }},
    }}), flush=True)
    prepared_identity_cache = prepared_identity
    expected += 1
""")
        return daemon

    def test_seeded_queue_is_deterministic_and_bounded(self):
        ten = MODULE.seeded_queue(123, 10)
        hundred = MODULE.seeded_queue(123, 100)
        self.assertEqual(ten, MODULE.seeded_queue(123, 10))
        self.assertEqual(ten, hundred[:10])
        self.assertEqual(len(hundred), 100)
        self.assertTrue(all(index in MODULE.PIE_INDICES for index in hundred))
        self.assertNotEqual(ten, MODULE.seeded_queue(124, 10))

    def test_protocol_parameters_reject_boolean_integer_alias(self):
        protocol = MODULE.PROTOCOL_PARAMETERS.copy()
        protocol["log_blowup_factor"] = True
        self.assertEqual(
            MODULE._protocol_parameters({"protocol": protocol}),
            (None, False),
        )

    def test_manifest_distinguishes_source_pie_from_adapted_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = {
                "runner": "runner",
                "shared": {
                    "witness_programs": "generic-witness",
                    "multiplicity_feeds": "generic-feeds",
                    "relation_templates": "relations",
                    "fixed_tables": "fixed",
                    "preprocessed_evaluations": "evaluations",
                    "preprocessed_coefficients": "coefficients",
                    "tree0_root_hex": "ab" * 32,
                },
                "pies": [
                    {
                        "index": index,
                        "name": f"SN{index + 1}",
                        "source_pie": f"source-{index}",
                        "adapted_input": f"adapted-{index}",
                        "schedule": f"schedule-{index}",
                        "composition": f"composition-{index}",
                        "transcript_reference": f"transcript-{index}",
                        "quotient_reference": f"quotient-{index}",
                        **(
                            {
                                "witness_programs": "witness-override-2",
                                "multiplicity_feeds": "feeds-override-2",
                            }
                            if index == 2
                            else {}
                        ),
                    }
                    for index in MODULE.PIE_INDICES
                ],
            }
            path = root / "manifest.json"
            path.write_text(json.dumps(manifest))
            config = MODULE.load_manifest(path)
            self.assertEqual(config.pies[2].source_pie, root.resolve() / "source-2")
            self.assertEqual(config.pies[2].adapted_input, root.resolve() / "adapted-2")
            self.assertIsNone(config.pies[0].witness_programs)
            self.assertEqual(config.witness_programs_for(config.pies[0]), root.resolve() / "generic-witness")
            self.assertEqual(
                config.witness_programs_for(config.pies[2]),
                root.resolve() / "witness-override-2",
            )

    def test_manifest_accepts_absent_diagnostics_and_rejects_unpaired_reference(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = json.loads(EXAMPLE_MANIFEST.read_text())
            for pie in manifest["pies"]:
                pie.pop("transcript_reference", None)
                pie.pop("quotient_reference", None)
            path = root / "manifest.json"
            path.write_text(json.dumps(manifest))

            config = MODULE.load_manifest(path)
            self.assertTrue(all(pie.transcript_reference is None for pie in config.pies))
            self.assertTrue(all(pie.quotient_reference is None for pie in config.pies))

            manifest["pies"][0]["transcript_reference"] = "transcript-only"
            path.write_text(json.dumps(manifest))
            with self.assertRaisesRegex(ValueError, "must both be present or absent"):
                MODULE.load_manifest(path)

    def test_manifest_persistent_session_is_explicit_and_validated(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            document = json.loads(EXAMPLE_MANIFEST.read_text())
            document["session"] = {
                "command": ["zig-out/bin/metal-arena-session", "--jsonl"],
                "startup_timeout_s": 12.5,
            }
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps(document))
            config = MODULE.load_manifest(manifest)
            self.assertEqual(
                config.session_command,
                ("zig-out/bin/metal-arena-session", "--jsonl"),
            )
            self.assertEqual(config.session_startup_timeout_s, 12.5)

            document["session"]["command"] = []
            manifest.write_text(json.dumps(document))
            with self.assertRaisesRegex(ValueError, "non-empty string array"):
                MODULE.load_manifest(manifest)

    def test_example_manifest_loads_and_expands_home_paths(self):
        config = MODULE.load_manifest(EXAMPLE_MANIFEST)
        self.assertEqual(len(config.pies), 4)
        self.assertEqual(
            config.pies[0].source_pie,
            Path.home() / "Downloads/SN-PIEs/SN_PIE_1",
        )
        self.assertTrue(all(pie.witness_programs is None for pie in config.pies))
        self.assertTrue(
            all(
                config.witness_programs_for(pie) == config.shared.witness_programs
                for pie in config.pies
            )
        )
        self.assertEqual(config.adapter_prefetch_depth, 2)

    def test_manifest_prefetch_depth_is_opt_in_and_validated(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            document = json.loads(EXAMPLE_MANIFEST.read_text())
            document["adapter"]["prefetch_depth"] = 2
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps(document))
            self.assertEqual(MODULE.load_manifest(manifest).adapter_prefetch_depth, 2)
            document["adapter"]["prefetch_depth"] = -1
            manifest.write_text(json.dumps(document))
            with self.assertRaisesRegex(ValueError, "non-negative integer"):
                MODULE.load_manifest(manifest)
            document["adapter"]["prefetch_depth"] = True
            manifest.write_text(json.dumps(document))
            with self.assertRaisesRegex(ValueError, "non-negative integer"):
                MODULE.load_manifest(manifest)

    def test_production_rejects_cache_only_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            config = self.make_config(Path(directory))
            MODULE.validate_config(config)
            with self.assertRaisesRegex(ValueError, "production mode requires adapter.command"):
                MODULE.validate_config(config, production=True)

    def test_adapter_command_requires_raw_input_and_adapted_output_placeholders(self):
        with tempfile.TemporaryDirectory() as directory:
            config = self.make_config(Path(directory), ("adapter", "{source_pie}"))
            with self.assertRaisesRegex(ValueError, r"\{adapted_input\}"):
                MODULE.validate_config(config, production=True)

    def test_nonproduction_cache_hit_is_explicit(self):
        with tempfile.TemporaryDirectory() as directory:
            config = self.make_config(Path(directory))
            result = MODULE.CacheOrCommandAdapter(config).prepare(
                config.pies[0], Path(directory) / "unused.stwzcpi", production=False
            )
            self.assertEqual(result.status, "completed")
            self.assertTrue(result.cache_hit)
            self.assertEqual(result.adapted_input, config.pies[0].adapted_input)
            self.assertEqual(result.wall_s, 0.0)

    def test_production_adapter_formats_argv_and_captures_resources(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = self.make_config(
                root,
                (
                    "adapter",
                    "--source",
                    "{source_pie}",
                    "--out",
                    "{adapted_input}",
                    "{pie_index}",
                    "{pie_name}",
                ),
            )
            destination = root / "generated.stwzcpi"

            def run(command, **kwargs):
                destination.write_bytes(b"STWZCPI\0payload")
                return MODULE.subprocess.CompletedProcess(
                    command,
                    0,
                    "",
                    "  4096 maximum resident set size\n  8192 peak memory footprint\n",
                )

            with (
                mock.patch.object(MODULE.subprocess, "run", side_effect=run) as execute,
                mock.patch.object(MODULE.time, "perf_counter", side_effect=(10.0, 11.5)),
            ):
                result = MODULE.CacheOrCommandAdapter(config).prepare(
                    config.pies[2], destination, production=True
                )
            command = execute.call_args.args[0]
            self.assertEqual(command[:3], ["/usr/bin/time", "-lp", "adapter"])
            self.assertIn(str(config.pies[2].source_pie), command)
            self.assertIn(str(destination), command)
            self.assertEqual(command[-2:], ["2", "SN3"])
            self.assertEqual(result.status, "completed")
            self.assertFalse(result.cache_hit)
            self.assertEqual(result.wall_s, 1.5)
            self.assertEqual(result.max_rss_bytes, 4096)
            self.assertEqual(result.peak_footprint_bytes, 8192)

    def test_prefetch_adapter_cancels_the_external_process_group(self):
        class Process:
            pid = 4321
            returncode = -15

            def __init__(self, cancel_event):
                self.cancel_event = cancel_event

            def communicate(self, timeout=None):
                if timeout is not None:
                    self.cancel_event.set()
                    raise MODULE.subprocess.TimeoutExpired(["adapter"], timeout)
                return "", ""

            def wait(self, timeout=None):
                return self.returncode

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = self.make_config(
                root,
                ("adapter", "{source_pie}", "{adapted_input}"),
            )
            destination = root / "cancelled.stwzcpi"
            cancel_event = threading.Event()
            with (
                mock.patch.object(
                    MODULE.subprocess,
                    "Popen",
                    return_value=Process(cancel_event),
                ),
                mock.patch.object(MODULE.os, "killpg") as kill_group,
            ):
                result = MODULE.CacheOrCommandAdapter(config).prepare_prefetch(
                    config.pies[0], destination, True, cancel_event
                )
            self.assertEqual(result.status, "cancelled")
            self.assertEqual(result.failure_reason, "adapter_cancelled")
            kill_group.assert_called_once_with(4321, MODULE.signal.SIGTERM)
            self.assertFalse(destination.exists())

    def test_benchmark_command_uses_selected_pie_artifacts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = self.make_config(root)
            pie = config.pies[3]
            request = MODULE.BlockRequest(
                queue_position=0,
                pie=pie,
                adapted_input=pie.adapted_input,
                proof_output=root / "proof",
                benchmark_report=root / "report.json",
            )
            command = MODULE.benchmark_command(config, request)
            self.assertEqual(command[command.index("--input") + 1], str(pie.adapted_input))
            self.assertEqual(command[command.index("--schedule") + 1], str(pie.schedule))
            self.assertEqual(
                command[command.index("--witness-programs") + 1],
                str(config.shared.witness_programs),
            )
            self.assertEqual(
                command[command.index("--multiplicity-feeds") + 1],
                str(config.shared.multiplicity_feeds),
            )
            self.assertEqual(command[command.index("--composition") + 1], str(pie.composition))
            self.assertEqual(
                command[command.index("--transcript-reference") + 1],
                str(pie.transcript_reference),
            )

    def test_benchmark_command_omits_absent_diagnostic_references(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = self.make_config(root)
            pie = replace(
                config.pies[1],
                transcript_reference=None,
                quotient_reference=None,
            )
            request = MODULE.BlockRequest(
                queue_position=0,
                pie=pie,
                adapted_input=pie.adapted_input,
                proof_output=root / "proof",
                benchmark_report=root / "report.json",
            )
            command = MODULE.benchmark_command(config, request)
            self.assertNotIn("--transcript-reference", command)
            self.assertNotIn("--quotient-reference", command)

    def test_benchmark_command_honors_future_semantic_graph_override(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = self.make_config(root)
            witness_override = root / "witness-override.bin"
            feeds_override = root / "feeds-override.bin"
            witness_override.touch()
            feeds_override.touch()
            pie = replace(
                config.pies[3],
                witness_programs=witness_override,
                multiplicity_feeds=feeds_override,
            )
            request = MODULE.BlockRequest(
                queue_position=0,
                pie=pie,
                adapted_input=pie.adapted_input,
                proof_output=root / "proof",
                benchmark_report=root / "report.json",
            )
            command = MODULE.benchmark_command(config, request)
            self.assertEqual(
                command[command.index("--witness-programs") + 1],
                str(witness_override),
            )
            self.assertEqual(
                command[command.index("--multiplicity-feeds") + 1],
                str(feeds_override),
            )

    def test_verified_queue_reports_sustained_full_queue_mhz(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = self.make_config(root)
            report = root / "output" / "queue.json"
            document, exit_code = MODULE.run_queue(
                config,
                [0, 3],
                123,
                report.parent,
                report,
                FakeExecutor(),
                FakeAdapter(),
                clock=StepClock(),
            )
            self.assertEqual(exit_code, 0)
            self.assertTrue(document["summary"]["all_proofs_verified"])
            self.assertEqual(document["summary"]["adapted_cycles"], 16_000_000)
            self.assertEqual(document["summary"]["queue_wall_s"], 7.0)
            self.assertAlmostEqual(document["summary"]["sustained_mhz"], 16.0 / 7.0)
            self.assertAlmostEqual(document["summary"]["sustained_end_to_end_mhz"], 16.0 / 7.0)
            self.assertEqual(document["summary"]["aggregate_prove_only_mhz"], 4.0)
            self.assertEqual(document["summary"]["peak_verified_prove_only_mhz"], 4.0)
            self.assertEqual(document["summary"]["cold_first_block_end_to_end_mhz"], 8.0)
            self.assertIsNone(document["summary"]["persistent_session_service_mhz"])
            self.assertEqual(document["summary"]["sum_execution_adaptation_wall_s"], 0.5)
            self.assertTrue(document["summary"]["self_contained_proofs"])
            self.assertEqual(document["summary"]["parity_fixture_blocks"], 0)
            self.assertEqual(document["summary"]["proof_derived_artifact_blocks"], 0)
            self.assertTrue(document["summary"]["pipeline_cache_telemetry_complete"])
            self.assertEqual(
                document["summary"]["pipeline_cache_delta"],
                {
                    "library_cache_hits": 2,
                    "library_cache_misses": 4,
                    "pipeline_cache_hits": 6,
                    "binary_archive_hits": 8,
                    "binary_archive_misses": 10,
                    "direct_compiles": 12,
                    "archive_populations": 14,
                    "archive_serializations": 16,
                    "pipeline_preparation_seconds": 0.25,
                    "library_preparation_seconds": 0.5,
                },
            )
            self.assertTrue(all(block["self_contained"] for block in document["blocks"]))
            self.assertTrue(all(not block["parity_fixture_used"] for block in document["blocks"]))
            self.assertTrue(
                all(not block["proof_derived_artifact_used"] for block in document["blocks"])
            )
            self.assertTrue(
                all(block["pipeline_cache_delta"] is not None for block in document["blocks"])
            )
            self.assertTrue(all(block["adapted_cache_hit"] for block in document["blocks"]))
            self.assertEqual(len({block["proof_output"] for block in document["blocks"]}), 2)
            self.assertEqual(len({block["benchmark_report"] for block in document["blocks"]}), 2)
            self.assertTrue(all(len(block["proof_sha256"]) == 64 for block in document["blocks"]))
            self.assertTrue(all(
                block["rust_verifier"] == rust_verifier_evidence()
                for block in document["blocks"]
            ))
            self.assertTrue(
                document["production_streaming_acceptance"]["cryptographic_verification"]
            )

    def test_queue_rejects_missing_false_drifting_or_inexact_rust_verifier_evidence(self):
        def missing(report):
            del report["rust_verifier"]

        def false_success(report):
            report["rust_verifier"]["verified"] = False

        def proof_digest_drift(report):
            report["rust_verifier"]["proof_digest"] = "66" * 32

        def unknown_field(report):
            report["rust_verifier"]["unexpected"] = True

        mutations = {
            "missing": missing,
            "verified false": false_success,
            "proof digest drift": proof_digest_drift,
            "unknown field": unknown_field,
        }
        for label, mutate in mutations.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                config = self.make_config(root)

                class InvalidRustEvidenceExecutor(FakeExecutor):
                    def execute(self, request):
                        result = super().execute(request)
                        mutate(result.report)
                        return result

                executor = InvalidRustEvidenceExecutor()
                report = root / "output" / "queue.json"
                document, exit_code = MODULE.run_queue(
                    config,
                    [0, 1],
                    123,
                    report.parent,
                    report,
                    executor,
                    FakeAdapter(),
                )
                self.assertEqual(exit_code, 1)
                self.assertEqual(executor.calls, 1)
                self.assertEqual(document["completed_blocks"], 1)
                self.assertEqual(document["blocks"][0]["status"], "failed")
                self.assertTrue(any(
                    "rust_verifier" in reason
                    for reason in document["blocks"][0]["failure_reasons"]
                ))
                self.assertIsNone(document["summary"]["sustained_mhz"])
                self.assertIsNone(document["summary"]["sustained_end_to_end_mhz"])
                self.assertFalse(
                    document["production_streaming_acceptance"]["cryptographic_verification"]
                )

    def test_queue_requires_session_validated_rust_evidence_to_match_report(self):
        class SessionEvidenceExecutor(FakeExecutor):
            def __init__(self, mutation):
                super().__init__()
                self.mutation = mutation

            def execute(self, request):
                result = super().execute(request)
                authoritative = result.report["rust_verifier"].copy()
                self.mutation(result.report)
                return replace(
                    result,
                    session_id="validated-session",
                    rust_verifier=authoritative,
                )

        cases = {
            "missing": lambda report: report.pop("rust_verifier"),
            "mismatch": lambda report: report["rust_verifier"].update(
                {"result_sha256": "77" * 32}
            ),
        }
        for label, mutation in cases.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                config = self.make_config(root)
                report = root / "output" / "queue.json"
                document, exit_code = MODULE.run_queue(
                    config,
                    [0],
                    123,
                    report.parent,
                    report,
                    SessionEvidenceExecutor(mutation),
                    FakeAdapter(),
                )
                self.assertEqual(exit_code, 1)
                self.assertTrue(any(
                    "rust_verifier_session" in reason
                    for reason in document["blocks"][0]["failure_reasons"]
                ))

    def test_ten_and_hundred_block_acceptance_requires_rust_evidence_for_every_block(self):
        for length in (10, 100):
            with self.subTest(length=length):
                indices = MODULE.seeded_queue(123, length)
                blocks = [
                    {
                        "status": "verified",
                        "queue_position": position,
                        "pie_index": pie_index,
                        "adapted_cache_hit": False,
                        "session_id": "test-session",
                        "proof_sha256": hashlib.sha256(b"proof").hexdigest(),
                        "proof_bytes": len(b"proof"),
                        "self_contained": True,
                        "parity_fixture_used": False,
                        "proof_derived_artifact_used": False,
                        "statement_self_derived": True,
                        "provenance_complete": True,
                        "artifact_manifest_digest": "ab" * 32,
                        "protocol_complete": True,
                        "protocol": MODULE.PROTOCOL_PARAMETERS.copy(),
                        "pow_telemetry_complete": True,
                        "rust_verifier": rust_verifier_evidence(),
                    }
                    for position, pie_index in enumerate(indices)
                ]
                accepted = MODULE.queue_document(
                    indices,
                    123,
                    MODULE.PersistentSessionExecutor.name,
                    "test-adapter",
                    True,
                    blocks,
                    1.0,
                    "completed",
                    adapter_prefetch_depth=2,
                    max_adapter_prefetch_pending=2,
                    session_shutdown_status="completed",
                )["production_streaming_acceptance"]
                self.assertTrue(accepted["cryptographic_verification"])

                del blocks[length // 2]["rust_verifier"]
                rejected = MODULE.queue_document(
                    indices,
                    123,
                    MODULE.PersistentSessionExecutor.name,
                    "test-adapter",
                    True,
                    blocks,
                    1.0,
                    "completed",
                    adapter_prefetch_depth=2,
                    max_adapter_prefetch_pending=2,
                    session_shutdown_status="completed",
                )["production_streaming_acceptance"]
                self.assertFalse(rejected["cryptographic_verification"])
                self.assertFalse(rejected["passed"])

    def test_production_reporting_fails_closed_on_missing_or_forbidden_provenance(self):
        class MissingProvenanceExecutor(FakeExecutor):
            def execute(self, request):
                result = super().execute(request)
                del result.report["self_contained"]
                del result.report["parity_fixture_used"]
                del result.report["proof_derived_artifact_used"]
                return result

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = self.make_config(root)
            report = root / "output" / "queue.json"
            document, exit_code = MODULE.run_queue(
                config,
                [0],
                123,
                report.parent,
                report,
                MissingProvenanceExecutor(),
                FakeAdapter(),
                production=True,
            )
            self.assertEqual(exit_code, 1)
            self.assertEqual(document["status"], "production_rejected")
            self.assertEqual(document["throughput_evidence_class"], "verified_diagnostic")
            self.assertIsNone(document["summary"]["sustained_mhz"])
            self.assertIsNone(document["summary"]["sustained_end_to_end_mhz"])
            block = document["blocks"][0]
            self.assertFalse(block["self_contained"])
            self.assertTrue(block["parity_fixture_used"])
            self.assertTrue(block["proof_derived_artifact_used"])
            acceptance = document["production_streaming_acceptance"]
            self.assertFalse(acceptance["self_contained_proofs"])
            self.assertFalse(acceptance["no_parity_fixtures"])
            self.assertFalse(acceptance["no_proof_derived_artifacts"])
            self.assertFalse(acceptance["passed"])

        indices = MODULE.seeded_queue(123, 10)
        blocks = [
            {
                "status": "verified",
                "queue_position": position,
                "pie_index": pie_index,
                "adapted_cache_hit": False,
                "session_id": "test-session",
                "proof_sha256": "ab" * 32,
                "proof_bytes": 1,
                "self_contained": True,
                "parity_fixture_used": False,
                "proof_derived_artifact_used": False,
            }
            for position, pie_index in enumerate(indices)
        ]
        blocks[3]["parity_fixture_used"] = True
        forbidden = MODULE.queue_document(
            indices,
            123,
            MODULE.PersistentSessionExecutor.name,
            "test-adapter",
            True,
            blocks,
            1.0,
            "completed",
            adapter_prefetch_depth=2,
            max_adapter_prefetch_pending=2,
            session_shutdown_status="completed",
        )["production_streaming_acceptance"]
        self.assertFalse(forbidden["no_parity_fixtures"])
        self.assertFalse(forbidden["passed"])

    def test_production_reporting_explicitly_rejects_incomplete_provenance(self):
        class IncompleteProvenanceExecutor(FakeExecutor):
            def execute(self, request):
                result = super().execute(request)
                result.report["artifact_manifest_digest"] = None
                result.report["provenance_complete"] = False
                return result

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = self.make_config(root)
            report = root / "output" / "queue.json"
            document, exit_code = MODULE.run_queue(
                config,
                [0],
                123,
                report.parent,
                report,
                IncompleteProvenanceExecutor(),
                FakeAdapter(),
                production=True,
            )
            self.assertEqual(exit_code, 1)
            self.assertEqual(document["status"], "production_rejected")
            self.assertEqual(
                document["throughput_evidence_class"],
                "verified_incomplete_evidence",
            )
            block = document["blocks"][0]
            self.assertTrue(block["statement_self_derived"])
            self.assertIsNone(block["artifact_manifest_digest"])
            self.assertFalse(block["provenance_complete"])
            acceptance = document["production_streaming_acceptance"]
            self.assertTrue(acceptance["self_contained_proofs"])
            self.assertTrue(acceptance["no_parity_fixtures"])
            self.assertTrue(acceptance["no_proof_derived_artifacts"])
            self.assertFalse(acceptance["complete_provenance"])
            self.assertFalse(acceptance["passed"])

    def test_production_reporting_explicitly_rejects_missing_protocol_object(self):
        class MissingProtocolExecutor(FakeExecutor):
            def execute(self, request):
                result = super().execute(request)
                del result.report["protocol"]
                return result

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = self.make_config(root)
            report = root / "output" / "queue.json"
            document, exit_code = MODULE.run_queue(
                config,
                [0],
                123,
                report.parent,
                report,
                MissingProtocolExecutor(),
                FakeAdapter(),
                production=True,
            )
            self.assertEqual(exit_code, 1)
            self.assertEqual(
                document["throughput_evidence_class"],
                "verified_incomplete_evidence",
            )
            self.assertIsNone(document["blocks"][0]["protocol"])
            self.assertFalse(document["blocks"][0]["protocol_complete"])
            acceptance = document["production_streaming_acceptance"]
            self.assertTrue(acceptance["complete_provenance"])
            self.assertFalse(acceptance["complete_protocol"])
            self.assertFalse(acceptance["passed"])

    def test_invalid_pipeline_cache_delta_is_not_aggregated(self):
        class InvalidCacheTelemetryExecutor(FakeExecutor):
            def execute(self, request):
                result = super().execute(request)
                result.report["pipeline_cache_delta"]["pipeline_cache_hits"] = -1
                return result

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = self.make_config(root)
            report = root / "output" / "queue.json"
            document, exit_code = MODULE.run_queue(
                config,
                [0],
                123,
                report.parent,
                report,
                InvalidCacheTelemetryExecutor(),
                FakeAdapter(),
            )
            self.assertEqual(exit_code, 0)
            self.assertIsNone(document["blocks"][0]["pipeline_cache_delta"])
            self.assertFalse(document["summary"]["pipeline_cache_telemetry_complete"])
            self.assertIsNone(document["summary"]["pipeline_cache_delta"])

    def test_queue_rejects_inconsistent_verified_mhz(self):
        class InvalidMhzExecutor(FakeExecutor):
            def execute(self, request):
                result = super().execute(request)
                result.report["prove_mhz"] = 5.0
                return result

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = self.make_config(root)
            report = root / "output" / "queue.json"
            document, exit_code = MODULE.run_queue(
                config,
                [0],
                123,
                report.parent,
                report,
                InvalidMhzExecutor(),
                FakeAdapter(),
            )
            self.assertEqual(exit_code, 1)
            self.assertIn("invalid_prove_mhz", document["blocks"][0]["failure_reasons"])
            self.assertIsNone(document["summary"]["aggregate_prove_only_mhz"])

    def test_queue_rejects_unverified_timing_scope_and_input_digest(self):
        cases = (
            ("proving_speed_verified", False, "proving_speed_unverified"),
            ("prove_timing_scope", "wrong_scope", "invalid_prove_timing_scope"),
            ("input.sha256", "00" * 32, "adapted_input_sha256_mismatch"),
        )
        for field, value, expected_reason in cases:
            with self.subTest(field=field), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                config = self.make_config(root)

                class InvalidReportExecutor(FakeExecutor):
                    def execute(self, request):
                        result = super().execute(request)
                        if field == "input.sha256":
                            result.report["input"]["sha256"] = value
                        else:
                            result.report[field] = value
                        return result

                report = root / "output" / "queue.json"
                document, exit_code = MODULE.run_queue(
                    config,
                    [0],
                    123,
                    report.parent,
                    report,
                    InvalidReportExecutor(),
                    FakeAdapter(),
                )
                self.assertEqual(exit_code, 1)
                self.assertIn(expected_reason, document["blocks"][0]["failure_reasons"])

    def test_queue_refuses_nonempty_output_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = self.make_config(root)
            output = root / "output"
            output.mkdir()
            (output / "stale.proof").write_bytes(b"stale")
            with self.assertRaisesRegex(ValueError, "not empty"):
                MODULE.run_queue(
                    config,
                    [0],
                    123,
                    output,
                    output / "queue.json",
                    FakeExecutor(),
                    FakeAdapter(),
                )

    def test_queue_stops_and_withholds_mhz_on_unverified_proof(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = self.make_config(root)
            report = root / "output" / "queue.json"
            executor = FakeExecutor(fail_at=1)
            document, exit_code = MODULE.run_queue(
                config,
                [0, 1, 2],
                123,
                report.parent,
                report,
                executor,
                FakeAdapter(),
                clock=StepClock(),
            )
            self.assertEqual(exit_code, 1)
            self.assertEqual(executor.calls, 2)
            self.assertEqual(document["completed_blocks"], 2)
            self.assertFalse(document["summary"]["all_proofs_verified"])
            self.assertIsNone(document["summary"]["sustained_mhz"])
            self.assertIn("proof_unverified", document["blocks"][1]["failure_reasons"])

    def test_prefetch_overlaps_adaptation_but_executes_in_strict_order_and_depth(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = replace(self.make_config(root), adapter_prefetch_depth=2)
            adapter = TrackingPrefetchAdapter()
            executor = OrderedOverlapExecutor(adapter)
            report = root / "output" / "queue.json"
            document, exit_code = MODULE.run_queue(
                config,
                [3, 1, 3, 0],
                123,
                report.parent,
                report,
                executor,
                adapter,
                production=True,
            )
            self.assertEqual(exit_code, 0)
            self.assertEqual(executor.positions, [0, 1, 2, 3])
            self.assertEqual([call[1] for call in adapter.calls], [0, 1, 2, 3])
            self.assertEqual([call[2] for call in adapter.calls], [3, 1, 3, 0])
            self.assertEqual(document["summary"]["max_adapter_prefetch_pending"], 2)
            self.assertEqual(document["summary"]["adapter_prefetch_workers"], 1)
            self.assertEqual(document["summary"]["active_adapted_input_depth_bound"], 3)
            self.assertLessEqual(executor.max_staged_inputs, 3)
            self.assertEqual(document["summary"]["prefetched_blocks"], 3)
            self.assertGreater(document["summary"]["sum_adaptation_overlapped_wall_s"], 0)
            self.assertFalse(any(report.parent.glob(".adapt-prefetch-*")))
            self.assertTrue(all(not Path(block["adapted_input"]).exists() for block in document["blocks"]))

    def test_prefetch_cleanup_never_removes_manifest_cache_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = replace(self.make_config(root), adapter_prefetch_depth=1)
            cached_inputs = [pie.adapted_input for pie in config.pies]
            report = root / "output" / "queue.json"
            document, exit_code = MODULE.run_queue(
                config,
                [0, 1],
                123,
                report.parent,
                report,
                FakeExecutor(),
                FakeAdapter(),
            )
            self.assertEqual(exit_code, 0)
            self.assertTrue(all(path.is_file() for path in cached_inputs))
            self.assertTrue(all(block["adapted_cache_hit"] for block in document["blocks"]))
            self.assertFalse(any(report.parent.glob(".adapt-prefetch-*")))

    def test_prefetch_reports_feed_starvation_wait(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = replace(self.make_config(root), adapter_prefetch_depth=1)
            adapter = TrackingPrefetchAdapter(delay_s=0.05)
            report = root / "output" / "queue.json"
            document, exit_code = MODULE.run_queue(
                config,
                [0, 1],
                123,
                report.parent,
                report,
                FakeExecutor(),
                adapter,
                production=True,
            )
            self.assertEqual(exit_code, 0)
            self.assertTrue(document["blocks"][1]["feed_starved"])
            self.assertGreater(document["blocks"][1]["adaptation_wait_s"], 0.02)
            self.assertEqual(document["summary"]["feed_starved_blocks"], 1)

    def test_persistent_executor_streams_verified_blocks_through_one_session(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = self.make_config(root)
            config = replace(
                config,
                pies=tuple(
                    replace(
                        pie,
                        transcript_reference=None,
                        quotient_reference=None,
                    )
                    for pie in config.pies
                ),
            )
            daemon = self.write_session_daemon(root)
            executor = MODULE.PersistentSessionExecutor(
                config,
                (sys.executable, "-u", str(daemon)),
                startup_timeout_s=2.0,
            )
            report = root / "output" / "queue.json"
            document, exit_code = MODULE.run_queue(
                config,
                [0, 1, 0],
                123,
                report.parent,
                report,
                executor,
                FakeAdapter(),
                clock=StepClock(),
            )
            executor.close()

            self.assertEqual(exit_code, 0)
            self.assertEqual(document["executor"], "persistent_session")
            self.assertEqual(document["summary"]["persistent_session_count"], 1)
            self.assertTrue(document["summary"]["metal_runtime_reuse_verified"])
            self.assertTrue(document["summary"]["resident_arena_reuse_verified"])
            self.assertTrue(document["summary"]["preprocessed_state_reuse_verified"])
            self.assertAlmostEqual(document["summary"]["sum_session_block_wall_s"], 6.3)
            self.assertAlmostEqual(
                document["summary"]["persistent_session_service_mhz"],
                24.0 / 6.3,
            )
            self.assertEqual(document["session_shutdown_status"], "completed")
            self.assertEqual(
                {block["session_id"] for block in document["blocks"]},
                {"queue-test-session"},
            )
            self.assertTrue(all(block["metal_runtime_reused"] for block in document["blocks"]))
            self.assertFalse(document["blocks"][0]["resident_arena_reused"])
            self.assertFalse(document["blocks"][0]["preprocessed_state_reused"])
            self.assertTrue(all(block["resident_arena_reused"] for block in document["blocks"][1:]))
            self.assertTrue(all(block["preprocessed_state_reused"] for block in document["blocks"][1:]))
            self.assertTrue(all(Path(block["proof_output"]).is_file() for block in document["blocks"]))

    def test_persistent_prepared_state_cache_is_capacity_one_across_key_switches(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = self.make_config(root)
            config.pies[1].schedule.write_bytes(b"different-schedule")
            config = replace(
                config,
                pies=tuple(
                    replace(
                        pie,
                        transcript_reference=None,
                        quotient_reference=None,
                    )
                    for pie in config.pies
                ),
            )
            daemon = self.write_session_daemon(root)
            executor = MODULE.PersistentSessionExecutor(
                config,
                (sys.executable, "-u", str(daemon)),
                startup_timeout_s=2.0,
            )
            report = root / "output" / "queue.json"
            document, exit_code = MODULE.run_queue(
                config,
                [0, 0, 1, 1, 0],
                123,
                report.parent,
                report,
                executor,
                FakeAdapter(),
                clock=StepClock(),
            )
            executor.close()

            self.assertEqual(exit_code, 0)
            expected = [False, True, False, True, False]
            self.assertEqual(
                [block["resident_arena_reused"] for block in document["blocks"]],
                expected,
            )
            self.assertEqual(
                [block["preprocessed_state_reused"] for block in document["blocks"]],
                expected,
            )
            self.assertTrue(document["summary"]["resident_arena_reuse_verified"])
            self.assertTrue(document["summary"]["preprocessed_state_reuse_verified"])

    def test_reuse_summary_aggregates_cold_false_then_warm_true(self):
        rust_verifier = rust_verifier_evidence()
        rust_verifier["proof_digest"] = "ab" * 32
        blocks = [
            {
                "status": "verified",
                "queue_position": position,
                "pie_index": 0,
                "proof_sha256": "ab" * 32,
                "proof_bytes": 1,
                "metal_runtime_reused": True,
                "resident_arena_reused": reused,
                "preprocessed_state_reused": reused,
                "rust_verifier": rust_verifier.copy(),
            }
            for position, reused in enumerate((False, True))
        ]
        document = MODULE.queue_document(
            [0, 0],
            123,
            MODULE.PersistentSessionExecutor.name,
            "test-adapter",
            False,
            blocks,
            1.0,
            "completed",
            session_shutdown_status="completed",
        )

        self.assertTrue(document["summary"]["resident_arena_reuse_verified"])
        self.assertTrue(document["summary"]["preprocessed_state_reuse_verified"])

        blocks[1]["resident_arena_reused"] = False
        blocks[1]["preprocessed_state_reused"] = False
        cold_only = MODULE.queue_document(
            [0, 0],
            123,
            MODULE.PersistentSessionExecutor.name,
            "test-adapter",
            False,
            blocks,
            1.0,
            "completed",
            session_shutdown_status="completed",
        )
        self.assertFalse(cold_only["summary"]["resident_arena_reuse_verified"])
        self.assertFalse(cold_only["summary"]["preprocessed_state_reuse_verified"])

    def test_seeded_ten_and_hundred_block_production_streams_meet_queue_contract(self):
        for length in (10, 100):
            with self.subTest(length=length), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                config = replace(self.make_config(root), adapter_prefetch_depth=2)
                daemon = self.write_session_daemon(root)
                executor = MODULE.PersistentSessionExecutor(
                    config,
                    (sys.executable, "-u", str(daemon)),
                    startup_timeout_s=2.0,
                )
                report = root / "output" / "queue.json"
                indices = MODULE.seeded_queue(123, length)
                with mock.patch.object(MODULE.sys, "stderr", new=io.StringIO()):
                    document, exit_code = MODULE.run_queue(
                        config,
                        indices,
                        123,
                        report.parent,
                        report,
                        executor,
                        TrackingPrefetchAdapter(),
                        production=True,
                    )

                self.assertEqual(exit_code, 0)
                acceptance = document["production_streaming_acceptance"]
                self.assertTrue(acceptance["passed"])
                self.assertTrue(all(acceptance.values()))
                self.assertEqual(document["completed_blocks"], length)
                self.assertEqual(document["queue_indices"], indices)
                self.assertEqual(document["session_shutdown_status"], "completed")

    def test_persistent_executor_withholds_reuse_claim_on_false_result_flag(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = self.make_config(root)
            daemon = self.write_session_daemon(root, result_runtime_reuse=False)
            executor = MODULE.PersistentSessionExecutor(
                config,
                (sys.executable, "-u", str(daemon)),
                startup_timeout_s=2.0,
            )
            report = root / "output" / "queue.json"
            document, exit_code = MODULE.run_queue(
                config,
                [0, 1],
                123,
                report.parent,
                report,
                executor,
                FakeAdapter(),
                clock=StepClock(),
            )
            executor.close()

            self.assertEqual(exit_code, 1)
            self.assertEqual(document["completed_blocks"], 1)
            self.assertFalse(document["summary"]["metal_runtime_reuse_verified"])
            self.assertIsNone(document["summary"]["sustained_mhz"])
            self.assertIn("executor_failed", document["blocks"][0]["failure_reasons"])

    def test_session_close_failure_withholds_queue_throughput(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = self.make_config(root)
            daemon = self.write_session_daemon(root)
            executor = MODULE.PersistentSessionExecutor(
                config,
                (sys.executable, "-u", str(daemon)),
                startup_timeout_s=2.0,
            )
            report = root / "output" / "queue.json"

            def close_then_fail():
                executor.client.close()
                raise MODULE.SESSION_PROTOCOL.SessionProtocolError("invalid close acknowledgement")

            with mock.patch.object(executor, "close", side_effect=close_then_fail):
                document, exit_code = MODULE.run_queue(
                    config,
                    [0],
                    123,
                    report.parent,
                    report,
                    executor,
                    FakeAdapter(),
                )

            self.assertEqual(exit_code, 1)
            self.assertEqual(document["status"], "failed")
            self.assertEqual(document["session_shutdown_status"], "failed")
            self.assertTrue(document["summary"]["all_proofs_verified"])
            self.assertIsNone(document["summary"]["sustained_end_to_end_mhz"])
            self.assertFalse(document["production_streaming_acceptance"]["passed"])

    def test_failed_proof_cancels_prefetch_and_cleans_staging(self):
        class CancellableAdapter(TrackingPrefetchAdapter):
            def __init__(self):
                super().__init__()
                self.cancelled = threading.Event()

            def prepare_prefetch(self, pie, destination, production, cancel_event):
                position = self.position(destination)
                self.calls.append(("prefetch", position, pie.index))
                destination.write_bytes(b"STWZCPI\0partial")
                self.started[position].set()
                if not cancel_event.wait(timeout=2.0):
                    raise AssertionError("prefetch cancellation was not propagated")
                self.cancelled.set()
                return MODULE.AdaptationResult(
                    "cancelled", None, 0.0, False, failure_reason="adapter_cancelled"
                )

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = replace(self.make_config(root), adapter_prefetch_depth=2)
            adapter = CancellableAdapter()
            executor = OrderedOverlapExecutor(adapter, fail_at=0)
            report = root / "output" / "queue.json"
            document, exit_code = MODULE.run_queue(
                config,
                [0, 1, 2],
                123,
                report.parent,
                report,
                executor,
                adapter,
                production=True,
            )
            self.assertEqual(exit_code, 1)
            self.assertEqual(executor.positions, [0])
            self.assertTrue(adapter.cancelled.is_set())
            self.assertEqual(document["completed_blocks"], 1)
            self.assertIsNone(document["summary"]["sustained_mhz"])
            self.assertFalse(any(report.parent.glob(".adapt-prefetch-*")))


if __name__ == "__main__":
    unittest.main()
