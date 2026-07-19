"""Fail-closed schemas and visible snapshots for the installed RISC-V CLI."""

from __future__ import annotations

import hashlib
import json
from collections.abc import Mapping
from typing import Any


HELP_SHA256 = {
    "root-help": "da4c10b0b6b0da94e05b2cab64892184c09143857cecb50837db9cdd6936dad3",
    "prove-help": "5a3e2b0247447a70f39bee934a0f99f2716c4d89d2c728c8e5c73ce180e69901",
    "bench-help": "fc757cc0e2ecb9e8023f7076d715cde4b6fa5c718c5be01be75d1d260b5b570b",
    "verify-help": "8a878cd538b6f27edca958362a1b24fb4a30a8070dc347446221e8e17a327ca5",
    "applications-help": "c375525c99ee84a5e51a3db048fc2ac61a44782536b4d0d8e9a55de826b8bf5b",
}

DIAGNOSTIC_SHA256 = {
    "missing-command": "fdd507078fd393037596c181b570ca9388b68fc382369810562753b24c381e8c",
    "unknown-command": "eead26a36dea31a85ed57b0be9f37e93abd0bc6d429ed196b68e94f756967498",
}

ARTIFACT_FIELDS = {
    "artifact_kind", "schema_version", "exchange_mode", "release_status",
    "generator", "air", "backend", "protocol", "source", "provenance",
    "pcs_config", "statement", "interaction_claim", "proof_bytes_hex",
}
PROVE_REPORT_FIELDS = {
    "schema", "release_status", "experimental", "verified_in_process",
    "total_steps", "n_components", "execution_seconds", "witness_seconds",
    "proving_seconds", "verification_seconds", "total_seconds",
    "statement_sha256", "transcript_blake2s", "implementation_commit",
    "implementation_dirty", "executable_sha256", "proof_path",
}
VERIFY_RECEIPT_FIELDS = {
    "schema", "status", "artifact_kind", "artifact_schema_version",
    "release_status", "security_policy", "statement_sha256", "proof_bytes",
    "proof_sha256", "transcript_blake2s", "implementation_commit",
    "implementation_dirty", "executable_sha256",
}
BENCHMARK_REPORT_FIELDS = {
    "schema", "release_status", "mode", "experimental", "profiled",
    "warmups", "samples", "verified_samples", "total_steps", "n_components",
    "throughput_numerator", "median_seconds", "throughput_mhz",
    "mean_execution_seconds", "mean_witness_seconds", "mean_proving_seconds",
    "mean_verification_seconds", "sample_seconds", "statement_sha256",
    "transcript_blake2s", "implementation_commit", "implementation_dirty",
    "executable_sha256", "artifact_sha256", "proof_path",
}


class ContractError(ValueError):
    """A produced CLI value does not match its release contract."""


