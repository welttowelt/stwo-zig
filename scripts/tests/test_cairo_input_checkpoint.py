from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "scripts/cairo_input_checkpoint.py"
SPEC = importlib.util.spec_from_file_location("cairo_input_checkpoint", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
checkpoint = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checkpoint)


def synthetic_input(public_addresses: tuple[int, ...] = (3, 7)) -> bytes:
    encoded = bytearray(checkpoint.MAGIC)
    encoded.extend(struct.pack("<II", 1, 0))
    encoded.extend(struct.pack("<III", 1, 2, 3))
    encoded.extend(struct.pack("<III", 4, 5, 6))
    encoded.extend(struct.pack("<QHHIII", 2, 0, 0, 0, len(checkpoint.OPCODE_NAMES), 0))
    for index in range(len(checkpoint.OPCODE_NAMES)):
        count = 1 if index == 1 else 0
        encoded.extend(struct.pack("<Q", count))
        if count:
            encoded.extend(struct.pack("<III", 10, 11, 12))
    encoded.extend(struct.pack("<QQIIQQQ", 7, 0, 8, 0, 0, 0, 0))
    encoded.extend(struct.pack("<Q", len(public_addresses)))
    encoded.extend(struct.pack(f"<{len(public_addresses)}I", *public_addresses))
    for _ in checkpoint.BUILTIN_NAMES:
        encoded.extend(struct.pack("<B7xQQ", 0, 0, 0))
    return bytes(encoded)


def fixture_manifest(input_path: Path) -> dict[str, object]:
    inspected = checkpoint.inspect_stwzcpi(input_path)
    return {
        "schema_version": 1,
        "fixture_kind": "cairo-adapted-input-checkpoint",
        "fixture_id": "test/synthetic",
        "case": {"expected_cycles": inspected["cycle_count"]},
        "oracle": {"stwo_cairo_revision": "unused"},
        "source": {},
        "generator": {},
        "artifact": {
            "format": "STWZCPI/1",
            "sha256": checkpoint.sha256_file(input_path),
            "bytes": input_path.stat().st_size,
        },
        "checkpoint": inspected,
    }


class CairoInputCheckpointTests(unittest.TestCase):
    def test_checked_in_manifest_is_bound_to_fib25k(self) -> None:
        manifest = checkpoint.load_manifest(checkpoint.DEFAULT_MANIFEST)
        self.assertEqual(manifest["case"]["expected_cycles"], 175016)
        self.assertEqual(manifest["checkpoint"]["cycle_count"], 175016)
        self.assertEqual(
            manifest["artifact"]["sha256"],
            "3e5f076f30efbf9f295803ac7198750879267ba78d1e98c820742de08255e366",
        )
        self.assertEqual(manifest["oracle"]["stwo_cairo_revision"], "dcd5834565b7a26a27a614e353c9c60109ebc1d9")

    def test_inspector_accepts_canonical_structure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "input.stwzcpi"
            path.write_bytes(synthetic_input())
            value = checkpoint.inspect_stwzcpi(path)
        self.assertEqual(value["cycle_count"], 1)
        self.assertEqual(value["opcode_counts"]["add_ap_opcode"], 1)
        self.assertEqual(value["public_memory"]["count"], 2)

    def test_inspector_rejects_truncation_trailing_and_noncanonical_public_memory(self) -> None:
        cases = {
            "truncated": synthetic_input()[:-1],
            "trailing": synthetic_input() + b"x",
            "unsorted": synthetic_input((7, 3)),
            "duplicate": synthetic_input((3, 3)),
        }
        with tempfile.TemporaryDirectory() as directory:
            for name, encoded in cases.items():
                with self.subTest(name=name):
                    path = Path(directory) / f"{name}.stwzcpi"
                    path.write_bytes(encoded)
                    with self.assertRaises(checkpoint.FixtureError):
                        checkpoint.inspect_stwzcpi(path)

    def test_artifact_validation_rejects_same_size_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "input.stwzcpi"
            path.write_bytes(synthetic_input())
            manifest = fixture_manifest(path)
            self.assertEqual(checkpoint.validate_artifact(manifest, path)["status"], "accepted")
            mutated = bytearray(path.read_bytes())
            mutated[-1] ^= 1
            path.write_bytes(mutated)
            with self.assertRaisesRegex(checkpoint.FixtureError, "SHA-256 mismatch"):
                checkpoint.validate_artifact(manifest, path)

    def test_generator_authenticates_sources_and_publishes_atomically(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_input = root / "source.stwzcpi"
            source_input.write_bytes(synthetic_input())
            program = root / "compiled.json"
            cargo_lock = root / "Cargo.lock"
            program.write_text("program")
            cargo_lock.write_text("lock")
            fake = root / "gpu_bench"
            fake.write_text(
                "#!/usr/bin/env python3\n"
                "import os, shutil\n"
                "shutil.copyfile(os.environ['FAKE_STWZCPI'], os.environ['STWO_DUMP_STWZCPI'])\n"
            )
            fake.chmod(0o755)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            subprocess.run(["git", "-C", str(root), "config", "user.email", "test@example.com"], check=True)
            subprocess.run(["git", "-C", str(root), "config", "user.name", "Test"], check=True)
            subprocess.run(["git", "-C", str(root), "add", "Cargo.lock", "compiled.json", "gpu_bench"], check=True)
            subprocess.run(["git", "-C", str(root), "commit", "-qm", "fixture"], check=True)
            revision = subprocess.run(
                ["git", "-C", str(root), "rev-parse", "HEAD"],
                capture_output=True,
                text=True,
                check=True,
            ).stdout.strip()

            manifest = fixture_manifest(source_input)
            manifest["oracle"] = {"stwo_cairo_revision": revision}
            manifest["source"] = {"program_sha256": checkpoint.sha256_file(program)}
            manifest["generator"] = {
                "source_sha256": checkpoint.sha256_file(fake),
                "cargo_lock_sha256": checkpoint.sha256_file(cargo_lock),
                "binary_sha256": checkpoint.sha256_file(fake),
                "arguments": [],
            }
            output = root / "published" / "input.stwzcpi"
            args = argparse.Namespace(
                program=program,
                generator_source=fake,
                cargo_lock=cargo_lock,
                gpu_bench=fake,
                stwo_cairo_root=root,
                output=output,
                timeout=10.0,
            )
            previous = os.environ.get("FAKE_STWZCPI")
            os.environ["FAKE_STWZCPI"] = str(source_input)
            try:
                result = checkpoint.generate_artifact(args, manifest)
            finally:
                if previous is None:
                    os.environ.pop("FAKE_STWZCPI", None)
                else:
                    os.environ["FAKE_STWZCPI"] = previous
            self.assertEqual(result["status"], "accepted")
            self.assertEqual(output.read_bytes(), source_input.read_bytes())
            self.assertEqual(list(output.parent.glob("*.part-*")), [])


if __name__ == "__main__":
    unittest.main()
