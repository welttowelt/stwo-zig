#!/usr/bin/env python3
"""Compare cumulative Rust and Metal Cairo composition accumulator digests."""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
import re
from typing import Iterable


METAL_DIGEST = re.compile(
    r"^composition_accumulator_digest "
    r"component_index=(?P<component>\d+) "
    r"log_size=(?P<log_size>\d+) "
    r"coordinate=(?P<coordinate>\d+) "
    r"words=(?P<words>\d+) "
    r"first=(?P<first>\d+) "
    r"last=(?P<last>\d+) "
    r"fnv64=(?P<fnv64>[0-9a-fA-F]{16})$"
)
METAL_FINAL_DIGEST = re.compile(
    r"^composition_lifted_accumulator_digest "
    r"coordinate=(?P<coordinate>\d+) "
    r"log_size=(?P<log_size>\d+) "
    r"words=(?P<words>\d+) "
    r"first=(?P<first>\d+) "
    r"last=(?P<last>\d+) "
    r"fnv64=(?P<fnv64>[0-9a-fA-F]{16})$"
)
METAL_COEFFICIENT_DIGEST = re.compile(
    r"^composition_coefficient_digest "
    r"index=(?P<index>\d+) "
    r"log_size=(?P<log_size>\d+) "
    r"words=(?P<words>\d+) "
    r"first=(?P<first>\d+) "
    r"last=(?P<last>\d+) "
    r"fnv64=(?P<fnv64>[0-9a-fA-F]{16})$"
)

FIELDS = ("words", "first", "last", "fnv64")


def _integer_record(values: dict[str, str]) -> dict[str, int | str]:
    return {
        "component_index": int(values["component"]),
        "log_size": int(values["log_size"]),
        "coordinate": int(values["coordinate"]),
        "words": int(values["words"]),
        "first": int(values["first"]),
        "last": int(values["last"]),
        "fnv64": values["fnv64"].lower(),
    }


def parse_metal(lines: Iterable[str]) -> list[dict[str, int | str]]:
    records = []
    for line in lines:
        match = METAL_DIGEST.fullmatch(line.strip())
        if match:
            records.append(_integer_record(match.groupdict()))
    return records


def parse_rust(lines: Iterable[str]) -> list[dict[str, int | str]]:
    records = []
    for row in csv.DictReader(lines):
        required = {
            "component_index",
            "log_size",
            "coordinate",
            "words",
            "first",
            "last",
            "fnv64",
        }
        if not required.issubset(row):
            raise ValueError("Rust digest CSV is missing required columns")
        records.append(
            {
                "component_index": int(row["component_index"]),
                "log_size": int(row["log_size"]),
                "coordinate": int(row["coordinate"]),
                "words": int(row["words"]),
                "first": int(row["first"]),
                "last": int(row["last"]),
                "fnv64": row["fnv64"].lower(),
            }
        )
    return records


def parse_metal_final(lines: Iterable[str]) -> list[dict[str, int | str]]:
    records = []
    for line in lines:
        match = METAL_FINAL_DIGEST.fullmatch(line.strip())
        if match:
            values = match.groupdict()
            records.append(
                {
                    "coordinate": int(values["coordinate"]),
                    "log_size": int(values["log_size"]),
                    "words": int(values["words"]),
                    "first": int(values["first"]),
                    "last": int(values["last"]),
                    "fnv64": values["fnv64"].lower(),
                }
            )
    return records


def parse_rust_final(lines: Iterable[str]) -> list[dict[str, int | str]]:
    records = []
    required = {"coordinate", "log_size", "words", "first", "last", "fnv64"}
    for row in csv.DictReader(lines):
        if not required.issubset(row):
            raise ValueError("Rust final-accumulator CSV is missing required columns")
        records.append(
            {
                "coordinate": int(row["coordinate"]),
                "log_size": int(row["log_size"]),
                "words": int(row["words"]),
                "first": int(row["first"]),
                "last": int(row["last"]),
                "fnv64": row["fnv64"].lower(),
            }
        )
    return records


def parse_metal_coefficients(lines: Iterable[str]) -> list[dict[str, int | str]]:
    records = []
    for line in lines:
        match = METAL_COEFFICIENT_DIGEST.fullmatch(line.strip())
        if match:
            values = match.groupdict()
            records.append(
                {
                    "index": int(values["index"]),
                    "log_size": int(values["log_size"]),
                    "words": int(values["words"]),
                    "first": int(values["first"]),
                    "last": int(values["last"]),
                    "fnv64": values["fnv64"].lower(),
                }
            )
    return records


def parse_rust_coefficients(lines: Iterable[str]) -> list[dict[str, int | str]]:
    records = []
    required = {
        "index",
        "log_size",
        "words",
        "canonical_first",
        "canonical_last",
        "canonical_fnv64",
    }
    for row in csv.DictReader(lines):
        if not required.issubset(row):
            raise ValueError("Rust coefficient CSV is missing required canonical columns")
        records.append(
            {
                "index": int(row["index"]),
                "log_size": int(row["log_size"]),
                "words": int(row["words"]),
                "first": int(row["canonical_first"]),
                "last": int(row["canonical_last"]),
                "fnv64": row["canonical_fnv64"].lower(),
            }
        )
    return records


