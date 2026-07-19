#!/usr/bin/env python3
"""Select and extract one exact same-run architecture receipt artifact."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import stat
import sys
import zipfile
from pathlib import Path


HEX64 = re.compile(r"^[0-9a-f]{64}$")
DECIMAL = re.compile(r"^[1-9][0-9]*$")
SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
MAX_ARCHIVE_BYTES = 8 * 1024 * 1024
MAX_RECEIPT_BYTES = 4 * 1024 * 1024


class ArtifactError(ValueError):
    """Artifact metadata or archive content violated the CI trust contract."""


def _strict_json(path: Path) -> object:
    def reject(pairs: list[tuple[str, object]]) -> dict[str, object]:
        result = {}
        for key, value in pairs:
            if key in result:
                raise ArtifactError(f"duplicate JSON key: {key}")
            result[key] = value
        return result

    return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=reject)


def select(metadata: object, name: str, run_id: str, digest: str) -> dict[str, object]:
    if SAFE_NAME.fullmatch(name) is None:
        raise ArtifactError("artifact name is not a bounded path component")
    if DECIMAL.fullmatch(run_id) is None:
        raise ArtifactError("run ID is not canonical")
    if not digest.startswith("sha256:") or HEX64.fullmatch(digest[7:]) is None:
        raise ArtifactError("artifact digest is not canonical SHA-256")
    if not isinstance(metadata, dict) or set(metadata) < {"artifacts"}:
        raise ArtifactError("artifact API response is malformed")
    artifacts = metadata["artifacts"]
    if not isinstance(artifacts, list):
        raise ArtifactError("artifact API response has no artifact array")
    matches = [
        item for item in artifacts
        if isinstance(item, dict)
        and item.get("name") == name
        and str(item.get("workflow_run", {}).get("id")) == run_id
        and item.get("expired") is False
    ]
    if len(matches) != 1:
        raise ArtifactError("expected exactly one live same-run artifact")
    artifact = matches[0]
    if artifact.get("digest") != digest:
        raise ArtifactError("artifact API digest differs from producer output")
    identifier = artifact.get("id")
    if not isinstance(identifier, int) or identifier <= 0:
        raise ArtifactError("artifact ID is invalid")
    return {"artifact_id": identifier, "digest": digest, "name": name}


def extract(archive: Path, output: Path, expected_member: str, digest: str) -> str:
    if SAFE_NAME.fullmatch(expected_member) is None:
        raise ArtifactError("expected receipt member is unsafe")
    size = archive.stat().st_size
    if size > MAX_ARCHIVE_BYTES:
        raise ArtifactError("artifact archive exceeds the size bound")
    actual = hashlib.sha256(archive.read_bytes()).hexdigest()
    if digest != f"sha256:{actual}":
        raise ArtifactError("downloaded artifact archive digest mismatch")
    with zipfile.ZipFile(archive) as bundle:
        members = bundle.infolist()
        if len(members) != 1 or members[0].filename != expected_member:
            raise ArtifactError("artifact must contain exactly the canonical receipt member")
        member = members[0]
        mode = member.external_attr >> 16
        if stat.S_ISLNK(mode) or member.is_dir() or member.file_size > MAX_RECEIPT_BYTES:
            raise ArtifactError("artifact receipt member type or size is invalid")
        payload = bundle.read(member)
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        raise ArtifactError("refusing to replace an extracted receipt")
    output.write_bytes(payload)
    return hashlib.sha256(payload).hexdigest()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    phases = parser.add_subparsers(dest="phase", required=True)
    choose = phases.add_parser("select")
    choose.add_argument("--metadata", type=Path, required=True)
    choose.add_argument("--name", required=True)
    choose.add_argument("--run-id", required=True)
    choose.add_argument("--digest", required=True)
    unpack = phases.add_parser("extract")
    unpack.add_argument("--archive", type=Path, required=True)
    unpack.add_argument("--output", type=Path, required=True)
    unpack.add_argument("--member", required=True)
    unpack.add_argument("--digest", required=True)
    args = parser.parse_args(argv)
    try:
        if args.phase == "select":
            result = select(_strict_json(args.metadata), args.name, args.run_id, args.digest)
        else:
            result = {
                "receipt_sha256": extract(
                    args.archive, args.output, args.member, args.digest,
                )
            }
    except (ArtifactError, OSError, UnicodeError, json.JSONDecodeError, zipfile.BadZipFile) as error:
        print(f"architecture artifact: FAIL: {error}", file=sys.stderr)
        return 2
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
