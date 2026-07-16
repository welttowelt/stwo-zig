#!/usr/bin/env python3
"""Run direct SN PIE Metal gates without presenting partial stages as proving speed."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import signal
import struct
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_ARTIFACTS = (
    ROOT / "vectors/cairo/sn_pie_2_witness_programs.bin",
    ROOT / "vectors/cairo/sn_pie_2_multiplicity_feeds.bin",
    ROOT / "vectors/cairo/cairo_relation_templates.bin",
    ROOT / "vectors/cairo/cairo_fixed_tables.bin",
    ROOT / "vectors/cairo/sn_pie_2_composition.bin",
)
MAGIC = b"STWZCPI\0"
PROVE_TIMING_SCOPE = "recorded_witness_start_to_verified_proof"
TREE0_MERKLE_SUFFIX = ".tree0-merkle"
CANONICAL_PROOF_PROTOCOL: dict[str, object] = {
    "channel": "blake2s",
    "channel_salt": 0,
    "log_blowup_factor": 1,
    "n_queries": 70,
    "interaction_pow_bits": 24,
    "query_pow_bits": 26,
    "fri_fold_step": 3,
    "fri_lifting": None,
    "fri_log_last_layer_degree_bound": 0,
}

ROOT_MODES = ("base-root", "interaction-root", "composition-root", "full-proof")

UNATTESTED_GENERATOR = {
    "executable_sha256": None,
    "semantic_version": None,
    "compiler_identity": None,
    "arguments": [],
}

ARTIFACT_FORMATS = {
    "adapted_input": "STWZCPI/1",
    "schedule": "metal-arena-schedule/json-unattested",
    "witness_programs": "STWZWIT/unattested",
    "multiplicity_feeds": "STWZFED/unattested",
    "relation_templates": "STWZREL/unattested",
    "fixed_tables": "STWZFIX/unattested",
    "composition": "STWZCOM/unattested",
    "composition_source": "metal-air-source/unattested",
    "preprocessed_evaluations": "metal-preprocessed-evaluations/unattested",
    "preprocessed_coefficients": "STWZPPC/unattested",
    "tree0_merkle": "metal-retained-merkle/unattested",
    "transcript_reference": "diagnostic-transcript-reference/unattested",
    "quotient_reference": "diagnostic-quotient-reference/unattested",
    "proof": "stwo-proof/unattested",
}


def tree0_merkle_companion(preprocessed_evaluations: Path) -> Path:
    """Match the retained tree-0 cache path derived by the Zig runner."""
    return Path(f"{preprocessed_evaluations}{TREE0_MERKLE_SUFFIX}")


def adapted_counts(path: Path) -> tuple[int, int]:
    """Read cycle and PC counts without materializing the large adapted input."""
    with path.open("rb") as stream:
        header = stream.read(64)
        if len(header) != 64 or header[:8] != MAGIC:
            raise ValueError(f"{path} is not a STWZCPI input")
        version, flags = struct.unpack_from("<II", header, 8)
        del flags
        if version != 1:
            raise ValueError(f"unsupported STWZCPI version {version}")
        pc_count = struct.unpack_from("<Q", header, 40)[0]
        opcode_count = struct.unpack_from("<I", header, 56)[0]
        cycles = 0
        for _ in range(opcode_count):
            encoded = stream.read(8)
            if len(encoded) != 8:
                raise ValueError("truncated STWZCPI opcode table")
            count = struct.unpack("<Q", encoded)[0]
            cycles += count
            stream.seek(count * 12, os.SEEK_CUR)
        return cycles, pc_count


def measure_file(path: Path) -> tuple[str, int]:
    digest = hashlib.sha256()
    byte_count = 0
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            digest.update(chunk)
            byte_count += len(chunk)
    return digest.hexdigest(), byte_count


def sha256_file(path: Path) -> str:
    return measure_file(path)[0]


def artifact_entry(
    path: Path,
    *,
    kind: str,
    format_version: str,
    provenance: str,
    generator: dict[str, object] | None = None,
    source_digests: list[str] | None = None,
    source_chain_complete: bool = False,
    provenance_reason: str,
) -> dict[str, object]:
    digest, byte_count = measure_file(path)
    return {
        "kind": kind,
        "path": str(path.resolve()),
        "sha256": digest,
        "bytes": byte_count,
        "format_version": format_version,
        "generator": dict(generator or UNATTESTED_GENERATOR),
        "source_digests": list(source_digests or []),
        "source_chain_complete": source_chain_complete,
        "provenance": provenance,
        "provenance_reason": provenance_reason,
    }


def input_artifact_entries(
    args: argparse.Namespace,
    artifacts: tuple[Path, ...],
) -> dict[str, dict[str, object]]:
    entries = {
        "adapted_input": artifact_entry(
            args.input,
            kind="adapted_input",
            format_version=ARTIFACT_FORMATS["adapted_input"],
            provenance="proof_derived",
            provenance_reason=(
                "the one-shot benchmark receives adapted bytes without an authenticated raw-PIE, "
                "adapter, or bootloader source chain"
            ),
        ),
        "schedule": artifact_entry(
            args.schedule,
            kind="schedule",
            format_version=ARTIFACT_FORMATS["schedule"],
            provenance="proof_derived",
            provenance_reason="current SN PIE schedules are retargeted from target Rust proof data",
        ),
    }
    artifact_metadata = (
        ("witness_programs", "air_witness_programs"),
        ("multiplicity_feeds", "air_multiplicity_feeds"),
        ("relation_templates", "air_relation_templates"),
        ("fixed_tables", "air_fixed_tables"),
        ("composition", "air_composition"),
    )
    for (name, kind), path in zip(artifact_metadata, artifacts, strict=True):
        reason = "current composition is retargeted from target Rust proof data" if name == "composition" else (
            "canonical generator identity and transitive source chain are not authenticated by this benchmark"
        )
        entries[name] = artifact_entry(
            path,
            kind=kind,
            format_version=ARTIFACT_FORMATS[name],
            provenance="proof_derived",
            provenance_reason=reason,
        )

    for name, kind, path in (
        ("preprocessed_evaluations", "preprocessed_state", args.preprocessed_evaluations),
        ("preprocessed_coefficients", "preprocessed_state", args.preprocessed_coefficients),
    ):
        if path is not None and path.is_file():
            entries[name] = artifact_entry(
                path,
                kind=kind,
                format_version=ARTIFACT_FORMATS[name],
                provenance="proof_derived",
                provenance_reason=(
                    "canonical generator identity and transitive source chain are not authenticated by this benchmark"
                ),
            )
    if args.preprocessed_evaluations is not None:
        retained_tree = tree0_merkle_companion(args.preprocessed_evaluations)
        if retained_tree.is_file():
            entries["tree0_merkle"] = artifact_entry(
                retained_tree,
                kind="preprocessed_merkle_state",
                format_version=ARTIFACT_FORMATS["tree0_merkle"],
                provenance="proof_derived",
                provenance_reason=(
                    "canonical generator identity and transitive source chain are not authenticated by this benchmark"
                ),
            )
    for name, path in (
        ("transcript_reference", args.transcript_reference),
        ("quotient_reference", args.quotient_reference),
    ):
        if path is not None and path.is_file():
            entries[name] = artifact_entry(
                path,
                kind="parity_fixture",
                format_version=ARTIFACT_FORMATS[name],
                provenance="diagnostic_fixture",
                provenance_reason="optional Rust oracle comparison fixture",
            )
    return entries


def proof_artifact_entry(
    proof_output: Path,
    runner_sha256: str,
    command: list[str],
    source_entries: dict[str, dict[str, object]],
    cli_report: dict[str, object] | None,
) -> dict[str, object]:
    version = cli_report.get("runner_version") if cli_report is not None else None
    compiler = cli_report.get("compiler_identity") if cli_report is not None else None
    generator = {
        "executable_sha256": runner_sha256,
        "semantic_version": version if isinstance(version, str) else None,
        "compiler_identity": compiler if isinstance(compiler, str) else None,
        "arguments": command[1:],
    }
    return artifact_entry(
        proof_output,
        kind="proof",
        format_version=ARTIFACT_FORMATS["proof"],
        provenance="canonical_generated",
        generator=generator,
        source_digests=[str(entry["sha256"]) for entry in source_entries.values()],
        source_chain_complete=bool(source_entries) and all(
            entry.get("source_chain_complete") is True for entry in source_entries.values()
        ),
        provenance_reason="emitted by the content-identified runner during this invocation",
    )


def artifact_manifest(
    entries: dict[str, dict[str, object]],
    pre_run_hash_wall_s: float,
    post_run_hash_wall_s: float,
) -> dict[str, object]:
    canonical_entries = json.dumps(entries, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return {
        "schema_version": 1,
        "sha256": hashlib.sha256(canonical_entries).hexdigest(),
        "entries": entries,
        "hash_timing": {
            "scope": "outside_runner_process_and_recorded_prove_wall_s",
            "pre_run_wall_s": pre_run_hash_wall_s,
            "post_run_wall_s": post_run_hash_wall_s,
            "total_wall_s": pre_run_hash_wall_s + post_run_hash_wall_s,
            "runner_process_wall_s_excludes_hashing": True,
            "prove_wall_s_excludes_hashing": True,
        },
    }


def authoritative_provenance(
    mode: str,
    status: str,
    metrics: dict[str, object],
    cli_report: dict[str, object] | None,
    entries: dict[str, dict[str, object]],
    transcript_reference: Path | None,
    quotient_reference: Path | None,
) -> dict[str, object]:
    runner_parity = cli_report.get("parity_fixture_used") if cli_report is not None else None
    runner_proof_derived = cli_report.get("proof_derived_artifact_used") if cli_report is not None else None
    runner_self_contained = cli_report.get("self_contained") if cli_report is not None else None
    runner_statement_self_derived = (
        cli_report.get("statement_self_derived") if cli_report is not None else None
    )
    fixture_arguments_used = transcript_reference is not None or quotient_reference is not None
    parity_fixture_used = fixture_arguments_used or runner_parity is not False
    measured_proof_derived = any(
        entry.get("provenance") == "proof_derived" for entry in entries.values()
    )
    proof_derived_artifact_used = measured_proof_derived or runner_proof_derived is not False

    # This wrapper has no authenticated generator/source-chain trust root. Even a
    # verified proof therefore cannot be promoted to a self-contained production proof.
    self_contained = False
    return {
        "self_contained": self_contained,
        "parity_fixture_used": parity_fixture_used,
        "proof_derived_artifact_used": proof_derived_artifact_used,
        "provenance_evidence": {
            "mode": mode,
            "status": status,
            "proof_verified": metrics.get("proof_verified") is True,
            "runner_self_contained": runner_self_contained,
            "runner_statement_self_derived": runner_statement_self_derived,
            "runner_parity_fixture_used": runner_parity,
            "runner_proof_derived_artifact_used": runner_proof_derived,
            "fixture_arguments_used": fixture_arguments_used,
            "measured_proof_derived_artifact": measured_proof_derived,
            "authenticated_source_chain_available": False,
            "derivation": (
                "fail closed: caller assertions cannot establish self-containment; missing runner evidence "
                "conservatively means parity fixtures and proof-derived artifacts may have been used"
            ),
        },
    }


def pow_telemetry(cli_report: dict[str, object] | None) -> dict[str, object]:
    scope = cli_report.get("pow_timing_scope") if cli_report is not None else None
    result: dict[str, object] = {
        "scope": scope if isinstance(scope, str) else None,
        "complete": True,
    }
    for prefix, expected_bits in (("interaction", 24), ("query", 26)):
        values = {
            "nonce": cli_report.get(f"{prefix}_pow_nonce") if cli_report else None,
            "wall_s": cli_report.get(f"{prefix}_pow_wall_s") if cli_report else None,
            "mode": cli_report.get(f"{prefix}_pow_mode") if cli_report else None,
            "bits": cli_report.get(f"{prefix}_pow_bits") if cli_report else None,
            "invocations": (
                cli_report.get(f"{prefix}_pow_invocations") if cli_report else None
            ),
        }
        valid = (
            isinstance(values["nonce"], int)
            and not isinstance(values["nonce"], bool)
            and values["nonce"] >= 0
            and isinstance(values["wall_s"], (int, float))
            and not isinstance(values["wall_s"], bool)
            and math.isfinite(float(values["wall_s"]))
            and values["wall_s"] >= 0
            and values["mode"] in {"self_ground", "fixture_forced"}
            and values["bits"] == expected_bits
            and isinstance(values["invocations"], int)
            and not isinstance(values["invocations"], bool)
            and values["invocations"] == 1
        )
        result[prefix] = values
        result["complete"] = result["complete"] and valid
    result["complete"] = (
        result["complete"]
        and result["scope"] == "cpu_nonce_search_or_fixture_validation_only"
    )
    return result


def canonical_protocol_evidence(
    cli_report: dict[str, object] | None,
) -> tuple[dict[str, object] | None, bool]:
    if cli_report is None or cli_report.get("protocol_complete") is not True:
        return None, False
    value = cli_report.get("protocol")
    if not isinstance(value, dict) or set(value) != set(CANONICAL_PROOF_PROTOCOL):
        return None, False
    for name, expected in CANONICAL_PROOF_PROTOCOL.items():
        actual = value[name]
        if isinstance(expected, int):
            valid = isinstance(actual, int) and not isinstance(actual, bool) and actual == expected
        elif expected is None:
            valid = actual is None
        else:
            valid = type(actual) is type(expected) and actual == expected
        if not valid:
            return None, False
    return dict(value), True


def protocol_gate(
    status: str,
    cli_report: dict[str, object] | None,
) -> tuple[str, dict[str, object] | None, bool]:
    protocol_parameters, protocol_complete = canonical_protocol_evidence(cli_report)
    if status == "completed" and not protocol_complete:
        status = "invalid_protocol"
    return status, protocol_parameters, protocol_complete


def hardware() -> dict[str, object]:
    result = subprocess.run(
        ["system_profiler", "SPHardwareDataType", "SPDisplaysDataType"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    ).stdout
    chip = re.search(r"^\s+Chip:\s+(.+)$", result, re.MULTILINE)
    memory = re.search(r"^\s+Memory:\s+(.+)$", result, re.MULTILINE)
    gpu = re.search(r"^\s+Total Number of Cores:\s+(\d+)$", result[result.find("Graphics/Displays:") :], re.MULTILINE)
    return {
        "chip": chip.group(1) if chip else None,
        "memory": memory.group(1) if memory else None,
        "gpu_cores": int(gpu.group(1)) if gpu else None,
    }


def benchmark_environment() -> dict[str, str]:
    """Keep unrelated shell diagnostics from changing the measured protocol path."""
    return {key: value for key, value in os.environ.items() if not key.startswith("STWO_ZIG_SN2_")}


def parse_time(stderr: str) -> dict[str, object]:
    values: dict[str, object] = {}
    for key, pattern, cast in (
        ("time_real_s", r"^real\s+([0-9.]+)$", float),
        ("time_user_s", r"^user\s+([0-9.]+)$", float),
        ("time_sys_s", r"^sys\s+([0-9.]+)$", float),
        ("max_rss_bytes", r"^\s*(\d+)\s+maximum resident set size$", int),
        ("peak_footprint_bytes", r"^\s*(\d+)\s+peak memory footprint$", int),
    ):
        match = re.search(pattern, stderr, re.MULTILINE)
        if match:
            values[key] = cast(match.group(1))
    return values


def write_text_atomic(path: Path, contents: str) -> None:
    temporary_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f".{path.name}.",
            delete=False,
        ) as temporary:
            temporary_name = temporary.name
            temporary.write(contents)
            temporary.flush()
            os.fsync(temporary.fileno())
        os.replace(temporary_name, path)
        temporary_name = None
    finally:
        if temporary_name is not None:
            Path(temporary_name).unlink(missing_ok=True)


def run_gate(command: list[str], env: dict[str, str], timeout: float) -> tuple[str, int | None, float, str, str]:
    started = time.perf_counter()
    process = subprocess.Popen(
        ["/usr/bin/time", "-lp", *command],
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=timeout)
        status = "completed" if process.returncode == 0 else "failed"
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            stdout, stderr = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            stdout, stderr = process.communicate()
        status = "timed_out"
    return status, process.returncode, time.perf_counter() - started, stdout, stderr


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description=__doc__)
    value.add_argument("--input", type=Path, required=True, help="Direct adapted SN PIE (.stwzcpi)")
    value.add_argument(
        "--mode",
        choices=("plan", "prepare", *ROOT_MODES),
        default="plan",
        help="full-proof fails closed unless the CLI emits a verified proof and proving wall time",
    )
    value.add_argument("--runner", type=Path, default=ROOT / "zig-out/bin/metal-arena-plan")
    value.add_argument("--schedule", type=Path, default=Path("/tmp/sn2-arena.json"))
    value.add_argument("--witness-programs", type=Path, default=DEFAULT_ARTIFACTS[0])
    value.add_argument("--multiplicity-feeds", type=Path, default=DEFAULT_ARTIFACTS[1])
    value.add_argument("--relation-templates", type=Path, default=DEFAULT_ARTIFACTS[2])
    value.add_argument("--fixed-tables", type=Path, default=DEFAULT_ARTIFACTS[3])
    value.add_argument("--composition", type=Path, default=DEFAULT_ARTIFACTS[4])
    value.add_argument("--budget-gib", default="29")
    value.add_argument("--timeout", type=float, default=600.0)
    value.add_argument("--preprocessed-evaluations", type=Path)
    value.add_argument("--preprocessed-coefficients", type=Path)
    value.add_argument("--tree0-root-hex")
    value.add_argument("--transcript-reference", type=Path)
    value.add_argument("--quotient-reference", type=Path)
    value.add_argument("--proof-output", type=Path)
    value.add_argument(
        "--diagnostic-base-eval-digests",
        action="store_true",
        help="emit per-column Metal base-evaluation digests in root/proof modes",
    )
    value.add_argument("--diagnostic-base-eval-dump-logical-id", type=int)
    value.add_argument("--diagnostic-base-eval-dump-output", type=Path)
    value.add_argument("--stderr-output", type=Path, help="atomically preserve full runner stderr")
    value.add_argument("--output", type=Path)
    return value


def protocol_artifacts(args: argparse.Namespace) -> tuple[Path, ...]:
    """Return the runner's five positional protocol artifacts in ABI order."""
    return (
        args.witness_programs,
        args.multiplicity_feeds,
        args.relation_templates,
        args.fixed_tables,
        args.composition,
    )


