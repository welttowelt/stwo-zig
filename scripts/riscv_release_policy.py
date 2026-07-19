#!/usr/bin/env python3
"""Capture and enforce the trusted-main RISC-V release policy domain."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import zipfile
from pathlib import Path
from typing import Any


POLICY_PATHS = (
    ".github/workflows/ci.yml",
    "CONTRIBUTING.md",
    "autoresearch/MANIFEST.json",
    "build.zig",
    "build.zig.zon",
    "build_support",
    "conformance",
    "scripts",
    "vectors/riscv_elfs",
)
DOMAIN_SCHEMA = "riscv-release-policy-domain-v1"
BASELINE_SCHEMA = "riscv-release-policy-baseline-v1"
MATCH_SCHEMA = "riscv-release-policy-match-v1"
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
MAX_JSON_BYTES = 8 * 1024 * 1024
MAX_ARCHIVE_FILES = 32
MAX_ARCHIVE_BYTES = 512 * 1024 * 1024


class PolicyError(ValueError):
    """The selected source is not governed by the trusted release policy."""


def git(root: Path, *arguments: str, binary: bool = False) -> bytes | str:
    result = subprocess.run(
        ["git", *arguments], cwd=root, check=True, capture_output=True,
        text=not binary,
    )
    return result.stdout


def require_clean_commit(root: Path, expected: str) -> None:
    if COMMIT_RE.fullmatch(expected) is None:
        raise PolicyError("expected commit is not a full SHA")
    if git(root, "rev-parse", "HEAD").strip() != expected:
        raise PolicyError("checkout does not match the expected commit")
    if git(root, "status", "--porcelain=v1", "--untracked-files=all").strip():
        raise PolicyError("policy checkout is dirty")


def policy_domain(
    root: Path, paths: tuple[str, ...] | None = None,
) -> dict[str, Any]:
    paths = POLICY_PATHS if paths is None else paths
    output = git(
        root, "ls-tree", "-r", "-z", "--full-tree", "HEAD", "--", *paths,
        binary=True,
    )
    assert isinstance(output, bytes)
    entries: list[tuple[bytes, bytes, bytes, bytes]] = []
    covered: set[str] = set()
    for raw in output.split(b"\0"):
        if not raw:
            continue
        metadata, path = raw.split(b"\t", 1)
        mode, kind, object_id = metadata.split(b" ")
        entries.append((mode, kind, object_id, path))
        decoded = path.decode("utf-8")
        for declared in paths:
            if decoded == declared or decoded.startswith(f"{declared}/"):
                covered.add(declared)
    if covered != set(paths):
        missing = sorted(set(paths) - covered)
        raise PolicyError(f"policy domain path is absent: {missing}")

    process = subprocess.Popen(
        ["git", "cat-file", "--batch"], cwd=root,
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if process.stdin is None or process.stdout is None or process.stderr is None:
        process.kill()
        raise PolicyError("cannot open git cat-file batch pipes")
    digest = hashlib.sha256()
    try:
        for mode, kind, object_id, path in entries:
            if kind != b"blob":
                raise PolicyError(f"policy domain contains non-blob entry: {path!r}")
            process.stdin.write(object_id + b"\n")
            process.stdin.flush()
            header = process.stdout.readline().rstrip(b"\n").split(b" ")
            if len(header) != 3 or header[:2] != [object_id, b"blob"]:
                raise PolicyError("git cat-file policy identity drifted")
            try:
                size = int(header[2])
            except ValueError as error:
                raise PolicyError("invalid git cat-file policy size") from error
            for value in (mode, path):
                digest.update(len(value).to_bytes(8, "big"))
                digest.update(value)
            digest.update(size.to_bytes(8, "big"))
            remaining = size
            while remaining:
                content = process.stdout.read(min(1024 * 1024, remaining))
                if not content:
                    raise PolicyError("truncated git cat-file policy object")
                digest.update(content)
                remaining -= len(content)
            if process.stdout.read(1) != b"\n":
                raise PolicyError("truncated git cat-file policy terminator")
        process.stdin.close()
        if process.wait() != 0:
            diagnostic = process.stderr.read().decode("utf-8", errors="replace").strip()
            raise PolicyError(f"git cat-file policy batch failed: {diagnostic}")
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        for stream in (process.stdin, process.stdout, process.stderr):
            if not stream.closed:
                stream.close()
    return {
        "schema": DOMAIN_SCHEMA,
        "sha256": digest.hexdigest(),
        "file_count": len(entries),
        "paths": list(paths),
    }


def strict_json(path: Path) -> dict[str, Any]:
    if path.stat().st_size > MAX_JSON_BYTES:
        raise PolicyError(f"JSON exceeds {MAX_JSON_BYTES} bytes: {path}")

    def strict_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise PolicyError(f"duplicate JSON field: {key}")
            result[key] = value
        return result

    payload = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=strict_object)
    if not isinstance(payload, dict):
        raise PolicyError("JSON root must be an object")
    return payload


def atomic_json(path: Path, payload: dict[str, Any]) -> None:
    encoded = (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode()
    path.parent.mkdir(parents=True, exist_ok=True)
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


def capture(args: argparse.Namespace) -> int:
    root = args.root.resolve()
    require_clean_commit(root, args.trusted_commit)
    atomic_json(args.output, {
        "schema": BASELINE_SCHEMA,
        "trusted_workflow_commit": args.trusted_commit,
        "domain": policy_domain(root),
    })
    return 0


def compare(args: argparse.Namespace) -> int:
    root = args.root.resolve()
    require_clean_commit(root, args.candidate)
    baseline = strict_json(args.baseline)
    if set(baseline) != {"schema", "trusted_workflow_commit", "domain"} or \
            baseline.get("schema") != BASELINE_SCHEMA:
        raise PolicyError("trusted policy baseline schema drifted")
    trusted_commit = baseline.get("trusted_workflow_commit")
    if not isinstance(trusted_commit, str) or COMMIT_RE.fullmatch(trusted_commit) is None:
        raise PolicyError("trusted workflow commit is invalid")
    candidate_domain = policy_domain(root)
    if candidate_domain != baseline.get("domain"):
        raise PolicyError("candidate release policy differs from trusted main")
    atomic_json(args.output, {
        "schema": MATCH_SCHEMA,
        "trusted_workflow_commit": trusted_commit,
        "candidate_commit": args.candidate,
        "domain": candidate_domain,
    })
    return 0


def extract(args: argparse.Namespace) -> int:
    archive = args.archive.resolve()
    output = args.output.resolve()
    if output.exists():
        raise PolicyError(f"artifact output already exists: {output}")
    with zipfile.ZipFile(archive) as bundle:
        members = bundle.infolist()
        if not members or len(members) > MAX_ARCHIVE_FILES:
            raise PolicyError("artifact archive file count is invalid")
        if sum(member.file_size for member in members) > MAX_ARCHIVE_BYTES:
            raise PolicyError("artifact archive is too large")
        names: set[str] = set()
        for member in members:
            path = Path(member.filename)
            normalized = path.as_posix().rstrip("/")
            if normalized in names or not normalized or normalized == "." or \
                    normalized != member.filename.rstrip("/") or \
                    path.is_absolute() or ".." in path.parts:
                raise PolicyError("artifact archive path is unsafe or duplicated")
            names.add(normalized)
            mode = member.external_attr >> 16
            if stat.S_ISLNK(mode):
                raise PolicyError("artifact archive contains a symlink")
            kind = stat.S_IFMT(mode)
            if not member.is_dir() and kind not in (0, stat.S_IFREG):
                raise PolicyError("artifact archive contains a non-regular entry")
        output.mkdir(parents=True)
        try:
            bundle.extractall(output)
        except BaseException:
            shutil.rmtree(output)
            raise
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    command = commands.add_parser("capture")
    command.add_argument("--root", type=Path, required=True)
    command.add_argument("--trusted-commit", required=True)
    command.add_argument("--output", type=Path, required=True)
    command.set_defaults(handler=capture)
    command = commands.add_parser("compare")
    command.add_argument("--root", type=Path, required=True)
    command.add_argument("--candidate", required=True)
    command.add_argument("--baseline", type=Path, required=True)
    command.add_argument("--output", type=Path, required=True)
    command.set_defaults(handler=compare)
    command = commands.add_parser("extract")
    command.add_argument("--archive", type=Path, required=True)
    command.add_argument("--output", type=Path, required=True)
    command.set_defaults(handler=extract)
    args = parser.parse_args(argv)
    try:
        return args.handler(args)
    except (OSError, ValueError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
        print(f"riscv release policy: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
