"""Pinned Rust/Zig relation parity for the nonempty public-input fixture."""

from __future__ import annotations

import hashlib
import json
import subprocess
import tempfile
from pathlib import Path
from typing import Callable

from . import public_input_fixture
from .public_values import (
    PUBLIC_DATA_FIELDS,
    parse_public_values_diagnostic,
    strict_object,
    validate_public_data_shape,
)


CASE_NAME = public_input_fixture.CASE_NAME
GENERATOR = "scripts/riscv_release_oracle_lib/public_input_fixture.py"
ELF_SHA256 = public_input_fixture.ELF_SHA256
INPUT_SHA256 = public_input_fixture.INPUT_SHA256
INPUT_LEN = len(public_input_fixture.INPUT)
EVIDENCE_MODE = "nonempty_public_input"
COMPONENT_COUNT = 27
RELATION_COUNT = 12
PUBLIC_RELATION_COUNT = 3


def _run(command: list[str], cwd: Path) -> str:
    return subprocess.run(
        command,
        cwd=cwd,
        check=True,
        capture_output=True,
        text=True,
    ).stdout


def _failure(error: Exception) -> tuple[dict[str, object], dict[str, object]]:
    base = {
        "name": CASE_NAME,
        "generator": GENERATOR,
        "elf_sha256": ELF_SHA256,
        "input_sha256": INPUT_SHA256,
        "input_len": INPUT_LEN,
        "proof_admitted": True,
        "evidence_mode": EVIDENCE_MODE,
        "agree": False,
        "evidence_error": str(error),
    }
    return (
        {**base, "observation": "canonical_nonzero_tuple_streams"},
        {**base, "observation": "all_component_prefixes_and_relation_domains"},
    )


def compare_or_failure(
    oracle_exe: Path,
    zig_exe: Path,
    receipt: dict,
    root: Path,
    pinned: str,
    compare_tuple_dumps: Callable,
    compare_sum_dumps: Callable,
    parse_sum_dump: Callable,
    binding_problem: Callable,
) -> tuple[dict[str, object], dict[str, object]]:
    try:
        with tempfile.TemporaryDirectory() as directory:
            elf, input_path, input_bytes = public_input_fixture.materialize(
                Path(directory)
            )
            return _compare(
                oracle_exe,
                zig_exe,
                receipt,
                root,
                pinned,
                elf,
                input_path,
                input_bytes,
                compare_tuple_dumps,
                compare_sum_dumps,
                parse_sum_dump,
                binding_problem,
            )
    except (
        KeyError,
        OSError,
        TypeError,
        ValueError,
        json.JSONDecodeError,
        subprocess.SubprocessError,
    ) as error:
        return _failure(error)


