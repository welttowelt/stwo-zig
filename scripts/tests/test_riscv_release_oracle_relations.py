"""Fail-closed tests for CP-11 relation evidence parsing and comparison."""

from __future__ import annotations

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


def tuple_dump(padding: int = 1, active_digest: str = NONZERO) -> str:
    lines = ["schema=riscv-relation-tuples-v2"]
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


def sum_dump(claim_delta: int = 0, corrupt_prefix: bool = False) -> str:
    lines = ["schema=riscv-relation-sums-v1"]
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
    public_values = {
        "registers_state": (2, 0, 0, 0),
        "merkle": (3, 0, 0, 0),
        "memory_access": (5, 0, 0, 0),
    }
    for relation in relations.PUBLIC_RELATIONS:
        lines.append(f"public={relation} sum={qm31(public_values[relation])}")
    public = (10, 0, 0, 0)
    lines.append(
        f"aggregate=native sum={qm31(prefix)} public_sum={qm31(public)} "
        f"balanced_sum={qm31(add(prefix, public))}"
    )
    return "\n".join(lines) + "\n"


class RelationEvidenceTest(unittest.TestCase):
    def test_tuple_parser_requires_complete_canonical_evidence(self) -> None:
        parsed = relations.parse_tuple_dump(tuple_dump())
        self.assertEqual(1, parsed["aggregate"]["nonzero_entries"])
        lines = tuple_dump().splitlines()
        lines[1], lines[14] = lines[14], lines[1]
        with self.assertRaisesRegex(relations.EvidenceError, "expected component=auipc"):
            relations.parse_tuple_dump("\n".join(lines) + "\n")

    def test_tuple_comparison_ignores_padding_but_localizes_active_drift(self) -> None:
        self.assertTrue(
            relations.compare_tuple_dumps(tuple_dump(1), tuple_dump(7))["agree"]
        )
        result = relations.compare_tuple_dumps(tuple_dump(), tuple_dump(active_digest="4" * 64))
        self.assertFalse(result["agree"])
        self.assertIn("/components/auipc", result["first_divergence"]["path"])

    def test_sum_parser_checks_prefixes_domain_totals_and_balance(self) -> None:
        parsed = relations.parse_sum_dump(sum_dump())
        self.assertEqual((27, 0, 0, 0), parsed["aggregate"]["native"])
        with self.assertRaisesRegex(relations.EvidenceError, "cumulative prefix drifted"):
            relations.parse_sum_dump(sum_dump(corrupt_prefix=True))

    def test_sum_comparison_localizes_first_component_claim_drift(self) -> None:
        result = relations.compare_sum_dumps(sum_dump(), sum_dump(claim_delta=1))
        self.assertFalse(result["agree"])
        self.assertEqual(
            "/components/auipc/claim",
            result["first_divergence"]["path"],
        )


if __name__ == "__main__":
    unittest.main()
