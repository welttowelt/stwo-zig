#!/usr/bin/env python3
"""Project Cairo semantic artifacts from an authenticated composition manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import tempfile
from typing import NamedTuple


PACK_FORMAT = "stwo-zig-cairo-program-semantic-pack"
PACK_VERSION = 1
COMPOSITION_MANIFEST_FORMAT = "stwo-zig-cairo-composition-projection"
WITNESS_MAGIC = b"STWZWIT\0"
FEED_MAGIC = b"STWZFED\0"
RELATION_MAGIC = b"STWZREL\0"
FIXED_MAGIC = b"STWZFIX\0"
PREPROCESSED_MAGIC = b"STWZPPC\0"
FIXED_PROJECTED_VERSION = 2
FIXED_PLAN_HASH_OFFSET = 28
COPY_BUFFER_BYTES = 1 << 20

ARTIFACT_KEYS = (
    "witness_programs",
    "multiplicity_feeds",
    "relation_templates",
    "fixed_tables",
    "preprocessed_coefficients",
)


class RawEntry(NamedTuple):
    label: str
    encoded: bytes
    metadata: object = None


class ParsedBundle(NamedTuple):
    version: int
    prefix: bytes
    entries: list[RawEntry]


class FixedBundle(NamedTuple):
    version: int
    graph_hash: int
    identities: list[RawEntry]
    entries: list[RawEntry]


def u16(data: bytes | bytearray, offset: int) -> int:
    return struct.unpack_from("<H", data, offset)[0]


def u32(data: bytes | bytearray, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def fnv64_with_zero_range(data: bytes | bytearray, start: int, end: int) -> int:
    result = 0xCBF29CE484222325
    for index, byte in enumerate(data):
        result ^= 0 if start <= index < end else byte
        result = (result * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    if result == 0:
        raise ValueError("projected artifact plan hash is zero")
    return result


def parse_composition_authority(path: Path) -> dict[str, object]:
    encoded = path.read_bytes()
    document = json.loads(encoded)
    if (
        document.get("format") != COMPOSITION_MANIFEST_FORMAT
        or document.get("version") != 1
    ):
        raise ValueError("unsupported composition projection manifest")
    source = document.get("source")
    target = document.get("target")
    components = document.get("components")
    if not isinstance(source, dict) or not isinstance(target, dict) or not isinstance(components, list):
        raise ValueError("invalid composition projection manifest")
    active = [component.get("label") for component in components if isinstance(component, dict)]
    if len(active) != len(components) or any(not isinstance(label, str) for label in active):
        raise ValueError("invalid composition component authority")
    if not active or len(active) != len(set(active)) or target.get("components") != len(active):
        raise ValueError("invalid composition component authority")
    plan_hash = target.get("plan_hash")
    if not isinstance(plan_hash, str) or len(plan_hash) != 16 or int(plan_hash, 16) == 0:
        raise ValueError("invalid composition plan hash")
    source_bundle_sha256 = source.get("bundle_sha256")
    target_bundle_sha256 = target.get("bundle_sha256")
    for digest in (source_bundle_sha256, target_bundle_sha256):
        if (
            not isinstance(digest, str)
            or len(digest) != 64
            or any(character not in "0123456789abcdef" for character in digest)
        ):
            raise ValueError("invalid composition bundle SHA-256")
    for section in (source, target):
        variant = section.get("preprocessed_variant")
        columns = section.get("tree_columns")
        if not isinstance(variant, str) or not isinstance(columns, list) or len(columns) != 4:
            raise ValueError("invalid composition proof geometry")
    preprocessed_bindings: list[dict[str, object]] = []
    for component in components:
        bindings = component.get("preprocessed")
        if not isinstance(bindings, list) or any(not isinstance(binding, dict) for binding in bindings):
            raise ValueError("invalid composition preprocessed mapping")
        preprocessed_bindings.extend(bindings)
    return {
        "manifest_sha256": sha256_bytes(encoded),
        "source_bundle_sha256": source_bundle_sha256,
        "bundle_sha256": target_bundle_sha256,
        "plan_hash": plan_hash,
        "active_components": active,
        "source_preprocessed_variant": source["preprocessed_variant"],
        "target_preprocessed_variant": target["preprocessed_variant"],
        "source_tree_columns": source["tree_columns"],
        "target_tree_columns": target["tree_columns"],
        "preprocessed_bindings": preprocessed_bindings,
    }


def parse_witness(data: bytes) -> ParsedBundle:
    if data[:8] != WITNESS_MAGIC or u32(data, 8) != 1:
        raise ValueError("unsupported witness bundle")
    count = u32(data, 12)
    offset = 16
    entries: list[RawEntry] = []
    for _ in range(count):
        start = offset
        if offset + 40 > len(data):
            raise ValueError("truncated witness bundle")
        label_len = u16(data, offset)
        if u16(data, offset + 2) != 0 or label_len == 0:
            raise ValueError("invalid witness entry")
        instruction_count = u32(data, offset + 28)
        offset += 40
        end = offset + label_len + instruction_count * 16
        if end > len(data):
            raise ValueError("truncated witness entry")
        label = data[offset : offset + label_len].decode()
        entries.append(RawEntry(label, data[start:end]))
        offset = end
    if offset != len(data):
        raise ValueError("trailing witness bundle data")
    return ParsedBundle(1, data[:12], entries)


def parse_feeds(data: bytes) -> ParsedBundle:
    if data[:8] != FEED_MAGIC or u32(data, 8) != 1:
        raise ValueError("unsupported feed bundle")
    count = u32(data, 12)
    offset = 16
    entries: list[RawEntry] = []
    for _ in range(count):
        start = offset
        if offset + 24 > len(data):
            raise ValueError("truncated feed bundle")
        label_len = u16(data, offset)
        descriptor_words = u32(data, offset + 12)
        lut_count = u32(data, offset + 16)
        destination_count = u32(data, offset + 20)
        if u16(data, offset + 2) != 0 or label_len == 0:
            raise ValueError("invalid feed entry")
        offset += 24
        producer = data[offset : offset + label_len].decode()
        offset += label_len + descriptor_words * 4
        destinations: list[str] = []
        for _ in range(lut_count):
            words = u32(data, offset)
            offset += 4 + words * 4
            if offset > len(data):
                raise ValueError("truncated feed lookup table")
        for _ in range(destination_count):
            destination_len = u16(data, offset)
            if u16(data, offset + 2) != 0 or destination_len == 0:
                raise ValueError("invalid feed destination")
            offset += 12
            end = offset + destination_len
            if end > len(data):
                raise ValueError("truncated feed destination")
            destinations.append(data[offset:end].decode())
            offset = end
        entries.append(RawEntry(producer, data[start:offset], destinations))
    if offset != len(data):
        raise ValueError("trailing feed bundle data")
    return ParsedBundle(1, data[:12], entries)


def parse_relations(data: bytes) -> ParsedBundle:
    if data[:8] != RELATION_MAGIC or u32(data, 8) != 1:
        raise ValueError("unsupported relation bundle")
    count = u32(data, 20)
    offset = 24
    entries: list[RawEntry] = []
    for _ in range(count):
        start = offset
        if offset + 8 > len(data):
            raise ValueError("truncated relation bundle")
        label_len = u16(data, offset)
        trace_count = u16(data, offset + 2)
        if label_len == 0 or trace_count == 0:
            raise ValueError("invalid relation entry")
        offset += 8
        end = offset + label_len
        if end > len(data):
            raise ValueError("truncated relation entry")
        label = data[offset:end].decode()
        offset = end
        for _ in range(trace_count):
            if offset + 16 > len(data):
                raise ValueError("truncated relation trace")
            output_columns = u32(data, offset + 12)
            offset += 16 + output_columns * 16 * 4
            if offset > len(data):
                raise ValueError("truncated relation descriptors")
        entries.append(RawEntry(label, data[start:offset]))
    if offset != len(data):
        raise ValueError("trailing relation bundle data")
    return ParsedBundle(1, data[:20], entries)


def read_encoded_string(data: bytes, offset: int) -> tuple[RawEntry, int]:
    start = offset
    if offset + 4 > len(data):
        raise ValueError("truncated encoded identity")
    length = u16(data, offset)
    if u16(data, offset + 2) != 0 or length == 0:
        raise ValueError("invalid encoded identity")
    offset += 4
    end = offset + length
    if end > len(data):
        raise ValueError("truncated encoded identity")
    return RawEntry(data[offset:end].decode(), data[start:end]), end


def parse_fixed(data: bytes) -> FixedBundle:
    if data[:8] != FIXED_MAGIC or u32(data, 8) not in (1, FIXED_PROJECTED_VERSION):
        raise ValueError("unsupported fixed-table bundle")
    version = u32(data, 8)
    graph_hash = struct.unpack_from("<Q", data, 12)[0]
    identity_count = u32(data, 20)
    entry_count = u32(data, 24)
    offset = 28
    if version == FIXED_PROJECTED_VERSION:
        if len(data) < 36:
            raise ValueError("truncated projected fixed-table bundle")
        expected_hash = struct.unpack_from("<Q", data, FIXED_PLAN_HASH_OFFSET)[0]
        actual_hash = fnv64_with_zero_range(
            data, FIXED_PLAN_HASH_OFFSET, FIXED_PLAN_HASH_OFFSET + 8
        )
        if expected_hash != actual_hash:
            raise ValueError("invalid projected fixed-table plan hash")
        offset += 8
    identities: list[RawEntry] = []
    for _ in range(identity_count):
        identity, offset = read_encoded_string(data, offset)
        identities.append(identity)
    entries: list[RawEntry] = []
    for _ in range(entry_count):
        start = offset
        if offset + 32 > len(data):
            raise ValueError("truncated fixed-table bundle")
        label_len = u16(data, offset)
        trace_count = u32(data, offset + 16)
        source_count = u32(data, offset + 20)
        descriptor_words = u32(data, offset + 28)
        if u16(data, offset + 2) != 0 or label_len == 0:
            raise ValueError("invalid fixed-table entry")
        offset += 32
        end = offset + label_len
        if end > len(data):
            raise ValueError("truncated fixed-table entry")
        label = data[offset:end].decode()
        offset = end + trace_count * 4
        sources: list[str] = []
        for _ in range(source_count):
            source, offset = read_encoded_string(data, offset)
            sources.append(source.label)
        offset += descriptor_words * 4
        if offset > len(data):
            raise ValueError("truncated fixed-table descriptors")
        entries.append(RawEntry(label, data[start:offset], sources))
    if offset != len(data):
        raise ValueError("trailing fixed-table bundle data")
    return FixedBundle(version, graph_hash, identities, entries)


def projected_identities(
    identities: list[RawEntry], source_variant: str, target_variant: str
) -> list[RawEntry]:
    labels = [entry.label for entry in identities]
    if len(labels) != len(set(labels)):
        raise ValueError("fixed-table bundle contains duplicate preprocessed identities")
    if source_variant == target_variant:
        return identities
    if source_variant != "canonical" or target_variant != "canonical_without_pedersen":
        raise ValueError(
            f"unsupported preprocessed projection {source_variant} -> {target_variant}"
        )
    pedersen = [f"pedersen_points_{index}" for index in range(56)]
    present = [label for label in labels if label.startswith("pedersen_points_")]
    result = [entry for entry in identities if not entry.label.startswith("pedersen_points_")]
    if present != pedersen or len(identities) != 161 or len(result) != 105:
        raise ValueError("canonical preprocessed identity geometry is invalid")
    return result


def encode_filtered_v1(bundle: ParsedBundle, entries: list[RawEntry]) -> bytes:
    return bundle.prefix + struct.pack("<I", len(entries)) + b"".join(
        entry.encoded for entry in entries
    )


def encode_projected_fixed(
    source: FixedBundle, identities: list[RawEntry], entries: list[RawEntry]
) -> tuple[bytes, int]:
    header = bytearray(FIXED_MAGIC)
    header.extend(struct.pack("<IQIIQ", FIXED_PROJECTED_VERSION, source.graph_hash, len(identities), len(entries), 0))
    output = header + b"".join(identity.encoded for identity in identities)
    output.extend(b"".join(entry.encoded for entry in entries))
    plan_hash = fnv64_with_zero_range(
        output, FIXED_PLAN_HASH_OFFSET, FIXED_PLAN_HASH_OFFSET + 8
    )
    struct.pack_into("<Q", output, FIXED_PLAN_HASH_OFFSET, plan_hash)
    return bytes(output), plan_hash


def copy_and_hash(stream, output, byte_count: int, source_hash, output_hash=None) -> None:
    remaining = byte_count
    while remaining:
        chunk = stream.read(min(remaining, COPY_BUFFER_BYTES))
        if not chunk:
            raise ValueError("truncated preprocessed coefficient payload")
        source_hash.update(chunk)
        if output is not None:
            output.write(chunk)
            if output_hash is not None:
                output_hash.update(chunk)
        remaining -= len(chunk)


def project_preprocessed(
    source_path: Path,
    output_path: Path,
    source_identities: list[str],
    target_identities: list[str],
) -> dict[str, object]:
    source_hash = hashlib.sha256()
    output_hash = hashlib.sha256()
    target_set = set(target_identities)
    retained: list[str] = []
    with source_path.open("rb") as source, output_path.open("wb") as output:
        header = source.read(16)
        if len(header) != 16 or header[:8] != PREPROCESSED_MAGIC or u32(header, 8) != 1:
            raise ValueError("unsupported preprocessed coefficient fixture")
        count = u32(header, 12)
        if count != len(source_identities):
            raise ValueError("preprocessed coefficient and fixed identity counts disagree")
        source_hash.update(header)
        output_header = PREPROCESSED_MAGIC + struct.pack("<II", 1, len(target_identities))
        output.write(output_header)
        output_hash.update(output_header)
        for expected_identity in source_identities:
            record_header = source.read(16)
            if len(record_header) != 16:
                raise ValueError("truncated preprocessed coefficient fixture")
            source_hash.update(record_header)
            identity_len, reserved, log_size, value_count = struct.unpack("<HHIQ", record_header)
            if reserved != 0 or value_count != 1 << log_size:
                raise ValueError("invalid preprocessed coefficient geometry")
            identity = source.read(identity_len)
            if len(identity) != identity_len or identity.decode() != expected_identity:
                raise ValueError("preprocessed coefficient identity order disagrees with fixed tables")
            source_hash.update(identity)
            retain = expected_identity in target_set
            if retain:
                output.write(record_header)
                output.write(identity)
                output_hash.update(record_header)
                output_hash.update(identity)
                retained.append(expected_identity)
            copy_and_hash(
                source,
                output if retain else None,
                value_count * 4,
                source_hash,
                output_hash if retain else None,
            )
        if source.read(1):
            raise ValueError("trailing preprocessed coefficient fixture data")
    if retained != target_identities:
        raise ValueError("projected preprocessed coefficient order is invalid")
    return {
        "source_sha256": source_hash.hexdigest(),
        "output_sha256": output_hash.hexdigest(),
        "source_count": len(source_identities),
        "output_count": len(target_identities),
        "source_bytes": source_path.stat().st_size,
        "output_bytes": output_path.stat().st_size,
    }


def temporary_path(target: Path) -> Path:
    target.parent.mkdir(parents=True, exist_ok=True)
    handle = tempfile.NamedTemporaryFile(
        prefix=f".{target.name}.", suffix=".tmp", dir=target.parent, delete=False
    )
    handle.close()
    return Path(handle.name)


def build_program_pack(
    composition_manifest_path: Path,
    sources: dict[str, Path],
    outputs: dict[str, Path],
    output_manifest_path: Path,
) -> dict[str, object]:
    if set(sources) != set(ARTIFACT_KEYS) or set(outputs) != set(ARTIFACT_KEYS):
        raise ValueError("program pack artifact set is incomplete")
    all_outputs = list(outputs.values()) + [output_manifest_path]
    if len({path.resolve() for path in all_outputs}) != len(all_outputs):
        raise ValueError("program pack output paths must be distinct")
    authority = parse_composition_authority(composition_manifest_path)
    active = authority["active_components"]
    active_set = set(active)

    source_bytes = {key: sources[key].read_bytes() for key in ARTIFACT_KEYS[:-1]}
    witness = parse_witness(source_bytes["witness_programs"])
    feeds = parse_feeds(source_bytes["multiplicity_feeds"])
    relations = parse_relations(source_bytes["relation_templates"])
    fixed = parse_fixed(source_bytes["fixed_tables"])

    selected_witness = [entry for entry in witness.entries if entry.label in active_set]
    selected_feeds = [entry for entry in feeds.entries if entry.label in active_set]
    if {entry.label for entry in selected_witness} != {entry.label for entry in selected_feeds}:
        raise ValueError("active witness programs and multiplicity feeds disagree")
    dependencies: set[str] = set()
    for feed in selected_feeds:
        for destination in feed.metadata:
            dependency = destination.split("#", 1)[0]
            if dependency not in active_set:
                raise ValueError(
                    f"active feed {feed.label} has unauthorized dependency {destination}"
                )
            dependencies.add(destination)
    relation_authority = active_set | {dependency.split("#", 1)[0] for dependency in dependencies}
    selected_relations = [
        entry for entry in relations.entries if entry.label in relation_authority
    ]
    selected_fixed = [entry for entry in fixed.entries if entry.label in active_set]

    target_identities = projected_identities(
        fixed.identities,
        authority["source_preprocessed_variant"],
        authority["target_preprocessed_variant"],
    )
    if authority["source_tree_columns"][0] != len(fixed.identities):
        raise ValueError("source fixed identities do not match composition tree-0 geometry")
    if authority["target_tree_columns"][0] != len(target_identities):
        raise ValueError("target fixed identities do not match composition tree-0 geometry")
    target_identity_set = {identity.label for identity in target_identities}
    source_identity_ordinals = {
        identity.label: index for index, identity in enumerate(fixed.identities)
    }
    target_identity_ordinals = {
        identity.label: index for index, identity in enumerate(target_identities)
    }
    for binding in authority["preprocessed_bindings"]:
        identity = binding.get("identity")
        if (
            not isinstance(identity, str)
            or binding.get("source_index") != source_identity_ordinals.get(identity)
            or binding.get("target_index") != target_identity_ordinals.get(identity)
        ):
            raise ValueError("composition preprocessed ordinal mapping is not authoritative")
    for entry in selected_fixed:
        for identity in entry.metadata:
            if identity not in target_identity_set:
                raise ValueError(
                    f"active fixed table {entry.label} requires unavailable identity {identity}"
                )

    encoded_outputs: dict[str, bytes] = {
        "witness_programs": encode_filtered_v1(witness, selected_witness),
        "multiplicity_feeds": encode_filtered_v1(feeds, selected_feeds),
        "relation_templates": encode_filtered_v1(relations, selected_relations),
    }
    encoded_fixed, fixed_plan_hash = encode_projected_fixed(
        fixed, target_identities, selected_fixed
    )
    encoded_outputs["fixed_tables"] = encoded_fixed

    temporary = {key: temporary_path(outputs[key]) for key in ARTIFACT_KEYS}
    manifest_temporary = temporary_path(output_manifest_path)
    try:
        for key, encoded in encoded_outputs.items():
            temporary[key].write_bytes(encoded)
        preprocessed_info = project_preprocessed(
            sources["preprocessed_coefficients"],
            temporary["preprocessed_coefficients"],
            [identity.label for identity in fixed.identities],
            [identity.label for identity in target_identities],
        )
        artifact_entries = {
            key: {
                "source_sha256": sha256_bytes(source_bytes[key]),
                "output_sha256": sha256_bytes(encoded_outputs[key]),
                "source_count": len(
                    {
                        "witness_programs": witness.entries,
                        "multiplicity_feeds": feeds.entries,
                        "relation_templates": relations.entries,
                        "fixed_tables": fixed.entries,
                    }[key]
                ),
                "output_count": len(
                    {
                        "witness_programs": selected_witness,
                        "multiplicity_feeds": selected_feeds,
                        "relation_templates": selected_relations,
                        "fixed_tables": selected_fixed,
                    }[key]
                ),
                "output_bytes": len(encoded_outputs[key]),
            }
            for key in ARTIFACT_KEYS[:-1]
        }
        artifact_entries["witness_programs"]["labels"] = [
            entry.label for entry in selected_witness
        ]
        artifact_entries["multiplicity_feeds"]["labels"] = [
            entry.label for entry in selected_feeds
        ]
        artifact_entries["relation_templates"]["labels"] = [
            entry.label for entry in selected_relations
        ]
        artifact_entries["fixed_tables"].update(
            {
                "output_version": FIXED_PROJECTED_VERSION,
                "plan_hash": f"{fixed_plan_hash:016x}",
                "identity_count": len(target_identities),
                "labels": [entry.label for entry in selected_fixed],
                "identity_ordinals": [
                    {
                        "identity": identity.label,
                        "source": next(
                            index
                            for index, source in enumerate(fixed.identities)
                            if source.label == identity.label
                        ),
                        "target": index,
                    }
                    for index, identity in enumerate(target_identities)
                ],
            }
        )
        artifact_entries["preprocessed_coefficients"] = preprocessed_info
        artifact_entries["preprocessed_coefficients"]["output_version"] = 1
        manifest = {
            "format": PACK_FORMAT,
            "version": PACK_VERSION,
            "composition": authority,
            "dependencies": sorted(dependencies),
            "artifacts": artifact_entries,
        }
        manifest_temporary.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        for key in ARTIFACT_KEYS:
            os.replace(temporary[key], outputs[key])
        os.replace(manifest_temporary, output_manifest_path)
        return manifest
    finally:
        for path in [*temporary.values(), manifest_temporary]:
            path.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--composition-manifest", type=Path, required=True)
    for key in ARTIFACT_KEYS:
        option = key.replace("_", "-")
        parser.add_argument(f"--{option}-source", type=Path, required=True)
        parser.add_argument(f"--{option}-output", type=Path, required=True)
    parser.add_argument("--output-manifest", type=Path, required=True)
    args = parser.parse_args()
    sources = {
        key: getattr(args, f"{key}_source")
        for key in ARTIFACT_KEYS
    }
    outputs = {
        key: getattr(args, f"{key}_output")
        for key in ARTIFACT_KEYS
    }
    manifest = build_program_pack(
        args.composition_manifest, sources, outputs, args.output_manifest
    )
    print(json.dumps(manifest, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
