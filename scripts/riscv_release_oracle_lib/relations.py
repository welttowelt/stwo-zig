"""Fail-closed CP-11 relation tuple and cumulative-sum comparisons."""

from __future__ import annotations

import hashlib
import re
import subprocess
from pathlib import Path

from .witness import load_trace_vectors


COMPONENTS = (
    "auipc", "base_alu_imm", "base_alu_reg", "branch_eq", "branch_lt",
    "div", "jal", "jalr", "load_store", "lt_imm", "lt_reg", "lui",
    "mul", "mulh", "shifts_imm", "shifts_reg", "program", "memory",
    "merkle", "poseidon2", "clock_update", "bitwise", "range_check_20",
    "range_check_8_11", "range_check_8_8_4", "range_check_8_8",
    "range_check_m31",
)
RELATIONS = (
    "registers_state", "memory_access", "program_access", "merkle",
    "poseidon2", "poseidon2_io", "bitwise", "range_check_20",
    "range_check_8_11", "range_check_8_8_4", "range_check_8_8",
    "range_check_m31",
)
PUBLIC_RELATIONS = ("registers_state", "merkle", "memory_access")
M31_MODULUS = (1 << 31) - 1
HEX_DIGEST = re.compile(r"[0-9a-f]{64}")
EMPTY_TUPLE_DIGEST = hashlib.blake2s(
    b"stwo-zig/riscv/relation-tuples/v1\0"
).hexdigest()


class EvidenceError(ValueError):
    """The producer output is structurally invalid and cannot be compared."""