def runner_command(args: argparse.Namespace, artifacts: tuple[Path, ...]) -> list[str]:
    if len(artifacts) != 5:
        raise ValueError("runner requires exactly five protocol artifacts")
    return [
        str(args.runner.resolve()),
        str(args.schedule),
        args.budget_gib,
        *(str(path) for path in artifacts),
    ]


def apply_mode_environment(
    environment: dict[str, str],
    mode: str,
    preprocessed_evaluations: Path | None,
    preprocessed_coefficients: Path | None,
    tree0_root_hex: str | None,
    transcript_reference: Path | None,
    quotient_reference: Path | None,
    proof_output: Path | None,
) -> None:
    if mode == "plan":
        return
    environment["STWO_ZIG_SN2_PREPARE_METAL"] = "1"
    if mode not in ROOT_MODES:
        return
    if not preprocessed_evaluations or not preprocessed_evaluations.is_file():
        raise ValueError(f"{mode} requires --preprocessed-evaluations")
    retained_tree = tree0_merkle_companion(preprocessed_evaluations)
    if not retained_tree.is_file():
        raise ValueError(f"{mode} requires retained tree-0 cache: {retained_tree}")
    if not tree0_root_hex or not re.fullmatch(r"[0-9a-fA-F]{64}", tree0_root_hex):
        raise ValueError(f"{mode} requires a 64-digit --tree0-root-hex")
    environment.update({
        "STWO_ZIG_SN2_RESTORE_PREPROCESSED_EVALUATIONS": str(preprocessed_evaluations.resolve()),
        "STWO_ZIG_SN2_TREE0_ROOT_HEX": tree0_root_hex,
        "STWO_ZIG_SN2_EXECUTE_PREPROCESSED": "1",
        "STWO_ZIG_SN2_EXECUTE_WITNESS": "1",
        "STWO_ZIG_SN2_EXECUTE_BASE_INTERPOLATION": "1",
        "STWO_ZIG_SN2_EXECUTE_COMMITMENTS": "1",
    })
    tree_count = {
        "base-root": "2",
        "interaction-root": "3",
        "composition-root": "4",
        "full-proof": "4",
    }[mode]
    environment["STWO_ZIG_SN2_COMMIT_TREE_COUNT"] = tree_count
    if mode in ("interaction-root", "composition-root", "full-proof"):
        environment["STWO_ZIG_SN2_EXECUTE_RELATIONS"] = "1"
    if mode in ("composition-root", "full-proof"):
        if not preprocessed_coefficients or not preprocessed_coefficients.is_file():
            raise ValueError(f"{mode} requires --preprocessed-coefficients")
        environment["STWO_ZIG_SN2_PREPROCESSED_COEFFS"] = str(preprocessed_coefficients.resolve())
        environment["STWO_ZIG_SN2_EXECUTE_COMPOSITION"] = "1"
    if mode == "full-proof":
        if (transcript_reference is None) != (quotient_reference is None):
            raise ValueError(
                "--transcript-reference and --quotient-reference must be provided together or both omitted"
            )
        for label, path in (
            ("--transcript-reference", transcript_reference),
            ("--quotient-reference", quotient_reference),
        ):
            if path is not None and not path.is_file():
                raise ValueError(f"{label} is not a file: {path}")
        if proof_output is None:
            raise ValueError("full-proof requires --proof-output")
        if not proof_output.parent.is_dir():
            raise ValueError(f"proof output parent does not exist: {proof_output.parent}")
        if proof_output.exists():
            raise ValueError(f"proof output already exists; refusing stale artifact: {proof_output}")
        environment.update({
            "STWO_ZIG_SN2_PROOF_OUTPUT": str(proof_output.resolve()),
            "STWO_ZIG_SN2_EXECUTE_OODS": "1",
        })
        if transcript_reference is not None and quotient_reference is not None:
            environment.update({
                "STWO_ZIG_SN2_TRANSCRIPT_REFERENCE": str(transcript_reference.resolve()),
                "STWO_ZIG_SN2_QUOTIENT_REFERENCE": str(quotient_reference.resolve()),
                "STWO_ZIG_SN2_REPLAY_TRANSCRIPT_AFTER_TREE2": "1",
            })
        environment["STWO_ZIG_SN2_EXECUTE_PROOF"] = "1"
        environment["STWO_ZIG_SN2_VERIFY_PROOF"] = "1"


