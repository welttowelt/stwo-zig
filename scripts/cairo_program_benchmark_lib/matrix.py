"""Strict loader for the canonical Cairo acceptance corpus."""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path
from typing import Any


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
MATRIX_PATH = REPOSITORY_ROOT / "vectors/cairo/cairo_program_matrix.json"
PROGRAM_COUNT = 9
TIER_NAMES = ("small", "medium", "large")
CASE_COUNT = PROGRAM_COUNT * len(TIER_NAMES)

_HEX_40 = re.compile(r"[0-9a-f]{40}")
_HEX_64 = re.compile(r"[0-9a-f]{64}")
_SLUG = re.compile(r"[a-z0-9]+(?:[-_][a-z0-9]+)*")


def _object(value: object, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be an object")
    return value


def _array(value: object, label: str) -> list[Any]:
    if not isinstance(value, list):
        raise ValueError(f"{label} must be an array")
    return value


def _string(value: object, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError(f"{label} must be a non-empty string")
    return value


def _integer(value: object, label: str, *, positive: bool = False) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError(f"{label} must be an integer")
    if positive and value <= 0:
        raise ValueError(f"{label} must be positive")
    return value


def _relative_path(value: object, label: str) -> str:
    encoded = _string(value, label)
    path = Path(encoded)
    if path.is_absolute() or ".." in path.parts or path.as_posix() != encoded:
        raise ValueError(f"{label} must be a normalized relative path")
    return encoded


def _validate_compiler(document: dict[str, Any]) -> None:
    compiler = _object(document.get("compiler"), "compiler")
    _string(compiler.get("executable"), "compiler.executable")
    _string(compiler.get("version"), "compiler.version")
    profile = _string(compiler.get("profile"), "compiler.profile")
    arguments = _array(compiler.get("arguments"), "compiler.arguments")
    if any(not isinstance(argument, str) or not argument for argument in arguments):
        raise ValueError("compiler.arguments must contain non-empty strings")
    if profile != "proof_mode" or arguments != ["--proof_mode"]:
        raise ValueError("Cairo corpus compiler profile must be proof_mode")
    _string(compiler.get("program_input_key"), "compiler.program_input_key")


def _validate_source_repository(document: dict[str, Any]) -> None:
    source = _object(document.get("source_repository"), "source_repository")
    url = _string(source.get("url"), "source_repository.url")
    if not url.startswith("https://") or not url.endswith(".git"):
        raise ValueError("source_repository.url must be an HTTPS Git URL")
    commit = _string(source.get("commit"), "source_repository.commit")
    if _HEX_40.fullmatch(commit) is None:
        raise ValueError("source_repository.commit must be a lowercase Git commit")
    _relative_path(source.get("program_root"), "source_repository.program_root")


def _validate_programs(document: dict[str, Any]) -> dict[str, dict[str, Any]]:
    records = _array(document.get("programs"), "programs")
    if len(records) != PROGRAM_COUNT:
        raise ValueError(f"Cairo corpus must contain exactly {PROGRAM_COUNT} programs")

    programs: dict[str, dict[str, Any]] = {}
    source_paths: set[str] = set()
    for index, value in enumerate(records):
        label = f"programs[{index}]"
        record = _object(value, label)
        slug = _string(record.get("slug"), f"{label}.slug")
        if _SLUG.fullmatch(slug) is None or slug in programs:
            raise ValueError(f"{label}.slug must be a unique canonical slug")
        _string(record.get("display_name"), f"{label}.display_name")
        source_relative = _relative_path(
            record.get("source_relative"), f"{label}.source_relative"
        )
        if source_relative in source_paths:
            raise ValueError("Cairo corpus source paths must be unique")
        source_paths.add(source_relative)
        source_sha256 = _string(record.get("source_sha256"), f"{label}.source_sha256")
        if _HEX_64.fullmatch(source_sha256) is None:
            raise ValueError(f"{label}.source_sha256 must be lowercase SHA-256")
        _string(record.get("size_unit"), f"{label}.size_unit")
        _string(record.get("size_semantics"), f"{label}.size_semantics")
        _string(record.get("primary_stress"), f"{label}.primary_stress")
        _integer(record.get("maximum_size"), f"{label}.maximum_size", positive=True)
        _integer(record.get("size_multiple"), f"{label}.size_multiple", positive=True)
        rule = record.get("exact_cycle_rule")
        if rule is not None and rule != "7*n+16":
            raise ValueError(f"{label}.exact_cycle_rule is unsupported")
        programs[slug] = record
    return programs


def _validate_cases(
    document: dict[str, Any], programs: dict[str, dict[str, Any]]
) -> None:
    records = _array(document.get("cases"), "cases")
    if len(records) != CASE_COUNT:
        raise ValueError(f"Cairo corpus must contain exactly {CASE_COUNT} cases")

    identities: set[str] = set()
    program_tiers: set[tuple[str, str]] = set()
    for index, value in enumerate(records):
        label = f"cases[{index}]"
        record = _object(value, label)
        program_slug = _string(record.get("program"), f"{label}.program")
        tier = _string(record.get("tier"), f"{label}.tier")
        if program_slug not in programs:
            raise ValueError(f"{label}.program is not in the canonical corpus")
        if tier not in TIER_NAMES:
            raise ValueError(f"{label}.tier is not canonical")
        identity = _string(record.get("identity"), f"{label}.identity")
        if identity != f"{program_slug}:{tier}" or identity in identities:
            raise ValueError(f"{label}.identity must uniquely equal PROGRAM:TIER")
        identities.add(identity)
        key = (program_slug, tier)
        if key in program_tiers:
            raise ValueError("Cairo corpus program/tier pairs must be unique")
        program_tiers.add(key)

        program = programs[program_slug]
        if record.get("size_unit") != program["size_unit"]:
            raise ValueError(f"{label}.size_unit does not match its program")
        size = _integer(record.get("size"), f"{label}.size", positive=True)
        _integer(record.get("expected_cycles"), f"{label}.expected_cycles", positive=True)
        if size > program["maximum_size"] or size % program["size_multiple"]:
            raise ValueError(f"{label}.size violates its program bounds")
        if program.get("exact_cycle_rule") == "7*n+16":
            if record["expected_cycles"] != 7 * size + 16:
                raise ValueError(f"{label}.expected_cycles violates the Fib cycle law")

    expected = {
        (program_slug, tier)
        for program_slug in programs
        for tier in TIER_NAMES
    }
    if program_tiers != expected:
        raise ValueError("Cairo corpus must cover every program/tier pair exactly once")


def load_matrix(path: Path = MATRIX_PATH) -> dict[str, Any]:
    """Load and fully validate a Cairo acceptance corpus document."""

    try:
        document = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"invalid Cairo acceptance corpus: {path}") from error
    document = _object(document, "Cairo acceptance corpus")
    if document.get("schema_version") != 1:
        raise ValueError("unsupported Cairo acceptance corpus schema")
    if document.get("kind") != "cairo_acceptance_corpus":
        raise ValueError("unexpected Cairo acceptance corpus kind")
    _validate_compiler(document)
    _validate_source_repository(document)
    tiers = tuple(_array(document.get("tiers"), "tiers"))
    if tiers != TIER_NAMES:
        raise ValueError("Cairo corpus tiers must be small, medium, and large")
    programs = _validate_programs(document)
    _validate_cases(document, programs)
    return document


def matrix_sha256(document: dict[str, Any]) -> str:
    """Hash the semantic JSON document independently of whitespace."""

    encoded = json.dumps(document, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


MATRIX = load_matrix()
MATRIX_SHA256 = matrix_sha256(MATRIX)
