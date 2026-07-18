"""Content-address and verify every raw Native profiler artifact."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
from typing import Any

if __package__.startswith("scripts."):
    from scripts.native_proof_matrix_lib.artifacts import atomic_write_bytes, atomic_write_json
else:
    from native_proof_matrix_lib.artifacts import atomic_write_bytes, atomic_write_json

from .model import (
    MAX_ARTIFACT_BYTES,
    MAX_CAPTURE_BYTES,
    MAX_CAPTURE_FILES,
    CaptureError,
)


MANIFEST_NAME = "manifest.json"
CHECKSUM_NAME = "manifest.sha256"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def canonical_sha256(value: Any) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def artifact_inventory(root: Path) -> dict[str, dict[str, int | str]]:
    records: dict[str, dict[str, int | str]] = {}
    total_bytes = 0
    for path in sorted(root.rglob("*")):
        if path.name in {MANIFEST_NAME, CHECKSUM_NAME}:
            continue
        if path.is_symlink() or not path.is_file():
            if path.is_dir():
                continue
            raise CaptureError(f"profile evidence contains a non-regular artifact: {path}")
        relative = path.relative_to(root).as_posix()
        size = path.stat().st_size
        if size > MAX_ARTIFACT_BYTES:
            raise CaptureError(f"profile artifact exceeds byte limit: {relative}")
        total_bytes += size
        records[relative] = {"bytes": size, "sha256": sha256_file(path)}
    if not records:
        raise CaptureError("profile capture contains no artifacts")
    if len(records) > MAX_CAPTURE_FILES:
        raise CaptureError(f"profile capture exceeds {MAX_CAPTURE_FILES} files")
    if total_bytes > MAX_CAPTURE_BYTES:
        raise CaptureError(f"profile capture exceeds {MAX_CAPTURE_BYTES} bytes")
    return records


def publish_manifest(root: Path, document: dict[str, Any]) -> dict[str, Any]:
    if "artifacts" in document:
        raise CaptureError("manifest payload already contains an artifact inventory")
    manifest = {**document, "artifacts": artifact_inventory(root)}
    encoded = atomic_write_json(root / MANIFEST_NAME, manifest)
    digest = hashlib.sha256(encoded).hexdigest()
    atomic_write_bytes(root / CHECKSUM_NAME, f"{digest}  {MANIFEST_NAME}\n".encode())
    verify_manifest(root)
    return {"manifest": str(root / MANIFEST_NAME), "manifest_sha256": digest}


def verify_manifest(root: Path) -> dict[str, Any]:
    manifest_path = root / MANIFEST_NAME
    checksum_path = root / CHECKSUM_NAME
    if not manifest_path.is_file() or not checksum_path.is_file():
        raise CaptureError("profile capture is missing its manifest or checksum")
    raw = manifest_path.read_bytes()
    digest = hashlib.sha256(raw).hexdigest()
    if checksum_path.read_text(encoding="ascii") != f"{digest}  {MANIFEST_NAME}\n":
        raise CaptureError("profile manifest checksum does not match")
    try:
        document = json.loads(raw)
    except json.JSONDecodeError as error:
        raise CaptureError("profile manifest is not valid JSON") from error
    if not isinstance(document, dict) or not isinstance(document.get("artifacts"), dict):
        raise CaptureError("profile manifest has an invalid artifact inventory")
    if document["artifacts"] != artifact_inventory(root):
        raise CaptureError("profile artifact tree differs from its manifest")
    return document


def write_bytes_exclusive(path: Path, contents: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    try:
        with os.fdopen(descriptor, "wb", closefd=False) as destination:
            destination.write(contents)
            destination.flush()
            os.fsync(destination.fileno())
    finally:
        os.close(descriptor)
