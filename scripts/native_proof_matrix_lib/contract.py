"""Fail-closed validation for Native proof benchmark reports."""

from __future__ import annotations

import argparse
import math
from typing import Any

from .model import (
    ACCELERATED_CLASSIFICATIONS,
    BACKEND_COUNTER_KEYS,
    EXPECTED_BACKENDS,
    HEADLINE_REQUIREMENT_KEYS,
    INTEROP_ARTIFACT_SCHEMA_VERSION,
    INTEROP_EXCHANGE_MODE,
    INTEROP_UPSTREAM_COMMIT,
    PIPELINE_CACHE_COUNTER_KEYS,
    PIPELINE_CACHE_SECONDS_KEY,
    PROTOCOL_PRESETS,
    RATE_ABSOLUTE_TOLERANCE,
    RATE_RELATIVE_TOLERANCE,
    REPORT_SCHEMA_VERSION,
    MatrixError,
    Workload,
    workload_descriptor_sha256,
)


ARTIFACT_KEYS = {
    "schema_version",
    "upstream_commit",
    "exchange_mode",
    "generator",
    "example",
    "prove_mode",
    "pcs_config",
    "blake_statement",
    "plonk_statement",
    "poseidon_statement",
    "state_machine_statement",
    "wide_fibonacci_statement",
    "xor_statement",
    "proof_bytes_hex",
}
ARTIFACT_BINDING_KEYS = {
    "path",
    "sample_index",
    "bytes",
    "sha256",
    "artifact_schema_version",
    "upstream_commit",
    "exchange_mode",
}


def require_object(parent: dict[str, Any], key: str, context: str) -> dict[str, Any]:
    value = parent.get(key)
    if not isinstance(value, dict):
        raise MatrixError(f"{context}.{key} must be an object")
    return value


def require_list(parent: dict[str, Any], key: str, context: str) -> list[Any]:
    value = parent.get(key)
    if not isinstance(value, list):
        raise MatrixError(f"{context}.{key} must be an array")
    return value


def require_finite_number(value: Any, context: str, positive: bool = False) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise MatrixError(f"{context} must be numeric")
    result = float(value)
    if not math.isfinite(result) or (positive and result <= 0):
        qualifier = "positive and finite" if positive else "finite"
        raise MatrixError(f"{context} must be {qualifier}")
    return result


def require_digest(value: Any, context: str) -> str:
    if not isinstance(value, str) or len(value) != 64:
        raise MatrixError(f"{context} must be a SHA-256 hex digest")
    try:
        int(value, 16)
    except ValueError as error:
        raise MatrixError(f"{context} must be a SHA-256 hex digest") from error
    return value.lower()


def require_exact_keys(value: dict[str, Any], expected: set[str], context: str) -> None:
    actual = set(value)
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        raise MatrixError(
            f"{context} has the wrong schema; missing={missing}, extra={extra}"
        )


def proof_fingerprint(report: dict[str, Any], lane: str, samples: int) -> tuple[str, int]:
    proof = require_object(report, "proof", lane)
    records = require_list(proof, "samples", f"{lane}.proof")
    if proof.get("verified_samples") != samples or len(records) != samples:
        raise MatrixError(f"{lane} did not verify every requested proof sample")
    if proof.get("all_samples_byte_identical") is not True:
        raise MatrixError(f"{lane} proof samples are not byte-identical")

    fingerprints: list[tuple[str, int]] = []
    for index, record in enumerate(records):
        if not isinstance(record, dict):
            raise MatrixError(f"{lane}.proof.samples[{index}] must be an object")
        digest = require_digest(
            record.get("sha256"),
            f"{lane}.proof.samples[{index}].sha256",
        )
        size = record.get("bytes")
        if isinstance(size, bool) or not isinstance(size, int) or size <= 0:
            raise MatrixError(f"{lane}.proof.samples[{index}].bytes must be positive")
        fingerprints.append((digest, size))
    if len(set(fingerprints)) != 1:
        raise MatrixError(f"{lane} proof fingerprints disagree despite byte-identity claim")
    return fingerprints[0]


