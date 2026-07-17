from __future__ import annotations

import argparse
import contextlib
import copy
import hashlib
import importlib.util
import io
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "native_proof_matrix.py"
SPEC = importlib.util.spec_from_file_location("native_proof_matrix", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


PROOF_WIRE_BYTES = json.dumps(
    {
        "config": {},
        "commitments": [],
        "sampled_values": [],
        "decommitments": [],
        "queried_values": [],
        "proof_of_work": 0,
        "fri_proof": {},
    },
    separators=(",", ":"),
).encode()
PROOF_WIRE_SHA256 = hashlib.sha256(PROOF_WIRE_BYTES).hexdigest()
INTEROP_UPSTREAM_COMMIT = "a8fcf4bdde3778ae72f1e6cfe61a38e2911648d2"
INTEROP_EXCHANGE_MODE = "proof_exchange_json_wire_v1"


def write_proof_artifact(
    path: Path,
    workload: MODULE.Workload,
    proof_bytes: bytes = PROOF_WIRE_BYTES,
    *,
    upstream_commit: str = INTEROP_UPSTREAM_COMMIT,
) -> None:
    document = {
        "schema_version": 1,
        "upstream_commit": upstream_commit,
        "exchange_mode": INTEROP_EXCHANGE_MODE,
        "generator": "zig",
        "example": "wide_fibonacci",
        "prove_mode": "prove",
        "pcs_config": {
            "pow_bits": 10,
            "fri_config": {
                "log_blowup_factor": 1,
                "log_last_layer_degree_bound": 0,
                "n_queries": 3,
                "fold_step": 1,
            },
            "lifting_log_size": None,
        },
        "blake_statement": None,
        "plonk_statement": None,
        "poseidon_statement": None,
        "state_machine_statement": None,
        "wide_fibonacci_statement": {
            "log_n_rows": workload.log_rows,
            "sequence_len": workload.sequence_len,
        },
        "xor_statement": None,
        "proof_bytes_hex": proof_bytes.hex(),
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(document) + "\n")


def pipeline_cache() -> dict[str, int | float]:
    return {
        **{key: 0 for key in MODULE.PIPELINE_CACHE_COUNTER_KEYS},
        MODULE.PIPELINE_CACHE_SECONDS_KEY: 0.0,
    }


def backend_counters(dispatches: int = 4, fallbacks: int = 1) -> dict[str, int]:
    counters = {key: 0 for key in MODULE.BACKEND_COUNTER_KEYS}
    counters["metal_circle_lde_dispatches"] = dispatches
    counters["host_merkle_commits"] = fallbacks
    return counters


def telemetry_delta(dispatches: int = 4, fallbacks: int = 1) -> dict[str, object]:
    return {
        "classification": "accelerated_with_fallbacks",
        "metal_dispatches": dispatches,
        "cpu_fallbacks": fallbacks,
        "counters": backend_counters(dispatches, fallbacks),
        "pipeline_cache": pipeline_cache(),
    }


def make_report(
    lane: str,
    workload: MODULE.Workload,
    *,
    samples: int = 2,
    warmups: int = 1,
    digest: str = "a" * 64,
    dirty: bool = False,
    telemetry_valid: bool = True,
    artifact_path: Path | None = None,
    proof_bytes: int = 128,
) -> dict[str, object]:
    prove_seconds = 2.0 if lane == "cpu" else 1.0
    request_seconds = 2.5 if lane == "cpu" else 1.25
    row_mhz = workload.rows / prove_seconds / 1_000_000
    committed_rate = workload.committed_trace_cells / prove_seconds / 1_000_000
    sample_rows = [
        {
            "input_seconds": 0.1,
            "prove_seconds": prove_seconds,
            "proof_encode_seconds": 0.01,
            "verify_seconds": 0.02,
            "request_seconds": request_seconds,
            "row_mhz": row_mhz,
            "committed_mcells_per_second": committed_rate,
        }
        for _ in range(samples)
    ]
    summary = {
        "median": prove_seconds,
        "min": prove_seconds,
        "max": prove_seconds,
        "mad": 0.0,
    }
    requirements = {
        "verified_unprofiled": True,
        "sampling_contract": True,
        "functional_protocol": True,
        "release_fast": True,
        "clean_complete_provenance": not dirty,
        "thread_parallelism_enabled": True,
        "byte_identical_verified_samples": True,
        "backend_telemetry_valid": telemetry_valid,
    }
    telemetry = None
    if lane == "metal":
        warmup_records = [telemetry_delta() for _ in range(warmups)]
        sample_records = [telemetry_delta() for _ in range(samples)]
        telemetry = {
            "scope": "verified_proof_request",
            "post_warmup_pipeline_cache": pipeline_cache(),
            "warmups": warmup_records,
            "samples": sample_records,
            "total_metal_dispatches": 4 * (warmups + samples),
            "total_cpu_fallbacks": warmups + samples,
            "valid": telemetry_valid,
        }
    proof = {
        "samples": [
            {"bytes": proof_bytes, "sha256": digest} for _ in range(samples)
        ],
        "verified_samples": samples,
        "all_samples_byte_identical": True,
    }
    if artifact_path is not None:
        proof["artifact"] = {
            "path": str(artifact_path),
            "sample_index": 0,
            "bytes": proof_bytes,
            "sha256": digest,
            "artifact_schema_version": 1,
            "upstream_commit": INTEROP_UPSTREAM_COMMIT,
            "exchange_mode": INTEROP_EXCHANGE_MODE,
        }
    return {
        "schema_version": 2,
        "backend": "cpu_native" if lane == "cpu" else "metal_hybrid",
        "evidence_class": "verified_unprofiled",
        "profiled": False,
        "provenance": {
            "git_commit": "1" * 40,
            "git_dirty": dirty,
            "zig_version": "0.15.2",
            "optimization": "ReleaseFast",
            "target_os": "macos",
            "target_arch": "aarch64",
            "cpu_count": 12,
            "simd_pack_width": 4,
            "single_threaded": False,
            "thread_parallelism_enabled": True,
            "environment_overrides": [],
            "complete": True,
        },
        "protocol": {
            "name": "functional",
            "pow_bits": 10,
            "log_blowup_factor": 1,
            "log_last_layer_degree_bound": 0,
            "n_queries": 3,
            "fold_step": 1,
        },
        "workload": {
            "name": "wide_fibonacci",
            "descriptor_sha256": MODULE.workload_descriptor_sha256(
                workload,
                "functional",
            ),
            **workload.as_dict(),
        },
        "session": {
            "max_circle_log": workload.log_rows + 1,
            "host_byte_budget": 1 << 30,
            "retained_host_twiddle_bytes": 1 << 20,
            "tower_build_count": 1,
        },
        "proof": proof,
        "backend_telemetry": telemetry,
        "timing": {
            "backend_init_seconds": 0.1,
            "warmup_request_seconds": [request_seconds] * warmups,
            "samples": sample_rows,
            "input_seconds": {**summary, "median": 0.1, "min": 0.1, "max": 0.1},
            "prove_seconds": summary,
            "proof_encode_seconds": {**summary, "median": 0.01, "min": 0.01, "max": 0.01},
            "verify_seconds": {**summary, "median": 0.02, "min": 0.02, "max": 0.02},
            "request_seconds": {
                **summary,
                "median": request_seconds,
                "min": request_seconds,
                "max": request_seconds,
            },
        },
        "throughput": {
            "native_unit": "trace_rows",
            "headline_eligible": not dirty and telemetry_valid,
            "headline_row_mhz": {
                "median": row_mhz,
                "min": row_mhz,
                "max": row_mhz,
                "mad": 0.0,
            },
            "diagnostic_row_mhz": None,
            "headline_committed_mcells_per_second": {
                "median": committed_rate,
                "min": committed_rate,
                "max": committed_rate,
                "mad": 0.0,
            },
            "diagnostic_committed_mcells_per_second": None,
            "headline_requirements": requirements,
        },
    }


def make_args(
    output_dir: Path,
    cpu_bin: Path,
    metal_bin: Path,
    workloads: list[MODULE.Workload],
) -> argparse.Namespace:
    return argparse.Namespace(
        workloads=workloads,
        warmups=1,
        samples=2,
        protocol="functional",
        cooldown_seconds=0.25,
        timeout_seconds=30.0,
        output_dir=output_dir,
        cpu_bin=cpu_bin,
        metal_bin=metal_bin,
    )


class NativeProofMatrixTests(unittest.TestCase):
    def test_defaults_are_small_and_bounded(self):
        args = MODULE.parse_args([])
        self.assertEqual(
            args.workloads,
            [MODULE.Workload(10, 8), MODULE.Workload(12, 16)],
        )
        self.assertEqual(args.samples, 5)
        self.assertTrue(
            all(
                workload.committed_trace_cells <= MODULE.MAX_COMMITTED_TRACE_CELLS
                for workload in args.workloads
            )
        )
        with self.assertRaises(ValueError):
            args.output_dir.resolve().relative_to(MODULE.ROOT.resolve())

    def test_explicit_log_width_product_is_bounded(self):
        args = MODULE.parse_args(
            [
                "--log-rows",
                "9",
                "10",
                "--sequence-lens",
                "4",
                "8",
                "--warmups",
                "0",
                "--samples",
                "1",
            ]
        )
        self.assertEqual(
            args.workloads,
            [
                MODULE.Workload(9, 4),
                MODULE.Workload(9, 8),
                MODULE.Workload(10, 4),
                MODULE.Workload(10, 8),
            ],
        )

    def test_rejects_oversized_workload(self):
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                MODULE.parse_args(["--workload", "22:512"])

    def test_atomic_write_replaces_complete_artifact(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "artifact.json"
            path.write_bytes(b"old")
            MODULE.atomic_write_bytes(path, b"new document\n")
            self.assertEqual(path.read_bytes(), b"new document\n")
            self.assertEqual(list(path.parent.glob(f".{path.name}.*")), [])

    def test_matrix_alternates_lanes_and_emits_speedups(self):
        workloads = [MODULE.Workload(8, 4), MODULE.Workload(9, 8)]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            cpu_bin = root / "native-proof-bench-cpu"
            metal_bin = root / "native-proof-bench-metal"
            for binary in (cpu_bin, metal_bin):
                binary.write_bytes(b"fixture")
                binary.chmod(0o755)
            args = make_args(root / "out", cpu_bin, metal_bin, workloads)
            calls: list[str] = []

            def execute(command, **unused):
                lane = "metal" if "metal" in Path(command[0]).name else "cpu"
                calls.append(lane)
                log_rows = int(command[command.index("--log-rows") + 1])
                sequence_len = int(command[command.index("--sequence-len") + 1])
                artifact_path = Path(
                    command[command.index("--proof-artifact-out") + 1]
                )
                workload = MODULE.Workload(log_rows, sequence_len)
                write_proof_artifact(artifact_path, workload)
                report = make_report(
                    lane,
                    workload,
                    digest=PROOF_WIRE_SHA256,
                    artifact_path=artifact_path,
                    proof_bytes=len(PROOF_WIRE_BYTES),
                )
                return subprocess.CompletedProcess(
                    command,
                    0,
                    stdout=json.dumps(report).encode(),
                    stderr=f"{lane} diagnostic\n".encode(),
                )

            with (
                mock.patch.object(MODULE.subprocess, "run", side_effect=execute),
                mock.patch.object(MODULE.time, "sleep") as sleep,
            ):
                document = MODULE.run_matrix(args)

            self.assertEqual(calls, ["cpu", "metal", "metal", "cpu"])
            self.assertEqual(sleep.call_count, 3)
            self.assertTrue(document["summary"]["all_rows_headline_eligible"])
            self.assertEqual(document["rows"][0]["lane_order"], ["cpu", "metal"])
            self.assertEqual(document["rows"][1]["lane_order"], ["metal", "cpu"])
            self.assertEqual(
                document["rows"][0]["lanes"]["cpu"]["display_name"],
                "Zig CPU/SIMD",
            )
            self.assertEqual(
                document["rows"][0]["lanes"]["cpu"]["session"],
                make_report("cpu", workloads[0])["session"],
            )
            self.assertAlmostEqual(
                document["rows"][0]["speedup"]["metal_prove_time_speedup"],
                2.0,
            )
            self.assertAlmostEqual(
                document["rows"][0]["speedup"]["metal_request_time_speedup"],
                2.0,
            )
            self.assertEqual(
                document["rows"][0]["lanes"]["cpu"]["metrics"]["prove_seconds"]["mad"],
                0.0,
            )
            for field in (
                "backend_init_seconds",
                "input_seconds",
                "proof_encode_seconds",
                "verify_seconds",
                "request_row_mhz",
            ):
                self.assertIn(field, document["rows"][0]["lanes"]["cpu"]["metrics"])
            self.assertEqual(
                len(document["rows"][0]["lanes"]["cpu"]["stdout_sha256"]),
                64,
            )
            artifact_summary = document["rows"][0]["lanes"]["cpu"]["proof_artifact"]
            self.assertEqual(artifact_summary["proof_sha256"], PROOF_WIRE_SHA256)
            self.assertEqual(artifact_summary["proof_bytes"], len(PROOF_WIRE_BYTES))
            self.assertEqual(len(artifact_summary["sha256"]), 64)
            self.assertEqual(
                document["correctness_scope"]["classification"],
                "zig_cross_backend_parity",
            )
            self.assertFalse(
                document["correctness_scope"]["pinned_rust_stwo_oracle_checked"]
            )
            summary = json.loads((args.output_dir / "summary.json").read_text())
            self.assertEqual(summary["protocol"], MODULE.SUMMARY_PROTOCOL)
            self.assertEqual(
                (args.output_dir / document["rows"][0]["lanes"]["metal"]["stderr_artifact"]).read_text(),
                "metal diagnostic\n",
            )

    def test_cross_backend_digest_mismatch_is_fatal(self):
        workload = MODULE.Workload(8, 4)
        args = argparse.Namespace(samples=2, warmups=1, protocol="functional")
        cpu = make_report("cpu", workload)
        metal = make_report("metal", workload, digest="c" * 64)
        cpu_fingerprint, _ = MODULE.validate_report(cpu, "cpu", workload, args)
        metal_fingerprint, _ = MODULE.validate_report(metal, "metal", workload, args)
        with self.assertRaisesRegex(MODULE.MatrixError, "canonical proof digests differ"):
            MODULE.validate_pair(cpu, metal, cpu_fingerprint, metal_fingerprint)

    def test_wrong_protocol_parameter_is_fatal(self):
        workload = MODULE.Workload(8, 4)
        args = argparse.Namespace(samples=2, warmups=1, protocol="functional")
        report = make_report("metal", workload)
        report["protocol"] = copy.deepcopy(report["protocol"])
        report["protocol"]["n_queries"] = 99
        with self.assertRaisesRegex(MODULE.MatrixError, "protocol descriptor"):
            MODULE.validate_report(report, "metal", workload, args)

    def test_wrong_workload_descriptor_digest_is_fatal(self):
        workload = MODULE.Workload(8, 4)
        args = argparse.Namespace(samples=2, warmups=1, protocol="functional")
        report = make_report("cpu", workload)
        report["workload"]["descriptor_sha256"] = "f" * 64
        with self.assertRaisesRegex(MODULE.MatrixError, "descriptor digest"):
            MODULE.validate_report(report, "cpu", workload, args)

    def test_session_schema_is_exact(self):
        workload = MODULE.Workload(8, 4)
        args = argparse.Namespace(samples=2, warmups=1, protocol="functional")
        for mutation in ("missing", "extra"):
            with self.subTest(mutation=mutation):
                report = make_report("cpu", workload)
                if mutation == "missing":
                    del report["session"]["tower_build_count"]
                else:
                    report["session"]["device_twiddle_bytes"] = 1
                with self.assertRaisesRegex(MODULE.MatrixError, "wrong schema"):
                    MODULE.validate_report(report, "cpu", workload, args)

    def test_session_builds_one_tower_with_bounded_retained_bytes(self):
        workload = MODULE.Workload(8, 4)
        args = argparse.Namespace(samples=2, warmups=1, protocol="functional")
        mutations = {
            "zero builds": ("tower_build_count", 0, "must equal 1"),
            "multiple builds": ("tower_build_count", 2, "must equal 1"),
            "no retained bytes": (
                "retained_host_twiddle_bytes",
                0,
                "must be positive",
            ),
            "over budget": (
                "retained_host_twiddle_bytes",
                (1 << 30) + 1,
                "exceeds host_byte_budget",
            ),
        }
        for name, (field, value, message) in mutations.items():
            with self.subTest(name=name):
                report = make_report("metal", workload)
                report["session"][field] = value
                with self.assertRaisesRegex(MODULE.MatrixError, message):
                    MODULE.validate_report(report, "metal", workload, args)

    def test_session_fields_are_integer_counters(self):
        workload = MODULE.Workload(8, 4)
        args = argparse.Namespace(samples=2, warmups=1, protocol="functional")
        for field, value in (
            ("max_circle_log", True),
            ("host_byte_budget", 1.5),
            ("retained_host_twiddle_bytes", -1),
        ):
            with self.subTest(field=field):
                report = make_report("cpu", workload)
                report["session"][field] = value
                with self.assertRaisesRegex(MODULE.MatrixError, "nonnegative integer"):
                    MODULE.validate_report(report, "cpu", workload, args)

    def test_session_max_circle_log_covers_protocol_blowup(self):
        workload = MODULE.Workload(8, 4)
        args = argparse.Namespace(samples=2, warmups=1, protocol="functional")
        report = make_report("cpu", workload)
        report["session"]["max_circle_log"] = workload.log_rows
        with self.assertRaisesRegex(MODULE.MatrixError, "does not cover"):
            MODULE.validate_report(report, "cpu", workload, args)

    def test_missing_headline_requirement_key_is_fatal(self):
        workload = MODULE.Workload(8, 4)
        args = argparse.Namespace(samples=2, warmups=1, protocol="functional")
        report = make_report("cpu", workload)
        del report["throughput"]["headline_requirements"]["functional_protocol"]
        with self.assertRaisesRegex(MODULE.MatrixError, "wrong schema"):
            MODULE.validate_report(report, "cpu", workload, args)

    def test_zero_dispatch_warmup_is_fatal(self):
        workload = MODULE.Workload(8, 4)
        args = argparse.Namespace(samples=2, warmups=1, protocol="functional")
        report = make_report("metal", workload)
        report["backend_telemetry"]["warmups"][0]["metal_dispatches"] = 0
        report["backend_telemetry"]["warmups"][0]["counters"] = backend_counters(0, 1)
        report["backend_telemetry"]["warmups"][0]["classification"] = "host_only"
        report["backend_telemetry"]["total_metal_dispatches"] -= 4
        with self.assertRaisesRegex(MODULE.MatrixError, r"warmups\[0\].*no Metal work"):
            MODULE.validate_report(report, "metal", workload, args)

    def test_inconsistent_rate_is_fatal(self):
        workload = MODULE.Workload(8, 4)
        args = argparse.Namespace(samples=2, warmups=1, protocol="functional")
        report = make_report("cpu", workload)
        report["timing"]["samples"][0]["row_mhz"] *= 1.01
        with self.assertRaisesRegex(MODULE.MatrixError, "row_mhz is inconsistent"):
            MODULE.validate_report(report, "cpu", workload, args)

    def test_dirty_provenance_blocks_headline_without_weakening_parity(self):
        workload = MODULE.Workload(8, 4)
        args = argparse.Namespace(samples=2, warmups=1, protocol="functional")
        report = make_report("cpu", workload, dirty=True)
        fingerprint, blockers = MODULE.validate_report(report, "cpu", workload, args)
        self.assertEqual(fingerprint, ("a" * 64, 128))
        self.assertIn("cpu_git_dirty", blockers)
        self.assertIn("cpu_report_not_headline_eligible", blockers)

    def test_metal_telemetry_must_cover_every_sample(self):
        workload = MODULE.Workload(8, 4)
        args = argparse.Namespace(samples=2, warmups=1, protocol="functional")
        report = make_report("metal", workload)
        report["backend_telemetry"]["samples"].pop()
        with self.assertRaisesRegex(MODULE.MatrixError, "every benchmark request"):
            MODULE.validate_report(report, "metal", workload, args)

    def test_invalid_metal_telemetry_blocks_headline(self):
        workload = MODULE.Workload(8, 4)
        args = argparse.Namespace(samples=2, warmups=1, protocol="functional")
        report = make_report("metal", workload, telemetry_valid=False)
        fingerprint, blockers = MODULE.validate_report(report, "metal", workload, args)
        self.assertEqual(fingerprint, ("a" * 64, 128))
        self.assertIn("metal_telemetry_invalid", blockers)
        self.assertIn("metal_report_not_headline_eligible", blockers)

    def test_nonzero_exit_preserves_both_streams_atomically(self):
        workload = MODULE.Workload(8, 4)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = root / "native-proof-bench-cpu"
            binary.write_bytes(b"fixture")
            binary.chmod(0o755)
            args = make_args(root / "out", binary, binary, [workload])
            artifact_dir = root / "out/row"
            completed = subprocess.CompletedProcess(
                [str(binary)],
                7,
                stdout=b"partial stdout",
                stderr=b"fatal stderr",
            )
            with mock.patch.object(MODULE.subprocess, "run", return_value=completed):
                with self.assertRaisesRegex(MODULE.MatrixError, "exited 7"):
                    MODULE.run_lane("cpu", binary, workload, args, artifact_dir)
            self.assertEqual((artifact_dir / "cpu.stdout.json").read_bytes(), b"partial stdout")
            self.assertEqual((artifact_dir / "cpu.stderr.txt").read_bytes(), b"fatal stderr")

    def test_success_without_requested_proof_artifact_is_fatal(self):
        workload = MODULE.Workload(8, 4)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = root / "native-proof-bench-cpu"
            binary.write_bytes(b"fixture")
            binary.chmod(0o755)
            args = make_args(root / "out", binary, binary, [workload])
            completed = subprocess.CompletedProcess(
                [str(binary)],
                0,
                stdout=json.dumps(make_report("cpu", workload)).encode(),
                stderr=b"",
            )
            with mock.patch.object(MODULE.subprocess, "run", return_value=completed):
                with self.assertRaisesRegex(MODULE.MatrixError, "was not produced"):
                    MODULE.run_lane("cpu", binary, workload, args, root / "out/row")

    def test_mutated_report_artifact_binding_is_fatal(self):
        workload = MODULE.Workload(8, 4)
        args = argparse.Namespace(samples=2, warmups=1, protocol="functional")
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "proof.json"
            write_proof_artifact(path, workload)
            artifact = MODULE.load_proof_artifact(path, "cpu")
            report = make_report(
                "cpu",
                workload,
                digest=PROOF_WIRE_SHA256,
                artifact_path=path,
                proof_bytes=len(PROOF_WIRE_BYTES),
            )
            fingerprint, _ = MODULE.validate_report(report, "cpu", workload, args)
            report["proof"]["artifact"]["sample_index"] = 1
            with self.assertRaisesRegex(MODULE.MatrixError, "binding does not match"):
                MODULE.validate_proof_artifact(
                    report, "cpu", workload, args, artifact, fingerprint
                )

    def test_mutated_artifact_proof_and_pinned_metadata_are_fatal(self):
        workload = MODULE.Workload(8, 4)
        args = argparse.Namespace(samples=2, warmups=1, protocol="functional")
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "proof.json"
            report = make_report(
                "cpu",
                workload,
                digest=PROOF_WIRE_SHA256,
                artifact_path=path,
                proof_bytes=len(PROOF_WIRE_BYTES),
            )
            fingerprint, _ = MODULE.validate_report(report, "cpu", workload, args)

            write_proof_artifact(path, workload, PROOF_WIRE_BYTES + b" ")
            artifact = MODULE.load_proof_artifact(path, "cpu")
            with self.assertRaisesRegex(MODULE.MatrixError, r"(byte length|digest) disagrees"):
                MODULE.validate_proof_artifact(
                    report, "cpu", workload, args, artifact, fingerprint
                )

            write_proof_artifact(path, workload, upstream_commit="0" * 40)
            artifact = MODULE.load_proof_artifact(path, "cpu")
            with self.assertRaisesRegex(MODULE.MatrixError, "invalid upstream_commit"):
                MODULE.validate_proof_artifact(
                    report, "cpu", workload, args, artifact, fingerprint
                )

    def test_oversized_stdout_still_publishes_stderr(self):
        workload = MODULE.Workload(8, 4)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = root / "native-proof-bench-cpu"
            binary.write_bytes(b"fixture")
            binary.chmod(0o755)
            args = make_args(root / "out", binary, binary, [workload])
            artifact_dir = root / "out/row"
            completed = subprocess.CompletedProcess(
                [str(binary)],
                0,
                stdout=b"oversized stdout",
                stderr=b"preserved stderr",
            )
            with (
                mock.patch.object(MODULE.subprocess, "run", return_value=completed),
                mock.patch.dict(MODULE.run_lane.__globals__, {"MAX_STDOUT_BYTES": 4}),
            ):
                with self.assertRaisesRegex(MODULE.MatrixError, "stream limit exceeded"):
                    MODULE.run_lane("cpu", binary, workload, args, artifact_dir)
            self.assertEqual(
                (artifact_dir / "cpu.stdout.json").read_bytes(),
                b"oversized stdout",
            )
            self.assertEqual(
                (artifact_dir / "cpu.stderr.txt").read_bytes(),
                b"preserved stderr",
            )

    def test_formal_mode_returns_nonzero_for_non_headline_matrix(self):
        args = argparse.Namespace(allow_non_headline=False)
        document = {"summary": {"all_rows_headline_eligible": False}}
        with (
            mock.patch.object(MODULE, "parse_args", return_value=args),
            mock.patch.object(MODULE, "run_matrix", return_value=document),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            self.assertEqual(MODULE.main([]), 2)
        args.allow_non_headline = True
        with (
            mock.patch.object(MODULE, "parse_args", return_value=args),
            mock.patch.object(MODULE, "run_matrix", return_value=document),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            self.assertEqual(MODULE.main([]), 0)

    def test_profiler_environment_is_rejected(self):
        with self.assertRaisesRegex(MODULE.MatrixError, "profiler environment"):
            MODULE.require_unprofiled_environment(
                {"STWO_ZIG_METAL_PROFILE_OUT": "/tmp/profile.ndjson"}
            )

    def test_output_directory_lock_is_exclusive(self):
        with tempfile.TemporaryDirectory() as temporary:
            output_dir = Path(temporary) / "matrix"
            with MODULE.output_dir_lock(output_dir):
                with self.assertRaisesRegex(MODULE.MatrixError, "is locked"):
                    with MODULE.output_dir_lock(output_dir):
                        self.fail("second lock unexpectedly succeeded")


if __name__ == "__main__":
    unittest.main()