def _key(record: dict[str, int | str]) -> tuple[int, int, int]:
    return (
        int(record["component_index"]),
        int(record["log_size"]),
        int(record["coordinate"]),
    )


def _unique_index(
    records: Iterable[dict[str, int | str]], source: str
) -> dict[tuple[int, int, int], dict[str, int | str]]:
    result = {}
    for record in records:
        key = _key(record)
        if key in result:
            raise ValueError(f"duplicate {source} digest key {key}")
        result[key] = record
    return result


def compare(
    rust_records: list[dict[str, int | str]],
    metal_records: list[dict[str, int | str]],
) -> dict[str, object]:
    rust = _unique_index(rust_records, "Rust")
    metal = _unique_index(metal_records, "Metal")
    if not metal:
        raise ValueError("Metal log contains no composition accumulator digests")

    components: dict[int, list[tuple[int, int, int]]] = {}
    for key in metal:
        components.setdefault(key[0], []).append(key)

    checked = 0
    first_mismatch = None
    for component in sorted(components):
        keys = sorted(components[component])
        coordinates = [key[2] for key in keys]
        if coordinates != [0, 1, 2, 3] or len({key[1] for key in keys}) != 1:
            raise ValueError(
                f"Metal component {component} does not contain one four-coordinate checkpoint"
            )
        for key in keys:
            actual = metal[key]
            expected = rust.get(key)
            if expected is None:
                first_mismatch = {
                    "component_index": key[0],
                    "log_size": key[1],
                    "coordinate": key[2],
                    "reason": "missing_rust_checkpoint",
                    "metal": actual,
                }
                break
            differences = {
                field: {"rust": expected[field], "metal": actual[field]}
                for field in FIELDS
                if expected[field] != actual[field]
            }
            checked += 1
            if differences:
                first_mismatch = {
                    "component_index": key[0],
                    "log_size": key[1],
                    "coordinate": key[2],
                    "reason": "digest_mismatch",
                    "differences": differences,
                }
                break
        if first_mismatch is not None:
            break

    return {
        "status": "match" if first_mismatch is None else "mismatch",
        "metal_components": len(components),
        "checked_coordinates": checked,
        "first_mismatch": first_mismatch,
    }


def _compare_indexed(
    expected_records: list[dict[str, int | str]],
    actual_records: list[dict[str, int | str]],
    key_name: str,
    expected_count: int,
) -> dict[str, object]:
    expected = {int(record[key_name]): record for record in expected_records}
    actual = {int(record[key_name]): record for record in actual_records}
    if len(expected) != len(expected_records):
        raise ValueError(f"duplicate Rust {key_name}")
    if len(actual) != len(actual_records):
        raise ValueError(f"duplicate Metal {key_name}")
    required_keys = set(range(expected_count))
    if set(expected) != required_keys:
        raise ValueError(f"Rust records do not contain {expected_count} canonical {key_name} values")
    if set(actual) != required_keys:
        raise ValueError(f"Metal records do not contain {expected_count} {key_name} values")

    checked = 0
    first_mismatch = None
    for key in range(expected_count):
        differences = {
            field: {"rust": expected[key][field], "metal": actual[key][field]}
            for field in ("log_size", *FIELDS)
            if expected[key][field] != actual[key][field]
        }
        checked += 1
        if differences:
            first_mismatch = {
                key_name: key,
                "reason": "digest_mismatch",
                "differences": differences,
            }
            break
    return {
        "status": "match" if first_mismatch is None else "mismatch",
        "checked_records": checked,
        "first_mismatch": first_mismatch,
    }


def compare_final(
    rust_records: list[dict[str, int | str]],
    metal_records: list[dict[str, int | str]],
) -> dict[str, object]:
    return _compare_indexed(rust_records, metal_records, "coordinate", 4)


def compare_coefficients(
    rust_records: list[dict[str, int | str]],
    metal_records: list[dict[str, int | str]],
) -> dict[str, object]:
    return _compare_indexed(rust_records, metal_records, "index", 8)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rust", type=Path, required=True, help="Rust oracle CSV")
    parser.add_argument("--metal", type=Path, required=True, help="Metal stderr log")
    parser.add_argument(
        "--phase",
        choices=("accumulator", "final", "coefficient"),
        default="accumulator",
        help="Composition checkpoint represented by the Rust CSV",
    )
    parser.add_argument("--output", type=Path, help="Optional JSON report path")
    args = parser.parse_args()

    rust_lines = args.rust.read_text().splitlines()
    metal_lines = args.metal.read_text().splitlines()
    report = {
        "accumulator": lambda: compare(parse_rust(rust_lines), parse_metal(metal_lines)),
        "final": lambda: compare_final(parse_rust_final(rust_lines), parse_metal_final(metal_lines)),
        "coefficient": lambda: compare_coefficients(
            parse_rust_coefficients(rust_lines), parse_metal_coefficients(metal_lines)
        ),
    }[args.phase]()
    encoded = json.dumps(report, indent=2) + "\n"
    if args.output:
        args.output.write_text(encoded)
    print(encoded, end="")
    return 0 if report["status"] == "match" else 1


if __name__ == "__main__":
    raise SystemExit(main())