def apply_diagnostic_environment(
    environment: dict[str, str], mode: str, base_eval_digests: bool, input_sha256: str | None = None
) -> None:
    if not base_eval_digests:
        return
    if mode not in ROOT_MODES:
        raise ValueError("--diagnostic-base-eval-digests requires a root/proof mode")
    if not input_sha256 or not re.fullmatch(r"[0-9a-f]{64}", input_sha256):
        raise ValueError("base-eval diagnostics require the adapted input SHA-256")
    environment["STWO_ZIG_SN2_LOG_BASE_EVAL_DIGESTS"] = "1"
    environment["STWO_ZIG_SN2_INPUT_SHA256"] = input_sha256


def apply_base_eval_dump_environment(
    environment: dict[str, str], logical_id: int | None, output: Path | None
) -> None:
    if (logical_id is None) != (output is None):
        raise ValueError("base-eval dump logical ID and output must be provided together")
    if logical_id is None:
        return
    if logical_id < 0 or logical_id > 0xFFFFFFFF:
        raise ValueError("base-eval dump logical ID is outside u32")
    if environment.get("STWO_ZIG_SN2_LOG_BASE_EVAL_DIGESTS") != "1":
        raise ValueError("base-eval dump requires --diagnostic-base-eval-digests")
    if not output.parent.is_dir():
        raise ValueError(f"base-eval dump parent does not exist: {output.parent}")
    environment["STWO_ZIG_SN2_DUMP_BASE_EVAL_LOGICAL_ID"] = str(logical_id)
    environment["STWO_ZIG_SN2_DUMP_BASE_EVAL_PATH"] = str(output.resolve())


