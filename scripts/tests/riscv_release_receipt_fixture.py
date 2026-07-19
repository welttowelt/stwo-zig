"""Shared receipt fixtures for RISC-V release contract tests."""

from scripts.riscv_release_gate_lib.contract import (
    NONEMPTY_RELATION_CASE,
    NONEMPTY_RELATION_ELF_SHA256,
    NONEMPTY_RELATION_GENERATOR,
    NONEMPTY_RELATION_INPUT_SHA256,
    NONEMPTY_RELATION_PUBLIC_FIELDS,
    PINNED_ORACLE,
)


TEST_COMMIT = "a" * 40
TEST_DIGEST = "b" * 64


def nonempty_relation_case(boundary: str) -> dict[str, object]:
    return {
        "name": NONEMPTY_RELATION_CASE,
        "generator": NONEMPTY_RELATION_GENERATOR,
        "elf_sha256": NONEMPTY_RELATION_ELF_SHA256,
        "input_sha256": NONEMPTY_RELATION_INPUT_SHA256,
        "input_len": 9,
        "proof_admitted": True,
        "evidence_mode": "nonempty_public_input",
        "agree": True,
        "first_divergence": None,
        "component_count": 27,
        "relation_count": 12,
        "observation": (
            "canonical_nonzero_tuple_streams"
            if boundary == "relation_tuples"
            else "all_component_prefixes_and_relation_domains"
        ),
        "rust_sha256": TEST_DIGEST,
        "zig_sha256": TEST_DIGEST,
        "public_data": {
            "agree": True,
            "fields": list(NONEMPTY_RELATION_PUBLIC_FIELDS),
            "mismatches": [],
            "normalized_sha256": TEST_DIGEST,
        },
        "zig_binding": {
            "implementation_commit": TEST_COMMIT,
            "implementation_dirty": False,
            "oracle_commit": PINNED_ORACLE,
            "elf_sha256": NONEMPTY_RELATION_ELF_SHA256,
            "input_sha256": NONEMPTY_RELATION_INPUT_SHA256,
            "witness_layout_sha256": TEST_DIGEST,
            "diagnostic_preprocessed_commitment": TEST_DIGEST,
            "diagnostic_main_commitment": TEST_DIGEST,
            "diagnostic_interaction_commitment": TEST_DIGEST,
        },
        **({
            "public_relation_count": 3,
            "public_memory_sum_nonzero": True,
            "balanced_sum": [0, 0, 0, 0],
        } if boundary == "relation_sums" else {}),
    }
