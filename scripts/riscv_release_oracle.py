#!/usr/bin/env python3
"""CP-11 producer: build the pinned Stark-V oracle and compare shared boundaries.

Produces the machine-readable receipt required by
conformance/2026-07-18-riscv-release-goal.md. Every boundary named by the
contract appears in the receipt with an explicit status; boundaries whose
comparison is not yet implemented are recorded as "unimplemented" and the
receipt's overall verdict is FAIL-closed until every boundary passes. The
receipt never claims a comparison that did not run.

Producer:
  python3 scripts/riscv_release_oracle.py build-and-compare \
    --stark-v-source "$STARK_V_SOURCE" \
    --candidate "$(git rev-parse HEAD)" \
    --receipt-out zig-out/release-evidence/riscv/oracle-receipt.json

Validator:
  python3 scripts/riscv_release_oracle.py validate \
    --receipt zig-out/release-evidence/riscv/oracle-receipt.json
"""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import platform
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from riscv_release_gate_lib.contract import receipt_errors
from riscv_release_oracle_lib.witness import (
    compare_ordered_accesses,
    compare_per_family_witness_rows,
    load_trace_vectors,
)
from riscv_release_oracle_lib.relations import compare_relation_boundaries
from riscv_release_oracle_lib.public_values import (
    IMPLEMENTATION_REPOSITORY,
    PINNED_ORACLE,
    PUBLIC_DATA_FIELDS,
    PUBLIC_VALUES_DERIVATION,
    PUBLIC_VALUES_SCHEMA,
    parse_proof_artifact_public_data,
    parse_public_values_diagnostic,
    strict_object as _strict_object,
    validate_public_data_shape as _validate_public_data_shape,
)
from riscv_trace_vectors_lib import admission as trace_admission

ROOT = Path(__file__).resolve().parent.parent
PINNED = PINNED_ORACLE
MAX_RECEIPT_BYTES = 64 * 1024 * 1024
UNSUPPORTED_PROOF_FAMILY_STDERR = (
    "stark-v adapter: error=UnsupportedProofFamily "
    "stage=statement_validation_before_first_commitment "
    "limitation=stark-v-signed-mulh\n"
)

# The trace-dump adapter is a thin serializer over the oracle's own runner
# crate (a duplicated standalone model is not acceptable per CP-11; a
# recorded overlay that only formats RunResult is). Its exact content is
# hashed into the receipt.
ADAPTER_REL = "crates/prover/src/bin/cp11_dump.rs"
ADAPTER_SOURCE_PATH = ROOT / "scripts" / "riscv_release_oracle_lib" / "cp11_dump.rs"
ADAPTER_SUMS_REL = "crates/prover/src/bin/cp11_dump/relation_sums.rs"
ADAPTER_SUMS_SOURCE_PATH = (
    ROOT / "scripts" / "riscv_release_oracle_lib" / "cp11_dump" / "relation_sums.rs"
)
ADAPTER_TUPLES_REL = "crates/prover/src/bin/cp11_dump/relation_tuples.rs"
ADAPTER_TUPLES_SOURCE_PATH = (
    ROOT / "scripts" / "riscv_release_oracle_lib" / "cp11_dump" / "relation_tuples.rs"
)
ADAPTER_LIMITATION_REL = "crates/prover/src/bin/cp11_dump/relation_limitation.rs"
ADAPTER_LIMITATION_SOURCE_PATH = (
    ROOT / "scripts" / "riscv_release_oracle_lib" / "cp11_dump" / "relation_limitation.rs"
)
ADAPTER_OVERLAYS = (
    (ADAPTER_REL, ADAPTER_SOURCE_PATH),
    (ADAPTER_SUMS_REL, ADAPTER_SUMS_SOURCE_PATH),
    (ADAPTER_TUPLES_REL, ADAPTER_TUPLES_SOURCE_PATH),
    (ADAPTER_LIMITATION_REL, ADAPTER_LIMITATION_SOURCE_PATH),
)
PROVER_MANIFEST_REL = "crates/prover/Cargo.toml"
SHA2_DEPENDENCY = 'sha2 = { version = "0.10", default-features = false }'

BOUNDARIES = [
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
]

def _run(cmd: list[str], cwd: Path | None = None) -> str:
    return subprocess.run(cmd, cwd=cwd, check=True, capture_output=True, text=True).stdout


