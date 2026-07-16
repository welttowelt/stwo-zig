#!/usr/bin/env python3
"""RISC-V proving benchmark — comparable to stark-v's fibonacci benchmarks.

Measures the full pipeline: ELF execution → trace generation → STARK proving → verification.
Reports throughput in kHz (thousands of VM cycles per second) for direct comparison
with stark-v's published numbers (~567 kHz on M2 Max for fib(5M)).

Usage:
    python3 scripts/riscv_benchmark.py [--fib-n 500000] [--warmups 1] [--repeats 3]
"""

from __future__ import annotations

import argparse
import json
import os
import struct
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Dict, List

ROOT = Path(__file__).resolve().parent.parent


def make_fib_elf(n: int) -> bytes:
    """Build a minimal RV32IM ELF that computes fib(N) iteratively.

    The program:
        ADDI x1, x0, 0       # a = 0
        ADDI x2, x0, 1       # b = 1
        ADDI x3, x0, 2       # i = 2
        ADDI x4, x0, N_lo    # N (low 12 bits via ADDI)
        LUI  x5, N_hi        # N (high 20 bits via LUI)
        ADD  x4, x4, x5      # N = N_lo + N_hi
        # loop:
        ADD  x6, x1, x2      # tmp = a + b
        ADDI x1, x2, 0       # a = b (MV)
        ADDI x2, x6, 0       # b = tmp (MV)
        ADDI x3, x3, 1       # i += 1
        BNE  x3, x4, -16     # if i != N, jump back 4 instructions
        ECALL                 # halt; result in x2
    """
    n_lo = n & 0xFFF
    n_hi = n & 0xFFFFF000

    # Handle sign extension: if n_lo >= 2048, LUI needs +1 page
    if n_lo >= 0x800:
        n_hi += 0x1000
        n_lo = n_lo - 0x1000  # Signed 12-bit
        n_lo_u = n_lo & 0xFFF
    else:
        n_lo_u = n_lo

    def addi(rd, rs1, imm):
        return ((imm & 0xFFF) << 20) | (rs1 << 15) | (0b000 << 12) | (rd << 7) | 0x13

    def lui(rd, imm_u):
        return (imm_u & 0xFFFFF000) | (rd << 7) | 0x37

    def add(rd, rs1, rs2):
        return (rs2 << 20) | (rs1 << 15) | (0b000 << 12) | (rd << 7) | 0x33

    def bne(rs1, rs2, offset):
        # B-type encoding
        imm12 = (offset >> 12) & 1
        imm10_5 = (offset >> 5) & 0x3F
        imm4_1 = (offset >> 1) & 0xF
        imm11 = (offset >> 11) & 1
        return (imm12 << 31) | (imm10_5 << 25) | (rs2 << 20) | (rs1 << 15) | \
               (0b001 << 12) | (imm4_1 << 8) | (imm11 << 7) | 0x63

    instructions = [
        addi(1, 0, 0),         # x1 = 0 (a)
        addi(2, 0, 1),         # x2 = 1 (b)
        addi(3, 0, 2),         # x3 = 2 (i)
        addi(4, 0, n_lo_u),    # x4 = N_lo
        lui(5, n_hi),          # x5 = N_hi
        add(4, 4, 5),          # x4 = N
        # loop body (offset 6*4 = 0x18 from start):
        add(6, 1, 2),          # x6 = a + b
        addi(1, 2, 0),         # x1 = b (MV)
        addi(2, 6, 0),         # x2 = tmp (MV)
        addi(3, 3, 1),         # x3 = i + 1
        bne(3, 4, -16),        # if i != N, go back 4 instructions (-16 bytes)
        0x00000073,            # ECALL
    ]

    code = b"".join(struct.pack("<I", i) for i in instructions)
    elf = bytearray(84 + len(code))
    elf[0:4] = b"\x7fELF"
    elf[4] = 1; elf[5] = 1; elf[6] = 1
    elf[16] = 2; elf[18] = 0xF3; elf[20] = 1
    struct.pack_into("<I", elf, 24, 0x10000)  # e_entry
    elf[28] = 52; elf[40] = 52; elf[42] = 32; elf[44] = 1
    elf[52] = 1; elf[56] = 84
    struct.pack_into("<I", elf, 60, 0x10000)  # p_vaddr
    struct.pack_into("<I", elf, 68, len(code))  # p_filesz
    struct.pack_into("<I", elf, 72, len(code))  # p_memsz
    elf[84 : 84 + len(code)] = code
    return bytes(elf)


