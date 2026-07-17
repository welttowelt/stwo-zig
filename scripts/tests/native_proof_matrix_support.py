"""Deterministic fixtures for the Native proof matrix tests."""

from __future__ import annotations

import argparse
import copy
import hashlib
import importlib.util
import json
import statistics
import sys
from pathlib import Path


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