def _sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _tree_digest(source: Path) -> str:
    out = _run(["git", "ls-files", "-s"], cwd=source)
    return hashlib.sha256(out.encode()).hexdigest()


def _canonical_digest(value: object) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def _promote_locked_sha2_dependency(original: bytes) -> tuple[bytes, dict[str, str]]:
    """Temporarily expose the pinned manifest's already-locked SHA-256 crate.

    The CP-11 serializer needs SHA-256 but must not modify the pinned lockfile or
    permanently mutate the oracle checkout. Fail closed if the pinned manifest
    no longer has the exact dependency/section shape reviewed here.
    """
    try:
        text = original.decode("utf-8")
    except UnicodeDecodeError as error:
        raise SystemExit("pinned prover manifest is not UTF-8") from error
    lines = text.splitlines(keepends=True)
    logical = [line.rstrip("\r\n") for line in lines]
    if logical.count("[dependencies]") != 1 or logical.count("[dev-dependencies]") != 1:
        raise SystemExit("pinned prover manifest has unexpected dependency sections")
    if logical.count(SHA2_DEPENDENCY) != 1:
        raise SystemExit("pinned prover manifest has unexpected sha2 dependency shape")
    dependencies_index = logical.index("[dependencies]")
    dev_dependencies_index = logical.index("[dev-dependencies]")
    sha2_index = logical.index(SHA2_DEPENDENCY)
    next_section_index = next(
        (
            index
            for index in range(dev_dependencies_index + 1, len(logical))
            if logical[index].startswith("[") and logical[index].endswith("]")
        ),
        len(logical),
    )
    if not dependencies_index < dev_dependencies_index < sha2_index < next_section_index:
        raise SystemExit("pinned sha2 dependency is not in [dev-dependencies]")

    sha2_line = lines.pop(sha2_index)
    lines.insert(dependencies_index + 1, sha2_line)
    transformed = "".join(lines).encode("utf-8")
    before_sha256 = hashlib.sha256(original).hexdigest()
    after_sha256 = hashlib.sha256(transformed).hexdigest()
    patch_record = {
        "operation": "promote_locked_dev_dependency",
        "path": PROVER_MANIFEST_REL,
        "dependency": SHA2_DEPENDENCY,
        "before_sha256": before_sha256,
        "after_sha256": after_sha256,
    }
    return transformed, {
        **patch_record,
        "sha256": after_sha256,
        "patch_sha256": _canonical_digest(patch_record),
    }


@contextlib.contextmanager
def _temporary_sha2_dependency(source: Path):
    manifest = source / PROVER_MANIFEST_REL
    original = manifest.read_bytes()
    transformed, evidence = _promote_locked_sha2_dependency(original)
    try:
        manifest.write_bytes(transformed)
        yield evidence
    finally:
        manifest.write_bytes(original)


def require_clean_candidate(root: Path, candidate: str) -> None:
    """Bind standalone CP-11 production to the clean candidate it names."""
    head = _run(["git", "rev-parse", "--verify", "HEAD"], cwd=root).strip()
    if candidate != head:
        raise SystemExit(f"candidate {candidate} does not match HEAD {head}")
    dirty = _run(
        ["git", "status", "--porcelain=v1", "--untracked-files=all"],
        cwd=root,
    ).strip()
    if dirty:
        raise SystemExit("Zig candidate checkout is not clean; refusing CP-11 evidence")


def load_receipt(path: Path) -> dict[str, object]:
    if path.stat().st_size > MAX_RECEIPT_BYTES:
        raise ValueError(f"receipt exceeds {MAX_RECEIPT_BYTES} bytes")
    payload = json.loads(
        path.read_text(encoding="utf-8"),
        object_pairs_hook=_strict_object,
    )
    if not isinstance(payload, dict):
        raise ValueError("receipt root must be an object")
    return payload


def record_implementation_executable(
    receipt: dict,
    name: str,
    executable: Path,
    oracle_executable: Path,
) -> None:
    resolved = executable.resolve(strict=True)
    oracle_resolved = oracle_executable.resolve(strict=True)
    digest = _sha256_file(resolved)
    if resolved == oracle_resolved or digest == _sha256_file(oracle_resolved):
        raise SystemExit(f"{name} resolves to the Rust oracle executable; refusing self-comparison")
    implementation = receipt.setdefault(
        "implementation",
        {
            "repository": IMPLEMENTATION_REPOSITORY,
            "commit": receipt["candidate_commit"],
            "clean": True,
            "executables": {},
        },
    )
    previous = implementation["executables"].setdefault(name, digest)
    if previous != digest:
        raise SystemExit(f"{name} executable changed during one CP-11 run")


