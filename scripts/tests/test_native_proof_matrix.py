from __future__ import annotations

import argparse
import contextlib
import copy
import hashlib
import importlib.util
import json
import io
import statistics
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "native_proof_matrix.py"
SPEC = importlib.util.spec_from_file_location("native_proof_matrix", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)

from native_proof_matrix_lib.contract import pipeline_preparation_occurred
from native_proof_matrix_lib.model import RUST_ORACLE_SHA256

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
UPSTREAM_COMMIT = "a8fcf4bdde3778ae72f1e6cfe61a38e2911648d2"
EXCHANGE_MODE = "proof_exchange_json_wire_v1"
FUNCTIONAL_PROTOCOL = {
    "name": "functional",
    "pow_bits": 10,
    "log_blowup_factor": 1,
    "log_last_layer_degree_bound": 0,
    "n_queries": 3,
    "fold_step": 1,
}


def summary(value: float) -> dict[str, float]:
    return {"median": value, "min": value, "max": value, "mad": 0.0}


def values_summary(values: list[float]) -> dict[str, float]:
    median = statistics.median(values)
    return {
        "median": median,
        "min": min(values),
        "max": max(values),
        "mad": statistics.median(abs(value - median) for value in values),
    }


def set_prove_times(
    report: dict[str, object], workload: MODULE.Workload, values: list[float]
) -> None:
    samples = report["timing"]["samples"]
    for sample, prove_seconds in zip(samples, values, strict=True):
        sample["prove_seconds"] = prove_seconds
        sample["native_mhz"] = workload.native_units / prove_seconds / 1_000_000
        sample["trace_row_mhz"] = workload.trace_rows / prove_seconds / 1_000_000
        sample["committed_mcells_per_second"] = (
            workload.committed_trace_cells / prove_seconds / 1_000_000
        )
    report["timing"]["prove_seconds"] = values_summary(values)
    for summary_field, sample_field in (
        ("headline_native_mhz", "native_mhz"),
        ("headline_trace_row_mhz", "trace_row_mhz"),
        ("headline_committed_mcells_per_second", "committed_mcells_per_second"),
    ):
        report["throughput"][summary_field] = values_summary(
            [sample[sample_field] for sample in samples]
        )


