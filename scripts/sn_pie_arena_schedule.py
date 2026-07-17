#!/usr/bin/env python3
"""Retarget a captured SN PIE arena schedule to another Rust proof claim."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import math
import mmap
from pathlib import Path
import struct


ROW_LINEAR_PURPOSES = {
    "BaseTrace",
    "BaseCoefficients",
    "InteractionTrace",
    "InteractionCoefficients",
    "LookupInputs",
    "SubcomponentInputs",
    "WitnessInput",
    "WitnessInputCompactTupleScratch",
    "WitnessInputCompactSortKey",
    "WitnessInputCompactSortIndex",
    "WitnessInputCompactRunHeads",
    "WitnessInputCompactRunPositions",
    "WitnessInputCompactSortTemp",
    "WitnessInputCompactScanTemp",
    "EcOpPartialIota",
}
COMPACT_SOURCE_COMPONENTS = {
    "pedersen_aggregator_window_bits_18": "pedersen_builtin",
    "poseidon_aggregator": "poseidon_builtin",
}
COMPACT_GEOMETRY = {
    "verify_instruction": {
        "tuple_words": 7,
        "edges": (
            "add_opcode",
            "add_opcode_small",
            "add_ap_opcode",
            "assert_eq_opcode",
            "assert_eq_opcode_imm",
            "assert_eq_opcode_double_deref",
            "blake_compress_opcode",
            "call_opcode_abs",
            "call_opcode_rel_imm",
            "generic_opcode",
            "jnz_opcode_non_taken",
            "jnz_opcode_taken",
            "jump_opcode_abs",
            "jump_opcode_double_deref",
            "jump_opcode_rel",
            "jump_opcode_rel_imm",
            "mul_opcode",
            "mul_opcode_small",
            "qm_31_add_mul_opcode",
            "ret_opcode",
        ),
    },
    "pedersen_aggregator_window_bits_18": {
        "tuple_words": 3,
        "edges": ("pedersen_builtin",),
    },
    "poseidon_aggregator": {
        "tuple_words": 6,
        "edges": ("poseidon_builtin",),
    },
}
COEFFICIENT_PURPOSES = (
    "BaseCoefficients",
    "InteractionCoefficients",
    "CompositionCoefficients",
)
RELATION_MAGIC = b"STWZREL\0"
FIXED_MAGIC = b"STWZFIX\0"
FIXED_PROJECTED_VERSION = 2
FIXED_GRAPH_HASH = 0x7383DE8A8DF6398B
FIXED_PLAN_HASH_OFFSET = 28
COMPOSITION_MAGIC = b"STWZEVA\0"
COMPOSITION_VERSIONS = (1, 2)
ADAPTED_INPUT_MAGIC = b"STWZCPI\0"
ADAPTED_INPUT_VERSION = 1
OPCODE_COUNT = 20
BUILTIN_SEGMENT_COUNT = 9
PEDERSEN_SEGMENT_INDEX = 4
POSEIDON_SEGMENT_INDEX = 5
FRI_FOLD_STEP = 3
FRI_FINAL_LOG = 1
FRI_PACKED_LOG = 2
PROOF_FIXED_TRANSCRIPT_INPUT_ORDINALS = (
    3,
    20,
    23,
    24,
    22,
    21,
    25,
    30,
    31,
)
FRI_TRANSCRIPT_ORDINAL_BASE = 1 << 16
FRI_TRANSCRIPT_ORDINAL_STRIDE = 4
COMPONENT_ORDINAL_PURPOSES = {
    "CompositionExtParams",
    "RelationClaimedSum",
    "RelationDenominators",
    "RelationOutputPointers",
    "RelationSourcePointers",
}
COMPOSITION_PROJECTION_FORMAT = "stwo-zig-cairo-composition-projection"
TRACE_GROUP_PURPOSES = {
    "DecommitTraceEvaluationPointers": 2,
    "DecommitTraceEvaluationLogs": 1,
}
OBSOLETE_COMMIT_GROUP_PURPOSES = {
    "CommitColumnPointers",
    "CommitCoefficientPointers",
    "CommitCoefficientSizes",
    "CommitOutputPointers",
}


def proof_rows(path: Path) -> dict[str, list[int]]:
    claim = json.loads(path.read_text())["claim"]
    rows: dict[str, list[int]] = {}
    for label, value in claim.items():
        if label == "public_data" or value is None or not isinstance(value, dict):
            continue
        if "log_size" in value:
            rows[label] = [1 << int(value["log_size"])]
        elif label == "memory_id_to_big":
            rows[label] = [1 << int(log_size) for log_size in value.get("big_log_sizes", [])]
    memory_small = claim.get("memory_id_to_small")
    if isinstance(memory_small, dict) and "log_size" in memory_small:
        rows.setdefault("memory_id_to_big", []).append(1 << int(memory_small["log_size"]))
    return rows


def proof_components(path: Path) -> list[str]:
    claim = json.loads(path.read_text())["claim"]
    return [
        label
        for label, value in claim.items()
        if label != "public_data" and value is not None
    ]


def proof_tree_columns(path: Path) -> tuple[int, int, int, int]:
    proof = json.loads(path.read_text())
    stark_proof = proof.get("stark_proof")
    if stark_proof is None:
        extended = proof.get("extended_stark_proof")
        stark_proof = extended.get("proof") if isinstance(extended, dict) else None
    if not isinstance(stark_proof, dict):
        raise ValueError("proof has no canonical STARK payload")
    queried = stark_proof.get("queried_values")
    sampled = stark_proof.get("sampled_values")
    if not isinstance(queried, list) or not isinstance(sampled, list):
        raise ValueError("proof has no sampled/queried tree geometry")
    if len(queried) != 4 or len(sampled) != 4:
        raise ValueError("proof must have four commitment trees")
    result = tuple(len(tree) for tree in queried)
    if result != tuple(len(tree) for tree in sampled):
        raise ValueError("sampled and queried tree geometry disagree")
    return result


def preprocessed_identities(path: Path) -> list[str]:
    with path.open("rb") as stream:
        if stream.read(8) != b"STWZPPC\0":
            raise ValueError("unsupported preprocessed coefficient fixture")
        version, count = struct.unpack("<II", stream.read(8))
        if version != 1 or count == 0 or count > 1 << 16:
            raise ValueError("invalid preprocessed coefficient fixture")
        result: list[str] = []
        for _ in range(count):
            identity_len, reserved = struct.unpack("<HH", stream.read(4))
            log_size = struct.unpack("<I", stream.read(4))[0]
            value_count = struct.unpack("<Q", stream.read(8))[0]
            if reserved != 0 or identity_len == 0 or value_count != 1 << log_size:
                raise ValueError("invalid preprocessed coefficient entry")
            result.append(stream.read(identity_len).decode())
            stream.seek(value_count * 4, 1)
        if stream.read(1):
            raise ValueError("trailing preprocessed coefficient fixture data")
        return result


def target_preprocessed_identities(source: list[str], target_proof_path: Path) -> list[str]:
    proof = json.loads(target_proof_path.read_text())
    variant = proof.get("preprocessed_trace_variant")
    if variant == "canonical":
        result = list(source)
    elif variant == "canonical_without_pedersen":
        result = [identity for identity in source if not identity.startswith("pedersen_points_")]
    else:
        raise ValueError(f"unsupported target preprocessed variant: {variant!r}")
    if len(result) != proof_tree_columns(target_proof_path)[0]:
        raise ValueError("target preprocessed identities do not match proof tree 0")
    return result


def project_preprocessed_geometry(
    schedule: list[dict[str, object]], source: list[str], target: list[str]
) -> tuple[list[dict[str, object]], int]:
    target_indices = {identity: index for index, identity in enumerate(target)}
    if len(target_indices) != len(target):
        raise ValueError("target preprocessed identities contain duplicates")
    source_to_target = {
        source_index: target_indices[identity]
        for source_index, identity in enumerate(source)
        if identity in target_indices
    }
    changed = 0
    result: list[dict[str, object]] = []
    for entry in schedule:
        if entry["purpose"] not in {"PreprocessedCoefficients", "PreprocessedEvaluations"}:
            result.append(entry)
            continue
        source_ordinal = int(entry["ordinal"])
        target_ordinal = source_to_target.get(source_ordinal)
        if target_ordinal is None:
            changed += 1
            continue
        changed += source_ordinal != target_ordinal
        entry["ordinal"] = target_ordinal
        result.append(entry)
    for index, entry in enumerate(result):
        entry["id"] = index
    coefficient_ordinals = sorted(
        int(entry["ordinal"])
        for entry in result
        if entry["purpose"] == "PreprocessedCoefficients"
    )
    if coefficient_ordinals != list(range(len(target))):
        raise ValueError("projected preprocessed coefficients are not contiguous")
    return result, changed


def rebuild_trace_group_geometry(
    schedule: list[dict[str, object]], tree_columns: tuple[int, int, int, int]
) -> tuple[list[dict[str, object]], int]:
    templates: dict[str, dict[str, object]] = {}
    for entry in schedule:
        purpose = str(entry["purpose"])
        if purpose == "CommitColumnLogSizes" or purpose in TRACE_GROUP_PURPOSES:
            templates.setdefault(purpose, entry)
    required = {"CommitColumnLogSizes", *TRACE_GROUP_PURPOSES}
    if set(templates) != required:
        raise ValueError("schedule is missing trace-group templates")

    removed_purposes = required | OBSOLETE_COMMIT_GROUP_PURPOSES | {
        "DecommitTraceCoefficientPointers",
        "DecommitTraceCoefficientSizes",
        "DecommitTraceLdeOutputPointers",
    }
    result = [entry for entry in schedule if entry["purpose"] not in removed_purposes]
    removed = len(schedule) - len(result)
    added = 0
    for tree_index, column_count in enumerate(tree_columns):
        if column_count <= 0:
            raise ValueError(f"tree {tree_index} has no columns")
        remaining = column_count
        group_index = 0
        while remaining:
            width = min(16, remaining)
            remaining -= width
            commit = copy.deepcopy(templates["CommitColumnLogSizes"])
            commit["ordinal"] = (tree_index << 20) | group_index
            commit["len_words"] = width
            result.append(commit)
            for purpose, words_per_column in TRACE_GROUP_PURPOSES.items():
                decommit = copy.deepcopy(templates[purpose])
                decommit["ordinal"] = (tree_index << 16) | group_index
                decommit["len_words"] = width * words_per_column
                result.append(decommit)
            group_index += 1
            added += 3
    for index, entry in enumerate(result):
        entry["id"] = index
    return result, removed + added


def schedule_component_set(proof_component_order: list[str]) -> set[str]:
    result = set(proof_component_order)
    if "memory_id_to_small" in result:
        result.add("memory_id_to_big")
    return result


def validate_projection_manifest(
    path: Path,
    template_proof_path: Path,
    target_proof_path: Path,
    composition_path: Path,
    target_components: list[str],
) -> None:
    manifest = json.loads(path.read_text())
    if manifest.get("format") != COMPOSITION_PROJECTION_FORMAT or manifest.get("version") != 2:
        raise ValueError("unsupported composition projection manifest")

    def sha256(file_path: Path) -> str:
        return hashlib.sha256(file_path.read_bytes()).hexdigest()

    if manifest.get("source", {}).get("proof_sha256") != sha256(template_proof_path):
        raise ValueError("composition projection source proof mismatch")
    target = manifest.get("target", {})
    if target.get("proof_sha256") != sha256(target_proof_path):
        raise ValueError("composition projection target proof mismatch")
    if target.get("bundle_sha256") != sha256(composition_path):
        raise ValueError("composition projection bundle mismatch")
    manifest_components = [component.get("label") for component in manifest.get("components", [])]
    if manifest_components != target_components:
        raise ValueError("composition projection component order mismatch")


def project_component_geometry(
    schedule: list[dict[str, object]],
    source_components: list[str],
    target_components: list[str],
) -> tuple[list[dict[str, object]], int]:
    source_positions = {name: index for index, name in enumerate(source_components)}
    if len(source_positions) != len(source_components):
        raise ValueError("source proof has duplicate components")
    if any(name not in source_positions for name in target_components):
        raise ValueError("target proof has components absent from the template proof")
    if [name for name in source_components if name in set(target_components)] != target_components:
        raise ValueError("target component order is not a projection of the template proof")

    retained_source_ordinals = {
        source_positions[name]: target_index
        for target_index, name in enumerate(target_components)
    }
    retained_schedule_components = schedule_component_set(target_components)
    projected: list[dict[str, object]] = []
    removed = 0
    for entry in schedule:
        component = entry.get("component")
        if component is not None and str(component) not in retained_schedule_components:
            removed += 1
            continue
        if entry["purpose"] in COMPONENT_ORDINAL_PURPOSES:
            source_ordinal = int(entry["ordinal"])
            target_ordinal = retained_source_ordinals.get(source_ordinal)
            if target_ordinal is None:
                removed += 1
                continue
            entry["ordinal"] = target_ordinal
        projected.append(entry)
    for index, entry in enumerate(projected):
        entry["id"] = index
    return projected, removed


def adapted_input_metadata(
    path: Path, pedersen_rows: int | None, poseidon_rows: int | None
) -> dict[str, int]:
    with path.open("rb") as file:
        with mmap.mmap(file.fileno(), 0, access=mmap.ACCESS_READ) as data:
            if data[:8] != ADAPTED_INPUT_MAGIC:
                raise ValueError("invalid adapted input magic")
            version, _flags = struct.unpack_from("<II", data, 8)
            if version != ADAPTED_INPUT_VERSION:
                raise ValueError(f"unsupported adapted input version: {version}")

            offset = 16 + 2 * 3 * 4
            pc_count = struct.unpack_from("<Q", data, offset)[0]
            offset += 8
            _public_mask, _reserved16, _reserved32, opcode_count, _reserved_opcode = struct.unpack_from(
                "<HHIII", data, offset
            )
            offset += 16
            if opcode_count != OPCODE_COUNT:
                raise ValueError(f"unsupported adapted input opcode count: {opcode_count}")
            for _ in range(opcode_count):
                state_count = struct.unpack_from("<Q", data, offset)[0]
                offset += 8 + state_count * 3 * 4

            offset += 2 * 8 + 2 * 4
            address_count, f252_count, small_count = struct.unpack_from("<QQQ", data, offset)
            offset += 3 * 8
            address_offset = offset
            offset += address_count * 4 + f252_count * 8 * 4 + small_count * 2 * 8
            public_count = struct.unpack_from("<Q", data, offset)[0]
            offset += 8 + public_count * 4

            segments: list[tuple[int, int] | None] = []
            for _ in range(BUILTIN_SEGMENT_COUNT):
                present = data[offset]
                begin, stop = struct.unpack_from("<QQ", data, offset + 8)
                offset += 24
                if present > 1:
                    raise ValueError("invalid adapted input segment presence flag")
                segments.append((begin, stop) if present else None)
            if offset != len(data):
                raise ValueError("trailing adapted input data")

            def unique_id_tuples(segment_index: int, rows: int | None, width: int) -> int:
                if rows is None:
                    return 0
                segment = segments[segment_index]
                if segment is None:
                    raise ValueError(f"required builtin segment {segment_index} is absent")
                begin, stop = segment
                required_stop = begin + rows * width
                if required_stop > stop or required_stop > address_count:
                    raise ValueError(
                        f"builtin segment {segment_index} requires address {required_stop}, "
                        f"stop={stop}, address_count={address_count}"
                    )
                record = "<" + "I" * width
                return len(
                    {
                        struct.unpack_from(record, data, address_offset + (begin + row * width) * 4)
                        for row in range(rows)
                    }
                )

            return {
                "pc_count": pc_count,
                "address_count": address_count,
                "f252_count": f252_count,
                "small_count": small_count,
                "pedersen_compact_rows": unique_id_tuples(
                    PEDERSEN_SEGMENT_INDEX, pedersen_rows, 3
                ),
                "poseidon_compact_rows": unique_id_tuples(
                    POSEIDON_SEGMENT_INDEX, poseidon_rows, 6
                ),
            }


def component_groups(schedule: list[dict[str, object]], purpose: str) -> dict[str, list[list[dict[str, object]]]]:
    result: dict[str, list[list[dict[str, object]]]] = {}
    for entry in schedule:
        if entry["purpose"] != purpose or "component" not in entry:
            continue
        component = str(entry["component"])
        groups = result.setdefault(component, [])
        if not groups or int(entry["ordinal"]) == 0:
            groups.append([])
        groups[-1].append(entry)
    return result


def source_target_rows(
    schedule: list[dict[str, object]], target_rows: dict[str, list[int]]
) -> dict[str, list[tuple[int, int]]]:
    base_groups = component_groups(schedule, "BaseTrace")
    result: dict[str, list[tuple[int, int]]] = {}
    for component, groups in base_groups.items():
        sources = [int(group[0]["len_words"]) for group in groups]
        targets = target_rows.get(component)
        if targets is None:
            targets = sources
        if len(targets) != len(sources):
            raise ValueError(
                f"component {component} has {len(sources)} schedule groups but {len(targets)} target row groups"
            )
        result[component] = list(zip(sources, targets, strict=True))
    return result


def scale_component_entries(
    schedule: list[dict[str, object]], row_pairs: dict[str, list[tuple[int, int]]]
) -> int:
    changed = 0
    grouped_purposes = {
        "BaseTrace",
        "BaseCoefficients",
        "InteractionTrace",
        "InteractionCoefficients",
    }
    groups_by_purpose = {
        purpose: component_groups(schedule, purpose) for purpose in grouped_purposes
    }
    grouped_ids = {
        id(entry)
        for groups in groups_by_purpose.values()
        for component_groups_ in groups.values()
        for group in component_groups_
        for entry in group
    }
    for purpose, components in groups_by_purpose.items():
        for component, groups in components.items():
            pairs = row_pairs[component]
            if len(groups) != len(pairs):
                raise ValueError(
                    f"component {component} purpose {purpose} has {len(groups)} groups; expected {len(pairs)}"
                )
            for group, (source_rows, target_rows) in zip(groups, pairs, strict=True):
                for entry in group:
                    if int(entry["len_words"]) != source_rows:
                        raise ValueError(f"nonuniform {purpose} group for {component}")
                    entry["len_words"] = target_rows
                    changed += source_rows != target_rows

    for entry in schedule:
        if id(entry) in grouped_ids or entry["purpose"] not in ROW_LINEAR_PURPOSES:
            continue
        component = entry.get("component")
        if component is None or component not in row_pairs:
            continue
        scaling_component = (
            COMPACT_SOURCE_COMPONENTS.get(str(component), str(component))
            if str(entry["purpose"]).startswith("WitnessInputCompact")
            else str(component)
        )
        pairs = row_pairs[scaling_component]
        if len(pairs) != 1:
            continue
        source_rows, target_rows = pairs[0]
        if source_rows == target_rows:
            continue
        words = int(entry["len_words"])
        scaled = (words * target_rows + source_rows - 1) // source_rows
        entry["len_words"] = scaled
        changed += words != scaled

    for entry in schedule:
        if entry["purpose"] != "RuntimeMultiplicity":
            continue
        component = str(entry.get("component", ""))
        if component != "memory_id_to_big":
            continue
        pairs = row_pairs.get(component)
        if not pairs:
            continue
        ordinal = int(entry["ordinal"])
        pair_index = ordinal - 22 if component == "memory_id_to_big" else 0
        if pair_index < 0 or pair_index >= len(pairs):
            raise ValueError(f"cannot map RuntimeMultiplicity {component}:{ordinal}")
        source_rows, target_rows = pairs[pair_index]
        if int(entry["len_words"]) != source_rows:
            raise ValueError(f"unexpected RuntimeMultiplicity geometry for {component}:{ordinal}")
        entry["len_words"] = target_rows
        changed += source_rows != target_rows
    return changed


def rebuild_compact_workspace_geometry(
    schedule: list[dict[str, object]],
    row_pairs: dict[str, list[tuple[int, int]]],
) -> int:
    changed = 0
    for consumer, geometry in COMPACT_GEOMETRY.items():
        if consumer not in row_pairs:
            continue
        active_edges = [producer for producer in geometry["edges"] if producer in row_pairs]
        if not active_edges:
            raise ValueError(f"compact consumer {consumer} has no active producers")
        if any(len(row_pairs[producer]) != 1 for producer in active_edges):
            raise ValueError(f"compact consumer {consumer} has grouped producer rows")
        total_rows = sum(row_pairs[producer][0][1] for producer in active_edges)
        sort_rows = 1 << (total_rows - 1).bit_length()
        targets = {
            "WitnessInputCompactSourcePointers": len(active_edges) * 2,
            "WitnessInputCompactDescriptors": len(active_edges) * 5,
            "WitnessInputCompactTupleScratch": sort_rows * int(geometry["tuple_words"]),
            "WitnessInputCompactSortKey": sort_rows,
            "WitnessInputCompactSortIndex": sort_rows,
            "WitnessInputCompactRunHeads": sort_rows,
            "WitnessInputCompactRunPositions": sort_rows,
            "WitnessInputCompactUniqueCount": 1,
            "WitnessInputCompactSortTemp": sort_rows * 8 + 4096,
            "WitnessInputCompactScanTemp": sort_rows * 2 + 1024,
        }
        found: set[str] = set()
        for entry in schedule:
            if entry.get("component") != consumer:
                continue
            purpose = str(entry["purpose"])
            target = targets.get(purpose)
            if target is None:
                continue
            found.add(purpose)
            changed += int(entry["len_words"]) != target
            entry["len_words"] = target
        if found != set(targets):
            missing = sorted(set(targets) - found)
            raise ValueError(f"compact consumer {consumer} is missing workspace purposes: {missing}")
    return changed


def update_execution_table_geometry(
    schedule: list[dict[str, object]],
    row_pairs: dict[str, list[tuple[int, int]]],
    metadata: dict[str, int],
) -> int:
    memory_rows = row_pairs.get("memory_id_to_big")
    if memory_rows is None or len(memory_rows) != 2:
        raise ValueError("schedule must contain one big and one small memory-ID group")
    big_rows = memory_rows[0][1]
    small_rows = memory_rows[1][1]
    address_count = metadata["address_count"]
    if address_count <= 0:
        raise ValueError("adapted input has no address-to-ID entries")
    address_capacity = 1 << (address_count - 1).bit_length()
    targets = {
        "ExecutionTableRawAddressToId": address_count,
        "ExecutionTableRawF252Words": metadata["f252_count"] * 8,
        "ExecutionTableRawSmallWords": metadata["small_count"] * 4,
        "ExecutionTableBigLimb": big_rows,
        "ExecutionTableSmallLimb": small_rows,
    }
    changed = 0
    for entry in schedule:
        purpose = str(entry["purpose"])
        target = targets.get(purpose)
        if purpose == "RuntimeMultiplicity" and entry.get("component") == "memory_address_to_id":
            target = address_capacity
        if target is None:
            continue
        old = int(entry["len_words"])
        entry["len_words"] = target
        changed += old != target
    return changed


def fnv64_with_zero_range(data: bytes, start: int, end: int) -> int:
    result = 0xCBF29CE484222325
    for index, byte in enumerate(data):
        result ^= 0 if start <= index < end else byte
        result = (result * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return result


def read_fixed_table_geometry(
    path: Path, expected_identity_count: int
) -> tuple[list[str], list[dict[str, object]]]:
    data = path.read_bytes()
    if (
        data[:8] != FIXED_MAGIC
        or struct.unpack_from("<I", data, 8)[0] != FIXED_PROJECTED_VERSION
        or struct.unpack_from("<Q", data, 12)[0] != FIXED_GRAPH_HASH
    ):
        raise ValueError("unsupported projected fixed-table bundle")
    identity_count, entry_count = struct.unpack_from("<II", data, 20)
    if identity_count != expected_identity_count or entry_count == 0:
        raise ValueError("projected fixed-table cardinality mismatch")
    expected_plan_hash = struct.unpack_from("<Q", data, FIXED_PLAN_HASH_OFFSET)[0]
    actual_plan_hash = fnv64_with_zero_range(
        data, FIXED_PLAN_HASH_OFFSET, FIXED_PLAN_HASH_OFFSET + 8
    )
    if expected_plan_hash != actual_plan_hash:
        raise ValueError("invalid projected fixed-table plan hash")

    offset = 36

    def read_string() -> str:
        nonlocal offset
        if offset + 4 > len(data):
            raise ValueError("truncated fixed-table identity")
        length, reserved = struct.unpack_from("<HH", data, offset)
        offset += 4
        end = offset + length
        if reserved != 0 or length == 0 or end > len(data):
            raise ValueError("invalid fixed-table identity")
        value = data[offset:end].decode()
        offset = end
        return value

    identities = [read_string() for _ in range(identity_count)]
    if len(set(identities)) != len(identities):
        raise ValueError("duplicate fixed-table identity")
    identity_set = set(identities)
    entries: list[dict[str, object]] = []
    for _ in range(entry_count):
        if offset + 32 > len(data):
            raise ValueError("truncated fixed-table entry")
        (
            component_len,
            reserved,
            log_size,
            row_count,
            multiplicity_columns,
            trace_columns,
            source_count,
            lookup_count,
            descriptor_words,
        ) = struct.unpack_from("<HHIIIIIII", data, offset)
        offset += 32
        component_end = offset + component_len
        if (
            reserved != 0
            or component_len == 0
            or component_end > len(data)
            or log_size >= 31
            or row_count != 1 << log_size
            or multiplicity_columns == 0
            or trace_columns == 0
            or trace_columns > multiplicity_columns
            or source_count > identity_count
            or lookup_count == 0
            or descriptor_words != lookup_count * 4
        ):
            raise ValueError("invalid fixed-table entry")
        component = data[offset:component_end].decode()
        offset = component_end
        trace_end = offset + trace_columns * 4
        if trace_end > len(data):
            raise ValueError("truncated fixed-table trace columns")
        trace_multiplicities = list(
            struct.unpack_from(f"<{trace_columns}I", data, offset)
        )
        offset = trace_end
        if any(value >= multiplicity_columns for value in trace_multiplicities):
            raise ValueError("invalid fixed-table trace multiplicity")
        sources = [read_string() for _ in range(source_count)]
        if any(source not in identity_set for source in sources):
            raise ValueError("fixed-table source is absent from projected identities")
        descriptor_end = offset + descriptor_words * 4
        if descriptor_end > len(data):
            raise ValueError("truncated fixed-table descriptors")
        offset = descriptor_end
        entries.append(
            {
                "component": component,
                "row_count": row_count,
                "multiplicity_columns": multiplicity_columns,
                "trace_columns": trace_columns,
                "sources": sources,
                "lookup_count": lookup_count,
                "descriptor_words": descriptor_words,
            }
        )
    if offset != len(data):
        raise ValueError("trailing fixed-table bundle data")
    components = [str(entry["component"]) for entry in entries]
    if len(set(components)) != len(components):
        raise ValueError("duplicate projected fixed-table component")
    return identities, entries


def rebuild_fixed_table_geometry(
    schedule: list[dict[str, object]],
    fixed_path: Path,
    expected_identity_count: int,
) -> tuple[list[dict[str, object]], int, int]:
    identities, fixed_entries = read_fixed_table_geometry(
        fixed_path, expected_identity_count
    )
    evaluations = {
        int(entry["ordinal"]): entry
        for entry in schedule
        if entry["purpose"] == "PreprocessedEvaluations"
    }
    if len(evaluations) != sum(
        entry["purpose"] == "PreprocessedEvaluations" for entry in schedule
    ):
        raise ValueError("duplicate preprocessed evaluation ordinal")
    identity_ordinals = {identity: ordinal for ordinal, identity in enumerate(identities)}

    purposes = (
        "FixedMultiplicity",
        "FixedTableLookupDescriptors",
        "FixedTableSourcePointers",
        "FixedTableMultiplicityPointers",
        "FixedTableLookupOutputPointers",
    )
    templates = {
        purpose: next(
            (entry for entry in schedule if entry["purpose"] == purpose), None
        )
        for purpose in purposes
    }
    if any(template is None for template in templates.values()):
        raise ValueError("schedule is missing fixed-table geometry templates")
    rebuilt: dict[str, list[dict[str, object]]] = {
        purpose: [] for purpose in purposes
    }
    lookup_updates = 0
    for fixed in fixed_entries:
        component = str(fixed["component"])
        rows = int(fixed["row_count"])
        multiplicity_columns = int(fixed["multiplicity_columns"])
        trace_columns = int(fixed["trace_columns"])
        sources = list(fixed["sources"])
        lookup_count = int(fixed["lookup_count"])
        component_lookups = [
            entry
            for entry in schedule
            if entry["purpose"] == "LookupInputs"
            and entry.get("component") == component
        ]
        if len(component_lookups) != 1:
            raise ValueError(f"expected one fixed lookup destination for {component}")
        lookup_words = rows * lookup_count
        lookup_updates += int(component_lookups[0]["len_words"]) != lookup_words
        component_lookups[0]["len_words"] = lookup_words

        traces = [
            entry
            for entry in schedule
            if entry["purpose"] == "BaseTrace" and entry.get("component") == component
        ]
        if len(traces) != trace_columns or sorted(
            int(entry["ordinal"]) for entry in traces
        ) != list(range(trace_columns)):
            raise ValueError(f"fixed trace columns disagree for {component}")
        if any(int(entry["len_words"]) != rows for entry in traces):
            raise ValueError(f"fixed trace rows disagree for {component}")
        for source in sources:
            ordinal = identity_ordinals[source]
            evaluation = evaluations.get(ordinal)
            if evaluation is None or int(evaluation["len_words"]) != rows:
                raise ValueError(f"fixed source evaluation disagrees for {component}")

        target_words = {
            "FixedMultiplicity": rows * multiplicity_columns,
            "FixedTableLookupDescriptors": int(fixed["descriptor_words"]),
            "FixedTableSourcePointers": len(sources) * 2,
            "FixedTableMultiplicityPointers": multiplicity_columns * 2,
            "FixedTableLookupOutputPointers": lookup_count * 2,
        }
        for purpose in purposes:
            if purpose == "FixedTableSourcePointers" and not sources:
                continue
            support = copy.deepcopy(templates[purpose])
            support["component"] = component
            support["ordinal"] = 0
            support["len_words"] = target_words[purpose]
            rebuilt[purpose].append(support)

    result: list[dict[str, object]] = []
    inserted: set[str] = set()
    removed = 0
    for entry in schedule:
        purpose = str(entry["purpose"])
        replacements = rebuilt.get(purpose)
        if replacements is None:
            result.append(entry)
            continue
        removed += 1
        if purpose not in inserted:
            result.extend(replacements)
            inserted.add(purpose)
    if inserted != set(purposes):
        raise ValueError("schedule fixed-table geometry replacement is incomplete")
    for index, entry in enumerate(result):
        entry["id"] = index
    changed = removed + sum(map(len, rebuilt.values())) + lookup_updates
    return result, changed, len(fixed_entries)


def read_relation_components(
    path: Path,
) -> list[tuple[str, list[tuple[int, int, int, int]]]]:
    data = path.read_bytes()
    if data[:8] != RELATION_MAGIC or struct.unpack_from("<I", data, 8)[0] != 1:
        raise ValueError("unsupported relation bundle")
    count = struct.unpack_from("<I", data, 20)[0]
    offset = 24
    result: list[tuple[str, list[tuple[int, int, int, int]]]] = []
    for _ in range(count):
        name_len, trace_count, _lookup_words = struct.unpack_from("<HHI", data, offset)
        offset += 8
        name = data[offset : offset + name_len].decode()
        offset += name_len
        traces: list[tuple[int, int, int, int]] = []
        for _ in range(trace_count):
            part, layout, layout_arg, output_columns = struct.unpack_from(
                "<IIII", data, offset
            )
            offset += 16 + output_columns * 16 * 4
            traces.append((part, layout, layout_arg, output_columns))
        result.append((name, traces))
    if offset != len(data):
        raise ValueError("trailing relation bundle data")
    return result


def relation_source_count(layout: int, layout_arg: int) -> int:
    if layout == 0:
        return 1
    if layout == 1:
        return layout_arg * 2
    if layout in (2, 3):
        return layout_arg + 1
    if layout == 4:
        return layout_arg
    raise ValueError(f"unsupported relation source layout: {layout}")


def rebuild_relation_geometry(
    schedule: list[dict[str, object]],
    relation_path: Path,
    target_components: list[str],
) -> tuple[list[dict[str, object]], int, int]:
    groups = component_groups(schedule, "InteractionTrace")
    purposes = (
        "RelationSourcePointers",
        "RelationOutputPointers",
        "RelationDenominators",
        "RelationClaimedSum",
    )
    templates = {
        purpose: next(
            (entry for entry in schedule if entry["purpose"] == purpose), None
        )
        for purpose in purposes
    }
    if any(template is None for template in templates.values()):
        raise ValueError("schedule is missing relation geometry templates")
    canonical_ordinals = {
        component: ordinal for ordinal, component in enumerate(target_components)
    }
    if len(canonical_ordinals) != len(target_components):
        raise ValueError("target proof has duplicate relation components")

    rebuilt: dict[str, list[dict[str, object]]] = {
        purpose: [] for purpose in purposes
    }
    claimed_ordinals: list[int] = []
    for component, traces in read_relation_components(relation_path):
        component_groups_ = groups.get(component, [])
        if not component_groups_:
            continue
        group_index = 0
        for trace_index, (part, layout, layout_arg, output_columns) in enumerate(traces):
            remaining_fixed = sum(
                1 for later_part, *_ in traces[trace_index + 1 :] if later_part != 1
            )
            instances = len(component_groups_) - group_index - remaining_fixed if part == 1 else 1
            if instances <= 0:
                raise ValueError(f"invalid relation group count for {component}")
            for _ in range(instances):
                if group_index >= len(component_groups_):
                    raise ValueError("relation group count mismatch")
                group = component_groups_[group_index]
                if len(group) != output_columns * 4:
                    raise ValueError(f"relation output mismatch for {component}")
                rows = int(group[0]["len_words"])
                if any(int(entry["len_words"]) != rows for entry in group):
                    raise ValueError(f"nonuniform relation output rows for {component}")
                canonical_label = (
                    "memory_id_to_small"
                    if component == "memory_id_to_big" and part == 2
                    else component
                )
                canonical_ordinal = canonical_ordinals.get(canonical_label)
                if canonical_ordinal is None:
                    raise ValueError(
                        f"relation component {canonical_label} is absent from target proof"
                    )
                claimed_ordinals.append(canonical_ordinal)
                target_words = {
                    "RelationSourcePointers": relation_source_count(
                        layout, layout_arg
                    )
                    * 2,
                    "RelationOutputPointers": output_columns * 4 * 2,
                    "RelationDenominators": rows * output_columns * 4,
                    "RelationClaimedSum": 4,
                }
                for purpose in purposes:
                    relation_entry = copy.deepcopy(templates[purpose])
                    relation_entry["ordinal"] = canonical_ordinal
                    relation_entry["len_words"] = target_words[purpose]
                    rebuilt[purpose].append(relation_entry)
                group_index += 1
        if group_index != len(component_groups_):
            raise ValueError(f"unused relation groups for {component}")
    if sorted(claimed_ordinals) != list(range(len(target_components))):
        raise ValueError("relation bundle does not cover every target proof component once")

    result: list[dict[str, object]] = []
    inserted: set[str] = set()
    removed = 0
    for entry in schedule:
        purpose = str(entry["purpose"])
        replacements = rebuilt.get(purpose)
        if replacements is None:
            result.append(entry)
            continue
        removed += 1
        if purpose not in inserted:
            result.extend(replacements)
            inserted.add(purpose)
    if inserted != set(purposes):
        raise ValueError("schedule relation geometry replacement is incomplete")
    for index, entry in enumerate(result):
        entry["id"] = index
    return result, removed + sum(map(len, rebuilt.values())), len(claimed_ordinals)


def validate_composition_encoding(data: bytes) -> None:
    if (
        data[:8] != COMPOSITION_MAGIC
        or struct.unpack_from("<I", data, 8)[0] not in COMPOSITION_VERSIONS
    ):
        raise ValueError("unsupported composition bundle")
    if struct.unpack_from("<I", data, 8)[0] != 2:
        return
    expected = struct.unpack_from("<Q", data, 32)[0]
    actual = 0xCBF29CE484222325
    for index, byte in enumerate(data):
        actual ^= 0 if 32 <= index < 40 else byte
        actual = (actual * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    if actual != expected:
        raise ValueError("invalid projected composition plan hash")


def composition_logs(path: Path) -> list[int]:
    data = path.read_bytes()
    validate_composition_encoding(data)
    count = struct.unpack_from("<I", data, 28)[0]
    offset = 40
    logs: list[int] = []
    for _ in range(count):
        label_len = struct.unpack_from("<H", data, offset)[0]
        evaluation_log = struct.unpack_from("<I", data, offset + 12)[0]
        span_count, preprocessed_count, denominator_count, ext_count, part_count = struct.unpack_from(
            "<IIIII", data, offset + 24
        )
        offset += 44 + label_len + span_count * 12 + preprocessed_count * 4
        offset += denominator_count * 4 + ext_count * 32
        for _ in range(part_count):
            program_len = struct.unpack_from("<I", data, offset + 4)[0]
            offset += 16 + program_len
        logs.append(evaluation_log)
    if offset != len(data):
        raise ValueError("trailing composition bundle data")
    return logs


def composition_lde_words(path: Path) -> int:
    data = path.read_bytes()
    validate_composition_encoding(data)
    count = struct.unpack_from("<I", data, 28)[0]
    offset = 40
    maximum_words = 0
    for _ in range(count):
        label_len = struct.unpack_from("<H", data, offset)[0]
        evaluation_log = struct.unpack_from("<I", data, offset + 12)[0]
        span_count, preprocessed_count, denominator_count, ext_count, part_count = struct.unpack_from(
            "<IIIII", data, offset + 24
        )
        span_offset = offset + 44 + label_len
        source_count = preprocessed_count
        for span in range(span_count):
            tree, start, end = struct.unpack_from("<III", data, span_offset + span * 12)
            if end < start:
                raise ValueError("invalid composition trace span")
            if tree in (1, 2):
                source_count += end - start
        maximum_words = max(maximum_words, source_count << evaluation_log)
        offset += 44 + label_len + span_count * 12 + preprocessed_count * 4
        offset += denominator_count * 4 + ext_count * 32
        for _ in range(part_count):
            program_len = struct.unpack_from("<I", data, offset + 4)[0]
            offset += 16 + program_len
    if offset != len(data) or maximum_words == 0:
        raise ValueError("invalid composition bundle geometry")
    return maximum_words


def quotient_geometry(path: Path) -> tuple[int, int, list[int]]:
    with path.open("rb") as file:
        with mmap.mmap(file.fileno(), 0, access=mmap.ACCESS_READ) as data:
            if data[:8] != b"STWZQI01" or struct.unpack_from("<I", data, 8)[0] != 1:
                raise ValueError("unsupported quotient-input fixture")
            sample_count, subdomain_log, quotient_log = struct.unpack_from("<III", data, 12)
            if sample_count == 0 or quotient_log <= subdomain_log:
                raise ValueError("invalid quotient-input geometry")
            offset = 56
            partial_logs: list[int] = []
            for _ in range(sample_count):
                if offset + 52 > len(data):
                    raise ValueError("truncated quotient-input fixture")
                partial_log = struct.unpack_from("<I", data, offset)[0]
                if partial_log > subdomain_log:
                    raise ValueError("quotient partial exceeds subdomain")
                partial_logs.append(partial_log)
                offset += 52 + (16 << partial_log)
            if offset != len(data):
                raise ValueError("trailing quotient-input fixture data")
            return subdomain_log, quotient_log, partial_logs


def update_transcript_geometry(
    schedule: list[dict[str, object]], path: Path
) -> int:
    document = json.loads(path.read_text())
    inputs = document.get("inputs")
    if not isinstance(inputs, dict):
        raise ValueError("transcript fixture inputs must be an object")

    lengths: dict[int, int] = {}
    for ordinal_text, words in inputs.items():
        try:
            ordinal = int(ordinal_text)
        except (TypeError, ValueError) as error:
            raise ValueError(f"invalid transcript input ordinal: {ordinal_text!r}") from error
        if ordinal < 0 or ordinal > 0xFFFFFFFF or str(ordinal) != ordinal_text:
            raise ValueError(f"invalid transcript input ordinal: {ordinal_text!r}")
        if not isinstance(words, list) or not all(
            isinstance(word, int) and 0 <= word <= 0xFFFFFFFF for word in words
        ):
            raise ValueError(f"invalid transcript input words for ordinal {ordinal}")
        lengths[ordinal] = len(words)

    found: set[int] = set()
    changed = 0
    for entry in schedule:
        if entry["purpose"] != "TranscriptInput":
            continue
        ordinal = int(entry["ordinal"])
        target = lengths.get(ordinal)
        if target is None:
            continue
        old = int(entry["len_words"])
        entry["len_words"] = target
        changed += old != target
        found.add(ordinal)
    missing = sorted(lengths.keys() - found)
    if missing:
        raise ValueError(f"transcript inputs missing from schedule: {missing}")
    return changed


def update_proof_geometry(schedule: list[dict[str, object]]) -> int:
    transcript_inputs = {
        int(entry["ordinal"]): entry
        for entry in schedule
        if entry["purpose"] == "TranscriptInput"
    }
    if len(transcript_inputs) != sum(
        entry["purpose"] == "TranscriptInput" for entry in schedule
    ):
        raise ValueError("duplicate transcript input ordinal")
    fri_root_ordinals = sorted(
        ordinal
        for ordinal in transcript_inputs
        if ordinal >= FRI_TRANSCRIPT_ORDINAL_BASE
        and (ordinal - FRI_TRANSCRIPT_ORDINAL_BASE) % FRI_TRANSCRIPT_ORDINAL_STRIDE == 0
    )
    expected_fri_roots = [
        FRI_TRANSCRIPT_ORDINAL_BASE + round_index * FRI_TRANSCRIPT_ORDINAL_STRIDE
        for round_index in range(len(fri_root_ordinals))
    ]
    if fri_root_ordinals != expected_fri_roots:
        raise ValueError("proof FRI transcript input ordinals are not contiguous")
    proof_ordinals = (*PROOF_FIXED_TRANSCRIPT_INPUT_ORDINALS, *fri_root_ordinals)
    missing = [
        ordinal
        for ordinal in proof_ordinals
        if ordinal not in transcript_inputs
    ]
    if missing:
        raise ValueError(f"proof transcript inputs missing from schedule: {missing}")

    decommit = [entry for entry in schedule if entry["purpose"] == "DecommitAssembly"]
    proof = [entry for entry in schedule if entry["purpose"] == "ProofBytes"]
    if len(decommit) != 1 or len(proof) != 1:
        raise ValueError("schedule must contain one DecommitAssembly and one ProofBytes")
    target = int(decommit[0]["len_words"]) + sum(
        int(transcript_inputs[ordinal]["len_words"])
        for ordinal in proof_ordinals
    )
    old = int(proof[0]["len_words"])
    proof[0]["len_words"] = target
    return old != target


def update_quotient_geometry(
    schedule: list[dict[str, object]], path: Path
) -> tuple[list[dict[str, object]], int, int]:
    subdomain_log, quotient_log, partial_logs = quotient_geometry(path)
    sample_count = len(partial_logs)
    changed = 0
    partials = sorted(
        [entry for entry in schedule if entry["purpose"] == "QuotientPartialNumerator"],
        key=lambda entry: int(entry["ordinal"]),
    )
    if not partials or len(partials) % 4 != 0:
        raise ValueError("invalid quotient partial templates")
    target_partial_count = sample_count * 4
    changed += abs(len(partials) - target_partial_count)
    while len(partials) < target_partial_count:
        partials.append(copy.deepcopy(partials[-1]))
    partials = partials[:target_partial_count]
    for sample, partial_log in enumerate(partial_logs):
        for coordinate in range(4):
            ordinal = sample * 4 + coordinate
            entry = partials[ordinal]
            words = 1 << partial_log
            changed += int(entry["ordinal"]) != ordinal
            changed += int(entry["len_words"]) != words
            entry["ordinal"] = ordinal
            entry["len_words"] = words

    targets = {
        "QuotientSamplePoints": sample_count * 8,
        "QuotientFirstLinearTerms": sample_count * 4,
        "QuotientPartialCoordinatePointers": sample_count * 8,
        "QuotientPartialLogSizes": sample_count,
        "QuotientSubdomainValues": 4 << subdomain_log,
        "QuotientTile": 4 << quotient_log,
        "QuotientDenominatorScratch": sample_count * 2 << subdomain_log,
        "QuotientInverseTwiddles": 1 << (subdomain_log - 1),
        "QuotientNumeratorGroupOffsets": sample_count + 1,
        "QuotientNumeratorOutputLogSizes": sample_count,
        "QuotientNumeratorOutputPointers": sample_count * 8,
        "QuotientNumeratorLdeTile": 2 << max(partial_logs),
    }
    for purpose, target in targets.items():
        entries = [entry for entry in schedule if entry["purpose"] == purpose]
        if len(entries) != 1:
            raise ValueError(f"expected one {purpose} entry")
        changed += int(entries[0]["len_words"]) != target
        entries[0]["len_words"] = target

    result = [entry for entry in schedule if entry["purpose"] != "QuotientPartialNumerator"]
    result.extend(partials)
    for index, entry in enumerate(result):
        entry["id"] = index
    return result, changed, quotient_log


def update_composition_geometry(schedule: list[dict[str, object]], path: Path) -> int:
    data = path.read_bytes()
    validate_composition_encoding(data)
    logs = composition_logs(path)
    max_log = max(logs)
    constraint_count = struct.unpack_from("<Q", data, 16)[0]
    if constraint_count == 0 or constraint_count > 1 << 32:
        raise ValueError("invalid composition constraint count")
    accumulator_words = sum(4 << log_size for log_size in set(logs))
    output_words = 1 << (max_log - 1)
    values = {
        "CompositionAccumulators": accumulator_words,
        "CompositionCoefficients": output_words,
        "CompositionLdeTile": composition_lde_words(path),
        "CompositionRandomCoefficientPowers": constraint_count * 4,
        "InverseTwiddles": output_words,
    }
    changed = 0
    for entry in schedule:
        target = values.get(str(entry["purpose"]))
        if target is None:
            continue
        old = int(entry["len_words"])
        entry["len_words"] = target
        changed += old != target
    return changed


def fri_geometry(start_log: int) -> tuple[list[int], list[int], list[int]]:
    if start_log <= FRI_FINAL_LOG:
        raise ValueError(f"invalid FRI start log: {start_log}")
    evaluation_logs: list[int] = []
    fold_steps: list[int] = []
    leaf_logs: list[int] = []
    evaluation_log = start_log
    while evaluation_log > FRI_FINAL_LOG:
        if evaluation_log < FRI_PACKED_LOG:
            raise ValueError("FRI evaluation log is too small for a packed leaf")
        evaluation_logs.append(evaluation_log)
        leaf_logs.append(evaluation_log - FRI_PACKED_LOG)
        fold_step = min(FRI_FOLD_STEP, evaluation_log - FRI_FINAL_LOG)
        fold_steps.append(fold_step)
        evaluation_log -= fold_step
    return evaluation_logs, fold_steps, leaf_logs


def update_domain_geometry(
    schedule: list[dict[str, object]], start_log: int
) -> tuple[list[dict[str, object]], int]:
    evaluation_logs, _fold_steps, leaf_logs = fri_geometry(start_log)
    fri_rounds = len(evaluation_logs)
    changed = 0

    retained_evaluations = {
        int(entry["ordinal"]): entry
        for entry in schedule
        if entry["purpose"] == "FriRetainedEvaluation"
    }
    if not set(range(1, fri_rounds)).issubset(retained_evaluations):
        raise ValueError("unexpected FRI retained-evaluation ordinals")
    for round_index in range(1, fri_rounds):
        entry = retained_evaluations[round_index]
        target = 4 << evaluation_logs[round_index]
        changed += int(entry["len_words"]) != target
        entry["len_words"] = target

    singleton_targets = {
        "QuotientTile": 4 << start_log,
    }
    for purpose, target in singleton_targets.items():
        entries = [entry for entry in schedule if entry["purpose"] == purpose]
        if len(entries) != 1:
            raise ValueError(f"expected one {purpose} entry")
        changed += int(entries[0]["len_words"]) != target
        entries[0]["len_words"] = target

    commit_tiles = {
        int(entry["ordinal"]) >> 20: entry
        for entry in schedule
        if entry["purpose"] == "CommitLdeTile"
    }
    if set(commit_tiles) != set(range(4)):
        raise ValueError("unexpected commitment LDE tile ordinals")
    for tree, width in ((1, 16), (2, 16), (3, 8)):
        target = width << start_log
        changed += int(commit_tiles[tree]["len_words"]) != target
        commit_tiles[tree]["len_words"] = target

    decommit_tiles = [entry for entry in schedule if entry["purpose"] == "DecommitTraceLdeTile"]
    if len(decommit_tiles) != 1:
        raise ValueError("expected one decommit trace LDE tile")
    decommit_target = max(int(commit_tiles[0]["len_words"]), 16 << start_log)
    changed += int(decommit_tiles[0]["len_words"]) != decommit_target
    decommit_tiles[0]["len_words"] = decommit_target

    trace_pointers = {
        int(entry["ordinal"]) >> 16: entry
        for entry in schedule
        if entry["purpose"] == "DecommitTraceRetainedPointers"
    }
    if set(trace_pointers) != set(range(4)):
        raise ValueError("unexpected trace retained-pointer ordinals")
    trace_leaf_logs = (26, start_log, start_log, start_log)
    for tree, leaf_log in enumerate(trace_leaf_logs):
        target = (leaf_log + 1) * 2
        changed += int(trace_pointers[tree]["len_words"]) != target
        trace_pointers[tree]["len_words"] = target

    fri_pointers = {
        (int(entry["ordinal"]) >> 16) - 4: entry
        for entry in schedule
        if entry["purpose"] == "DecommitFriRetainedPointers"
    }
    if not set(range(fri_rounds)).issubset(fri_pointers):
        raise ValueError("unexpected FRI retained-pointer ordinals")
    for round_index, leaf_log in enumerate(leaf_logs):
        target = (leaf_log + 1) * 2
        changed += int(fri_pointers[round_index]["len_words"]) != target
        fri_pointers[round_index]["len_words"] = target

    fri_layers = [entry for entry in schedule if entry["purpose"] == "FriMerkleLayer"]
    layers_by_round = {
        round_index: sorted(
            [entry for entry in fri_layers if int(entry["ordinal"]) >> 16 == round_index],
            key=lambda entry: int(entry["ordinal"]) & 0xFFFF,
        )
        for round_index in range(fri_rounds)
    }
    rebuilt_layers: list[dict[str, object]] = []
    for round_index, leaf_log in enumerate(leaf_logs):
        templates = layers_by_round[round_index]
        if not templates:
            raise ValueError(f"missing FRI Merkle templates for round {round_index}")
        target_count = leaf_log + 1
        changed += abs(len(templates) - target_count)
        while len(templates) < target_count:
            templates.append(copy.deepcopy(templates[-1]))
        templates = templates[:target_count]
        for layer_log, entry in enumerate(templates):
            target_ordinal = (round_index << 16) | layer_log
            target_words = 8 << layer_log
            changed += int(entry["ordinal"]) != target_ordinal
            changed += int(entry["len_words"]) != target_words
            entry["ordinal"] = target_ordinal
            entry["len_words"] = target_words
        rebuilt_layers.extend(reversed(templates))

    def retained_round(entry: dict[str, object]) -> int | None:
        purpose = str(entry["purpose"])
        ordinal = int(entry["ordinal"])
        if purpose in {
            "FriRetainedEvaluation",
            "FriRetainedCoordinatePointers",
            "FriFoldingChallenge",
        }:
            return ordinal
        if purpose == "FriMerkleLayer":
            return ordinal >> 16
        if purpose in {"DecommitFriCoordinatePointers", "DecommitFriRetainedPointers"}:
            return (ordinal >> 16) - 4
        if purpose == "TranscriptInput" and ordinal >= FRI_TRANSCRIPT_ORDINAL_BASE:
            delta = ordinal - FRI_TRANSCRIPT_ORDINAL_BASE
            if delta % FRI_TRANSCRIPT_ORDINAL_STRIDE == 0:
                return delta // FRI_TRANSCRIPT_ORDINAL_STRIDE
        if purpose == "TranscriptOutput" and ordinal >= FRI_TRANSCRIPT_ORDINAL_BASE + 1:
            delta = ordinal - FRI_TRANSCRIPT_ORDINAL_BASE - 1
            if delta % FRI_TRANSCRIPT_ORDINAL_STRIDE == 0:
                return delta // FRI_TRANSCRIPT_ORDINAL_STRIDE
        return None

    result = []
    for entry in schedule:
        if entry["purpose"] == "FriMerkleLayer":
            continue
        round_index = retained_round(entry)
        if round_index is not None and round_index >= fri_rounds:
            changed += 1
            continue
        result.append(entry)
    result.extend(rebuilt_layers)
    for index, entry in enumerate(result):
        entry["id"] = index
    return result, changed


def retention_sources(
    schedule: list[dict[str, object]],
    retained_evaluation_bytes: int = 8 * 1024 * 1024 * 1024,
) -> list[list[dict[str, object]]]:
    trees: list[list[dict[str, object]]] = [[], [], []]
    for entry in schedule:
        purpose = str(entry["purpose"])
        if purpose in COEFFICIENT_PURPOSES:
            trees[COEFFICIENT_PURPOSES.index(purpose)].append(entry)
    for entries in trees:
        entries.sort(key=lambda entry: (int(entry["len_words"]), int(entry["id"])))
    candidates: list[tuple[float, int, int, list[dict[str, object]], int]] = []
    for tree, entries in enumerate(trees):
        for group_index in range(0, len(entries), 16):
            group = entries[group_index : group_index + 16]
            words = sum(int(entry["len_words"]) * 2 for entry in group)
            weighted_log = sum(
                int(entry["len_words"]) * 2 * math.log2(int(entry["len_words"]) * 2)
                for entry in group
            )
            candidates.append((-weighted_log / words, words, tree, group, group_index // 16))
    candidates.sort(key=lambda item: (item[0], item[1], item[2], item[4]))
    selected_groups: list[set[int]] = [set(), set(), set()]
    remaining = retained_evaluation_bytes // 4
    for _score, words, tree, _group, group_index in candidates:
        if words <= remaining:
            selected_groups[tree].add(group_index)
            remaining -= words
    selected: list[list[dict[str, object]]] = [[], [], []]
    for tree, entries in enumerate(trees):
        for group_index in sorted(selected_groups[tree]):
            selected[tree].extend(entries[group_index * 16 : (group_index + 1) * 16])
    return selected


def rebuild_retention(
    schedule: list[dict[str, object]], retained_evaluation_bytes: int
) -> tuple[list[dict[str, object]], int, int]:
    selected = retention_sources(schedule, retained_evaluation_bytes)
    destinations = {
        tree: [
            entry
            for entry in schedule
            if entry["purpose"] == "CommitRetainedEvaluation" and (int(entry["ordinal"]) >> 20) == tree
        ]
        for tree in range(1, 4)
    }
    removed_ids: set[int] = set()
    for tree in range(1, 4):
        existing = destinations[tree]
        wanted = selected[tree - 1]
        if len(wanted) > len(existing):
            raise ValueError(f"tree {tree} needs {len(wanted)} retained destinations; template has {len(existing)}")
        for destination, source in zip(existing, wanted, strict=False):
            destination["len_words"] = int(source["len_words"]) * 2
        removed_ids.update(int(entry["id"]) for entry in existing[len(wanted) :])
    result = [entry for entry in schedule if int(entry["id"]) not in removed_ids]

    all_sources = retention_sources(schedule, 1 << 62)
    for tree in range(1, 4):
        geometry_sources = selected[tree - 1] or all_sources[tree - 1]
        max_evaluation = max(int(source["len_words"]) * 2 for source in geometry_sources)
        scale_targets = {
            "MerkleLeafState": max_evaluation * 8,
            "MerkleLayerScratch": max_evaluation * 4,
        }
        layers = [
            entry
            for entry in result
            if entry["purpose"] == "RetainedMerkleLayers" and (int(entry["ordinal"]) >> 20) == tree
        ]
        lifting_log = int(math.log2(max_evaluation))
        target_layer_count = lifting_log - 3
        while len(layers) < target_layer_count:
            root = copy.deepcopy(layers[-1])
            root["ordinal"] = max(int(entry["ordinal"]) for entry in layers) + 1
            insert_at = next(
                index for index, entry in enumerate(result) if entry is layers[-1]
            ) + 1
            layers.append(root)
            result.insert(insert_at, root)
        if len(layers) > target_layer_count:
            removed_layer_ids = {int(entry["id"]) for entry in layers[target_layer_count:]}
            result = [entry for entry in result if int(entry["id"]) not in removed_layer_ids]
            layers = layers[:target_layer_count]
        for entry in result:
            if (int(entry["ordinal"]) >> 20) != tree:
                continue
            target = scale_targets.get(str(entry["purpose"]))
            if target is not None:
                entry["len_words"] = target
        layer_words = max_evaluation // 2
        for layer in layers:
            layer["len_words"] = layer_words
            layer_words //= 2

    evaluation_pointers = {
        int(entry["ordinal"]): entry
        for entry in result
        if entry["purpose"] == "DecommitTraceEvaluationPointers"
    }
    evaluation_logs = {
        int(entry["ordinal"]): entry
        for entry in result
        if entry["purpose"] == "DecommitTraceEvaluationLogs"
    }
    coefficient_ordinals = {
        int(entry["ordinal"])
        for entry in result
        if entry["purpose"] == "DecommitTraceCoefficientPointers"
    }
    added_coefficient_groups = 0
    for ordinal, pointers in evaluation_pointers.items():
        if ordinal in coefficient_ordinals:
            continue
        logs = evaluation_logs[ordinal]
        for source, purpose in (
            (pointers, "DecommitTraceCoefficientPointers"),
            (logs, "DecommitTraceCoefficientSizes"),
            (pointers, "DecommitTraceLdeOutputPointers"),
        ):
            entry = copy.deepcopy(source)
            entry["purpose"] = purpose
            result.append(entry)
        added_coefficient_groups += 1

    for index, entry in enumerate(result):
        entry["id"] = index
    return result, len(removed_ids), added_coefficient_groups


def retarget(
    template_path: Path,
    template_proof_path: Path,
    proof_path: Path,
    input_path: Path,
    preprocessed_coefficients_path: Path,
    composition_path: Path,
    quotient_path: Path,
    relation_path: Path,
    fixed_path: Path,
    transcript_path: Path,
    composition_projection_manifest_path: Path,
    output_path: Path,
    retained_evaluation_bytes: int,
) -> dict[str, object]:
    document = copy.deepcopy(json.loads(template_path.read_text()))
    schedule = document["arena"]["logical_buffer_schedule"]
    source_components = proof_components(template_proof_path)
    target_components = proof_components(proof_path)
    validate_projection_manifest(
        composition_projection_manifest_path,
        template_proof_path,
        proof_path,
        composition_path,
        target_components,
    )
    schedule, removed_component_entries = project_component_geometry(
        schedule, source_components, target_components
    )
    target_tree_columns = proof_tree_columns(proof_path)
    source_preprocessed = preprocessed_identities(preprocessed_coefficients_path)
    target_preprocessed = target_preprocessed_identities(source_preprocessed, proof_path)
    schedule, preprocessed_changes = project_preprocessed_geometry(
        schedule, source_preprocessed, target_preprocessed
    )
    pairs = source_target_rows(schedule, proof_rows(proof_path))
    component_changes = scale_component_entries(schedule, pairs)
    compact_workspace_changes = rebuild_compact_workspace_geometry(schedule, pairs)
    pedersen_source_rows = (
        pairs["pedersen_builtin"][0][1] if "pedersen_builtin" in pairs else None
    )
    poseidon_source_rows = (
        pairs["poseidon_builtin"][0][1] if "poseidon_builtin" in pairs else None
    )
    input_metadata = adapted_input_metadata(
        input_path, pedersen_source_rows, poseidon_source_rows
    )
    execution_changes = update_execution_table_geometry(schedule, pairs, input_metadata)
    schedule, fixed_table_changes, fixed_table_components = rebuild_fixed_table_geometry(
        schedule, fixed_path, target_tree_columns[0]
    )
    schedule, relation_changes, relation_instances = rebuild_relation_geometry(
        schedule, relation_path, target_components
    )
    transcript_changes = update_transcript_geometry(schedule, transcript_path)
    schedule, quotient_changes, quotient_log = update_quotient_geometry(schedule, quotient_path)
    composition_log = max(composition_logs(composition_path))
    if quotient_log != composition_log:
        raise ValueError(
            f"composition max evaluation log {composition_log} does not match quotient log {quotient_log}"
        )
    composition_changes = update_composition_geometry(schedule, composition_path)
    coefficient_counts = tuple(
        sum(entry["purpose"] == purpose for entry in schedule)
        for purpose in (
            "PreprocessedCoefficients",
            "BaseCoefficients",
            "InteractionCoefficients",
            "CompositionCoefficients",
        )
    )
    if coefficient_counts != target_tree_columns:
        raise ValueError(
            f"projected coefficient counts {coefficient_counts} do not match proof {target_tree_columns}"
        )
    schedule, trace_group_changes = rebuild_trace_group_geometry(
        schedule, target_tree_columns
    )
    schedule, removed_retained, added_decommit_coefficient_groups = rebuild_retention(
        schedule, retained_evaluation_bytes
    )
    schedule, domain_changes = update_domain_geometry(schedule, composition_log)
    proof_changes = update_proof_geometry(schedule)
    document["arena"]["logical_buffer_schedule"] = schedule
    compact_rows = {"verify_instruction": input_metadata["pc_count"]}
    if "pedersen_aggregator_window_bits_18" in pairs:
        compact_rows["pedersen_aggregator_window_bits_18"] = input_metadata[
            "pedersen_compact_rows"
        ]
    if "poseidon_aggregator" in pairs:
        compact_rows["poseidon_aggregator"] = input_metadata["poseidon_compact_rows"]
    document["compacted_consumer_rows"] = [
        {
            "component": component,
            "n_real_rows": rows,
            "padded_rows": pairs[component][0][1],
        }
        for component, rows in compact_rows.items()
    ]
    for compact in document["compacted_consumer_rows"]:
        if compact["n_real_rows"] <= 0 or compact["n_real_rows"] > compact["padded_rows"]:
            raise ValueError(
                f"compact rows exceed padding for {compact['component']}: "
                f"real={compact['n_real_rows']} padded={compact['padded_rows']}"
            )
    document["source"] = f"retargeted:{template_path}"
    document["caveat"] = "Retargeted from a captured schedule using the target Rust proof claim."
    output_path.write_text(json.dumps(document, indent=2) + "\n")
    return {
        "output": str(output_path),
        "logical_buffers": len(schedule),
        "component_entries_removed": removed_component_entries,
        "preprocessed_entries_changed": preprocessed_changes,
        "trace_group_entries_changed": trace_group_changes,
        "component_entries_changed": component_changes,
        "compact_workspace_entries_changed": compact_workspace_changes,
        "execution_entries_changed": execution_changes,
        "fixed_table_entries_rebuilt": fixed_table_changes,
        "fixed_table_components": fixed_table_components,
        "relation_entries_rebuilt": relation_changes,
        "relation_instances": relation_instances,
        "transcript_entries_changed": transcript_changes,
        "quotient_entries_changed": quotient_changes,
        "composition_entries_changed": composition_changes,
        "domain_entries_changed": domain_changes,
        "proof_entries_changed": proof_changes,
        "fri_start_log": composition_log,
        "retained_destinations_removed": removed_retained,
        "retained_evaluation_budget_bytes": retained_evaluation_bytes,
        "decommit_coefficient_groups_added": added_decommit_coefficient_groups,
        "compacted_consumer_rows": compact_rows,
        "execution_table_counts": {
            key: input_metadata[key]
            for key in ("address_count", "f252_count", "small_count")
        },
        "target_rows": {
            component: [target for _source, target in values]
            for component, values in pairs.items()
            if any(source != target for source, target in values)
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--template", type=Path, required=True)
    parser.add_argument("--template-proof", type=Path, required=True)
    parser.add_argument("--proof", type=Path, required=True)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--preprocessed-coefficients", type=Path, required=True)
    parser.add_argument("--composition", type=Path, required=True)
    parser.add_argument("--quotient", type=Path, required=True)
    parser.add_argument("--relations", type=Path, required=True)
    parser.add_argument("--fixed-tables", type=Path, required=True)
    parser.add_argument("--transcript", type=Path, required=True)
    parser.add_argument("--composition-projection-manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--retained-evaluation-bytes",
        type=int,
        default=8 * 1024 * 1024 * 1024,
        help="Resident full-evaluation budget; use 0 to recompute every decommit group",
    )
    args = parser.parse_args()
    result = retarget(
        args.template,
        args.template_proof,
        args.proof,
        args.input,
        args.preprocessed_coefficients,
        args.composition,
        args.quotient,
        args.relations,
        args.fixed_tables,
        args.transcript,
        args.composition_projection_manifest,
        args.output,
        args.retained_evaluation_bytes,
    )
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