def verified_metrics(
    mode: str,
    status: str,
    cli_report: dict[str, object] | None,
    cycles: int,
    process_wall_s: float,
) -> dict[str, object]:
    verified = bool(
        mode == "full-proof"
        and status == "completed"
        and cli_report is not None
        and cli_report.get("proof_verified") is True
    )
    prove_wall_s = None
    timing_scope = cli_report.get("prove_timing_scope") if verified and cli_report is not None else None
    if verified and cli_report is not None:
        candidate = cli_report.get("prove_wall_s")
        if (
            timing_scope == PROVE_TIMING_SCOPE
            and isinstance(candidate, (int, float))
            and not isinstance(candidate, bool)
            and math.isfinite(candidate)
            and candidate > 0
        ):
            prove_wall_s = float(candidate)
    proving_speed_verified = verified and prove_wall_s is not None
    return {
        "proof_verified": verified,
        "proving_speed_verified": proving_speed_verified,
        "prove_timing_scope": timing_scope,
        "prove_wall_s": prove_wall_s,
        "prove_mhz": cycles / prove_wall_s / 1_000_000 if proving_speed_verified else None,
        "cold_process_mhz": cycles / process_wall_s / 1_000_000 if verified and process_wall_s > 0 else None,
        "calculation": "adapted_cycles / prove_wall_s / 1e6",
        "timing_contract": (
            f"prove_wall_s must use {PROVE_TIMING_SCOPE}; "
            "proof_verified must be true after cryptographic verification"
        ),
    }


