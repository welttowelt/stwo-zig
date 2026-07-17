"""Content-addressed benchmark report and delta archive."""

from __future__ import annotations

import hashlib
import json
import os
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator

from .common import (
    DELTA_PROTOCOL,
    DeltaError,
    atomic_write,
    digest_json,
    encoded_json,
    require_list,
    require_object,
)


ARCHIVE_SCHEMA_VERSION = 1


@contextmanager
def archive_lock(archive_dir: Path) -> Iterator[None]:
    archive_dir.mkdir(parents=True, exist_ok=True)
    lock_path = archive_dir / ".benchmark-delta.lock"
    try:
        descriptor = os.open(lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError as error:
        raise DeltaError(f"benchmark archive is locked: {archive_dir}") from error
    try:
        os.write(descriptor, f"pid={os.getpid()}\n".encode())
        os.fsync(descriptor)
        yield
    finally:
        os.close(descriptor)
        lock_path.unlink(missing_ok=True)


def archive_blob(
    archive_dir: Path, category: str, kind: str, raw: bytes, sha256: str
) -> str:
    relative = Path(category) / kind / f"{sha256}.json"
    destination = archive_dir / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        if not destination.is_file() or destination.read_bytes() != raw:
            raise DeltaError(f"content-addressed archive collision: {destination}")
    else:
        try:
            with destination.open("xb") as output:
                output.write(raw)
                output.flush()
                os.fsync(output.fileno())
        except FileExistsError:
            if destination.read_bytes() != raw:
                raise DeltaError(f"content-addressed archive collision: {destination}")
    return relative.as_posix()


def update_archive(
    archive_dir: Path,
    document: dict[str, Any],
    baseline_raw: bytes,
    current_raw: bytes,
) -> dict[str, Any]:
    with archive_lock(archive_dir):
        sources = document["sources"]
        baseline_relative = archive_blob(
            archive_dir,
            "reports",
            sources["baseline"]["report_protocol"],
            baseline_raw,
            sources["baseline"]["sha256"],
        )
        current_relative = archive_blob(
            archive_dir,
            "reports",
            sources["current"]["report_protocol"],
            current_raw,
            sources["current"]["sha256"],
        )
        core_delta = encoded_json(document)
        delta_sha256 = hashlib.sha256(core_delta).hexdigest()
        delta_relative = archive_blob(
            archive_dir, "deltas", DELTA_PROTOCOL, core_delta, delta_sha256
        )
        index_path = archive_dir / "index.json"
        if index_path.exists():
            try:
                index = json.loads(index_path.read_text(encoding="utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError) as error:
                raise DeltaError("benchmark archive index is invalid") from error
            if not isinstance(index, dict) or index.get("schema_version") != ARCHIVE_SCHEMA_VERSION:
                raise DeltaError("benchmark archive index schema is incompatible")
        else:
            index = {
                "schema_version": ARCHIVE_SCHEMA_VERSION,
                "artifacts": {},
                "deltas": {},
                "comparisons": [],
            }
        artifacts = require_object(index.get("artifacts"), "archive.artifacts")
        for source, relative in (
            (sources["baseline"], baseline_relative),
            (sources["current"], current_relative),
        ):
            expected = {"path": relative, "bytes": source["bytes"]}
            existing = artifacts.get(source["sha256"])
            if existing is not None and existing != expected:
                raise DeltaError("archive artifact index conflicts with immutable content")
            artifacts[source["sha256"]] = expected
        deltas = require_object(index.setdefault("deltas", {}), "archive.deltas")
        expected_delta = {"path": delta_relative, "bytes": len(core_delta)}
        existing_delta = deltas.get(delta_sha256)
        if existing_delta is not None and existing_delta != expected_delta:
            raise DeltaError("archive delta index conflicts with immutable content")
        deltas[delta_sha256] = expected_delta
        comparison = {
            "archived_at": document["generated_at"],
            "report_kind": document["report_kind"],
            "status": document["status"],
            "comparison_identity_sha256": (
                document["comparison_identity"]["sha256"]
                if document["comparison_identity"] is not None
                else None
            ),
            "baseline_sha256": sources["baseline"]["sha256"],
            "current_sha256": sources["current"]["sha256"],
            "delta_sha256": delta_sha256,
            "delta_path": delta_relative,
        }
        comparison["id"] = digest_json(comparison)
        comparisons = require_list(index.get("comparisons"), "archive.comparisons")
        existing_ids = {
            entry.get("id")
            for entry in comparisons
            if isinstance(entry, dict) and isinstance(entry.get("id"), str)
        }
        if comparison["id"] not in existing_ids:
            comparisons.append(comparison)
        comparisons.sort(key=lambda entry: (entry["archived_at"], entry["id"]))
        atomic_write(index_path, encoded_json(index))
    return {
        "directory": str(archive_dir.resolve()),
        "index": str((archive_dir / "index.json").resolve()),
        "baseline_artifact": baseline_relative,
        "current_artifact": current_relative,
        "delta_artifact": delta_relative,
        "delta_sha256": delta_sha256,
        "delta_representation": "core_delta_without_archive_block",
    }
