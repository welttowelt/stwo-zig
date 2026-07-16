#!/usr/bin/env python3
"""Merge diagnostic RISC-V and legacy Cairo Fibonacci backend reports."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import statistics
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_RISCV_REPORT = ROOT / "vectors/reports/riscv_fib_metal_vs_cpu_report.json"
DEFAULT_CAIRO_REPORTS = (
    ROOT / "vectors/reports/cairo_fib_metal_vs_simd_report.json",
    ROOT / "vectors/reports/cairo_fib_metal_vs_simd_large_report.json",
)
DEFAULT_OUTPUT = ROOT / "vectors/reports/fib_backend_unified_report.json"
DEFAULT_MARKDOWN = ROOT / "docs/fib-backend-comparison.md"
LANE_ORDER = (
    "riscv_zig_cpu",
    "riscv_zig_metal_hybrid",
    "cairo_rust_simd",
    "cairo_rust_metal_hybrid",
)
EXPECTED_CAIRO_PROTOCOL = {
    "security_bits": 96,
    "n_queries": 70,
    "pow_bits": 26,
    "fold_step": 3,
}
RISCV_SOUNDNESS_STATUS = "diagnostic_pcs_fri_only"
RISCV_DIAGNOSTIC_CLASSIFICATION = {
    "soundness_status": RISCV_SOUNDNESS_STATUS,
    "no_trace_dependent_air_constraints": True,
    "shared_verifier": True,
    "sound_proof_evidence": False,
    "production_evidence": False,
    "correctness_parity_evidence": False,
}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _mapping(value: object, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be an object")
    return value


def _list(value: object, label: str) -> list[Any]:
    if not isinstance(value, list):
        raise ValueError(f"{label} must be an array")
    return value


def _integer(value: object, label: str, *, positive: bool = False) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError(f"{label} must be an integer")
    if value < 0 or (positive and value == 0):
        qualifier = "positive " if positive else "non-negative "
        raise ValueError(f"{label} must be a {qualifier}integer")
    return value


def _number(value: object, label: str, *, positive: bool = False) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{label} must be a finite number")
    result = float(value)
    if not math.isfinite(result) or result < 0 or (positive and result == 0):
        qualifier = "positive " if positive else "non-negative "
        raise ValueError(f"{label} must be a finite {qualifier}number")
    return result


def _close(actual: float, expected: float, label: str) -> None:
    if not math.isclose(actual, expected, rel_tol=1e-9, abs_tol=1e-12):
        raise ValueError(f"{label} is inconsistent with raw samples")


def _validate_report_header(
    report: dict[str, Any],
    *,
    benchmark: str,
    schema_version: int,
) -> None:
    if report.get("benchmark") != benchmark:
        raise ValueError(f"expected {benchmark} report")
    if report.get("schema_version") != schema_version:
        raise ValueError(f"unsupported {benchmark} schema_version")
    if report.get("status") != "completed":
        raise ValueError(f"{benchmark} report is not completed")


def _validate_summary(
    lane: dict[str, Any],
    fields: tuple[str, ...],
    label: str,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    summary = _mapping(lane.get("summary"), f"{label}.summary")
    raw_samples = [
        _mapping(sample, f"{label}.raw_samples[{index}]")
        for index, sample in enumerate(_list(lane.get("raw_samples"), f"{label}.raw_samples"))
    ]
    if not raw_samples:
        raise ValueError(f"{label} has no raw samples")
    if _integer(summary.get("samples"), f"{label}.summary.samples", positive=True) != len(raw_samples):
        raise ValueError(f"{label} summary sample count mismatch")
    for field in fields:
        distribution = _mapping(summary.get(field), f"{label}.summary.{field}")
        observed = [_number(sample.get(field), f"{label}.{field}", positive=True) for sample in raw_samples]
        median = _number(distribution.get("median"), f"{label}.summary.{field}.median", positive=True)
        _close(median, statistics.median(observed), f"{label}.summary.{field}.median")
    return summary, raw_samples


def _validate_sizes(rows: list[dict[str, Any]], label: str) -> list[int]:
    sizes = [_integer(row.get("fib_n"), f"{label}.rows[{index}].fib_n", positive=True) for index, row in enumerate(rows)]
    if not sizes or sizes != sorted(sizes) or len(set(sizes)) != len(sizes):
        raise ValueError(f"{label} Fib N values must be unique and increasing")
    return sizes


def _validate_riscv_protocol(report: dict[str, Any]) -> dict[str, Any]:
    protocol = _mapping(report.get("protocol"), "RISC-V protocol")
    if protocol.get("hash") != "blake2s":
        raise ValueError("RISC-V protocol must use Blake2s")
    for field in ("log_blowup_factor", "fri_log_last_layer_degree_bound", "pow_bits"):
        _integer(protocol.get(field), f"RISC-V protocol.{field}")
    _integer(protocol.get("n_queries"), "RISC-V protocol.n_queries", positive=True)
    if _integer(protocol.get("fri_fold_step"), "RISC-V protocol.fri_fold_step", positive=True) != 1:
        raise ValueError("RISC-V report must explicitly record fold step 1")
    return protocol


def _validate_riscv_classification(report: dict[str, Any]) -> dict[str, Any]:
    for field, expected in RISCV_DIAGNOSTIC_CLASSIFICATION.items():
        if report.get(field) != expected or type(report.get(field)) is not type(expected):
            raise ValueError(f"RISC-V diagnostic classification mismatch for {field}")
    return dict(RISCV_DIAGNOSTIC_CLASSIFICATION)


def _validate_riscv_backends(report: dict[str, Any]) -> None:
    backends = _mapping(report.get("backends"), "RISC-V backends")
    if set(backends) != {"cpu", "metal"}:
        raise ValueError("RISC-V report must contain exactly CPU and Metal lanes")
    expected_labels = {
        "cpu": "Zig CPU ReleaseFast with auto-SIMD hot paths",
        "metal": "generic hybrid MetalProverEngine",
    }
    for name, expected_label in expected_labels.items():
        backend = _mapping(backends.get(name), f"RISC-V backends.{name}")
        if backend.get("label") != expected_label:
            raise ValueError(f"RISC-V {name} backend identity mismatch")
        if not isinstance(backend.get("binary"), str) or not backend["binary"]:
            raise ValueError(f"RISC-V {name} binary identity is missing")
        digest = backend.get("sha256")
        if not isinstance(digest, str) or len(digest) != 64:
            raise ValueError(f"RISC-V {name} binary SHA-256 is missing")


def _validate_cairo_protocol(report: dict[str, Any]) -> dict[str, Any]:
    protocol = _mapping(report.get("protocol"), "Cairo protocol")
    for field, expected in EXPECTED_CAIRO_PROTOCOL.items():
        if _integer(protocol.get(field), f"Cairo protocol.{field}", positive=True) != expected:
            raise ValueError(f"Cairo protocol mismatch for {field}")
    return protocol


def _riscv_lane(
    row: dict[str, Any],
    source_name: str,
    fib_n: int,
    cycles: int,
) -> dict[str, Any]:
    lane = _mapping(row.get(source_name), f"RISC-V fib({fib_n}).{source_name}")
    fields = (
        "prove_ms",
        "cli_total_ms",
        "process_wall_s",
        "prove_mhz",
        "e2e_mhz",
        "prove_fib_iterations_per_s",
        "e2e_fib_iterations_per_s",
    )
    summary, samples = _validate_summary(lane, fields, f"RISC-V fib({fib_n}).{source_name}")
    for sample in samples:
        if "proof_verified" in sample:
            raise ValueError(
                f"RISC-V fib({fib_n}).{source_name} contains ambiguous proof_verified evidence"
            )
        if sample.get("pcs_fri_accepted_by_shared_verifier") is not True:
            raise ValueError(
                f"RISC-V fib({fib_n}).{source_name} lacks shared-verifier PCS/FRI acceptance"
            )
        if sample.get("soundness_status") != RISCV_SOUNDNESS_STATUS:
            raise ValueError(f"RISC-V fib({fib_n}).{source_name} soundness status mismatch")
        if _integer(sample.get("fib_n"), "RISC-V sample fib_n", positive=True) != fib_n:
            raise ValueError("RISC-V sample Fib N mismatch")
        if _integer(sample.get("cycles"), "RISC-V sample cycles", positive=True) != cycles:
            raise ValueError("RISC-V sample cycle mismatch")
        prove_s = _number(sample.get("prove_ms"), "RISC-V sample prove_ms", positive=True) / 1000.0
        total_s = _number(sample.get("cli_total_ms"), "RISC-V sample cli_total_ms", positive=True) / 1000.0
        process_s = _number(sample.get("process_wall_s"), "RISC-V sample process_wall_s", positive=True)
        if total_s > process_s:
            raise ValueError("RISC-V CLI total exceeds fresh-process wall")
        _close(_number(sample.get("prove_mhz"), "RISC-V sample prove_mhz", positive=True), cycles / prove_s / 1e6, "RISC-V prove MHz")
        _close(_number(sample.get("e2e_mhz"), "RISC-V sample e2e_mhz", positive=True), cycles / process_s / 1e6, "RISC-V E2E MHz")
        _close(_number(sample.get("prove_fib_iterations_per_s"), "RISC-V prove Fib/s", positive=True), fib_n / prove_s, "RISC-V prove Fib/s")
        _close(_number(sample.get("e2e_fib_iterations_per_s"), "RISC-V E2E Fib/s", positive=True), fib_n / process_s, "RISC-V E2E Fib/s")

    return {
        "native_cycles": cycles,
        "prove_s": _number(summary["prove_ms"]["median"], "RISC-V prove median", positive=True) / 1000.0,
        "internal_total": {
            "seconds": _number(summary["cli_total_ms"]["median"], "RISC-V CLI total median", positive=True) / 1000.0,
            "measurement_kind": "direct_cli_timer",
            "directly_timed": True,
        },
        "fresh_process_wall_s": _number(summary["process_wall_s"]["median"], "RISC-V process median", positive=True),
        "native_prove_mhz": _number(summary["prove_mhz"]["median"], "RISC-V prove MHz median", positive=True),
        "native_end_to_end_mhz": _number(summary["e2e_mhz"]["median"], "RISC-V E2E MHz median", positive=True),
        "fib_prove_iterations_per_s": _number(summary["prove_fib_iterations_per_s"]["median"], "RISC-V prove Fib/s median", positive=True),
        "fib_end_to_end_iterations_per_s": _number(summary["e2e_fib_iterations_per_s"]["median"], "RISC-V E2E Fib/s median", positive=True),
        "diagnostic_artifacts_accepted": len(samples),
        **RISCV_DIAGNOSTIC_CLASSIFICATION,
        "eligible_for_sound_performance_ranking": False,
        "source_backend": source_name,
    }


def _cairo_backend_names(report: dict[str, Any]) -> tuple[str, str]:
    backends = _mapping(report.get("backends"), "Cairo backends")
    simd: list[str] = []
    metal: list[str] = []
    for name, encoded in backends.items():
        backend = _mapping(encoded, f"Cairo backends.{name}")
        identity = (backend.get("gpu_bench_backend"), backend.get("engine"), backend.get("acceleration"))
        if identity == ("simd", "legacy", "cpu_simd"):
            simd.append(name)
        elif identity == ("metal", "legacy", "apple_metal_gpu"):
            metal.append(name)
        else:
            raise ValueError(f"unsupported Cairo backend lane: {name}")
    if len(simd) != 1 or len(metal) != 1 or len(backends) != 2:
        raise ValueError("Cairo report must contain exactly one Rust SIMD and one hybrid Metal lane")
    return simd[0], metal[0]


def merge_cairo_reports(reports: list[dict[str, Any]]) -> dict[str, Any]:
    if not reports:
        raise ValueError("at least one Cairo report is required")
    consistency_fields = (
        "workload",
        "cycle_semantics",
        "protocol",
        "measurement",
        "artifacts",
        "backends",
        "environment",
    )
    merged_rows: dict[int, dict[str, Any]] = {}
    first = reports[0]
    for report_index, report in enumerate(reports):
        _validate_report_header(
            report,
            benchmark="cairo_fib_backend_compare",
            schema_version=1,
        )
        for field in consistency_fields:
            if report.get(field) != first.get(field):
                raise ValueError(f"Cairo report shard mismatch for {field}")
        rows = [
            _mapping(row, f"Cairo shard {report_index} rows[{row_index}]")
            for row_index, row in enumerate(
                _list(report.get("rows"), f"Cairo shard {report_index} rows")
            )
        ]
        for row in rows:
            fib_n = _integer(row.get("fib_n"), "Cairo shard Fib N", positive=True)
            if fib_n in merged_rows:
                raise ValueError(f"duplicate Cairo Fib N across report shards: {fib_n}")
            merged_rows[fib_n] = row
    merged = dict(first)
    merged["rows"] = [merged_rows[fib_n] for fib_n in sorted(merged_rows)]
    return merged


def _cairo_lane(
    row: dict[str, Any],
    source_name: str,
    fib_n: int,
    cycles: int,
    protocol: dict[str, Any],
) -> dict[str, Any]:
    backends = _mapping(row.get("backends"), f"Cairo fib({fib_n}).backends")
    lane = _mapping(backends.get(source_name), f"Cairo fib({fib_n}).{source_name}")
    fields = (
        "prove_s",
        "constructed_internal_total_s",
        "process_wall_s",
        "native_prove_mhz",
        "native_end_to_end_mhz",
        "fib_prove_iterations_per_s",
        "fib_end_to_end_iterations_per_s",
    )
    summary, samples = _validate_summary(lane, fields, f"Cairo fib({fib_n}).{source_name}")
    for sample in samples:
        if sample.get("proof_verified") is not True:
            raise ValueError(f"Cairo fib({fib_n}).{source_name} contains an unverified proof")
        if _integer(sample.get("fib_n"), "Cairo sample fib_n", positive=True) != fib_n:
            raise ValueError("Cairo sample Fib N mismatch")
        if _integer(sample.get("cycles"), "Cairo sample cycles", positive=True) != cycles:
            raise ValueError("Cairo sample cycle mismatch")
        if sample.get("protocol") != protocol:
            raise ValueError("Cairo sample protocol mismatch")
        prove_s = _number(sample.get("prove_s"), "Cairo sample prove_s", positive=True)
        total_s = _number(sample.get("constructed_internal_total_s"), "Cairo internal total", positive=True)
        process_s = _number(sample.get("process_wall_s"), "Cairo process wall", positive=True)
        if total_s > process_s:
            raise ValueError("Cairo constructed internal total exceeds fresh-process wall")
        _close(_number(sample.get("native_prove_mhz"), "Cairo prove MHz", positive=True), cycles / prove_s / 1e6, "Cairo prove MHz")
        _close(_number(sample.get("native_end_to_end_mhz"), "Cairo E2E MHz", positive=True), cycles / process_s / 1e6, "Cairo E2E MHz")
        _close(_number(sample.get("fib_prove_iterations_per_s"), "Cairo prove Fib/s", positive=True), fib_n / prove_s, "Cairo prove Fib/s")
        _close(_number(sample.get("fib_end_to_end_iterations_per_s"), "Cairo E2E Fib/s", positive=True), fib_n / process_s, "Cairo E2E Fib/s")

    return {
        "native_cycles": cycles,
        "prove_s": _number(summary["prove_s"]["median"], "Cairo prove median", positive=True),
        "internal_total": {
            "seconds": _number(summary["constructed_internal_total_s"]["median"], "Cairo internal total median", positive=True),
            "measurement_kind": "constructed_non_overlapping_phase_sum",
            "directly_timed": False,
        },
        "fresh_process_wall_s": _number(summary["process_wall_s"]["median"], "Cairo process median", positive=True),
        "native_prove_mhz": _number(summary["native_prove_mhz"]["median"], "Cairo prove MHz median", positive=True),
        "native_end_to_end_mhz": _number(summary["native_end_to_end_mhz"]["median"], "Cairo E2E MHz median", positive=True),
        "fib_prove_iterations_per_s": _number(summary["fib_prove_iterations_per_s"]["median"], "Cairo prove Fib/s median", positive=True),
        "fib_end_to_end_iterations_per_s": _number(summary["fib_end_to_end_iterations_per_s"]["median"], "Cairo E2E Fib/s median", positive=True),
        "proofs_verified": len(samples),
        "source_backend": source_name,
    }


def build_unified_report(
    riscv_report: dict[str, Any],
    cairo_report: dict[str, Any],
    source_reports: dict[str, Any] | None = None,
) -> dict[str, Any]:
    _validate_report_header(
        riscv_report,
        benchmark="riscv_fib_backend_compare",
        schema_version=3,
    )
    _validate_report_header(
        cairo_report,
        benchmark="cairo_fib_backend_compare",
        schema_version=1,
    )
    riscv_classification = _validate_riscv_classification(riscv_report)
    riscv_protocol = _validate_riscv_protocol(riscv_report)
    _validate_riscv_backends(riscv_report)
    cairo_protocol = _validate_cairo_protocol(cairo_report)
    simd_name, metal_name = _cairo_backend_names(cairo_report)

    riscv_rows = [
        _mapping(row, f"RISC-V rows[{index}]")
        for index, row in enumerate(_list(riscv_report.get("rows"), "RISC-V rows"))
    ]
    cairo_rows = [
        _mapping(row, f"Cairo rows[{index}]")
        for index, row in enumerate(_list(cairo_report.get("rows"), "Cairo rows"))
    ]
    riscv_sizes = _validate_sizes(riscv_rows, "RISC-V")
    cairo_sizes = _validate_sizes(cairo_rows, "Cairo")
    if riscv_sizes != cairo_sizes:
        raise ValueError("RISC-V and Cairo reports must contain identical Fib N values")

    rows: list[dict[str, Any]] = []
    for fib_n, riscv_row, cairo_row in zip(riscv_sizes, riscv_rows, cairo_rows, strict=True):
        riscv_cycles = 5 * fib_n - 3
        cairo_cycles = 7 * fib_n + 16
        if _integer(riscv_row.get("cycles"), "RISC-V row cycles", positive=True) != riscv_cycles:
            raise ValueError(f"RISC-V fib({fib_n}) does not satisfy 5*N-3 cycle semantics")
        if _integer(cairo_row.get("expected_cycles"), "Cairo expected_cycles", positive=True) != cairo_cycles:
            raise ValueError(f"Cairo fib({fib_n}) does not satisfy 7*N+16 cycle semantics")
        lanes = {
            "riscv_zig_cpu": _riscv_lane(riscv_row, "cpu", fib_n, riscv_cycles),
            "riscv_zig_metal_hybrid": _riscv_lane(riscv_row, "metal", fib_n, riscv_cycles),
            "cairo_rust_simd": _cairo_lane(cairo_row, simd_name, fib_n, cairo_cycles, cairo_protocol),
            "cairo_rust_metal_hybrid": _cairo_lane(cairo_row, metal_name, fib_n, cairo_cycles, cairo_protocol),
        }
        rows.append(
            {
                "fib_n": fib_n,
                "lanes": lanes,
                "within_vm_backend_speedup": {
                    "riscv_diagnostic_metal_over_cpu_auto_simd": {
                        "prove": lanes["riscv_zig_cpu"]["prove_s"]
                        / lanes["riscv_zig_metal_hybrid"]["prove_s"],
                        "fresh_process_total": lanes["riscv_zig_cpu"]["fresh_process_wall_s"]
                        / lanes["riscv_zig_metal_hybrid"]["fresh_process_wall_s"],
                        "soundness_status": RISCV_SOUNDNESS_STATUS,
                        "eligible_for_sound_performance_ranking": False,
                    },
                    "cairo_over_rust_simd": {
                        "prove": lanes["cairo_rust_simd"]["prove_s"]
                        / lanes["cairo_rust_metal_hybrid"]["prove_s"],
                        "fresh_process_total": lanes["cairo_rust_simd"]["fresh_process_wall_s"]
                        / lanes["cairo_rust_metal_hybrid"]["fresh_process_wall_s"],
                    },
                },
            }
        )

    return {
        "schema_version": 2,
        "benchmark": "fib_backend_unified_compare",
        "status": "completed",
        "supersedes_unified_schema_version": 1,
        "cross_vm_correctness_ranking_allowed": False,
        "cross_vm_performance_ranking_allowed": False,
        "ranking_refusal_reason": (
            "RISC-V is diagnostic PCS/FRI-only evidence with no trace-dependent AIR "
            "constraints and a shared verifier; it cannot be ranked as sound proof evidence"
        ),
        "evidence_classification": {
            "riscv": riscv_classification,
            "cairo": {
                "source_schema_version": 1,
                "compatibility_status": "legacy_schema_v1_preserved",
                "acceptance_status": "source_claimed_proof_verified",
                "production_evidence": False,
            },
        },
        "workload": "Fibonacci at identical requested N across native RISC-V and Cairo programs",
        "comparability": {
            "identical_fib_n": True,
            "native_cycle_semantics": {
                "riscv": "emitted RV32IM VM cycles; 5 * fib_n - 3",
                "cairo": "emitted Cairo opcode cycles; 7 * fib_n + 16",
            },
            "native_mhz": "backend-diagnostic only within the same VM program and protocol",
            "cross_vm_metric": "none; cross-VM correctness and performance ranking is refused",
            "fresh_process_wall": (
                "direct parent perf_counter around one diagnostic artifact subprocess for "
                "RISC-V or source-claimed verified proof subprocess for Cairo"
            ),
            "internal_total": "RISC-V is directly timed by the CLI; Cairo is a constructed non-overlapping phase sum",
        },
        "protocols": {
            "riscv": riscv_protocol,
            "cairo": cairo_protocol,
        },
        "lane_order": list(LANE_ORDER),
        "lanes": {
            "riscv_zig_cpu": {
                "label": "Zig RISC-V CPU with auto-SIMD hot paths",
                "vm": "riscv",
                "acceleration": "cpu_auto_simd",
                "hybrid": False,
                **riscv_classification,
                "eligible_for_sound_performance_ranking": False,
            },
            "riscv_zig_metal_hybrid": {
                "label": "Zig RISC-V hybrid MetalProverEngine",
                "vm": "riscv",
                "acceleration": "apple_metal_gpu",
                "hybrid": True,
                **riscv_classification,
                "eligible_for_sound_performance_ranking": False,
            },
            "cairo_rust_simd": {
                "label": "Rust Cairo SimdBackend",
                "vm": "cairo",
                "acceleration": "cpu_simd",
                "hybrid": False,
                "source_backend": simd_name,
                "source_schema_version": 1,
            },
            "cairo_rust_metal_hybrid": {
                "label": "Rust Cairo hybrid Metal backend",
                "vm": "cairo",
                "acceleration": "apple_metal_gpu",
                "hybrid": True,
                "source_backend": metal_name,
                "source_schema_version": 1,
            },
        },
        "source_reports": source_reports or {},
        "rows": rows,
    }


def _duration(seconds: float) -> str:
    if seconds < 1:
        return f"{seconds * 1000:.1f} ms"
    return f"{seconds:.3f} s"


def render_markdown(report: dict[str, Any]) -> str:
    lanes = _mapping(report.get("lanes"), "unified lanes")
    rows = _list(report.get("rows"), "unified rows")
    protocols = _mapping(report.get("protocols"), "unified protocols")
    riscv_protocol = _mapping(protocols.get("riscv"), "unified RISC-V protocol")
    cairo_protocol = _mapping(protocols.get("cairo"), "unified Cairo protocol")
    classification = _mapping(report.get("evidence_classification"), "evidence classification")
    riscv_classification = _mapping(classification.get("riscv"), "RISC-V classification")
    for field, expected in RISCV_DIAGNOSTIC_CLASSIFICATION.items():
        if riscv_classification.get(field) != expected:
            raise ValueError(f"unified RISC-V classification mismatch for {field}")
    if report.get("cross_vm_correctness_ranking_allowed") is not False:
        raise ValueError("unified report must refuse cross-VM correctness ranking")
    if report.get("cross_vm_performance_ranking_allowed") is not False:
        raise ValueError("unified report must refuse cross-VM performance ranking")

    riscv_acceptance_counts = sorted(
        {
            _integer(
                _mapping(_mapping(row, "unified row").get("lanes"), "unified row lanes")[
                    "riscv_zig_cpu"
                ]["diagnostic_artifacts_accepted"],
                "RISC-V diagnostic acceptance count",
                positive=True,
            )
            for row in rows
        }
    )
    cairo_proof_counts = sorted(
        {
            _integer(
                _mapping(_mapping(row, "unified row").get("lanes"), "unified row lanes")[
                    "cairo_rust_simd"
                ]["proofs_verified"],
                "Cairo verified proof count",
                positive=True,
            )
            for row in rows
        }
    )
    riscv_acceptance_count_text = "/".join(str(count) for count in riscv_acceptance_counts)
    cairo_proof_count_text = "/".join(str(count) for count in cairo_proof_counts)
    lines = [
        "# Fibonacci Backend Diagnostics",
        "",
        "**Cross-VM correctness and performance ranking is refused.** The RISC-V",
        "lane is diagnostic PCS/FRI-only evidence: it has no trace-dependent AIR",
        "constraints and both backends use the same Zig verifier. Its values do not",
        "prove RISC-V execution, the Fibonacci result, soundness parity, or production",
        "readiness.",
        "",
        "Identical requested Fib N does not establish equivalent execution or proof",
        "semantics. RISC-V emits `5*N-3` VM cycles and Cairo emits `7*N+16` opcode",
        "cycles. Native MHz and Fib iterations per second are reported only inside each",
        "VM's section as backend diagnostics; they are not a cross-VM ranking metric.",
        "",
        f"RISC-V uses {riscv_protocol['hash']}, blowup {riscv_protocol['log_blowup_factor']}, "
        f"FRI fold {riscv_protocol['fri_fold_step']}, PoW {riscv_protocol['pow_bits']}, and "
        f"{riscv_protocol['n_queries']} queries. Cairo uses {cairo_protocol['security_bits']}-bit "
        f"security, FRI fold {cairo_protocol['fold_step']}, PoW {cairo_protocol['pow_bits']}, "
        f"and {cairo_protocol['n_queries']} queries. Cairo inputs retain their legacy schema-v1 "
        "source-claimed verification status; this schema-v2 output supersedes the old unified",
        "schema without upgrading either source's evidence class.",
        "",
        f"Each RISC-V cell is the median of {riscv_acceptance_count_text} shared-verifier "
        f"diagnostic artifact processes. Each Cairo cell contains {cairo_proof_count_text} "
        "source-claimed verified proof process.",
        "",
        "## RISC-V Diagnostic PCS/FRI Throughput",
        "",
        "These tables compare only the RISC-V CPU and Metal implementations of the same",
        "incomplete proof relation.",
        "",
        "### Prove Only",
        "",
        "| Fib N | Lane | Native cycles | Prove | Native MHz | Fib Miter/s |",
        "| ---: | :--- | ---: | ---: | ---: | ---: |",
    ]
    for row_value in rows:
        row = _mapping(row_value, "unified row")
        fib_n = _integer(row.get("fib_n"), "unified fib_n", positive=True)
        row_lanes = _mapping(row.get("lanes"), "unified row lanes")
        for lane_name in ("riscv_zig_cpu", "riscv_zig_metal_hybrid"):
            lane = _mapping(row_lanes.get(lane_name), f"unified lane {lane_name}")
            metadata = _mapping(lanes.get(lane_name), f"lane metadata {lane_name}")
            lines.append(
                f"| {fib_n:,} | {metadata['label']} | {lane['native_cycles']:,} | "
                f"{_duration(float(lane['prove_s']))} | {float(lane['native_prove_mhz']):.3f} | "
                f"{float(lane['fib_prove_iterations_per_s']) / 1e6:.3f} |"
            )
    lines.extend(
        [
            "",
            "### Fresh-Process Total",
            "",
            "| Fib N | Lane | Internal total | Kind | Total wall | Native MHz | Fib Miter/s |",
            "| ---: | :--- | ---: | :--- | ---: | ---: | ---: |",
        ]
    )
    for row_value in rows:
        row = _mapping(row_value, "unified row")
        fib_n = _integer(row.get("fib_n"), "unified fib_n", positive=True)
        row_lanes = _mapping(row.get("lanes"), "unified row lanes")
        for lane_name in ("riscv_zig_cpu", "riscv_zig_metal_hybrid"):
            lane = _mapping(row_lanes.get(lane_name), f"unified lane {lane_name}")
            metadata = _mapping(lanes.get(lane_name), f"lane metadata {lane_name}")
            internal = _mapping(lane.get("internal_total"), f"{lane_name} internal total")
            kind = "direct" if internal.get("directly_timed") is True else "constructed"
            lines.append(
                f"| {fib_n:,} | {metadata['label']} | {_duration(float(internal['seconds']))} | "
                f"{kind} | {_duration(float(lane['fresh_process_wall_s']))} | "
                f"{float(lane['native_end_to_end_mhz']):.3f} | "
                f"{float(lane['fib_end_to_end_iterations_per_s']) / 1e6:.3f} |"
            )
    lines.extend(
        [
            "",
            "### Diagnostic Metal Speedup",
            "",
            "A value above `1.0x` means Metal is faster than the RISC-V CPU lane for",
            "this diagnostic PCS/FRI relation. It is not sound-proof evidence.",
            "",
            "| Fib N | Prove | Fresh-process total |",
            "| ---: | ---: | ---: |",
        ]
    )
    for row_value in rows:
        row = _mapping(row_value, "unified row")
        fib_n = _integer(row.get("fib_n"), "unified fib_n", positive=True)
        speedups = _mapping(row.get("within_vm_backend_speedup"), "within-VM backend speedup")
        riscv = _mapping(
            speedups.get("riscv_diagnostic_metal_over_cpu_auto_simd"),
            "RISC-V diagnostic Metal speedup",
        )
        lines.append(
            f"| {fib_n:,} | {float(riscv['prove']):.3f}x | "
            f"{float(riscv['fresh_process_total']):.3f}x |"
        )
    lines.extend(
        [
            "",
            "## Cairo Legacy Schema-v1 Source Results",
            "",
            "These inputs retain their source-claimed proof verification status. They are",
            "shown separately and are not ranked against the diagnostic RISC-V lane.",
            "",
            "### Prove Only",
            "",
            "| Fib N | Lane | Native cycles | Prove | Native MHz | Fib Miter/s |",
            "| ---: | :--- | ---: | ---: | ---: | ---: |",
        ]
    )
    for row_value in rows:
        row = _mapping(row_value, "unified row")
        fib_n = _integer(row.get("fib_n"), "unified fib_n", positive=True)
        row_lanes = _mapping(row.get("lanes"), "unified row lanes")
        for lane_name in ("cairo_rust_simd", "cairo_rust_metal_hybrid"):
            lane = _mapping(row_lanes.get(lane_name), f"unified lane {lane_name}")
            metadata = _mapping(lanes.get(lane_name), f"lane metadata {lane_name}")
            lines.append(
                f"| {fib_n:,} | {metadata['label']} | {lane['native_cycles']:,} | "
                f"{_duration(float(lane['prove_s']))} | {float(lane['native_prove_mhz']):.3f} | "
                f"{float(lane['fib_prove_iterations_per_s']) / 1e6:.3f} |"
            )
    lines.extend(
        [
            "",
            "### Fresh-Process Total",
            "",
            "| Fib N | Lane | Internal total | Kind | Total wall | Native MHz | Fib Miter/s |",
            "| ---: | :--- | ---: | :--- | ---: | ---: | ---: |",
        ]
    )
    for row_value in rows:
        row = _mapping(row_value, "unified row")
        fib_n = _integer(row.get("fib_n"), "unified fib_n", positive=True)
        row_lanes = _mapping(row.get("lanes"), "unified row lanes")
        for lane_name in ("cairo_rust_simd", "cairo_rust_metal_hybrid"):
            lane = _mapping(row_lanes.get(lane_name), f"unified lane {lane_name}")
            metadata = _mapping(lanes.get(lane_name), f"lane metadata {lane_name}")
            internal = _mapping(lane.get("internal_total"), f"{lane_name} internal total")
            kind = "direct" if internal.get("directly_timed") is True else "constructed"
            lines.append(
                f"| {fib_n:,} | {metadata['label']} | {_duration(float(internal['seconds']))} | "
                f"{kind} | {_duration(float(lane['fresh_process_wall_s']))} | "
                f"{float(lane['native_end_to_end_mhz']):.3f} | "
                f"{float(lane['fib_end_to_end_iterations_per_s']) / 1e6:.3f} |"
            )
    lines.extend(
        [
            "",
            "### Cairo Metal Speedup",
            "",
            "| Fib N | Prove | Fresh-process total |",
            "| ---: | ---: | ---: |",
        ]
    )
    for row_value in rows:
        row = _mapping(row_value, "unified row")
        fib_n = _integer(row.get("fib_n"), "unified fib_n", positive=True)
        speedups = _mapping(row.get("within_vm_backend_speedup"), "within-VM backend speedup")
        cairo = _mapping(speedups.get("cairo_over_rust_simd"), "Cairo Metal speedup")
        lines.append(
            f"| {fib_n:,} | {float(cairo['prove']):.3f}x | "
            f"{float(cairo['fresh_process_total']):.3f}x |"
        )
    lines.append("")
    return "\n".join(lines)


def _load_report(path: Path, label: str) -> dict[str, Any]:
    if not path.is_file():
        raise ValueError(f"missing {label}: {path}")
    try:
        value = json.loads(path.read_text())
    except json.JSONDecodeError as error:
        raise ValueError(f"invalid JSON in {label}: {path}") from error
    return _mapping(value, label)


def _write_atomic(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        with temporary.open("x") as output:
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--riscv-report", type=Path, default=DEFAULT_RISCV_REPORT)
    parser.add_argument(
        "--cairo-report",
        type=Path,
        action="append",
        help="repeat for disjoint, schema-identical Cairo report shards",
    )
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--markdown", type=Path, default=DEFAULT_MARKDOWN)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    riscv_path = args.riscv_report.expanduser().resolve()
    cairo_paths = tuple(
        path.expanduser().resolve()
        for path in (args.cairo_report or DEFAULT_CAIRO_REPORTS)
    )
    output = args.output.expanduser().resolve()
    markdown = args.markdown.expanduser().resolve()
    if output == markdown:
        raise SystemExit("JSON and Markdown outputs must be different paths")
    try:
        riscv_report = _load_report(riscv_path, "riscv report")
        cairo_reports = [
            _load_report(path, f"cairo report shard {index}")
            for index, path in enumerate(cairo_paths)
        ]
        cairo_report = merge_cairo_reports(cairo_reports)
        unified = build_unified_report(
            riscv_report,
            cairo_report,
            {
                "riscv": {"path": str(riscv_path), "sha256": sha256_file(riscv_path)},
                "cairo": [
                    {"path": str(path), "sha256": sha256_file(path)} for path in cairo_paths
                ],
            },
        )
        encoded = json.dumps(unified, indent=2) + "\n"
        rendered_markdown = render_markdown(unified)
        _write_atomic(output, encoded)
        _write_atomic(markdown, rendered_markdown)
    except (OSError, ValueError) as error:
        raise SystemExit(str(error)) from error
    sys.stdout.write(encoded)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
