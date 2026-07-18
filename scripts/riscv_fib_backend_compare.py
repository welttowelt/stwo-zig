#!/usr/bin/env python3
"""Compare diagnostic RISC-V Fib PCS/FRI throughput on CPU and Metal."""

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
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SIZES = [25_000, 50_000, 100_000, 250_000, 500_000, 1_000_000, 2_000_000]
SOUNDNESS_STATUS = "diagnostic_pcs_fri_only"

EXECUTE_RE = re.compile(r"Execute:\s+([0-9.]+)ms\s+\(([0-9]+) cycles")
PROVE_RE = re.compile(r"Prove:\s+([0-9.]+)ms")
VERIFY_RE = re.compile(r"Verify:\s+([0-9.]+)ms")
RUN_PROVE_RE = re.compile(r"Run\+Prove:\s*([0-9.]+)ms")
TOTAL_RE = re.compile(r"^Total:\s+([0-9.]+)ms$", re.MULTILINE)
TRACE_RE = re.compile(
    r"Trace cells: preprocessed=([0-9]+) main=([0-9]+) "
    r"implicit-zero=([0-9]+) committed=([0-9]+)"
)
AMPLIFICATION_RE = re.compile(r"Committed cells/cycle:\s+([0-9.]+)")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def required_match(pattern: re.Pattern[str], output: str, label: str) -> re.Match[str]:
    match = pattern.search(output)
    if match is None:
        raise ValueError(f"missing {label} in benchmark output")
    return match


def parse_benchmark_output(output: str) -> dict[str, Any]:
    execute = required_match(EXECUTE_RE, output, "execute timing")
    prove = required_match(PROVE_RE, output, "prove timing")
    verify = required_match(VERIFY_RE, output, "verify timing")
    run_prove = required_match(RUN_PROVE_RE, output, "run+prove timing")
    total = required_match(TOTAL_RE, output, "total timing")
    trace = required_match(TRACE_RE, output, "trace geometry")
    amplification = required_match(AMPLIFICATION_RE, output, "trace amplification")

    execute_ms = float(execute.group(1))
    cycles = int(execute.group(2))
    prove_ms = float(prove.group(1))
    verify_ms = float(verify.group(1))
    run_prove_ms = float(run_prove.group(1))
    cli_total_ms = float(total.group(1))
    values = [execute_ms, prove_ms, verify_ms, run_prove_ms, cli_total_ms]
    if cycles <= 0 or any(not math.isfinite(value) or value < 0 for value in values):
        raise ValueError("benchmark returned invalid timing or cycle data")
    if prove_ms == 0 or run_prove_ms == 0 or cli_total_ms == 0:
        raise ValueError("benchmark returned a zero throughput denominator")
    if run_prove_ms < prove_ms or cli_total_ms < run_prove_ms:
        raise ValueError("benchmark returned inconsistent timing scopes")

    return {
        "cycles": cycles,
        "execute_ms": execute_ms,
        "prove_ms": prove_ms,
        "verify_ms": verify_ms,
        "run_prove_ms": run_prove_ms,
        "cli_total_ms": cli_total_ms,
        "prove_mhz": cycles / prove_ms / 1000.0,
        "run_prove_mhz": cycles / run_prove_ms / 1000.0,
        "cli_total_mhz": cycles / cli_total_ms / 1000.0,
        "trace_cells": {
            "preprocessed": int(trace.group(1)),
            "main": int(trace.group(2)),
            "implicit_zero": int(trace.group(3)),
            "committed": int(trace.group(4)),
        },
        "committed_cells_per_cycle": float(amplification.group(1)),
        "pcs_fri_accepted_by_shared_verifier": True,
        "soundness_status": SOUNDNESS_STATUS,
    }


def attach_e2e_metrics(
    sample: dict[str, Any],
    fib_n: int,
    process_wall_s: float,
) -> dict[str, Any]:
    if fib_n <= 2 or sample["cycles"] != 5 * fib_n - 3:
        raise ValueError("benchmark returned cycles inconsistent with fib_n")
    if not math.isfinite(process_wall_s) or process_wall_s <= 0:
        raise ValueError("benchmark returned invalid process wall timing")
    if process_wall_s * 1000.0 < sample["cli_total_ms"]:
        raise ValueError("process wall timing is shorter than the CLI total")

    sample.update(
        {
            "fib_n": fib_n,
            "process_wall_s": process_wall_s,
            "process_overhead_ms": process_wall_s * 1000.0 - sample["cli_total_ms"],
            "e2e_mhz": sample["cycles"] / process_wall_s / 1_000_000.0,
            "prove_fib_iterations_per_s": fib_n / sample["prove_ms"] * 1000.0,
            "run_prove_fib_iterations_per_s": fib_n / sample["run_prove_ms"] * 1000.0,
            "cli_total_fib_iterations_per_s": fib_n / sample["cli_total_ms"] * 1000.0,
            "e2e_fib_iterations_per_s": fib_n / process_wall_s,
        }
    )
    return sample


