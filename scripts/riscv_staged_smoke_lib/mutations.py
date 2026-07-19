"""Deterministic hostile artifacts for the installed RISC-V verifier boundary."""

from __future__ import annotations

import json
from typing import Any


def _read_uleb(data: bytes, start: int) -> tuple[int, int]:
    value = 0
    shift = 0
    position = start
    while position < len(data) and shift < 70:
        byte = data[position]
        position += 1
        value |= (byte & 0x7f) << shift
        if not byte & 0x80:
            return value, position
        shift += 7
    raise ValueError("invalid postcard ULEB128")


def _write_uleb(value: int) -> bytes:
    encoded = bytearray()
    while value >= 0x80:
        encoded.append((value & 0x7f) | 0x80)
        value >>= 7
    encoded.append(value)
    return bytes(encoded)


def proof_wire(proof_hex: str) -> dict[str, str]:
    raw = bytes.fromhex(proof_hex)
    position = 0
    for _ in range(5):
        _, position = _read_uleb(raw, position)
    lifting_tag = raw[position]
    position += 1
    if lifting_tag == 1:
        _, position = _read_uleb(raw, position)
    elif lifting_tag != 0:
        raise ValueError("invalid postcard lifting-log option")
    commitments_start = position
    _, commitments_end = _read_uleb(raw, commitments_start)
    length_bomb = (raw[:commitments_start] + _write_uleb(1 << 32) + raw[commitments_end:])
    return {
        "trailing": (raw + b"\x00").hex(),
        "truncated": raw[:-1].hex(),
        "length-bomb": length_bomb.hex(),
    }


def hostile_json(artifact_text: str, payload: dict[str, Any]) -> dict[str, tuple[str, str]]:
    unknown = dict(payload)
    unknown["untrusted_extension"] = True
    relabelled = dict(payload)
    relabelled["release_status"] = (
        "release_gated" if payload["release_status"] == "not_release_gated"
        else "not_release_gated"
    )
    omitted = dict(payload)
    omitted.pop("interaction_claim")
    duplicate = artifact_text.replace(
        '"schema_version":3,',
        '"schema_version":3,"schema_version":3,',
        1,
    )
    return {
        "corrupt-json": ("{", "SyntaxError"),
        "legacy-schema-v2": (
            '{"artifact_kind":"stwo_riscv_proof","schema_version":2,'
            '"exchange_mode":"riscv_proof_json_wire_v2"}',
            "LegacySchemaVersion",
        ),
        "duplicate-header": (duplicate, "DuplicateField"),
        "unknown-field": (json.dumps(unknown), "UnknownField"),
        "omitted-claim": (json.dumps(omitted), "MissingField"),
        "release-relabel": (json.dumps(relabelled), "InvalidReleaseStatus"),
    }
