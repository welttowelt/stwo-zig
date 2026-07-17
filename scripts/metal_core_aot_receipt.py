#!/usr/bin/env python3
"""Build twice and record authenticated Native Metal core acceptance evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
SCHEMA = "stwo_zig_metal_core_aot_acceptance_v1"
FORMAT = "stwo-zig-metal-core-aot-v2"
MANIFEST = "stwo_zig_core.manifest.json"
ANCHOR = "stwo_zig_core.manifest.sha256"
FILES = (
    "stwo_zig_core.metal",
    "stwo_zig_core.air",
    "stwo_zig_core.metallib",
    MANIFEST,
    ANCHOR,
)


class ReceiptError(RuntimeError):
    pass


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def measure(path: Path) -> dict[str, Any]:
    data = path.read_bytes()
    if not data:
        raise ReceiptError(f"empty AOT artifact: {path}")
    return {"bytes": len(data), "sha256": sha256_bytes(data)}


def load_bundle(path: Path) -> dict[str, Any]:
    path = path.resolve()
    measurements = {name: measure(path / name) for name in FILES}
    manifest_bytes = (path / MANIFEST).read_bytes()
    try:
        manifest = json.loads(manifest_bytes)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ReceiptError(f"invalid AOT manifest: {path / MANIFEST}: {error}") from error
    if not isinstance(manifest, dict) or manifest.get("format") != FORMAT:
        raise ReceiptError("AOT manifest format mismatch")
    if manifest.get("toolchain") is None:
        raise ReceiptError("built AOT manifest is missing toolchain identity")

    source = manifest.get("source")
    artifacts = manifest.get("artifacts")
    if not isinstance(source, dict) or not isinstance(artifacts, dict):
        raise ReceiptError("AOT manifest is missing source or artifact identity")
    declared = {
        "stwo_zig_core.metal": source,
        "stwo_zig_core.air": artifacts.get("air"),
        "stwo_zig_core.metallib": artifacts.get("metallib"),
    }
    for filename, identity in declared.items():
        if not isinstance(identity, dict) or identity.get("path") != filename:
            raise ReceiptError(f"AOT manifest path mismatch for {filename}")
        actual = measurements[filename]
        if identity.get("sha256") != actual["sha256"] or identity.get("bytes") != actual["bytes"]:
            raise ReceiptError(f"AOT manifest measurement mismatch for {filename}")

    expected_anchor = f"{measurements[MANIFEST]['sha256']}  {MANIFEST}\n".encode()
    if (path / ANCHOR).read_bytes() != expected_anchor:
        raise ReceiptError("AOT manifest trust anchor mismatch")
    return {
        "path": str(path),
        "files": measurements,
        "manifest": manifest,
    }


def require_reproducible(first: dict[str, Any], second: dict[str, Any]) -> None:
    for filename in FILES:
        if first["files"][filename] != second["files"][filename]:
            raise ReceiptError(f"independent AOT builds differ: {filename}")


def run(command: list[str], *, cwd: Path = ROOT) -> dict[str, Any]:
    completed = subprocess.run(command, cwd=cwd, text=True, capture_output=True, check=False)
    evidence = {
        "argv": command,
        "returncode": completed.returncode,
        "stdout_sha256": sha256_bytes(completed.stdout.encode()),
        "stderr_sha256": sha256_bytes(completed.stderr.encode()),
    }
    if completed.returncode != 0:
        if completed.stdout:
            print(completed.stdout, end="", file=sys.stderr)
        if completed.stderr:
            print(completed.stderr, end="", file=sys.stderr)
        raise ReceiptError(f"acceptance command failed: {command}")
    return evidence


def command_output(command: list[str]) -> str:
    try:
        completed = subprocess.run(command, text=True, capture_output=True, check=False)
    except OSError:
        return "unavailable"
    if completed.returncode != 0:
        return "unavailable"
    return (completed.stdout or completed.stderr).strip() or "unavailable"


def executable_identity(path: Path) -> dict[str, Any]:
    resolved = path.resolve(strict=True)
    result = measure(resolved)
    result["path"] = str(resolved)
    return result


def write_receipt(path: Path, receipt: dict[str, Any]) -> str:
    encoded = (json.dumps(receipt, indent=2, sort_keys=True) + "\n").encode()
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_bytes(encoded)
    temporary.replace(path)
    digest = sha256_bytes(encoded)
    path.with_suffix(path.suffix + ".sha256").write_text(
        f"{digest}  {path.name}\n",
        encoding="utf-8",
    )
    return digest


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--builder", type=Path, required=True)
    parser.add_argument("--probe", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--receipt-out", type=Path, required=True)
    parser.add_argument("--commit", default=None)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    output_dir = args.output_dir.resolve()
    if output_dir.exists():
        shutil.rmtree(output_dir)
    output_dir.mkdir(parents=True)
    builder = args.builder.resolve(strict=True)
    probe = args.probe.resolve(strict=True)
    commit = args.commit or command_output(["git", "rev-parse", "HEAD"])
    if len(commit) != 40:
        raise ReceiptError("acceptance receipt requires an exact 40-character commit")

    commands: list[dict[str, Any]] = []
    bundles: list[dict[str, Any]] = []
    for name in ("build-a", "build-b"):
        bundle = output_dir / name
        commands.append(run([str(builder), "build", "--output-dir", str(bundle)]))
        commands.append(
            run(
                [
                    str(probe),
                    "--bundle-dir",
                    str(bundle),
                    "--trust-anchor",
                    str(bundle / ANCHOR),
                ]
            )
        )
        bundles.append(load_bundle(bundle))
    require_reproducible(bundles[0], bundles[1])

    receipt = {
        "schema": SCHEMA,
        "repository_commit": commit,
        "build_mode": "ReleaseSafe",
        "checks": {
            "authenticated_bundle_admission": True,
            "aot_jit_transcript_output_parity": True,
            "exact_export_set_and_function_constants": True,
            "independent_builds_byte_identical": True,
        },
        "executables": {
            "builder": executable_identity(builder),
            "probe": executable_identity(probe),
        },
        "commands": commands,
        "bundle": {
            "files": bundles[0]["files"],
            "manifest": bundles[0]["manifest"],
        },
        "host": {
            "platform": platform.platform(),
            "macos": command_output(["sw_vers"]),
            "machine": platform.machine(),
            "device": command_output(
                ["system_profiler", "SPDisplaysDataType", "-json", "-detailLevel", "mini"]
            ),
        },
        "ci": {
            key: os.environ.get(key)
            for key in ("GITHUB_ACTIONS", "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_JOB")
        },
    }
    digest = write_receipt(args.receipt_out.resolve(), receipt)
    print(f"Native Metal core AOT acceptance receipt: {digest}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ReceiptError) as error:
        print(f"metal core AOT acceptance failed: {error}", file=sys.stderr)
        raise SystemExit(2)
