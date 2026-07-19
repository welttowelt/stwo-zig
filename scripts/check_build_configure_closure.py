#!/usr/bin/env python3
"""Prove that focused internal build scopes configure only owned products."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path


SCOPES: dict[str, set[str]] = {
    "aggregate": {
        "stwo-zig",
        "test",
        "identity-stwo-zig",
        "product-matrix-identity",
    },
    "architecture": {
        "architecture-gate",
        "architecture-verify",
        "build-monorepo-baseline",
    },
    "compatibility_tools": {
        "interop-cli",
        "cairo-input",
        "riscv-opcode-manifest",
        "riscv-opcode-manifest-check",
        "riscv-bench",
        "native-proof-bench-cpu",
    },
    "core": {"stwo-core", "test-stwo-core", "identity-stwo-core"},
    "prover": {
        "stwo-core",
        "test-stwo-core",
        "stwo-prover",
        "test-stwo-prover",
        "identity-stwo-core",
        "identity-stwo-prover",
    },
    "package": {
        "stwo-core",
        "test-stwo-core",
        "identity-stwo-core",
        "stwo-prover",
        "test-stwo-prover",
        "identity-stwo-prover",
        "test-downstream-modules",
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
    "riscv_cpu_compat": {
        "riscv-trace-dump",
        "stwo-zig-riscv-cpu",
        "stwo-zig-riscv-cpu-static",
        "test-riscv-cpu-product",
        "test-riscv",
        "test-riscv-prover",
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
    "verification": {
        "riscv-release-gate",
        "deep-gate",
        "vectors",
        "interop",
        "prove-checkpoints",
        "bench-smoke",
        "bench-kernels",
        "bench-strict",
        "bench-opt",
        "bench-opt-binary-codec",
        "bench-contrast",
        "bench-contrast-long",
        "bench-targeted-families",
        "bench-pages",
        "bench-full",
        "bench-pages-validate",
        "profile-smoke",
        "profile-opt",
        "profile-contrast",
        "profile-contrast-long",
        "merkle-worker-stress",
        "opt-gate",
        "std-shims-smoke",
        "std-shims-behavior",
        "release-evidence",
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
    "release": {"release-gate", "release-gate-strict"},
}

MANIFESTS: dict[str, dict[str, object]] = {
    "aggregate": {
        "product_ids": ["stwo-zig"],
        "external_tools": ["python3"],
        "runtime_probes": [],
        "constructors": [
            "products/matrix.construct.aggregate",
            "products/matrix.addIdentity",
        ],
        "declarative_exports_only": False,
    },
    "architecture": {
        "product_ids": [], "module_roots": [], "external_tools": ["python3"],
        "runtime_probes": [],
        "constructors": ["gates/architecture_receipts.addGates", "gates/baseline.addGate"],
        "declarative_exports_only": False,
    },
    "compatibility_tools": {
        "product_ids": ["stwo-compatibility-tools"],
        "module_roots": [
            "src/tools/interop/main.zig", "src/tools/cairo/input_inspector.zig",
            "src/tools/riscv_opcode_manifest/main.zig", "src/riscv_bench_cli.zig",
            "src/tools/native_proof_bench/cpu.zig",
        ],
        "external_tools": [], "runtime_probes": [],
        "constructors": ["products/compatibility_tools.addProducts"],
        "declarative_exports_only": False,
    },
    "core": {"product_ids": ["stwo-core"], "external_tools": ["python3"], "runtime_probes": [], "constructors": ["products/matrix.construct.core"], "declarative_exports_only": False},
    "prover": {"product_ids": ["stwo-prover"], "external_tools": ["python3"], "runtime_probes": [], "constructors": ["products/matrix.construct.prover"], "declarative_exports_only": False},
    "native_cpu": {"product_ids": ["stwo-native-cpu"], "external_tools": ["python3"], "runtime_probes": [], "constructors": ["products/matrix.construct.native_cpu"], "declarative_exports_only": False},
    "native_metal": {"product_ids": ["stwo-native-metal"], "external_tools": ["python3", "xcrun"], "runtime_probes": ["Metal.framework", "Foundation.framework", "libobjc"], "constructors": ["products/matrix.construct.native_metal"], "declarative_exports_only": False},
    "riscv_cpu": {"product_ids": ["stwo-riscv-cpu"], "external_tools": ["python3"], "runtime_probes": [], "constructors": ["products/matrix.construct.riscv_cpu"], "declarative_exports_only": False},
    "riscv_cpu_compat": {"product_ids": ["stwo-riscv-cpu"], "external_tools": ["python3"], "runtime_probes": [], "constructors": ["products/matrix.construct.riscv_cpu", "compatibility aliases"], "declarative_exports_only": False},
    "package": {
        "product_ids": ["stwo-core", "stwo-prover", "stwo"],
        "module_roots": ["src/core/mod.zig", "src/products/prover/root.zig", "src/stwo.zig"],
        "external_tools": ["python3"], "runtime_probes": [],
        "constructors": ["products/libraries.addProducts"],
        "declarative_exports_only": False,
    },
    "metal_tools": {
        "product_ids": ["stwo-native-metal-tools"],
        "module_roots": ["src/stwo.zig", "src/backends/metal/shader_manifest.zig"],
        "external_tools": ["xcrun", "metal", "metallib"],
        "runtime_probes": ["Metal.framework", "Foundation.framework", "libobjc"],
        "constructors": ["backends/metal_aot.addProducts", "benchmarks/metal.addProducts"],
        "declarative_exports_only": False,
    },
    "verification": {"product_ids": [], "module_roots": [], "external_tools": ["python3", "zig"], "runtime_probes": [], "constructors": ["gates/riscv.addGates", "gates/native.addGates", "benchmarks/native.addProducts", "gates/release_evidence.addGates"], "declarative_exports_only": False},
    "deferred": {"product_ids": ["stwo-cairo-cpu", "stwo-cairo-metal", "stwo-riscv-metal", "stwo-native-cuda", "stwo-cairo-cuda", "stwo-riscv-cuda"], "module_roots": [], "external_tools": [], "runtime_probes": [], "constructors": ["products/matrix.addDeferredProducts"], "declarative_exports_only": False},
    "policy": {"product_ids": [], "module_roots": [], "external_tools": ["python3", "zig"], "runtime_probes": [], "constructors": ["internal_build.addPolicyGates"], "declarative_exports_only": False},
    "release": {"product_ids": ["stwo-zig-release"], "module_roots": [], "external_tools": ["python3", "zig"], "runtime_probes": [], "constructors": ["gates/release.addGates"], "declarative_exports_only": False},
}

BUILTINS = {"install", "uninstall", "configure-manifest"}
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
        "--cache-dir",
        str(repository / ".zig-cache/products" / scope),
        f"-Drepository-root={repository}",
        f"-Dproduct-scope={scope}",
    ]
    started = time.monotonic()
    result = subprocess.run(command, cwd=repository, text=True, capture_output=True)
    elapsed = time.monotonic() - started
    if result.returncode != 0:
        raise SystemExit(f"{scope} configuration failed:\n{result.stderr}")
    return parse_steps(result.stdout), elapsed, result.stdout


def read_product_matrix(repository: Path) -> tuple[dict[str, dict[str, object]], str]:
    with tempfile.TemporaryDirectory(prefix="stwo-product-matrix-") as raw:
        result = subprocess.run(
            ["zig", "build", "product-matrix-identity", "-p", raw],
            cwd=repository,
            text=True,
            capture_output=True,
        )
        if result.returncode != 0:
            raise SystemExit(f"product matrix identity failed:\n{result.stderr}")
        encoded = (Path(raw) / "identity/product-matrix.json").read_bytes()
    matrix = json.loads(encoded)
    if matrix.get("schema") != "stwo-product-matrix-v1":
        raise SystemExit("product matrix has an unknown schema")
    payload = json.dumps(
        {"schema": matrix["schema"], "products": matrix["products"]},
        separators=(",", ":"),
    ).encode()
    if hashlib.sha256(payload).hexdigest() != matrix.get("matrix_sha256"):
        raise SystemExit("product matrix digest is invalid")
    by_id = {product["product_id"]: product for product in matrix["products"]}
    if len(by_id) != len(matrix["products"]):
        raise SystemExit("product matrix contains duplicate product identities")
    return by_id, hashlib.sha256(encoded).hexdigest()


def read_configure_manifest(
    repository: Path,
    scope: str,
    matrix: dict[str, dict[str, object]],
) -> tuple[dict[str, object], str]:
    with tempfile.TemporaryDirectory(prefix="stwo-configure-manifest-") as raw:
        command = [
            "zig",
            "build",
            "configure-manifest",
            "--build-file",
            str(repository / "build_support/internal_build.zig"),
            "--cache-dir",
            str(repository / ".zig-cache/products" / scope),
            f"-Drepository-root={repository}",
            f"-Dproduct-scope={scope}",
            "-p",
            raw,
        ]
        result = subprocess.run(command, cwd=repository, text=True, capture_output=True)
        if result.returncode != 0:
            raise SystemExit(f"{scope} configure manifest failed:\n{result.stderr}")
        path = Path(raw) / f"build-graph/configure-{scope}.json"
        encoded = path.read_bytes()
        manifest = json.loads(encoded)
    if manifest.get("schema") != "stwo-configure-manifest-v2":
        raise SystemExit(f"{scope} configure manifest has an unknown schema")
    if manifest.get("scope") != scope or not manifest.get("constructors"):
        raise SystemExit(f"{scope} configure manifest is incomplete")
    expected = dict(MANIFESTS[scope])
    if "module_roots" not in expected:
        products = [matrix.get(product_id) for product_id in expected["product_ids"]]
        if any(product is None for product in products):
            raise SystemExit(f"{scope} has no authoritative product descriptor")
        expected["module_roots"] = list(
            dict.fromkeys(
                root
                for product in products
                for root in product["module_roots"]  # type: ignore[index]
            )
        )
        declared_runtime = sorted(
            dependency
            for product in products
            for dependency in product["external_dependencies"]  # type: ignore[index]
        )
        if declared_runtime != sorted(expected["runtime_probes"]):
            raise SystemExit(f"{scope} runtime probes diverge from its product descriptor")
    for field, wanted in expected.items():
        if manifest.get(field) != wanted:
            raise SystemExit(
                f"{scope} configure manifest {field} mismatch: "
                f"expected={wanted!r}, actual={manifest.get(field)!r}"
            )
    validate_actual_construction(manifest, matrix, scope)
    return manifest, hashlib.sha256(encoded).hexdigest()


def validate_actual_construction(
    manifest: dict[str, object],
    matrix: dict[str, dict[str, object]],
    scope: str,
) -> None:
    actual = manifest.get("actual")
    if not isinstance(actual, dict):
        raise SystemExit(f"{scope} configure manifest has no observed construction graph")
    for field in ("module_roots", "external_tools", "runtime_probes"):
        values = actual.get(field)
        if not isinstance(values, list) or values != sorted(set(values)):
            raise SystemExit(f"{scope} actual {field} is not a sorted unique list")

    actual_tools = set(actual["external_tools"])
    declared_tools = set(manifest["external_tools"])
    if not actual_tools <= declared_tools:
        raise SystemExit(
            f"{scope} constructed undeclared external tools: "
            f"{sorted(actual_tools - declared_tools)}"
        )
    actual_probes = set(actual["runtime_probes"])
    declared_probes = set(manifest["runtime_probes"])
    if actual_probes != declared_probes:
        raise SystemExit(
            f"{scope} runtime probes diverge from constructed linkage: "
            f"declared={sorted(declared_probes)}, actual={sorted(actual_probes)}"
        )

    selected = [matrix.get(product_id) for product_id in manifest["product_ids"]]
    if not selected or any(product is None for product in selected):
        return
    allowed_files: set[str] = set()
    allowed_prefixes: list[str] = []
    for product in selected:
        assert product is not None
        allowed_files.update(product["module_roots"])
        allowed_files.update(product["allowed_files"])
        allowed_files.update(product["configure_allowed_files"])
        allowed_prefixes.extend(
            prefix.rstrip("/") + "/"
            for prefix in (
                list(product["allowed_prefixes"])
                + list(product["configure_allowed_prefixes"])
            )
        )
    undeclared = [
        path
        for path in actual["module_roots"]
        if path not in allowed_files
        and not any(path.startswith(prefix) for prefix in allowed_prefixes)
    ]
    if undeclared:
        raise SystemExit(f"{scope} constructed undeclared module roots: {undeclared}")


def check_scope(
    repository: Path,
    scope: str,
    expected: set[str],
    matrix: dict[str, dict[str, object]],
) -> dict[str, object]:
    actual, elapsed, output = internal_help(repository, scope)
    wanted = expected | BUILTINS
    missing = sorted(wanted - actual)
    extra = sorted(actual - wanted)
    if missing or extra:
        raise SystemExit(
            f"{scope} configure closure mismatch: missing={missing}, extra={extra}"
        )
    manifest, manifest_digest = read_configure_manifest(repository, scope, matrix)
    return {
        "scope": scope,
        "steps": sorted(actual),
        "help_sha256": hashlib.sha256(output.encode()).hexdigest(),
        "configure_seconds": round(elapsed, 6),
        "manifest": manifest,
        "manifest_sha256": manifest_digest,
    }


def check_unknown_scope(repository: Path) -> None:
    command = [
        "zig",
        "build",
        "--help",
        "--build-file",
        str(repository / "build_support/internal_build.zig"),
        "--cache-dir",
        str(repository / ".zig-cache/products/invalid-scope"),
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
    delegation = (repository / "build_support/graph/delegation.zig").read_text()
    if "delegation.addInstallProxy" not in dispatcher or '"aggregate", "stwo-zig"' not in delegation:
        raise SystemExit("root default install is not pinned to the aggregate CLI only")
    libraries = (repository / "build_support/products/libraries.zig").read_text()
    public_start = libraries.index("pub fn addPublicModules")
    products_start = libraries.index("pub fn addProducts", public_start)
    public_body = libraries[public_start:products_start]
    forbidden = ("addExecutable", "addTest", "addSystemCommand", "addInstall")
    found = [token for token in forbidden if token in public_body]
    if found:
        raise SystemExit(f"declarative public module export constructs build work: {found}")


def inspect_linkage(binary: Path) -> str:
    result = subprocess.run(["otool", "-L", str(binary)], text=True, capture_output=True)
    if result.returncode != 0:
        raise SystemExit(f"cannot inspect aggregate linkage:\n{result.stderr}")
    return result.stdout.lower()


def exercise_install(repository: Path, *, metal: bool) -> dict[str, object]:
    with tempfile.TemporaryDirectory(prefix="stwo-install-closure-") as raw:
        prefix = Path(raw)
        command = [
            "zig",
            "build",
            "stwo-zig" if metal else "install",
            "-Doptimize=ReleaseFast",
            "-p",
            str(prefix),
        ]
        if metal:
            command.append("-Daggregate-metal=true")
        result = subprocess.run(command, cwd=repository, text=True, capture_output=True)
        if result.returncode != 0:
            raise SystemExit(f"aggregate install exercise failed:\n{result.stderr}")
        files = sorted(
            path.relative_to(prefix).as_posix()
            for path in prefix.rglob("*")
            if path.is_file()
        )
        if files != ["bin/stwo-zig"]:
            raise SystemExit(f"aggregate install manifest mismatch: {files}")
        executable = prefix / "bin/stwo-zig"
        registry_run = subprocess.run(
            [str(executable), "applications"], text=True, capture_output=True
        )
        if registry_run.returncode != 0:
            raise SystemExit(f"aggregate registry failed:\n{registry_run.stderr}")
        registry = json.loads(registry_run.stdout)
        availability = registry["backend_availability"]["metal-hybrid"]
        if availability is not metal:
            raise SystemExit("aggregate registry capability does not match selected Metal product")
        for application in registry["applications"]:
            advertised = "metal-hybrid" in application.get("backends", [])
            if advertised is not metal:
                raise SystemExit("aggregate application registry leaks an unselected backend")
        linkage = inspect_linkage(executable) if sys.platform == "darwin" else ""
        has_metal = "metal.framework" in linkage and "foundation.framework" in linkage
        if sys.platform == "darwin" and has_metal is not metal:
            raise SystemExit("aggregate binary linkage does not match selected Metal product")
        return {
            "metal_enabled": metal,
            "files": files,
            "registry_sha256": hashlib.sha256(registry_run.stdout.encode()).hexdigest(),
            "linkage_sha256": hashlib.sha256(linkage.encode()).hexdigest() if linkage else None,
        }


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
    nested_cache = repository / "build_support/.zig-cache"
    nested_cache_preexisting = nested_cache.exists()

    matrix, matrix_receipt_sha256 = read_product_matrix(repository)
    receipts = [
        check_scope(repository, scope, expected, matrix)
        for scope, expected in SCOPES.items()
    ]
    check_unknown_scope(repository)
    check_install_ownership(repository)
    installs = [exercise_install(repository, metal=False)]
    if sys.platform == "darwin":
        installs.append(exercise_install(repository, metal=True))
    if not nested_cache_preexisting and nested_cache.exists():
        raise SystemExit("internal build invocation leaked a build_support/.zig-cache")
    payload = {
        "schema": "stwo-build-configure-closure-v1",
        "result": "pass",
        "default_install_artifacts": ["stwo-zig"],
        "root_declarative_exports": ["stwo_core", "stwo_prover", "stwo"],
        "product_matrix_receipt_sha256": matrix_receipt_sha256,
        "scopes": receipts,
        "install_manifests": installs,
        "negative_checks": [
            "unknown-scope-fails",
            "exact-step-set",
            "focused-install-mutation-rejected",
            "internal-cache-placement",
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