def finalize_case_result_digests(receipt: dict) -> None:
    vectors = load_trace_vectors(ROOT, PINNED, receipt)
    names = [vector["name"] for vector in vectors["vectors"]]
    generated = {"decode", "poseidon2_vectors"}
    expected = []
    digests = {}
    for boundary_name in BOUNDARIES:
        boundary = receipt["boundaries"][boundary_name]
        aggregate_key = f"{boundary_name}/aggregate"
        expected.append(aggregate_key)
        digests[aggregate_key] = _canonical_digest(boundary)
        if boundary_name in generated:
            case_key = f"{boundary_name}/corpus"
            expected.append(case_key)
            digests[case_key] = _canonical_digest(boundary)
            continue
        expected.extend(f"{boundary_name}/{name}" for name in names)
        cases = boundary.get("corpus")
        if not isinstance(cases, list):
            continue
        for case in cases:
            name = case.get("name") if isinstance(case, dict) else None
            if name in names:
                digests[f"{boundary_name}/{name}"] = _canonical_digest(case)
    receipt["expected_case_result_keys"] = sorted(set(expected))
    receipt["case_result_digests"] = dict(sorted(digests.items()))


def build_oracle(source: Path, receipt: dict) -> Path:
    head = _run(["git", "rev-parse", "HEAD"], cwd=source).strip()
    if head != PINNED:
        raise SystemExit(f"oracle checkout at {head}, pinned {PINNED}")
    dirty = subprocess.run(
        ["git", "status", "--porcelain"], cwd=source, check=True, capture_output=True, text=True
    ).stdout.strip()
    if dirty:
        raise SystemExit("oracle checkout is not clean; refusing to build")
    submodule = _run(["git", "submodule", "status", "--recursive"], cwd=source)
    invalid_submodules = [
        line for line in submodule.splitlines()
        if line and line[0] != " "
    ]
    if invalid_submodules:
        raise SystemExit(
            "oracle submodules are not initialized at the recorded commits: "
            + "; ".join(invalid_submodules)
        )
    tree_digest = _tree_digest(source)
    with _temporary_sha2_dependency(source) as manifest_evidence:
        overlay_files = [manifest_evidence]
        overlay_paths = []
        try:
            for relative_path, source_path in ADAPTER_OVERLAYS:
                payload = source_path.read_bytes()
                destination = source / relative_path
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(payload)
                overlay_paths.append(destination)
                overlay_files.append(
                    {
                        "path": relative_path,
                        "sha256": hashlib.sha256(payload).hexdigest(),
                    }
                )
            toolchain = _run(["rustc", "--version"], cwd=source).strip()
            build_cmd = ["cargo", "build", "--locked", "--release", "-p", "prover"]
            _run(build_cmd, cwd=source)
            exe = source / "target" / "release" / "cp11_dump"
            receipt["oracle"] = {
                "repository": "https://github.com/ClementWalter/stark-v",
                "commit": head,
                "clean": True,
                "tree_digest_sha256": tree_digest,
                "submodule_status": submodule.strip().splitlines(),
                "lockfile_sha256": _sha256_file(source / "Cargo.lock"),
                "toolchain": toolchain,
                "build_command": " ".join(build_cmd),
                "build_mode": "release",
                "adapter_overlay": {
                    "path": ADAPTER_REL,
                    "sha256": _canonical_digest(overlay_files),
                    "files": overlay_files,
                    "note": "aggregate identity of thin serializers over the oracle's "
                    "own production APIs and a recorded, temporary manifest transform; "
                    "applied after tree digest, removed after build",
                },
                "executable_sha256": _sha256_file(exe),
                "host_arch": platform.machine(),
                "host_os": f"{platform.system()} {platform.release()}",
            }
            return exe
        finally:
            for overlay_path in reversed(overlay_paths):
                overlay_path.unlink(missing_ok=True)
            try:
                (source / ADAPTER_REL).parent.rmdir()
            except OSError:
                pass