def _fields(line: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for token in line.split():
        if token.count("=") != 1:
            raise EvidenceError(f"malformed token {token!r}")
        key, value = token.split("=", 1)
        if not key or not value or key in result:
            raise EvidenceError(f"invalid or duplicate field {key!r}")
        result[key] = value
    return result


def _uint(value: str, field: str) -> int:
    if not value.isascii() or not value.isdecimal():
        raise EvidenceError(f"{field} is not an unsigned decimal integer")
    return int(value)


def _digest(value: str, field: str) -> str:
    if not HEX_DIGEST.fullmatch(value):
        raise EvidenceError(f"{field} is not a lowercase SHA-sized digest")
    return value


def _stream(line: str, identity: str, expected: str) -> dict[str, object]:
    fields = _fields(line)
    expected_fields = {
        identity, "entries", "digest", "zero_entries", "zero_digest",
        "nonzero_entries", "nonzero_digest",
    }
    if set(fields) != expected_fields:
        raise EvidenceError(
            f"{identity}={expected} has fields {sorted(fields)}, expected {sorted(expected_fields)}"
        )
    if fields[identity] != expected:
        raise EvidenceError(
            f"expected {identity}={expected}, found {fields[identity]!r}"
        )
    entries = _uint(fields["entries"], "entries")
    zero_entries = _uint(fields["zero_entries"], "zero_entries")
    nonzero_entries = _uint(fields["nonzero_entries"], "nonzero_entries")
    if entries != zero_entries + nonzero_entries:
        raise EvidenceError(f"{identity}={expected} stream counts do not partition")
    result = {
        "entries": entries,
        "digest": _digest(fields["digest"], "digest"),
        "zero_entries": zero_entries,
        "zero_digest": _digest(fields["zero_digest"], "zero_digest"),
        "nonzero_entries": nonzero_entries,
        "nonzero_digest": _digest(fields["nonzero_digest"], "nonzero_digest"),
    }
    for count_field, digest_field in (
        ("entries", "digest"),
        ("zero_entries", "zero_digest"),
        ("nonzero_entries", "nonzero_digest"),
    ):
        if result[count_field] == 0 and result[digest_field] != EMPTY_TUPLE_DIGEST:
            raise EvidenceError(
                f"{identity}={expected} empty {count_field} has a nonempty digest"
            )
    return result


def parse_tuple_dump(output: str) -> dict[str, object]:
    lines = output.splitlines()
    expected_lines = 1 + len(COMPONENTS) * (1 + len(RELATIONS)) + 1 + len(RELATIONS)
    if len(lines) != expected_lines:
        raise EvidenceError(f"tuple dump has {len(lines)} lines, expected {expected_lines}")
    if lines[0] != "schema=riscv-relation-tuples-v2":
        raise EvidenceError("tuple dump schema is not riscv-relation-tuples-v2")

    cursor = 1
    components: dict[str, object] = {}
    for component in COMPONENTS:
        stream = _stream(lines[cursor], "component", component)
        cursor += 1
        domains: dict[str, object] = {}
        for relation in RELATIONS:
            domains[relation] = _stream(
                lines[cursor], "component_relation", f"{component}/{relation}"
            )
            cursor += 1
        if stream["entries"] != sum(item["entries"] for item in domains.values()):
            raise EvidenceError(f"component {component} domain entry counts do not compose")
        if stream["nonzero_entries"] != sum(
            item["nonzero_entries"] for item in domains.values()
        ):
            raise EvidenceError(f"component {component} nonzero domain counts do not compose")
        components[component] = {"stream": stream, "relations": domains}

    aggregate = _stream(lines[cursor], "aggregate", "all_components")
    cursor += 1
    aggregate_relations: dict[str, object] = {}
    for relation in RELATIONS:
        aggregate_relations[relation] = _stream(
            lines[cursor], "aggregate_relation", relation
        )
        cursor += 1
    if cursor != len(lines):
        raise EvidenceError("tuple dump has trailing evidence")
    if aggregate["entries"] != sum(
        item["stream"]["entries"] for item in components.values()
    ):
        raise EvidenceError("aggregate tuple entry count does not compose")
    if aggregate["nonzero_entries"] != sum(
        item["stream"]["nonzero_entries"] for item in components.values()
    ):
        raise EvidenceError("aggregate nonzero tuple count does not compose")
    for relation in RELATIONS:
        expected = sum(
            item["relations"][relation]["entries"] for item in components.values()
        )
        if aggregate_relations[relation]["entries"] != expected:
            raise EvidenceError(f"aggregate {relation} entry count does not compose")
        expected_nonzero = sum(
            item["relations"][relation]["nonzero_entries"]
            for item in components.values()
        )
        if aggregate_relations[relation]["nonzero_entries"] != expected_nonzero:
            raise EvidenceError(f"aggregate {relation} nonzero count does not compose")
    return {
        "components": components,
        "aggregate": aggregate,
        "aggregate_relations": aggregate_relations,
    }


def _qm31(value: str, field: str) -> tuple[int, int, int, int]:
    parts = value.split(",")
    if len(parts) != 4:
        raise EvidenceError(f"{field} is not four M31 limbs")
    limbs = tuple(_uint(part, field) for part in parts)
    if any(limb >= M31_MODULUS for limb in limbs):
        raise EvidenceError(f"{field} contains a noncanonical M31 limb")
    return limbs  # type: ignore[return-value]


def _add_qm31(*values: tuple[int, int, int, int]) -> tuple[int, int, int, int]:
    return tuple(sum(value[index] for value in values) % M31_MODULUS for index in range(4))  # type: ignore[return-value]


def _exact_fields(line: str, expected: dict[str, str | None]) -> dict[str, str]:
    fields = _fields(line)
    if set(fields) != set(expected):
        raise EvidenceError(f"line has fields {sorted(fields)}, expected {sorted(expected)}")
    for key, value in expected.items():
        if value is not None and fields[key] != value:
            raise EvidenceError(f"expected {key}={value}, found {fields[key]!r}")
    return fields


def parse_sum_dump(output: str) -> dict[str, object]:
    lines = output.splitlines()
    expected_lines = 1 + len(RELATIONS) + len(COMPONENTS) + len(RELATIONS) + len(PUBLIC_RELATIONS) + 1
    if len(lines) != expected_lines:
        raise EvidenceError(f"sum dump has {len(lines)} lines, expected {expected_lines}")
    if lines[0] != "schema=riscv-relation-sums-v1":
        raise EvidenceError("sum dump schema is not riscv-relation-sums-v1")

    cursor = 1
    challenges: dict[str, tuple[int, int, int, int]] = {}
    for relation in RELATIONS:
        fields = _exact_fields(
            lines[cursor], {"challenge": relation, "signature": None}
        )
        challenges[relation] = _qm31(fields["signature"], f"challenge {relation}")
        cursor += 1

    components: dict[str, object] = {}
    prefix = (0, 0, 0, 0)
    for component in COMPONENTS:
        fields = _exact_fields(
            lines[cursor], {"component": component, "claim": None, "prefix": None}
        )
        claim = _qm31(fields["claim"], f"component {component} claim")
        observed_prefix = _qm31(fields["prefix"], f"component {component} prefix")
        prefix = _add_qm31(prefix, claim)
        if observed_prefix != prefix:
            raise EvidenceError(f"component {component} cumulative prefix drifted")
        components[component] = {"claim": claim, "prefix": prefix}
        cursor += 1

    relation_sums: dict[str, tuple[int, int, int, int]] = {}
    for relation in RELATIONS:
        fields = _exact_fields(lines[cursor], {"relation": relation, "sum": None})
        relation_sums[relation] = _qm31(fields["sum"], f"relation {relation} sum")
        cursor += 1

    public_sums: dict[str, tuple[int, int, int, int]] = {}
    for relation in PUBLIC_RELATIONS:
        fields = _exact_fields(lines[cursor], {"public": relation, "sum": None})
        public_sums[relation] = _qm31(fields["sum"], f"public {relation} sum")
        cursor += 1

    fields = _exact_fields(
        lines[cursor],
        {"aggregate": "native", "sum": None, "public_sum": None, "balanced_sum": None},
    )
    native = _qm31(fields["sum"], "aggregate native sum")
    public = _qm31(fields["public_sum"], "aggregate public sum")
    balanced = _qm31(fields["balanced_sum"], "aggregate balanced sum")
    if cursor + 1 != len(lines):
        raise EvidenceError("sum dump has trailing evidence")
    if native != prefix:
        raise EvidenceError("aggregate native sum differs from the final component prefix")
    if native != _add_qm31(*relation_sums.values()):
        raise EvidenceError("aggregate native sum differs from the relation-domain total")
    if public != _add_qm31(*public_sums.values()):
        raise EvidenceError("aggregate public sum differs from the public-domain total")
    if balanced != _add_qm31(native, public):
        raise EvidenceError("balanced sum is not native plus public")
    return {
        "challenges": challenges,
        "components": components,
        "relations": relation_sums,
        "public": public_sums,
        "aggregate": {"native": native, "public": public, "balanced": balanced},
    }


def _comparable_tuple(parsed: dict[str, object]) -> dict[str, object]:
    def nonzero(stream: dict[str, object]) -> tuple[object, object]:
        return stream["nonzero_entries"], stream["nonzero_digest"]

    components = parsed["components"]
    return {
        "components": {
            component: {
                "stream": nonzero(components[component]["stream"]),
                "relations": {
                    relation: nonzero(components[component]["relations"][relation])
                    for relation in RELATIONS
                },
            }
            for component in COMPONENTS
        },
        "aggregate": nonzero(parsed["aggregate"]),
        "aggregate_relations": {
            relation: nonzero(parsed["aggregate_relations"][relation])
            for relation in RELATIONS
        },
    }


def _first_difference(rust: object, zig: object, path: str = "") -> dict[str, object] | None:
    if isinstance(rust, dict) and isinstance(zig, dict):
        for key in rust:
            child = _first_difference(rust[key], zig.get(key), f"{path}/{key}")
            if child is not None:
                return child
        return None
    if rust != zig:
        return {"path": path or "/", "rust": rust, "zig": zig}
    return None


def compare_tuple_dumps(rust_output: str, zig_output: str) -> dict[str, object]:
    rust = _comparable_tuple(parse_tuple_dump(rust_output))
    zig = _comparable_tuple(parse_tuple_dump(zig_output))
    difference = _first_difference(rust, zig)
    return {"agree": difference is None, "first_divergence": difference}


def compare_sum_dumps(rust_output: str, zig_output: str) -> dict[str, object]:
    rust = parse_sum_dump(rust_output)
    zig = parse_sum_dump(zig_output)
    difference = _first_difference(rust, zig)
    return {"agree": difference is None, "first_divergence": difference}


def _run(command: list[str], cwd: Path | None = None) -> str:
    return subprocess.run(
        command, cwd=cwd, check=True, capture_output=True, text=True
    ).stdout


def compare_relation_boundaries(
    oracle_exe: Path,
    receipt: dict,
    root: Path,
    pinned: str,
) -> None:
    zig_exe = root / "zig-out" / "bin" / "riscv-trace-dump"
    vectors = load_trace_vectors(root, pinned, receipt)
    tuple_cases = []
    sum_cases = []
    tuples_ok = True
    sums_ok = True
    for vector in vectors["vectors"]:
        elf = root / vector["elf"]
        rust_tuples = _run([str(oracle_exe), "--relation-tuples", "--elf", str(elf)])
        zig_tuples = _run([str(zig_exe), "--relation-tuples", str(elf)], cwd=root)
        rust_sums = _run([str(oracle_exe), "--relation-sums", "--elf", str(elf)])
        zig_sums = _run([str(zig_exe), "--relation-sums", str(elf)], cwd=root)
        try:
            tuple_result = compare_tuple_dumps(rust_tuples, zig_tuples)
        except EvidenceError as error:
            tuple_result = {"agree": False, "evidence_error": str(error)}
        try:
            sum_result = compare_sum_dumps(rust_sums, zig_sums)
        except EvidenceError as error:
            sum_result = {"agree": False, "evidence_error": str(error)}
        tuples_ok = tuples_ok and bool(tuple_result["agree"])
        sums_ok = sums_ok and bool(sum_result["agree"])
        tuple_cases.append({
            "name": vector["name"],
            "elf_sha256": vector["elf_sha256"],
            "rust_sha256": hashlib.sha256(rust_tuples.encode()).hexdigest(),
            "zig_sha256": hashlib.sha256(zig_tuples.encode()).hexdigest(),
            **tuple_result,
        })
        sum_cases.append({
            "name": vector["name"],
            "elf_sha256": vector["elf_sha256"],
            "rust_sha256": hashlib.sha256(rust_sums.encode()).hexdigest(),
            "zig_sha256": hashlib.sha256(zig_sums.encode()).hexdigest(),
            **sum_result,
        })
    receipt["boundaries"]["relation_tuples"] = {
        "status": "pass" if tuples_ok else "fail",
        "comparison": "canonical production nonzero streams by component and relation",
        "padding_policy": "full and zero streams are validated locally but excluded from cross-port equality because Zig may shard a pinned Rust component",
        "corpus": tuple_cases,
    }
    receipt["boundaries"]["relation_sums"] = {
        "status": "pass" if sums_ok else "fail",
        "comparison": "exact fixed challenges, native component claims and prefixes, domain sums, public compensation, and aggregate balance",
        "corpus": sum_cases,
    }
