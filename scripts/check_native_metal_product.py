#!/usr/bin/env python3
"""Check Native Metal import ownership and final dynamic linkage."""

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
    ROOT / "src/products/native_metal/main.zig",
    ROOT / "src/stwo_native_metal.zig",
    ROOT / "src/prover/native/runner.zig",
)
NAMED_ROOTS = {
    "stwo": ROOT / "src/stwo_native_metal.zig",
    "stwo_backend_contracts": ROOT / "src/backend/mod.zig",
    "stwo_core": ROOT / "src/core/mod.zig",
    "stwo_native_metal": ROOT / "src/stwo_native_metal.zig",
    "stwo_prover_impl": ROOT / "src/prover/mod.zig",
    "native_proof_runner": ROOT / "src/prover/native/runner.zig",
}
GENERATED_IMPORTS = {"build_identity", "builtin", "product_identity", "std"}
FORBIDDEN_PREFIXES = (
    Path("src/backends/cuda"),
    Path("src/frontends/cairo"),
    Path("src/frontends/riscv"),
    Path("src/integrations"),
    Path("src/products/native_cpu"),
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
    ROOT / "build_support/products/native_metal.zig",
    ROOT / "src/stwo_native_metal.zig",
    *(ROOT / "src/products/native_metal").glob("*.zig"),
)
FORBIDDEN_OWNER_MARKERS = (
    "frontends/cairo",
    "frontends/riscv",
    "backends/cuda",
    "src/stwo.zig",
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
        raise ValueError(
            f"{repository_path(source)}: import escapes repository: {imported}"
        ) from error
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
    if sys.platform != "darwin":
        raise ValueError("Native Metal linkage inspection requires a macOS host")
    tool = shutil.which("otool")
    if tool is None:
        raise ValueError("required otool linkage inspector is unavailable")
    result = subprocess.run(
        [tool, "-L", str(binary)], text=True, capture_output=True, check=False
    )
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
    if not any(
        Path("src/backends/metal") in repository_path(path).parents for path in closure
    ):
        failures.append("focused compile closure does not contain the Metal backend")
    for path in OWNED_ROOTS:
        text = path.read_text(encoding="utf-8")
        for marker in FORBIDDEN_OWNER_MARKERS:
            if marker in text:
                failures.append(
                    f"{repository_path(path)}: forbidden product-owner dependency {marker!r}"
                )
    if args.binary is not None:
        try:
            linkage = dynamic_linkage(args.binary).lower()
        except ValueError as error:
            failures.append(str(error))
        else:
            for runtime in ("metal.framework", "foundation.framework", "libobjc"):
                if runtime not in linkage:
                    failures.append(f"focused binary is missing required runtime {runtime!r}")
            if "cuda" in linkage:
                failures.append("focused binary unexpectedly links CUDA")
    if failures:
        print("\n".join(failures))
        return 1
    print(f"native Metal product closure: PASS ({len(closure)} transitive Zig sources)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
