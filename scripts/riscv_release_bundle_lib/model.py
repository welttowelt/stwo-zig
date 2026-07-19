"""Content identities and fail-closed bundle validation."""

from __future__ import annotations

import hashlib
import json
import os
import stat
import subprocess
from pathlib import Path
from typing import Any


SCHEMA = "riscv-release-bundle-v1"
ORACLE_BOUNDARY_COUNT = 11
MAX_JSON_BYTES = 64 * 1024 * 1024
FILE_LAYOUT = {
    "release-gate.json": "release-gate.json",
    "oracle-receipt.json": "oracle-receipt.json",
    "cli/summary.json": "cli/summary.json",
    "bin/stwo-zig": "bin/stwo-zig",
}
COVERAGE = {
    "exhaustive_gate": "PASS",
    "cross_shard_cli_smoke": "PASS",
    "benchmark_cli_smoke": "PASS",
    "oracle_boundaries": f"{ORACLE_BOUNDARY_COUNT}/{ORACLE_BOUNDARY_COUNT}",
}
DOMAIN_PATHS = {
    "repository": (),
    "prover": (
        "build.zig",
        "build.zig.zon",
        "build_support",
        "src",
        "tools",
        "vectors/riscv_elfs",
    ),
    "cli_admission": (
        "src/tools/prove",
        "src/interop/riscv_artifact.zig",
        "scripts/riscv_staged_smoke.py",
        "scripts/riscv_staged_smoke_lib",
        "scripts/riscv_trace_vectors_lib/admission.py",
        "vectors/riscv_elfs",
    ),
    "release_gate": (
        ".github/workflows/ci.yml",
        "build.zig",
        "build_support",
        "scripts",
        "conformance",
        "autoresearch/MANIFEST.json",
    ),
    "oracle_adapter": (
        "scripts/riscv_release_oracle.py",
        "scripts/riscv_release_oracle_lib",
        "scripts/riscv_release_gate_lib/contract.py",
        "vectors/riscv_elfs",
    ),
}


class BundleError(ValueError):
    """The bundle cannot authorize the requested release gate."""


def canonical_sha256(value: object) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def strict_json(path: Path) -> dict[str, Any]:
    if path.stat().st_size > MAX_JSON_BYTES:
        raise BundleError(f"{path}: exceeds {MAX_JSON_BYTES} bytes")

    def strict_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise BundleError(f"{path}: duplicate JSON field {key}")
            result[key] = value
        return result

    try:
        payload = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=strict_object)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise BundleError(f"cannot read {path}: {error}") from error
    if not isinstance(payload, dict):
        raise BundleError(f"{path}: root must be an object")
    return payload


def git_output(root: Path, *args: str) -> str:
    return subprocess.run(
        ["git", *args], cwd=root, check=True, capture_output=True, text=True,
    ).stdout.strip()


def require_clean_head(root: Path, candidate: str) -> str:
    head = git_output(root, "rev-parse", "HEAD")
    if head != candidate:
        raise BundleError(f"candidate {candidate} does not match HEAD {head}")
    dirty = git_output(root, "status", "--porcelain=v1", "--untracked-files=all")
    if dirty:
        raise BundleError("candidate checkout is dirty")
    return git_output(root, "rev-parse", f"{candidate}^{{tree}}")


def tracked_domain(root: Path, paths: tuple[str, ...]) -> dict[str, object]:
    command = ["git", "ls-files", "--stage", "-z"]
    if paths:
        command.extend(("--", *paths))
    raw = subprocess.run(command, cwd=root, check=True, capture_output=True).stdout
    records: list[dict[str, object]] = []
    digest = hashlib.sha256()
    for entry in raw.split(b"\0"):
        if not entry:
            continue
        metadata, path_bytes = entry.split(b"\t", 1)
        mode, object_id, stage = metadata.decode("ascii").split(" ")
        if stage != "0":
            raise BundleError(f"unmerged path in content domain: {path_bytes!r}")
        blob = subprocess.run(
            ["git", "cat-file", "blob", object_id], cwd=root, check=True, capture_output=True,
        ).stdout
        for value in (mode.encode(), path_bytes, blob):
            digest.update(len(value).to_bytes(8, "big"))
            digest.update(value)
        records.append({"path": path_bytes.decode("utf-8"), "mode": mode})
    if not records:
        raise BundleError(f"empty content domain for paths {paths}")
    return {
        "schema": "git-tracked-content-v1",
        "sha256": digest.hexdigest(),
        "file_count": len(records),
        "paths": list(paths),
    }


def source_domains(root: Path) -> dict[str, dict[str, object]]:
    return {name: tracked_domain(root, paths) for name, paths in DOMAIN_PATHS.items()}