def main() -> int:
    args = parser().parse_args()
    cycles, pc_count = adapted_counts(args.input)
    if not args.runner.is_file():
        raise SystemExit(f"runner not found: {args.runner}")
    if not args.schedule.is_file():
        raise SystemExit(f"schedule not found: {args.schedule}")
    artifacts = protocol_artifacts(args)
    for artifact in artifacts:
        if not artifact.is_file():
            raise SystemExit(f"protocol artifact not found: {artifact}")
    if args.stderr_output and not args.stderr_output.parent.is_dir():
        raise SystemExit(f"stderr output parent does not exist: {args.stderr_output.parent}")

    environment = benchmark_environment()
    environment["STWO_ZIG_SN2_POPULATE_INPUT"] = str(args.input.resolve())
    try:
        apply_mode_environment(
            environment,
            args.mode,
            args.preprocessed_evaluations,
            args.preprocessed_coefficients,
            args.tree0_root_hex,
            args.transcript_reference,
            args.quotient_reference,
            args.proof_output,
        )
    except ValueError as error:
        raise SystemExit(str(error)) from error

    pre_run_hash_started = time.perf_counter()
    runner_sha256 = sha256_file(args.runner)
    entries = input_artifact_entries(args, artifacts)
    composition_source = args.composition.with_suffix(".metal")
    if composition_source.is_file():
        entries["composition_source"] = artifact_entry(
            composition_source,
            kind="air_composition_source",
            format_version=ARTIFACT_FORMATS["composition_source"],
            provenance="proof_derived",
            source_digests=[str(entries["composition"]["sha256"])],
            provenance_reason=(
                "current generated Metal source is retargeted from target Rust proof data"
            ),
        )
        environment["STWO_ZIG_SN2_COMPOSITION_SOURCE"] = str(composition_source.resolve())
    pre_run_hash_wall_s = time.perf_counter() - pre_run_hash_started
    input_sha256 = str(entries["adapted_input"]["sha256"])

    try:
        apply_diagnostic_environment(
            environment,
            args.mode,
            args.diagnostic_base_eval_digests,
            input_sha256,
        )
        apply_base_eval_dump_environment(
            environment,
            args.diagnostic_base_eval_dump_logical_id,
            args.diagnostic_base_eval_dump_output,
        )
    except ValueError as error:
        raise SystemExit(str(error)) from error

    command = runner_command(args, artifacts)
    status, exit_code, wall_s, stdout, stderr = run_gate(command, environment, args.timeout)
    if args.stderr_output:
        write_text_atomic(args.stderr_output, stderr)
    cli_report = None
    if status == "completed":
        try:
            decoded_report = json.loads(stdout)
            if isinstance(decoded_report, dict):
                cli_report = decoded_report
            else:
                status = "invalid_output"
        except json.JSONDecodeError:
            status = "invalid_output"

    status, protocol_parameters, protocol_complete = protocol_gate(status, cli_report)

    metrics = verified_metrics(args.mode, status, cli_report, cycles, wall_s)
    if args.mode == "full-proof" and status == "completed":
        if not metrics["proof_verified"]:
            status = "unverified_output"
        elif metrics["prove_wall_s"] is None:
            status = "missing_prove_timing"

    post_run_hash_started = time.perf_counter()
    if args.proof_output is not None and args.proof_output.is_file():
        entries["proof"] = proof_artifact_entry(
            args.proof_output,
            runner_sha256,
            command,
            entries,
            cli_report,
        )
    post_run_hash_wall_s = time.perf_counter() - post_run_hash_started
    if args.mode == "full-proof" and status == "completed" and "proof" not in entries:
        status = "missing_proof_artifact"
    manifest = artifact_manifest(entries, pre_run_hash_wall_s, post_run_hash_wall_s)
    provenance = authoritative_provenance(
        args.mode,
        status,
        metrics,
        cli_report,
        entries,
        args.transcript_reference,
        args.quotient_reference,
    )
    pow_report = pow_telemetry(cli_report)

    report = {
        "schema_version": 3,
        "benchmark": "direct_sn_pie_metal_gate",
        "mode": args.mode,
        "status": status,
        **metrics,
        **provenance,
        "protocol": protocol_parameters,
        "protocol_complete": protocol_complete,
        "pow_telemetry": pow_report,
        "input": {
            "path": str(args.input.resolve()),
            "sha256": input_sha256,
            "adapted_cycles": cycles,
            "pc_count": pc_count,
        },
        "protocol_artifacts": {
            "witness_programs": str(args.witness_programs.resolve()),
            "multiplicity_feeds": str(args.multiplicity_feeds.resolve()),
            "relation_templates": str(args.relation_templates.resolve()),
            "fixed_tables": str(args.fixed_tables.resolve()),
            "composition": str(args.composition.resolve()),
        },
        "artifact_manifest": manifest,
        "hardware": hardware(),
        "command": command,
        "exit_code": exit_code,
        "wall_s": wall_s,
        "resource_usage": parse_time(stderr),
        "cli_report": cli_report,
        "stderr_tail": stderr[-4096:],
    }
    encoded = json.dumps(report, indent=2) + "\n"
    if args.output:
        args.output.write_text(encoded)
    sys.stdout.write(encoded)
    return 0 if status == "completed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
