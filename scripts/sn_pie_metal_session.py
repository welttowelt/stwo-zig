#!/usr/bin/env python3
"""Versioned, fail-closed client protocol for the persistent SN PIE Metal prover.

The matching Zig runner is ``zig-out/bin/metal-arena-session --jsonl
--rust-verifier <adapter> --rust-verifier-lockfile <Cargo.lock>``. One
request may be in flight, every response is sequence checked, and a successful
response is independently checked against the atomically published proof and
benchmark report.
"""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import math
import os
from pathlib import Path
import re
import selectors
import signal
import shutil
import struct
import subprocess
import tempfile
import time
from typing import BinaryIO, Mapping, Sequence


PROTOCOL = "stwo-zig-metal-prover-session"
# Version 4 adds mandatory ready-time verifier identity and digest-bound
# canonical Rust verification evidence to every committed proof.
VERSION = 4
PROVE_TIMING_SCOPE = "recorded_witness_start_to_verified_proof"
IN_PROCESS_RUNNER_LINKAGE = "in_process"
RUST_VERIFIER_ENVELOPE_ABI = "STWZCVE/1"
RUST_VERIFIER_ADAPTER_VERSION = "0.1.0"
RUST_VERIFIER_MODE = "compact_metal_proof_v1"
RUST_VERIFIER_CARGO_LOCK_SHA256 = (
    "72ee6a80235ff78a6e2c1724a8c6d1c45798c2a11c1c1539bc675af066b0e31c"
)
RUST_VERIFIER_STWO_CAIRO_REVISION = "dcd5834565b7a26a27a614e353c9c60109ebc1d9"
RUST_VERIFIER_STWO_REVISION = "9d7e3d6fa0fc64a0d143a8b2fcb8ee952f4de8f2"
REVISION_PATTERN = re.compile(r"[0-9a-f]{40}")
REQUEST_ID_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}")
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")
CANONICAL_PROOF_PROTOCOL: dict[str, object] = {
    "channel": "blake2s",
    "channel_salt": 0,
    "log_blowup_factor": 1,
    "n_queries": 70,
    "interaction_pow_bits": 24,
    "query_pow_bits": 26,
    "fri_fold_step": 3,
    "fri_lifting": None,
    "fri_log_last_layer_degree_bound": 0,
}
ARTIFACT_MANIFEST_DOMAIN = b"stwo-zig-artifact-manifest\x00"
PROOF_PROTOCOL_DOMAIN = b"stwo-zig-proof-protocol\x00"
ARTIFACT_ROLES = {
    "backend_executable": 1,
    "adapted_input": 2,
    "schedule": 3,
    "witness_programs": 4,
    "multiplicity_feeds": 5,
    "relation_templates": 6,
    "fixed_tables": 7,
    "composition": 8,
    "composition_program": 9,
    "preprocessed_evaluations": 10,
    "preprocessed_tree0_merkle": 11,
    "preprocessed_coefficients": 12,
    "transcript_reference": 13,
    "quotient_reference": 14,
    "raw_pie": 15,
    "adapter_executable": 16,
    "bootloader": 17,
    "schedule_generator": 18,
    "semantic_air": 19,
    "verifier_executable": 20,
    "verifier_lockfile": 21,
}
ARTIFACT_PROVENANCE = {
    "canonical_generated": 1,
    "unattested": 2,
    "proof_derived": 3,
    "diagnostic_fixture": 4,
    "raw": 5,
}


class SessionProtocolError(RuntimeError):
    """The daemon violated the session contract or failed a proof request."""


@dataclass(frozen=True)
class SessionArtifacts:
    adapted_input: Path
    schedule: Path
    witness_programs: Path
    multiplicity_feeds: Path
    relation_templates: Path
    fixed_tables: Path
    composition: Path
    composition_program: Path
    preprocessed_evaluations: Path
    preprocessed_tree0_merkle: Path
    preprocessed_coefficients: Path
    transcript_reference: Path | None = None
    quotient_reference: Path | None = None

    def document(
        self,
        object_references: Mapping[str, ArtifactObjectReference] | None = None,
    ) -> dict[str, dict[str, object]]:
        references = object_references or {}
        present_names = {
            name for name, path in self.__dict__.items() if path is not None
        }
        unknown = references.keys() - present_names
        if unknown:
            raise ValueError(f"object references have unknown artifact roles: {sorted(unknown)}")
        document: dict[str, dict[str, object]] = {}
        for name, path in self.__dict__.items():
            if path is None:
                continue
            reference = references.get(name)
            if reference is None:
                document[name] = {"path": str(path)}
                continue
            if reference.diagnostic_path != path:
                raise ValueError(f"object reference diagnostic path does not match artifacts.{name}")
            document[name] = reference.document()
        return document


@dataclass(frozen=True)
class ArtifactObjectReference:
    object_id: str
    bytes: int
    diagnostic_path: Path

    def document(self) -> dict[str, object]:
        if not isinstance(self.object_id, str) or SHA256_PATTERN.fullmatch(self.object_id) is None:
            raise ValueError("artifact object_id must be lowercase SHA-256")
        if (
            isinstance(self.bytes, bool)
            or not isinstance(self.bytes, int)
            or not 0 < self.bytes <= 0xFFFFFFFFFFFFFFFF
        ):
            raise ValueError("artifact object bytes must be a positive unsigned 64-bit integer")
        _absolute(self.diagnostic_path, "artifact object diagnostic_path")
        return {
            "object_id": self.object_id,
            "bytes": self.bytes,
            "diagnostic_path": str(self.diagnostic_path),
        }


@dataclass(frozen=True)
class ProveRequest:
    sequence: int
    request_id: str
    artifacts: SessionArtifacts
    proof_output: Path
    report_output: Path
    budget_gib: str
    tree0_root_hex: str

    def document(
        self,
        object_references: Mapping[str, ArtifactObjectReference] | None = None,
    ) -> dict[str, object]:
        references = object_references or {}
        validate_request(self, service_object_roles=set(references))
        return {
            "protocol": PROTOCOL,
            "version": VERSION,
            "type": "prove",
            "sequence": self.sequence,
            "request_id": self.request_id,
            "artifacts": self.artifacts.document(references),
            "outputs": {
                "proof": str(self.proof_output),
                "report": str(self.report_output),
            },
            "budget_gib": self.budget_gib,
            "expected_tree0_root_hex": self.tree0_root_hex,
        }


@dataclass(frozen=True)
class VerifiedResult:
    sequence: int
    request_id: str
    adapted_cycles: int
    prove_wall_s: float
    prove_mhz: float
    session_block_wall_s: float
    proof_bytes: int
    proof_sha256: str
    adapted_input_sha256: str
    self_contained: bool
    parity_fixture_used: bool
    proof_derived_artifact_used: bool
    statement_self_derived: bool
    artifact_manifest_digest: str
    artifact_objects: dict[str, dict[str, object]]
    provenance_complete: bool
    proof_protocol: dict[str, object]
    protocol_complete: bool
    daemon_executable_sha256: str
    runner_executable_sha256: str
    runner_linkage: str
    runtime_reused: bool
    resident_arena_reused: bool
    preprocessed_state_reused: bool
    rust_verifier: dict[str, object]
    raw: dict[str, object]


def _absolute(path: Path, label: str) -> None:
    if not path.is_absolute():
        raise ValueError(f"{label} must be absolute: {path}")