def compare_execution(oracle_exe: Path, receipt: dict) -> None:
    """Executor-corpus boundary: the committed trace-vector ELFs through both
    implementations, over the equivalence contract fields."""
    subprocess.run(
        ["zig", "build", "riscv-trace-dump", "-Doptimize=ReleaseFast"], cwd=ROOT, check=True
    )
    zig_exe = ROOT / "zig-out" / "bin" / "riscv-trace-dump"
    record_implementation_executable(receipt, "riscv-trace-dump", zig_exe, oracle_exe)
    vectors = load_trace_vectors(ROOT, PINNED, receipt)
    cases = []
    all_ok = True
    for vector in vectors["vectors"]:
        elf = ROOT / vector["elf"]
        rust = json.loads(_run([str(oracle_exe), "--elf", str(elf)]))["trace"]
        zig = json.loads(_run([str(zig_exe), "--elf", str(elf)], cwd=ROOT))
        ok = all(rust[k] == zig[k] for k in ("total_steps", "final_pc", "final_regs"))
        all_ok = all_ok and ok
        cases.append(
            {
                "name": vector["name"],
                "elf_sha256": vector["elf_sha256"],
                "agree": ok,
                "total_steps": zig["total_steps"],
                "final_pc": zig["final_pc"],
            }
        )
    receipt["boundaries"]["execution"] = {
        "status": "pass" if all_ok else "fail",
        "fields": ["total_steps", "final_pc", "final_regs"],
        "corpus": cases,
    }
    # Decode agreement is implied per-corpus by execution agreement only for
    # executed paths; the exhaustive decode matrix remains its own boundary.


