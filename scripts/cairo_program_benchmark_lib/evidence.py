"""Rust stwo-cairo backend execution and proof-evidence validation."""

from __future__ import annotations

import math
import os
import statistics
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

from .catalog import ProgramSpec


PROTOCOL = {
    "security_bits": 96,
    "n_queries": 70,
    "pow_bits": 26,
    "fold_step": 3,
}

PROOF_BYPASS_ENVIRONMENT = frozenset(
    {
        "STWO_ADAPT_ONLY",
        "STWO_BENCH_TRACE",
        "STWO_CAIRO_LOW_MEMORY",
        "STWO_CAIRO_STREAM_LDE",
        "STWO_CUDA_ASYNC_SPINE",
        "STWO_CUDA_DEVICE_INTERACTION",
        "STWO_CUDA_MEM_COUNT_FEEDS",
        "STWO_CUDA_PIPELINED_COMMIT",
        "STWO_CUDA_STREAM_FANOUT",
        "STWO_CUDA_STREAM_LEAF_COMMIT",
        "STWO_CUDA_WITNESS_EDGES",
        "STWO_CUDA_WITNESS_JIT_PROVE",
        "STWO_DIET_REBUILD_PREPROCESSED",
        "STWO_DEVICE_INTERACTION_SELFTEST",
        "STWO_DUMP_INPUT",
        "STWO_DUMP_PROOF",
        "STWO_DUMP_PROOF_JSON",
        "STWO_DUMP_STWZCPI",
        "STWO_FORCE_EXTEND_EVAL_MODE",
        "STWO_METAL_DISABLE_JIT",
        "STWO_METAL_FRI_PACK_LEAVES_MODE",
        "STWO_METAL_JIT_LOG",
        "STWO_METAL_PROFILE_MERKLE",
        "STWO_METAL_WITNESS_UPLOAD_MODE",
        "STWO_STORE_COEFFS",
        "STWO_VRAM_PHASES",
        "STWO_WITNESS_JIT_SELFTEST",
    }
)


@dataclass(frozen=True)
class Lane:
    key: str
    label: str
    gpu_bench_backend: str
    acceleration: str
    engine: str = "legacy"

    def as_record(self) -> dict[str, object]:
        return {
            "label": self.label,
            "implementation": "Rust stwo-cairo",
            "gpu_bench_backend": self.gpu_bench_backend,
            "engine": self.engine,
            "acceleration": self.acceleration,
            "is_zig_backend": False,
        }


LANES = {
    "simd": Lane(
        key="simd",
        label="Rust stwo-cairo SIMD",
        gpu_bench_backend="simd",
        acceleration="CPU SIMD",
    ),
    "metal": Lane(
        key="metal",
        label="Rust stwo-cairo Metal",
        gpu_bench_backend="metal",
        acceleration="Apple Metal GPU",
    ),
}


class EvidenceError(RuntimeError):
    """gpu_bench did not produce the complete verified evidence contract."""


def benchmark_environment(
    source: dict[str, str] | None = None,
    *,
    rayon_threads: int | None = None,
) -> dict[str, str]:
    environment = dict(os.environ if source is None else source)
    for name in PROOF_BYPASS_ENVIRONMENT:
        environment.pop(name, None)
    if rayon_threads is not None:
        if rayon_threads <= 0:
            raise ValueError("Rayon thread count must be positive")
        environment["RAYON_NUM_THREADS"] = str(rayon_threads)
    return environment


def build_command(
    binary: Path,
    compiled: Path,
    size: int,
    lane: Lane,
    proofs_per_process: int,
) -> list[str]:
    if proofs_per_process < 2:
        raise ValueError("proofs per process must be at least 2")
    return [
        str(binary),
        "--program",
        str(compiled),
        "--iterations",
        str(size),
        "--backend",
        lane.gpu_bench_backend,
        "--engine",
        lane.engine,
        "--reps",
        str(proofs_per_process),
        "--reuse-input",
    ]


def _number(value: object, label: str, *, positive: bool = False) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise EvidenceError(f"{label} must be a finite number")
    result = float(value)
    if not math.isfinite(result) or result < 0 or (positive and result == 0):
        qualifier = "positive" if positive else "non-negative"
        raise EvidenceError(f"{label} must be a finite {qualifier} number")
    return result