def validate_proof_artifact(
    report: dict[str, Any],
    lane: str,
    workload: Workload,
    args: argparse.Namespace,
    artifact: dict[str, Any],
    fingerprint: tuple[str, int],
) -> None:
    proof = require_object(report, "proof", lane)
    binding = require_object(proof, "artifact", f"{lane}.proof")
    require_exact_keys(binding, ARTIFACT_BINDING_KEYS, f"{lane}.proof.artifact")
    expected_binding = {
        "path": str(artifact["path"]),
        "sample_index": 0,
        "bytes": fingerprint[1],
        "sha256": fingerprint[0],
        "artifact_schema_version": INTEROP_ARTIFACT_SCHEMA_VERSION,
        "upstream_commit": INTEROP_UPSTREAM_COMMIT,
        "exchange_mode": INTEROP_EXCHANGE_MODE,
    }
    if binding != expected_binding:
        raise MatrixError(f"{lane} proof artifact binding does not match sample 0")

    document = artifact["document"]
    if not isinstance(document, dict):
        raise MatrixError(f"{lane} proof artifact root must be an object")
    require_exact_keys(document, ARTIFACT_KEYS, f"{lane}.proof_artifact")
    expected_headers = {
        "schema_version": INTEROP_ARTIFACT_SCHEMA_VERSION,
        "upstream_commit": INTEROP_UPSTREAM_COMMIT,
        "exchange_mode": INTEROP_EXCHANGE_MODE,
        "generator": "zig",
        "example": "wide_fibonacci",
        "prove_mode": "prove",
    }
    for key, expected in expected_headers.items():
        if document.get(key) != expected:
            raise MatrixError(f"{lane} proof artifact has invalid {key}")

    protocol = PROTOCOL_PRESETS[args.protocol]
    expected_pcs_config = {
        "pow_bits": protocol["pow_bits"],
        "fri_config": {
            "log_blowup_factor": protocol["log_blowup_factor"],
            "log_last_layer_degree_bound": protocol["log_last_layer_degree_bound"],
            "n_queries": protocol["n_queries"],
            "fold_step": protocol["fold_step"],
        },
        "lifting_log_size": None,
    }
    if document.get("pcs_config") != expected_pcs_config:
        raise MatrixError(f"{lane} proof artifact PCS config does not match request")
    if document.get("wide_fibonacci_statement") != {
        "log_n_rows": workload.log_rows,
        "sequence_len": workload.sequence_len,
    }:
        raise MatrixError(f"{lane} proof artifact statement does not match request")
    for key in (
        "blake_statement",
        "plonk_statement",
        "poseidon_statement",
        "state_machine_statement",
        "xor_statement",
    ):
        if document.get(key) is not None:
            raise MatrixError(f"{lane} proof artifact has unexpected {key}")
    if artifact["proof_bytes"] != fingerprint[1]:
        raise MatrixError(f"{lane} proof artifact byte length disagrees with sample 0")
    if artifact["proof_sha256"] != fingerprint[0]:
        raise MatrixError(f"{lane} proof artifact digest disagrees with sample 0")


def validate_counter_object(value: Any, context: str) -> dict[str, int]:
    if not isinstance(value, dict):
        raise MatrixError(f"{context} must be an object")
    require_exact_keys(value, BACKEND_COUNTER_KEYS, context)
    for key, counter in value.items():
        if isinstance(counter, bool) or not isinstance(counter, int) or counter < 0:
            raise MatrixError(f"{context}.{key} must be a nonnegative integer")
    return value


def validate_pipeline_cache_object(value: Any, context: str) -> None:
    if not isinstance(value, dict):
        raise MatrixError(f"{context} must be an object")
    required = PIPELINE_CACHE_COUNTER_KEYS | {PIPELINE_CACHE_SECONDS_KEY}
    require_exact_keys(value, required, context)
    for key in PIPELINE_CACHE_COUNTER_KEYS:
        counter = value[key]
        if isinstance(counter, bool) or not isinstance(counter, int) or counter < 0:
            raise MatrixError(f"{context}.{key} must be a nonnegative integer")
    seconds = require_finite_number(
        value[PIPELINE_CACHE_SECONDS_KEY],
        f"{context}.{PIPELINE_CACHE_SECONDS_KEY}",
    )
    if seconds < 0:
        raise MatrixError(
            f"{context}.{PIPELINE_CACHE_SECONDS_KEY} must be nonnegative"
        )


def metal_dispatch_total(counters: dict[str, int]) -> int:
    return sum(
        counters[key]
        for key in (
            "resident_merkle_commits",
            "metal_quotient_dispatches",
            "metal_sampled_value_dispatches",
            "metal_circle_transform_dispatches",
            "metal_circle_lde_dispatches",
            "metal_fri_circle_fold_dispatches",
            "metal_fri_line_fold_dispatches",
            "metal_qm31_coordinate_dispatches",
        )
    )


def cpu_fallback_total(counters: dict[str, int]) -> int:
    named_merkle = (
        counters["cpu_small_merkle_commits"]
        + counters["cpu_streaming_merkle_commits"]
    )
    return max(counters["host_merkle_commits"], named_merkle) + sum(
        counters[key]
        for key in (
            "cpu_sampled_value_evaluations",
            "cpu_small_circle_interpolations",
            "cpu_small_circle_evaluations",
            "cpu_small_circle_ldes",
        )
    )


