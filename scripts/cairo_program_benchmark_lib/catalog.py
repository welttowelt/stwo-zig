"""Canonical Cairo program benchmark catalog and bounded size parsing."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


MAX_CASES = 9
MAX_SIZES_PER_PROGRAM = 16


@dataclass(frozen=True)
class ProgramSpec:
    slug: str
    display_name: str
    source_relative: Path
    size_unit: str
    size_semantics: str
    default_sizes: tuple[int, ...]
    maximum_size: int
    size_multiple: int = 1
    exact_cycle_rule: str | None = None

    @property
    def artifact_relative(self) -> Path:
        return self.source_relative.parent / "compiled.json"

    def validate_size(self, value: int) -> None:
        if value <= 0:
            raise ValueError(f"{self.slug} size must be positive")
        if value > self.maximum_size:
            raise ValueError(
                f"{self.slug} size exceeds the safety limit "
                f"({value} > {self.maximum_size})"
            )
        if value % self.size_multiple != 0:
            raise ValueError(
                f"{self.slug} size must be divisible by {self.size_multiple}"
            )

    def expected_cycle_count(self, value: int) -> int | None:
        self.validate_size(value)
        if self.exact_cycle_rule == "7*n+16":
            return 7 * value + 16
        return None

    def as_record(self) -> dict[str, object]:
        return {
            "slug": self.slug,
            "display_name": self.display_name,
            "source_relative": self.source_relative.as_posix(),
            "artifact_relative": self.artifact_relative.as_posix(),
            "size_unit": self.size_unit,
            "size_semantics": self.size_semantics,
            "size_multiple": self.size_multiple,
            "maximum_size": self.maximum_size,
            "exact_cycle_rule": self.exact_cycle_rule,
        }


PROGRAMS = (
    ProgramSpec(
        slug="fib",
        display_name="Fibonacci",
        source_relative=Path("fib/fibonacci.cairo"),
        size_unit="iterations",
        size_semantics="recursive Fibonacci iterations",
        default_sizes=(25_000, 100_000, 500_000, 2_000_000),
        maximum_size=4_194_304,
        exact_cycle_rule="7*n+16",
    ),
    ProgramSpec(
        slug="sha2",
        display_name="SHA-256",
        source_relative=Path("sha2/sha256.cairo"),
        size_unit="input_bytes",
        size_semantics="bytes hashed by one SHA-256 invocation",
        default_sizes=(64, 1_024, 16_384),
        maximum_size=4_194_304,
        size_multiple=4,
    ),
    ProgramSpec(
        slug="sha2-chain",
        display_name="SHA-256 chain",
        source_relative=Path("sha2-chain/sha256_chain.cairo"),
        size_unit="hashes",
        size_semantics="chained SHA-256 invocations over 32-byte states",
        default_sizes=(8, 64, 256),
        maximum_size=16_384,
    ),
    ProgramSpec(
        slug="sha3",
        display_name="Keccak",
        source_relative=Path("sha3/cairo_keccak.cairo"),
        size_unit="input_bytes",
        size_semantics="bytes hashed by one Cairo Keccak invocation",
        default_sizes=(64, 1_024, 16_384),
        maximum_size=4_194_304,
        size_multiple=8,
    ),
    ProgramSpec(
        slug="sha3-chain",
        display_name="Keccak chain",
        source_relative=Path("sha3-chain/keccak_chain.cairo"),
        size_unit="hashes",
        size_semantics="chained Keccak invocations",
        default_sizes=(8, 64, 256),
        maximum_size=16_384,
    ),
    ProgramSpec(
        slug="blake",
        display_name="Blake precompile",
        source_relative=Path("blake-precompile/blake.cairo"),
        size_unit="input_bytes",
        size_semantics="bytes processed by the Cairo Blake opcode",
        default_sizes=(64, 1_024, 16_384),
        maximum_size=4_194_304,
        size_multiple=4,
    ),
    ProgramSpec(
        slug="blake-chain",
        display_name="Blake chain",
        source_relative=Path("blake-chain-precompile/blake_chain.cairo"),
        size_unit="hashes",
        size_semantics="chained Blake opcode invocations",
        default_sizes=(8, 64, 256),
        maximum_size=16_384,
    ),
    ProgramSpec(
        slug="mat-mul",
        display_name="Matrix multiplication",
        source_relative=Path("mat_mul/mat_mul.cairo"),
        size_unit="matrix_dimension",
        size_semantics="dimension N of an N by N matrix product",
        default_sizes=(16, 32, 64),
        maximum_size=128,
    ),
    ProgramSpec(
        slug="ec",
        display_name="secp256k1 doubling",
        source_relative=Path("ec/ec_add.cairo"),
        size_unit="point_doublings",
        size_semantics="repeated secp256k1 point doublings",
        default_sizes=(64, 256, 1_024),
        maximum_size=4_096,
    ),
)

PROGRAM_BY_SLUG = {program.slug: program for program in PROGRAMS}


def parse_case(encoded: str) -> tuple[ProgramSpec, tuple[int, ...]]:
    slug, separator, encoded_sizes = encoded.partition("=")
    if not separator or slug not in PROGRAM_BY_SLUG:
        choices = ", ".join(PROGRAM_BY_SLUG)
        raise ValueError(f"case must be PROGRAM=N[,N...] where PROGRAM is one of: {choices}")
    try:
        sizes = tuple(int(value) for value in encoded_sizes.split(","))
    except ValueError as error:
        raise ValueError(f"{slug} sizes must be integers") from error
    if not sizes or len(sizes) > MAX_SIZES_PER_PROGRAM:
        raise ValueError(
            f"{slug} must contain between 1 and {MAX_SIZES_PER_PROGRAM} sizes"
        )
    if len(set(sizes)) != len(sizes):
        raise ValueError(f"{slug} sizes must be unique")
    program = PROGRAM_BY_SLUG[slug]
    for size in sizes:
        program.validate_size(size)
    return program, sizes


def resolve_cases(encoded_cases: list[str] | None) -> list[tuple[ProgramSpec, tuple[int, ...]]]:
    if encoded_cases is None:
        return [(program, program.default_sizes) for program in PROGRAMS]
    cases = [parse_case(value) for value in encoded_cases]
    if not cases or len(cases) > MAX_CASES:
        raise ValueError(f"benchmark must contain between 1 and {MAX_CASES} programs")
    slugs = [program.slug for program, _ in cases]
    if len(set(slugs)) != len(slugs):
        raise ValueError("each Cairo program may appear in only one case")
    return cases
