#!/usr/bin/env python3
"""Enforce the explicit source boundary of the focused RISC-V CPU product."""

from __future__ import annotations

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OWNED = (
    ROOT / "build_support/products/riscv_cpu.zig",
    ROOT / "src/riscv_cpu_product.zig",
    ROOT / "src/stwo_riscv_cpu.zig",
    ROOT / "src/riscv_trace_cli.zig",
    *(ROOT / "src/products/riscv_cpu").glob("*.zig"),
)
FORBIDDEN = (
    '@import("stwo.zig")',
    '@import("stwo")',
    'native_dispatch',
    'frontends/cairo',
    'integrations/cairo',
    'backends/metal',
    'backends/cuda',
    'examples/mod.zig',
    'metal_products',
    'linkFramework',
    'linkSystemLibrary',
)


def main() -> int:
    failures: list[str] = []
    for path in OWNED:
        text = path.read_text()
        for marker in FORBIDDEN:
            if marker in text:
                failures.append(f"{path.relative_to(ROOT)}: forbidden focused-product dependency {marker!r}")
    owner = (ROOT / "build_support/products/riscv_cpu.zig").read_text()
    for artifact in ("stwo-zig-riscv-cpu", "riscv-trace-dump"):
        if artifact not in owner:
            failures.append(f"focused product does not construct {artifact}")
    if failures:
        print("\n".join(failures))
        return 1
    print(f"riscv cpu product closure: PASS ({len(OWNED)} owned files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
