#!/usr/bin/env python3
"""Prove that focused internal build scopes configure only owned products."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import time
from pathlib import Path


SCOPES: dict[str, set[str]] = {
    "architecture": {
        "architecture-gate",
        "architecture-verify",
        "build-monorepo-baseline",
    },
    "core": {"stwo-core", "test-stwo-core"},
    "prover": {
        "stwo-core",
        "test-stwo-core",
        "stwo-prover",
        "test-stwo-prover",
    },
    "native_cpu": {
        "stwo-native-cpu",
        "benchmark-native-cpu",
        "test-native-cpu-product",
    },
    "native_metal": {
        "stwo-native-metal",
        "native-proof-bench-metal",
        "test-native-metal",
    },
    "riscv_cpu": {
        "riscv-trace-dump",
        "stwo-zig-riscv-cpu",
        "stwo-zig-riscv-cpu-static",
        "test-riscv-cpu-product",
    },
    "policy": {
        "fmt",
        "api-parity",
        "upstream-pins",
        "source-conformance",
        "upstream-surface",
        "build-configure-closure",
    },
    "metal_tools": {
        "metal-core-aot",
        "test-metal-core-aot",
        "metal-core-aot-probe",
        "test-metal-core-aot-probe",
        "metal-core-aot-acceptance",
        "metal-arena-plan",
        "metal-arena-session",
        "metal-prover-session-test",
        "metal-recovery-bench",
        "metal-ec-op-bench",
        "metal-compact-bench",
        "cairo-streaming-commitment-bench",
        "cairo-streaming-commitment-test",
        "metal-eval-prepare",
        "metal-eval-source",
        "metal-witness-source",
        "metal-test",
        "metal-check",
        "metal-bench",
        "riscv-metal-bench",
    },
    "deferred": {
        "stwo-cairo-cpu",
        "stwo-cairo-metal",
        "stwo-riscv-metal",
        "stwo-native-cuda",
        "stwo-cairo-cuda",
        "stwo-riscv-cuda",
        "cuda-test",
    },
}

BUILTINS = {"install", "uninstall"}
FOCUSED_OWNER_FILES = (
    "build_support/products/core.zig",
    "build_support/products/prover.zig",
    "build_support/products/native_cpu.zig",
    "build_support/products/native_metal.zig",
    "build_support/products/riscv_cpu.zig",
)


def parse_steps(help_text: str) -> set[str]:
    lines = help_text.splitlines()
    start = lines.index("Steps:") + 1
    end = next(index for index in range(start, len(lines)) if not lines[index].strip())
    return {line.strip().split()[0] for line in lines[start:end]}


def internal_help(repository: Path, scope: str) -> tuple[set[str], float, str]:
    command = [
        "zig",
        "build",
        "--help",
        "--build-file",
        str(repository / "build_support/internal_build.zig"),
        f"-Drepository-root={repository}",
        f"-Dproduct-scope={scope}",
    ]
    started = time.monotonic()
    result = subprocess.run(command, cwd=repository, text=True, capture_output=True)
    elapsed = time.monotonic() - started
    if result.returncode != 0:
        raise SystemExit(f"{scope} configuration failed:\n{result.stderr}")
    return parse_steps(result.stdout), elapsed, result.stdout


def check_scope(repository: Path, scope: str, expected: set[str]) -> dict[str, object]:
    actual, elapsed, output = internal_help(repository, scope)
    wanted = expected | BUILTINS
    missing = sorted(wanted - actual)
    extra = sorted(actual - wanted)
    if missing or extra:
        raise SystemExit(
            f"{scope} configure closure mismatch: missing={missing}, extra={extra}"
        )
    return {
        "scope": scope,
        "steps": sorted(actual),
        "help_sha256": hashlib.sha256(output.encode()).hexdigest(),
        "configure_seconds": round(elapsed, 6),
    }


def check_unknown_scope(repository: Path) -> None:
    command = [
        "zig",
        "build",
        "--help",
        "--build-file",
        str(repository / "build_support/internal_build.zig"),
        f"-Drepository-root={repository}",
        "-Dproduct-scope=not_a_product",
    ]
    result = subprocess.run(command, cwd=repository, text=True, capture_output=True)
    if result.returncode == 0 or "unknown internal product scope" not in result.stderr:
        raise SystemExit("unknown internal product scope did not fail closed")


def check_install_ownership(repository: Path) -> None:
    for relative in FOCUSED_OWNER_FILES:
        source = (repository / relative).read_text()
        if "getInstallStep" in source:
            raise SystemExit(f"focused owner mutates global install step: {relative}")
    dispatcher = (repository / "build_support/root_dispatcher.zig").read_text()
    required = 'delegatedCommand(b, target, optimize, options, "aggregate", "stwo-zig")'
    if required not in dispatcher:
        raise SystemExit("root default install is not pinned to the aggregate CLI only")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument(
        "--receipt",
        type=Path,
        default=Path("zig-out/build-graph/configure-closure.json"),
    )
    arguments = parser.parse_args()
    repository = arguments.repo.resolve()

    receipts = [check_scope(repository, scope, expected) for scope, expected in SCOPES.items()]
    check_unknown_scope(repository)
    check_install_ownership(repository)
    payload = {
        "schema": "stwo-build-configure-closure-v1",
        "result": "pass",
        "default_install_artifacts": ["stwo-zig"],
        "scopes": receipts,
        "negative_checks": [
            "unknown-scope-fails",
            "exact-step-set",
            "focused-install-mutation-rejected",
        ],
    }
    receipt = arguments.receipt
    if not receipt.is_absolute():
        receipt = repository / receipt
    receipt.parent.mkdir(parents=True, exist_ok=True)
    receipt.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    print(f"build configure closure: PASS ({len(receipts)} focused scopes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
