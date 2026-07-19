"""Command-specific authorities for architecture evidence outputs."""

from __future__ import annotations

import json
import stat
from pathlib import Path
from typing import Any

from scripts.architecture_host_gate_lib import aggregate_parity, link_closure
from scripts.architecture_host_gate_lib.capture import sha256_file
from scripts.architecture_host_gate_lib.products import _canonical, _normalize
from scripts.benchmark_delta_lib.product_identity import validate_native_v6_report
from scripts.build_architecture_receipt_lib.model import ReceiptError
from scripts.e2e_interop_lib.controller import SUPPORTED_EXAMPLES
from scripts.e2e_interop_lib.evidence import ARCHIVE_PROTOCOL
from scripts.metal_core_aot_receipt_lib import artifacts as aot_artifacts
from scripts.metal_core_aot_receipt_lib import controller as aot_controller
from scripts.metal_core_aot_receipt_lib.model import BUILD_SCHEMA
from scripts.product_identity_lib import validate_canonical_identity
from scripts.riscv_release_challenge_lib import model as challenge_model


EXECUTABLE_COMMANDS = {
    "native-cpu-product",
    "native-metal-product",
    "native-metal-rust-oracle-build",
    "metal-aot-builder",
    "riscv-product",
}
IDENTITY_COMMANDS = {"core-prover", "aggregate"}
LINK_COMMANDS = {
    "native-cpu-link-closure": ("stwo-native-cpu", "zig-out/bin/stwo-zig-native-cpu", None),
    "native-metal-link-closure": ("stwo-native-metal", "zig-out/bin/stwo-zig-native-metal", None),
    "riscv-link-closure": (
        "stwo-riscv-cpu", "zig-out/bin/stwo-zig-riscv-cpu",
        "zig-out/bin/stwo-zig-riscv-cpu-x86_64-linux-musl",
    ),
    "aggregate-link-closure": ("stwo-zig", "zig-out/bin/stwo-zig", None),
}
PROVE_COMMANDS = {
    "focused-parity-prove": "stwo-native-cpu",
    "aggregate-parity-prove": "stwo-zig",
}
KNOWN_OUTPUT_COMMANDS = (
    EXECUTABLE_COMMANDS
    | IDENTITY_COMMANDS
    | set(LINK_COMMANDS)
    | set(PROVE_COMMANDS)
    | {
        "product-matrix", "riscv-fast-challenge-issue",
        "riscv-fast-challenge-execute", "aggregate-parity-compare",
        "configure-closure", "native-rust-oracle", "metal-aot-receipt",
        "native-metal-oracle-matrix", "native-metal-formal-matrix",
        "formal-performance-evidence",
    }
)


def _strict_json(path: Path) -> dict[str, Any]:
    def unique(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        value: dict[str, Any] = {}
        for key, item in pairs:
            if key in value:
                raise ReceiptError(f"duplicate evidence field in {path}: {key}")
            value[key] = item
        return value

    raw = path.read_bytes()
    if not raw or len(raw) > 64 * 1024 * 1024:
        raise ReceiptError(f"architecture evidence size is invalid: {path}")
    value = json.loads(raw.decode("utf-8"), object_pairs_hook=unique)
    if not isinstance(value, dict):
        raise ReceiptError(f"architecture evidence is not an object: {path}")
    return value


def input_digest(path: Path) -> str:
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode) or path.is_symlink() or metadata.st_size == 0:
        raise ReceiptError(f"required architecture input is not a nonempty regular file: {path}")
    return sha256_file(path)


def _executables(outputs: list[Path]) -> None:
    if not outputs:
        raise ReceiptError("executable-producing command declared no artifacts")
    for output in outputs:
        metadata = output.lstat()
        if (
            not stat.S_ISREG(metadata.st_mode)
            or output.is_symlink()
            or metadata.st_size == 0
            or metadata.st_mode & 0o111 == 0
        ):
            raise ReceiptError(f"generated product is not an executable regular file: {output}")


def _identity_receipt(path: Path) -> dict[str, Any]:
    value = _strict_json(path)
    if value.get("schema") != "stwo-product-artifact-identity-v1":
        raise ReceiptError(f"product artifact identity schema drifted: {path}")
    normalized, artifact, _ = _normalize(value)
    identity = validate_canonical_identity(_canonical(normalized), context=str(path))
    if not isinstance(artifact, str) or len(artifact) != 64:
        raise ReceiptError(f"product artifact digest is missing: {path}")
    return identity


