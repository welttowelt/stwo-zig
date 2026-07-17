"""Bounded orchestration and report construction for Cairo program proofs."""

from __future__ import annotations

import math
import statistics
import time
from pathlib import Path
from typing import Any, Callable

from .catalog import ProgramSpec
from .evidence import LANES, Lane, benchmark_environment, run_sample
from .provenance import (
    ProvenanceError,
    load_compile_manifest,
    runtime_provenance,
    sha256_file,
    validate_compile_manifest,
)


MIN_HEADLINE_WARMUPS = 1
MIN_HEADLINE_REPEATS = 3
MIN_HEADLINE_PROOFS_PER_PROCESS = 3
MAX_OUTER_PASSES = 10
MAX_PROOFS_PER_PROCESS = 10
MAX_TOTAL_PROOFS = 1_000
MAX_TIMEOUT_S = 3_600.0
MAX_PAUSE_S = 60.0

SUMMARY_FIELDS = (
    "vm_s",
    "adapt_s",
    "execute_adapt_s",
    "cold_prove_s",
    "warm_prove_s",
    "prove_s_total",
    "verify_s_total",
    "process_wall_s",
    "amortized_process_wall_s",
    "process_overhead_s",
    "resident_batch_internal_total_s",
    "cold_cycle_mhz",
    "warm_cycle_mhz",
    "sustained_cycle_mhz",
    "cold_size_units_per_s",
    "warm_size_units_per_s",
    "sustained_size_units_per_s",
)


def _percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    weight = position - lower
    return ordered[lower] * (1.0 - weight) + ordered[upper] * weight


def summarize(samples: list[dict[str, Any]]) -> dict[str, Any]:
    if not samples:
        raise ValueError("cannot summarize an empty sample set")
    result: dict[str, Any] = {"samples": len(samples)}
    for field in SUMMARY_FIELDS:
        values = [float(sample[field]) for sample in samples]
        median = statistics.median(values)
        result[field] = {
            "median": median,
            "p25": _percentile(values, 0.25),
            "p75": _percentile(values, 0.75),
            "min": min(values),
            "max": max(values),
            "mad": statistics.median(abs(value - median) for value in values),
        }
    return result


def _validate_measurement(
    *,
    cases: list[tuple[ProgramSpec, tuple[int, ...]]],
    lanes: list[Lane],
    warmups: int,
    repeats: int,
    proofs_per_process: int,
    timeout_s: float,
    pause_s: float,
) -> None:
    if warmups < 0 or repeats <= 0 or warmups + repeats > MAX_OUTER_PASSES:
        raise ValueError(f"warmups + repeats must be in [1, {MAX_OUTER_PASSES}]")
    if not lanes or len({lane.key for lane in lanes}) != len(lanes):
        raise ValueError("Rust backend lanes must be non-empty and unique")
    if proofs_per_process < 2 or proofs_per_process > MAX_PROOFS_PER_PROCESS:
        raise ValueError(
            f"proofs per process must be in [2, {MAX_PROOFS_PER_PROCESS}]"
        )
    if not math.isfinite(timeout_s) or timeout_s <= 0 or timeout_s > MAX_TIMEOUT_S:
        raise ValueError(f"timeout must be in (0, {MAX_TIMEOUT_S}] seconds")
    if not math.isfinite(pause_s) or pause_s < 0 or pause_s > MAX_PAUSE_S:
        raise ValueError(f"pause must be in [0, {MAX_PAUSE_S}] seconds")
    rows = sum(len(sizes) for _, sizes in cases)
    total_proofs = rows * len(lanes) * (warmups + repeats) * proofs_per_process
    if total_proofs > MAX_TOTAL_PROOFS:
        raise ValueError(
            f"benchmark requests too many proofs ({total_proofs} > {MAX_TOTAL_PROOFS})"
        )