def compare_public_values(oracle_exe: Path, receipt: dict) -> None:
    """Compare Rust public data to the exact production or diagnostic boundary.

    Supported vectors must publish a real proof artifact and are compared from
    the public statement it binds. Explicit family-wide limitations instead
    use the proof-independent tree-builder diagnostic, while the same installed
    CLI must reject proving before commitment and publish no outputs.
    """
    subprocess.run(
        ["zig", "build", "stwo-zig", "-Doptimize=ReleaseFast"],
        cwd=ROOT,
        check=True,
    )
    cli = ROOT / "zig-out" / "bin" / "stwo-zig"
    trace_dump = ROOT / "zig-out" / "bin" / "riscv-trace-dump"
    record_implementation_executable(receipt, "stwo-zig", cli, oracle_exe)
    vectors = load_trace_vectors(ROOT, PINNED, receipt)
    expected_admission = trace_admission.for_programs(
        vector["name"] for vector in vectors["vectors"]
    )
    admission_errors = trace_admission.errors(vectors["vectors"], expected_admission)
    if admission_errors:
        raise SystemExit("invalid proof-admission policy: " + "; ".join(admission_errors))
    cases = []
    all_ok = True
    witness_digest = receipt.get("witness_layout_digest_sha256")
    if not isinstance(witness_digest, str):
        raise SystemExit("public-values comparison has no live witness-layout digest")
    for vector in vectors["vectors"]:
        elf = ROOT / vector["elf"]
        rust_payload = json.loads(
            _run([str(oracle_exe), "--elf", str(elf)]),
            object_pairs_hook=_strict_object,
        )
        rust = _validate_public_data_shape(rust_payload["public_data"], "Rust public_data")
        input_bytes = b"".join(
            word.to_bytes(4, "little") for word in rust["io_entries"]["input_words"]
        )[:rust["io_entries"]["input_len"]]
        input_digest = hashlib.sha256(input_bytes).hexdigest()
        admission = vector["proof_admission"]
        status = admission["status"]
        boundary_error = None
        rejection = None
        with tempfile.TemporaryDirectory() as directory:
            proof_path = Path(directory) / "proof.json"
            report_path = Path(directory) / "report.json"
            if status == trace_admission.SUPPORTED:
                try:
                    _run(
                        [
                            str(cli),
                            "prove",
                            "--elf",
                            str(elf),
                            "--backend",
                            "cpu",
                            "--protocol",
                            "functional",
                            "--experimental",
                            "--output",
                            str(proof_path),
                        ],
                        cwd=ROOT,
                    )
                    zig = parse_proof_artifact_public_data(
                        proof_path.read_text(encoding="utf-8"),
                        candidate=receipt["candidate_commit"],
                        witness_layout_sha256=witness_digest,
                        elf_sha256=vector["elf_sha256"],
                        input_sha256=input_digest,
                    )
                    mismatches = [
                        field for field in PUBLIC_DATA_FIELDS if rust[field] != zig[field]
                    ]
                except (
                    KeyError,
                    OSError,
                    TypeError,
                    ValueError,
                    json.JSONDecodeError,
                    subprocess.SubprocessError,
                ) as error:
                    mismatches = ["proof_artifact_contract"]
                    boundary_error = str(error)
                mode = "production_proof_artifact"
            else:
                try:
                    diagnostic_raw = _run(
                        [str(trace_dump), "--public-values", str(elf)],
                        cwd=ROOT,
                    )
                    zig = parse_public_values_diagnostic(
                        diagnostic_raw,
                        candidate=receipt["candidate_commit"],
                        witness_layout_sha256=witness_digest,
                        elf_sha256=vector["elf_sha256"],
                        input_sha256=input_digest,
                    )
                    mismatches = [
                        field for field in PUBLIC_DATA_FIELDS if rust[field] != zig[field]
                    ]
                except (
                    KeyError,
                    OSError,
                    TypeError,
                    ValueError,
                    json.JSONDecodeError,
                    subprocess.SubprocessError,
                ) as error:
                    mismatches = ["diagnostic_contract"]
                    boundary_error = str(error)
                process = subprocess.run(
                    [
                        str(cli),
                        "prove",
                        "--elf",
                        str(elf),
                        "--backend",
                        "cpu",
                        "--protocol",
                        "functional",
                        "--experimental",
                        "--output",
                        str(proof_path),
                        "--report-out",
                        str(report_path),
                    ],
                    cwd=ROOT,
                    capture_output=True,
                    text=True,
                )
                temporary_residue = sorted(
                    path.name for path in Path(directory).iterdir()
                    if path != proof_path and path != report_path
                )
                rejection_ok = (
                    process.returncode == 1
                    and process.stdout == ""
                    and process.stderr == UNSUPPORTED_PROOF_FAMILY_STDERR
                    and not proof_path.exists()
                    and not report_path.exists()
                    and not temporary_residue
                )
                if not rejection_ok:
                    mismatches.append("typed_precommit_rejection")
                rejection = {
                    "error": "UnsupportedProofFamily",
                    "stage": "statement_validation_before_first_commitment",
                    "returncode": process.returncode,
                    "stdout_empty": process.stdout == "",
                    "stderr_exact": process.stderr == UNSUPPORTED_PROOF_FAMILY_STDERR,
                    "proof_artifact_published": proof_path.exists(),
                    "report_published": report_path.exists(),
                    "temporary_residue": temporary_residue,
                }
                mode = "tree_builder_diagnostic_and_production_rejection"
        ok = not mismatches
        all_ok = all_ok and ok
        case = {
            "name": vector["name"],
            "elf_sha256": vector["elf_sha256"],
            "input_sha256": input_digest,
            "proof_admission": admission,
            "mode": mode,
            "agree": ok,
            "mismatches": mismatches,
        }
        if rejection is not None:
            case["production_rejection"] = rejection
        if boundary_error is not None:
            case["boundary_error"] = boundary_error
        cases.append(case)
    receipt["boundaries"]["public_values"] = {
        "status": "pass" if all_ok else "fail",
        "comparison": "supported=Rust PublicData::new versus production proof artifact; "
        "fail-closed=Rust PublicData::new versus tree-builder diagnostic plus typed "
        "precommit production rejection",
        "diagnostic_schema": PUBLIC_VALUES_SCHEMA,
        "fields": list(PUBLIC_DATA_FIELDS),
        "corpus": cases,
    }


DECODE_WORDS_NOTE = "systematic opcode/funct/register/immediate sweep, deterministic"


