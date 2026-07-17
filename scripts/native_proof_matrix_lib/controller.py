"""Sequential alternating-lane orchestration for Native proof matrices."""

from __future__ import annotations

import argparse
import os
import statistics
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .artifacts import (
    atomic_write_json,
    output_dir_lock,
    prepare_output_dir,
    require_binary,
    require_unprofiled_environment,
    run_lane,
    sha256_file,
)
from .contract import validate_pair, validate_proof_artifact, validate_report
from .model import (
    LANES,
    MAX_COMMITTED_TRACE_CELLS,
    MAX_LOG_ROWS,
    MAX_MATRIX_ROWS,
    MAX_SEQUENCE_LEN,
    MAX_TOTAL_REQUEST_CELLS,
    SUMMARY_PROTOCOL,
    SUMMARY_SCHEMA_VERSION,
    MatrixError,
    Workload,
)


def numeric_summary(values: list[float]) -> dict[str, float]:
    median = statistics.median(values)
    return {
        "median": median,
        "min": min(values),
        "max": max(values),
        "mad": statistics.median([abs(value - median) for value in values]),
    }


def lane_metrics(
    report: dict[str, Any],
    workload: Workload,
) -> dict[str, dict[str, float]]:
    samples = report["timing"]["samples"]
    metrics = {
        field: numeric_summary([float(sample[field]) for sample in samples])
        for field in (
            "input_seconds",
            "prove_seconds",
            "proof_encode_seconds",
            "verify_seconds",
            "request_seconds",
            "row_mhz",
            "committed_mcells_per_second",
        )
    }
    metrics["backend_init_seconds"] = numeric_summary(
        [float(report["timing"]["backend_init_seconds"])]
    )
    metrics["request_row_mhz"] = numeric_summary(
        [workload.rows / float(sample["request_seconds"]) / 1_000_000.0 for sample in samples]
    )
    return metrics


def comparison_metrics(
    cpu: dict[str, dict[str, float]],
    metal: dict[str, dict[str, float]],
) -> dict[str, float]:
    return {
        "metal_prove_time_speedup": (
            cpu["prove_seconds"]["median"] / metal["prove_seconds"]["median"]
        ),
        "metal_request_time_speedup": (
            cpu["request_seconds"]["median"] / metal["request_seconds"]["median"]
        ),
        "metal_row_mhz_speedup": (
            metal["row_mhz"]["median"] / cpu["row_mhz"]["median"]
        ),
        "metal_request_row_mhz_speedup": (
            metal["request_row_mhz"]["median"] / cpu["request_row_mhz"]["median"]
        ),
        "metal_committed_mcells_speedup": (
            metal["committed_mcells_per_second"]["median"]
            / cpu["committed_mcells_per_second"]["median"]
        ),
    }


def relative_to_output(path: Path, output_dir: Path) -> str:
    return str(path.relative_to(output_dir))


def summarize_lane(
    execution: dict[str, Any],
    output_dir: Path,
    fingerprint: tuple[str, int],
    workload: Workload,
) -> dict[str, Any]:
    report = execution["report"]
    artifact = execution["proof_artifact"]
    return {
        "display_name": "Zig CPU/SIMD" if execution["lane"] == "cpu" else "Zig Metal",
        "backend": report["backend"],
        "command": execution["command"],
        "process_wall_seconds": execution["process_wall_seconds"],
        "stdout_artifact": relative_to_output(execution["stdout_path"], output_dir),
        "stdout_sha256": sha256_file(execution["stdout_path"]),
        "stderr_artifact": relative_to_output(execution["stderr_path"], output_dir),
        "stderr_sha256": sha256_file(execution["stderr_path"]),
        "proof": {
            "sha256": fingerprint[0],
            "bytes": fingerprint[1],
            "verified_samples": report["proof"]["verified_samples"],
            "all_samples_byte_identical": report["proof"]["all_samples_byte_identical"],
        },
        "proof_artifact": {
            "path": relative_to_output(artifact["path"], output_dir),
            "bytes": artifact["bytes"],
            "sha256": artifact["sha256"],
            "proof_bytes": artifact["proof_bytes"],
            "proof_sha256": artifact["proof_sha256"],
        },
        "metrics": lane_metrics(report, workload),
        "session": report["session"],
        "backend_telemetry": report.get("backend_telemetry"),
    }


def run_matrix(args: argparse.Namespace) -> dict[str, Any]:
    require_unprofiled_environment(os.environ)
    binaries = {
        "cpu": require_binary(args.cpu_bin, "cpu"),
        "metal": require_binary(args.metal_bin, "metal"),
    }
    binary_hashes = {lane: sha256_file(binary) for lane, binary in binaries.items()}
    output_dir = args.output_dir.resolve()
    with output_dir_lock(output_dir):
        prepare_output_dir(output_dir)
        return _run_matrix_locked(args, binaries, binary_hashes, output_dir)


