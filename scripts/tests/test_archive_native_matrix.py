import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from scripts.archive_native_matrix import ArchiveError, build_manifest, publish_bundle


def digest(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def write_matrix(path: Path) -> Path:
    row = path / "row"
    row.mkdir(parents=True)
    lanes = {}
    for lane in ("cpu", "metal"):
        stdout = row / f"{lane}.stdout.json"
        stderr = row / f"{lane}.stderr.txt"
        proof = row / f"{lane}.proof.json"
        stdout.write_text(json.dumps({"backend": lane}) + "\n", encoding="utf-8")
        stderr.write_bytes(b"stderr\n")
        proof.write_text(json.dumps({"proof_bytes_hex": "00"}) + "\n", encoding="utf-8")
        lanes[lane] = {
            "stdout_artifact": f"row/{lane}.stdout.json",
            "stdout_sha256": digest(stdout.read_bytes()),
            "stderr_artifact": f"row/{lane}.stderr.txt",
            "stderr_sha256": digest(stderr.read_bytes()),
            "proof_artifact": {
                "path": f"row/{lane}.proof.json",
                "sha256": digest(proof.read_bytes()),
            },
        }
    summary = {
        "protocol": "native_proof_cross_backend_matrix_v4",
        "schema_version": 4,
        "configuration": {"provenance": {"git_commit": "a" * 40}},
        "rows": [{"lanes": lanes}],
    }
    report = path / "summary.json"
    report.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return report


class ArchiveNativeMatrixTests(unittest.TestCase):
    def test_publishes_exact_tree_and_is_idempotent(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            report = write_matrix(root / "matrix")
            first = publish_bundle(root / "matrix", root / "archive", report)
            second = publish_bundle(root / "matrix", root / "archive", report)
            self.assertEqual(first, second)
            self.assertEqual(6, first["artifact_files"])
            bundle = root / "archive" / first["path"]
            self.assertEqual(report.read_bytes(), (bundle / "summary.json").read_bytes())
            self.assertTrue((bundle / "tree/row/metal.proof.json").is_file())

    def test_rejects_artifact_and_report_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            report = write_matrix(root / "matrix")
            (root / "matrix/row/cpu.stdout.json").write_text("mutated\n")
            with self.assertRaisesRegex(ArchiveError, "digest mismatch"):
                build_manifest(root / "matrix", report)

            report = write_matrix(root / "other")
            immutable = root / "immutable.json"
            immutable.write_text("{}\n")
            with self.assertRaisesRegex(ArchiveError, "differs"):
                build_manifest(root / "other", immutable)

    def test_rejects_path_traversal(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            report = write_matrix(root / "matrix")
            summary = json.loads(report.read_text())
            summary["rows"][0]["lanes"]["cpu"]["stdout_artifact"] = "../escape"
            report.write_text(json.dumps(summary) + "\n")
            with self.assertRaisesRegex(ArchiveError, "safe relative path"):
                build_manifest(root / "matrix", None)


if __name__ == "__main__":
    unittest.main()