def decode_corpus() -> bytes:
    """Deterministic instruction-word corpus covering every opcode template,
    funct combination, register pattern, and immediate edge."""
    words = []
    regs = [0, 1, 5, 31]
    funct7s = [0x00, 0x20, 0x01, 0x7F, 0x40]
    imm_patterns = [0x000, 0x001, 0x7FF, 0x800, 0xFFF, 0x555, 0xAAA]
    for opcode7 in range(0, 128, 1):
        for funct3 in range(8):
            for funct7 in funct7s:
                base = opcode7 | (funct3 << 12) | (funct7 << 25)
                for rd in regs[:2]:
                    for rs1 in regs[:2]:
                        words.append(base | (rd << 7) | (rs1 << 15) | (regs[3] << 20))
    for opcode7 in (0x13, 0x03, 0x23, 0x63, 0x67, 0x6F, 0x37, 0x17):
        for funct3 in range(8):
            for imm in imm_patterns:
                words.append(opcode7 | (funct3 << 12) | (5 << 7) | (1 << 15) | (imm << 20))
    for word in (0x00000073, 0x00100073, 0x0000000F, 0x00000000, 0xFFFFFFFF,
                 0x0000006F, 0xFFDFF06F, 0x800000B7, 0xFFFFF0B7):
        words.append(word)
    seed = 0x9E3779B9
    for _ in range(4096):
        seed = (seed * 1664525 + 1013904223) & 0xFFFFFFFF
        words.append(seed)
    import struct as _struct
    return b"".join(_struct.pack("<I", w) for w in words)


def compare_decode(oracle_exe: Path, receipt: dict) -> None:
    """Exhaustive-template decode matrix: both decoders over one corpus,
    canonical line format, byte-compared."""
    import tempfile

    zig_exe = ROOT / "zig-out" / "bin" / "riscv-trace-dump"
    with tempfile.TemporaryDirectory() as tmp:
        corpus = Path(tmp) / "words.bin"
        payload = decode_corpus()
        corpus.write_bytes(payload)
        rust_out = _run([str(oracle_exe), "--decode-file", str(corpus)])
        zig_out = _run([str(zig_exe), "--decode-file", str(corpus)], cwd=ROOT)
    if rust_out == zig_out:
        receipt["boundaries"]["decode"] = {
            "status": "pass",
            "corpus_words": len(payload) // 4,
            "corpus_sha256": hashlib.sha256(payload).hexdigest(),
            "note": DECODE_WORDS_NOTE,
        }
        return
    diffs = []
    for rust_line, zig_line in zip(rust_out.splitlines(), zig_out.splitlines()):
        if rust_line != zig_line:
            diffs.append({"rust": rust_line, "zig": zig_line})
            if len(diffs) >= 20:
                break
    receipt["boundaries"]["decode"] = {
        "status": "fail",
        "corpus_words": len(payload) // 4,
        "first_disagreements": diffs,
    }


def compare_program_tuples(oracle_exe: Path, receipt: dict) -> None:
    """Program-tuple boundary, root-mediated: the oracle keeps decode_program
    crate-private, but its program root IS the Poseidon2 sparse-tree hash of
    exactly the decoded tuple leaves. Root equality on a content-bearing
    region (checked in public_values against the live oracle) is therefore a
    collision-resistance-mediated comparison of the tuple multiset. This
    boundary passes only when (a) public_values passed, and (b) at least one
    corpus region is non-empty, and it records the Zig tuple rows for audit."""
    zig_exe = ROOT / "zig-out" / "bin" / "riscv-trace-dump"
    vectors = json.loads((ROOT / "vectors" / "riscv_elfs" / "trace_vectors.json").read_text())
    public_ok = receipt["boundaries"].get("public_values", {}).get("status") == "pass"
    cases = []
    nonempty = 0
    for vector in vectors["vectors"]:
        elf = ROOT / vector["elf"]
        rows = _run([str(zig_exe), "--program-tuples", str(elf)], cwd=ROOT).splitlines()
        nonempty += 1 if rows else 0
        cases.append({"name": vector["name"], "rows": len(rows),
                      "rows_sha256": hashlib.sha256("\n".join(rows).encode()).hexdigest()})
    status = "pass" if (public_ok and nonempty > 0) else "fail"
    receipt["boundaries"]["program_tuples"] = {
        "status": status,
        "method": "root-mediated (Poseidon2 sparse tree over decoded tuple "
        "leaves; oracle root compared live in public_values)",
        "nonempty_regions": nonempty,
        "corpus": cases,
    }


