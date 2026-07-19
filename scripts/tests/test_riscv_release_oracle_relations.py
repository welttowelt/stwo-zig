"""Fail-closed tests for CP-11 relation evidence parsing and comparison."""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from riscv_release_oracle_lib import relations  # noqa: E402


EMPTY = relations.EMPTY_TUPLE_DIGEST
FULL = "1" * 64
ZERO = "2" * 64
NONZERO = "3" * 64
P = relations.M31_MODULUS


def binding_line() -> str:
    return (
        "binding=zig_diagnostic challenge_mode=pinned_default_blake2s_v1 "
        f"implementation_commit={'a' * 40} implementation_dirty=false "
        f"oracle_commit={'b' * 40} elf_sha256={'4' * 64} "
        f"input_sha256={relations.EMPTY_INPUT_DIGEST} "
        f"witness_layout_sha256={'5' * 64} "
        f"diagnostic_preprocessed_commitment={'6' * 64} "
        f"diagnostic_main_commitment={'7' * 64} "
        f"diagnostic_interaction_commitment={'8' * 64}"
    )


def stream_line(
    identity: str,
    name: str,
    zero_count: int,
    active: bool,
    active_digest: str = NONZERO,
) -> str:
    nonzero_count = int(active)
    entries = zero_count + nonzero_count
    return (
        f"{identity}={name} entries={entries} digest={FULL if entries else EMPTY} "
        f"zero_entries={zero_count} zero_digest={ZERO if zero_count else EMPTY} "
        f"nonzero_entries={nonzero_count} "
        f"nonzero_digest={active_digest if nonzero_count else EMPTY}"
    )


def tuple_dump(
    padding: int = 1,
    active_digest: str = NONZERO,
    *,
    bound: bool = True,
) -> str:
    lines = [
        "schema=riscv-relation-tuples-v3"
        if bound else "schema=riscv-relation-tuples-v2"
    ]
    if bound:
        lines.append(binding_line())
    aggregate_zero = 0
    for component_index, component in enumerate(relations.COMPONENTS):
        active = component_index == 0
        zero_count = padding
        aggregate_zero += zero_count
        lines.append(stream_line(
            "component", component, zero_count, active, active_digest
        ))
        for relation_index, relation in enumerate(relations.RELATIONS):
            lines.append(stream_line(
                "component_relation",
                f"{component}/{relation}",
                zero_count if relation_index == 0 else 0,
                active and relation_index == 0,
                active_digest,
            ))
    lines.append(stream_line(
        "aggregate", "all_components", aggregate_zero, True, active_digest
    ))
    for relation_index, relation in enumerate(relations.RELATIONS):
        lines.append(stream_line(
            "aggregate_relation",
            relation,
            aggregate_zero if relation_index == 0 else 0,
            relation_index == 0,
            active_digest,
        ))
    return "\n".join(lines) + "\n"


def qm31(value: tuple[int, int, int, int]) -> str:
    return ",".join(str(limb) for limb in value)


def add(lhs: tuple[int, int, int, int], rhs: tuple[int, int, int, int]):
    return tuple((a + b) % P for a, b in zip(lhs, rhs))


def sum_dump(
    claim_delta: int = 0,
    corrupt_prefix: bool = False,
    unbalanced: bool = False,
    *,
    bound: bool = True,
) -> str:
    lines = [
        "schema=riscv-relation-sums-v2"
        if bound else "schema=riscv-relation-sums-v1"
    ]
    if bound:
        lines.append(binding_line())
    for index, relation in enumerate(relations.RELATIONS):
        lines.append(f"challenge={relation} signature={qm31((index + 1, 0, 0, 0))}")
    prefix = (0, 0, 0, 0)
    claims = []
    for index, component in enumerate(relations.COMPONENTS):
        claim = (1 + (claim_delta if index == 0 else 0), 0, 0, 0)
        claims.append(claim)
        prefix = add(prefix, claim)
        rendered_prefix = add(prefix, (1, 0, 0, 0)) if corrupt_prefix and index == 4 else prefix
        lines.append(
            f"component={component} claim={qm31(claim)} prefix={qm31(rendered_prefix)}"
        )
    for index, relation in enumerate(relations.RELATIONS):
        value = prefix if index == 0 else (0, 0, 0, 0)
        lines.append(f"relation={relation} sum={qm31(value)}")
    compensation = tuple((-limb) % P for limb in prefix)
    if unbalanced:
        compensation = add(compensation, (1, 0, 0, 0))
    public_values = {
        "registers_state": compensation,
        "merkle": (0, 0, 0, 0),
        "memory_access": (0, 0, 0, 0),
    }
    for relation in relations.PUBLIC_RELATIONS:
        lines.append(f"public={relation} sum={qm31(public_values[relation])}")
    public = compensation
    lines.append(
        f"aggregate=native sum={qm31(prefix)} public_sum={qm31(public)} "
        f"balanced_sum={qm31(add(prefix, public))}"
    )
    return "\n".join(lines) + "\n"