def _compare(
    oracle_exe: Path,
    zig_exe: Path,
    receipt: dict,
    root: Path,
    pinned: str,
    elf: Path,
    input_path: Path,
    input_bytes: bytes,
    compare_tuple_dumps: Callable,
    compare_sum_dumps: Callable,
    parse_sum_dump: Callable,
    binding_problem: Callable,
) -> tuple[dict[str, object], dict[str, object]]:
    witness_digest = receipt.get("witness_layout_digest_sha256")
    if not isinstance(witness_digest, str):
        raise ValueError("nonempty comparison lacks the live witness-layout digest")

    rust_public_raw = _run(
        [str(oracle_exe), "--elf", str(elf), "--input", str(input_path)], root
    )
    rust_payload = json.loads(rust_public_raw, object_pairs_hook=strict_object)
    if not isinstance(rust_payload, dict) or "public_data" not in rust_payload:
        raise ValueError("pinned Rust nonempty output has no public_data")
    rust_public = validate_public_data_shape(
        rust_payload["public_data"], "Rust nonempty public_data"
    )
    zig_public_raw = _run(
        [
            str(zig_exe),
            "--public-values",
            str(elf),
            "--input",
            str(input_path),
        ],
        root,
    )
    zig_public = parse_public_values_diagnostic(
        zig_public_raw,
        candidate=receipt["candidate_commit"],
        witness_layout_sha256=witness_digest,
        elf_sha256=ELF_SHA256,
        input_sha256=INPUT_SHA256,
    )
    input_io = rust_public["io_entries"]
    reconstructed_input = b"".join(
        word.to_bytes(4, "little") for word in input_io["input_words"]
    )[:input_io["input_len"]]
    if input_io["input_len"] != INPUT_LEN:
        raise ValueError("pinned Rust public input length is not nine bytes")
    if reconstructed_input != input_bytes:
        raise ValueError("pinned Rust public input words do not bind fixture bytes")
    public_mismatches = [
        field
        for field in PUBLIC_DATA_FIELDS
        if rust_public[field] != zig_public[field]
    ]
    public_result = {
        "agree": not public_mismatches,
        "fields": list(PUBLIC_DATA_FIELDS),
        "mismatches": public_mismatches,
        "normalized_sha256": hashlib.sha256(
            json.dumps(zig_public, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest(),
    }

    rust_tuples = _run(
        [
            str(oracle_exe),
            "--relation-tuples",
            "--elf",
            str(elf),
            "--input",
            str(input_path),
        ],
        root,
    )
    zig_tuples = _run(
        [
            str(zig_exe),
            "--relation-tuples",
            str(elf),
            "--input",
            str(input_path),
        ],
        root,
    )
    rust_sums = _run(
        [
            str(oracle_exe),
            "--relation-sums",
            "--elf",
            str(elf),
            "--input",
            str(input_path),
        ],
        root,
    )
    zig_sums = _run(
        [
            str(zig_exe),
            "--relation-sums",
            str(elf),
            "--input",
            str(input_path),
        ],
        root,
    )
    tuple_result = compare_tuple_dumps(rust_tuples, zig_tuples)
    sum_result = compare_sum_dumps(rust_sums, zig_sums)
    tuple_binding = tuple_result.pop("binding", None)
    sum_binding = sum_result.pop("binding", None)
    vector = {"elf_sha256": ELF_SHA256}
    for binding, label in ((tuple_binding, "tuple"), (sum_binding, "sum")):
        problem = binding_problem(
            binding,
            receipt=receipt,
            vector=vector,
            pinned=pinned,
            input_sha256=INPUT_SHA256,
        )
        if problem is not None:
            raise ValueError(f"nonempty {label} binding: {problem}")
    if tuple_binding != sum_binding:
        raise ValueError("nonempty tuple and sum diagnostic bindings differ")
    parsed_sums = parse_sum_dump(zig_sums, require_binding=True)
    public_memory_sum = parsed_sums["public"]["memory_access"]
    balanced_sum = parsed_sums["aggregate"]["balanced"]

    base = {
        "name": CASE_NAME,
        "generator": GENERATOR,
        "elf_sha256": ELF_SHA256,
        "input_sha256": INPUT_SHA256,
        "input_len": INPUT_LEN,
        "proof_admitted": True,
        "evidence_mode": EVIDENCE_MODE,
        "public_data": public_result,
    }
    tuple_case = {
        **base,
        "observation": "canonical_nonzero_tuple_streams",
        "component_count": COMPONENT_COUNT,
        "relation_count": RELATION_COUNT,
        "rust_sha256": hashlib.sha256(rust_tuples.encode()).hexdigest(),
        "zig_sha256": hashlib.sha256(zig_tuples.encode()).hexdigest(),
        "zig_binding": tuple_binding,
        **tuple_result,
    }
    tuple_case["agree"] = bool(tuple_result["agree"] and public_result["agree"])
    sum_case = {
        **base,
        "observation": "all_component_prefixes_and_relation_domains",
        "component_count": COMPONENT_COUNT,
        "relation_count": RELATION_COUNT,
        "public_relation_count": PUBLIC_RELATION_COUNT,
        "public_memory_sum_nonzero": any(public_memory_sum),
        "balanced_sum": list(balanced_sum),
        "rust_sha256": hashlib.sha256(rust_sums.encode()).hexdigest(),
        "zig_sha256": hashlib.sha256(zig_sums.encode()).hexdigest(),
        "zig_binding": sum_binding,
        **sum_result,
    }
    sum_case["agree"] = bool(sum_result["agree"] and public_result["agree"])
    return tuple_case, sum_case