def compare_memory_roots(oracle_exe: Path, receipt: dict) -> None:
    """Memory-roots boundary, root-mediated like program_tuples: the initial
    and final RW sparse-tree roots are compared LIVE against the oracle inside
    public_values; this boundary passes only when that comparison passed AND
    the oracle reports content-bearing (non-null, distinct) roots for at
    least one vector with stores — proving the trees hash real RW content."""
    vectors = json.loads((ROOT / "vectors" / "riscv_elfs" / "trace_vectors.json").read_text())
    public_ok = receipt["boundaries"].get("public_values", {}).get("status") == "pass"
    content_bearing = 0
    cases = []
    for vector in vectors["vectors"]:
        elf = ROOT / vector["elf"]
        rust = json.loads(_run([str(oracle_exe), "--elf", str(elf)]))["public_data"]
        initial = rust["initial_rw_root"]
        final = rust["final_rw_root"]
        bearing = initial is not None and final is not None and initial != final
        content_bearing += 1 if bearing else 0
        cases.append({"name": vector["name"], "initial_rw_root": initial,
                      "final_rw_root": final, "content_bearing": bearing})
    status = "pass" if (public_ok and content_bearing > 0) else "fail"
    receipt["boundaries"]["memory_roots"] = {
        "status": status,
        "method": "root-mediated (RW sparse trees compared live in "
        "public_values; content-bearing distinct roots required)",
        "content_bearing_vectors": content_bearing,
        "corpus": cases,
    }


def poseidon2_corpus() -> bytes:
    """Deterministic 16-word states: structured edges plus an LCG sweep."""
    import struct as _struct
    states = []
    states.append([0] * 16)
    states.append([1] * 16)
    states.append([0x7FFFFFFE] * 16)
    states.append(list(range(16)))
    seed = 0x243F6A88
    for _ in range(512):
        state = []
        for _ in range(16):
            seed = (seed * 1664525 + 1013904223) & 0x7FFFFFFF
            state.append(seed)
        states.append(state)
    return b"".join(_struct.pack("<16I", *state) for state in states)


def compare_poseidon2(oracle_exe: Path, receipt: dict) -> None:
    """Direct Poseidon2 permutation parity over a deterministic state corpus,
    byte-compared, plus the depth-30 default-hash chain constants."""
    import tempfile

    zig_exe = ROOT / "zig-out" / "bin" / "riscv-trace-dump"
    with tempfile.TemporaryDirectory() as tmp:
        corpus = Path(tmp) / "states.bin"
        payload = poseidon2_corpus()
        corpus.write_bytes(payload)
        rust_out = _run([str(oracle_exe), "--poseidon2-file", str(corpus)])
        zig_out = _run([str(zig_exe), "--poseidon2-file", str(corpus)], cwd=ROOT)
    if rust_out == zig_out:
        receipt["boundaries"]["poseidon2_vectors"] = {
            "status": "pass",
            "states": len(payload) // 64,
            "corpus_sha256": hashlib.sha256(payload).hexdigest(),
        }
        return
    diffs = []
    for rust_line, zig_line in zip(rust_out.splitlines(), zig_out.splitlines()):
        if rust_line != zig_line:
            diffs.append({"rust": rust_line[:96], "zig": zig_line[:96]})
            if len(diffs) >= 5:
                break
    receipt["boundaries"]["poseidon2_vectors"] = {"status": "fail", "first_disagreements": diffs}