def oracle_domain(receipt: dict[str, Any]) -> dict[str, object]:
    oracle = receipt.get("oracle")
    if not isinstance(oracle, dict):
        raise BundleError("oracle receipt lacks oracle identity")
    identity = {
        key: oracle.get(key)
        for key in (
            "repository",
            "commit",
            "tree_digest_sha256",
            "submodule_status",
            "lockfile_sha256",
            "toolchain",
            "build_command",
            "build_mode",
            "adapter_overlay",
            "executable_sha256",
            "host_arch",
            "host_os",
        )
    }
    return {"schema": "pinned-oracle-build-v1", "sha256": canonical_sha256(identity)}


def validate_gate_report(report: dict[str, Any], candidate: str, phase: str) -> None:
    if report.get("schema") != "riscv-release-gate-evidence-v1":
        raise BundleError("release gate evidence schema drifted")
    if (report.get("status"), report.get("phase"), report.get("candidate_commit")) != (
        "PASS", phase, candidate,
    ):
        raise BundleError("release gate did not pass for this exact candidate and phase")
    git = report.get("git")
    if not isinstance(git, dict) or git.get("head") != candidate or any(
        git.get(field) for field in ("initial_porcelain", "final_porcelain")
    ):
        raise BundleError("release gate did not run from a clean exact candidate")
    commands = report.get("commands")
    if not isinstance(commands, list):
        raise BundleError("release gate commands are missing")
    for record in commands:
        if not isinstance(record, dict) or record.get("exit_code") != 0:
            raise BundleError("release gate contains a failed command")
        if record.get("skipped_tests") != 0:
            raise BundleError("release gate contains skipped required tests")
    rendered = [record.get("command_shell", "") for record in commands]
    required = (
        "scripts/riscv_staged_smoke.py",
        "zig build release-gate-strict",
        "scripts/riscv_release_oracle.py build-and-compare",
        "scripts/riscv_release_oracle.py validate",
        "scripts/riscv_release_evidence.py",
    )
    for fragment in required:
        if sum(fragment in command for command in rendered) != 1:
            raise BundleError(f"release gate lacks one exhaustive command: {fragment}")


def validate_cli_summary(
    summary: dict[str, Any], candidate: str, phase: str, executable_sha256: str,
) -> None:
    expected_status = "not_release_gated" if phase == "candidate" else "release_gated"
    expected = (
        summary.get("schema"), summary.get("phase"), summary.get("release_status"),
        summary.get("implementation_commit"), summary.get("implementation_dirty"),
        summary.get("executable_sha256"),
    )
    if expected != (
        "riscv_cli_evidence_v1", phase, expected_status, candidate, False, executable_sha256,
    ):
        raise BundleError("exhaustive CLI summary identity drifted")
    if summary.get("multi_shard_addi_rows", 0) <= 65_536:
        raise BundleError("exhaustive CLI summary did not cross a shard boundary")
    required_successes = (
        "artifact_sha256", "benchmark_artifact_sha256", "benchmark_report_sha256",
        "verify_receipt_sha256", "benchmark_verify_receipt_sha256",
    )
    if any(not isinstance(summary.get(field), str) for field in required_successes):
        raise BundleError("exhaustive CLI or benchmark evidence is incomplete")
    if summary.get("independent_verify_returncode") != 0 or summary.get("tamper_returncode") == 0:
        raise BundleError("exhaustive CLI verification/tamper result drifted")


def regular_bundle_file(bundle: Path, relative: str) -> Path:
    path = bundle / relative
    try:
        metadata = path.lstat()
    except OSError as error:
        raise BundleError(f"missing bundle file {relative}: {error}") from error
    if not stat.S_ISREG(metadata.st_mode) or path.is_symlink():
        raise BundleError(f"bundle entry is not a regular file: {relative}")
    if not path.resolve().is_relative_to(bundle.resolve()):
        raise BundleError(f"bundle entry escapes bundle root: {relative}")
    return path


def file_record(path: Path) -> dict[str, object]:
    return {"sha256": sha256_file(path), "size": path.stat().st_size}


def validate_files(bundle: Path, manifest: dict[str, Any]) -> dict[str, Path]:
    files = manifest.get("files")
    if not isinstance(files, dict) or set(files) != set(FILE_LAYOUT):
        raise BundleError("bundle file manifest drifted")
    resolved: dict[str, Path] = {}
    for name, relative in FILE_LAYOUT.items():
        path = regular_bundle_file(bundle, relative)
        if files[name] != file_record(path):
            raise BundleError(f"bundle file digest or size drifted: {name}")
        resolved[name] = path
    return resolved


def atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
    encoded = (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode()
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)