def telemetry_classification(metal_dispatches: int, cpu_fallbacks: int) -> str:
    if metal_dispatches == 0:
        return "no_backend_work" if cpu_fallbacks == 0 else "host_only"
    if cpu_fallbacks == 0:
        return "accelerated_without_fallbacks"
    return "accelerated_with_fallbacks"


def validate_metal_telemetry(
    report: dict[str, Any],
    warmups: int,
    samples: int,
) -> list[str]:
    telemetry = report.get("backend_telemetry")
    if not isinstance(telemetry, dict):
        raise MatrixError("metal.backend_telemetry must be present")
    if telemetry.get("scope") != "verified_proof_request":
        raise MatrixError("metal telemetry has the wrong scope")
    validate_pipeline_cache_object(
        telemetry.get("post_warmup_pipeline_cache"),
        "metal.backend_telemetry.post_warmup_pipeline_cache",
    )
    warmup_records = require_list(telemetry, "warmups", "metal.backend_telemetry")
    sample_records = require_list(telemetry, "samples", "metal.backend_telemetry")
    if len(warmup_records) != warmups or len(sample_records) != samples:
        raise MatrixError("metal telemetry does not cover every benchmark request")

    measured_dispatches = 0
    measured_fallbacks = 0
    for group, records in (("warmups", warmup_records), ("samples", sample_records)):
        for index, record in enumerate(records):
            context = f"metal.backend_telemetry.{group}[{index}]"
            if not isinstance(record, dict):
                raise MatrixError(f"{context} must be an object")
            counters = validate_counter_object(record.get("counters"), f"{context}.counters")
            validate_pipeline_cache_object(
                record.get("pipeline_cache"),
                f"{context}.pipeline_cache",
            )
            dispatches = metal_dispatch_total(counters)
            fallbacks = cpu_fallback_total(counters)
            classification = telemetry_classification(dispatches, fallbacks)
            if record.get("metal_dispatches") != dispatches:
                raise MatrixError(f"{context}.metal_dispatches disagrees with counters")
            if record.get("cpu_fallbacks") != fallbacks:
                raise MatrixError(f"{context}.cpu_fallbacks disagrees with counters")
            if record.get("classification") != classification:
                raise MatrixError(f"{context}.classification disagrees with counters")
            if dispatches == 0:
                raise MatrixError(f"metal telemetry {group}[{index}] dispatched no Metal work")
            if classification not in ACCELERATED_CLASSIFICATIONS:
                raise MatrixError(f"metal telemetry {group}[{index}] is not accelerated")
            measured_dispatches += dispatches
            measured_fallbacks += fallbacks

    if telemetry.get("total_metal_dispatches") != measured_dispatches:
        raise MatrixError("metal telemetry dispatch total is inconsistent")
    if telemetry.get("total_cpu_fallbacks") != measured_fallbacks:
        raise MatrixError("metal telemetry fallback total is inconsistent")
    return [] if telemetry.get("valid") is True else ["metal_telemetry_invalid"]


def validate_sample_timing(
    sample: dict[str, Any],
    lane: str,
    index: int,
    workload: Workload,
) -> None:
    context = f"{lane}.timing.samples[{index}]"
    for field in (
        "prove_seconds",
        "request_seconds",
        "row_mhz",
        "committed_mcells_per_second",
    ):
        require_finite_number(sample.get(field), f"{context}.{field}", positive=True)
    for field in ("input_seconds", "proof_encode_seconds", "verify_seconds"):
        value = require_finite_number(sample.get(field), f"{context}.{field}")
        if value < 0:
            raise MatrixError(f"{context}.{field} must be nonnegative")

    prove_seconds = float(sample["prove_seconds"])
    if float(sample["request_seconds"]) < prove_seconds:
        raise MatrixError(f"{context}.request_seconds is shorter than prove_seconds")
    expected_row_mhz = workload.rows / prove_seconds / 1_000_000.0
    if not math.isclose(
        float(sample["row_mhz"]),
        expected_row_mhz,
        rel_tol=RATE_RELATIVE_TOLERANCE,
        abs_tol=RATE_ABSOLUTE_TOLERANCE,
    ):
        raise MatrixError(f"{context}.row_mhz is inconsistent")
    expected_cell_rate = workload.committed_trace_cells / prove_seconds / 1_000_000.0
    if not math.isclose(
        float(sample["committed_mcells_per_second"]),
        expected_cell_rate,
        rel_tol=RATE_RELATIVE_TOLERANCE,
        abs_tol=RATE_ABSOLUTE_TOLERANCE,
    ):
        raise MatrixError(f"{context}.committed_mcells_per_second is inconsistent")


