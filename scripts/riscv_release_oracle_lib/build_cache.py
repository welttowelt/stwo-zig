"""Authenticated local cache for the pinned Stark-V CP-11 helper binary."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import stat
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path


CACHE_SCHEMA = "riscv-stark-v-oracle-build-cache-v1"
MANIFEST_NAME = "manifest.json"
EXECUTABLE_NAME = "cp11_dump"
MAX_MANIFEST_BYTES = 256 * 1024


def _strict_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    value: dict[str, object] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError(f"duplicate JSON field: {key}")
        value[key] = item
    return value


def canonical_json(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def cache_key(identity: dict[str, object]) -> str:
    return sha256_bytes(canonical_json(identity))


def default_cache_dir() -> Path:
    explicit = os.environ.get("STWO_ZIG_RISCV_ORACLE_CACHE_DIR")
    if explicit:
        return Path(explicit).expanduser()
    xdg = os.environ.get("XDG_CACHE_HOME")
    if xdg:
        return Path(xdg).expanduser() / "stwo-zig" / "riscv-oracle"
    home = Path.home()
    if sys.platform == "darwin":
        return home / "Library" / "Caches" / "stwo-zig" / "riscv-oracle"
    return home / ".cache" / "stwo-zig" / "riscv-oracle"


@dataclass(frozen=True)
class CacheHit:
    executable: Path
    key_sha256: str
    manifest_sha256: str
    executable_sha256: str


def _load_entry(entry: Path, identity: dict[str, object]) -> CacheHit | None:
    manifest_path = entry / MANIFEST_NAME
    executable = entry / EXECUTABLE_NAME
    if (
        manifest_path.is_symlink()
        or executable.is_symlink()
        or not manifest_path.is_file()
        or not executable.is_file()
    ):
        return None
    try:
        manifest_bytes = manifest_path.read_bytes()
        if len(manifest_bytes) > MAX_MANIFEST_BYTES:
            return None
        manifest = json.loads(
            manifest_bytes.decode("utf-8"),
            object_pairs_hook=_strict_object,
        )
    except (OSError, UnicodeDecodeError, ValueError, json.JSONDecodeError):
        return None
    if not isinstance(manifest, dict) or set(manifest) != {
        "schema",
        "cache_key_sha256",
        "identity",
        "artifact",
    }:
        return None
    expected_key = cache_key(identity)
    if (
        manifest.get("schema") != CACHE_SCHEMA
        or manifest.get("cache_key_sha256") != expected_key
        or manifest.get("identity") != identity
    ):
        return None
    artifact = manifest.get("artifact")
    if not isinstance(artifact, dict) or set(artifact) != {
        "path",
        "size_bytes",
        "sha256",
    }:
        return None
    expected_sha = artifact.get("sha256")
    expected_size = artifact.get("size_bytes")
    if (
        artifact.get("path") != EXECUTABLE_NAME
        or not isinstance(expected_sha, str)
        or len(expected_sha) != 64
        or not isinstance(expected_size, int)
        or expected_size < 1
    ):
        return None
    try:
        executable_stat = executable.stat()
        if not stat.S_ISREG(executable_stat.st_mode):
            return None
        if executable_stat.st_size != expected_size:
            return None
        if executable_stat.st_mode & 0o111 == 0:
            return None
        actual_sha = sha256_file(executable)
    except OSError:
        return None
    if actual_sha != expected_sha:
        return None
    return CacheHit(
        executable=executable,
        key_sha256=expected_key,
        manifest_sha256=sha256_bytes(manifest_bytes),
        executable_sha256=actual_sha,
    )


def load(cache_dir: Path, identity: dict[str, object]) -> CacheHit | None:
    """Return only an entry whose identity, manifest, size, mode, and SHA match."""
    return _load_entry(cache_dir / cache_key(identity), identity)


def store(cache_dir: Path, identity: dict[str, object], executable: Path) -> CacheHit:
    """Atomically publish one immutable content-addressed cache entry."""
    if executable.is_symlink() or not executable.is_file():
        raise ValueError("oracle cache source executable is not a regular file")
    key = cache_key(identity)
    cache_dir.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=f".{key}.", dir=cache_dir))
    try:
        staged_executable = staging / EXECUTABLE_NAME
        shutil.copyfile(executable, staged_executable)
        staged_executable.chmod(0o755)
        artifact_sha = sha256_file(staged_executable)
        manifest = {
            "schema": CACHE_SCHEMA,
            "cache_key_sha256": key,
            "identity": identity,
            "artifact": {
                "path": EXECUTABLE_NAME,
                "size_bytes": staged_executable.stat().st_size,
                "sha256": artifact_sha,
            },
        }
        (staging / MANIFEST_NAME).write_bytes(canonical_json(manifest))
        if _load_entry(staging, identity) is None:
            raise ValueError("new oracle cache entry failed self-validation")

        destination = cache_dir / key
        existing = _load_entry(destination, identity)
        if existing is not None:
            return existing
        if destination.exists() or destination.is_symlink():
            if destination.is_dir() and not destination.is_symlink():
                shutil.rmtree(destination)
            else:
                destination.unlink()
        staging.rename(destination)
        hit = _load_entry(destination, identity)
        if hit is None:
            raise ValueError("published oracle cache entry failed validation")
        return hit
    finally:
        if staging.exists():
            shutil.rmtree(staging)