def run_sample(
    binary: Path,
    fib_n: int,
    pow_bits: int,
    n_queries: int,
    timeout_s: float,
    environment: dict[str, str],
) -> dict[str, Any]:
    command = [
        str(binary),
        "--fib-n",
        str(fib_n),
        "--pow-bits",
        str(pow_bits),
        "--n-queries",
        str(n_queries),
    ]
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
    output = completed.stdout + completed.stderr
    if completed.returncode != 0:
        raise RuntimeError(
            f"benchmark exited {completed.returncode}: {' '.join(command)}\n{output[-4000:]}"
        )
    parsed = attach_e2e_metrics(parse_benchmark_output(output), fib_n, process_wall_s)
    parsed.update(
        {
            "command": command,
            "output": output,
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


def summarize(samples: list[dict[str, Any]]) -> dict[str, Any]:
    fields = [
        "execute_ms",
        "prove_ms",
        "verify_ms",
        "run_prove_ms",
        "cli_total_ms",
        "process_wall_s",
        "process_overhead_ms",
        "prove_mhz",
        "run_prove_mhz",
        "cli_total_mhz",
        "e2e_mhz",
        "prove_fib_iterations_per_s",
        "run_prove_fib_iterations_per_s",
        "cli_total_fib_iterations_per_s",
        "e2e_fib_iterations_per_s",
    ]
    summary: dict[str, Any] = {"samples": len(samples)}
    for field in fields:
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
    trace = sample["trace_cells"]
    return (
        sample["cycles"],
        trace["preprocessed"],
        trace["main"],
        trace["implicit_zero"],
        trace["committed"],
        sample["committed_cells_per_cycle"],
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sizes", type=int, nargs="+", default=DEFAULT_SIZES)
    parser.add_argument("--warmups", type=int, default=0)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--pow-bits", type=int, default=10)
    parser.add_argument("--n-queries", type=int, default=3)
    parser.add_argument("--timeout-s", type=float, default=300.0)
    parser.add_argument("--pause-s", type=float, default=0.0)
    parser.add_argument("--cpu-bin", type=Path, default=ROOT / "zig-out/bin/riscv-bench")
    parser.add_argument("--metal-bin", type=Path, default=ROOT / "zig-out/bin/riscv-metal-bench")
    parser.add_argument("--output", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.repeats <= 0 or args.warmups < 0 or any(size <= 2 for size in args.sizes):
        raise SystemExit("sizes, warmups, and repeats must be positive")
    binaries = {"cpu": args.cpu_bin.resolve(), "metal": args.metal_bin.resolve()}
    for path in binaries.values():
        if not path.is_file():
            raise SystemExit(f"missing benchmark binary: {path}")

    environment = os.environ.copy()
    samples: dict[int, dict[str, list[dict[str, Any]]]] = {
        size: {"cpu": [], "metal": []} for size in args.sizes
    }
    total_passes = args.warmups + args.repeats
    for pass_index in range(total_passes):
        measured = pass_index >= args.warmups
        sizes = args.sizes if pass_index % 2 == 0 else list(reversed(args.sizes))
        backend_order = ["cpu", "metal"] if pass_index % 2 == 0 else ["metal", "cpu"]
        for size in sizes:
            pass_samples: dict[str, dict[str, Any]] = {}
            for backend in backend_order:
                print(
                    f"pass={pass_index} measured={measured} fib={size} backend={backend}",
                    file=sys.stderr,
                    flush=True,
                )
                sample = run_sample(
                    binaries[backend],
                    size,
                    args.pow_bits,
                    args.n_queries,
                    args.timeout_s,
                    environment,
                )
                pass_samples[backend] = sample
                if measured:
                    samples[size][backend].append(sample)
                if args.pause_s > 0:
                    time.sleep(args.pause_s)
            if geometry_key(pass_samples["cpu"]) != geometry_key(pass_samples["metal"]):
                raise RuntimeError(f"backend geometry mismatch for fib({size}) on pass {pass_index}")

    rows = []
    for size in args.sizes:
        cpu_summary = summarize(samples[size]["cpu"])
        metal_summary = summarize(samples[size]["metal"])
        rows.append(
            {
                "fib_n": size,
                "cycles": samples[size]["cpu"][0]["cycles"],
                "trace_cells": samples[size]["cpu"][0]["trace_cells"],
                "committed_cells_per_cycle": samples[size]["cpu"][0]["committed_cells_per_cycle"],
                "cpu": {"summary": cpu_summary, "raw_samples": samples[size]["cpu"]},
                "metal": {"summary": metal_summary, "raw_samples": samples[size]["metal"]},
                "metal_speedup_prove": (
                    cpu_summary["prove_ms"]["median"] / metal_summary["prove_ms"]["median"]
                ),
                "metal_speedup_run_prove": (
                    cpu_summary["run_prove_ms"]["median"]
                    / metal_summary["run_prove_ms"]["median"]
                ),
                "metal_speedup_cli_total": (
                    cpu_summary["cli_total_ms"]["median"]
                    / metal_summary["cli_total_ms"]["median"]
                ),
                "metal_speedup_e2e": (
                    cpu_summary["process_wall_s"]["median"]
                    / metal_summary["process_wall_s"]["median"]
                ),
            }
        )

    report = {
        "schema_version": 3,
        "benchmark": "riscv_fib_backend_compare",
        "status": "completed",
        "soundness_status": SOUNDNESS_STATUS,
        "no_trace_dependent_air_constraints": True,
        "shared_verifier": True,
        "sound_proof_evidence": False,
        "production_evidence": False,
        "correctness_parity_evidence": False,
        "workload": "generated RV32IM iterative Fibonacci guest",
        "cycle_semantics": "emitted VM cycles; generated guest is 5 * fib_n - 3",
        "protocol": {
            "hash": "blake2s",
            "log_blowup_factor": 1,
            "fri_log_last_layer_degree_bound": 0,
            "fri_fold_step": 1,
            "pow_bits": args.pow_bits,
            "n_queries": args.n_queries,
        },
        "measurement": {
            "warmups": args.warmups,
            "repeats": args.repeats,
            "process_model": "fresh process per proof; Metal runtime warmup occurs before the CLI prove timer",
            "diagnostic_acceptance": (
                "every measured PCS/FRI artifact was accepted by the same shared Zig verifier; "
                "this does not verify RISC-V execution semantics"
            ),
            "execution_policy": "strictly sequential with alternating backend and size order",
            "timing_scopes": {
                "prove_ms": "proveRiscVWithEngine only; excludes execution, verification, and Metal runtime warmup",
                "run_prove_ms": "guest execution plus proof; excludes verification and Metal runtime warmup",
                "cli_total_ms": "ELF generation, guest execution, proof, and verification; excludes argument parsing and Metal runtime warmup",
                "process_wall_s": "parent perf_counter around the fresh subprocess, including startup and Metal runtime warmup; cold end-to-end metric of record",
            },
            "throughput_units": {
                "mhz": "emitted VM cycles per second divided by 1e6",
                "fib_iterations_per_s": "requested Fibonacci loop iterations per second",
            },
        },
        "backends": {
            "cpu": {
                "label": "Zig CPU ReleaseFast with auto-SIMD hot paths",
                "binary": str(binaries["cpu"]),
                "sha256": sha256_file(binaries["cpu"]),
            },
            "metal": {
                "label": "generic hybrid MetalProverEngine",
                "binary": str(binaries["metal"]),
                "sha256": sha256_file(binaries["metal"]),
            },
        },
        "limitations": [
            "No trace-dependent AIR constraints are enforced; accepted artifacts do not prove RISC-V execution correctness or the Fibonacci result.",
            "Both backends use the same Zig verifier, so acceptance is not independent verifier or correctness parity evidence.",
            "This report is diagnostic PCS/FRI performance evidence only and is neither a sound-proof nor production result.",
            "The repository has no distinct full Zig SimdBackend; the CPU lane uses CpuBackend with native SIMD hot paths.",
            "MetalProverEngine is hybrid: bulk transforms, commitments, quotient work, sampling, and FRI use Metal while trace generation and compatibility operations remain CPU.",
            "The CLI does not expose artifact bytes or a digest.",
        ],
        "rows": rows,
    }
    rendered = json.dumps(report, indent=2) + "\n"
    if args.output is not None:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered)
    sys.stdout.write(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