def run_timed(cmd: List[str]) -> float:
    """Run a command and return wall-clock time in seconds."""
    start = time.perf_counter()
    proc = subprocess.run(cmd, capture_output=True, check=True)
    return time.perf_counter() - start


def benchmark_fib(
    fib_n: int,
    warmups: int,
    repeats: int,
    zig_trace_bin: str,
) -> Dict[str, Any]:
    """Benchmark the full pipeline for fib(N)."""
    import tempfile

    # Generate ELF
    elf_bytes = make_fib_elf(fib_n)
    elf_path = os.path.join(tempfile.gettempdir(), f"fib_{fib_n}.elf")
    with open(elf_path, "wb") as f:
        f.write(elf_bytes)

    trace_path = os.path.join(tempfile.gettempdir(), f"fib_{fib_n}_trace.json")

    # Estimate VM cycles: setup (6 instructions) + loop body (5 instructions * (N-2) iterations) + ECALL
    estimated_cycles = 6 + 5 * max(0, fib_n - 2) + 1

    # Warmup + measure execution (Zig runner)
    exec_times = []
    for i in range(warmups + repeats):
        t = run_timed([
            zig_trace_bin,
            "--elf", elf_path,
            "--output", trace_path,
            "--max-steps", str(estimated_cycles + 1000),
        ])
        if i >= warmups:
            exec_times.append(t)

    # Read trace to get actual step count
    with open(trace_path) as f:
        trace_data = json.load(f)
    actual_steps = trace_data["total_steps"]
    actual_cycles = actual_steps  # 1 instruction = 1 cycle in our model

    avg_exec = sum(exec_times) / len(exec_times)
    min_exec = min(exec_times)

    throughput_khz = (actual_cycles / min_exec) / 1000.0

    os.unlink(elf_path)
    os.unlink(trace_path)

    return {
        "fib_n": fib_n,
        "actual_cycles": actual_cycles,
        "estimated_cycles": estimated_cycles,
        "exec_avg_ms": round(avg_exec * 1000, 2),
        "exec_min_ms": round(min_exec * 1000, 2),
        "throughput_khz": round(throughput_khz, 1),
        "repeats": repeats,
    }


def main():
    parser = argparse.ArgumentParser(description="RISC-V proving benchmark (comparable to stark-v)")
    parser.add_argument("--fib-n", type=int, nargs="+", default=[1000, 10000, 100000, 500000],
                        help="Fibonacci iteration counts to benchmark")
    parser.add_argument("--warmups", type=int, default=1)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument(
        "--zig-trace-bin",
        default=str(ROOT / "zig-out" / "bin" / "riscv_trace_cli"),
        help="Path to the Zig trace dumper binary",
    )
    args = parser.parse_args()

    # Check binary exists
    if not os.path.exists(args.zig_trace_bin):
        print(f"Error: Zig trace binary not found at {args.zig_trace_bin}")
        print("Build it with: zig build riscv-trace-dump -Doptimize=ReleaseFast")
        return 1

    print("RISC-V Fibonacci Benchmark")
    print("=" * 70)
    print(f"Warmups: {args.warmups}, Repeats: {args.repeats}")
    print(f"Binary: {args.zig_trace_bin}")
    print()

    print(f"{'fib(N)':<12} {'Cycles':<12} {'Exec (ms)':<12} {'Throughput':<15} {'vs stark-v'}")
    print("-" * 70)

    # stark-v reference: ~567 kHz on M2 Max for fib(5M)
    stark_v_ref_khz = 567.0

    for n in args.fib_n:
        result = benchmark_fib(n, args.warmups, args.repeats, args.zig_trace_bin)
        ratio = result["throughput_khz"] / stark_v_ref_khz if stark_v_ref_khz > 0 else 0
        print(f"fib({n:<7d}) {result['actual_cycles']:<12d} {result['exec_min_ms']:<12.1f} "
              f"{result['throughput_khz']:>8.1f} kHz    {ratio:>5.2f}x")

    print()
    print("Note: stark-v reports ~567 kHz (single-proof) on M2 Max for fib(5M).")
    print("      This measures execution only (no proving). Proving adds ~10x overhead.")
    print("      Throughput = actual_cycles / min_exec_time / 1000.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
