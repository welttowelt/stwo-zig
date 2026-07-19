"""Static candidate/promoted state and CP-11 receipt validation."""

from __future__ import annotations

import hashlib
import json
import re
import time
from pathlib import Path
from typing import Any

try:
    from riscv_trace_vectors_lib import admission as admission_policy
except ModuleNotFoundError:  # Imported as scripts.riscv_release_gate_lib in tests.
    from scripts.riscv_trace_vectors_lib import admission as admission_policy


PINNED_ORACLE = "d478f783055aa0d73a93768a433a3c6c31c91d1c"
ORACLE_REPOSITORY = "https://github.com/ClementWalter/stark-v"
IMPLEMENTATION_REPOSITORY = "https://github.com/teddyjfpender/stwo-zig"
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
ELF_AGREEMENT_BOUNDARIES = ELF_CORPUS_BOUNDARIES - {
    "program_tuples", "memory_roots",
}
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
SIGNED_MULH_FIX_MARKER = "FIX(stark-v-signed-mulh)"
PROOF_SUPPORTED = admission_policy.SUPPORTED
PROOF_FAIL_CLOSED = admission_policy.FAIL_CLOSED
PROOF_DIAGNOSTIC_FAIL_CLOSED = admission_policy.DIAGNOSTIC_FAIL_CLOSED
SIGNED_MULH_LIMITATION = admission_policy.SIGNED_MULH_LIMITATION
BALANCED_RELATION_MODE = "balanced_full"
LIMITATION_RELATION_MODE = "pinned_known_limitation"
LIMITATION_DIAGNOSTIC = (
    "stark-v adapter: error=UnsupportedProofFamily "
    "stage=statement_validation_before_first_commitment "
    "limitation=stark-v-signed-mulh"
)
EXPECTED_LIMITATION_REQUESTS = (
    (0, 38, 12, (255, 1_073_741_827)),
    (0, 38, 13, (235, 12_582_914)),
    (0, 38, 14, (255, 49_154)),
    (0, 38, 16, (255, 1_610_612_738)),
    (2, 39, 12, (255, 1_073_741_827)),
    (2, 39, 13, (235, 12_582_914)),
    (2, 39, 14, (255, 49_154)),
    (2, 39, 16, (255, 1_610_612_738)),
)
LIMITATION_CORE_FIELDS = {
    "schema", "limitation_id", "oracle_commit", "family", "family_rows",
    "signed_rows", "unsigned_rows", "raw_nonzero_entries", "raw_stream_sha256",
    "range811_requests", "range811_stream_sha256", "invalid_request_count",
    "invalid_requests_sha256", "invalid_requests", "outcome", "source",
}
ALLOWED_ACTIVE_DIVERGENCES = frozenset({
    ("RISC-V", "PCS geometry"),
    ("RISC-V", "Interaction transcript"),
    ("RISC-V", "Signed `MULH` carry relation"),
})
REQUIRED_ARCHITECTURAL_DIVERGENCES = frozenset({
    ("RISC-V", "PCS geometry"),
    ("RISC-V", "Interaction transcript"),
})
KNOWN_PIN_DOCUMENTED_LIMITATIONS = {
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
    """Reject active divergences except narrow, explicitly documented exceptions."""
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

    for key in REQUIRED_ARCHITECTURAL_DIVERGENCES:
        if key not in rows:
            errors.append(
                "required architectural divergence is missing: "
                f"{key[0]} / {key[1]}"
            )

    for key in KNOWN_PIN_DOCUMENTED_LIMITATIONS.get(pinned_oracle, frozenset()):
        if key not in rows:
            errors.append(
                "known oracle limitation lacks its mandatory documented divergence: "
                f"{key[0]} / {key[1]}"
            )
    return errors


def divergence_errors(root: Path) -> list[str]:
    ledger = root / "conformance/divergence-log.md"
    if not ledger.is_file():
        return ["missing required release artifact: conformance/divergence-log.md"]
    return divergence_ledger_errors(ledger.read_text(encoding="utf-8"))


def oracle_limitation_source_errors(source: str) -> list[str]:
    """Require the implementation marker for the pinned signed-MULH defect."""
    if SIGNED_MULH_FIX_MARKER not in source:
        return [f"signed-MULH oracle limitation lacks {SIGNED_MULH_FIX_MARKER}"]
    return []


def repository_contract_errors(root: Path, phase: str) -> list[str]:
    required = (
        "conformance/2026-07-18-riscv-release-goal.md",
        "conformance/divergence-log.md",
        "scripts/riscv_release_gate.py",
        "scripts/riscv_release_evidence.py",
        "scripts/riscv_release_oracle.py",
        "scripts/riscv_staged_smoke.py",
        "scripts/riscv_trace_vectors.py",
        "src/frontends/riscv/air/semantics/mulh.zig",
    )
    errors = [f"missing required release artifact: {path}" for path in required if not (root / path).is_file()]
    registry = (root / "src/tools/prove/registry.zig").read_text(encoding="utf-8")
    artifact = (root / "src/interop/riscv_artifact.zig").read_text(encoding="utf-8")
    cli = (root / "src/tools/prove/cli.zig").read_text(encoding="utf-8")
    errors.extend(phase_errors(phase, registry, artifact, cli))
    errors.extend(divergence_errors(root))
    mulh_semantics = root / "src/frontends/riscv/air/semantics/mulh.zig"
    if mulh_semantics.is_file():
        errors.extend(oracle_limitation_source_errors(mulh_semantics.read_text(encoding="utf-8")))

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


def trace_vector_contract() -> tuple[
    tuple[str, ...], dict[str, dict[str, str]], dict[str, str]
]:
    root = Path(__file__).resolve().parents[2]
    payload = json.loads(
        (root / "vectors/riscv_elfs/trace_vectors.json").read_text(encoding="utf-8")
    )
    vectors = payload.get("vectors")
    if not isinstance(vectors, list):
        raise ValueError("trace-vector manifest has no positive vector list")
    names = tuple(
        vector.get("name") if isinstance(vector, dict) else None for vector in vectors
    )
    if not names or any(not isinstance(name, str) for name in names) or len(set(names)) != len(names):
        raise ValueError("trace-vector manifest has invalid or duplicate names")
    expected = admission_policy.for_programs(names)
    admission_errors = admission_policy.errors(vectors, expected)
    if admission_errors:
        raise ValueError(
            "trace-vector proof-admission policy is invalid: " + "; ".join(admission_errors)
        )
    elf_digests = {vector["name"]: vector.get("elf_sha256") for vector in vectors}
    if any(SHA256_RE.fullmatch(digest or "") is None for digest in elf_digests.values()):
        raise ValueError("trace-vector manifest has an invalid ELF digest")
    return names, expected, elf_digests


def trace_vector_names() -> tuple[str, ...]:
    return trace_vector_contract()[0]


def expected_case_result_keys(vector_names: tuple[str, ...]) -> list[str]:
    keys = [f"{boundary}/aggregate" for boundary in BOUNDARIES]
    for boundary in BOUNDARIES:
        if boundary in ELF_CORPUS_BOUNDARIES:
            keys.extend(f"{boundary}/{name}" for name in vector_names)
        elif boundary in GENERATED_CORPUS_KEYS:
            keys.append(GENERATED_CORPUS_KEYS[boundary])
    return sorted(keys)


def _limitation_core_errors(core: object, label: str, elf_sha256: object) -> list[str]:
    errors: list[str] = []
    if not isinstance(core, dict) or set(core) != LIMITATION_CORE_FIELDS:
        return [f"{label} normalized limitation core is missing or non-canonical"]
    expected = {
        "schema": "riscv-mulh-limitation-v1",
        "limitation_id": SIGNED_MULH_LIMITATION,
        "oracle_commit": PINNED_ORACLE,
        "family": "mulh",
        "family_rows": 3,
        "signed_rows": 2,
        "unsigned_rows": 1,
        "raw_nonzero_entries": 60,
        "range811_requests": 24,
        "invalid_request_count": 8,
        "outcome": "preprocessed_registration_rejected",
    }
    for field, value in expected.items():
        if core.get(field) != value or type(core.get(field)) is not type(value):
            errors.append(f"{label} limitation core has invalid {field}")
    for field in (
        "raw_stream_sha256", "range811_stream_sha256", "invalid_requests_sha256"
    ):
        _sha(core.get(field), f"{label} limitation core {field}", errors)
    if core.get("source") != {
        "elf_sha256": elf_sha256,
        "input_sha256": hashlib.sha256(b"").hexdigest(),
    }:
        errors.append(f"{label} limitation core is not bound to the live source")

    requests = core.get("invalid_requests")
    if not isinstance(requests, list) or len(requests) != 8:
        errors.append(f"{label} limitation core has no exact invalid-request matrix")
        return errors
    identities: set[tuple[int, int, int]] = set()
    observed_requests: list[tuple[int, int, int, tuple[int, int]]] = []
    for request in requests:
        if not isinstance(request, dict) or set(request) != {
            "row", "opcode_id", "request_index", "tuple", "classification",
        }:
            errors.append(f"{label} limitation core has a malformed invalid request")
            continue
        row = request.get("row")
        opcode_id = request.get("opcode_id")
        request_index = request.get("request_index")
        values = request.get("tuple")
        if (
            type(row) is not int or not 0 <= row < 3
            or type(opcode_id) is not int or opcode_id not in {38, 39}
            or type(request_index) is not int
            or not isinstance(values, list) or len(values) != 2
            or any(
                type(value) is not int or not 0 <= value < (1 << 31) - 1
                for value in values
            )
            or request.get("classification") != "range_check_8_11_value_out_of_range"
        ):
            errors.append(f"{label} limitation core has an invalid request record")
            continue
        identity = (row, opcode_id, request_index)
        if identity in identities:
            errors.append(f"{label} limitation core duplicates an invalid request")
        identities.add(identity)
        observed_requests.append((row, opcode_id, request_index, tuple(values)))
    if tuple(observed_requests) != EXPECTED_LIMITATION_REQUESTS:
        errors.append(f"{label} limitation core request matrix is not exact")
    return errors


def _relation_case_errors(
    case: dict,
    boundary: str,
    admission: dict[str, str],
) -> list[str]:
    label = f"boundary case {boundary}/{case.get('name')}"
    errors: list[str] = []
    if case.get("proof_admission") != admission:
        errors.append(f"{label} relabels the live proof-admission policy")
    status = admission["status"]
    if status in {PROOF_SUPPORTED, PROOF_DIAGNOSTIC_FAIL_CLOSED}:
        if case.get("evidence_mode") != BALANCED_RELATION_MODE:
            errors.append(f"{label} is not a full balanced relation comparison")
        expected_admitted = status == PROOF_SUPPORTED
        if case.get("proof_admitted") is not expected_admitted:
            errors.append(f"{label} has an invalid proof-admission verdict")
        if case.get("agree") is not True:
            errors.append(f"{label} does not attest balanced agreement")
        if status == PROOF_DIAGNOSTIC_FAIL_CLOSED:
            count = case.get("mulh_nonzero_entries")
            if type(count) is not int or count <= 0:
                errors.append(f"{label} has no nonzero MULH tuple evidence")
        if "limitation_evidence" in case or "comparison_outcome" in case:
            errors.append(f"{label} mixes balanced and limitation evidence")
        return errors

    if status != PROOF_FAIL_CLOSED:
        return [f"{label} uses an unknown proof-admission status"]
    if case.get("evidence_mode") != LIMITATION_RELATION_MODE:
        errors.append(f"{label} is not exact pinned-limitation evidence")
    if case.get("proof_admitted") is not False:
        errors.append(f"{label} calls the signed-MULH case proof-admitted")
    if case.get("agree") is not True:
        errors.append(f"{label} does not attest exact fail-closed agreement")
    if case.get("comparison_outcome") != "exact_pinned_limitation_fail_closed":
        errors.append(f"{label} lacks the exact fail-closed outcome")
    expected_observation = (
        "raw_relation_requests" if boundary == "relation_tuples"
        else "preprocessed_registration"
    )
    if case.get("observation") != expected_observation:
        errors.append(f"{label} has the wrong limitation observation")
    evidence = case.get("limitation_evidence")
    if not isinstance(evidence, dict) or set(evidence) != {
        "normalized_core", "normalized_core_sha256", "production_rejection",
    }:
        errors.append(f"{label} has incomplete limitation evidence")
        return errors
    core = evidence["normalized_core"]
    errors.extend(_limitation_core_errors(core, label, case.get("elf_sha256")))
    if isinstance(core, dict):
        expected_digest = _canonical_digest(core)
        if evidence.get("normalized_core_sha256") != expected_digest:
            errors.append(f"{label} limitation core digest does not bind the core")
    production = evidence.get("production_rejection")
    if not isinstance(production, dict) or set(production) != {
        "exit_code", "stdout_sha256", "stderr_sha256", "diagnostic",
        "proof_artifact_absent", "report_artifact_absent", "temporary_residue_absent",
    }:
        errors.append(f"{label} has incomplete production rejection evidence")
        return errors
    if (
        production.get("exit_code") != 1
        or production.get("stdout_sha256") != hashlib.sha256(b"").hexdigest()
        or production.get("diagnostic") != LIMITATION_DIAGNOSTIC
        or production.get("stderr_sha256")
        != hashlib.sha256((LIMITATION_DIAGNOSTIC + "\n").encode()).hexdigest()
        or production.get("proof_artifact_absent") is not True
        or production.get("report_artifact_absent") is not True
        or production.get("temporary_residue_absent") is not True
    ):
        errors.append(f"{label} production rejection is not the exact no-artifact contract")
    return errors


def receipt_errors(
    receipt: dict[str, Any],
    candidate: str,
    *,
    now: int | None = None,
    vector_names: tuple[str, ...] | None = None,
) -> list[str]:
    """Validate the full CP-11 evidence contract, not only its verdict bit."""
    errors: list[str] = []
    try:
        live_names, live_admission, live_elf_digests = trace_vector_contract()
    except (OSError, TypeError, ValueError, json.JSONDecodeError) as error:
        errors.append(f"live trace-vector contract is invalid: {error}")
        live_names, live_admission, live_elf_digests = (), {}, {}
    if vector_names is None:
        names = live_names
        admissions = live_admission
        elf_digests = live_elf_digests
    else:
        names = vector_names
        admissions = (
            live_admission
            if vector_names == live_names
            else {name: {"status": PROOF_SUPPORTED} for name in vector_names}
        )
        elf_digests = live_elf_digests if vector_names == live_names else {}
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

    implementation = receipt.get("implementation")
    if not isinstance(implementation, dict):
        errors.append("Zig implementation provenance is missing")
        implementation = {}
    if implementation.get("repository") != IMPLEMENTATION_REPOSITORY:
        errors.append("Zig implementation repository identity is not pinned")
    if implementation.get("commit") != candidate:
        errors.append("Zig implementation executable belongs to another candidate")
    if implementation.get("clean") is not True:
        errors.append("Zig implementation executable does not attest a clean source tree")
    executables = implementation.get("executables")
    if not isinstance(executables, dict) or set(executables) != {
        "riscv-trace-dump", "stwo-zig",
    }:
        errors.append("Zig implementation executable manifest is incomplete or non-canonical")
    else:
        for name, digest in executables.items():
            _sha(digest, f"Zig executable {name}", errors)

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

    expected_keys = expected_case_result_keys(names)
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

        for boundary_name in ELF_CORPUS_BOUNDARIES:
            boundary = boundaries.get(boundary_name)
            cases = boundary.get("corpus") if isinstance(boundary, dict) else None
            if not isinstance(cases, list):
                errors.append(f"boundary {boundary_name} has no per-corpus evidence")
                continue
            case_names = tuple(
                case.get("name") if isinstance(case, dict) else None for case in cases
            )
            if case_names != names:
                errors.append(
                    f"boundary {boundary_name} corpus is incomplete, duplicated, or non-canonical"
                )
                continue
            for case in cases:
                key = f"{boundary_name}/{case['name']}"
                expected_elf = elf_digests.get(case["name"])
                if (
                    boundary_name in {"relation_tuples", "relation_sums"}
                    and expected_elf is not None
                    and case.get("elf_sha256") != expected_elf
                ):
                    errors.append(f"boundary case {key} is not bound to the live ELF digest")
                if digests.get(key) != _canonical_digest(case):
                    errors.append(f"case-result digest does not bind {key}")
                if boundary_name in ELF_AGREEMENT_BOUNDARIES and case.get("agree") is not True:
                    errors.append(f"boundary case {key} does not attest agreement")
                if boundary_name in {"relation_tuples", "relation_sums"}:
                    expected_admission = admissions.get(case["name"])
                    if expected_admission is None:
                        errors.append(f"boundary case {key} has no live admission policy")
                    else:
                        errors.extend(_relation_case_errors(
                            case, boundary_name, expected_admission
                        ))
        for boundary_name, key in GENERATED_CORPUS_KEYS.items():
            boundary = boundaries.get(boundary_name)
            if isinstance(boundary, dict) and digests.get(key) != _canonical_digest(boundary):
                errors.append(f"case-result digest does not bind {key}")
    return errors


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()
