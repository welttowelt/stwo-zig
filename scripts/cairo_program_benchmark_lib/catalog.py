"""Typed catalog projected from the canonical Cairo acceptance corpus."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from .matrix import MATRIX, MATRIX_SHA256, TIER_NAMES


MAX_CASES = len(MATRIX["programs"])
MAX_SIZES_PER_PROGRAM = 16
CORPUS_SHA256 = MATRIX_SHA256
COMPILER = MATRIX["compiler"]
SOURCE_REPOSITORY = MATRIX["source_repository"]


@dataclass(frozen=True)
class ProgramTier:
    name: str
    size: int
    expected_cycles: int

    def as_record(self) -> dict[str, object]:
        return {
            "tier": self.name,
            "size": self.size,
            "expected_cycles": self.expected_cycles,
        }


@dataclass(frozen=True)
class ProgramSpec:
    slug: str
    display_name: str
    source_relative: Path
    source_sha256: str
    size_unit: str
    size_semantics: str
    primary_stress: str
    maximum_size: int
    size_multiple: int
    exact_cycle_rule: str | None
    tiers: tuple[ProgramTier, ...]

    @property
    def artifact_relative(self) -> Path:
        return self.source_relative.parent / "compiled.json"

    @property
    def default_sizes(self) -> tuple[int, ...]:
        """Return exactly the canonical small, medium, and large sizes."""

        return tuple(tier.size for tier in self.tiers)

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
        for tier in self.tiers:
            if tier.size == value:
                return tier.expected_cycles
        if self.exact_cycle_rule == "7*n+16":
            return 7 * value + 16
        return None

    def as_record(self) -> dict[str, object]:
        return {
            "slug": self.slug,
            "display_name": self.display_name,
            "source_relative": self.source_relative.as_posix(),
            "source_sha256": self.source_sha256,
            "artifact_relative": self.artifact_relative.as_posix(),
            "size_unit": self.size_unit,
            "size_semantics": self.size_semantics,
            "primary_stress": self.primary_stress,
            "size_multiple": self.size_multiple,
            "maximum_size": self.maximum_size,
            "exact_cycle_rule": self.exact_cycle_rule,
            "tiers": [tier.as_record() for tier in self.tiers],
        }


def _programs_from_matrix() -> tuple[ProgramSpec, ...]:
    cases_by_program: dict[str, dict[str, dict[str, object]]] = {}
    for case in MATRIX["cases"]:
        cases_by_program.setdefault(case["program"], {})[case["tier"]] = case

    programs: list[ProgramSpec] = []
    for record in MATRIX["programs"]:
        tier_records = cases_by_program[record["slug"]]
        tiers = tuple(
            ProgramTier(
                name=name,
                size=tier_records[name]["size"],
                expected_cycles=tier_records[name]["expected_cycles"],
            )
            for name in TIER_NAMES
        )
        programs.append(
            ProgramSpec(
                slug=record["slug"],
                display_name=record["display_name"],
                source_relative=Path(record["source_relative"]),
                source_sha256=record["source_sha256"],
                size_unit=record["size_unit"],
                size_semantics=record["size_semantics"],
                primary_stress=record["primary_stress"],
                maximum_size=record["maximum_size"],
                size_multiple=record["size_multiple"],
                exact_cycle_rule=record["exact_cycle_rule"],
                tiers=tiers,
            )
        )
    return tuple(programs)


PROGRAMS = _programs_from_matrix()
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
