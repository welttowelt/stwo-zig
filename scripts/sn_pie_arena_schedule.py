#!/usr/bin/env python3
"""Retarget a captured SN PIE arena schedule to another Rust proof claim."""

from __future__ import annotations

import argparse
import copy
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
COEFFICIENT_PURPOSES = (
    "BaseCoefficients",
    "InteractionCoefficients",
    "CompositionCoefficients",
)
RELATION_MAGIC = b"STWZREL\0"
COMPOSITION_MAGIC = b"STWZEVA\0"
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


def adapted_input_metadata(
    path: Path, pedersen_rows: int, poseidon_rows: int
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

            def unique_id_tuples(segment_index: int, rows: int, width: int) -> int:
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


def read_relation_components(path: Path) -> list[tuple[str, list[tuple[int, int]]]]:
    data = path.read_bytes()
    if data[:8] != RELATION_MAGIC or struct.unpack_from("<I", data, 8)[0] != 1:
        raise ValueError("unsupported relation bundle")
    count = struct.unpack_from("<I", data, 20)[0]
    offset = 24
    result: list[tuple[str, list[tuple[int, int]]]] = []
    for _ in range(count):
        name_len, trace_count, _lookup_words = struct.unpack_from("<HHI", data, offset)
        offset += 8
        name = data[offset : offset + name_len].decode()
        offset += name_len
        traces: list[tuple[int, int]] = []
        for _ in range(trace_count):
            part, _layout, _layout_arg, output_columns = struct.unpack_from("<IIII", data, offset)
            offset += 16 + output_columns * 16 * 4
            traces.append((part, output_columns))
        result.append((name, traces))
    if offset != len(data):
        raise ValueError("trailing relation bundle data")
    return result


def retarget_relation_denominators(
    schedule: list[dict[str, object]], relation_path: Path
) -> int:
    groups = component_groups(schedule, "InteractionTrace")
    denominators = [entry for entry in schedule if entry["purpose"] == "RelationDenominators"]
    index = 0
    changed = 0
    for component, traces in read_relation_components(relation_path):
        component_groups_ = groups.get(component, [])
        if not component_groups_:
            continue
        group_index = 0
        for trace_index, (part, output_columns) in enumerate(traces):
            remaining_fixed = sum(1 for later_part, _ in traces[trace_index + 1 :] if later_part != 1)
            instances = len(component_groups_) - group_index - remaining_fixed if part == 1 else 1
            if instances <= 0:
                raise ValueError(f"invalid relation group count for {component}")
            for _ in range(instances):
                if index >= len(denominators) or group_index >= len(component_groups_):
                    raise ValueError("relation denominator count mismatch")
                group = component_groups_[group_index]
                if len(group) != output_columns * 4:
                    raise ValueError(f"relation output mismatch for {component}")
                rows = int(group[0]["len_words"])
                expected = rows * output_columns * 4
                old = int(denominators[index]["len_words"])
                denominators[index]["len_words"] = expected
                changed += old != expected
                index += 1
                group_index += 1
        if group_index != len(component_groups_):
            raise ValueError(f"unused relation groups for {component}")
    if index != len(denominators):
        raise ValueError(f"updated {index} of {len(denominators)} relation denominators")
    return changed


def composition_logs(path: Path) -> list[int]:
    data = path.read_bytes()
    if data[:8] != COMPOSITION_MAGIC or struct.unpack_from("<I", data, 8)[0] != 1:
        raise ValueError("unsupported composition bundle")
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
    if data[:8] != COMPOSITION_MAGIC or struct.unpack_from("<I", data, 8)[0] != 1:
        raise ValueError("unsupported composition bundle")
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
    logs = composition_logs(path)
    max_log = max(logs)
    accumulator_words = sum(4 << log_size for log_size in set(logs))
    output_words = 1 << (max_log - 1)
    values = {
        "CompositionAccumulators": accumulator_words,
        "CompositionCoefficients": output_words,
        "CompositionLdeTile": composition_lde_words(path),
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
    proof_path: Path,
    input_path: Path,
    composition_path: Path,
    quotient_path: Path,
    relation_path: Path,
    transcript_path: Path,
    output_path: Path,
    retained_evaluation_bytes: int,
) -> dict[str, object]:
    document = copy.deepcopy(json.loads(template_path.read_text()))
    schedule = document["arena"]["logical_buffer_schedule"]
    pairs = source_target_rows(schedule, proof_rows(proof_path))
    component_changes = scale_component_entries(schedule, pairs)
    pedersen_source_rows = pairs["pedersen_builtin"][0][1]
    poseidon_source_rows = pairs["poseidon_builtin"][0][1]
    input_metadata = adapted_input_metadata(
        input_path, pedersen_source_rows, poseidon_source_rows
    )
    execution_changes = update_execution_table_geometry(schedule, pairs, input_metadata)
    relation_changes = retarget_relation_denominators(schedule, relation_path)
    transcript_changes = update_transcript_geometry(schedule, transcript_path)
    schedule, quotient_changes, quotient_log = update_quotient_geometry(schedule, quotient_path)
    composition_log = max(composition_logs(composition_path))
    if quotient_log != composition_log:
        raise ValueError(
            f"composition max evaluation log {composition_log} does not match quotient log {quotient_log}"
        )
    composition_changes = update_composition_geometry(schedule, composition_path)
    schedule, removed_retained, added_decommit_coefficient_groups = rebuild_retention(
        schedule, retained_evaluation_bytes
    )
    schedule, domain_changes = update_domain_geometry(schedule, composition_log)
    proof_changes = update_proof_geometry(schedule)
    document["arena"]["logical_buffer_schedule"] = schedule
    compact_rows = {
        "pedersen_aggregator_window_bits_18": input_metadata["pedersen_compact_rows"],
        "poseidon_aggregator": input_metadata["poseidon_compact_rows"],
        "verify_instruction": input_metadata["pc_count"],
    }
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
        "component_entries_changed": component_changes,
        "execution_entries_changed": execution_changes,
        "relation_denominators_changed": relation_changes,
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
    parser.add_argument("--proof", type=Path, required=True)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--composition", type=Path, required=True)
    parser.add_argument("--quotient", type=Path, required=True)
    parser.add_argument("--relations", type=Path, required=True)
    parser.add_argument("--transcript", type=Path, required=True)
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
        args.proof,
        args.input,
        args.composition,
        args.quotient,
        args.relations,
        args.transcript,
        args.output,
        args.retained_evaluation_bytes,
    )
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
