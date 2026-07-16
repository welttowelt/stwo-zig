#!/usr/bin/env python3
"""Retarget a validated Cairo composition bundle to another proof's trace logs."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import struct


BUNDLE_MAGIC = b"STWZEVA\0"
BUNDLE_VERSION = 1
PROGRAM_MAGIC = 0x31505453
PROGRAM_HEADER_BYTES = 96
PROGRAM_SECTION_BYTES = 24
PROGRAM_DOMAIN_LOG_OFFSET = 60
PROGRAM_SEMANTIC_HASH_OFFSET = 16
PROGRAM_BASE_INSTRUCTIONS = 3
PROGRAM_BASE_CONSTANT_OPCODE = 3


def u16(data: bytes | bytearray, offset: int) -> int:
    return struct.unpack_from("<H", data, offset)[0]


def u32(data: bytes | bytearray, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def trace_logs(proof_path: Path) -> dict[str, int]:
    claim = json.loads(proof_path.read_text())["claim"]
    result: dict[str, int] = {}
    for label, value in claim.items():
        if label == "public_data" or value is None:
            continue
        if "log_size" in value:
            result[label] = int(value["log_size"])
        elif label == "memory_id_to_big":
            logs = value.get("big_log_sizes", [])
            if len(logs) != 1:
                raise ValueError(f"{label} has unsupported instances: {logs}")
            result[label] = int(logs[0])
    return result


def public_segment_starts(proof_path: Path) -> dict[str, int]:
    claim = json.loads(proof_path.read_text())["claim"]
    segments = claim.get("public_data", {}).get("public_memory", {}).get("public_segments", {})
    return {
        label: int(segment["start_ptr"]["value"])
        for label, segment in segments.items()
        if int(segment["start_ptr"]["value"]) != 0
    }


def statement_constant_substitutions(template_proof: Path, target_proof: Path) -> dict[int, int]:
    template = public_segment_starts(template_proof)
    target = public_segment_starts(target_proof)
    substitutions: dict[int, int] = {}
    for label in template.keys() & target.keys():
        old, new = template[label], target[label]
        if old == new:
            continue
        previous = substitutions.setdefault(old, new)
        if previous != new:
            raise ValueError(f"ambiguous statement constant {old}: {previous} or {new}")
    return substitutions


def fnv64(chunks: list[bytes]) -> int:
    result = 0xCBF29CE484222325
    for chunk in chunks:
        for byte in chunk:
            result ^= byte
            result = (result * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return result


def retarget_program_constants(
    data: bytearray,
    program_offset: int,
    program_len: int,
    substitutions: dict[int, int],
) -> tuple[int, int, list[tuple[int, int]]]:
    if not substitutions:
        semantic_hash = struct.unpack_from("<Q", data, program_offset + PROGRAM_SEMANTIC_HASH_OFFSET)[0]
        return semantic_hash, semantic_hash, []
    n_sections = u32(data, program_offset + 8)
    payload_start = program_offset + PROGRAM_HEADER_BYTES + n_sections * PROGRAM_SECTION_BYTES
    program_end = program_offset + program_len
    sections: dict[int, tuple[int, int, int]] = {}
    for index in range(n_sections):
        descriptor = program_offset + PROGRAM_HEADER_BYTES + index * PROGRAM_SECTION_BYTES
        kind, elem_size, relative_offset, count = struct.unpack_from("<IIQQ", data, descriptor)
        start = payload_start + relative_offset
        end = start + elem_size * count
        if end > program_end:
            raise ValueError("program section exceeds its encoded extent")
        sections[kind] = (start, elem_size, count)

    base = sections.get(PROGRAM_BASE_INSTRUCTIONS)
    if base is None or base[1] != 16:
        raise ValueError("evaluation program has no canonical base instruction section")
    replacements: list[tuple[int, int]] = []
    start, _, count = base
    for index in range(count):
        instruction = start + index * 16
        if data[instruction] != PROGRAM_BASE_CONSTANT_OPCODE:
            continue
        old = u32(data, instruction + 4)
        new = substitutions.get(old)
        if new is None:
            continue
        struct.pack_into("<I", data, instruction + 4, new)
        replacements.append((old, new))

    old_hash = struct.unpack_from("<Q", data, program_offset + PROGRAM_SEMANTIC_HASH_OFFSET)[0]
    if not replacements:
        return old_hash, old_hash, []
    canonical_sections: list[bytes] = []
    for kind in range(1, 6):
        section = sections.get(kind)
        if section is None:
            raise ValueError("evaluation program is missing a semantic section")
        section_start, elem_size, section_count = section
        canonical_sections.append(bytes(data[section_start : section_start + elem_size * section_count]))
    new_hash = fnv64(canonical_sections)
    struct.pack_into("<Q", data, program_offset + PROGRAM_SEMANTIC_HASH_OFFSET, new_hash)
    return old_hash, new_hash, replacements


def preprocessed_identities(path: Path) -> list[str]:
    with path.open("rb") as stream:
        if stream.read(8) != b"STWZPPC\0":
            raise ValueError("unsupported preprocessed coefficient fixture")
        version, count = struct.unpack("<II", stream.read(8))
        if version != 1:
            raise ValueError("unsupported preprocessed coefficient fixture")
        result: list[str] = []
        for _ in range(count):
            identity_len, reserved = struct.unpack("<HH", stream.read(4))
            log_size = struct.unpack("<I", stream.read(4))[0]
            value_count = struct.unpack("<Q", stream.read(8))[0]
            if reserved != 0 or value_count != 1 << log_size:
                raise ValueError("invalid preprocessed coefficient fixture")
            result.append(stream.read(identity_len).decode())
            stream.seek(value_count * 4, 1)
        if stream.read(1):
            raise ValueError("trailing preprocessed coefficient fixture data")
        return result


def retarget(
    template_path: Path,
    proof_path: Path,
    output_path: Path,
    preprocessed_path: Path | None = None,
    template_proof_path: Path | None = None,
) -> dict[str, object]:
    data = bytearray(template_path.read_bytes())
    if data[:8] != BUNDLE_MAGIC or u32(data, 8) != BUNDLE_VERSION:
        raise ValueError("unsupported composition bundle")
    logs = trace_logs(proof_path)
    component_count = u32(data, 28)
    offset = 40
    changed: dict[str, tuple[int, int]] = {}
    preprocessed_changes: dict[str, list[dict[str, object]]] = {}
    max_evaluation_log = 0
    identities = preprocessed_identities(preprocessed_path) if preprocessed_path else None
    identity_indices = {identity: index for index, identity in enumerate(identities or [])}
    substitutions = (
        statement_constant_substitutions(template_proof_path, proof_path)
        if template_proof_path is not None
        else {}
    )
    statement_changes: dict[str, list[dict[str, object]]] = {}

    for _ in range(component_count):
        component_offset = offset
        label_len = u16(data, offset)
        if u16(data, offset + 2) != 0:
            raise ValueError("invalid component header")
        trace_log = u32(data, offset + 8)
        evaluation_log = u32(data, offset + 12)
        span_count = u32(data, offset + 24)
        preprocessed_count = u32(data, offset + 28)
        denominator_count = u32(data, offset + 32)
        ext_source_count = u32(data, offset + 36)
        part_count = u32(data, offset + 40)
        offset += 44
        label = data[offset : offset + label_len].decode()
        offset += label_len

        target_log = logs.get(label, trace_log)
        target_evaluation_log = target_log + (evaluation_log - trace_log)
        if target_evaluation_log < target_log:
            raise ValueError(f"invalid evaluation log for {label}")
        if denominator_count != 1 << (target_evaluation_log - target_log):
            raise ValueError(f"denominator geometry changed for {label}")
        struct.pack_into("<II", data, component_offset + 8, target_log, target_evaluation_log)
        if target_log != trace_log:
            changed[label] = (trace_log, target_log)
        max_evaluation_log = max(max_evaluation_log, target_evaluation_log)

        offset += span_count * 12
        if identities is not None and target_log != trace_log:
            old_sequence = f"seq_{trace_log}"
            target_sequence = f"seq_{target_log}"
            for index in range(preprocessed_count):
                index_offset = offset + index * 4
                old_index = u32(data, index_offset)
                if old_index >= len(identities):
                    raise ValueError(f"invalid preprocessed index for {label}")
                if identities[old_index] != old_sequence:
                    continue
                target_index = identity_indices.get(target_sequence)
                if target_index is None:
                    raise ValueError(f"missing {target_sequence} preprocessed column")
                struct.pack_into("<I", data, index_offset, target_index)
                preprocessed_changes.setdefault(label, []).append(
                    {
                        "slot": index,
                        "from": old_sequence,
                        "to": target_sequence,
                        "from_index": old_index,
                        "to_index": target_index,
                    }
                )
        offset += preprocessed_count * 4
        offset += denominator_count * 4
        offset += ext_source_count * 32
        for part_index in range(part_count):
            part_offset = offset
            program_len = u32(data, offset + 4)
            program_offset = offset + 16
            if u32(data, program_offset) != PROGRAM_MAGIC:
                raise ValueError(f"invalid evaluation program for {label}")
            struct.pack_into("<I", data, program_offset + PROGRAM_DOMAIN_LOG_OFFSET, target_log)
            old_hash, new_hash, replacements = retarget_program_constants(
                data, program_offset, program_len, substitutions
            )
            if replacements:
                struct.pack_into("<Q", data, part_offset + 8, new_hash)
                statement_changes.setdefault(label, []).append(
                    {
                        "part": part_index,
                        "from_semantic_hash": f"{old_hash:016x}",
                        "to_semantic_hash": f"{new_hash:016x}",
                        "constants": [
                            {"from": old, "to": new} for old, new in sorted(set(replacements))
                        ],
                    }
                )
            offset = program_offset + program_len

    if offset != len(data):
        raise ValueError("trailing composition bundle data")
    struct.pack_into("<I", data, 24, max_evaluation_log)
    output_path.write_bytes(data)
    return {
        "components": component_count,
        "changed_components": len(changed),
        "changed_preprocessed_components": len(preprocessed_changes),
        "changed_statement_components": len(statement_changes),
        "max_evaluation_log_size": max_evaluation_log,
        "changes": {label: {"from": old, "to": new} for label, (old, new) in changed.items()},
        "preprocessed_changes": preprocessed_changes,
        "statement_changes": statement_changes,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--template", type=Path, required=True)
    parser.add_argument("--proof", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--preprocessed-coefficients", type=Path)
    parser.add_argument("--template-proof", type=Path)
    args = parser.parse_args()
    print(
        json.dumps(
            retarget(
                args.template,
                args.proof,
                args.output,
                args.preprocessed_coefficients,
                args.template_proof,
            ),
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