def _identities(outputs: list[Path]) -> None:
    identities = [_identity_receipt(path) for path in outputs if path.suffix == ".json"]
    if not identities:
        raise ReceiptError("identity command emitted no canonical identity receipts")
    names = [identity["name"] for identity in identities]
    if len(names) != len(set(names)):
        raise ReceiptError("identity command emitted duplicate product identities")
    for output in outputs:
        if output.suffix != ".json":
            _executables([output])


def _product_matrix(path: Path) -> None:
    value = _strict_json(path)
    if set(value) != {"schema", "products"} or value["schema"] != "stwo-product-matrix-v1":
        raise ReceiptError("product matrix identity schema drifted")
    products = value["products"]
    if not isinstance(products, list) or not products:
        raise ReceiptError("product matrix has no products")
    identities = [validate_canonical_identity(item, context="product matrix") for item in products]
    names = [item["name"] for item in identities]
    if names != sorted(names) or len(names) != len(set(names)):
        raise ReceiptError("product matrix identity order or coverage is non-canonical")


def _prove(outputs: list[Path], product: str) -> None:
    if len(outputs) != 2:
        raise ReceiptError("profiled parity command must emit proof and report")
    proof_path = next((path for path in outputs if path.name.endswith("proof.json")), None)
    report_path = next((path for path in outputs if path.name.endswith("report.json")), None)
    if proof_path is None or report_path is None:
        raise ReceiptError("profiled parity proof/report naming drifted")
    _, _, proof_digest = aggregate_parity.artifact(proof_path)
    report, _ = aggregate_parity.report(report_path, product, proof_digest)
    if aggregate_parity.stage_topology(report["timing"]["stage_profiles"]) is None:
        raise ReceiptError("profiled parity report contains no production stage tree")


def _configure_closure(path: Path) -> None:
    value = _strict_json(path)
    if set(value) != {
        "schema", "result", "default_install_artifacts", "scopes", "negative_checks",
    }:
        raise ReceiptError("configure-closure receipt fields drifted")
    if (
        value["schema"] != "stwo-build-configure-closure-v1"
        or value["result"] != "pass"
        or value["default_install_artifacts"] != ["stwo-zig"]
        or value["negative_checks"] != [
            "unknown-scope-fails", "exact-step-set", "focused-install-mutation-rejected",
        ]
    ):
        raise ReceiptError("configure-closure receipt did not pass its exact contract")
    scopes = value["scopes"]
    expected = {
        "architecture", "core", "prover", "native_cpu", "native_metal", "riscv_cpu",
        "policy", "metal_tools", "deferred",
    }
    if not isinstance(scopes, list) or {item.get("scope") for item in scopes if isinstance(item, dict)} != expected:
        raise ReceiptError("configure-closure receipt scope coverage drifted")
    for item in scopes:
        if set(item) != {"scope", "steps", "help_sha256", "configure_seconds"}:
            raise ReceiptError("configure-closure scope receipt fields drifted")
        if not isinstance(item["steps"], list) or not item["steps"]:
            raise ReceiptError("configure-closure scope has no configured steps")


def _native_oracle(path: Path) -> None:
    value = _strict_json(path)
    required = {
        "status", "schema_version", "exchange_mode", "upstream_commit", "rust_toolchain",
        "summary", "mutation_coverage", "cases", "steps", "artifacts", "failure",
        "generated_at_unix", "duration_seconds", "archive",
    }
    if set(value) != required or value["status"] != "ok" or value["failure"] is not None:
        raise ReceiptError("Native Rust-oracle report did not pass its exact schema")
    summary = value["summary"]
    examples = list(SUPPORTED_EXAMPLES)
    if (
        not isinstance(summary, dict)
        or summary.get("examples") != examples
        or summary.get("cases_total") != len(examples) * 2
        or summary.get("cases_passed") != len(examples) * 2
        or summary.get("cases_failed") != 0
        or summary.get("tamper_cases_failed") != 0
        or summary.get("tamper_cases_passed") != summary.get("tamper_cases_total")
    ):
        raise ReceiptError("Native Rust-oracle report lacks all-six AIR/tamper coverage")
    cases = value["cases"]
    if not isinstance(cases, list) or [item.get("example") for item in cases] != examples or any(
        item.get("status") != "ok" or len(item.get("directions", [])) != 2 for item in cases
    ):
        raise ReceiptError("Native Rust-oracle exchange directions are incomplete")
    archive = value["archive"]
    if not isinstance(archive, dict) or archive.get("protocol") != ARCHIVE_PROTOCOL:
        raise ReceiptError("Native Rust-oracle content-addressed archive is missing")
    receipt = Path(archive["directory"]) / archive["receipt_path"]
    if sha256_file(receipt) != archive.get("receipt_sha256"):
        raise ReceiptError("Native Rust-oracle archived receipt digest drifted")