def sha256_text(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def strict_json_object(value: str, label: str) -> dict[str, Any]:
    def object_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, item in pairs:
            if key in result:
                raise ContractError(f"{label}: duplicate JSON field {key}")
            result[key] = item
        return result

    try:
        parsed = json.loads(value, object_pairs_hook=object_pairs)
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        raise ContractError(f"{label}: invalid JSON: {error}") from error
    if not isinstance(parsed, dict):
        raise ContractError(f"{label}: expected one JSON object")
    return parsed


def exact_fields(value: Mapping[str, Any], expected: set[str], label: str) -> None:
    actual = set(value)
    if actual != expected:
        missing = sorted(expected - actual)
        unknown = sorted(actual - expected)
        raise ContractError(f"{label}: fields drifted (missing={missing}, unknown={unknown})")


def require_sha256(value: Any, label: str) -> str:
    if not isinstance(value, str) or len(value) != 64 or any(
            byte not in "0123456789abcdef" for byte in value):
        raise ContractError(f"{label}: expected lowercase SHA-256")
    return value


def require_nonnegative_number(value: Any, label: str) -> None:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value < 0:
        raise ContractError(f"{label}: expected a non-negative number")


def validate_visible_snapshot(name: str, value: str, *, diagnostic: bool = False) -> str:
    expected = (DIAGNOSTIC_SHA256 if diagnostic else HELP_SHA256).get(name)
    if expected is None:
        raise ContractError(f"unknown visible snapshot {name}")
    actual = sha256_text(value)
    if actual != expected:
        raise ContractError(f"{name}: visible output drifted ({actual})")
    return actual


def validate_registry(payload: Mapping[str, Any], expected_status: str) -> None:
    exact_fields(
        payload,
        {"schema_version", "backend_availability", "applications", "deferred_adapters"},
        "applications",
    )
    if payload["schema_version"] != 1:
        raise ContractError("applications: unsupported schema")
    if not isinstance(payload["backend_availability"], dict):
        raise ContractError("applications: missing backend availability")
    applications = payload["applications"]
    deferred = payload["deferred_adapters"]
    if not isinstance(applications, list) or not isinstance(deferred, list):
        raise ContractError("applications: adapter lists must be arrays")
    all_entries = [*applications, *deferred]
    matches = [entry for entry in all_entries
               if isinstance(entry, dict) and entry.get("adapter") == "stark-v-rv32im-elf"]
    if len(matches) != 1 or matches[0].get("status") != expected_status:
        raise ContractError("applications: RISC-V release status drifted")
    if matches[0].get("isa") != "rv32im" or matches[0].get("backends") != ["cpu"]:
        raise ContractError("applications: RISC-V capability declaration drifted")


def validate_artifact(
    payload: Mapping[str, Any], *, expected_status: str, expected_commit: str,
    expected_dirty: bool, elf_sha256: str, input_sha256: str, witness_layout_sha256: str,
) -> None:
    exact_fields(payload, ARTIFACT_FIELDS, "artifact")
    if (payload["artifact_kind"], payload["schema_version"], payload["exchange_mode"]) != (
            "stwo_riscv_proof", 3, "riscv_proof_json_wire_v3"):
        raise ContractError("artifact: schema-v3 identity drifted")
    if payload["release_status"] != expected_status or payload["backend"] != "cpu":
        raise ContractError("artifact: release/backend identity drifted")
    source = payload["source"]
    exact_fields(source, {"elf_sha256", "input_sha256"}, "artifact.source")
    if source != {"elf_sha256": elf_sha256, "input_sha256": input_sha256}:
        raise ContractError("artifact: source identity drifted")
    provenance = payload["provenance"]
    exact_fields(provenance, {
        "oracle_repository", "oracle_commit", "implementation_repository",
        "implementation_commit", "implementation_dirty", "witness_layout_sha256",
    }, "artifact.provenance")
    if provenance["implementation_commit"] != expected_commit or \
            provenance["implementation_dirty"] is not expected_dirty:
        raise ContractError("artifact: embedded implementation identity drifted")
    if provenance["witness_layout_sha256"] != witness_layout_sha256:
        raise ContractError("artifact: witness-layout identity drifted")
    proof_hex = payload["proof_bytes_hex"]
    if not isinstance(proof_hex, str) or not proof_hex or len(proof_hex) % 2 or any(
            byte not in "0123456789abcdef" for byte in proof_hex):
        raise ContractError("artifact: proof bytes are not canonical lowercase hex")


def validate_prove_report(
    payload: Mapping[str, Any], *, expected_status: str, experimental: bool,
    statement_sha256: str, proof_path: str, expected_commit: str,
    expected_dirty: bool, executable_sha256: str,
) -> None:
    exact_fields(payload, PROVE_REPORT_FIELDS, "prove report")
    if payload["schema"] != "riscv_prove_v1" or payload["release_status"] != expected_status:
        raise ContractError("prove report: schema/release status drifted")
    if payload["experimental"] is not experimental or payload["verified_in_process"] is not True:
        raise ContractError("prove report: admission or verification state drifted")
    if payload["statement_sha256"] != statement_sha256 or payload["proof_path"] != proof_path:
        raise ContractError("prove report: statement or proof path drifted")
    require_sha256(payload["transcript_blake2s"], "prove report.transcript_blake2s")
    if payload["implementation_commit"] != expected_commit or \
            payload["implementation_dirty"] is not expected_dirty:
        raise ContractError("prove report: build identity drifted")
    if payload["executable_sha256"] != executable_sha256:
        raise ContractError("prove report: executable identity drifted")
    for field in (
        "execution_seconds", "witness_seconds", "proving_seconds",
        "verification_seconds", "total_seconds",
    ):
        require_nonnegative_number(payload[field], f"prove report.{field}")


def validate_verify_receipt(
    payload: Mapping[str, Any], *, expected_status: str, policy: str,
    statement_sha256: str, proof_bytes: bytes, transcript_blake2s: str,
    expected_commit: str, expected_dirty: bool, executable_sha256: str,
) -> None:
    exact_fields(payload, VERIFY_RECEIPT_FIELDS, "verify receipt")
    expected = {
        "schema": "riscv_verify_v1",
        "status": "verified",
        "artifact_kind": "stwo_riscv_proof",
        "artifact_schema_version": 3,
        "release_status": expected_status,
        "security_policy": policy,
        "statement_sha256": statement_sha256,
        "proof_bytes": len(proof_bytes),
        "proof_sha256": hashlib.sha256(proof_bytes).hexdigest(),
        "transcript_blake2s": transcript_blake2s,
        "implementation_commit": expected_commit,
        "implementation_dirty": expected_dirty,
        "executable_sha256": executable_sha256,
    }
    if payload != expected:
        raise ContractError("verify receipt: values drifted")


def validate_benchmark_report(
    payload: Mapping[str, Any], *, expected_status: str, experimental: bool,
    warmups: int, samples: int, proof_path: str, expected_commit: str,
    expected_dirty: bool, executable_sha256: str,
) -> None:
    exact_fields(payload, BENCHMARK_REPORT_FIELDS, "benchmark report")
    if payload["schema"] != "riscv_proof_v1" or payload["mode"] != "bench":
        raise ContractError("benchmark report: schema/mode drifted")
    if payload["release_status"] != expected_status or payload["experimental"] is not experimental:
        raise ContractError("benchmark report: release/admission drifted")
    if payload["warmups"] != warmups or payload["samples"] != samples or \
            payload["verified_samples"] != samples:
        raise ContractError("benchmark report: sample accounting drifted")
    if payload["proof_path"] != proof_path or payload["throughput_numerator"] != "vm_steps":
        raise ContractError("benchmark report: artifact or throughput contract drifted")
    if not isinstance(payload["sample_seconds"], list) or len(payload["sample_seconds"]) != samples:
        raise ContractError("benchmark report: sample array drifted")
    require_sha256(payload["statement_sha256"], "benchmark report.statement_sha256")
    require_sha256(payload["transcript_blake2s"], "benchmark report.transcript_blake2s")
    require_sha256(payload["artifact_sha256"], "benchmark report.artifact_sha256")
    if payload["implementation_commit"] != expected_commit or \
            payload["implementation_dirty"] is not expected_dirty:
        raise ContractError("benchmark report: build identity drifted")
    if payload["executable_sha256"] != executable_sha256:
        raise ContractError("benchmark report: executable identity drifted")
    for field in (
        "median_seconds", "throughput_mhz", "mean_execution_seconds",
        "mean_witness_seconds", "mean_proving_seconds", "mean_verification_seconds",
    ):
        require_nonnegative_number(payload[field], f"benchmark report.{field}")