def _measurement_blockers(
    warmups: int, repeats: int, proofs_per_process: int
) -> list[str]:
    blockers: list[str] = []
    if warmups < MIN_HEADLINE_WARMUPS:
        blockers.append("insufficient_outer_warmups")
    if repeats < MIN_HEADLINE_REPEATS:
        blockers.append("insufficient_measured_repeats")
    if proofs_per_process < MIN_HEADLINE_PROOFS_PER_PROCESS:
        blockers.append("insufficient_resident_proofs_per_process")
    return blockers


def _geometry_key(sample: dict[str, Any]) -> tuple[Any, ...]:
    record = sample["gpu_bench_record"]
    return (
        sample["program"],
        sample["size"],
        sample["cycles"],
        sample["proof_kb"],
        record["security_bits"],
        record["n_queries"],
        record["pow_bits"],
        record["fold_step"],
    )


def collect_report(
    *,
    manifest_path: Path,
    gpu_bench: Path,
    gpu_bench_repo: Path,
    rust_stwo_repo: Path,
    cases: list[tuple[ProgramSpec, tuple[int, ...]]],
    lanes: list[Lane],
    warmups: int,
    repeats: int,
    proofs_per_process: int,
    timeout_s: float,
    pause_s: float,
    rayon_threads: int | None,
    allow_non_headline: bool,
    sample_runner: Callable[..., dict[str, Any]] = run_sample,
    sleep: Callable[[float], None] = time.sleep,
) -> dict[str, Any]:
    _validate_measurement(
        cases=cases,
        lanes=lanes,
        warmups=warmups,
        repeats=repeats,
        proofs_per_process=proofs_per_process,
        timeout_s=timeout_s,
        pause_s=pause_s,
    )
    requested_programs = [program for program, _ in cases]
    manifest_sha256 = sha256_file(manifest_path.resolve())
    compile_manifest = load_compile_manifest(manifest_path)
    artifacts, compile_blockers = validate_compile_manifest(
        compile_manifest, requested_programs
    )
    runtime, runtime_blockers = runtime_provenance(
        gpu_bench=gpu_bench,
        gpu_bench_repo=gpu_bench_repo,
        rust_stwo_repo=rust_stwo_repo,
    )
    measurement_blockers = _measurement_blockers(
        warmups, repeats, proofs_per_process
    )
    blockers = sorted(set(compile_blockers + runtime_blockers + measurement_blockers))
    if blockers and not allow_non_headline:
        raise ProvenanceError("headline provenance rejected: " + ", ".join(blockers))

    environment = benchmark_environment(rayon_threads=rayon_threads)
    samples: dict[tuple[str, int, str], list[dict[str, Any]]] = {
        (program.slug, size, lane.key): []
        for program, sizes in cases
        for size in sizes
        for lane in lanes
    }
    geometry: dict[tuple[str, int], tuple[Any, ...]] = {}
    requests = [
        (program, size, lane)
        for program, sizes in cases
        for size in sizes
        for lane in lanes
    ]
    for pass_index in range(warmups + repeats):
        measured = pass_index >= warmups
        ordered = requests if pass_index % 2 == 0 else list(reversed(requests))
        for program, size, lane in ordered:
            sample = sample_runner(
                binary=gpu_bench,
                compiled=artifacts[program.slug],
                program=program,
                size=size,
                lane=lane,
                proofs_per_process=proofs_per_process,
                timeout_s=timeout_s,
                environment=environment,
            )
            if sample.get("all_proofs_verified") is not True:
                raise RuntimeError("unverified proof escaped the gpu_bench evidence gate")
            statement = (program.slug, size)
            key = _geometry_key(sample)
            if statement in geometry and geometry[statement] != key:
                raise RuntimeError(
                    f"Rust SIMD/Metal proof geometry mismatch for {program.slug}({size})"
                )
            geometry[statement] = key
            if measured:
                samples[(program.slug, size, lane.key)].append(sample)
            if pause_s:
                sleep(pause_s)

    _, final_compile_blockers = validate_compile_manifest(
        compile_manifest, requested_programs
    )
    final_runtime, final_runtime_blockers = runtime_provenance(
        gpu_bench=gpu_bench,
        gpu_bench_repo=gpu_bench_repo,
        rust_stwo_repo=rust_stwo_repo,
    )
    final_blockers = final_compile_blockers + final_runtime_blockers
    if sha256_file(manifest_path.resolve()) != manifest_sha256:
        final_blockers.append("compile_manifest_changed_during_measurement")
    if final_runtime != runtime:
        final_blockers.append("runtime_provenance_changed_during_measurement")
    blockers = sorted(set(blockers + final_blockers))
    if final_blockers and not allow_non_headline:
        raise ProvenanceError(
            "provenance changed during measurement: "
            + ", ".join(sorted(set(final_blockers)))
        )

    rows: list[dict[str, Any]] = []
    for program, sizes in cases:
        for size in sizes:
            rows.append(
                {
                    "program": program.as_record(),
                    "size": size,
                    "emitted_cycle_count": geometry[(program.slug, size)][2],
                    "cycle_count_policy": (
                        "exact_known_gate"
                        if program.expected_cycle_count(size) is not None
                        else "positive_gpu_bench_emitted_count"
                    ),
                    "lanes": {
                        lane.key: {
                            "identity": lane.as_record(),
                            "summary": summarize(samples[(program.slug, size, lane.key)]),
                            "raw_samples": samples[(program.slug, size, lane.key)],
                        }
                        for lane in lanes
                    },
                }
            )

    provenance = {
        "headline_eligible": not blockers,
        "blockers": blockers,
        "compile_manifest": {
            "path": str(manifest_path.resolve()),
            "sha256": manifest_sha256,
            "compiler": compile_manifest["compiler"],
            "source_repository": compile_manifest["source_repository"],
            "programs": {
                program.slug: compile_manifest["programs"][program.slug]
                for program in requested_programs
            },
        },
        "runtime": runtime,
    }
    return {
        "schema_version": 1,
        "benchmark": "canonical_cairo_program_rust_backend_matrix",
        "status": "completed",
        "headline_eligible": not blockers,
        "backend_scope": (
            "Rust stwo-cairo SIMD and Rust stwo-cairo Metal; this report contains "
            "no Zig backend measurements"
        ),
        "measurement": {
            "warmups": warmups,
            "repeats": repeats,
            "proofs_per_process": proofs_per_process,
            "pause_s": pause_s,
            "execution_policy": (
                "strictly sequential fresh processes; complete request order reverses "
                "on alternate passes"
            ),
            "process_model": (
                "each process executes one cold proof followed by resident warm proofs "
                "over --reuse-input"
            ),
            "proof_acceptance": (
                "Rust verify_cairo accepts every proof and resident repetitions are "
                "byte-identical"
            ),
            "cold_scope": "first proof in each fresh gpu_bench process",
            "warm_scope": "median of later proofs in the same resident process",
            "process_wall_scope": "subprocess launch through verified process exit",
            "process_wall_directly_timed": True,
            "cycle_numerator": "positive gpu_bench-emitted Cairo opcode cycles",
        },
        "provenance": provenance,
        "lanes": {lane.key: lane.as_record() for lane in lanes},
        "rows": rows,
        "limitations": [
            "These lanes use Rust stwo-cairo and cannot be cited as stwo-zig performance.",
            "Byte equality is checked across repetitions within a lane, not across lanes.",
            "Warm proof time excludes Cairo VM execution and adaptation because input is reused.",
            "Process-wall throughput includes one cold initialization per resident subprocess.",
            "Program size units differ; cycle MHz is comparable only for the same statement.",
        ],
    }


def resolve_lanes(values: list[str] | None) -> list[Lane]:
    selected = values or ["simd", "metal"]
    unknown = [value for value in selected if value not in LANES]
    if unknown:
        raise ValueError(f"unknown Rust stwo-cairo lane: {', '.join(unknown)}")
    if len(set(selected)) != len(selected):
        raise ValueError("Rust stwo-cairo lanes must be unique")
    return [LANES[value] for value in selected]
