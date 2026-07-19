#!/usr/bin/env python3
"""Prove the transitive source boundary of the Native CPU/SIMD product."""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
IMPORT = re.compile(r'@import\("([^"\n]+)"\)')
ENTRY_ROOTS = (
    ROOT / "src/native_cpu_product.zig",
    ROOT / "src/stwo_native_cpu.zig",
    ROOT / "src/prover/native/runner.zig",
    ROOT / "src/products/native_cpu/benchmark.zig",
)
NAMED_ROOTS = {
    "stwo": ROOT / "src/stwo_native_cpu.zig",
    "stwo_native_cpu": ROOT / "src/stwo_native_cpu.zig",
    "native_proof_runner": ROOT / "src/prover/native/runner.zig",
}
GENERATED_IMPORTS = {"build_identity", "builtin", "product_identity", "std"}
FORBIDDEN_PREFIXES = (
    Path("src/backends/cuda"),
    Path("src/backends/metal"),
    Path("src/frontends/cairo"),
    Path("src/frontends/riscv"),
    Path("src/integrations"),
    Path("src/tools/prove"),
)
FORBIDDEN_EXACT = {
    Path("src/backends/mod.zig"),
    Path("src/frontends/mod.zig"),
    Path("src/examples/mod.zig"),
    Path("src/interop/mod.zig"),
    Path("src/stwo.zig"),
}
OWNED_ROOTS = (
    ROOT / "build_support/products/native_cpu.zig",
    ROOT / "src/native_cpu_product.zig",
    ROOT / "src/stwo_native_cpu.zig",
    *(ROOT / "src/products/native_cpu").glob("*.zig"),
)
FORBIDDEN_OWNER_MARKERS = (
    "metal_products",
    "linkFramework",
    "linkSystemLibrary",
    "src/stwo.zig",
    "frontends/cairo",
    "frontends/riscv",
    "backends/metal",
    "backends/cuda",
)


def repository_path(path: Path) -> Path:
    return path.resolve().relative_to(ROOT.resolve())


def is_forbidden(path: Path) -> bool:
    relative = repository_path(path)
    return relative in FORBIDDEN_EXACT or any(
        relative == prefix or prefix in relative.parents for prefix in FORBIDDEN_PREFIXES
    )


def resolve_import(source: Path, imported: str) -> Path | None:
    if imported in GENERATED_IMPORTS:
        return None
    if imported in NAMED_ROOTS:
        return NAMED_ROOTS[imported]
    if not imported.endswith(".zig"):
        raise ValueError(f"{repository_path(source)}: undeclared named import {imported!r}")
    target = (source.parent / imported).resolve()
    try:
        target.relative_to(ROOT.resolve())
    except ValueError as error:
        raise ValueError(f"{repository_path(source)}: import escapes repository: {imported}") from error
    if not target.is_file():
        raise ValueError(f"{repository_path(source)}: unresolved import {imported}")
    return target


def compile_closure() -> set[Path]:
    pending = list(ENTRY_ROOTS)
    visited: set[Path] = set()
    while pending:
        source = pending.pop().resolve()
        if source in visited:
            continue
        visited.add(source)
        for imported in IMPORT.findall(source.read_text(encoding="utf-8")):
            target = resolve_import(source, imported)
            if target is not None:
                pending.append(target)
    return visited


def dynamic_linkage(binary: Path) -> str:
    if sys.platform == "darwin":
        tool = shutil.which("otool")
        command = [tool, "-L", str(binary)] if tool else None
    elif sys.platform.startswith("linux"):
        tool = shutil.which("readelf")
        command = [tool, "-d", str(binary)] if tool else None
    else:
        raise ValueError(f"unsupported linkage-inspection host: {sys.platform}")
    if command is None:
        raise ValueError("required dynamic-linkage inspection tool is unavailable")
    result = subprocess.run(command, text=True, capture_output=True, check=False)
    if result.returncode != 0:
        raise ValueError(f"dynamic-linkage inspection failed: {result.stderr.strip()}")
    return result.stdout


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path)
    args = parser.parse_args()
    failures: list[str] = []
    try:
        closure = compile_closure()
    except ValueError as error:
        failures.append(str(error))
        closure = set()
    for path in sorted(closure):
        if is_forbidden(path):
            failures.append(f"forbidden compile-closure source: {repository_path(path)}")
    for path in OWNED_ROOTS:
        text = path.read_text(encoding="utf-8")
        for marker in FORBIDDEN_OWNER_MARKERS:
            if marker in text:
                failures.append(
                    f"{repository_path(path)}: forbidden product-owner dependency {marker!r}"
                )
    owner = (ROOT / "build_support/products/native_cpu.zig").read_text(encoding="utf-8")
    for artifact in (
        '"stwo-native-cpu"',
        '"stwo-zig-native-cpu"',
        '"stwo-zig-native-cpu-bench"',
        '"benchmark-native-cpu"',
    ):
        if artifact not in owner:
            failures.append(f"focused product does not construct {artifact}")
    if args.binary is not None:
        try:
            linkage = dynamic_linkage(args.binary)
        except ValueError as error:
            failures.append(str(error))
        else:
            lowered = linkage.lower()
            for runtime in ("metal", "cuda", "objc"):
                if runtime in lowered:
                    failures.append(f"focused binary links forbidden runtime {runtime!r}")
    if failures:
        print("\n".join(failures))
        return 1
    print(f"native cpu product closure: PASS ({len(closure)} transitive Zig sources)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
