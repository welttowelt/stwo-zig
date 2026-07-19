"""Static candidate/promoted state and CP-11 receipt validation."""

from __future__ import annotations

import hashlib
import json
import re
import time
from pathlib import Path
from typing import Any


PINNED_ORACLE = "d478f783055aa0d73a93768a433a3c6c31c91d1c"
ORACLE_REPOSITORY = "https://github.com/ClementWalter/stark-v"
BOUNDARIES = (
    "decode",
    "execution",
    "per_family_witness_rows",
    "program_tuples",
    "ordered_accesses",
    "public_values",
    "memory_roots",
    "poseidon2_vectors",
    "relation_tuples",
    "relation_sums",
    "shared_transcript_prefix",
)
ELF_CORPUS_BOUNDARIES = frozenset({
    "execution",
    "per_family_witness_rows",
    "program_tuples",
    "ordered_accesses",
    "public_values",
    "memory_roots",
    "relation_tuples",
    "relation_sums",
    "shared_transcript_prefix",
})
GENERATED_CORPUS_KEYS = {
    "decode": "decode/corpus",
    "poseidon2_vectors": "poseidon2_vectors/corpus",
}
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
MAX_RECEIPT_AGE_SECONDS = 24 * 60 * 60
ZIG_IMPORT_RE = re.compile(r'@import\("([^"\n]+)"\)')
ZIG_NON_CODE_RE = re.compile(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"', re.DOTALL)
ACTIVE_PLACEHOLDER_RE = re.compile(r"\b(?:legacy|placeholder|silent)\b")
MANUAL_SOURCE_CEILING = 850
ALLOWED_ACTIVE_DIVERGENCES = frozenset({("RISC-V", "PCS geometry")})
KNOWN_PIN_BLOCKING_DIVERGENCES = {
    PINNED_ORACLE: frozenset({("RISC-V", "Signed `MULH` carry relation")}),
}


def _contains_assignment(source: str, name: str, value: str) -> bool:
    pattern = rf'pub\s+const\s+{re.escape(name)}\s*=\s*"{re.escape(value)}"\s*;'
    return re.search(pattern, source) is not None


def _contains_bool_assignment(source: str, name: str, value: bool) -> bool:
    rendered = "true" if value else "false"
    pattern = rf"pub\s+const\s+{re.escape(name)}\s*=\s*{rendered}\s*;"
    return re.search(pattern, source) is not None


def phase_errors(phase: str, registry_source: str, artifact_source: str, cli_source: str) -> list[str]:
    """Return every source-level release-state mismatch for ``phase``."""
    if phase not in {"candidate", "promoted"}:
        return [f"unknown release phase: {phase}"]
    errors: list[str] = []
    expected = "not_release_gated" if phase == "candidate" else "release_gated"
    if not _contains_assignment(artifact_source, "RELEASE_STATUS", expected):
        errors.append(f"artifact RELEASE_STATUS is not {expected}")

    promoted = phase == "promoted"
    if not _contains_bool_assignment(registry_source, "RISCV_ADAPTER_RELEASE_GATED", promoted):
        errors.append(f"registry admission switch does not select the {phase} phase")
    for required in (
        '"adapter":"stark-v-rv32im-elf"',
        '"status":"not_release_gated"',
        '"status":"release_gated"',
        '"isa":"rv32im"',
        '"backends":["cpu"]',
        "requireRiscVAdmission",
    ):
        if required not in registry_source:
            errors.append(f"registry is missing required Stark-V release surface: {required}")
    reason = re.search(
        r'"status":"not_release_gated"[^}]*"reason":"([^"]+)"',
        registry_source,
        re.DOTALL,
    )
    if reason is None or not reason.group(1).strip():
        errors.append("deferred Stark-V registry entry lacks a non-empty reason")
    if "Flag.experimental" not in cli_source or '"--experimental"' not in cli_source:
        errors.append("CLI lacks the typed --experimental admission flag")
    return errors


def divergence_ledger_errors(text: str, pinned_oracle: str = PINNED_ORACLE) -> list[str]:
    """Reject every active divergence except a narrowly allowlisted PCS deviation."""
    marker = "## Active divergences"
    if marker not in text:
        return ["divergence ledger has no Active divergences section"]
    active = text.split(marker, 1)[1].split("\n## ", 1)[0]
    rows: dict[tuple[str, str], str] = {}
    errors: list[str] = []
    for raw_line in active.splitlines():
        line = raw_line.strip()
        if not line.startswith("|"):
            continue
        cells = [cell.strip() for cell in line.strip("|").split("|")]
        if not cells or cells[0] == "Lane" or all(set(cell) <= {"-", ":"} for cell in cells):
            continue
        if len(cells) != 5:
            errors.append("divergence ledger contains a malformed active table row")
            continue
        key = (cells[0], cells[1])
        if key in rows:
            errors.append(f"divergence ledger contains duplicate active row: {key[0]} / {key[1]}")
            continue
        rows[key] = cells[4]

    if not rows:
        errors.append("divergence ledger active table is empty or malformed")
    for key, status in sorted(rows.items()):
        if key in ALLOWED_ACTIVE_DIVERGENCES:
            if not status.startswith("Allowed only with "):
                errors.append(
                    f"allowlisted divergence lacks its conditional status: {key[0]} / {key[1]}"
                )
            continue
        errors.append(f"release-blocking divergence remains active: {key[0]} / {key[1]}")

    for key in KNOWN_PIN_BLOCKING_DIVERGENCES.get(pinned_oracle, frozenset()):
        if key not in rows:
            errors.append(
                "known-defective oracle pin lacks its mandatory blocking divergence: "
                f"{key[0]} / {key[1]}"
            )
    return errors


def divergence_errors(root: Path) -> list[str]:
    ledger = root / "conformance/divergence-log.md"
    if not ledger.is_file():
        return ["missing required release artifact: conformance/divergence-log.md"]
    return divergence_ledger_errors(ledger.read_text(encoding="utf-8"))


def repository_contract_errors(root: Path, phase: str) -> list[str]:
    required = (
        "conformance/2026-07-18-riscv-release-goal.md",
        "conformance/divergence-log.md",
        "scripts/riscv_release_gate.py",
        "scripts/riscv_release_evidence.py",
        "scripts/riscv_release_oracle.py",
        "scripts/riscv_staged_smoke.py",
        "scripts/riscv_trace_vectors.py",
    )
    errors = [f"missing required release artifact: {path}" for path in required if not (root / path).is_file()]
    registry = (root / "src/tools/prove/registry.zig").read_text(encoding="utf-8")
    artifact = (root / "src/interop/riscv_artifact.zig").read_text(encoding="utf-8")
    cli = (root / "src/tools/prove/cli.zig").read_text(encoding="utf-8")
    errors.extend(phase_errors(phase, registry, artifact, cli))
    errors.extend(divergence_errors(root))

    autoresearch = root / "autoresearch/MANIFEST.json"
    if autoresearch.is_file():
        payload = json.loads(autoresearch.read_text(encoding="utf-8"))
        groups = payload.get("workload_registry", {}).get("groups", {})
        riscv = groups.get("riscv") if isinstance(groups, dict) else None
        if not isinstance(riscv, dict):
            errors.append("autoresearch RISC-V workload group is missing")
        elif riscv.get("enabled") is not False or not str(riscv.get("disabled_reason", "")).strip():
            errors.append("autoresearch RISC-V workload group must remain disabled through RF-01")
    return errors


def _zig_sources(directory: Path) -> list[Path]:
    if not directory.is_dir():
        return []
    return sorted(
        path
        for path in directory.rglob("*.zig")
        if path.is_file()
        and not {".zig-cache", "generated", "vendor", "zig-out"}.intersection(path.parts)
    )


def _resolved_src_import(source: Path, imported: str, src_root: Path) -> Path | None:
    if not imported.startswith(".") or not imported.endswith(".zig"):
        return None
    target = (source.parent / imported).resolve()
    try:
        relative = target.relative_to(src_root.resolve())
    except ValueError:
        return None
    return relative if target.is_file() else None


def _generated_zig(source: str) -> bool:
    header = "\n".join(source.splitlines()[:8]).lower()
    return "generated" in header and "generator:" in header and "regenerate:" in header


def core_purity_errors(root: Path) -> list[str]:
    """Reject core dependencies on a frontend or concrete backend owner."""
    src_root = root / "src"
    errors: list[str] = []
    forbidden = {"backends", "frontends", "integrations"}
    for source in _zig_sources(src_root / "core"):
        text = source.read_text(encoding="utf-8")
        for imported in ZIG_IMPORT_RE.findall(text):
            target = _resolved_src_import(source, imported, src_root)
            if target is not None and target.parts and target.parts[0] in forbidden:
                display = source.relative_to(root).as_posix()
                errors.append(f"core purity: {display} imports {target.as_posix()}")
    return errors


def frontend_layering_errors(root: Path) -> list[str]:
    """Enforce the backend-neutral RISC-V frontend ownership boundary."""
    src_root = root / "src"
    frontend_root = src_root / "frontends" / "riscv"
    errors: list[str] = []
    forbidden_layers = {"backends", "bench", "examples", "integrations", "interop", "tools"}
    for source in _zig_sources(frontend_root):
        text = source.read_text(encoding="utf-8")
        display = source.relative_to(root).as_posix()
        for imported in ZIG_IMPORT_RE.findall(text):
            target = _resolved_src_import(source, imported, src_root)
            if target is not None and target.parts and target.parts[0] in forbidden_layers:
                errors.append(f"frontend layering: {display} imports {target.as_posix()}")
        line_count = len(text.splitlines())
        if line_count > MANUAL_SOURCE_CEILING and not _generated_zig(text):
            errors.append(
                f"frontend layering: {display} has {line_count} lines "
                f"(manual ceiling {MANUAL_SOURCE_CEILING})"
            )
        code = ZIG_NON_CODE_RE.sub(" ", text)
        markers = sorted(set(ACTIVE_PLACEHOLDER_RE.findall(code)))
        if markers:
            errors.append(
                f"frontend layering: {display} contains active placeholder markers: "
                + ", ".join(markers)
            )
    return errors


def structure_errors(root: Path) -> list[str]:
    return core_purity_errors(root) + frontend_layering_errors(root)


def _sha(value: Any, label: str, errors: list[str]) -> None:
    if not isinstance(value, str) or SHA256_RE.fullmatch(value) is None:
        errors.append(f"{label} is not a lowercase SHA-256 digest")


def _canonical_digest(value: Any) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def trace_vector_names() -> tuple[str, ...]:
    root = Path(__file__).resolve().parents[2]
    payload = json.loads(
        (root / "vectors/riscv_elfs/trace_vectors.json").read_text(encoding="utf-8")
    )
    names = tuple(vector["name"] for vector in payload["vectors"])
    if not names or any(not isinstance(name, str) for name in names) or len(set(names)) != len(names):
        raise ValueError("trace-vector manifest has invalid or duplicate names")
    return names


def expected_case_result_keys(vector_names: tuple[str, ...]) -> list[str]:
    keys = [f"{boundary}/aggregate" for boundary in BOUNDARIES]
    for boundary in BOUNDARIES:
        if boundary in ELF_CORPUS_BOUNDARIES:
            keys.extend(f"{boundary}/{name}" for name in vector_names)
        elif boundary in GENERATED_CORPUS_KEYS:
            keys.append(GENERATED_CORPUS_KEYS[boundary])
    return sorted(keys)


def receipt_errors(
    receipt: dict[str, Any],
    candidate: str,
    *,
    now: int | None = None,
    vector_names: tuple[str, ...] | None = None,
) -> list[str]:
    """Validate the full CP-11 evidence contract, not only its verdict bit."""
    errors: list[str] = []
    if COMMIT_RE.fullmatch(candidate) is None:
        errors.append("candidate is not a full lowercase Git commit")
    if receipt.get("schema") != "riscv-oracle-receipt-v2":
        errors.append("unknown oracle receipt schema")
    if receipt.get("candidate_commit") != candidate:
        errors.append("oracle receipt belongs to another candidate")
    if receipt.get("verdict") != "PASS":
        errors.append(f"oracle receipt verdict is {receipt.get('verdict')!r}")

    oracle = receipt.get("oracle")
    if not isinstance(oracle, dict):
        errors.append("oracle provenance is missing")
        oracle = {}
    if oracle.get("repository") != ORACLE_REPOSITORY:
        errors.append("oracle repository identity is not pinned")
    if oracle.get("commit") != PINNED_ORACLE:
        errors.append("oracle commit identity is not pinned")
    if oracle.get("clean") is not True:
        errors.append("oracle receipt does not attest a clean source tree")
    for field in ("tree_digest_sha256", "lockfile_sha256", "executable_sha256"):
        _sha(oracle.get(field), f"oracle.{field}", errors)
    for field in ("toolchain", "build_command", "build_mode", "host_arch", "host_os"):
        if not isinstance(oracle.get(field), str) or not oracle[field].strip():
            errors.append(f"oracle.{field} is missing")
    if "--locked" not in str(oracle.get("build_command", "")):
        errors.append("oracle build command does not enforce locked dependencies")
    if not isinstance(oracle.get("submodule_status"), list):
        errors.append("oracle submodule state is missing")
    overlay = oracle.get("adapter_overlay")
    if not isinstance(overlay, dict) or not isinstance(overlay.get("path"), str):
        errors.append("oracle adapter overlay identity is missing")
    else:
        _sha(overlay.get("sha256"), "oracle adapter overlay", errors)

    created = receipt.get("created_at_unix")
    current = int(time.time()) if now is None else now
    if not isinstance(created, int):
        errors.append("receipt creation time is missing")
    elif created > current + 300 or current - created > MAX_RECEIPT_AGE_SECONDS:
        errors.append("oracle receipt is expired or from the future")
    _sha(receipt.get("witness_layout_digest_sha256"), "witness layout digest", errors)
    _sha(receipt.get("corpus_digest_sha256"), "corpus digest", errors)

    boundaries = receipt.get("boundaries")
    if not isinstance(boundaries, dict):
        errors.append("boundary results are missing")
        boundaries = {}
    for name in BOUNDARIES:
        boundary = boundaries.get(name)
        if not isinstance(boundary, dict) or boundary.get("status") != "pass":
            status = boundary.get("status") if isinstance(boundary, dict) else "missing"
            errors.append(f"boundary {name} is {status}")

    expected_keys = expected_case_result_keys(
        trace_vector_names() if vector_names is None else vector_names
    )
    declared_keys = receipt.get("expected_case_result_keys")
    if declared_keys != expected_keys:
        errors.append("expected case-result key manifest is incomplete or non-canonical")
    digests = receipt.get("case_result_digests")
    if not isinstance(digests, dict):
        errors.append("per-case result digests are missing")
    else:
        if sorted(digests) != expected_keys:
            errors.append("case-result digest keys do not exactly cover the declared corpus")
        for name, digest in digests.items():
            _sha(digest, f"case result {name}", errors)
        for boundary in BOUNDARIES:
            aggregate = f"{boundary}/aggregate"
            if aggregate in digests and boundary in boundaries:
                if digests[aggregate] != _canonical_digest(boundaries[boundary]):
                    errors.append(f"aggregate digest does not bind boundary {boundary}")
    return errors


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()