def _positive_number(value: object, label: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise SessionProtocolError(f"{label} must be a number")
    result = float(value)
    if not math.isfinite(result) or result <= 0:
        raise SessionProtocolError(f"{label} must be finite and positive")
    return result


def _positive_integer(value: object, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise SessionProtocolError(f"{label} must be a positive integer")
    return value


def _positive_u64(value: object, label: str) -> int:
    result = _positive_integer(value, label)
    if result > 0xFFFFFFFFFFFFFFFF:
        raise SessionProtocolError(f"{label} must fit in an unsigned 64-bit integer")
    return result


def _mapping(value: object, label: str) -> dict[str, object]:
    if not isinstance(value, dict) or not all(isinstance(key, str) for key in value):
        raise SessionProtocolError(f"{label} must be an object")
    return value


def _exact_keys(value: Mapping[str, object], required: set[str], optional: set[str], label: str) -> None:
    missing = required - value.keys()
    unknown = value.keys() - required - optional
    if missing:
        raise SessionProtocolError(f"{label} is missing fields: {sorted(missing)}")
    if unknown:
        raise SessionProtocolError(f"{label} has unknown fields: {sorted(unknown)}")


def _canonical_proof_protocol(value: object, label: str) -> dict[str, object]:
    document = _mapping(value, label)
    _exact_keys(document, set(CANONICAL_PROOF_PROTOCOL), set(), label)
    for name, expected in CANONICAL_PROOF_PROTOCOL.items():
        actual = document[name]
        if isinstance(expected, int):
            valid = isinstance(actual, int) and not isinstance(actual, bool) and actual == expected
        elif expected is None:
            valid = actual is None
        else:
            valid = type(actual) is type(expected) and actual == expected
        if not valid:
            raise SessionProtocolError(f"{label}.{name} has a non-canonical value or type")
    return document


def _canonical_protocol_digest() -> bytes:
    protocol = CANONICAL_PROOF_PROTOCOL
    channel = protocol["channel"]
    assert isinstance(channel, str)
    channel_bytes = channel.encode("utf-8")
    encoded = bytearray(PROOF_PROTOCOL_DOMAIN)
    encoded.extend(struct.pack("<IH", 1, len(channel_bytes)))
    encoded.extend(channel_bytes)
    for name in (
        "channel_salt",
        "log_blowup_factor",
        "n_queries",
        "interaction_pow_bits",
        "query_pow_bits",
        "fri_fold_step",
    ):
        encoded.extend(struct.pack("<I", int(protocol[name])))
    lifting = protocol["fri_lifting"]
    if lifting is None:
        encoded.extend(b"\x00")
    else:
        encoded.extend(b"\x01" + struct.pack("<I", int(lifting)))
    encoded.extend(struct.pack("<I", int(protocol["fri_log_last_layer_degree_bound"])))
    return hashlib.sha256(encoded).digest()


def _compact_protocol_digest(value: object, label: str = "compact proof layout") -> bytes:
    layout = _mapping(value, label)
    _exact_keys(
        layout,
        {
            "interaction_claim_words",
            "sampled_value_words",
            "decommitment_capacity_words",
        },
        set(),
        label,
    )
    interaction_words = _positive_integer(
        layout["interaction_claim_words"], f"{label}.interaction_claim_words"
    )
    sampled_words = _positive_integer(
        layout["sampled_value_words"], f"{label}.sampled_value_words"
    )
    decommitment_words = _positive_integer(
        layout["decommitment_capacity_words"],
        f"{label}.decommitment_capacity_words",
    )
    if interaction_words % 4 or not 1 <= interaction_words // 4 <= 83:
        raise SessionProtocolError(f"{label} has invalid interaction claim geometry")
    if sampled_words % 4 or decommitment_words < 340:
        raise SessionProtocolError(f"{label} has invalid proof geometry")
    encoded = bytearray(112)
    encoded[:8] = b"STWZCP1\0"
    struct.pack_into("<HH", encoded, 8, 1, 112)
    values = {
        16: 1,
        20: 1,
        24: 1,
        28: 0,
        32: 26,
        36: 1,
        40: 70,
        44: 0,
        48: 3,
        52: 0xFFFFFFFF,
        56: 24,
        60: 4,
        64: 4,
        68: 8,
        72: 1,
        76: 12,
        80: interaction_words // 4,
        84: sampled_words,
        88: decommitment_words,
        92: 161,
        96: 3449,
        100: 2268,
        104: 8,
    }
    for offset, word in values.items():
        struct.pack_into("<I", encoded, offset, word)
    return hashlib.sha256(encoded).digest()


def _sha256_bytes(value: object, label: str) -> bytes:
    if not isinstance(value, str) or SHA256_PATTERN.fullmatch(value) is None:
        raise SessionProtocolError(f"{label} must be lowercase SHA-256")
    return bytes.fromhex(value)


def _validated_artifact_manifest(value: object, expected_digest: str) -> dict[str, object]:
    manifest = _mapping(value, "artifact manifest")
    _exact_keys(
        manifest,
        {
            "schema_version",
            "canonical_encoding",
            "protocol_sha256",
            "sha256",
            "classification",
            "entries",
        },
        set(),
        "artifact manifest",
    )
    if manifest["schema_version"] != 1 or manifest["canonical_encoding"] != "STWZAM/1-little-endian":
        raise SessionProtocolError("artifact manifest has an incompatible encoding")
    protocol_digest = _sha256_bytes(manifest["protocol_sha256"], "artifact manifest protocol_sha256")
    if protocol_digest != _canonical_protocol_digest():
        raise SessionProtocolError("artifact manifest protocol digest is not canonical")
    if manifest["sha256"] != expected_digest:
        raise SessionProtocolError("artifact manifest digest does not match the report")
    entries_value = manifest["entries"]
    if not isinstance(entries_value, list) or not entries_value or len(entries_value) > 0xFFFF:
        raise SessionProtocolError("artifact manifest entries must be a non-empty bounded array")

    canonical_entries: list[tuple[int, bytes, bytes]] = []
    production_complete = True
    parity_fixture_used = False
    proof_derived_artifact_used = False
    for index, entry_value in enumerate(entries_value):
        entry = _mapping(entry_value, f"artifact manifest entry {index}")
        _exact_keys(
            entry,
            {
                "role",
                "logical_name",
                "format_version",
                "provenance",
                "bytes",
                "sha256",
                "source_chain_complete",
                "source_digests",
                "generator",
            },
            set(),
            f"artifact manifest entry {index}",
        )
        role = entry["role"]
        provenance = entry["provenance"]
        logical_name = entry["logical_name"]
        if (
            not isinstance(role, str)
            or role not in ARTIFACT_ROLES
            or not isinstance(provenance, str)
            or provenance not in ARTIFACT_PROVENANCE
        ):
            raise SessionProtocolError(f"artifact manifest entry {index} has an unknown enum")
        if not isinstance(logical_name, str):
            raise SessionProtocolError(f"artifact manifest entry {index} logical_name must be a string")
        try:
            logical_name_bytes = logical_name.encode("utf-8")
        except UnicodeEncodeError as error:
            raise SessionProtocolError("artifact logical_name is not UTF-8") from error
        if len(logical_name_bytes) > 0xFFFF:
            raise SessionProtocolError("artifact logical_name is too long")
        format_version = entry["format_version"]
        byte_count = entry["bytes"]
        source_chain_complete = entry["source_chain_complete"]
        if (
            isinstance(format_version, bool)
            or not isinstance(format_version, int)
            or not 0 < format_version <= 0xFFFFFFFF
            or isinstance(byte_count, bool)
            or not isinstance(byte_count, int)
            or not 0 < byte_count <= 0xFFFFFFFFFFFFFFFF
            or not isinstance(source_chain_complete, bool)
        ):
            raise SessionProtocolError(f"artifact manifest entry {index} has invalid scalar fields")
        artifact_digest = _sha256_bytes(entry["sha256"], f"artifact manifest entry {index} sha256")
        source_values = entry["source_digests"]
        if not isinstance(source_values, list) or len(source_values) > 0xFFFF:
            raise SessionProtocolError(f"artifact manifest entry {index} source_digests is invalid")
        source_digests = [
            _sha256_bytes(source, f"artifact manifest entry {index} source digest")
            for source in source_values
        ]
        encoded = bytearray()
        encoded.extend(struct.pack("<HH", ARTIFACT_ROLES[role], len(logical_name_bytes)))
        encoded.extend(logical_name_bytes)
        encoded.extend(struct.pack("<IBQ", format_version, ARTIFACT_PROVENANCE[provenance], byte_count))
        encoded.extend(artifact_digest)
        encoded.extend(struct.pack("<BH", int(source_chain_complete), len(source_digests)))
        for source_digest in source_digests:
            encoded.extend(source_digest)
        generator = entry["generator"]
        if generator is None:
            encoded.extend(b"\x00")
        else:
            generator_doc = _mapping(generator, f"artifact manifest entry {index} generator")
            _exact_keys(
                generator_doc,
                {"executable_sha256", "semantic_version", "compiler_identity", "arguments_sha256"},
                set(),
                f"artifact manifest entry {index} generator",
            )
            semantic_version = generator_doc["semantic_version"]
            compiler_identity = generator_doc["compiler_identity"]
            if not isinstance(semantic_version, str) or not isinstance(compiler_identity, str):
                raise SessionProtocolError("artifact generator strings are invalid")
            semantic_bytes = semantic_version.encode("utf-8")
            compiler_bytes = compiler_identity.encode("utf-8")
            if not semantic_bytes or len(semantic_bytes) > 0xFFFF or not compiler_bytes or len(compiler_bytes) > 0xFFFF:
                raise SessionProtocolError("artifact generator strings are empty or too long")
            encoded.extend(b"\x01")
            encoded.extend(_sha256_bytes(generator_doc["executable_sha256"], "generator executable"))
            encoded.extend(struct.pack("<H", len(semantic_bytes)) + semantic_bytes)
            encoded.extend(struct.pack("<H", len(compiler_bytes)) + compiler_bytes)
            encoded.extend(_sha256_bytes(generator_doc["arguments_sha256"], "generator arguments"))
        canonical_entries.append((ARTIFACT_ROLES[role], logical_name_bytes, bytes(encoded)))

        if provenance == "raw":
            production_complete &= source_chain_complete and generator is None
        elif provenance == "canonical_generated":
            production_complete &= source_chain_complete and generator is not None and bool(source_digests)
        elif provenance == "diagnostic_fixture":
            production_complete = False
            parity_fixture_used = True
        else:
            production_complete = False
            proof_derived_artifact_used = True

    canonical_entries.sort(key=lambda item: (item[0], item[1]))
    if any(
        canonical_entries[index][:2] == canonical_entries[index - 1][:2]
        for index in range(1, len(canonical_entries))
    ):
        raise SessionProtocolError("artifact manifest has duplicate role/logical_name entries")
    encoded_manifest = bytearray(ARTIFACT_MANIFEST_DOMAIN)
    encoded_manifest.extend(struct.pack("<I", 1))
    encoded_manifest.extend(protocol_digest)
    encoded_manifest.extend(struct.pack("<H", len(canonical_entries)))
    for _, _, encoded_entry in canonical_entries:
        encoded_manifest.extend(encoded_entry)
    if hashlib.sha256(encoded_manifest).hexdigest() != expected_digest:
        raise SessionProtocolError("artifact manifest canonical digest does not match")

    classification = _mapping(manifest["classification"], "artifact manifest classification")
    expected_classification = {
        "production_source_chain_complete": production_complete,
        "parity_fixture_used": parity_fixture_used,
        "proof_derived_artifact_used": proof_derived_artifact_used,
    }
    if classification != expected_classification:
        raise SessionProtocolError("artifact manifest classification does not match its entries")
    return manifest


def _validated_artifact_objects(
    value: object,
    request: ProveRequest,
    manifest: Mapping[str, object],
    label: str,
) -> dict[str, dict[str, object]]:
    artifact_objects = _mapping(value, label)
    expected_paths = {
        name: path
        for name, path in request.artifacts.__dict__.items()
        if path is not None
    }
    _exact_keys(artifact_objects, set(expected_paths), set(), label)

    entries_by_role: dict[str, list[Mapping[str, object]]] = {}
    entries = manifest.get("entries")
    if not isinstance(entries, list):
        raise SessionProtocolError("validated artifact manifest lost its entries")
    for entry_value in entries:
        entry = _mapping(entry_value, "artifact manifest entry")
        role = entry.get("role")
        if isinstance(role, str):
            entries_by_role.setdefault(role, []).append(entry)

    normalized: dict[str, dict[str, object]] = {}
    for role, configured_path in expected_paths.items():
        matching_entries = entries_by_role.get(role, [])
        if len(matching_entries) != 1:
            raise SessionProtocolError(
                f"{label}.{role} is not bound by exactly one manifest entry"
            )
        reference = _mapping(artifact_objects[role], f"{label}.{role}")
        _exact_keys(
            reference,
            {"object_id", "bytes", "diagnostic_path"},
            set(),
            f"{label}.{role}",
        )
        object_id = reference["object_id"]
        _sha256_bytes(object_id, f"{label}.{role}.object_id")
        byte_count = _positive_u64(reference["bytes"], f"{label}.{role}.bytes")
        diagnostic_path = reference["diagnostic_path"]
        if not isinstance(diagnostic_path, str) or diagnostic_path != str(configured_path):
            raise SessionProtocolError(
                f"{label}.{role}.diagnostic_path does not match the configured path"
            )
        manifest_entry = matching_entries[0]
        if object_id != manifest_entry.get("sha256"):
            raise SessionProtocolError(
                f"{label}.{role}.object_id does not match the manifest digest"
            )
        if byte_count != manifest_entry.get("bytes"):
            raise SessionProtocolError(
                f"{label}.{role}.bytes does not match the manifest byte count"
            )
        normalized[role] = {
            "object_id": object_id,
            "bytes": byte_count,
            "diagnostic_path": diagnostic_path,
        }
    return normalized


def validate_request(
    request: ProveRequest,
    *,
    require_inputs: bool = True,
    service_object_roles: set[str] | None = None,
) -> None:
    object_roles = service_object_roles or set()
    artifact_names = set(SessionArtifacts.__dataclass_fields__)
    if not object_roles <= artifact_names:
        raise ValueError(f"unknown service object artifact roles: {sorted(object_roles - artifact_names)}")
    if (
        isinstance(request.sequence, bool)
        or not isinstance(request.sequence, int)
        or not 0 <= request.sequence <= 0xFFFFFFFFFFFFFFFF
    ):
        raise ValueError("sequence must be a non-negative unsigned 64-bit integer")
    if REQUEST_ID_PATTERN.fullmatch(request.request_id) is None:
        raise ValueError("request_id has an invalid format")
    try:
        budget = float(request.budget_gib)
    except ValueError as error:
        raise ValueError("budget_gib must be numeric") from error
    if not math.isfinite(budget) or budget <= 0:
        raise ValueError("budget_gib must be finite and positive")
    if SHA256_PATTERN.fullmatch(request.tree0_root_hex) is None:
        raise ValueError("tree0_root_hex must contain 64 lowercase hexadecimal digits")
    has_transcript_reference = request.artifacts.transcript_reference is not None
    has_quotient_reference = request.artifacts.quotient_reference is not None
    if has_transcript_reference != has_quotient_reference:
        raise ValueError(
            "transcript_reference and quotient_reference must be provided together"
        )
    tree_roles = {"preprocessed_evaluations", "preprocessed_tree0_merkle"}
    if object_roles.isdisjoint(tree_roles):
        expected_tree_path = Path(
            f"{request.artifacts.preprocessed_evaluations}.tree0-merkle"
        )
        if request.artifacts.preprocessed_tree0_merkle != expected_tree_path:
            raise ValueError(
                "preprocessed_tree0_merkle must be the evaluations .tree0-merkle companion"
            )
    for name, path in request.artifacts.__dict__.items():
        if path is None:
            continue
        _absolute(path, f"artifacts.{name}")
        if require_inputs and name not in object_roles and not path.is_file():
            raise ValueError(f"missing artifacts.{name}: {path}")
    for label, path in (("outputs.proof", request.proof_output), ("outputs.report", request.report_output)):
        _absolute(path, label)
        if not path.parent.is_dir():
            raise ValueError(f"{label} parent does not exist: {path.parent}")
        if path.exists():
            raise ValueError(f"{label} already exists; refusing a stale output: {path}")
    if request.proof_output == request.report_output:
        raise ValueError("proof and report outputs must be different paths")


def parse_request_document(value: object, *, require_inputs: bool = True) -> ProveRequest:
    """Strict reference parser for the server side of protocol v4."""
    document = _mapping(value, "prove request")
    _exact_keys(
        document,
        {
            "protocol",
            "version",
            "type",
            "sequence",
            "request_id",
            "artifacts",
            "outputs",
            "budget_gib",
            "expected_tree0_root_hex",
        },
        set(),
        "prove request",
    )
    if document["protocol"] != PROTOCOL or document["version"] != VERSION or document["type"] != "prove":
        raise SessionProtocolError("incompatible prove request")
    artifacts = _mapping(document["artifacts"], "request artifacts")
    artifact_names = set(SessionArtifacts.__dataclass_fields__)
    diagnostic_reference_names = {"transcript_reference", "quotient_reference"}
    _exact_keys(
        artifacts,
        artifact_names - diagnostic_reference_names,
        diagnostic_reference_names,
        "request artifacts",
    )
    present_diagnostic_references = diagnostic_reference_names & artifacts.keys()
    if present_diagnostic_references and present_diagnostic_references != diagnostic_reference_names:
        raise SessionProtocolError(
            "transcript_reference and quotient_reference must be provided together"
        )
    outputs = _mapping(document["outputs"], "request outputs")
    _exact_keys(outputs, {"proof", "report"}, set(), "request outputs")

    def path_field(mapping: Mapping[str, object], name: str, label: str) -> Path:
        raw = mapping[name]
        if not isinstance(raw, str) or not raw:
            raise SessionProtocolError(f"{label}.{name} must be a non-empty string")
        return Path(raw)

    artifact_paths: dict[str, Path] = {}
    service_object_roles: set[str] = set()
    for name, raw_reference in artifacts.items():
        reference = _mapping(raw_reference, f"request artifacts.{name}")
        if set(reference) == {"path"}:
            artifact_paths[name] = path_field(reference, "path", f"request artifacts.{name}")
            continue
        if set(reference) != {"object_id", "bytes", "diagnostic_path"}:
            raise SessionProtocolError(
                f"request artifacts.{name} must be exactly a path or service object reference"
            )
        _sha256_bytes(reference["object_id"], f"request artifacts.{name}.object_id")
        _positive_u64(reference["bytes"], f"request artifacts.{name}.bytes")
        artifact_paths[name] = path_field(
            reference, "diagnostic_path", f"request artifacts.{name}"
        )
        service_object_roles.add(name)

    sequence = document["sequence"]
    request_id = document["request_id"]
    budget_gib = document["budget_gib"]
    tree0_root_hex = document["expected_tree0_root_hex"]
    if not isinstance(request_id, str) or not isinstance(budget_gib, str) or not isinstance(tree0_root_hex, str):
        raise SessionProtocolError("request_id, budget_gib, and tree0_root_hex must be strings")
    request = ProveRequest(
        sequence=sequence if isinstance(sequence, int) else -1,
        request_id=request_id,
        artifacts=SessionArtifacts(**{
            name: artifact_paths[name]
            for name in artifact_names
            if name in artifacts
        }),
        proof_output=path_field(outputs, "proof", "outputs"),
        report_output=path_field(outputs, "report", "outputs"),
        budget_gib=budget_gib,
        tree0_root_hex=tree0_root_hex,
    )
    try:
        validate_request(
            request,
            require_inputs=require_inputs,
            service_object_roles=service_object_roles,
        )
    except ValueError as error:
        raise SessionProtocolError(str(error)) from error
    return request


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def resolve_command_executable(command: str) -> Path:
    """Resolve argv[0] once so the measured path is also the path passed to exec."""
    if not isinstance(command, str) or not command:
        raise ValueError("session command executable must be a non-empty string")
    has_separator = os.sep in command or (os.altsep is not None and os.altsep in command)
    if has_separator:
        candidate = Path(command)
        if not candidate.is_absolute():
            candidate = Path.cwd() / candidate
        try:
            resolved = candidate.resolve(strict=True)
        except OSError as error:
            raise ValueError(f"session command executable does not exist: {command}") from error
    else:
        located = shutil.which(command)
        if located is None:
            raise ValueError(f"session command executable is not on PATH: {command}")
        resolved = Path(located).resolve(strict=True)
    if not resolved.is_file() or not os.access(resolved, os.X_OK):
        raise ValueError(f"session command executable is not an executable file: {resolved}")
    return resolved


def _executable_identity(
    value: Mapping[str, object], label: str
) -> tuple[str, str, str]:
    # This authenticates consistency with the launched bytes. An external
    # deployment policy must separately decide whether that digest is allowed.
    daemon_digest = value.get("daemon_executable_sha256")
    runner_digest = value.get("runner_executable_sha256")
    linkage = value.get("runner_linkage")
    if (
        not isinstance(daemon_digest, str)
        or SHA256_PATTERN.fullmatch(daemon_digest) is None
        or not isinstance(runner_digest, str)
        or SHA256_PATTERN.fullmatch(runner_digest) is None
    ):
        raise SessionProtocolError(f"{label} executable identities must be lowercase SHA-256")
    if daemon_digest != runner_digest:
        raise SessionProtocolError(f"{label} in-process daemon and runner identities differ")
    if linkage != IN_PROCESS_RUNNER_LINKAGE:
        raise SessionProtocolError(f"{label} runner_linkage must be in_process")
    return daemon_digest, runner_digest, linkage


def _rust_verifier_identity(value: object, label: str) -> dict[str, object]:
    identity = _mapping(value, label)
    _exact_keys(
        identity,
        {
            "required",
            "schema_version",
            "envelope_abi",
            "adapter_version",
            "executable_sha256",
            "cargo_lock_sha256",
            "stwo_cairo_revision",
            "stwo_revision",
            "verification_mode",
        },
        set(),
        label,
    )
    expected = {
        "required": True,
        "schema_version": 1,
        "envelope_abi": RUST_VERIFIER_ENVELOPE_ABI,
        "adapter_version": RUST_VERIFIER_ADAPTER_VERSION,
        "cargo_lock_sha256": RUST_VERIFIER_CARGO_LOCK_SHA256,
        "stwo_cairo_revision": RUST_VERIFIER_STWO_CAIRO_REVISION,
        "stwo_revision": RUST_VERIFIER_STWO_REVISION,
        "verification_mode": RUST_VERIFIER_MODE,
    }
    for name, required in expected.items():
        if identity[name] != required:
            raise SessionProtocolError(f"{label} has invalid {name}")
    executable = identity["executable_sha256"]
    if not isinstance(executable, str) or SHA256_PATTERN.fullmatch(executable) is None:
        raise SessionProtocolError(f"{label} executable_sha256 must be lowercase SHA-256")
    return dict(identity)


def _rust_verifier_evidence(
    value: object,
    label: str,
    *,
    proof_sha256: str,
    ready_identity: Mapping[str, object] | None = None,
) -> dict[str, object]:
    evidence = _mapping(value, label)
    _exact_keys(
        evidence,
        {
            "schema_version",
            "status",
            "verified",
            "envelope_abi",
            "adapter_version",
            "verification_mode",
            "protocol_digest",
            "statement_digest",
            "proof_digest",
            "provenance_digest",
            "executable_sha256",
            "cargo_lock_sha256",
            "stwo_cairo_revision",
            "stwo_revision",
            "wall_time_ns",
            "service_wall_time_ns",
            "result_sha256",
        },
        set(),
        label,
    )
    expected = {
        "schema_version": 1,
        "status": "passed",
        "verified": True,
        "envelope_abi": RUST_VERIFIER_ENVELOPE_ABI,
        "adapter_version": RUST_VERIFIER_ADAPTER_VERSION,
        "verification_mode": RUST_VERIFIER_MODE,
        "cargo_lock_sha256": RUST_VERIFIER_CARGO_LOCK_SHA256,
        "stwo_cairo_revision": RUST_VERIFIER_STWO_CAIRO_REVISION,
        "stwo_revision": RUST_VERIFIER_STWO_REVISION,
    }
    for name, required in expected.items():
        if evidence[name] != required:
            raise SessionProtocolError(f"{label} has invalid {name}")
    for name in (
        "protocol_digest",
        "statement_digest",
        "proof_digest",
        "provenance_digest",
        "executable_sha256",
        "result_sha256",
    ):
        digest = evidence[name]
        if not isinstance(digest, str) or SHA256_PATTERN.fullmatch(digest) is None:
            raise SessionProtocolError(f"{label} {name} must be lowercase SHA-256")
    if evidence["proof_digest"] != proof_sha256:
        raise SessionProtocolError(
            f"{label} proof_digest SHA-256 does not bind the committed proof"
        )
    for name in ("wall_time_ns", "service_wall_time_ns"):
        timing = evidence[name]
        if isinstance(timing, bool) or not isinstance(timing, int) or timing <= 0:
            raise SessionProtocolError(f"{label} {name} must be a positive integer")
    if evidence["service_wall_time_ns"] < evidence["wall_time_ns"]:
        raise SessionProtocolError(f"{label} service wall time is shorter than verifier wall time")
    if ready_identity is not None:
        for name in (
            "schema_version",
            "envelope_abi",
            "adapter_version",
            "executable_sha256",
            "cargo_lock_sha256",
            "stwo_cairo_revision",
            "stwo_revision",
            "verification_mode",
        ):
            if evidence[name] != ready_identity[name]:
                raise SessionProtocolError(f"{label} {name} drifted from ready identity")
    return dict(evidence)


def validate_ready(message: object) -> dict[str, object]:
    ready = _mapping(message, "ready response")
    _exact_keys(
        ready,
        {
            "protocol",
            "version",
            "type",
            "session_id",
            "daemon_executable_sha256",
            "runner_executable_sha256",
            "runner_linkage",
            "rust_verifier",
            "capabilities",
        },
        set(),
        "ready response",
    )
    if ready["protocol"] != PROTOCOL or ready["version"] != VERSION or ready["type"] != "ready":
        raise SessionProtocolError("incompatible session ready response")
    if not isinstance(ready["session_id"], str) or not ready["session_id"]:
        raise SessionProtocolError("ready response has no session_id")
    _executable_identity(ready, "ready response")
    _rust_verifier_identity(ready["rust_verifier"], "ready Rust verifier")
    capabilities = _mapping(ready["capabilities"], "ready capabilities")
    _exact_keys(
        capabilities,
        {
            "strict_order",
            "atomic_outputs",
            "verified_proofs",
            "runtime_reuse",
            "resident_arena_reuse",
            "preprocessed_state_reuse",
        },
        set(),
        "ready capabilities",
    )
    for name in ("strict_order", "atomic_outputs", "verified_proofs", "runtime_reuse"):
        if capabilities[name] is not True:
            raise SessionProtocolError(f"session requires capability {name}=true")
    for name in ("resident_arena_reuse", "preprocessed_state_reuse"):
        if not isinstance(capabilities[name], bool):
            raise SessionProtocolError(f"ready capability {name} must be boolean")
    return ready


def validate_verified_result(
    message: object,
    request: ProveRequest,
    *,
    expected_executable_sha256: str | None = None,
    expected_rust_verifier: Mapping[str, object] | None = None,
    sent_artifact_objects: Mapping[str, ArtifactObjectReference] | None = None,
) -> VerifiedResult:
    result = _mapping(message, "prove response")
    _exact_keys(
        result,
        {
            "protocol",
            "version",
            "type",
            "status",
            "sequence",
            "request_id",
            "proof_verified",
            "outputs_committed",
            "adapted_cycles",
            "prove_wall_s",
            "prove_timing_scope",
            "prove_mhz",
            "session_block_wall_s",
            "proof_bytes",
            "proof_sha256",
            "adapted_input_sha256",
            "self_contained",
            "parity_fixture_used",
            "proof_derived_artifact_used",
            "statement_self_derived",
            "artifact_manifest_digest",
            "artifact_objects",
            "provenance_complete",
            "proof_protocol",
            "protocol_complete",
            "daemon_executable_sha256",
            "runner_executable_sha256",
            "runner_linkage",
            "rust_verifier",
            "reuse",
        },
        {"pipeline_cache_delta"},
        "prove response",
    )
    if result["protocol"] != PROTOCOL or result["version"] != VERSION or result["type"] != "result":
        raise SessionProtocolError("incompatible prove response")
    proof_protocol = _canonical_proof_protocol(
        result["proof_protocol"], "prove response proof_protocol"
    )
    if result["protocol_complete"] is not True:
        raise SessionProtocolError("prove response protocol_complete must be true")
    daemon_executable_sha256, runner_executable_sha256, runner_linkage = (
        _executable_identity(result, "prove response")
    )
    if (
        expected_executable_sha256 is not None
        and daemon_executable_sha256 != expected_executable_sha256
    ):
        raise SessionProtocolError(
            "prove response executable identity does not match the started session"
        )
    if result["status"] != "verified" or result["proof_verified"] is not True:
        raise SessionProtocolError("session did not return a verified proof")
    if result["outputs_committed"] is not True:
        raise SessionProtocolError("session did not atomically commit its outputs")
    if result["sequence"] != request.sequence or result["request_id"] != request.request_id:
        raise SessionProtocolError("prove response does not match the in-flight request")
    if result["prove_timing_scope"] != PROVE_TIMING_SCOPE:
        raise SessionProtocolError("prove response uses an invalid timing scope")
    cycles = _positive_integer(result["adapted_cycles"], "adapted_cycles")
    prove_wall_s = _positive_number(result["prove_wall_s"], "prove_wall_s")
    prove_mhz = _positive_number(result["prove_mhz"], "prove_mhz")
    expected_mhz = cycles / prove_wall_s / 1_000_000
    if not math.isclose(prove_mhz, expected_mhz, rel_tol=1e-12, abs_tol=1e-12):
        raise SessionProtocolError("prove_mhz does not match adapted_cycles / prove_wall_s / 1e6")
    session_block_wall_s = _positive_number(result["session_block_wall_s"], "session_block_wall_s")
    proof_bytes = _positive_integer(result["proof_bytes"], "proof_bytes")
    proof_sha256 = result["proof_sha256"]
    if not isinstance(proof_sha256, str) or SHA256_PATTERN.fullmatch(proof_sha256) is None:
        raise SessionProtocolError("proof_sha256 must be lowercase hexadecimal")
    rust_verifier = _rust_verifier_evidence(
        result["rust_verifier"],
        "prove response rust_verifier",
        proof_sha256=proof_sha256,
        ready_identity=expected_rust_verifier,
    )
    adapted_input_sha256 = result["adapted_input_sha256"]
    if (
        not isinstance(adapted_input_sha256, str)
        or SHA256_PATTERN.fullmatch(adapted_input_sha256) is None
    ):
        raise SessionProtocolError("adapted_input_sha256 must be lowercase hexadecimal")
    provenance_fields = (
        "self_contained",
        "parity_fixture_used",
        "proof_derived_artifact_used",
        "statement_self_derived",
        "provenance_complete",
    )
    if not all(isinstance(result[field], bool) for field in provenance_fields):
        raise SessionProtocolError("prove response provenance fields must be boolean")
    self_contained = result["self_contained"]
    parity_fixture_used = result["parity_fixture_used"]
    proof_derived_artifact_used = result["proof_derived_artifact_used"]
    statement_self_derived = result["statement_self_derived"]
    provenance_complete = result["provenance_complete"]
    artifact_manifest_digest = result["artifact_manifest_digest"]
    if (
        not isinstance(artifact_manifest_digest, str)
        or SHA256_PATTERN.fullmatch(artifact_manifest_digest) is None
    ):
        raise SessionProtocolError(
            "protocol v4 requires an artifact_manifest_digest with lowercase SHA-256"
        )
    if provenance_complete is not True:
        raise SessionProtocolError(
            "protocol v4 requires complete artifact manifest evidence"
        )
    if self_contained and (
        not provenance_complete
        or parity_fixture_used
        or proof_derived_artifact_used
        or not statement_self_derived
    ):
        raise SessionProtocolError("self-contained provenance fields are contradictory")
    reuse = _mapping(result["reuse"], "reuse")
    _exact_keys(reuse, {"runtime", "resident_arena", "preprocessed_state"}, set(), "reuse")
    if not all(isinstance(value, bool) for value in reuse.values()):
        raise SessionProtocolError("reuse fields must be boolean")
    if reuse["runtime"] is not True:
        raise SessionProtocolError("persistent response did not reuse the Metal runtime")

    proof_path = request.proof_output
    report_path = request.report_output
    if not proof_path.is_file() or proof_path.stat().st_size != proof_bytes:
        raise SessionProtocolError("committed proof is missing or has the wrong size")
    if sha256_file(proof_path) != proof_sha256:
        raise SessionProtocolError("committed proof SHA-256 does not match the response")
    sent_objects = sent_artifact_objects or {}
    sent_adapted = sent_objects.get("adapted_input")
    if sent_adapted is None:
        if sha256_file(request.artifacts.adapted_input) != adapted_input_sha256:
            raise SessionProtocolError("adapted input SHA-256 does not match the response")
    elif sent_adapted.object_id != adapted_input_sha256:
        raise SessionProtocolError(
            "adapted input service object does not match the response digest"
        )
    try:
        report = _mapping(json.loads(report_path.read_text()), "committed benchmark report")
    except (OSError, json.JSONDecodeError) as error:
        raise SessionProtocolError("committed benchmark report is missing or invalid") from error
    for key, expected in (
        ("status", "completed"),
        ("proof_verified", True),
        ("proving_speed_verified", True),
        ("prove_timing_scope", PROVE_TIMING_SCOPE),
    ):
        if report.get(key) != expected:
            raise SessionProtocolError(f"committed benchmark report has invalid {key}")
    report_reuse = _mapping(report.get("reuse"), "committed benchmark report reuse")
    _exact_keys(
        report_reuse,
        {"runtime", "resident_arena", "preprocessed_state"},
        set(),
        "committed benchmark report reuse",
    )
    if not all(isinstance(value, bool) for value in report_reuse.values()):
        raise SessionProtocolError("committed benchmark report reuse fields must be boolean")
    if report_reuse != reuse:
        raise SessionProtocolError(
            "committed benchmark report reuse does not match the response"
        )
    cli_report = _mapping(report.get("cli_report"), "committed benchmark cli_report")
    prepared_state = report.get("prepared_state")
    prepared_state_hit = report.get("prepared_state_cache_hit")
    if (
        (reuse["resident_arena"] or reuse["preprocessed_state"])
        and prepared_state is None
        and prepared_state_hit is None
    ):
        raise SessionProtocolError("warm reuse is missing prepared-state evidence")
    if prepared_state is not None or prepared_state_hit is not None:
        state = _mapping(prepared_state, "committed benchmark prepared_state")
        _exact_keys(
            state,
            {
                "cache_hit",
                "arena_bytes",
                "snapshot_bytes",
                "clear_bytes",
                "capture_gpu_ms",
                "restore_gpu_ms",
            },
            set(),
            "committed benchmark prepared_state",
        )
        if not isinstance(prepared_state_hit, bool) or state["cache_hit"] is not prepared_state_hit:
            raise SessionProtocolError("prepared-state cache-hit evidence is inconsistent")
        if prepared_state_hit is not reuse["resident_arena"] or prepared_state_hit is not reuse["preprocessed_state"]:
            raise SessionProtocolError("prepared-state evidence does not match response reuse")
        for name in ("arena_bytes", "snapshot_bytes", "clear_bytes"):
            if isinstance(state[name], bool) or not isinstance(state[name], int) or state[name] < 0:
                raise SessionProtocolError(f"prepared-state {name} is invalid")
        if state["arena_bytes"] == 0 or state["snapshot_bytes"] == 0:
            raise SessionProtocolError("prepared-state resident and snapshot sizes must be positive")
        for name in ("capture_gpu_ms", "restore_gpu_ms"):
            value = state[name]
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
                raise SessionProtocolError(f"prepared-state {name} is invalid")
        if prepared_state_hit:
            if state["clear_bytes"] != state["arena_bytes"] or state["capture_gpu_ms"] != 0:
                raise SessionProtocolError("warm prepared-state reset telemetry is inconsistent")
        elif state["clear_bytes"] != 0 or state["restore_gpu_ms"] != 0:
            raise SessionProtocolError("cold prepared-state capture telemetry is inconsistent")

        runner_fields = {
            "cache_hit": "prepared_state_cache_hit",
            "arena_bytes": "resident_arena_bytes",
            "snapshot_bytes": "prepared_state_snapshot_bytes",
            "clear_bytes": "prepared_state_clear_bytes",
            "capture_gpu_ms": "prepared_state_capture_gpu_ms",
            "restore_gpu_ms": "prepared_state_restore_gpu_ms",
        }
        for state_name, runner_name in runner_fields.items():
            runner_value = cli_report.get(runner_name)
            if state_name == "cache_hit":
                matches = isinstance(runner_value, bool) and runner_value is state[state_name]
            elif state_name in {"arena_bytes", "snapshot_bytes", "clear_bytes"}:
                matches = (
                    isinstance(runner_value, int)
                    and not isinstance(runner_value, bool)
                    and runner_value == state[state_name]
                )
            else:
                matches = (
                    isinstance(runner_value, (int, float))
                    and not isinstance(runner_value, bool)
                    and math.isfinite(runner_value)
                    and runner_value == state[state_name]
                )
            if not matches:
                raise SessionProtocolError(
                    f"prepared-state {state_name} does not match embedded runner evidence"
                )
    report_protocol = _canonical_proof_protocol(
        report.get("protocol"), "committed benchmark report protocol"
    )
    if report.get("protocol_complete") is not True:
        raise SessionProtocolError("committed benchmark report protocol_complete must be true")
    if report_protocol != proof_protocol:
        raise SessionProtocolError(
            "committed benchmark report protocol does not match the response"
        )
    report_daemon_digest, report_runner_digest, report_runner_linkage = (
        _executable_identity(report, "committed benchmark report")
    )
    if (
        report_daemon_digest != daemon_executable_sha256
        or report_runner_digest != runner_executable_sha256
        or report_runner_linkage != runner_linkage
    ):
        raise SessionProtocolError(
            "committed benchmark report executable identity does not match the response"
        )
    for key in (*provenance_fields, "artifact_manifest_digest"):
        if report.get(key) != result[key]:
            raise SessionProtocolError(
                f"committed benchmark report provenance {key} does not match the response"
            )
    report_rust_verifier = _rust_verifier_evidence(
        report.get("rust_verifier"),
        "committed benchmark report rust_verifier",
        proof_sha256=proof_sha256,
        ready_identity=expected_rust_verifier,
    )
    if report_rust_verifier != rust_verifier:
        raise SessionProtocolError(
            "committed benchmark Rust verifier evidence does not match the response"
        )
    compact_protocol_digest = _compact_protocol_digest(
        cli_report.get("proof_layout"),
        "committed benchmark compact proof layout",
    ).hex()
    if rust_verifier["protocol_digest"] != compact_protocol_digest:
        raise SessionProtocolError(
            "Rust verifier protocol_digest does not match the runner proof layout"
        )
    manifest = _validated_artifact_manifest(
        report.get("artifact_manifest"), artifact_manifest_digest
    )
    response_artifact_objects = _validated_artifact_objects(
        result["artifact_objects"],
        request,
        manifest,
        "prove response artifact_objects",
    )
    report_artifact_objects = _validated_artifact_objects(
        report.get("artifact_objects"),
        request,
        manifest,
        "committed benchmark report artifact_objects",
    )
    if report_artifact_objects != response_artifact_objects:
        raise SessionProtocolError(
            "committed benchmark report artifact_objects do not match the response"
        )
    report_input = _mapping(report.get("input"), "benchmark input")
    report_cycles = report_input.get("adapted_cycles")
    if report_cycles != cycles:
        raise SessionProtocolError("benchmark report adapted_cycles does not match the response")
    if report_input.get("path") != str(request.artifacts.adapted_input):
        raise SessionProtocolError("benchmark report input path does not match the request")
    if report_input.get("sha256") != adapted_input_sha256:
        raise SessionProtocolError("benchmark report input SHA-256 does not match the response")
    for key, expected in (("prove_wall_s", prove_wall_s), ("prove_mhz", prove_mhz)):
        actual = report.get(key)
        if isinstance(actual, bool) or not isinstance(actual, (int, float)) or not math.isclose(
            float(actual), expected, rel_tol=1e-12, abs_tol=1e-12
        ):
            raise SessionProtocolError(f"benchmark report {key} does not match the response")

    return VerifiedResult(
        sequence=request.sequence,
        request_id=request.request_id,
        adapted_cycles=cycles,
        prove_wall_s=prove_wall_s,
        prove_mhz=prove_mhz,
        session_block_wall_s=session_block_wall_s,
        proof_bytes=proof_bytes,
        proof_sha256=proof_sha256,
        adapted_input_sha256=adapted_input_sha256,
        self_contained=self_contained,
        parity_fixture_used=parity_fixture_used,
        proof_derived_artifact_used=proof_derived_artifact_used,
        statement_self_derived=statement_self_derived,
        artifact_manifest_digest=artifact_manifest_digest,
        artifact_objects=response_artifact_objects,
        provenance_complete=provenance_complete,
        proof_protocol=proof_protocol,
        protocol_complete=True,
        daemon_executable_sha256=daemon_executable_sha256,
        runner_executable_sha256=runner_executable_sha256,
        runner_linkage=runner_linkage,
        runtime_reused=reuse["runtime"],
        resident_arena_reused=reuse["resident_arena"],
        preprocessed_state_reused=reuse["preprocessed_state"],
        rust_verifier=rust_verifier,
        raw=result,
    )


class PersistentSessionClient:
    """One-in-flight JSONL client with timeout and process-lifetime enforcement.

    ``daemon_stderr`` is passed directly to the daemon and remains caller-owned.
    This permits durable capture or direct relay without putting a wrapper in
    the authenticated command path.
    """

    def __init__(
        self,
        command: Sequence[str],
        *,
        startup_timeout_s: float = 30.0,
        daemon_stderr: BinaryIO | None = None,
    ):
        if not command:
            raise ValueError("session command must not be empty")
        if not math.isfinite(startup_timeout_s) or startup_timeout_s <= 0:
            raise ValueError("startup timeout must be finite and positive")
        executable_path = resolve_command_executable(command[0])
        self.command = (str(executable_path), *command[1:])
        self.executable_path = executable_path
        self.startup_timeout_s = startup_timeout_s
        self.daemon_stderr = daemon_stderr
        self.process: subprocess.Popen[bytes] | None = None
        self.stderr: BinaryIO | None = None
        self._owns_stderr = False
        self.stdout_buffer = bytearray()
        self.next_sequence = 0
        self.session_id: str | None = None
        self.executable_sha256: str | None = None
        self.rust_verifier_identity: dict[str, object] | None = None
        self._artifact_object_cache: dict[
            tuple[str, str], ArtifactObjectReference
        ] = {}
        self.broken = False

    def start(self) -> dict[str, object]:
        if self.process is not None:
            raise SessionProtocolError("session is already started")
        self._artifact_object_cache.clear()
        executable_sha256_before_spawn = sha256_file(self.executable_path)
        if self.daemon_stderr is None:
            self.stderr = tempfile.TemporaryFile(mode="w+b")
            self._owns_stderr = True
        else:
            self.stderr = self.daemon_stderr
            self._owns_stderr = False
        self.process = subprocess.Popen(
            self.command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=self.stderr,
            start_new_session=True,
        )
        try:
            ready = validate_ready(self._read_message(self.startup_timeout_s))
            ready_digest, _, _ = _executable_identity(ready, "ready response")
            executable_sha256_after_ready = sha256_file(self.executable_path)
            if (
                executable_sha256_before_spawn != ready_digest
                or executable_sha256_after_ready != ready_digest
            ):
                raise SessionProtocolError(
                    "session executable identity changed or does not match daemon self-measurement"
                )
        except Exception:
            self._abort()
            raise
        self.session_id = str(ready["session_id"])
        self.executable_sha256 = ready_digest
        self.rust_verifier_identity = _rust_verifier_identity(
            ready["rust_verifier"], "ready Rust verifier"
        )
        return ready

    def prove(self, request: ProveRequest, *, timeout_s: float) -> VerifiedResult:
        if self.process is None or self.process.stdin is None:
            raise SessionProtocolError("session is not started")
        if self.broken:
            raise SessionProtocolError("session is broken")
        if request.sequence != self.next_sequence:
            raise SessionProtocolError(
                f"expected request sequence {self.next_sequence}, got {request.sequence}"
            )
        if not math.isfinite(timeout_s) or timeout_s <= 0:
            raise ValueError("prove timeout must be finite and positive")
        object_references = self._object_references_for(request)
        payload = json.dumps(
            request.document(object_references), separators=(",", ":")
        ).encode() + b"\n"
        try:
            self._require_executable_unchanged()
            self.process.stdin.write(payload)
            self.process.stdin.flush()
            message = self._read_message(timeout_s)
            response = _mapping(message, "session response")
            if response.get("type") == "error":
                raise SessionProtocolError(self._error_message(response, request))
            verified = validate_verified_result(
                response,
                request,
                expected_executable_sha256=self.executable_sha256,
                expected_rust_verifier=self.rust_verifier_identity,
                sent_artifact_objects=object_references,
            )
            self._remember_artifact_objects(
                request,
                verified.artifact_objects,
                object_references,
            )
        except Exception:
            self.broken = True
            self._abort()
            raise
        self.next_sequence += 1
        return verified

    def _object_references_for(
        self, request: ProveRequest
    ) -> dict[str, ArtifactObjectReference]:
        references: dict[str, ArtifactObjectReference] = {}
        for role, path in request.artifacts.__dict__.items():
            if path is None:
                continue
            reference = self._artifact_object_cache.get((role, str(path)))
            if reference is not None:
                references[role] = reference
        return references

    def _remember_artifact_objects(
        self,
        request: ProveRequest,
        artifact_objects: Mapping[str, Mapping[str, object]],
        sent_references: Mapping[str, ArtifactObjectReference],
    ) -> None:
        candidate = dict(self._artifact_object_cache)
        for role, path in request.artifacts.__dict__.items():
            if path is None:
                continue
            document = artifact_objects.get(role)
            if document is None:
                raise SessionProtocolError(
                    f"validated result lost artifact object role {role}"
                )
            reference = ArtifactObjectReference(
                object_id=str(document["object_id"]),
                bytes=int(document["bytes"]),
                diagnostic_path=Path(str(document["diagnostic_path"])),
            )
            sent = sent_references.get(role)
            if sent is not None and reference != sent:
                raise SessionProtocolError(
                    f"prove response changed the service object for artifacts.{role}"
                )
            candidate[(role, str(path))] = reference
        self._artifact_object_cache = candidate

    def close(self, *, timeout_s: float = 5.0) -> None:
        process = self.process
        if process is None:
            return
        if not self.broken and process.stdin is not None and process.poll() is None:
            shutdown = {
                "protocol": PROTOCOL,
                "version": VERSION,
                "type": "shutdown",
                "next_sequence": self.next_sequence,
            }
            try:
                self._require_executable_unchanged()
                process.stdin.write(json.dumps(shutdown, separators=(",", ":")).encode() + b"\n")
                process.stdin.flush()
                response = _mapping(self._read_message(timeout_s), "shutdown response")
                expected = {
                    "protocol": PROTOCOL,
                    "version": VERSION,
                    "type": "closed",
                    "completed": self.next_sequence,
                }
                if response != expected:
                    raise SessionProtocolError("invalid shutdown response")
                process.wait(timeout=timeout_s)
                if process.returncode != 0:
                    raise SessionProtocolError(f"session exited with status {process.returncode}")
                self._require_executable_unchanged()
            except Exception:
                self._abort()
                raise
        else:
            self._abort()
        self._release()

    def __enter__(self) -> PersistentSessionClient:
        self.start()
        return self

    def __exit__(self, exc_type, exc_value, traceback) -> None:
        if exc_type is None:
            self.close()
        else:
            self._abort()

    def _read_message(self, timeout_s: float) -> object:
        process = self.process
        if process is None or process.stdout is None:
            raise SessionProtocolError("session is not started")
        deadline = time.monotonic() + timeout_s
        while True:
            newline = self.stdout_buffer.find(b"\n")
            if newline >= 0:
                encoded = bytes(self.stdout_buffer[:newline])
                del self.stdout_buffer[: newline + 1]
                if not encoded:
                    raise SessionProtocolError("session emitted an empty frame")
                try:
                    return json.loads(encoded)
                except json.JSONDecodeError as error:
                    raise SessionProtocolError("session emitted invalid JSON") from error
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise SessionProtocolError("session response timed out")
            selector = selectors.DefaultSelector()
            try:
                selector.register(process.stdout, selectors.EVENT_READ)
                if not selector.select(remaining):
                    raise SessionProtocolError("session response timed out")
                chunk = os.read(process.stdout.fileno(), 64 * 1024)
            finally:
                selector.close()
            if not chunk:
                raise SessionProtocolError(
                    f"session closed stdout with status {process.poll()}: {self._stderr_tail()}"
                )
            self.stdout_buffer.extend(chunk)
            if len(self.stdout_buffer) > 4 * 1024 * 1024:
                raise SessionProtocolError("session frame exceeds 4 MiB")

    def _error_message(self, response: Mapping[str, object], request: ProveRequest) -> str:
        if response.get("protocol") != PROTOCOL or response.get("version") != VERSION:
            return "session returned an incompatible error frame"
        if response.get("sequence") != request.sequence or response.get("request_id") != request.request_id:
            return "session error does not match the in-flight request"
        code = response.get("code")
        message = response.get("message")
        if not isinstance(code, str) or not isinstance(message, str):
            return "session returned an invalid error frame"
        stderr_tail = self._stderr_tail().strip()
        detail = f"\n{stderr_tail}" if stderr_tail else ""
        return f"session proof failed [{code}]: {message}{detail}"

    def _stderr_tail(self) -> str:
        if self.stderr is None:
            return ""
        try:
            self.stderr.flush()
            length = self.stderr.seek(0, os.SEEK_END)
            self.stderr.seek(max(0, length - 4096))
            return self.stderr.read().decode(errors="replace")
        except (OSError, ValueError):
            # A caller may relay directly to a write-only or non-seekable stream.
            return ""

    def _require_executable_unchanged(self) -> None:
        if self.executable_sha256 is None:
            raise SessionProtocolError("session has no authenticated executable measurement")
        try:
            current_digest = sha256_file(self.executable_path)
        except OSError as error:
            raise SessionProtocolError(
                "session executable path became unavailable after startup"
            ) from error
        if current_digest != self.executable_sha256:
            raise SessionProtocolError("session executable path changed after startup")

    def _abort(self) -> None:
        process = self.process
        if process is not None and process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
        self._release()

    def _release(self) -> None:
        if self.process is not None:
            if self.process.stdin is not None:
                self.process.stdin.close()
            if self.process.stdout is not None:
                self.process.stdout.close()
        if self.stderr is not None and self._owns_stderr:
            self.stderr.close()
        self.process = None
        self.stderr = None
        self._owns_stderr = False
        self._artifact_object_cache.clear()