def limitation_payload(producer: str = "rust") -> dict:
    invalid = [
        {
            "row": row,
            "opcode_id": opcode,
            "request_index": request,
            "tuple": list(values),
            "classification": "range_check_8_11_value_out_of_range",
        }
        for row, opcode, request, values in relations.EXPECTED_INVALID_REQUESTS
    ]
    payload = {
        "schema": relations.LIMITATION_SCHEMA,
        "limitation_id": relations.LIMITATION_ID,
        "oracle_commit": "b" * 40,
        "family": "mulh",
        **relations.EXPECTED_LIMITATION_COUNTS,
        "raw_stream_sha256": "1" * 64,
        "range811_stream_sha256": "2" * 64,
        "invalid_requests_sha256": "3" * 64,
        "invalid_requests": invalid,
        "outcome": "preprocessed_registration_rejected",
        "source": {
            "elf_sha256": "4" * 64,
            "input_sha256": relations.EMPTY_INPUT_DIGEST,
        },
    }
    if producer == "zig":
        payload["provenance"] = {
            "implementation_commit": "a" * 40,
            "implementation_dirty": False,
            "oracle_commit": "b" * 40,
            "witness_layout_sha256": "5" * 64,
        }
    return payload


def parse_limitation(payload: dict, producer: str = "rust") -> dict:
    return relations.parse_limitation_diagnostic(
        json.dumps(payload, separators=(",", ":")) + "\n",
        producer=producer,
        candidate="a" * 40,
        pinned="b" * 40,
        vector={"elf_sha256": "4" * 64},
        witness_layout_sha256="5" * 64,
    )


