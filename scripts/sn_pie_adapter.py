#!/usr/bin/env python3
"""Execute a Cairo PIE through the reference bootloader and export STWZCPI."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import zipfile


MAGIC = b"STWZCPI\0"
VERSION = 1
DIRECTORY_IDENTITY_VERSION = 2
HASH_CHUNK_BYTES = 1024 * 1024


def _member_digest(stream) -> tuple[int, bytes]:
    digest = hashlib.sha256()
    size = 0
    while chunk := stream.read(HASH_CHUNK_BYTES):
        digest.update(chunk)
        size += len(chunk)
    return size, digest.digest()


def _update_directory_identity(
    digest, relative: str, size: int, content_digest: bytes
) -> None:
    encoded = relative.encode("utf-8")
    digest.update(len(encoded).to_bytes(4, "little"))
    digest.update(encoded)
    digest.update(size.to_bytes(8, "little"))
    digest.update(content_digest)


def directory_fingerprint(source: Path) -> str:
    digest = hashlib.sha256()
    digest.update(b"stwo-zig-pie-directory\0")
    digest.update(DIRECTORY_IDENTITY_VERSION.to_bytes(4, "little"))
    entries = sorted(source.rglob("*"))
    for path in entries:
        if path.is_symlink():
            raise ValueError(f"PIE directory contains a symlink: {path}")
    files = [path for path in entries if path.is_file()]
    if not files:
        raise ValueError(f"PIE directory is empty: {source}")
    for path in files:
        relative = path.relative_to(source).as_posix()
        with path.open("rb") as member:
            size, content_digest = _member_digest(member)
        _update_directory_identity(digest, relative, size, content_digest)
    return digest.hexdigest()


def _archive_fingerprint(path: Path) -> str:
    digest = hashlib.sha256()
    digest.update(b"stwo-zig-pie-directory\0")
    digest.update(DIRECTORY_IDENTITY_VERSION.to_bytes(4, "little"))
    with zipfile.ZipFile(path) as archive:
        members = sorted(
            (info for info in archive.infolist() if not info.is_dir()),
            key=lambda info: info.filename,
        )
        if not members:
            raise ValueError(f"PIE archive is empty: {path}")
        names: set[str] = set()
        for info in members:
            if info.filename in names:
                raise ValueError(f"PIE archive contains duplicate member: {info.filename}")
            names.add(info.filename)
            with archive.open(info) as member:
                size, content_digest = _member_digest(member)
            _update_directory_identity(digest, info.filename, size, content_digest)
    return digest.hexdigest()


def _write_directory_archive(source: Path, destination: Path) -> None:
    files = sorted(path for path in source.rglob("*") if path.is_file())
    with zipfile.ZipFile(
        destination,
        "w",
        compression=zipfile.ZIP_STORED,
        allowZip64=True,
    ) as archive:
        for path in files:
            relative = path.relative_to(source).as_posix()
            info = zipfile.ZipInfo(relative, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_STORED
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            with path.open("rb") as member, archive.open(
                info, "w", force_zip64=True
            ) as output:
                shutil.copyfileobj(member, output, length=HASH_CHUNK_BYTES)


def pie_archive(source: Path, cache_dir: Path) -> tuple[Path, bool]:
    source = source.expanduser().resolve()
    if source.is_file():
        if not zipfile.is_zipfile(source):
            raise ValueError(f"PIE input is not a zip archive: {source}")
        return source, True
    if not source.is_dir():
        raise ValueError(f"PIE input does not exist: {source}")

    fingerprint = directory_fingerprint(source)
    cache_dir.mkdir(parents=True, exist_ok=True)
    destination = cache_dir / f"{source.name}-{fingerprint}.zip"
    if destination.is_file() and zipfile.is_zipfile(destination):
        return destination, True

    temporary = destination.with_suffix(f".tmp-{os.getpid()}.zip")
    temporary.unlink(missing_ok=True)
    try:
        _write_directory_archive(source, temporary)
        if _archive_fingerprint(temporary) != fingerprint:
            raise ValueError(f"PIE directory changed while creating archive: {source}")
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)
    return destination, False


def validate_adapted_input(path: Path) -> None:
    with path.open("rb") as adapted:
        header = adapted.read(12)
    if len(header) != 12 or header[:8] != MAGIC:
        raise ValueError(f"adapter did not produce STWZCPI: {path}")
    if int.from_bytes(header[8:12], "little") != VERSION:
        raise ValueError(f"adapter produced unsupported STWZCPI version: {path}")


def execute(
    gpu_bench: Path,
    source: Path,
    destination: Path,
    cache_dir: Path,
    bootloader_json: Path | None,
    timeout_s: float,
) -> tuple[Path, bool]:
    archive, archive_cache_hit = pie_archive(source, cache_dir)
    destination = destination.expanduser().resolve()
    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary_name = tempfile.mkstemp(
        prefix=f".{destination.name}.", suffix=".tmp", dir=destination.parent
    )
    os.close(fd)
    temporary = Path(temporary_name)
    temporary.unlink()

    environment = os.environ.copy()
    environment["STWO_DUMP_STWZCPI"] = str(temporary)
    if bootloader_json is not None:
        environment["STWO_BOOTLOADER_JSON"] = str(bootloader_json.expanduser().resolve())
    command = [
        str(gpu_bench.expanduser().resolve()),
        "--pie",
        str(archive),
        "--backend",
        "simd",
        "--adapt-only",
        "--reps",
        "1",
    ]
    try:
        subprocess.run(command, env=environment, check=True, timeout=timeout_s)
        validate_adapted_input(temporary)
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)
    return archive, archive_cache_hit


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gpu-bench", type=Path, required=True)
    parser.add_argument("--bootloader-json", type=Path)
    parser.add_argument(
        "--archive-cache-dir",
        type=Path,
        default=Path("/private/tmp/stwo-zig-pie-archives"),
    )
    parser.add_argument("--timeout-s", type=float, default=1800.0)
    parser.add_argument("source_pie", type=Path)
    parser.add_argument("adapted_input", type=Path)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    if args.timeout_s <= 0:
        raise ValueError("--timeout-s must be positive")
    if not args.gpu_bench.is_file():
        raise ValueError(f"missing gpu_bench: {args.gpu_bench}")
    archive, cache_hit = execute(
        args.gpu_bench,
        args.source_pie,
        args.adapted_input,
        args.archive_cache_dir,
        args.bootloader_json,
        args.timeout_s,
    )
    print(
        f"adapted PIE archive={archive} archive_cache_hit={str(cache_hit).lower()} "
        f"output={args.adapted_input.expanduser().resolve()}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