def headline_blockers(report: dict[str, Any], lane: str) -> list[str]:
    blockers: list[str] = []
    provenance = require_object(report, "provenance", lane)
    if provenance.get("complete") is not True:
        blockers.append(f"{lane}_provenance_incomplete")
    if provenance.get("git_dirty") is not False:
        blockers.append(f"{lane}_git_dirty")
    if provenance.get("optimization") != "ReleaseFast":
        blockers.append(f"{lane}_not_release_fast")
    if provenance.get("thread_parallelism_enabled") is not True:
        blockers.append(f"{lane}_thread_parallelism_disabled")

    throughput = require_object(report, "throughput", lane)
    requirements = require_object(throughput, "headline_requirements", f"{lane}.throughput")
    require_exact_keys(
        requirements,
        HEADLINE_REQUIREMENT_KEYS,
        f"{lane}.throughput.headline_requirements",
    )
    for name, satisfied in requirements.items():
        if satisfied is not True:
            blockers.append(f"{lane}_requirement_{name}")
    if report["protocol"]["name"] != "functional":
        blockers.append(f"{lane}_nonfunctional_protocol")
    if throughput.get("headline_eligible") is not True:
        blockers.append(f"{lane}_report_not_headline_eligible")
    if report.get("evidence_class") != "verified_unprofiled" or report.get("profiled") is not False:
        blockers.append(f"{lane}_not_verified_unprofiled")
    return blockers


def validate_report(
    report: dict[str, Any],
    lane: str,
    workload: Workload,
    args: argparse.Namespace,
) -> tuple[tuple[str, int], list[str]]:
    if report.get("schema_version") != REPORT_SCHEMA_VERSION:
        raise MatrixError(f"{lane} report schema version is unsupported")
    if report.get("backend") != EXPECTED_BACKENDS[lane]:
        raise MatrixError(f"{lane} report identifies the wrong backend")
    protocol = require_object(report, "protocol", lane)
    if protocol != PROTOCOL_PRESETS[args.protocol]:
        raise MatrixError(
            f"{lane} report protocol descriptor does not match preset {args.protocol}"
        )

    reported_workload = require_object(report, "workload", lane)
    for key, expected in {"name": "wide_fibonacci", **workload.as_dict()}.items():
        if reported_workload.get(key) != expected:
            raise MatrixError(f"{lane} workload field {key} does not match the request")
    descriptor_digest = require_digest(
        reported_workload.get("descriptor_sha256"),
        f"{lane}.workload.descriptor_sha256",
    )
    if descriptor_digest != workload_descriptor_sha256(workload, args.protocol):
        raise MatrixError(f"{lane} workload descriptor digest is inconsistent")

    timing = require_object(report, "timing", lane)
    backend_init = require_finite_number(
        timing.get("backend_init_seconds"),
        f"{lane}.timing.backend_init_seconds",
    )
    if backend_init < 0:
        raise MatrixError(f"{lane}.timing.backend_init_seconds must be nonnegative")
    warmup_timings = require_list(timing, "warmup_request_seconds", f"{lane}.timing")
    if len(warmup_timings) != args.warmups:
        raise MatrixError(f"{lane} timing does not cover every requested warmup")
    for index, seconds in enumerate(warmup_timings):
        require_finite_number(
            seconds,
            f"{lane}.timing.warmup_request_seconds[{index}]",
            positive=True,
        )
    timing_samples = require_list(timing, "samples", f"{lane}.timing")
    if len(timing_samples) != args.samples:
        raise MatrixError(f"{lane} timing does not cover every requested sample")
    for index, sample in enumerate(timing_samples):
        if not isinstance(sample, dict):
            raise MatrixError(f"{lane}.timing.samples[{index}] must be an object")
        validate_sample_timing(sample, lane, index, workload)

    fingerprint = proof_fingerprint(report, lane, args.samples)
    blockers = headline_blockers(report, lane)
    if lane == "metal":
        blockers.extend(validate_metal_telemetry(report, args.warmups, args.samples))
    elif report.get("backend_telemetry") is not None:
        raise MatrixError("CPU report must not claim Metal backend telemetry")
    return fingerprint, blockers


def validate_pair(
    cpu: dict[str, Any],
    metal: dict[str, Any],
    cpu_fingerprint: tuple[str, int],
    metal_fingerprint: tuple[str, int],
) -> None:
    if cpu["schema_version"] != metal["schema_version"]:
        raise MatrixError("CPU and Metal report schemas differ")
    if cpu["protocol"] != metal["protocol"]:
        raise MatrixError("CPU and Metal protocol descriptors differ")
    if cpu["workload"] != metal["workload"]:
        raise MatrixError("CPU and Metal workload descriptors differ")
    if cpu_fingerprint != metal_fingerprint:
        raise MatrixError("CPU and Metal canonical proof digests differ")
    if cpu["provenance"] != metal["provenance"]:
        raise MatrixError("CPU and Metal provenance tuples differ")
