import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from scripts.riscv_release_bundle_lib import controller, model


DIGEST = "a" * 64
COMMIT = "b" * 40


def gate_report() -> dict[str, object]:
    commands = [
        "python scripts/riscv_staged_smoke.py --phase candidate",
        "zig build release-gate-strict -Doptimize=ReleaseFast",
        "python scripts/riscv_release_oracle.py build-and-compare",
        "python scripts/riscv_release_oracle.py validate",
        "python scripts/riscv_release_evidence.py",
    ]
    return {
        "schema": "riscv-release-gate-evidence-v1",
        "status": "PASS",
        "phase": "candidate",
        "candidate_commit": COMMIT,
        "git": {"head": COMMIT, "initial_porcelain": "", "final_porcelain": ""},
        "commands": [
            {"command_shell": command, "exit_code": 0, "skipped_tests": 0}
            for command in commands
        ],
    }


class ContentDomainTests(unittest.TestCase):
    def repository(self, root: Path) -> None:
        subprocess.run(["git", "init", "-q"], cwd=root, check=True)
        subprocess.run(["git", "config", "user.name", "Bundle Test"], cwd=root, check=True)
        subprocess.run(
            ["git", "config", "user.email", "bundle@example.invalid"], cwd=root, check=True,
        )

    def commit(self, root: Path, path: str, content: str) -> None:
        destination = root / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(content, encoding="utf-8")
        subprocess.run(["git", "add", path], cwd=root, check=True)
        subprocess.run(["git", "commit", "-qm", path], cwd=root, check=True)

    def test_domain_hashes_file_bytes_and_paths(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.repository(root)
            self.commit(root, "src/value", "one")
            first = model.tracked_domain(root, ("src",))
            self.commit(root, "src/value", "two")
            second = model.tracked_domain(root, ("src",))
            self.assertNotEqual(first["sha256"], second["sha256"])
            self.assertEqual(["src"], first["paths"])

    def test_clean_head_rejects_untracked_input(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.repository(root)
            self.commit(root, "tracked", "ok")
            head = model.git_output(root, "rev-parse", "HEAD")
            (root / "untracked").write_text("dirty", encoding="utf-8")
            with self.assertRaisesRegex(model.BundleError, "dirty"):
                model.require_clean_head(root, head)


class BundleContractTests(unittest.TestCase):
    def test_pack_does_not_delete_a_preexisting_output_directory(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "existing"
            output.mkdir()
            marker = output / "marker"
            marker.write_text("keep", encoding="utf-8")
            args = SimpleNamespace(
                root=root,
                evidence_dir=root / "evidence",
                output_dir=output,
                candidate=COMMIT,
            )
            with mock.patch.object(model, "require_clean_head", return_value="tree"):
                self.assertEqual(1, controller.pack(args))
            self.assertEqual("keep", marker.read_text(encoding="utf-8"))

    def test_gate_report_requires_every_exhaustive_subphase(self) -> None:
        report = gate_report()
        model.validate_gate_report(report, COMMIT, "candidate")
        report["commands"] = report["commands"][:-1]
        with self.assertRaisesRegex(model.BundleError, "riscv_release_evidence"):
            model.validate_gate_report(report, COMMIT, "candidate")

    def test_gate_report_rejects_skipped_tests(self) -> None:
        report = gate_report()
        report["commands"][0]["skipped_tests"] = 1
        with self.assertRaisesRegex(model.BundleError, "skipped"):
            model.validate_gate_report(report, COMMIT, "candidate")

    def test_file_manifest_rejects_byte_tampering_and_symlinks(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory)
            for relative in model.FILE_LAYOUT.values():
                path = bundle / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(relative.encode())
            manifest = {
                "files": {
                    name: model.file_record(bundle / relative)
                    for name, relative in model.FILE_LAYOUT.items()
                }
            }
            model.validate_files(bundle, manifest)
            (bundle / "bin/stwo-zig").write_bytes(b"tampered")
            with self.assertRaisesRegex(model.BundleError, "digest"):
                model.validate_files(bundle, manifest)

            executable = bundle / "bin/stwo-zig"
            executable.unlink()
            os.symlink(bundle / "release-gate.json", executable)
            manifest["files"]["bin/stwo-zig"] = model.file_record(executable)
            with self.assertRaisesRegex(model.BundleError, "regular"):
                model.validate_files(bundle, manifest)

    def test_cli_summary_is_bound_to_phase_commit_and_executable(self) -> None:
        summary = {
            "schema": "riscv_cli_evidence_v1",
            "phase": "candidate",
            "release_status": "not_release_gated",
            "implementation_commit": COMMIT,
            "implementation_dirty": False,
            "executable_sha256": DIGEST,
            "multi_shard_addi_rows": 65_537,
            "total_steps": 131_078,
            "artifact_sha256": DIGEST,
            "benchmark_artifact_sha256": DIGEST,
            "benchmark_report_sha256": DIGEST,
            "verify_receipt_sha256": DIGEST,
            "benchmark_verify_receipt_sha256": DIGEST,
            "independent_verify_returncode": 0,
            "tamper_returncode": 1,
            "proof_wire_mutation_returncodes": {
                name: {"returncode": 1}
                for name in ("trailing", "truncated", "length-bomb")
            },
            "hostile_artifact_results": {
                name: {"returncode": 1}
                for name in (
                    "corrupt-json", "legacy-schema-v2", "duplicate-header", "unknown-field",
                    "omitted-claim", "release-relabel",
                )
            },
            "boundary_rejection_results": {"phase-admission": {"returncode": 1}},
        }
        model.validate_cli_summary(summary, COMMIT, "candidate", DIGEST)
        summary["implementation_commit"] = "c" * 40
        with self.assertRaisesRegex(model.BundleError, "identity"):
            model.validate_cli_summary(summary, COMMIT, "candidate", DIGEST)

    def test_strict_json_rejects_duplicate_fields(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "duplicate.json"
            path.write_text('{"phase":"candidate","phase":"promoted"}', encoding="utf-8")
            with self.assertRaisesRegex(model.BundleError, "duplicate"):
                model.strict_json(path)


if __name__ == "__main__":
    unittest.main()
