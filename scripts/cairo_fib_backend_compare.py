#!/usr/bin/env python3
"""Benchmark verified Cairo Fib proofs through Rust gpu_bench backends."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import statistics
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, NamedTuple


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CAIRO_ROOT = Path.home() / "code/personal/stwo-cairo/stwo_cairo_prover"
DEFAULT_GPU_BENCH = DEFAULT_CAIRO_ROOT / "target/release/gpu_bench"
DEFAULT_COMPILED_JSON = (
    Path.home() / "code/personal/stwo-cairo/gpu_benchmarks/fib/compiled.json"
)
DEFAULT_SIZES = [25_000, 50_000, 100_000, 250_000, 500_000, 1_000_000, 2_000_000]
DEFAULT_BACKEND = "rust-simd=simd:legacy"
BACKEND_NAME_RE = re.compile(r"[a-z0-9][a-z0-9_-]*\Z")
SUPPORTED_BACKEND_ENGINES = {
    "simd": frozenset({"legacy", "gpu-native"}),
    "cuda": frozenset({"legacy", "gpu-native"}),
    "metal": frozenset({"legacy"}),
}
BACKEND_ACCELERATION = {
    "simd": "cpu_simd",
    "cuda": "nvidia_cuda_gpu",
    "metal": "apple_metal_gpu",
}
EXPECTED_PROTOCOL = {
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
        "STWO_METAL_JIT_LOG",
        "STWO_METAL_DISABLE_JIT",
        "STWO_METAL_FRI_PACK_LEAVES_MODE",
        "STWO_METAL_PROFILE_MERKLE",
        "STWO_METAL_WITNESS_UPLOAD_MODE",
        "STWO_FORCE_EXTEND_EVAL_MODE",
        "STWO_STORE_COEFFS",
        "STWO_VRAM_PHASES",
        "STWO_WITNESS_JIT_SELFTEST",
    }
)


class BackendSpec(NamedTuple):
    name: str
    backend: str
    engine: str


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def expected_cycles(fib_n: int) -> int:
    if fib_n <= 0:
        raise ValueError("Fib N must be positive")
    return 7 * fib_n + 16


def parse_backend_spec(encoded: str) -> BackendSpec:
    name, separator, implementation = encoded.partition("=")
    if not separator or not BACKEND_NAME_RE.fullmatch(name):
        raise ValueError("backend must use NAME=BACKEND[:ENGINE] with a lowercase name")
    backend, engine_separator, engine = implementation.partition(":")
    if not engine_separator:
        engine = "legacy"
    if backend not in SUPPORTED_BACKEND_ENGINES:
        raise ValueError(f"unsupported gpu_bench backend: {backend}")
    if engine not in SUPPORTED_BACKEND_ENGINES[backend]:
        raise ValueError(f"unsupported gpu_bench backend/engine: {backend}/{engine}")
    return BackendSpec(name=name, backend=backend, engine=engine)


def parse_backend_specs(values: list[str] | None) -> list[BackendSpec]:
    specs = [parse_backend_spec(value) for value in (values or [DEFAULT_BACKEND])]
    names = [spec.name for spec in specs]
    if len(set(names)) != len(names):
        raise ValueError("backend names must be unique")
    return specs


def benchmark_environment(
    source: dict[str, str] | None = None,
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
    compiled_json: Path,
    fib_n: int,
    backend: BackendSpec,
    proofs_per_process: int,
) -> list[str]:
    if proofs_per_process < 2:
        raise ValueError("proofs per process must be at least 2 to measure a warm proof")
    return [
        str(binary),
        "--program",
        str(compiled_json),
        "--iterations",
        str(fib_n),
        "--backend",
        backend.backend,
        "--engine",
        backend.engine,
        "--reps",
        str(proofs_per_process),
        "--reuse-input",
    ]


def _number(
    value: object,
    label: str,
    *,
    positive: bool = False,
) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{label} must be a finite number")
    result = float(value)
    if not math.isfinite(result) or result < 0 or (positive and result == 0):
        qualifier = "positive " if positive else "non-negative "
        raise ValueError(f"{label} must be a finite {qualifier}number")
    return result


def _integer(value: object, label: str, *, positive: bool = False) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError(f"{label} must be an integer")
    if value < 0 or (positive and value == 0):
        qualifier = "positive " if positive else "non-negative "
        raise ValueError(f"{label} must be a {qualifier}integer")
    return value


def _number_list(
    value: object,
    label: str,
    *,
    expected_length: int,
    positive: bool = False,
) -> list[float]:
    if not isinstance(value, list) or len(value) != expected_length:
        raise ValueError(f"{label} must contain exactly {expected_length} samples")
    return [
        _number(sample, f"{label}[{index}]", positive=positive)
        for index, sample in enumerate(value)
    ]


def _require_rounded_match(actual: float, expected: float, label: str, samples: int = 1) -> None:
    # gpu_bench emits millisecond-rounded phase samples and totals.
    tolerance = 0.00051 * max(1, samples)
    if not math.isclose(actual, expected, rel_tol=0.0, abs_tol=tolerance):
        raise ValueError(f"gpu_bench {label} is inconsistent with its sample vector")


def _main_records(stdout: str) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for line in stdout.splitlines():
        stripped = line.strip()
        if not stripped.startswith("{"):
            continue
        try:
            value = json.loads(stripped)
        except json.JSONDecodeError as error:
            raise ValueError("gpu_bench emitted malformed JSON") from error
        if isinstance(value, dict) and {"cycle_count", "prove_s_cold"} <= value.keys():
            records.append(value)
    return records


def parse_gpu_bench_output(
    stdout: str,
    fib_n: int,
    backend: BackendSpec,
    compiled_json: Path,
    proofs_per_process: int,
) -> dict[str, Any]:
    records = _main_records(stdout)
    if len(records) != 1:
        raise ValueError(f"expected exactly one gpu_bench proof record, found {len(records)}")
    record = records[0]

    if _integer(record.get("n"), "n", positive=True) != fib_n:
        raise ValueError("gpu_bench Fib N does not match the request")
    if record.get("backend") != backend.backend or record.get("engine") != backend.engine:
        raise ValueError("gpu_bench backend identity does not match the requested lane")
    if record.get("pie_n_steps") is not None or record.get("bootloader_overhead_pct") is not None:
        raise ValueError("gpu_bench returned PIE geometry for a compiled-program request")
    program = record.get("program")
    if not isinstance(program, str) or Path(program).resolve() != compiled_json.resolve():
        raise ValueError("gpu_bench program identity does not match compiled.json")

    cycles = _integer(record.get("cycle_count"), "cycle_count", positive=True)
    if cycles != expected_cycles(fib_n):
        raise ValueError(
            f"Cairo Fib geometry mismatch: expected {expected_cycles(fib_n)} cycles, got {cycles}"
        )
    for name, expected in EXPECTED_PROTOCOL.items():
        if _integer(record.get(name), name, positive=True) != expected:
            raise ValueError(f"gpu_bench protocol mismatch for {name}")

    requested = _integer(record.get("proofs_requested"), "proofs_requested", positive=True)
    verified = _integer(record.get("proofs_verified"), "proofs_verified", positive=True)
    if requested != proofs_per_process or verified != proofs_per_process:
        raise ValueError("gpu_bench did not produce and verify every requested proof")
    if record.get("all_proofs_verified") is not True:
        raise ValueError("gpu_bench did not report all_proofs_verified=true")
    if record.get("proof_byte_equal") is not True:
        raise ValueError("gpu_bench repetitions were not byte-identical")

    vm_s = _number(record.get("vm_s"), "vm_s")
    adapt_s = _number(record.get("adapt_s"), "adapt_s")
    prove_samples = _number_list(
        record.get("prove_s_samples"),
        "prove_s_samples",
        expected_length=proofs_per_process,
        positive=True,
    )
    cold_prove_s = prove_samples[0]
    warm_samples = prove_samples[1:]
    warm_prove_s = statistics.median(warm_samples)
    prove_s_total = sum(prove_samples)
    _require_rounded_match(
        _number(record.get("prove_s_cold"), "prove_s_cold", positive=True),
        cold_prove_s,
        "prove_s_cold",
    )
    _require_rounded_match(
        _number(record.get("prove_s_warm_median"), "prove_s_warm_median", positive=True),
        warm_prove_s,
        "prove_s_warm_median",
        len(warm_samples),
    )
    _require_rounded_match(
        _number(record.get("prove_s_total"), "prove_s_total", positive=True),
        prove_s_total,
        "prove_s_total",
        proofs_per_process,
    )

    verify_ms_samples = _number_list(
        record.get("verify_ms_samples"),
        "verify_ms_samples",
        expected_length=proofs_per_process,
    )
    verify_s_samples = [sample / 1000.0 for sample in verify_ms_samples]
    verify_s_total = sum(verify_s_samples)
    _require_rounded_match(
        _number(record.get("verify_ms_total"), "verify_ms_total") / 1000.0,
        verify_s_total,
        "verify_ms_total",
        proofs_per_process,
    )
    _require_rounded_match(
        _number(record.get("verify_ms"), "verify_ms") / 1000.0,
        verify_s_samples[0],
        "verify_ms",
    )
    proof_kb = _number(record.get("proof_kb"), "proof_kb", positive=True)
    execute_adapt_s = vm_s + adapt_s
    resident_batch_internal_total_s = execute_adapt_s + prove_s_total + verify_s_total

    return {
        "fib_n": fib_n,
        "cycles": cycles,
        "proofs_per_process": proofs_per_process,
        "vm_s": vm_s,
        "adapt_s": adapt_s,
        "execute_adapt_s": execute_adapt_s,
        "cold_prove_s": cold_prove_s,
        "warm_prove_s": warm_prove_s,
        "prove_s_total": prove_s_total,
        "prove_s_samples": prove_samples,
        "verify_s_total": verify_s_total,
        "verify_s_per_proof": verify_s_total / proofs_per_process,
        "verify_s_samples": verify_s_samples,
        "resident_batch_internal_total_s": resident_batch_internal_total_s,
        "resident_batch_internal_total": {
            "seconds": resident_batch_internal_total_s,
            "measurement_kind": "constructed_non_overlapping_phase_sum",
            "components": ["vm_s", "adapt_s", "prove_s_total", "verify_s_total"],
            "directly_timed": False,
        },
        "cold_native_mhz": cycles / cold_prove_s / 1_000_000.0,
        "warm_native_mhz": cycles / warm_prove_s / 1_000_000.0,
        "cold_fib_iterations_per_s": fib_n / cold_prove_s,
        "warm_fib_iterations_per_s": fib_n / warm_prove_s,
        "proof_kb": proof_kb,
        "proof_verified": verified == requested,
        "proofs_verified": verified,
        "proof_byte_equal": True,
        "verification_evidence": "gpu_bench called verify_cairo successfully for every repetition",
        "protocol": dict(EXPECTED_PROTOCOL),
        "gpu_bench_reported_mhz": _number(record.get("mhz"), "mhz"),
        "gpu_bench_record": record,
    }


def run_sample(
    binary: Path,
    compiled_json: Path,
    fib_n: int,
    backend: BackendSpec,
    proofs_per_process: int,
    timeout_s: float,
    environment: dict[str, str],
) -> dict[str, Any]:
    command = build_command(binary, compiled_json, fib_n, backend, proofs_per_process)
    started = time.perf_counter()
    completed = subprocess.run(
        command,
        cwd=ROOT,
        env=environment,
        capture_output=True,
        text=True,
        timeout=timeout_s,
        check=False,
    )
    process_wall_s = time.perf_counter() - started
    if completed.returncode != 0:
        output = completed.stdout + completed.stderr
        raise RuntimeError(
            f"gpu_bench exited {completed.returncode}: {' '.join(command)}\n{output[-4000:]}"
        )
    parsed = parse_gpu_bench_output(
        completed.stdout,
        fib_n,
        backend,
        compiled_json,
        proofs_per_process,
    )
    process_overhead_s = process_wall_s - parsed["prove_s_total"] - parsed["verify_s_total"]
    if process_overhead_s < -0.01:
        raise RuntimeError("gpu_bench subprocess wall time is shorter than timed proof phases")
    process_overhead_s = max(0.0, process_overhead_s)
    parsed.update(
        {
            "process_wall_s": process_wall_s,
            "amortized_process_wall_s": process_wall_s / proofs_per_process,
            "process_overhead_s": process_overhead_s,
            "sustained_native_mhz": (
                parsed["cycles"] * proofs_per_process / process_wall_s / 1_000_000.0
            ),
            "sustained_fib_iterations_per_s": fib_n * proofs_per_process / process_wall_s,
            "command": command,
            "returncode": completed.returncode,
            "stdout": completed.stdout,
            "stderr": completed.stderr,
        }
    )
    return parsed


def percentile(values: list[float], fraction: float) -> float:
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


SUMMARY_FIELDS = (
    "vm_s",
    "adapt_s",
    "execute_adapt_s",
    "cold_prove_s",
    "warm_prove_s",
    "prove_s_total",
    "verify_s_total",
    "verify_s_per_proof",
    "resident_batch_internal_total_s",
    "process_wall_s",
    "amortized_process_wall_s",
    "process_overhead_s",
    "cold_native_mhz",
    "warm_native_mhz",
    "sustained_native_mhz",
    "cold_fib_iterations_per_s",
    "warm_fib_iterations_per_s",
    "sustained_fib_iterations_per_s",
)


def summarize(samples: list[dict[str, Any]]) -> dict[str, Any]:
    if not samples:
        raise ValueError("cannot summarize an empty sample set")
    summary: dict[str, Any] = {"samples": len(samples)}
    for field in SUMMARY_FIELDS:
        values = [float(sample[field]) for sample in samples]
        summary[field] = {
            "median": statistics.median(values),
            "p25": percentile(values, 0.25),
            "p75": percentile(values, 0.75),
            "min": min(values),
            "max": max(values),
        }
    return summary


def geometry_key(sample: dict[str, Any]) -> tuple[Any, ...]:
    protocol = sample["protocol"]
    return (
        sample["fib_n"],
        sample["cycles"],
        sample["proof_kb"],
        protocol["security_bits"],
        protocol["n_queries"],
        protocol["pow_bits"],
        protocol["fold_step"],
    )


def collect_report(
    *,
    binary: Path,
    compiled_json: Path,
    sizes: list[int],
    backends: list[BackendSpec],
    proofs_per_process: int,
    warmups: int,
    repeats: int,
    timeout_s: float,
    pause_s: float,
    environment: dict[str, str],
    sample_runner: Any = run_sample,
    sleep: Any = time.sleep,
) -> dict[str, Any]:
    if repeats <= 0 or warmups < 0 or not sizes or any(size <= 0 for size in sizes):
        raise ValueError("sizes and repeats must be positive and warmups non-negative")
    if proofs_per_process < 2:
        raise ValueError("proofs per process must be at least 2")
    if len(set(sizes)) != len(sizes):
        raise ValueError("Fib sizes must be unique")
    if not backends:
        raise ValueError("at least one backend is required")
    backend_names = [backend.name for backend in backends]
    if len(set(backend_names)) != len(backend_names):
        raise ValueError("backend names must be unique")

    samples: dict[int, dict[str, list[dict[str, Any]]]] = {
        size: {backend.name: [] for backend in backends} for size in sizes
    }
    geometry: dict[int, tuple[Any, ...]] = {}
    total_passes = warmups + repeats
    for pass_index in range(total_passes):
        measured = pass_index >= warmups
        pass_sizes = sizes if pass_index % 2 == 0 else list(reversed(sizes))
        pass_backends = backends if pass_index % 2 == 0 else list(reversed(backends))
        for fib_n in pass_sizes:
            for backend in pass_backends:
                print(
                    f"pass={pass_index} measured={measured} fib={fib_n} backend={backend.name}",
                    file=sys.stderr,
                    flush=True,
                )
                sample = sample_runner(
                    binary,
                    compiled_json,
                    fib_n,
                    backend,
                    proofs_per_process,
                    timeout_s,
                    environment,
                )
                key = geometry_key(sample)
                if fib_n in geometry and geometry[fib_n] != key:
                    raise RuntimeError(f"backend geometry mismatch for Cairo fib({fib_n})")
                geometry[fib_n] = key
                if sample.get("proof_verified") is not True:
                    raise RuntimeError(f"unverified proof for Cairo fib({fib_n})")
                if measured:
                    samples[fib_n][backend.name].append(sample)
                if pause_s > 0:
                    sleep(pause_s)

    rows: list[dict[str, Any]] = []
    for fib_n in sizes:
        rows.append(
            {
                "fib_n": fib_n,
                "expected_cycles": expected_cycles(fib_n),
                "backends": {
                    backend.name: {
                        "summary": summarize(samples[fib_n][backend.name]),
                        "raw_samples": samples[fib_n][backend.name],
                    }
                    for backend in backends
                },
            }
        )

    return {
        "schema_version": 2,
        "benchmark": "cairo_fib_backend_compare",
        "status": "completed",
        "workload": "compiled Cairo recursive Fibonacci program",
        "cycle_semantics": "emitted Cairo opcode cycles; expected 7 * fib_n + 16",
        "protocol": dict(EXPECTED_PROTOCOL),
        "measurement": {
            "warmups": warmups,
            "repeats": repeats,
            "proofs_per_process": proofs_per_process,
            "pause_s": pause_s,
            "process_model": "fresh gpu_bench process per sample; each process executes one cold proof followed by resident warm proofs over a reused adapted input",
            "execution_policy": "strictly sequential; backend and size order reverse on each alternate pass, while a single pass uses the declared order",
            "proof_acceptance": "verify_cairo must accept every repetition; repeated proof bytes must be identical; the subprocess must exit zero",
            "cold_scope": "first proof in each fresh process, including backend runtime JIT and in-process cache construction charged inside the prover timer",
            "warm_scope": "median of subsequent proofs in the same process over --reuse-input; excludes VM execution and adaptation",
            "sustained_scope": "all verified proofs divided by subprocess launch-through-exit wall time",
            "end_to_end_scope": "one resident multi-proof subprocess from launch through verified exit",
            "internal_total": {
                "field": "resident_batch_internal_total_s",
                "measurement_kind": "constructed_non_overlapping_phase_sum",
                "components": ["vm_s", "adapt_s", "prove_s_total", "verify_s_total"],
                "directly_timed": False,
                "excludes": [
                    "process startup and teardown",
                    "compiled program read and parse",
                    "input clone and prewarm",
                    "proof size calculation and JSON reporting",
                ],
            },
        },
        "artifacts": {
            "gpu_bench": {"path": str(binary), "sha256": sha256_file(binary)},
            "compiled_json": {"path": str(compiled_json), "sha256": sha256_file(compiled_json)},
        },
        "backends": {
            backend.name: {
                "gpu_bench_backend": backend.backend,
                "engine": backend.engine,
                "acceleration": BACKEND_ACCELERATION[backend.backend],
            }
            for backend in backends
        },
        "environment": {
            "RAYON_NUM_THREADS": environment.get("RAYON_NUM_THREADS"),
            "metal_witness_upload_mode": "compiled_platform_default",
            "metal_fri_pack_leaves_mode": "compiled_platform_default",
        },
        "limitations": [
            "Native Cairo cycle MHz is comparable only between backends proving this exact Cairo program and protocol.",
            "The warm service metric reuses one adapted input and therefore does not include raw Cairo VM execution or adaptation.",
            "The sustained metric includes cold startup once per resident subprocess and amortizes it over proofs_per_process proofs.",
            f"This report has {repeats} measured outer pass(es); its warm statistic is the intra-process median of {proofs_per_process - 1} resident proof(s) per sample.",
            "STWO_BENCH_TRACE is scrubbed from headline runs because span aggregation perturbs measured execution.",
            "gpu_bench rounds its internal phase timings to milliseconds.",
            "No result is synthesized; every reported lane is an executed gpu_bench backend.",
            "The Metal lane is accepted only as metal/legacy, matching gpu_bench's implemented dispatch table.",
        ],
        "rows": rows,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sizes", type=int, nargs="+", default=DEFAULT_SIZES)
    parser.add_argument("--warmups", type=int, default=0)
    parser.add_argument("--repeats", type=int, default=1)
    parser.add_argument("--proofs-per-process", type=int, default=3)
    parser.add_argument("--timeout-s", type=float, default=600.0)
    parser.add_argument("--pause-s", type=float, default=0.0)
    parser.add_argument("--rayon-threads", type=int)
    parser.add_argument("--gpu-bench", type=Path, default=DEFAULT_GPU_BENCH)
    parser.add_argument("--compiled-json", type=Path, default=DEFAULT_COMPILED_JSON)
    parser.add_argument(
        "--backend",
        action="append",
        metavar="NAME=BACKEND[:ENGINE]",
        help=f"repeatable gpu_bench lane (default: {DEFAULT_BACKEND})",
    )
    parser.add_argument("--output", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not math.isfinite(args.timeout_s) or args.timeout_s <= 0:
        raise SystemExit("timeout must be positive")
    if not math.isfinite(args.pause_s) or args.pause_s < 0:
        raise SystemExit("pause must be non-negative")
    binary = args.gpu_bench.expanduser().resolve()
    compiled_json = args.compiled_json.expanduser().resolve()
    for path, label in ((binary, "gpu_bench"), (compiled_json, "compiled Cairo Fib JSON")):
        if not path.is_file():
            raise SystemExit(f"missing {label}: {path}")
    try:
        backends = parse_backend_specs(args.backend)
        environment = benchmark_environment(rayon_threads=args.rayon_threads)
        report = collect_report(
            binary=binary,
            compiled_json=compiled_json,
            sizes=args.sizes,
            backends=backends,
            proofs_per_process=args.proofs_per_process,
            warmups=args.warmups,
            repeats=args.repeats,
            timeout_s=args.timeout_s,
            pause_s=args.pause_s,
            environment=environment,
        )
    except (ValueError, RuntimeError) as error:
        raise SystemExit(str(error)) from error
    rendered = json.dumps(report, indent=2) + "\n"
    if args.output is not None:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered)
    sys.stdout.write(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