def _integer(value: object, label: str, *, positive: bool = False) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise EvidenceError(f"{label} must be an integer")
    if value < 0 or (positive and value == 0):
        qualifier = "positive" if positive else "non-negative"
        raise EvidenceError(f"{label} must be a {qualifier} integer")
    return value


def _samples(
    value: object,
    label: str,
    *,
    expected_length: int,
    positive: bool = False,
) -> list[float]:
    if not isinstance(value, list) or len(value) != expected_length:
        raise EvidenceError(f"{label} must contain exactly {expected_length} samples")
    return [
        _number(sample, f"{label}[{index}]", positive=positive)
        for index, sample in enumerate(value)
    ]


def _rounded_match(actual: float, expected: float, label: str, count: int = 1) -> None:
    tolerance = 0.00051 * max(1, count)
    if not math.isclose(actual, expected, rel_tol=0.0, abs_tol=tolerance):
        raise EvidenceError(f"gpu_bench {label} is inconsistent with its sample vector")


def _main_records(stdout: str) -> list[dict[str, Any]]:
    import json

    records: list[dict[str, Any]] = []
    for line in stdout.splitlines():
        stripped = line.strip()
        if not stripped.startswith("{"):
            continue
        try:
            value = json.loads(stripped)
        except json.JSONDecodeError as error:
            raise EvidenceError("gpu_bench emitted malformed JSON") from error
        if isinstance(value, dict) and {"cycle_count", "prove_s_cold"} <= value.keys():
            records.append(value)
    return records


def parse_gpu_bench_output(
    stdout: str,
    *,
    program: ProgramSpec,
    size: int,
    lane: Lane,
    compiled: Path,
    proofs_per_process: int,
) -> dict[str, Any]:
    program.validate_size(size)
    records = _main_records(stdout)
    if len(records) != 1:
        raise EvidenceError(f"expected one gpu_bench proof record, found {len(records)}")
    record = records[0]
    if _integer(record.get("n"), "n", positive=True) != size:
        raise EvidenceError("gpu_bench size does not match the request")
    if record.get("backend") != lane.gpu_bench_backend:
        raise EvidenceError("gpu_bench backend does not match the Rust lane")
    if record.get("engine") != "legacy" or lane.engine != "legacy":
        raise EvidenceError("Cairo program matrix accepts only Rust legacy engine proofs")
    recorded_program = record.get("program")
    if not isinstance(recorded_program, str):
        raise EvidenceError("gpu_bench program must be a path")
    if Path(recorded_program).resolve() != compiled.resolve():
        raise EvidenceError("gpu_bench compiled program does not match the request")
    if record.get("pie_n_steps") is not None:
        raise EvidenceError("gpu_bench returned PIE geometry for a Cairo program")

    cycles = _integer(record.get("cycle_count"), "cycle_count", positive=True)
    expected_cycles = program.expected_cycle_count(size)
    if expected_cycles is not None and cycles != expected_cycles:
        raise EvidenceError(
            f"{program.slug} exact cycle gate failed: {cycles} != {expected_cycles}"
        )
    for name, expected in PROTOCOL.items():
        if _integer(record.get(name), name, positive=True) != expected:
            raise EvidenceError(f"gpu_bench protocol mismatch for {name}")

    requested = _integer(record.get("proofs_requested"), "proofs_requested", positive=True)
    verified = _integer(record.get("proofs_verified"), "proofs_verified", positive=True)
    if requested != proofs_per_process or verified != requested:
        raise EvidenceError("Rust verify_cairo did not verify every requested proof")
    if record.get("all_proofs_verified") is not True:
        raise EvidenceError("gpu_bench did not report all_proofs_verified=true")
    if record.get("proof_byte_equal") is not True:
        raise EvidenceError("resident repetitions were not byte-identical")

    vm_s = _number(record.get("vm_s"), "vm_s")
    adapt_s = _number(record.get("adapt_s"), "adapt_s")
    prove_samples = _samples(
        record.get("prove_s_samples"),
        "prove_s_samples",
        expected_length=proofs_per_process,
        positive=True,
    )
    verify_ms_samples = _samples(
        record.get("verify_ms_samples"),
        "verify_ms_samples",
        expected_length=proofs_per_process,
    )
    verify_samples = [value / 1000.0 for value in verify_ms_samples]
    cold_s = prove_samples[0]
    warm_s = statistics.median(prove_samples[1:])
    prove_total_s = sum(prove_samples)
    verify_total_s = sum(verify_samples)
    _rounded_match(_number(record.get("prove_s_cold"), "prove_s_cold"), cold_s, "cold")
    _rounded_match(
        _number(record.get("prove_s_warm_median"), "prove_s_warm_median"),
        warm_s,
        "warm median",
        proofs_per_process - 1,
    )
    _rounded_match(
        _number(record.get("prove_s_total"), "prove_s_total"),
        prove_total_s,
        "prove total",
        proofs_per_process,
    )
    _rounded_match(
        _number(record.get("verify_ms_total"), "verify_ms_total") / 1000.0,
        verify_total_s,
        "verify total",
        proofs_per_process,
    )
    proof_kb = _number(record.get("proof_kb"), "proof_kb", positive=True)
    return {
        "program": program.slug,
        "size": size,
        "size_unit": program.size_unit,
        "cycles": cycles,
        "expected_cycles": expected_cycles,
        "cycle_gate": "exact" if expected_cycles is not None else "emitted_positive",
        "lane": lane.key,
        "lane_label": lane.label,
        "proofs_per_process": proofs_per_process,
        "vm_s": vm_s,
        "adapt_s": adapt_s,
        "execute_adapt_s": vm_s + adapt_s,
        "cold_prove_s": cold_s,
        "warm_prove_s": warm_s,
        "prove_s_total": prove_total_s,
        "prove_s_samples": prove_samples,
        "verify_s_total": verify_total_s,
        "verify_s_samples": verify_samples,
        "cold_cycle_mhz": cycles / cold_s / 1_000_000.0,
        "warm_cycle_mhz": cycles / warm_s / 1_000_000.0,
        "cold_size_units_per_s": size / cold_s,
        "warm_size_units_per_s": size / warm_s,
        "proof_kb": proof_kb,
        "proofs_verified": verified,
        "all_proofs_verified": True,
        "proof_byte_equal_within_process": True,
        "verification_oracle": "Rust stwo-cairo verify_cairo",
        "gpu_bench_record": record,
    }


