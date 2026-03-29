#!/usr/bin/env python3
"""Cross-verify RISC-V execution traces between Rust and Zig.

Compares JSON trace files produced by the Rust stark-v trace dumper and
the Zig riscv-trace-dump CLI.  Two traces are *equivalent* when their
total step count, final PC, and all 32 final register values match.
Per-step PCs are compared for divergence diagnosis.

Usage:
  # Manual comparison of two pre-existing trace files:
  python3 scripts/riscv_equivalence.py rust_trace.json zig_trace.json

  # Automatic run-and-compare mode:
  python3 scripts/riscv_equivalence.py --run <elf_path> \
      [--rust-bin <path>] [--zig-bin <path>] [--max-steps N]
"""

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def load_trace(path: str) -> dict:
    """Load a JSON trace file."""
    with open(path) as f:
        return json.load(f)


def compare_traces(rust_trace: dict, zig_trace: dict) -> list[str]:
    """Compare two execution traces and return a list of differences."""
    errors: list[str] = []

    # Compare step counts.
    if rust_trace["total_steps"] != zig_trace["total_steps"]:
        errors.append(
            f"Step count: Rust={rust_trace['total_steps']} "
            f"Zig={zig_trace['total_steps']}"
        )

    # Compare final PC.
    if rust_trace["final_pc"] != zig_trace["final_pc"]:
        errors.append(
            f"Final PC: Rust={rust_trace['final_pc']:#x} "
            f"Zig={zig_trace['final_pc']:#x}"
        )

    # Compare final registers.
    rust_regs = rust_trace.get("final_regs", [])
    zig_regs = zig_trace.get("final_regs", [])
    for i in range(min(32, len(rust_regs), len(zig_regs))):
        if rust_regs[i] != zig_regs[i]:
            errors.append(
                f"x{i}: Rust={rust_regs[i]:#010x} Zig={zig_regs[i]:#010x}"
            )

    # Compare per-step PCs for divergence diagnosis.
    rust_steps = rust_trace.get("steps", [])
    zig_steps = zig_trace.get("steps", [])
    min_steps = min(len(rust_steps), len(zig_steps))
    for i in range(min_steps):
        r_pc = rust_steps[i].get("pc", -1)
        z_pc = zig_steps[i].get("pc", -2)
        if r_pc != z_pc:
            errors.append(
                f"Step {i}: PC diverged - Rust={r_pc:#x} Zig={z_pc:#x}"
            )
            # Stop after first PC divergence to avoid noise.
            break

    return errors


def run_equivalence(
    elf_path: str,
    rust_bin: str,
    zig_bin: str,
    max_steps: int = 100_000,
) -> list[str]:
    """Run both implementations on the same ELF and compare."""
    rust_fd, rust_path = tempfile.mkstemp(suffix=".json")
    zig_fd, zig_path = tempfile.mkstemp(suffix=".json")
    os.close(rust_fd)
    os.close(zig_fd)

    try:
        # Run Rust trace dumper.
        subprocess.run(
            [rust_bin, "--elf", elf_path, "--output", rust_path,
             "--max-steps", str(max_steps)],
            check=True,
            capture_output=True,
        )

        # Run Zig trace dumper.
        subprocess.run(
            [zig_bin, "--elf", elf_path, "--output", zig_path,
             "--max-steps", str(max_steps)],
            check=True,
            capture_output=True,
        )

        # Compare.
        rust_trace = load_trace(rust_path)
        zig_trace = load_trace(zig_path)
        return compare_traces(rust_trace, zig_trace)
    finally:
        for p in (rust_path, zig_path):
            try:
                os.unlink(p)
            except OSError:
                pass


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__.strip())
        return 1

    if sys.argv[1] == "--run":
        if len(sys.argv) < 3:
            print("error: --run requires an ELF path", file=sys.stderr)
            return 1

        elf_path = sys.argv[2]
        rust_bin = str(ROOT / "tools" / "stark-v-trace-dump" / "target" /
                       "release" / "stark-v-trace-dump")
        zig_bin = str(ROOT / "zig-out" / "bin" / "riscv-trace-dump")
        max_steps = 100_000

        # Parse optional flags.
        i = 3
        while i < len(sys.argv):
            if sys.argv[i] == "--rust-bin" and i + 1 < len(sys.argv):
                i += 1
                rust_bin = sys.argv[i]
            elif sys.argv[i] == "--zig-bin" and i + 1 < len(sys.argv):
                i += 1
                zig_bin = sys.argv[i]
            elif sys.argv[i] == "--max-steps" and i + 1 < len(sys.argv):
                i += 1
                max_steps = int(sys.argv[i])
            i += 1

        errors = run_equivalence(elf_path, rust_bin, zig_bin, max_steps)

    elif sys.argv[1] in ("--help", "-h"):
        print(__doc__.strip())
        return 0

    else:
        # Manual comparison mode: two trace file paths.
        if len(sys.argv) < 3:
            print(
                "Usage: riscv_equivalence.py <rust_trace.json> <zig_trace.json>",
                file=sys.stderr,
            )
            return 1

        rust_trace = load_trace(sys.argv[1])
        zig_trace = load_trace(sys.argv[2])
        errors = compare_traces(rust_trace, zig_trace)

    if errors:
        print(f"DIVERGENCE FOUND ({len(errors)} difference(s)):")
        for e in errors:
            print(f"  {e}")
        return 1
    else:
        print("EQUIVALENT: All registers, PC, and step count match.")
        return 0


if __name__ == "__main__":
    sys.exit(main())
