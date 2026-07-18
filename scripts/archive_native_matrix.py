#!/usr/bin/env python3
"""Archive an exact Native proof-matrix tree under a content address."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import tempfile
from pathlib import Path, PurePosixPath
from typing import Any


SCHEMA = "native_proof_matrix_bundle_v1"
MAX_FILES = 256
MAX_FILE_BYTES = 64 * 1024 * 1024
MAX_TOTAL_BYTES = 256 * 1024 * 1024


class ArchiveError(RuntimeError):
    pass


def encoded_json(value: Any) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def atomic_write(path: Path, value: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix=f".{path.name}.", delete=False) as out:
        temporary = Path(out.name)
        out.write(value)
        out.flush()
        os.fsync(out.fileno())
    os.replace(temporary, path)


def load_object(path: Path, label: str) -> tuple[dict[str, Any], bytes]:
    raw = path.read_bytes()
    try:
        value = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ArchiveError(f"{label} is not valid JSON: {error}") from error
    if not isinstance(value, dict):
        raise ArchiveError(f"{label} must be a JSON object")
    return value, raw


def safe_relative(value: Any, label: str) -> Path:
    if not isinstance(value, str) or not value:
        raise ArchiveError(f"{label} must be a nonempty relative path")
    posix = PurePosixPath(value)
    if posix.is_absolute() or ".." in posix.parts or "." in posix.parts:
        raise ArchiveError(f"{label} is not a safe relative path")
    return Path(*posix.parts)


def expected_files(summary: dict[str, Any]) -> dict[Path, str]:
    rows = summary.get("rows")
    if not isinstance(rows, list) or not rows:
        raise ArchiveError("matrix summary requires nonempty rows")
    expected: dict[Path, str] = {}
    for row_index, row in enumerate(rows):
        if not isinstance(row, dict) or not isinstance(row.get("lanes"), dict):
            raise ArchiveError(f"row[{row_index}] is malformed")
        for lane_name in ("cpu", "metal"):
            lane = row["lanes"].get(lane_name)
            if not isinstance(lane, dict):
                raise ArchiveError(f"row[{row_index}].{lane_name} is missing")
            identities = (
                ("stdout_artifact", "stdout_sha256"),
                ("stderr_artifact", "stderr_sha256"),
            )
            for path_field, digest_field in identities:
                relative = safe_relative(
                    lane.get(path_field), f"row[{row_index}].{lane_name}.{path_field}"
                )
                digest = lane.get(digest_field)
                if not isinstance(digest, str) or len(digest) != 64:
                    raise ArchiveError(f"row[{row_index}].{lane_name}.{digest_field} is invalid")
                expected[relative] = digest
            artifact = lane.get("proof_artifact")
            if not isinstance(artifact, dict):
                raise ArchiveError(f"row[{row_index}].{lane_name}.proof_artifact is missing")
            relative = safe_relative(
                artifact.get("path"), f"row[{row_index}].{lane_name}.proof_artifact.path"
            )
            digest = artifact.get("sha256")
            if not isinstance(digest, str) or len(digest) != 64:
                raise ArchiveError(f"row[{row_index}].{lane_name}.proof_artifact.sha256 is invalid")
            expected[relative] = digest
    if len(expected) > MAX_FILES:
        raise ArchiveError("matrix artifact count exceeds the archive bound")
    return expected


def build_manifest(matrix_dir: Path, expected_report: Path | None) -> tuple[dict[str, Any], bytes]:
    matrix_dir = matrix_dir.resolve(strict=True)
    summary_path = matrix_dir / "summary.json"
    summary, summary_raw = load_object(summary_path, "matrix summary")
    if expected_report is not None and expected_report.resolve(strict=True).read_bytes() != summary_raw:
        raise ArchiveError("matrix summary differs from the named immutable report")

    files: list[dict[str, Any]] = []
    total_bytes = 0
    for relative, declared_digest in sorted(expected_files(summary).items()):
        source = matrix_dir / relative
        if source.is_symlink() or not source.is_file():
            raise ArchiveError(f"matrix artifact is missing or not a regular file: {relative}")
        raw = source.read_bytes()
        if len(raw) > MAX_FILE_BYTES:
            raise ArchiveError(f"matrix artifact exceeds the per-file bound: {relative}")
        actual_digest = sha256_bytes(raw)
        if actual_digest != declared_digest:
            raise ArchiveError(f"matrix artifact digest mismatch: {relative}")
        total_bytes += len(raw)
        if total_bytes > MAX_TOTAL_BYTES:
            raise ArchiveError("matrix artifacts exceed the total archive bound")
        files.append(
            {"path": relative.as_posix(), "bytes": len(raw), "sha256": actual_digest}
        )
    configuration = summary.get("configuration", {})
    if not isinstance(configuration, dict):
        raise ArchiveError("matrix summary configuration must be an object")
    execution_provenance = {
        "runner": configuration.get("provenance"),
        "host_environment": configuration.get("host_environment"),
        "host_load": configuration.get("host_load"),
    }
    limitations = [
        "this bundle preserves evidence and does not reclassify diagnostic benchmark rows",
    ]
    if (
        execution_provenance["host_environment"] is None
        or execution_provenance["host_load"] is None
    ):
        limitations.insert(
            0,
            "execution host fields absent from the source report cannot be reconstructed",
        )
    manifest = {
        "schema": SCHEMA,
        "report": {
            "protocol": summary.get("protocol"),
            "schema_version": summary.get("schema_version"),
            "bytes": len(summary_raw),
            "sha256": sha256_bytes(summary_raw),
        },
        "execution_provenance": execution_provenance,
        "files": files,
        "totals": {"artifact_files": len(files), "artifact_bytes": total_bytes},
        "limitations": limitations,
    }
    return manifest, summary_raw


def publish_bundle(matrix_dir: Path, archive_dir: Path, expected_report: Path | None) -> dict[str, Any]:
    manifest, summary_raw = build_manifest(matrix_dir, expected_report)
    manifest_raw = encoded_json(manifest)
    digest = sha256_bytes(manifest_raw)
    relative = Path("matrix_bundles") / SCHEMA / digest
    destination = archive_dir.resolve() / relative
    tree = destination / "tree"
    destination.mkdir(parents=True, exist_ok=True)

    matrix_dir = matrix_dir.resolve(strict=True)
    for identity in manifest["files"]:
        artifact_relative = Path(*PurePosixPath(identity["path"]).parts)
        target = tree / artifact_relative
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists():
            if sha256_bytes(target.read_bytes()) != identity["sha256"]:
                raise ArchiveError(f"content-addressed matrix collision: {target}")
            continue
        with tempfile.NamedTemporaryFile(dir=target.parent, prefix=f".{target.name}.", delete=False) as out:
            temporary = Path(out.name)
            with (matrix_dir / artifact_relative).open("rb") as source:
                shutil.copyfileobj(source, out)
            out.flush()
            os.fsync(out.fileno())
        os.replace(temporary, target)
    atomic_write(destination / "summary.json", summary_raw)
    atomic_write(destination / "manifest.json", manifest_raw)

    locator = {
        "schema": SCHEMA,
        "bundle_sha256": digest,
        "path": relative.as_posix(),
        "report_sha256": manifest["report"]["sha256"],
        "artifact_files": manifest["totals"]["artifact_files"],
        "artifact_bytes": manifest["totals"]["artifact_bytes"],
    }
    index_path = archive_dir.resolve() / "matrix_bundles" / "index.json"
    if index_path.exists():
        index, _ = load_object(index_path, "matrix bundle index")
        if index.get("schema_version") != 1 or not isinstance(index.get("bundles"), dict):
            raise ArchiveError("matrix bundle index schema is incompatible")
    else:
        index = {"schema_version": 1, "bundles": {}}
    existing = index["bundles"].get(digest)
    if existing is not None and existing != locator:
        raise ArchiveError("matrix bundle index conflicts with immutable content")
    index["bundles"][digest] = locator
    atomic_write(index_path, encoded_json(index))
    return locator


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--matrix-dir", type=Path, required=True)
    parser.add_argument("--archive-dir", type=Path, required=True)
    parser.add_argument("--expected-report", type=Path)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        locator = publish_bundle(args.matrix_dir, args.archive_dir, args.expected_report)
    except (ArchiveError, OSError) as error:
        print(f"Native matrix archive failed: {error}")
        return 1
    print(json.dumps(locator, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