def _matrix(path: Path, *, formal: bool) -> None:
    value = _strict_json(path)
    validate_native_v6_report(value, str(path))
    configuration = value.get("configuration", {})
    summary = value.get("summary", {})
    if configuration.get("formal") is not formal:
        raise ReceiptError("Native matrix formal classification drifted")
    if (
        summary.get("all_proofs_verified_and_byte_identical") is not True
        or summary.get("all_cross_backend_proofs_identical") is not True
        or summary.get("all_rust_oracles_verified") is not True
        or value.get("correctness_scope", {}).get("final_correctness_oracle")
        != "pinned Rust Stwo"
    ):
        raise ReceiptError("Native matrix lacks CPU/Metal/Rust three-way acceptance")
    if formal and (
        configuration.get("warmups_per_lane", 0) < 10
        or configuration.get("samples_per_lane", 0) < 10
        or summary.get("all_rows_meet_stability_contract") is not True
        or summary.get("all_rows_headline_eligible") is not True
    ):
        raise ReceiptError("formal Native matrix is below the epoch sampling contract")


def _metal_aot(path: Path, candidate: str) -> None:
    receipt, _ = aot_artifacts.read_receipt(path, BUILD_SCHEMA)
    recorded = aot_controller.require_build_receipt(receipt, candidate)
    bundles = {
        name: aot_artifacts.load_bundle(path.parent / name)
        for name in ("build-a", "build-b")
    }
    for name, bundle in bundles.items():
        aot_controller.require_recorded_bundle(recorded[name], bundle, name)
    aot_artifacts.require_reproducible(bundles["build-a"], bundles["build-b"])


def validate_outputs(
    command_id: str, outputs: list[Path], inputs: list[Path], *, root: Path, candidate: str,
) -> dict[str, str]:
    """Validate output meaning and return exact digests; unknown authorities fail closed."""

    if command_id not in KNOWN_OUTPUT_COMMANDS:
        raise ReceiptError(f"no authoritative output validator for command: {command_id}")
    if not outputs:
        raise ReceiptError(f"evidence command declared no generated output: {command_id}")
    if command_id in EXECUTABLE_COMMANDS:
        _executables(outputs)
    elif command_id in IDENTITY_COMMANDS:
        _identities(outputs)
    elif command_id == "product-matrix":
        _product_matrix(outputs[0])
    elif command_id in LINK_COMMANDS:
        product, binary, static_binary = LINK_COMMANDS[command_id]
        link_closure.validate_receipt(
            outputs[0], product=product, binary=Path(binary),
            static_binary=Path(static_binary) if static_binary is not None else None,
        )
    elif command_id == "riscv-fast-challenge-issue":
        challenge_model.validate_challenge(_strict_json(outputs[0]))
    elif command_id == "riscv-fast-challenge-execute":
        challenge = _strict_json(next(path for path in inputs if path.name == "riscv-challenge.json"))
        challenge_model.validate_result(_strict_json(outputs[0]), challenge, outputs[0].parent)
    elif command_id in PROVE_COMMANDS:
        _prove(outputs, PROVE_COMMANDS[command_id])
    elif command_id == "aggregate-parity-compare":
        aggregate_parity.validate_receipt(outputs[0])
    elif command_id == "configure-closure":
        _configure_closure(outputs[0])
    elif command_id == "native-rust-oracle":
        _native_oracle(outputs[0])
    elif command_id == "native-metal-oracle-matrix":
        _matrix(outputs[0], formal=False)
    elif command_id == "native-metal-formal-matrix":
        _matrix(outputs[0], formal=True)
    elif command_id == "metal-aot-receipt":
        _metal_aot(outputs[0], candidate)
    elif command_id == "formal-performance-evidence":
        raise ReceiptError(
            "BG-14 remains NO-GO until an epoch-2 architecture performance validator and baseline exist"
        )
    return {path.relative_to(root).as_posix(): input_digest(path) for path in outputs}