def compare_shared_transcript_prefix(oracle_exe: Path, receipt: dict) -> None:
    """Shared-transcript-prefix boundary: everything both provers mix into the
    Fiat-Shamir channel before the first commitment root. The pinned oracle's
    prove_rv32im defaults to Blake2sMerkleChannel and mixes PublicData into a
    default Blake2sChannel (prover.rs step 4); the Zig prover seeds the same
    Blake2s channel with statement.public_data.mixInto in the mirrored field
    order. Both sides print the channel digest after every mix step and the
    transcripts are byte-compared per corpus ELF — the channels are
    structurally compatible, so digest equality is required, fail-closed."""
    zig_exe = ROOT / "zig-out" / "bin" / "riscv-trace-dump"
    vectors = json.loads((ROOT / "vectors" / "riscv_elfs" / "trace_vectors.json").read_text())
    cases = []
    all_ok = True
    for vector in vectors["vectors"]:
        elf = ROOT / vector["elf"]
        rust_out = _run([str(oracle_exe), "--transcript-prefix", "--elf", str(elf)])
        zig_out = _run([str(zig_exe), "--transcript-prefix", str(elf)], cwd=ROOT)
        ok = rust_out == zig_out
        all_ok = all_ok and ok
        zig_lines = zig_out.splitlines()
        case = {
            "name": vector["name"],
            "agree": ok,
            "mix_steps": max(len(zig_lines) - 1, 0),
            "prefix_digest": zig_lines[-1].rsplit("digest=", 1)[-1] if ok and zig_lines else None,
        }
        if not ok:
            diffs = []
            for rust_line, zig_line in zip(rust_out.splitlines(), zig_lines):
                if rust_line != zig_line:
                    diffs.append({"rust": rust_line, "zig": zig_line})
                    if len(diffs) >= 5:
                        break
            if not diffs:
                diffs.append({
                    "rust": f"{len(rust_out.splitlines())} transcript lines",
                    "zig": f"{len(zig_lines)} transcript lines",
                })
            case["first_disagreements"] = diffs
        cases.append(case)
    receipt["boundaries"]["shared_transcript_prefix"] = {
        "status": "pass" if all_ok else "fail",
        "channel": "blake2s on both sides (pinned prove_rv32im defaults to "
        "Blake2sMerkleChannel -> Blake2sChannel; Zig prover uses the ported "
        "stwo Blake2sChannel with upstream digest vectors)",
        "prefix": "default channel state + PublicData mix_u32s sequence — "
        "the full pre-commitment transcript; digest recorded after each step",
        "corpus": cases,
    }


def build_and_compare(args) -> int:
    require_clean_candidate(ROOT, args.candidate)
    source = Path(args.stark_v_source).resolve()
    receipt: dict = {
        "schema": "riscv-oracle-receipt-v2",
        "candidate_commit": args.candidate,
        "created_at_unix": int(time.time()),
        "case_result_digests": {},
        "boundaries": {name: {"status": "unimplemented"} for name in BOUNDARIES},
    }
    oracle_exe = build_oracle(source, receipt)
    compare_execution(oracle_exe, receipt)
    compare_per_family_witness_rows(oracle_exe, receipt, ROOT, PINNED)
    compare_ordered_accesses(oracle_exe, receipt, ROOT, PINNED)
    compare_public_values(oracle_exe, receipt)
    compare_decode(oracle_exe, receipt)
    compare_program_tuples(oracle_exe, receipt)
    compare_memory_roots(oracle_exe, receipt)
    compare_poseidon2(oracle_exe, receipt)
    compare_relation_boundaries(oracle_exe, receipt, ROOT, PINNED)
    compare_shared_transcript_prefix(oracle_exe, receipt)
    finalize_case_result_digests(receipt)
    require_clean_candidate(ROOT, args.candidate)
    receipt["verdict"] = "PASS"
    vectors = load_trace_vectors(ROOT, PINNED, receipt)
    contract_errors = receipt_errors(
        receipt,
        args.candidate,
        now=receipt["created_at_unix"],
        vector_names=tuple(vector["name"] for vector in vectors["vectors"]),
    )
    if contract_errors:
        receipt["verdict"] = "FAIL"
        receipt["contract_errors"] = contract_errors
    out = Path(args.receipt_out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(receipt, indent=1) + "\n")
    print(f"receipt written: {out} (verdict {receipt['verdict']})")
    for name, boundary in receipt["boundaries"].items():
        print(f"  {name}: {boundary['status']}")
    return 0 if receipt["verdict"] == "PASS" else 1


def validate(args) -> int:
    try:
        head = _run(["git", "rev-parse", "--verify", "HEAD"], cwd=ROOT).strip()
        require_clean_candidate(ROOT, head)
        receipt = load_receipt(Path(args.receipt))
        errors = receipt_errors(receipt, head)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print(f"oracle receipt: invalid evidence: {error}", file=sys.stderr)
        return 1
    for error in errors:
        print(f"oracle receipt: {error}", file=sys.stderr)
    if not errors:
        print("oracle receipt: all boundaries pass at the pinned revision")
    return 1 if errors else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="mode", required=True)
    p = sub.add_parser("build-and-compare")
    p.add_argument("--stark-v-source", required=True)
    p.add_argument("--candidate", required=True)
    p.add_argument("--receipt-out", required=True)
    p = sub.add_parser("validate")
    p.add_argument("--receipt", required=True)
    args = parser.parse_args(argv)
    return build_and_compare(args) if args.mode == "build-and-compare" else validate(args)


if __name__ == "__main__":
    raise SystemExit(main())