class RelationEvidenceTest(unittest.TestCase):
    def test_tuple_parser_requires_complete_canonical_evidence(self) -> None:
        parsed = relations.parse_tuple_dump(tuple_dump())
        self.assertEqual(1, parsed["aggregate"]["nonzero_entries"])
        lines = tuple_dump().splitlines()
        lines[2], lines[15] = lines[15], lines[2]
        with self.assertRaisesRegex(relations.EvidenceError, "expected component=auipc"):
            relations.parse_tuple_dump("\n".join(lines) + "\n")

    def test_tuple_comparison_ignores_padding_but_localizes_active_drift(self) -> None:
        self.assertTrue(
            relations.compare_tuple_dumps(
                tuple_dump(1, bound=False), tuple_dump(7)
            )["agree"]
        )
        result = relations.compare_tuple_dumps(
            tuple_dump(bound=False), tuple_dump(active_digest="4" * 64)
        )
        self.assertFalse(result["agree"])
        self.assertIn("/components/auipc", result["first_divergence"]["path"])

    def test_sum_parser_checks_prefixes_domain_totals_and_balance(self) -> None:
        parsed = relations.parse_sum_dump(sum_dump())
        self.assertEqual((27, 0, 0, 0), parsed["aggregate"]["native"])
        with self.assertRaisesRegex(relations.EvidenceError, "cumulative prefix drifted"):
            relations.parse_sum_dump(sum_dump(corrupt_prefix=True))
        with self.assertRaisesRegex(
            relations.EvidenceError,
            "relation registers_state is not independently balanced",
        ):
            relations.parse_sum_dump(sum_dump(unbalanced=True))

        lines = sum_dump().splitlines()
        register_index = next(
            index for index, line in enumerate(lines)
            if line.startswith("relation=registers_state ")
        )
        program_index = next(
            index for index, line in enumerate(lines)
            if line.startswith("relation=program_access ")
        )
        lines[register_index] = f"relation=registers_state sum={qm31((28, 0, 0, 0))}"
        lines[program_index] = f"relation=program_access sum={qm31((P - 1, 0, 0, 0))}"
        with self.assertRaisesRegex(
            relations.EvidenceError,
            "relation registers_state is not independently balanced",
        ):
            relations.parse_sum_dump("\n".join(lines) + "\n")

    def test_sum_comparison_localizes_first_component_claim_drift(self) -> None:
        result = relations.compare_sum_dumps(
            sum_dump(bound=False), sum_dump(claim_delta=1)
        )
        self.assertFalse(result["agree"])
        self.assertEqual(
            "/components/auipc/claim",
            result["first_divergence"]["path"],
        )

    def test_comparison_requires_root_bound_zig_evidence(self) -> None:
        with self.assertRaisesRegex(relations.EvidenceError, "root-bound schema v3"):
            relations.compare_tuple_dumps(
                tuple_dump(bound=False), tuple_dump(bound=False)
            )
        with self.assertRaisesRegex(relations.EvidenceError, "root-bound schema v2"):
            relations.compare_sum_dumps(sum_dump(bound=False), sum_dump(bound=False))

    def test_binding_rejects_zero_root_and_bad_challenge_mode(self) -> None:
        tuples = tuple_dump().replace(
            f"diagnostic_main_commitment={'7' * 64}",
            f"diagnostic_main_commitment={'0' * 64}",
        )
        with self.assertRaisesRegex(relations.EvidenceError, "unbound zero digest"):
            relations.parse_tuple_dump(tuples, require_binding=True)
        sums = sum_dump().replace(
            "challenge_mode=pinned_default_blake2s_v1",
            "challenge_mode=production",
        )
        with self.assertRaisesRegex(relations.EvidenceError, "challenge mode"):
            relations.parse_sum_dump(sums, require_binding=True)

    def test_limitation_diagnostic_requires_exact_normalized_core(self) -> None:
        rust = parse_limitation(limitation_payload())
        zig = parse_limitation(limitation_payload("zig"), "zig")
        self.assertEqual(relations._limitation_core(rust), relations._limitation_core(zig))

        malformed = limitation_payload()
        malformed["invalid_requests"][0]["request_index"] = 9
        with self.assertRaisesRegex(relations.EvidenceError, "invalid request matrix"):
            parse_limitation(malformed)

        aliased = limitation_payload()
        self.assertLess(
            (aliased["invalid_requests"][0]["tuple"][0]
             + (aliased["invalid_requests"][0]["tuple"][1] << 8)) & 0xFFFF_FFFF,
            1 << 19,
        )
        parse_limitation(aliased)

    def test_limitation_diagnostic_rejects_relabeling_and_unbound_zig(self) -> None:
        relabeled = limitation_payload()
        relabeled["outcome"] = "balanced"
        with self.assertRaisesRegex(relations.EvidenceError, "outcome"):
            parse_limitation(relabeled)

        dirty = limitation_payload("zig")
        dirty["provenance"]["implementation_dirty"] = True
        with self.assertRaisesRegex(relations.EvidenceError, "candidate-bound"):
            parse_limitation(dirty, "zig")

        noncanonical = limitation_payload()
        noncanonical["invalid_requests"][0]["tuple"][1] = relations.M31_MODULUS
        with self.assertRaisesRegex(relations.EvidenceError, "canonical M31"):
            parse_limitation(noncanonical)

        wrong_source = limitation_payload()
        wrong_source["source"]["elf_sha256"] = "6" * 64
        with self.assertRaisesRegex(relations.EvidenceError, "corpus-bound"):
            parse_limitation(wrong_source)

    def test_subprocess_failure_is_never_limitation_evidence(self) -> None:
        from unittest import mock

        completed = mock.Mock(returncode=101, stdout="", stderr="panic")
        with mock.patch.object(relations.subprocess, "run", return_value=completed):
            with self.assertRaisesRegex(
                relations.EvidenceError, "subprocess failure is not evidence"
            ):
                relations._run_exact_json(
                    ["oracle", "--relation-limitation"],
                    cwd=ROOT,
                    label="oracle",
                )


if __name__ == "__main__":
    unittest.main()