def run_sample(
    *,
    binary: Path,
    compiled: Path,
    program: ProgramSpec,
    size: int,
    lane: Lane,
    proofs_per_process: int,
    timeout_s: float,
    environment: dict[str, str],
    runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
    clock: Callable[[], float] = time.perf_counter,
) -> dict[str, Any]:
    command = build_command(binary, compiled, size, lane, proofs_per_process)
    started = clock()
    completed = runner(
        command,
        cwd=binary.parent,
        env=environment,
        capture_output=True,
        text=True,
        timeout=timeout_s,
        check=False,
    )
    process_wall_s = clock() - started
    if completed.returncode != 0:
        output = completed.stdout + completed.stderr
        raise EvidenceError(
            f"gpu_bench exited {completed.returncode}: {' '.join(command)}\n{output[-4000:]}"
        )
    sample = parse_gpu_bench_output(
        completed.stdout,
        program=program,
        size=size,
        lane=lane,
        compiled=compiled,
        proofs_per_process=proofs_per_process,
    )
    measured_s = sample["prove_s_total"] + sample["verify_s_total"]
    if process_wall_s + 0.01 < measured_s:
        raise EvidenceError("subprocess wall time is shorter than its proof evidence")
    process_overhead_s = max(0.0, process_wall_s - measured_s)
    sample.update(
        {
            "process_wall_s": process_wall_s,
            "amortized_process_wall_s": process_wall_s / proofs_per_process,
            "process_overhead_s": process_overhead_s,
            "sustained_cycle_mhz": (
                sample["cycles"] * proofs_per_process / process_wall_s / 1_000_000.0
            ),
            "sustained_size_units_per_s": size * proofs_per_process / process_wall_s,
            "resident_batch_internal_total_s": (
                sample["execute_adapt_s"]
                + sample["prove_s_total"]
                + sample["verify_s_total"]
            ),
            "command": command,
        }
    )
    return sample