def _run_matrix_locked(
    args: argparse.Namespace,
    binaries: dict[str, Path],
    binary_hashes: dict[str, str],
    output_dir: Path,
) -> dict[str, Any]:
    total_lanes = len(args.workloads) * len(LANES)
    completed_lanes = 0
    result_rows: list[dict[str, Any]] = []
    matrix_provenance: dict[str, Any] | None = None

    for row_index, workload in enumerate(args.workloads):
        lane_order = list(LANES if row_index % 2 == 0 else reversed(LANES))
        artifact_dir = output_dir / f"row-{row_index:03d}-{workload.slug}"
        executions: dict[str, dict[str, Any]] = {}
        for lane in lane_order:
            executions[lane] = run_lane(
                lane,
                binaries[lane],
                workload,
                args,
                artifact_dir,
            )
            if sha256_file(binaries[lane]) != binary_hashes[lane]:
                raise MatrixError(f"{lane} benchmark binary changed during the matrix")
            completed_lanes += 1
            if args.cooldown_seconds > 0 and completed_lanes < total_lanes:
                time.sleep(args.cooldown_seconds)

        fingerprints: dict[str, tuple[str, int]] = {}
        blockers: list[str] = []
        for lane in LANES:
            fingerprint, lane_blockers = validate_report(
                executions[lane]["report"],
                lane,
                workload,
                args,
            )
            fingerprints[lane] = fingerprint
            blockers.extend(lane_blockers)
            validate_proof_artifact(
                executions[lane]["report"],
                lane,
                workload,
                args,
                executions[lane]["proof_artifact"],
                fingerprint,
            )
        validate_pair(
            executions["cpu"]["report"],
            executions["metal"]["report"],
            fingerprints["cpu"],
            fingerprints["metal"],
        )
        row_provenance = executions["cpu"]["report"]["provenance"]
        if matrix_provenance is None:
            matrix_provenance = row_provenance
        elif row_provenance != matrix_provenance:
            raise MatrixError("provenance tuple changed between matrix rows")

        lane_summaries = {
            lane: summarize_lane(
                executions[lane],
                output_dir,
                fingerprints[lane],
                workload,
            )
            for lane in LANES
        }
        unique_blockers = sorted(set(blockers))
        result_rows.append(
            {
                "index": row_index,
                "workload": workload.as_dict(),
                "descriptor_sha256": executions["cpu"]["report"]["workload"]["descriptor_sha256"],
                "lane_order": lane_order,
                "proof_digest_sha256": fingerprints["cpu"][0],
                "proof_bytes": fingerprints["cpu"][1],
                "proof_parity": True,
                "headline_eligible": not unique_blockers,
                "headline_blockers": unique_blockers,
                "lanes": lane_summaries,
                "speedup": comparison_metrics(
                    lane_summaries["cpu"]["metrics"],
                    lane_summaries["metal"]["metrics"],
                ),
            }
        )

    document = {
        "schema_version": SUMMARY_SCHEMA_VERSION,
        "protocol": SUMMARY_PROTOCOL,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "correctness_scope": {
            "classification": "zig_cross_backend_parity",
            "cpu_metal_canonical_proof_equality": True,
            "pinned_rust_stwo_oracle_checked": False,
            "final_correctness_oracle": "pinned Rust Stwo; outside this controller",
        },
        "configuration": {
            "proof_protocol": args.protocol,
            "warmups_per_lane": args.warmups,
            "samples_per_lane": args.samples,
            "cooldown_seconds": args.cooldown_seconds,
            "timeout_seconds": args.timeout_seconds,
            "execution": "sequential_alternating_lane_order",
            "bounds": {
                "max_matrix_rows": MAX_MATRIX_ROWS,
                "max_log_rows": MAX_LOG_ROWS,
                "max_sequence_len": MAX_SEQUENCE_LEN,
                "max_committed_trace_cells_per_row": MAX_COMMITTED_TRACE_CELLS,
                "max_total_request_cells": MAX_TOTAL_REQUEST_CELLS,
            },
            "binaries": {
                lane: {"path": str(binary), "sha256": binary_hashes[lane]}
                for lane, binary in binaries.items()
            },
            "provenance": matrix_provenance,
        },
        "summary": {
            "rows": len(result_rows),
            "headline_rows": sum(row["headline_eligible"] for row in result_rows),
            "all_rows_headline_eligible": all(
                row["headline_eligible"] for row in result_rows
            ),
            "all_proofs_verified_and_byte_identical": True,
            "all_cross_backend_proofs_identical": True,
        },
        "rows": result_rows,
    }
    atomic_write_json(output_dir / "summary.json", document)
    return document
