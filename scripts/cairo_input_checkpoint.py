#!/usr/bin/env python3
"""Inspect or deterministically regenerate a content-addressed STWZCPI fixture."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
from typing import BinaryIO


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = ROOT / "vectors/cairo/checkpoints/fib_25000_stwzcpi.json"
MAGIC = b"STWZCPI\0"
OPCODE_NAMES = (
    "generic_opcode",
    "add_ap_opcode",
    "add_opcode",
    "add_opcode_small",
    "assert_eq_opcode",
    "assert_eq_opcode_double_deref",
    "assert_eq_opcode_imm",
    "call_opcode_abs",
    "call_opcode_rel_imm",
    "jnz_opcode_non_taken",
    "jnz_opcode_taken",
    "jump_opcode_rel_imm",
    "jump_opcode_rel",
    "jump_opcode_double_deref",
    "jump_opcode_abs",
    "mul_opcode_small",
    "mul_opcode",
    "ret_opcode",
    "blake_compress_opcode",
    "qm_31_add_mul_opcode",
)
BUILTIN_NAMES = (
    "add_mod_builtin",
    "bitwise_builtin",
    "output",
    "mul_mod_builtin",
    "pedersen_builtin",
    "poseidon_builtin",
    "range_check96_builtin",
    "range_check_builtin",
    "ec_op_builtin",
)


class FixtureError(ValueError):
    """The fixture, its provenance, or its encoded artifact is invalid."""


class Cursor:
    def __init__(self, stream: BinaryIO, size: int) -> None:
        self.stream = stream
        self.size = size
        self.offset = 0

    def read(self, length: int) -> bytes:
        if length < 0 or self.offset + length > self.size:
            raise FixtureError(f"truncated STWZCPI at byte {self.offset}")
        value = self.stream.read(length)
        if len(value) != length:
            raise FixtureError(f"truncated STWZCPI at byte {self.offset}")
        self.offset += length
        return value

    def skip(self, length: int) -> None:
        if length < 0 or self.offset + length > self.size:
            raise FixtureError(f"truncated STWZCPI at byte {self.offset}")
        self.stream.seek(length, os.SEEK_CUR)
        self.offset += length

    def integer(self, encoding: str) -> int:
        return struct.unpack("<" + encoding, self.read(struct.calcsize(encoding)))[0]


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _state(cursor: Cursor) -> list[int]:
    return [cursor.integer("I") for _ in range(3)]


def inspect_stwzcpi(path: Path) -> dict[str, object]:
    size = path.stat().st_size
    with path.open("rb") as stream:
        cursor = Cursor(stream, size)
        if cursor.read(len(MAGIC)) != MAGIC:
            raise FixtureError("invalid STWZCPI magic")
        version = cursor.integer("I")
        flags = cursor.integer("I")
        initial_state = _state(cursor)
        final_state = _state(cursor)
        pc_count = cursor.integer("Q")
        public_segment_mask = cursor.integer("H")
        reserved = [cursor.integer("H"), cursor.integer("I")]
        opcode_count = cursor.integer("I")
        reserved.append(cursor.integer("I"))
        if version != 1:
            raise FixtureError(f"unsupported STWZCPI version {version}")
        if flags != 0 or any(reserved):
            raise FixtureError("STWZCPI flags and reserved header fields must be zero")
        if opcode_count != len(OPCODE_NAMES):
            raise FixtureError(f"expected {len(OPCODE_NAMES)} opcode columns, got {opcode_count}")

        opcode_counts: dict[str, int] = {}
        for name in OPCODE_NAMES:
            count = cursor.integer("Q")
            opcode_counts[name] = count
            cursor.skip(count * 12)

        small_max = cursor.integer("Q") | cursor.integer("Q") << 64
        log_small_value_capacity = cursor.integer("I")
        if cursor.integer("I") != 0:
            raise FixtureError("STWZCPI memory reserved field must be zero")
        address_count = cursor.integer("Q")
        big_value_count = cursor.integer("Q")
        small_value_count = cursor.integer("Q")
        cursor.skip(address_count * 4)
        cursor.skip(big_value_count * 8 * 4)
        cursor.skip(small_value_count * 16)

        public_count = cursor.integer("Q")
        public_encoded = cursor.read(public_count * 4)
        public_addresses = list(struct.unpack(f"<{public_count}I", public_encoded))
        if public_addresses != sorted(set(public_addresses)):
            raise FixtureError("public memory addresses must be sorted and unique")

        builtin_segments: dict[str, dict[str, int] | None] = {}
        for name in BUILTIN_NAMES:
            present = cursor.integer("B")
            if cursor.read(7) != bytes(7):
                raise FixtureError(f"{name} segment padding must be zero")
            begin = cursor.integer("Q")
            stop = cursor.integer("Q")
            if present not in (0, 1):
                raise FixtureError(f"{name} segment presence must be boolean")
            if present == 0 and (begin != 0 or stop != 0):
                raise FixtureError(f"absent {name} segment must have zero bounds")
            builtin_segments[name] = None if present == 0 else {"begin": begin, "stop": stop}
        if cursor.offset != size:
            raise FixtureError(f"trailing STWZCPI data at byte {cursor.offset}")

    return {
        "version": version,
        "flags": flags,
        "initial_state": initial_state,
        "final_state": final_state,
        "pc_count": pc_count,
        "public_segment_mask": public_segment_mask,
        "opcode_counts": opcode_counts,
        "cycle_count": sum(opcode_counts.values()),
        "memory": {
            "small_max": str(small_max),
            "log_small_value_capacity": log_small_value_capacity,
            "address_count": address_count,
            "big_value_count": big_value_count,
            "small_value_count": small_value_count,
        },
        "public_memory": {
            "count": public_count,
            "sha256_le_u32": hashlib.sha256(public_encoded).hexdigest(),
        },
        "builtin_segments": builtin_segments,
    }


def load_manifest(path: Path) -> dict[str, object]:
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise FixtureError(f"cannot read fixture manifest {path}: {error}") from error
    if not isinstance(value, dict) or value.get("schema_version") != 1:
        raise FixtureError("fixture manifest must use schema_version 1")
    if value.get("fixture_kind") != "cairo-adapted-input-checkpoint":
        raise FixtureError("unexpected fixture_kind")
    for field in ("case", "oracle", "source", "generator", "artifact", "checkpoint"):
        if not isinstance(value.get(field), dict):
            raise FixtureError(f"fixture manifest requires object field {field}")
    artifact = value["artifact"]
    if artifact.get("format") != "STWZCPI/1":
        raise FixtureError("fixture artifact must use STWZCPI/1")
    digest = artifact.get("sha256")
    if not isinstance(digest, str) or len(digest) != 64:
        raise FixtureError("fixture artifact requires a SHA-256 digest")
    return value


def _first_difference(actual: object, expected: object, path: str = "checkpoint") -> str | None:
    if isinstance(actual, dict) and isinstance(expected, dict):
        if actual.keys() != expected.keys():
            return f"{path} keys: expected {sorted(expected)}, got {sorted(actual)}"
        for key in expected:
            difference = _first_difference(actual[key], expected[key], f"{path}.{key}")
            if difference:
                return difference
        return None
    if actual != expected:
        return f"{path}: expected {expected!r}, got {actual!r}"
    return None


def validate_artifact(manifest: dict[str, object], input_path: Path) -> dict[str, object]:
    artifact = manifest["artifact"]
    expected_size = artifact.get("bytes")
    if input_path.stat().st_size != expected_size:
        raise FixtureError(
            f"artifact size mismatch: expected {expected_size}, got {input_path.stat().st_size}"
        )
    digest = sha256_file(input_path)
    if digest != artifact["sha256"]:
        raise FixtureError(f"artifact SHA-256 mismatch: expected {artifact['sha256']}, got {digest}")
    checkpoint = inspect_stwzcpi(input_path)
    difference = _first_difference(checkpoint, manifest["checkpoint"])
    if difference:
        raise FixtureError(difference)
    expected_cycles = manifest["case"].get("expected_cycles")
    if checkpoint["cycle_count"] != expected_cycles:
        raise FixtureError("case expected_cycles does not match its STWZCPI checkpoint")
    return {
        "status": "accepted",
        "fixture_id": manifest.get("fixture_id"),
        "input": str(input_path.resolve()),
        "sha256": digest,
        "bytes": input_path.stat().st_size,
        "checkpoint": checkpoint,
    }


def _require_file_digest(path: Path, expected: object, label: str) -> None:
    actual = sha256_file(path)
    if not isinstance(expected, str) or actual != expected:
        raise FixtureError(f"{label} SHA-256 mismatch: expected {expected}, got {actual}")


def generate_artifact(args: argparse.Namespace, manifest: dict[str, object]) -> dict[str, object]:
    source = manifest["source"]
    generator = manifest["generator"]
    _require_file_digest(args.program, source.get("program_sha256"), "Cairo program")
    _require_file_digest(args.generator_source, generator.get("source_sha256"), "generator source")
    _require_file_digest(args.cargo_lock, generator.get("cargo_lock_sha256"), "Cargo.lock")
    _require_file_digest(args.gpu_bench, generator.get("binary_sha256"), "gpu_bench")
    revision = subprocess.run(
        ["git", "-C", str(args.stwo_cairo_root), "rev-parse", "HEAD"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()
    if revision != manifest["oracle"].get("stwo_cairo_revision"):
        raise FixtureError(f"Stwo-Cairo revision mismatch: expected pin, got {revision}")

    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(f".{output.name}.part-{os.getpid()}")
    temporary.unlink(missing_ok=True)
    command = [
        str(args.gpu_bench.resolve()),
        "--program",
        str(args.program.resolve()),
        *[str(value) for value in generator.get("arguments", [])],
    ]
    environment = {key: value for key, value in os.environ.items() if not key.startswith("STWO_")}
    environment["STWO_DUMP_STWZCPI"] = str(temporary)
    try:
        completed = subprocess.run(
            command,
            cwd=args.stwo_cairo_root,
            env=environment,
            capture_output=True,
            text=True,
            timeout=args.timeout,
            check=False,
        )
        if completed.returncode != 0:
            raise FixtureError(
                f"gpu_bench exited {completed.returncode}: {(completed.stdout + completed.stderr)[-2000:]}"
            )
        result = validate_artifact(manifest, temporary)
        os.replace(temporary, output)
    finally:
        temporary.unlink(missing_ok=True)
    result["input"] = str(output)
    result["command"] = command
    return result


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="operation", required=True)
    validate = subparsers.add_parser("validate", help="authenticate and inspect an existing input")
    validate.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    validate.add_argument("--input", type=Path, required=True)
    generate = subparsers.add_parser("generate", help="regenerate and atomically publish the input")
    generate.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    generate.add_argument("--gpu-bench", type=Path, required=True)
    generate.add_argument("--program", type=Path, required=True)
    generate.add_argument("--generator-source", type=Path, required=True)
    generate.add_argument("--cargo-lock", type=Path, required=True)
    generate.add_argument("--stwo-cairo-root", type=Path, required=True)
    generate.add_argument("--output", type=Path, required=True)
    generate.add_argument("--timeout", type=float, default=60.0)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        manifest = load_manifest(args.manifest)
        result = (
            validate_artifact(manifest, args.input)
            if args.operation == "validate"
            else generate_artifact(args, manifest)
        )
    except (FixtureError, OSError, subprocess.SubprocessError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