def pipeline_cache() -> dict[str, int | float]:
    return {
        **{key: 0 for key in MODULE.PIPELINE_CACHE_COUNTER_KEYS},
        MODULE.PIPELINE_CACHE_SECONDS_KEY: 0.0,
        MODULE.LIBRARY_PREPARATION_SECONDS_KEY: 0.0,
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


def write_proof_artifact(
    path: Path,
    workload: MODULE.Workload,
    proof_bytes: bytes = PROOF_WIRE_BYTES,
) -> None:
    statements = {
        "blake_statement": None,
        "plonk_statement": None,
        "poseidon_statement": None,
        "state_machine_statement": None,
        "wide_fibonacci_statement": None,
        "xor_statement": None,
    }
    if workload.name == "state_machine":
        parameters = workload.parameters
        log_n_rows = parameters["log_n_rows"]
        initial = [parameters["initial_x"], parameters["initial_y"]]
        statements["state_machine_statement"] = {
            "public_input": [
                initial,
                [initial[0] + (1 << log_n_rows), initial[1] + (1 << (log_n_rows - 1))],
            ],
            "stmt0": {"n": log_n_rows, "m": log_n_rows - 1},
            "stmt1": {
                "x_axis_claimed_sum": [1, 2, 3, 4],
                "y_axis_claimed_sum": [5, 6, 7, 8],
            },
        }
    else:
        statements[f"{workload.name}_statement"] = workload.parameters
    document = {
        "schema_version": 1,
        "upstream_commit": UPSTREAM_COMMIT,
        "exchange_mode": EXCHANGE_MODE,
        "generator": "zig",
        "example": workload.name,
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
        **statements,
        "proof_bytes_hex": proof_bytes.hex(),
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(document) + "\n")


def make_report(
    lane: str,
    workload: MODULE.Workload,
    *,
    samples: int = 5,
    warmups: int = 10,
    digest: str = PROOF_WIRE_SHA256,
    proof_bytes: int = len(PROOF_WIRE_BYTES),
    artifact_path: Path | None = None,
    dirty: bool = False,
    cold_pipeline: bool = False,
) -> dict[str, object]:
    prove = 2.0 if lane == "cpu" else 1.0
    request = 2.5 if lane == "cpu" else 1.25
    rates = {
        "native_mhz": workload.native_units / prove / 1_000_000,
        "request_native_mhz": workload.native_units / request / 1_000_000,
        "trace_row_mhz": workload.trace_rows / prove / 1_000_000,
        "request_trace_row_mhz": workload.trace_rows / request / 1_000_000,
        "committed_mcells_per_second": (
            workload.committed_trace_cells / prove / 1_000_000
        ),
    }
    sample = {
        "input_seconds": 0.1,
        "prove_seconds": prove,
        "proof_encode_seconds": 0.01,
        "verify_seconds": 0.02,
        "request_seconds": request,
        **rates,
    }
    minimum_samples = 5 if prove < 1.0 else 3
    sampling_contract = warmups >= MODULE.MIN_HEADLINE_WARMUPS and samples >= minimum_samples
    evidence_class = "verified_unprofiled" if sampling_contract else "correctness_only"
    requirements = {
        "verified_unprofiled": sampling_contract,
        "sampling_contract": sampling_contract,
        "functional_protocol": True,
        "release_fast": True,
        "clean_complete_provenance": not dirty,
        "thread_parallelism_enabled": True,
        "byte_identical_verified_samples": True,
        "backend_telemetry_valid": not cold_pipeline,
    }
    telemetry = None
    if lane == "metal":
        telemetry = {
            "scope": "verified_proof_request",
            "post_warmup_pipeline_cache": pipeline_cache(),
            "warmups": [telemetry_delta() for _ in range(warmups)],
            "samples": [telemetry_delta() for _ in range(samples)],
            "total_metal_dispatches": 4 * (warmups + samples),
            "total_cpu_fallbacks": warmups + samples,
            "valid": True,
        }
        if cold_pipeline:
            telemetry["samples"][0]["pipeline_cache"]["direct_compiles"] = 1
            telemetry["samples"][0]["pipeline_cache"][
                "pipeline_preparation_seconds"
            ] = 0.01
            telemetry["valid"] = False
    binding = None
    if artifact_path is not None:
        binding = {
            "path": str(artifact_path),
            "sample_index": 0,
            "bytes": proof_bytes,
            "sha256": digest,
            "artifact_schema_version": 1,
            "upstream_commit": UPSTREAM_COMMIT,
            "exchange_mode": EXCHANGE_MODE,
        }
    return {
        "schema_version": 3,
        "backend": "cpu_native" if lane == "cpu" else "metal_hybrid",
        "evidence_class": evidence_class,
        "profiled": False,
        "provenance": {
            "git_commit": "1" * 40,
            "git_dirty": dirty,
            "zig_version": "0.15.2",
            "optimization": "ReleaseFast",
            "target_os": "macos",
            "target_arch": "aarch64",
            "cpu_count": 8,
            "simd_pack_width": 4,
            "single_threaded": False,
            "thread_parallelism_enabled": True,
            "environment_overrides": [],
            "complete": True,
        },
        "protocol": copy.deepcopy(FUNCTIONAL_PROTOCOL),
        "workload": {
            **workload.report_dict(),
            "descriptor_sha256": MODULE.workload_descriptor_sha256(
                workload, "functional"
            ),
        },
        "session": {
            "max_circle_log": workload.trace_log_rows + 1,
            "host_byte_budget": 256 * 1024 * 1024,
            "retained_host_twiddle_bytes": 4096,
            "tower_build_count": 1,
        },
        "proof": {
            "samples": [
                {"bytes": proof_bytes, "sha256": digest} for _ in range(samples)
            ],
            "verified_samples": samples,
            "all_samples_byte_identical": True,
            "artifact": binding,
        },
        "backend_telemetry": telemetry,
        "timing": {
            "backend_init_seconds": 0.05,
            "warmup_request_seconds": [request for _ in range(warmups)],
            "samples": [copy.deepcopy(sample) for _ in range(samples)],
            "stage_profiles": None,
            "input_seconds": summary(0.1),
            "prove_seconds": summary(prove),
            "proof_encode_seconds": summary(0.01),
            "verify_seconds": summary(0.02),
            "request_seconds": summary(request),
        },
        "throughput": {
            "headline_eligible": all(requirements.values()),
            "headline_native_mhz": (
                summary(rates["native_mhz"]) if all(requirements.values()) else None
            ),
            "diagnostic_native_mhz": None,
            "headline_request_native_mhz": (
                summary(rates["request_native_mhz"])
                if all(requirements.values())
                else None
            ),
            "diagnostic_request_native_mhz": None,
            "headline_trace_row_mhz": (
                summary(rates["trace_row_mhz"])
                if all(requirements.values())
                else None
            ),
            "diagnostic_trace_row_mhz": None,
            "headline_request_trace_row_mhz": (
                summary(rates["request_trace_row_mhz"])
                if all(requirements.values())
                else None
            ),
            "diagnostic_request_trace_row_mhz": None,
            "headline_committed_mcells_per_second": (
                summary(rates["committed_mcells_per_second"])
                if all(requirements.values())
                else None
            ),
            "diagnostic_committed_mcells_per_second": None,
            "headline_requirements": requirements,
        },
    }


def args(samples: int = 5, warmups: int = 10) -> argparse.Namespace:
    return argparse.Namespace(protocol="functional", samples=samples, warmups=warmups)


def lane_args(timeout_seconds: float = 2.0) -> argparse.Namespace:
    return argparse.Namespace(
        protocol="functional",
        samples=5,
        warmups=10,
        timeout_seconds=timeout_seconds,
    )


def resource_usage_stderr(peak_rss_kib: int = 1024) -> bytes:
    if sys.platform == "darwin":
        return f"{peak_rss_kib * 1024}  maximum resident set size\n".encode()
    return f"Maximum resident set size (kbytes): {peak_rss_kib}\n".encode()


class NativeProofMatrixTests(unittest.TestCase):
    def test_real_wide_fibonacci_oracle_identity_is_pinned(self) -> None:
        from native_proof_matrix_lib import RUST_ORACLE_SHA256

        self.assertEqual(
            RUST_ORACLE_SHA256,
            "4d223c37e85b96f61dccc684f2897c82d2d55f6c50b59616a69cc5cc70d2ccf8",
        )

    def test_library_miss_is_cold_but_hit_timing_alone_is_warm(self) -> None:
        cache = pipeline_cache()
        cache["library_cache_misses"] = 1
        self.assertTrue(pipeline_preparation_occurred(cache))

        cache = pipeline_cache()
        cache["library_cache_hits"] = 1
        cache["pipeline_preparation_seconds"] = 0.125
        cache["library_preparation_seconds"] = 0.25
        self.assertFalse(pipeline_preparation_occurred(cache))

    def test_atomic_output_and_lock_boundaries(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            destination = root / "nested" / "result.json"
            destination.parent.mkdir()
            destination.write_bytes(b"old")
            MODULE.atomic_write_bytes(destination, b"complete-new-document")
            self.assertEqual(destination.read_bytes(), b"complete-new-document")
            self.assertEqual(
                [path for path in destination.parent.iterdir() if path != destination],
                [],
            )

            output_dir = root / "matrix"
            with MODULE.output_dir_lock(output_dir):
                with self.assertRaisesRegex(MODULE.MatrixError, "locked"):
                    with MODULE.output_dir_lock(output_dir):
                        self.fail("second lock unexpectedly succeeded")

    def test_tagged_workloads_have_exact_geometry_and_fixed_descriptors(self) -> None:
        vectors = (
            (
                MODULE.parse_workload("wide_fibonacci:sequence_len=8,log_n_rows=10"),
                8,
                8192,
                "8586bce9ae8c0673453803b3b65ca8d4fc677638d53e5933e7692af4dd38586f",
            ),
            (
                MODULE.parse_workload("xor:offset=3,log_step=2,log_size=10"),
                3,
                3072,
                "b0272044b4e572bf519aa58c00ee3520f2961b409d2ecb67ba86c5760a991c0e",
            ),
            (
                MODULE.parse_workload("plonk:log_n_rows=10"),
                8,
                8192,
                "8e22d72f97cfe01bdb3fdf94e362160418ca16022db7cdaccacf073e2ef67cee",
            ),
            (
                MODULE.parse_workload(
                    "state_machine:initial_y=3,log_n_rows=10,initial_x=9"
                ),
                3,
                3072,
                "2aef739c7447cb192da8648b7a4b539ccb86c1f532de7de986287cb89844b8a7",
            ),
            (
                MODULE.parse_workload("blake:n_rounds=2,log_n_rows=8"),
                192,
                49152,
                "bee0efa41b40d2f61fbecccb2096af92ff2bcf6fbbc253a852077d4c95a1830e",
            ),
            (
                MODULE.parse_workload("poseidon:log_n_instances=13"),
                1264,
                1_294_336,
                "aa292dd3fce8924260fbf1729589c9cfd93335298c7995bed4f537250527b956",
            ),
        )
        for workload, columns, cells, descriptor in vectors:
            with self.subTest(workload=workload.name):
                self.assertEqual(
                    workload.trace_rows,
                    256 if workload.name == "blake" else 1024,
                )
                self.assertEqual(workload.committed_columns, columns)
                self.assertEqual(workload.committed_trace_cells, cells)
                if workload.name == "blake":
                    self.assertEqual(workload.native_unit, "blake_round_instances")
                    self.assertEqual(workload.native_units, 512)
                elif workload.name == "poseidon":
                    self.assertEqual(workload.native_unit, "poseidon_instances")
                    self.assertEqual(workload.native_units, 8192)
                self.assertEqual(
                    MODULE.workload_descriptor_sha256(workload, "functional"),
                    descriptor,
                )
        self.assertEqual(
            MODULE.parse_workload("10:8"), MODULE.Workload.wide_fibonacci(10, 8)
        )

    def test_workload_parser_rejects_noncanonical_or_unbounded_rows(self) -> None:
        invalid = (
            "unknown:x=1",
            "xor:log_size=10,log_step=2",
            "xor:log_size=10,log_step=11,offset=3",
            "xor:log_size=10,log_step=2,offset=-1",
            "xor:log_size=10,log_step=2,offset=4",
            "wide_fibonacci:log_n_rows=10,log_n_rows=11,sequence_len=8",
            "wide_fibonacci:log_n_rows=22,sequence_len=512",
            "plonk:log_n_rows=0",
            "plonk:log_n_rows=23",
            "plonk:log_size=10",
            "state_machine:log_n_rows=0,initial_x=9,initial_y=3",
            "state_machine:log_n_rows=10,initial_x=-1,initial_y=3",
            "state_machine:log_n_rows=10,initial_x=2147483647,initial_y=3",
            "state_machine:log_n_rows=10,initial_x=9",
            "blake:log_n_rows=8",
            "blake:log_n_rows=8,n_rounds=0",
            "blake:log_n_rows=8,n_rounds=33",
            "blake:log_n_rows=18,n_rounds=2",
            "poseidon:log_n_instances=3",
            "poseidon:log_n_instances=18",
            "poseidon:log_n_instances=13,log_n_rows=10",
        )
        for encoded in invalid:
            with self.subTest(encoded=encoded):
                with self.assertRaises(argparse.ArgumentTypeError):
                    MODULE.parse_workload(encoded)

    def test_controller_bounds_and_formal_oracle_are_checked_during_parse(self) -> None:
        diagnostic = MODULE.parse_args(["--allow-non-headline"])
        self.assertFalse(diagnostic.formal)
        self.assertEqual(
            [row.name for row in diagnostic.workloads],
            ["wide_fibonacci", "xor", "plonk", "state_machine", "blake", "poseidon"],
        )
        self.assertEqual(diagnostic.warmups, MODULE.MIN_HEADLINE_WARMUPS)
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            MODULE.parse_args([])
        formal = MODULE.parse_args(["--rust-oracle-bin", "/tmp/oracle"])
        self.assertTrue(formal.formal)
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            MODULE.parse_args(
                [
                    "--allow-non-headline",
                    "--workload",
                    "wide_fibonacci:log_n_rows=16,sequence_len=512",
                    "--warmups",
                    "1",
                    "--samples",
                    "21",
                ]
            )

    def test_lane_commands_use_only_canonical_tagged_flags(self) -> None:
        from native_proof_matrix_lib.artifacts import lane_command

        artifact = Path("/tmp/proof.json")
        self.assertEqual(
            lane_command(Path("cpu"), MODULE.Workload.wide_fibonacci(10, 8), 1, 2, "functional", artifact),
            ["cpu", "--example", "wide_fibonacci", "--log-n-rows", "10", "--sequence-len", "8", "--warmups", "1", "--samples", "2", "--protocol", "functional", "--proof-artifact-out", "/tmp/proof.json"],
        )
        self.assertIn("--log-step", lane_command(Path("metal"), MODULE.Workload.xor(10, 2, 3), 1, 2, "functional", artifact))
        self.assertEqual(
            lane_command(Path("cpu"), MODULE.Workload.plonk(10), 10, 2, "functional", artifact),
            ["cpu", "--example", "plonk", "--log-n-rows", "10", "--warmups", "10", "--samples", "2", "--protocol", "functional", "--proof-artifact-out", "/tmp/proof.json"],
        )
        self.assertEqual(
            lane_command(
                Path("metal"),
                MODULE.Workload.state_machine(10, 9, 3),
                10,
                2,
                "functional",
                artifact,
            ),
            ["metal", "--example", "state_machine", "--log-n-rows", "10", "--initial-x", "9", "--initial-y", "3", "--warmups", "10", "--samples", "2", "--protocol", "functional", "--proof-artifact-out", "/tmp/proof.json"],
        )
        self.assertEqual(
            lane_command(
                Path("cpu"),
                MODULE.Workload.blake(8, 2),
                10,
                2,
                "functional",
                artifact,
            ),
            ["cpu", "--example", "blake", "--log-n-rows", "8", "--n-rounds", "2", "--warmups", "10", "--samples", "2", "--protocol", "functional", "--proof-artifact-out", "/tmp/proof.json"],
        )
        self.assertEqual(
            lane_command(
                Path("metal"),
                MODULE.Workload.poseidon(13),
                10,
                2,
                "functional",
                artifact,
            ),
            ["metal", "--example", "poseidon", "--log-n-instances", "13", "--warmups", "10", "--samples", "2", "--protocol", "functional", "--proof-artifact-out", "/tmp/proof.json"],
        )

    def test_reports_and_artifacts_validate_for_both_examples_and_lanes(self) -> None:
        workloads = (
            MODULE.Workload.wide_fibonacci(10, 8),
            MODULE.Workload.xor(10, 2, 3),
            MODULE.Workload.plonk(10),
            MODULE.Workload.state_machine(10, 9, 3),
            MODULE.Workload.blake(8, 2),
            MODULE.Workload.poseidon(13),
        )
        with tempfile.TemporaryDirectory() as directory:
            for workload in workloads:
                for lane in ("cpu", "metal"):
                    with self.subTest(workload=workload.name, lane=lane):
                        path = Path(directory) / f"{workload.name}-{lane}.json"
                        write_proof_artifact(path, workload)
                        artifact = MODULE.load_proof_artifact(path, lane)
                        report = make_report(lane, workload, artifact_path=path)
                        fingerprint, blockers = MODULE.validate_report(report, lane, workload, args())
                        self.assertEqual(fingerprint, (PROOF_WIRE_SHA256, len(PROOF_WIRE_BYTES)))
                        self.assertEqual(blockers, [])
                        MODULE.validate_proof_artifact(report, lane, workload, args(), artifact, fingerprint)

    def test_report_schema_and_derived_metrics_fail_closed(self) -> None:
        workload = MODULE.Workload.wide_fibonacci(10, 8)
        for mutation in ("missing", "extra"):
            report = make_report("cpu", workload)
            if mutation == "missing":
                del report["timing"]["request_seconds"]
            else:
                report["timing"]["surprise"] = 1
            with self.subTest(mutation=mutation), self.assertRaises(MODULE.MatrixError):
                MODULE.validate_report(report, "cpu", workload, args())
        for field in (
            "native_mhz",
            "request_native_mhz",
            "trace_row_mhz",
            "request_trace_row_mhz",
            "committed_mcells_per_second",
        ):
            report = make_report("cpu", workload)
            report["timing"]["samples"][0][field] *= 2
            with self.subTest(field=field), self.assertRaises(MODULE.MatrixError):
                MODULE.validate_report(report, "cpu", workload, args())
        report = make_report("cpu", workload)
        report["throughput"]["headline_native_mhz"]["median"] *= 2
        with self.assertRaises(MODULE.MatrixError):
            MODULE.validate_report(report, "cpu", workload, args())
        report = make_report("cpu", workload)
        report["timing"]["samples"][0]["request_seconds"] = 2.01
        report["timing"]["request_seconds"] = summary(2.402)
        with self.assertRaisesRegex(MODULE.MatrixError, "shorter than its phases"):
            MODULE.validate_report(report, "cpu", workload, args())

    def test_sampling_evidence_and_headline_requirements_are_recomputed(self) -> None:
        workload = MODULE.Workload.wide_fibonacci(10, 8)
        for samples, warmups in ((2, 10), (5, 1)):
            report = make_report("cpu", workload, samples=samples, warmups=warmups)
            report["evidence_class"] = "verified_unprofiled"
            requirements = report["throughput"]["headline_requirements"]
            requirements["verified_unprofiled"] = True
            requirements["sampling_contract"] = True
            report["throughput"]["headline_eligible"] = True
            for field in (
                "headline_native_mhz",
                "headline_request_native_mhz",
                "headline_trace_row_mhz",
                "headline_request_trace_row_mhz",
                "headline_committed_mcells_per_second",
            ):
                report["throughput"][field] = summary(
                    report["timing"]["samples"][0][
                        {
                            "headline_native_mhz": "native_mhz",
                            "headline_request_native_mhz": "request_native_mhz",
                            "headline_trace_row_mhz": "trace_row_mhz",
                            "headline_request_trace_row_mhz": "request_trace_row_mhz",
                            "headline_committed_mcells_per_second": "committed_mcells_per_second",
                        }[field]
                    ]
                )
            with self.subTest(samples=samples, warmups=warmups), self.assertRaisesRegex(
                MODULE.MatrixError,
                "measured sampling",
            ):
                MODULE.validate_report(
                    report,
                    "cpu",
                    workload,
                    args(samples=samples, warmups=warmups),
                )

    def test_ordered_prove_time_drift_blocks_unstable_headline_data(self) -> None:
        workload = MODULE.Workload.wide_fibonacci(10, 8)
        stable = make_report("cpu", workload)
        _, stable_blockers = MODULE.validate_report(
            stable, "cpu", workload, args()
        )
        self.assertNotIn("cpu_ordered_prove_time_drift", stable_blockers)

        drifting = make_report("cpu", workload)
        set_prove_times(drifting, workload, [2.2, 2.2, 2.0, 2.0, 2.0])
        _, drifting_blockers = MODULE.validate_report(
            drifting, "cpu", workload, args()
        )
        self.assertIn("cpu_ordered_prove_time_drift", drifting_blockers)

    def test_descriptor_session_protocol_and_telemetry_fail_closed(self) -> None:
        workload = MODULE.Workload.xor(10, 2, 3)
        mutations = (
            ("descriptor", lambda report: report["workload"].__setitem__("descriptor_sha256", "0" * 64)),
            ("geometry", lambda report: report["workload"].__setitem__("committed_columns", 4)),
            ("protocol", lambda report: report["protocol"].__setitem__("pow_bits", 9)),
            ("session", lambda report: report["session"].__setitem__("tower_build_count", 2)),
            ("telemetry", lambda report: report["backend_telemetry"].__setitem__("total_metal_dispatches", 0)),
        )
        for name, mutate in mutations:
            report = make_report("metal", workload)
            mutate(report)
            with self.subTest(name=name), self.assertRaises(MODULE.MatrixError):
                MODULE.validate_report(report, "metal", workload, args())

        report = make_report("metal", workload, cold_pipeline=True)
        _, blockers = MODULE.validate_report(report, "metal", workload, args())
        self.assertIn("metal_requirement_backend_telemetry_valid", blockers)
        self.assertFalse(report["throughput"]["headline_eligible"])
        report["backend_telemetry"]["valid"] = True
        with self.assertRaisesRegex(MODULE.MatrixError, "pipeline warmth"):
            MODULE.validate_report(report, "metal", workload, args())

        report = make_report("metal", workload)
        report["backend_telemetry"]["samples"] = report["backend_telemetry"][
            "samples"
        ][:-1]
        with self.assertRaisesRegex(MODULE.MatrixError, "cover every request"):
            MODULE.validate_report(report, "metal", workload, args())

        report = make_report("metal", workload)
        delta = report["backend_telemetry"]["warmups"][0]
        delta["counters"] = backend_counters(0, 1)
        delta["metal_dispatches"] = 0
        delta["classification"] = "host_only"
        report["backend_telemetry"]["total_metal_dispatches"] -= 4
        with self.assertRaisesRegex(MODULE.MatrixError, "no accelerated work"):
            MODULE.validate_report(report, "metal", workload, args())

    def test_artifact_statement_and_cross_backend_proofs_must_match(self) -> None:
        workload = MODULE.Workload.xor(10, 2, 3)
        cpu = make_report("cpu", workload)
        metal = make_report("metal", workload)
        cpu_fingerprint, _ = MODULE.validate_report(cpu, "cpu", workload, args())
        metal_fingerprint, _ = MODULE.validate_report(metal, "metal", workload, args())
        MODULE.validate_pair(cpu, metal, cpu_fingerprint, metal_fingerprint)
        metal["proof"]["samples"][0]["sha256"] = "0" * 64
        with self.assertRaises(MODULE.MatrixError):
            MODULE.validate_report(metal, "metal", workload, args())

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "proof.json"
            write_proof_artifact(path, workload)
            artifact = MODULE.load_proof_artifact(path, "cpu")
            report = make_report("cpu", workload, artifact_path=path)
            fingerprint, _ = MODULE.validate_report(report, "cpu", workload, args())
            artifact["document"]["xor_statement"]["offset"] += 1
            with self.assertRaises(MODULE.MatrixError):
                MODULE.validate_proof_artifact(report, "cpu", workload, args(), artifact, fingerprint)

            report["proof"]["artifact"]["sample_index"] = 1
            with self.assertRaisesRegex(MODULE.MatrixError, "binding does not match"):
                MODULE.validate_proof_artifact(
                    report, "cpu", workload, args(), artifact, fingerprint
                )
            report = make_report("cpu", workload, artifact_path=path)
            document = json.loads(path.read_text())
            document["upstream_commit"] = "0" * 40
            path.write_text(json.dumps(document) + "\n")
            mutated = MODULE.load_proof_artifact(path, "cpu")
            with self.assertRaisesRegex(MODULE.MatrixError, "upstream_commit"):
                MODULE.validate_proof_artifact(
                    report, "cpu", workload, args(), mutated, fingerprint
                )

    def test_fri_fold_commit_epochs_are_counted_as_metal_dispatches(self) -> None:
        workload = MODULE.Workload.wide_fibonacci(10, 8)
        report = make_report("metal", workload)
        for delta in (
            report["backend_telemetry"]["warmups"]
            + report["backend_telemetry"]["samples"]
        ):
            delta["counters"]["metal_circle_lde_dispatches"] = 0
            delta["counters"]["metal_fri_fold_commit_epochs"] = 4
        MODULE.validate_report(report, "metal", workload, args())

    def test_state_machine_artifact_binds_the_derived_statement(self) -> None:
        workload = MODULE.Workload.state_machine(10, 9, 3)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state-machine.json"
            write_proof_artifact(path, workload)
            report = make_report("cpu", workload, artifact_path=path)
            fingerprint, _ = MODULE.validate_report(report, "cpu", workload, args())

            artifact = MODULE.load_proof_artifact(path, "cpu")
            MODULE.validate_proof_artifact(
                report, "cpu", workload, args(), artifact, fingerprint
            )
            for mutation in (
                "initial",
                "final",
                "stmt0",
                "claim_negative",
                "claim_noncanonical",
            ):
                artifact = MODULE.load_proof_artifact(path, "cpu")
                statement = artifact["document"]["state_machine_statement"]
                if mutation == "initial":
                    statement["public_input"][0][0] += 1
                elif mutation == "final":
                    statement["public_input"][1][1] += 1
                elif mutation == "stmt0":
                    statement["stmt0"]["m"] += 1
                elif mutation == "claim_negative":
                    statement["stmt1"]["x_axis_claimed_sum"][0] = -1
                else:
                    statement["stmt1"]["x_axis_claimed_sum"][0] = (1 << 31) - 1
                with self.subTest(mutation=mutation), self.assertRaises(
                    MODULE.MatrixError
                ):
                    MODULE.validate_proof_artifact(
                        report, "cpu", workload, args(), artifact, fingerprint
                    )
            write_proof_artifact(path, workload, PROOF_WIRE_BYTES + b" ")
            mutated = MODULE.load_proof_artifact(path, "cpu")
            with self.assertRaisesRegex(MODULE.MatrixError, "bytes disagree"):
                MODULE.validate_proof_artifact(
                    report, "cpu", workload, args(), mutated, fingerprint
                )

    def test_blake_artifact_binds_log_rows_and_round_count(self) -> None:
        workload = MODULE.Workload.blake(8, 2)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "blake.json"
            write_proof_artifact(path, workload)
            report = make_report("cpu", workload, artifact_path=path)
            fingerprint, _ = MODULE.validate_report(report, "cpu", workload, args())

            artifact = MODULE.load_proof_artifact(path, "cpu")
            MODULE.validate_proof_artifact(
                report, "cpu", workload, args(), artifact, fingerprint
            )
            for field in ("log_n_rows", "n_rounds"):
                artifact = MODULE.load_proof_artifact(path, "cpu")
                artifact["document"]["blake_statement"][field] += 1
                with self.subTest(field=field), self.assertRaisesRegex(
                    MODULE.MatrixError,
                    "statement does not match request",
                ):
                    MODULE.validate_proof_artifact(
                        report, "cpu", workload, args(), artifact, fingerprint
                    )

    def test_poseidon_artifact_binds_instance_count(self) -> None:
        workload = MODULE.Workload.poseidon(13)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "poseidon.json"
            write_proof_artifact(path, workload)
            report = make_report("cpu", workload, artifact_path=path)
            fingerprint, _ = MODULE.validate_report(report, "cpu", workload, args())
            artifact = MODULE.load_proof_artifact(path, "cpu")
            artifact["document"]["poseidon_statement"]["log_n_instances"] += 1
            with self.assertRaisesRegex(
                MODULE.MatrixError,
                "statement does not match request",
            ):
                MODULE.validate_proof_artifact(
                    report, "cpu", workload, args(), artifact, fingerprint
                )

    def test_lane_failures_publish_bounded_streams_and_require_artifact(self) -> None:
        workload = MODULE.Workload.wide_fibonacci(10, 8)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "bench"
            binary.write_text("#!/bin/sh\nexit 0\n")
            binary.chmod(0o755)

            def nonzero_run(command: list[str], **kwargs: object) -> subprocess.CompletedProcess[bytes]:
                kwargs["stdout"].write(b"partial stdout")
                kwargs["stderr"].write(b"specific failure")
                return subprocess.CompletedProcess(command, 7)

            artifact_dir = root / "nonzero"
            with mock.patch(
                "native_proof_matrix_lib.artifacts.subprocess.run",
                side_effect=nonzero_run,
            ), self.assertRaisesRegex(MODULE.MatrixError, "exited 7"):
                MODULE.run_lane(
                    "cpu", binary, workload, lane_args(), artifact_dir
                )
            self.assertEqual(
                (artifact_dir / "cpu.stdout.json").read_bytes(), b"partial stdout"
            )
            self.assertEqual(
                (artifact_dir / "cpu.stderr.txt").read_bytes(), b"specific failure"
            )

            def timeout_run(command: list[str], **kwargs: object) -> None:
                kwargs["stdout"].write(b"timeout stdout")
                kwargs["stderr"].write(b"timeout stderr")
                raise subprocess.TimeoutExpired(command, 0.01)

            artifact_dir = root / "timeout"
            with mock.patch(
                "native_proof_matrix_lib.artifacts.subprocess.run",
                side_effect=timeout_run,
            ), self.assertRaisesRegex(MODULE.MatrixError, "timed out"):
                MODULE.run_lane(
                    "cpu", binary, workload, lane_args(0.01), artifact_dir
                )
            self.assertEqual(
                (artifact_dir / "cpu.stderr.txt").read_bytes(), b"timeout stderr"
            )

            def missing_artifact_run(
                command: list[str], **kwargs: object
            ) -> subprocess.CompletedProcess[bytes]:
                kwargs["stdout"].write(
                    json.dumps(make_report("cpu", workload)).encode()
                )
                kwargs["stderr"].write(resource_usage_stderr())
                return subprocess.CompletedProcess(command, 0)

            artifact_dir = root / "missing"
            with mock.patch(
                "native_proof_matrix_lib.artifacts.subprocess.run",
                side_effect=missing_artifact_run,
            ), self.assertRaisesRegex(MODULE.MatrixError, "was not produced"):
                MODULE.run_lane(
                    "cpu", binary, workload, lane_args(), artifact_dir
                )

    def test_oversized_stdout_still_publishes_stderr(self) -> None:
        workload = MODULE.Workload.wide_fibonacci(10, 8)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "bench"
            binary.write_text("#!/bin/sh\nexit 0\n")
            binary.chmod(0o755)

            def oversized_run(
                command: list[str], **kwargs: object
            ) -> subprocess.CompletedProcess[bytes]:
                kwargs["stdout"].write(b"oversized stdout")
                kwargs["stderr"].write(b"preserved stderr")
                return subprocess.CompletedProcess(command, 0)

            artifact_dir = root / "oversized"
            with mock.patch(
                "native_proof_matrix_lib.artifacts.subprocess.run",
                side_effect=oversized_run,
            ), mock.patch(
                "native_proof_matrix_lib.artifacts.MAX_STDOUT_BYTES", 4
            ), self.assertRaisesRegex(MODULE.MatrixError, "stream limit exceeded"):
                MODULE.run_lane(
                    "cpu", binary, workload, lane_args(), artifact_dir
                )
            self.assertEqual(
                (artifact_dir / "cpu.stdout.json").read_bytes(), b"oversized stdout"
            )
            self.assertEqual(
                (artifact_dir / "cpu.stderr.txt").read_bytes(), b"preserved stderr"
            )

    def test_pinned_rust_oracle_records_binary_and_artifact_evidence(self) -> None:
        from native_proof_matrix_lib.artifacts import run_rust_oracle

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            artifact = root / "proof.json"
            artifact.write_text("{}\n")
            oracle = root / "oracle"
            oracle.write_text("#!/bin/sh\nexit 0\n")
            oracle.chmod(0o755)
            oracle_digest = hashlib.sha256(oracle.read_bytes()).hexdigest()
            with self.assertRaisesRegex(MODULE.MatrixError, "pinned verifier"):
                run_rust_oracle(oracle, artifact, 2.0)
            with mock.patch(
                "native_proof_matrix_lib.artifacts.RUST_ORACLE_SHA256",
                oracle_digest,
            ):
                evidence = run_rust_oracle(oracle, artifact, 2.0)
            self.assertTrue(evidence["verified"])
            self.assertEqual(evidence["upstream_commit"], UPSTREAM_COMMIT)
            self.assertEqual(evidence["toolchain"], "nightly-2025-07-14")
            self.assertEqual(
                evidence["binary_sha256"],
                hashlib.sha256(oracle.read_bytes()).hexdigest(),
            )
            oracle.write_text("#!/bin/sh\nprintf unexpected\n")
            oracle.chmod(0o755)
            oracle_digest = hashlib.sha256(oracle.read_bytes()).hexdigest()
            with mock.patch(
                "native_proof_matrix_lib.artifacts.RUST_ORACLE_SHA256",
                oracle_digest,
            ), self.assertRaisesRegex(MODULE.MatrixError, "unexpected output"):
                run_rust_oracle(oracle, artifact, 2.0)
            oracle.write_text("#!/bin/sh\nexit 1\n")
            oracle.chmod(0o755)
            oracle_digest = hashlib.sha256(oracle.read_bytes()).hexdigest()
            with mock.patch(
                "native_proof_matrix_lib.artifacts.RUST_ORACLE_SHA256",
                oracle_digest,
            ), self.assertRaisesRegex(MODULE.MatrixError, "rejected"):
                run_rust_oracle(oracle, artifact, 2.0)

            oracle.write_text('#!/bin/sh\nprintf x >> "$4"\n')
            oracle.chmod(0o755)
            oracle_digest = hashlib.sha256(oracle.read_bytes()).hexdigest()
            artifact.write_text("{}\n")
            with mock.patch(
                "native_proof_matrix_lib.artifacts.RUST_ORACLE_SHA256",
                oracle_digest,
            ), self.assertRaisesRegex(MODULE.MatrixError, "artifact changed"):
                run_rust_oracle(oracle, artifact, 2.0)

    def test_formal_matrix_invokes_pinned_oracle_once_per_parity_row(self) -> None:
        workloads = [
            MODULE.Workload.wide_fibonacci(10, 8),
            MODULE.Workload.xor(10, 2, 3),
            MODULE.Workload.plonk(10),
            MODULE.Workload.state_machine(10, 9, 3),
            MODULE.Workload.blake(8, 2),
            MODULE.Workload.poseidon(13),
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binaries = {}
            for name in ("cpu", "metal", "oracle"):
                binary = root / name
                binary.write_text("#!/bin/sh\nexit 0\n")
                binary.chmod(0o755)
                binaries[name] = binary

            matrix_args = argparse.Namespace(
                workloads=workloads,
                cpu_bin=binaries["cpu"],
                metal_bin=binaries["metal"],
                rust_oracle_bin=binaries["oracle"],
                output_dir=root / "out",
                protocol="functional",
                warmups=10,
                samples=10,
                cooldown_seconds=0.0,
                timeout_seconds=2.0,
                formal=True,
            )

            def fake_lane(
                lane: str,
                _binary: Path,
                workload: MODULE.Workload,
                _args: argparse.Namespace,
                artifact_dir: Path,
            ) -> dict[str, object]:
                artifact_path = artifact_dir / f"{lane}.proof-artifact.json"
                write_proof_artifact(artifact_path, workload)
                report = make_report(
                    lane,
                    workload,
                    samples=_args.samples,
                    warmups=_args.warmups,
                    artifact_path=artifact_path,
                )
                stdout_path = artifact_dir / f"{lane}.stdout.json"
                stderr_path = artifact_dir / f"{lane}.stderr.txt"
                stdout_path.write_text(json.dumps(report))
                stderr_path.write_bytes(b"")
                return {
                    "lane": lane,
                    "command": [lane],
                    "process_wall_seconds": 1.0,
                    "resources": {
                        "measurement": "darwin_usr_bin_time_l_v1",
                        "measurement_locale": "C",
                        "normalized_unit": "KiB",
                        "peak_rss_kib": 1024,
                    },
                    "stdout_path": stdout_path,
                    "stderr_path": stderr_path,
                    "report": report,
                    "proof_artifact": MODULE.load_proof_artifact(
                        artifact_path, lane
                    ),
                }

            def oracle_evidence(
                binary: Path, artifact_path: Path, _timeout: float
            ) -> dict[str, object]:
                artifact_sha256 = hashlib.sha256(artifact_path.read_bytes()).hexdigest()
                command = [
                    str(binary),
                    "--mode",
                    "verify",
                    "--artifact",
                    str(artifact_path),
                ]
                return {
                    "status": "passed",
                    "verified": True,
                    "upstream_commit": UPSTREAM_COMMIT,
                    "toolchain": "nightly-2025-07-14",
                    "binary_path": str(binary),
                    "binary_sha256": RUST_ORACLE_SHA256,
                    "artifact_path": str(artifact_path),
                    "artifact_sha256": artifact_sha256,
                    "command": command,
                    "elapsed_seconds": 0.01,
                    "stdout_sha256": hashlib.sha256(b"").hexdigest(),
                    "stderr_sha256": hashlib.sha256(b"").hexdigest(),
                }
            with mock.patch(
                "native_proof_matrix_lib.controller.run_lane",
                side_effect=fake_lane,
            ), mock.patch(
                "native_proof_matrix_lib.controller.run_rust_oracle",
                side_effect=oracle_evidence,
            ) as oracle:
                document = MODULE.run_matrix(matrix_args)
            self.assertEqual(oracle.call_count, 6)
            self.assertTrue(document["summary"]["all_rust_oracles_verified"])
            self.assertEqual(
                [row["lane_order"] for row in document["rows"]],
                [
                    ["cpu", "metal"],
                    ["metal", "cpu"],
                    ["cpu", "metal"],
                    ["metal", "cpu"],
                    ["cpu", "metal"],
                    ["metal", "cpu"],
                ],
            )
            self.assertTrue(all(row["rust_oracle"] for row in document["rows"]))

    def test_dirty_provenance_blocks_headline_without_weakening_parity(self) -> None:
        workload = MODULE.Workload.wide_fibonacci(10, 8)
        report = make_report("cpu", workload, dirty=True)
        fingerprint, blockers = MODULE.validate_report(
            report, "cpu", workload, args()
        )
        self.assertEqual(fingerprint, (PROOF_WIRE_SHA256, len(PROOF_WIRE_BYTES)))
        self.assertIn("cpu_git_dirty", blockers)
        self.assertIn("cpu_requirement_clean_complete_provenance", blockers)
        self.assertFalse(report["throughput"]["headline_eligible"])

    def test_formal_mode_returns_nonzero_for_non_headline_matrix(self) -> None:
        parsed = argparse.Namespace(allow_non_headline=False)
        document = {"summary": {"all_rows_headline_eligible": False}}
        with mock.patch.object(
            MODULE, "parse_args", return_value=parsed
        ), mock.patch.object(
            MODULE, "run_matrix", return_value=document
        ), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(
            io.StringIO()
        ):
            self.assertEqual(MODULE.main([]), 2)
        parsed.allow_non_headline = True
        with mock.patch.object(
            MODULE, "parse_args", return_value=parsed
        ), mock.patch.object(
            MODULE, "run_matrix", return_value=document
        ), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(MODULE.main([]), 0)

    def test_unprofiled_environment_gate_is_fail_closed(self) -> None:
        MODULE.require_unprofiled_environment({})
        with self.assertRaises(MODULE.MatrixError):
            MODULE.require_unprofiled_environment({"STWO_ZIG_METAL_PROFILE_OUT": "x"})


if __name__ == "__main__":
    unittest.main()
