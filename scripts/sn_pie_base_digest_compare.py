#!/usr/bin/env python3
"""Compare Rust and Zig canonical SN PIE base-coefficient digest logs."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
from pathlib import Path
import re
import sys


BASE_COEFFICIENTS = "BaseCoefficients"
BASE_EVALUATIONS = "BaseTrace"
TEXT_MARKER = re.compile(
    r"\b(?P<marker>base_digest|base_coefficient_digest|base_eval_digest|"
    r"native_add_opcode_coeff_digest|add_opcode_coeff_digest)\b"
)
TEXT_FIELD = re.compile(r"(?P<key>[A-Za-z_][A-Za-z0-9_]*)=(?P<value>[^\s,]+)")


class ComparisonError(ValueError):
    pass


@dataclass(frozen=True)
class ColumnLayout:
    index: int
    logical_id: int
    component: str
    ordinal: int
    words: int
    log_size: int


@dataclass(frozen=True)
class Digest:
    index: int
    log_size: int
    first: int
    last: int
    fnv64: int
    line_number: int
    logical_id: int | None = None
    component: str | None = None
    ordinal: int | None = None


def _integer(value: object, label: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise ComparisonError(f"{label} must be a nonnegative integer")
    return value


def _hex(value: object, label: str) -> int:
    if isinstance(value, int) and not isinstance(value, bool) and value >= 0:
        return value
    if not isinstance(value, str) or not re.fullmatch(r"(?:0x)?[0-9a-fA-F]+", value):
        raise ComparisonError(f"{label} must be a hexadecimal string or nonnegative integer")
    return int(value, 16)


def _json_object(line: str) -> dict[str, object] | None:
    offset = line.find("{")
    if offset < 0:
        return None
    try:
        value, _ = json.JSONDecoder().raw_decode(line[offset:])
    except json.JSONDecodeError:
        return None
    return value if isinstance(value, dict) else None


def _schedule_entries(document: object) -> list[object]:
    if isinstance(document, list):
        return document
    if not isinstance(document, dict):
        raise ComparisonError("schedule root must be an object or array")
    direct = document.get("logical_buffer_schedule")
    if isinstance(direct, list):
        return direct
    arena = document.get("arena")
    if isinstance(arena, dict) and isinstance(arena.get("logical_buffer_schedule"), list):
        return arena["logical_buffer_schedule"]
    raise ComparisonError("schedule has no arena.logical_buffer_schedule array")


def load_schedule(path: Path, purpose: str = BASE_COEFFICIENTS) -> list[ColumnLayout]:
    try:
        document = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ComparisonError(f"cannot read schedule {path}: {error}") from error
    layouts: list[ColumnLayout] = []
    for entry_number, raw in enumerate(_schedule_entries(document), start=1):
        if not isinstance(raw, dict) or raw.get("purpose") != purpose:
            continue
        component = raw.get("component")
        if not isinstance(component, str) or not component:
            raise ComparisonError(f"schedule entry {entry_number} has no component")
        logical_id = _integer(raw.get("id"), f"schedule entry {entry_number} id")
        ordinal = _integer(raw.get("ordinal"), f"schedule entry {entry_number} ordinal")
        words = _integer(raw.get("len_words"), f"schedule entry {entry_number} len_words")
        if words == 0 or words & (words - 1):
            raise ComparisonError(f"schedule entry {entry_number} len_words is not a power of two")
        layouts.append(
            ColumnLayout(
                index=len(layouts),
                logical_id=logical_id,
                component=component,
                ordinal=ordinal,
                words=words,
                log_size=words.bit_length() - 1,
            )
        )
    if not layouts:
        raise ComparisonError(f"schedule contains no {purpose} entries")
    return layouts


def _json_digest(
    raw: dict[str, object],
    line_number: int,
    role: str,
    domain: str,
) -> Digest | None:
    if "index" not in raw:
        return None
    coefficient_domain = domain == "coefficients"
    prefix = "coefficients_" if coefficient_domain else ""
    required = (f"{prefix}first", f"{prefix}last", f"{prefix}fnv64")
    if not all(key in raw for key in required):
        if role == "rust" or coefficient_domain:
            raise ComparisonError(f"{role} line {line_number} has an incomplete digest object")
        return None
    index = _integer(raw["index"], f"{role} line {line_number} index")
    log_value = raw.get(f"{prefix}log_size", raw.get("log_size"))
    if log_value is None:
        words = _integer(raw.get("words"), f"{role} line {line_number} words")
        if words == 0 or words & (words - 1):
            raise ComparisonError(f"{role} line {line_number} words is not a power of two")
        log_size = words.bit_length() - 1
    else:
        log_size = _integer(log_value, f"{role} line {line_number} log_size")
    component = raw.get("component")
    if component is not None and not isinstance(component, str):
        raise ComparisonError(f"{role} line {line_number} component must be a string")
    return Digest(
        index=index,
        log_size=log_size,
        first=_integer(raw[required[0]], f"{role} line {line_number} {required[0]}"),
        last=_integer(raw[required[1]], f"{role} line {line_number} {required[1]}"),
        fnv64=_hex(raw[required[2]], f"{role} line {line_number} {required[2]}"),
        line_number=line_number,
        logical_id=_integer(raw["id"], f"{role} line {line_number} id") if "id" in raw else None,
        component=component,
        ordinal=(
            _integer(raw["ordinal"], f"{role} line {line_number} ordinal")
            if "ordinal" in raw
            else None
        ),
    )


def load_rust_digests(path: Path, requested_domain: str = "auto") -> tuple[dict[int, Digest], str]:
    digests: dict[int, Digest] = {}
    try:
        lines = path.read_text().splitlines()
    except OSError as error:
        raise ComparisonError(f"cannot read Rust digest log {path}: {error}") from error
    objects = [
        (line_number, raw)
        for line_number, line in enumerate(lines, start=1)
        if (raw := _json_object(line)) is not None and "index" in raw
    ]
    if requested_domain == "auto":
        domain = "coefficients" if any(
            all(key in raw for key in ("coefficients_first", "coefficients_last", "coefficients_fnv64"))
            for _, raw in objects
        ) else "evaluations"
    else:
        domain = requested_domain
    for line_number, raw in objects:
        digest = _json_digest(raw, line_number, "rust", domain)
        if digest is None:
            continue
        if digest.index in digests:
            raise ComparisonError(f"duplicate Rust digest index {digest.index} on line {line_number}")
        digests[digest.index] = digest
    if not digests:
        raise ComparisonError(f"Rust digest log contains no digest objects: {path}")
    return digests, domain


def _text_hex(fields: dict[str, str], key: str, line_number: int) -> int:
    value = fields.get(key)
    if value is None or not re.fullmatch(r"(?:0x)?[0-9a-fA-F]+", value):
        raise ComparisonError(f"Zig line {line_number} has invalid {key}")
    return int(value, 16)


def _text_decimal(fields: dict[str, str], key: str, line_number: int) -> int:
    value = fields.get(key)
    if value is None or not value.isdecimal():
        raise ComparisonError(f"Zig line {line_number} has invalid {key}")
    return int(value)


def _text_digest(
    line: str,
    line_number: int,
    layouts_by_identity: dict[tuple[str, int], list[ColumnLayout]],
    layouts_by_logical_id: dict[int, ColumnLayout],
) -> Digest | None:
    marker_match = TEXT_MARKER.search(line)
    if marker_match is None:
        return None
    marker = marker_match.group("marker")
    fields = {match.group("key"): match.group("value") for match in TEXT_FIELD.finditer(line[marker_match.end():])}
    component = fields.get("component")
    if component is None and marker == "native_add_opcode_coeff_digest":
        component = "add_opcode"
    ordinal = _text_decimal(fields, "ordinal", line_number) if "ordinal" in fields else None
    logical_id = None
    for key in ("logical_id", "id"):
        if key in fields:
            logical_id = _text_decimal(fields, key, line_number)
            break
    if "index" in fields:
        index = _text_decimal(fields, "index", line_number)
        layout = None
    elif logical_id is not None:
        layout = layouts_by_logical_id.get(logical_id)
        if layout is None:
            raise ComparisonError(f"Zig line {line_number} has unknown logical_id {logical_id}")
        index = layout.index
    elif component is not None and ordinal is not None:
        candidates = layouts_by_identity.get((component, ordinal), [])
        if not candidates:
            raise ComparisonError(
                f"Zig line {line_number} has unknown component/ordinal {component}/{ordinal}"
            )
        if len(candidates) != 1:
            raise ComparisonError(
                f"Zig line {line_number} has ambiguous component/ordinal {component}/{ordinal}; "
                "an explicit canonical index is required"
            )
        layout = candidates[0]
        index = layout.index
    else:
        raise ComparisonError(f"Zig line {line_number} has neither index nor component/ordinal")
    if "log_size" in fields:
        log_size = _text_decimal(fields, "log_size", line_number)
    elif "words" in fields:
        words = _text_decimal(fields, "words", line_number)
        if words == 0 or words & (words - 1):
            raise ComparisonError(f"Zig line {line_number} words is not a power of two")
        log_size = words.bit_length() - 1
    elif layout is not None:
        log_size = layout.log_size
    else:
        raise ComparisonError(f"Zig line {line_number} has no log_size or words")
    return Digest(
        index=index,
        log_size=log_size,
        first=_text_hex(fields, "first", line_number),
        last=_text_hex(fields, "last", line_number),
        fnv64=_text_hex(fields, "fnv64", line_number),
        line_number=line_number,
        logical_id=logical_id,
        component=component,
        ordinal=ordinal,
    )


def load_zig_digests(
    path: Path,
    layouts: list[ColumnLayout],
    domain: str = "coefficients",
) -> dict[int, Digest]:
    by_identity: dict[tuple[str, int], list[ColumnLayout]] = {}
    by_logical_id: dict[int, ColumnLayout] = {}
    for layout in layouts:
        by_identity.setdefault((layout.component, layout.ordinal), []).append(layout)
        if layout.logical_id in by_logical_id:
            raise ComparisonError(f"duplicate schedule logical id {layout.logical_id}")
        by_logical_id[layout.logical_id] = layout
    digests: dict[int, Digest] = {}
    try:
        lines = path.read_text().splitlines()
    except OSError as error:
        raise ComparisonError(f"cannot read Zig digest log {path}: {error}") from error
    for line_number, line in enumerate(lines, start=1):
        raw = _json_object(line)
        digest = _json_digest(raw, line_number, "zig", domain) if raw is not None else None
        if digest is None:
            digest = _text_digest(line, line_number, by_identity, by_logical_id)
        if digest is None:
            continue
        if digest.index in digests:
            raise ComparisonError(f"duplicate Zig digest index {digest.index} on line {line_number}")
        digests[digest.index] = digest
    if not digests:
        raise ComparisonError(f"Zig digest log contains no digest records: {path}")
    return digests


def _digest_values(digest: Digest) -> dict[str, object]:
    return {
        "log_size": digest.log_size,
        "first": digest.first,
        "last": digest.last,
        "fnv64": f"{digest.fnv64:016x}",
        "line_number": digest.line_number,
    }


def _column_result(
    layout: ColumnLayout,
    rust: Digest | None,
    zig: Digest | None,
) -> dict[str, object]:
    differences: dict[str, object] = {}
    if rust is None:
        differences["rust"] = "missing"
    if zig is None:
        differences["zig"] = "missing"
    if rust is not None and zig is not None:
        if rust.log_size != layout.log_size or zig.log_size != layout.log_size:
            differences["log_size"] = {
                "schedule": layout.log_size,
                "rust": rust.log_size,
                "zig": zig.log_size,
            }
        for field in ("first", "last", "fnv64"):
            rust_value = getattr(rust, field)
            zig_value = getattr(zig, field)
            if rust_value != zig_value:
                differences[field] = {
                    "rust": f"{rust_value:016x}" if field == "fnv64" else rust_value,
                    "zig": f"{zig_value:016x}" if field == "fnv64" else zig_value,
                }
        metadata = (
            ("logical_id", zig.logical_id, layout.logical_id),
            ("component", zig.component, layout.component),
            ("ordinal", zig.ordinal, layout.ordinal),
        )
        for field, actual, expected in metadata:
            if actual is not None and actual != expected:
                differences[field] = {"schedule": expected, "zig": actual}
    return {
        "index": layout.index,
        "logical_id": layout.logical_id,
        "component": layout.component,
        "ordinal": layout.ordinal,
        "status": "match" if not differences else "mismatch",
        "differences": differences,
        "rust": _digest_values(rust) if rust is not None else None,
        "zig": _digest_values(zig) if zig is not None else None,
    }


def _component_runs(
    layouts: list[ColumnLayout],
    columns: list[dict[str, object]],
) -> list[dict[str, object]]:
    runs: list[dict[str, object]] = []
    cumulative_matched = 0
    cumulative_mismatched = 0
    cursor = 0
    component_instances: dict[str, int] = {}
    while cursor < len(layouts):
        end = cursor + 1
        while (
            end < len(layouts)
            and layouts[end].component == layouts[cursor].component
            and layouts[end].ordinal > layouts[end - 1].ordinal
        ):
            end += 1
        selected = columns[cursor:end]
        matched = sum(column["status"] == "match" for column in selected)
        mismatched = len(selected) - matched
        cumulative_matched += matched
        cumulative_mismatched += mismatched
        instance = component_instances.get(layouts[cursor].component, 0)
        component_instances[layouts[cursor].component] = instance + 1
        runs.append({
            "component": layouts[cursor].component,
            "component_instance": instance,
            "start_index": cursor,
            "end_index": end - 1,
            "columns": len(selected),
            "matched": matched,
            "mismatched": mismatched,
            "status": "match" if mismatched == 0 else "mismatch",
            "cumulative_columns": end,
            "cumulative_matched": cumulative_matched,
            "cumulative_mismatched": cumulative_mismatched,
        })
        cursor = end
    return runs


def compare(
    schedule_path: Path,
    rust_path: Path,
    zig_path: Path,
    requested_domain: str = "auto",
) -> dict[str, object]:
    rust, domain = load_rust_digests(rust_path, requested_domain)
    purpose = BASE_COEFFICIENTS if domain == "coefficients" else BASE_EVALUATIONS
    layouts = load_schedule(schedule_path, purpose)
    zig = load_zig_digests(zig_path, layouts, domain)
    columns = [_column_result(layout, rust.get(layout.index), zig.get(layout.index)) for layout in layouts]
    runs = _component_runs(layouts, columns)
    extra_rust = sorted(set(rust) - set(range(len(layouts))))
    extra_zig = sorted(set(zig) - set(range(len(layouts))))
    first = next((column for column in columns if column["status"] != "match"), None)
    if first is None and (extra_rust or extra_zig):
        first = {
            "index": min(extra_rust + extra_zig),
            "component": None,
            "ordinal": None,
            "status": "mismatch",
            "differences": {"outside_schedule": {"rust": extra_rust, "zig": extra_zig}},
        }
    first_mismatch = None
    if first is not None:
        containing_run = next(
            (
                run for run in runs
                if run["start_index"] <= first["index"] <= run["end_index"]
            ),
            None,
        )
        prior_runs = [run for run in runs if run["end_index"] < first["index"]]
        first_mismatch = dict(first)
        first_mismatch["component_boundary"] = containing_run
        first_mismatch["fully_matched_components_before"] = sum(
            run["status"] == "match" for run in prior_runs
        )
    last_matched_boundary = None
    for run in runs:
        if run["status"] != "match":
            break
        last_matched_boundary = run
    matched = sum(column["status"] == "match" for column in columns)
    mismatch_count = len(columns) - matched + len(set(extra_rust) | set(extra_zig))
    return {
        "schema_version": 1,
        "benchmark": "sn_pie_base_digest_compare",
        "status": "match" if mismatch_count == 0 else "mismatch",
        "domain": f"canonical_base_{domain}",
        "schedule_purpose": purpose,
        "inputs": {
            "schedule": str(schedule_path.resolve()),
            "rust": str(rust_path.resolve()),
            "zig": str(zig_path.resolve()),
        },
        "summary": {
            "schedule_columns": len(layouts),
            "rust_columns": len(rust),
            "zig_columns": len(zig),
            "matched_columns": matched,
            "mismatched_columns": mismatch_count,
            "extra_rust_indices": extra_rust,
            "extra_zig_indices": extra_zig,
            "all_columns_match": mismatch_count == 0,
        },
        "first_mismatch": first_mismatch,
        "last_fully_matched_component_boundary": last_matched_boundary,
        "components": runs,
        "columns": columns,
    }


def write_report(path: Path | None, document: dict[str, object]) -> None:
    encoded = json.dumps(document, indent=2) + "\n"
    if path is not None:
        path.write_text(encoded)
    sys.stdout.write(encoded)


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description=__doc__)
    value.add_argument("--schedule", type=Path, required=True)
    value.add_argument("--rust", type=Path, required=True, help="Rust export_base_digests JSONL")
    value.add_argument("--zig", type=Path, required=True, help="Zig stderr or coefficient digest JSONL")
    value.add_argument(
        "--domain",
        choices=("auto", "evaluations", "coefficients"),
        default="auto",
        help="Auto selects coefficients when Rust exports them, otherwise evaluations",
    )
    value.add_argument("--output", type=Path)
    return value


def main() -> int:
    args = parser().parse_args()
    try:
        document = compare(args.schedule, args.rust, args.zig, args.domain)
    except ComparisonError as error:
        document = {
            "schema_version": 1,
            "benchmark": "sn_pie_base_digest_compare",
            "status": "invalid_input",
            "error": str(error),
        }
        write_report(args.output, document)
        return 2
    write_report(args.output, document)
    return 0 if document["status"] == "match" else 1


if __name__ == "__main__":
    raise SystemExit(main())
