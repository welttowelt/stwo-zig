"""Reproducible Cairo compilation and benchmark provenance gates."""

from __future__ import annotations

import hashlib
import json
import os
import re
import shlex
import subprocess
import tempfile
from pathlib import Path
from typing import Any, Callable, Iterable

from .catalog import PROGRAMS, ProgramSpec


COMPILE_MANIFEST_SCHEMA = 1
COMPILE_MANIFEST_KIND = "cairo_program_compile_cache"
VERSION_RE = re.compile(r"\d+\.\d+\.\d+(?:\.\d+)?(?:[-+][0-9A-Za-z.-]+)?")
CommandRunner = Callable[..., subprocess.CompletedProcess[str]]


class ProvenanceError(RuntimeError):
    """The requested evidence cannot be tied to reproducible artifacts."""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _catalog_sha256() -> str:
    encoded = json.dumps(
        [program.as_record() for program in PROGRAMS],
        sort_keys=True,
        separators=(",", ":"),
    ).encode()
    return hashlib.sha256(encoded).hexdigest()


def atomic_write_json(path: Path, document: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    encoded = (json.dumps(document, indent=2, sort_keys=True) + "\n").encode()
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(encoded)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def _run_text(
    command: list[str],
    *,
    cwd: Path | None = None,
    runner: CommandRunner = subprocess.run,
) -> str:
    completed = runner(
        command,
        cwd=cwd,
        capture_output=True,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        output = (completed.stdout + completed.stderr).strip()
        raise ProvenanceError(f"command failed ({' '.join(command)}): {output[-2000:]}")
    return completed.stdout.strip() or completed.stderr.strip()


def git_snapshot(path: Path, *, runner: CommandRunner = subprocess.run) -> dict[str, Any]:
    root_text = _run_text(
        ["git", "-C", str(path), "rev-parse", "--show-toplevel"], runner=runner
    )
    root = Path(root_text).resolve()
    head = _run_text(["git", "-C", str(root), "rev-parse", "HEAD"], runner=runner)
    status = _run_text(
        ["git", "-C", str(root), "status", "--porcelain=v1", "--untracked-files=all"],
        runner=runner,
    )
    return {
        "root": str(root),
        "head": head,
        "clean": not status,
        "status": status.splitlines(),
    }


def _tracked(path: Path, repository: Path, *, runner: CommandRunner) -> bool:
    try:
        relative = path.resolve().relative_to(repository.resolve())
    except ValueError:
        return False
    completed = runner(
        ["git", "-C", str(repository), "ls-files", "--error-unmatch", relative.as_posix()],
        capture_output=True,
        text=True,
        check=False,
    )
    return completed.returncode == 0


def compiler_identity(
    compiler: Path, *, runner: CommandRunner = subprocess.run
) -> dict[str, str]:
    compiler = compiler.expanduser().resolve()
    if not compiler.is_file():
        raise ProvenanceError(f"missing Cairo compiler: {compiler}")
    output = _run_text([str(compiler), "--version"], runner=runner)
    match = VERSION_RE.search(output)
    if match is None:
        raise ProvenanceError(f"could not parse Cairo compiler version: {output}")
    return {
        "path": str(compiler),
        "sha256": sha256_file(compiler),
        "version": match.group(0),
        "version_output": output,
    }


def _compiled_version(path: Path) -> str:
    try:
        document = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ProvenanceError(f"invalid compiled Cairo JSON: {path}") from error
    version = document.get("compiler_version")
    if not isinstance(version, str) or not version:
        raise ProvenanceError(f"compiled Cairo JSON has no compiler_version: {path}")
    return version


def _provenance_summary(blockers: Iterable[str]) -> dict[str, Any]:
    unique = sorted(set(blockers))
    return {"headline_eligible": not unique, "blockers": unique}


def compile_cache(
    *,
    program_root: Path,
    source_repo: Path,
    compiler: Path,
    output_dir: Path,
    manifest_path: Path,
    allow_non_headline: bool = False,
    runner: CommandRunner = subprocess.run,
) -> dict[str, Any]:
    program_root = program_root.expanduser().resolve()
    output_dir = output_dir.expanduser().resolve()
    source_snapshot = git_snapshot(source_repo.expanduser().resolve(), runner=runner)
    source_repo_root = Path(source_snapshot["root"])
    compiler_record = compiler_identity(compiler, runner=runner)
    blockers: list[str] = []
    if not source_snapshot["clean"]:
        blockers.append("dirty_cairo_program_source_repository")

    sources: dict[str, Path] = {}
    for program in PROGRAMS:
        source = (program_root / program.source_relative).resolve()
        if not source.is_file():
            raise ProvenanceError(f"missing {program.slug} Cairo source: {source}")
        if not _tracked(source, source_repo_root, runner=runner):
            blockers.append(f"{program.slug}_source_not_tracked")
        sources[program.slug] = source

    if blockers and not allow_non_headline:
        raise ProvenanceError(
            "compile-cache provenance rejected: " + ", ".join(sorted(set(blockers)))
        )

    records: dict[str, Any] = {}
    for program in PROGRAMS:
        source = sources[program.slug]
        artifact = output_dir / program.artifact_relative
        artifact.parent.mkdir(parents=True, exist_ok=True)
        temporary = artifact.with_name(f".{artifact.name}.tmp")
        command = [
            compiler_record["path"],
            str(source),
            "--output",
            str(temporary),
            "--proof_mode",
        ]
        try:
            _run_text(command, cwd=program_root, runner=runner)
            version = _compiled_version(temporary)
            if version != compiler_record["version"]:
                raise ProvenanceError(
                    f"{program.slug} compiler version mismatch: "
                    f"{version} != {compiler_record['version']}"
                )
            os.replace(temporary, artifact)
        finally:
            temporary.unlink(missing_ok=True)
        records[program.slug] = {
            **program.as_record(),
            "source": {"path": str(source), "sha256": sha256_file(source)},
            "compiled": {
                "path": str(artifact),
                "sha256": sha256_file(artifact),
                "bytes": artifact.stat().st_size,
                "compiler_version": version,
            },
        }

    document = {
        "schema_version": COMPILE_MANIFEST_SCHEMA,
        "kind": COMPILE_MANIFEST_KIND,
        "catalog_sha256": _catalog_sha256(),
        "compile_argv_template": [
            "{compiler}",
            "{source}",
            "--output",
            "{compiled}",
            "--proof_mode",
        ],
        "compiler": compiler_record,
        "program_root": str(program_root),
        "output_dir": str(output_dir),
        "source_repository": source_snapshot,
        "programs": records,
        "provenance": _provenance_summary(blockers),
    }
    atomic_write_json(manifest_path.expanduser().resolve(), document)
    return document


def load_compile_manifest(path: Path) -> dict[str, Any]:
    try:
        document = json.loads(path.expanduser().resolve().read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ProvenanceError(f"invalid compile manifest: {path}") from error
    if document.get("schema_version") != COMPILE_MANIFEST_SCHEMA:
        raise ProvenanceError("unsupported Cairo compile manifest schema")
    if document.get("kind") != COMPILE_MANIFEST_KIND:
        raise ProvenanceError("unexpected Cairo compile manifest kind")
    if document.get("catalog_sha256") != _catalog_sha256():
        raise ProvenanceError("Cairo program catalog does not match the compile manifest")
    return document


def validate_compile_manifest(
    document: dict[str, Any],
    programs: Iterable[ProgramSpec],
    *,
    runner: CommandRunner = subprocess.run,
) -> tuple[dict[str, Path], list[str]]:
    blockers: list[str] = list(document.get("provenance", {}).get("blockers", []))
    compiler = compiler_identity(Path(document["compiler"]["path"]), runner=runner)
    if compiler != document["compiler"]:
        blockers.append("cairo_compiler_identity_changed")

    source_record = document["source_repository"]
    current_source = git_snapshot(Path(source_record["root"]), runner=runner)
    if not current_source["clean"]:
        blockers.append("dirty_cairo_program_source_repository")
    if current_source["head"] != source_record["head"]:
        blockers.append("cairo_program_source_revision_changed")

    artifacts: dict[str, Path] = {}
    manifest_programs = document.get("programs")
    if not isinstance(manifest_programs, dict):
        raise ProvenanceError("compile manifest programs must be an object")
    for program in programs:
        record = manifest_programs.get(program.slug)
        if not isinstance(record, dict):
            raise ProvenanceError(f"compile manifest is missing {program.slug}")
        if record.get("source_relative") != program.source_relative.as_posix():
            raise ProvenanceError(f"compile manifest source mismatch for {program.slug}")
        source = Path(record["source"]["path"])
        compiled = Path(record["compiled"]["path"])
        if not source.is_file() or sha256_file(source) != record["source"]["sha256"]:
            blockers.append(f"{program.slug}_source_hash_changed")
        if not compiled.is_file() or sha256_file(compiled) != record["compiled"]["sha256"]:
            blockers.append(f"{program.slug}_compiled_hash_changed")
        elif _compiled_version(compiled) != compiler["version"]:
            blockers.append(f"{program.slug}_compiled_version_changed")
        artifacts[program.slug] = compiled
    return artifacts, sorted(set(blockers))


def _tool_version(command: list[str], runner: CommandRunner) -> str:
    return _run_text(command, runner=runner).splitlines()[0]


def _dependency_file(binary: Path) -> Path:
    return binary.with_suffix(".d")


def _newer_dependencies(binary: Path, dependency_file: Path) -> list[str]:
    content = dependency_file.read_text()
    _, separator, encoded = content.partition(":")
    if not separator:
        return ["invalid_dep_info"]
    binary_mtime = binary.stat().st_mtime_ns
    newer: list[str] = []
    for encoded_path in shlex.split(encoded):
        path = Path(encoded_path)
        if path.is_file() and path.stat().st_mtime_ns > binary_mtime:
            newer.append(str(path))
    return newer


def runtime_provenance(
    *,
    gpu_bench: Path,
    gpu_bench_repo: Path,
    rust_stwo_repo: Path,
    runner: CommandRunner = subprocess.run,
) -> tuple[dict[str, Any], list[str]]:
    gpu_bench = gpu_bench.expanduser().resolve()
    if not gpu_bench.is_file():
        raise ProvenanceError(f"missing Rust stwo-cairo gpu_bench: {gpu_bench}")
    gpu_snapshot = git_snapshot(gpu_bench_repo.expanduser().resolve(), runner=runner)
    stwo_snapshot = git_snapshot(rust_stwo_repo.expanduser().resolve(), runner=runner)
    blockers: list[str] = []
    if not gpu_snapshot["clean"]:
        blockers.append("dirty_stwo_cairo_repository")
    if not stwo_snapshot["clean"]:
        blockers.append("dirty_rust_stwo_repository")
    try:
        gpu_bench.relative_to(Path(gpu_snapshot["root"]))
    except ValueError:
        blockers.append("gpu_bench_outside_stwo_cairo_repository")

    dependency_file = _dependency_file(gpu_bench)
    dependency_record: dict[str, Any] | None = None
    if not dependency_file.is_file():
        blockers.append("missing_gpu_bench_dep_info")
    else:
        newer = _newer_dependencies(gpu_bench, dependency_file)
        if newer:
            blockers.append("gpu_bench_has_newer_dependencies")
        dependency_record = {
            "path": str(dependency_file),
            "sha256": sha256_file(dependency_file),
            "newer_dependencies": newer,
        }

    cargo_lock = Path(gpu_bench_repo).resolve() / "Cargo.lock"
    rust_toolchain = Path(gpu_bench_repo).resolve() / "rust-toolchain.toml"
    for path, blocker in (
        (cargo_lock, "missing_stwo_cairo_cargo_lock"),
        (rust_toolchain, "missing_stwo_cairo_rust_toolchain"),
    ):
        if not path.is_file():
            blockers.append(blocker)
    record = {
        "lane_implementation": "Rust stwo-cairo legacy prover",
        "reproduction_command": {
            "cwd": str(Path(gpu_bench_repo).resolve()),
            "argv": [
                "cargo",
                "build",
                "--release",
                "-p",
                "stwo-cairo-gpu-prover",
                "--bin",
                "gpu_bench",
            ],
        },
        "gpu_bench": {
            "path": str(gpu_bench),
            "sha256": sha256_file(gpu_bench),
            "bytes": gpu_bench.stat().st_size,
            "dep_info": dependency_record,
        },
        "stwo_cairo_repository": gpu_snapshot,
        "rust_stwo_repository": stwo_snapshot,
        "cargo_lock": (
            {"path": str(cargo_lock), "sha256": sha256_file(cargo_lock)}
            if cargo_lock.is_file()
            else None
        ),
        "rust_toolchain": (
            {"path": str(rust_toolchain), "sha256": sha256_file(rust_toolchain)}
            if rust_toolchain.is_file()
            else None
        ),
        "rustc": _tool_version(["rustc", "--version"], runner),
        "cargo": _tool_version(["cargo", "--version"], runner),
    }
    return record, sorted(set(blockers))
