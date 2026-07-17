import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from scripts.metal_core_aot_receipt import (
    ANCHOR,
    FILES,
    FORMAT,
    MANIFEST,
    ReceiptError,
    load_bundle,
    require_reproducible,
    write_receipt,
)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_bundle(path: Path, *, metallib: bytes = b"metallib") -> None:
    source = b"kernel source"
    air = b"compiled air"
    manifest = {
        "format": FORMAT,
        "toolchain": {"xcode_version": "16.0"},
        "source": {
            "path": "stwo_zig_core.metal",
            "sha256": digest(source),
            "bytes": len(source),
        },
        "artifacts": {
            "air": {
                "path": "stwo_zig_core.air",
                "sha256": digest(air),
                "bytes": len(air),
            },
            "metallib": {
                "path": "stwo_zig_core.metallib",
                "sha256": digest(metallib),
                "bytes": len(metallib),
            },
        },
    }
    path.mkdir()
    (path / "stwo_zig_core.metal").write_bytes(source)
    (path / "stwo_zig_core.air").write_bytes(air)
    (path / "stwo_zig_core.metallib").write_bytes(metallib)
    encoded = (json.dumps(manifest, sort_keys=True) + "\n").encode()
    (path / MANIFEST).write_bytes(encoded)
    (path / ANCHOR).write_text(f"{digest(encoded)}  {MANIFEST}\n", encoding="utf-8")


class MetalCoreAotReceiptTests(unittest.TestCase):
    def test_bundle_validation_and_reproducibility_bind_every_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_bundle(root / "first")
            write_bundle(root / "second")
            first = load_bundle(root / "first")
            second = load_bundle(root / "second")
            require_reproducible(first, second)
            self.assertEqual(set(FILES), set(first["files"]))

    def test_independent_build_drift_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_bundle(root / "first")
            write_bundle(root / "second", metallib=b"different metallib")
            with self.assertRaisesRegex(ReceiptError, "independent AOT builds differ"):
                require_reproducible(load_bundle(root / "first"), load_bundle(root / "second"))

    def test_manifest_measurement_and_anchor_drift_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "bundle"
            write_bundle(root)
            (root / "stwo_zig_core.air").write_bytes(b"mutated")
            with self.assertRaisesRegex(ReceiptError, "measurement mismatch"):
                load_bundle(root)

            write_bundle_root = Path(temporary) / "anchor"
            write_bundle(write_bundle_root)
            (write_bundle_root / ANCHOR).write_text("0" * 64 + f"  {MANIFEST}\n")
            with self.assertRaisesRegex(ReceiptError, "trust anchor mismatch"):
                load_bundle(write_bundle_root)

    def test_receipt_write_is_canonical_and_hashes_exact_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "receipt.json"
            receipt = {"z": 1, "a": {"accepted": True}}
            recorded = write_receipt(path, receipt)
            self.assertEqual(recorded, digest(path.read_bytes()))
            self.assertEqual(
                f"{recorded}  receipt.json\n",
                path.with_suffix(".json.sha256").read_text(encoding="utf-8"),
            )


if __name__ == "__main__":
    unittest.main()
