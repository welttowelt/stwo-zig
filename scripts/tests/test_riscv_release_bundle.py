import json
import os
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from scripts import riscv_release_policy
from scripts.riscv_release_bundle_lib import controller, model


DIGEST = "a" * 64
COMMIT = "b" * 40
TREE = "c" * 40


def gate_report() -> dict[str, object]:
    python = "/python"
    receipt = "/evidence/oracle-receipt.json"
    commands = [
        ["zig", "fmt", "--check", "build.zig", "src", "tools"],
        [python, "scripts/check_upstream_pins.py"],
        [python, "scripts/check_source_conformance.py"],
        [python, "scripts/check_riscv_release_contract.py", "--all", "--phase", "candidate"],
        [python, "scripts/check_riscv_release_contract.py", "--structure"],
        [python, "scripts/check_riscv_release_contract.py", "--core-purity"],
        [python, "scripts/check_riscv_release_contract.py", "--frontend-layering"],
        [python, "-m", "unittest", "discover", "-s", "scripts/tests", "-p", "test_*.py"],
        [
            python, "scripts/riscv_staged_smoke.py", "--phase", "candidate",
            "--evidence-dir", "/evidence/cli",
        ],
        ["zig", "build", "release-gate-strict", "-Doptimize=ReleaseFast"],
        [
            python, "scripts/riscv_release_oracle.py", "build-and-compare",
            "--stark-v-source", "/oracle", "--candidate", COMMIT,
            "--receipt-out", receipt,
        ],
        [python, "scripts/riscv_release_oracle.py", "validate", "--receipt", receipt],
        [
            python, "scripts/riscv_release_evidence.py", "--receipt", receipt,
            "--candidate", COMMIT,
        ],
    ]
    return {
        "schema": "riscv-release-gate-evidence-v1",
        "status": "PASS",
        "phase": "candidate",
        "candidate_commit": COMMIT,
        "host": {"system": "Linux"},
        "git": {"head": COMMIT, "initial_porcelain": "", "final_porcelain": ""},
        "commands": [
            {
                "command": command,
                "command_shell": shlex.join(command),
                "exit_code": 0,
                "skipped_tests": 0,
            }
            for command in commands
        ],
    }


def trust_context() -> dict[str, object]:
    repository = model.TRUSTED_REPOSITORY
    run_id = 123
    attempt = 2
    return {
        "schema": "riscv-release-producer-trust-v1",
        "trust_root": "repository-owner-dispatch",
        "repository": {"full_name": repository, "id": model.TRUSTED_REPOSITORY_ID},
        "candidate": {
            "sha": COMMIT,
            "tree_oid": TREE,
            "source_repository": repository,
            "source_repository_id": model.TRUSTED_REPOSITORY_ID,
            "source_ref": "refs/heads/candidate",
        },
        "workflow": {
            "path": ".github/workflows/ci.yml",
            "repository": repository,
            "repository_id": model.TRUSTED_REPOSITORY_ID,
            "ref": "refs/heads/main",
            "commit_sha": "d" * 40,
        },
        "workflow_base": {"ref": "refs/heads/main", "sha": "d" * 40},
        "event": "workflow_dispatch",
        "run": {"id": run_id, "attempt": attempt},
        "actor": {"login": "teddyjfpender", "id": model.TRUSTED_OWNER_ID},
        "triggering_actor": {"login": "teddyjfpender", "id": model.TRUSTED_OWNER_ID},
        "phase": "candidate",
        "artifact": {
            "name": f"riscv-exhaustive-bundle-{COMMIT}-{run_id}-{attempt}",
            "retention_days": 30,
        },
    }


def policy_context() -> dict[str, object]:
    return {
        "schema": "riscv-release-policy-match-v1",
        "trusted_workflow_commit": "d" * 40,
        "candidate_commit": COMMIT,
        "domain": {
            "schema": "riscv-release-policy-domain-v1",
            "sha256": DIGEST,
            "file_count": 100,
            "paths": model.RELEASE_POLICY_PATHS,
        },
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
    def test_release_policy_binds_trusted_workflow_candidate_and_domain(self) -> None:
        self.assertEqual(
            model.RELEASE_POLICY_PATHS, list(riscv_release_policy.POLICY_PATHS),
        )
        policy = policy_context()
        model.validate_policy_context(
            policy, candidate=COMMIT, workflow_commit="d" * 40,
        )
        for field, value, diagnostic in (
            ("trusted_workflow_commit", "e" * 40, "workflow"),
            ("candidate_commit", "e" * 40, "candidate"),
        ):
            drifted = json.loads(json.dumps(policy))
            drifted[field] = value
            with self.subTest(field=field), self.assertRaisesRegex(
                model.BundleError, diagnostic,
            ):
                model.validate_policy_context(
                    drifted, candidate=COMMIT, workflow_commit="d" * 40,
                )
        policy["domain"]["paths"] = model.RELEASE_POLICY_PATHS[:-1]
        with self.assertRaisesRegex(model.BundleError, "paths"):
            model.validate_policy_context(
                policy, candidate=COMMIT, workflow_commit="d" * 40,
            )

    def test_producer_trust_requires_canonical_main_and_owner_identities(self) -> None:
        trust = trust_context()
        model.validate_trust_context(trust, candidate=COMMIT, phase="candidate", tree=TREE)
        for mutate, diagnostic in (
            (lambda value: value["workflow"].update(ref="refs/heads/candidate"), "canonical"),
            (lambda value: value["actor"].update(id=0), "actor"),
            (lambda value: value["candidate"].update(tree_oid="e" * 40), "commit/tree"),
        ):
            drifted = json.loads(json.dumps(trust))
            mutate(drifted)
            with self.subTest(diagnostic=diagnostic), self.assertRaisesRegex(
                model.BundleError, diagnostic,
            ):
                model.validate_trust_context(
                    drifted, candidate=COMMIT, phase="candidate", tree=TREE,
                )

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
        with self.assertRaisesRegex(model.BundleError, "receipt argument|oracle source|canonical"):
            model.validate_gate_report(report, COMMIT, "candidate")

    def test_gate_report_rejects_reordered_canonical_subphases(self) -> None:
        report = gate_report()
        report["commands"][4], report["commands"][5] = (
            report["commands"][5], report["commands"][4],
        )
        with self.assertRaisesRegex(model.BundleError, "canonical and ordered"):
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

    def test_bundle_executables_must_match_exhaustive_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = {
                name: root / name for name in ("stwo-zig", "cp11_dump", "riscv-trace-dump")
            }
            for name, path in paths.items():
                path.write_bytes(name.encode())
            receipt = {
                "oracle": {"executable_sha256": model.sha256_file(paths["cp11_dump"])},
                "implementation": {"executables": {
                    "stwo-zig": model.sha256_file(paths["stwo-zig"]),
                    "riscv-trace-dump": model.sha256_file(paths["riscv-trace-dump"]),
                }},
            }
            model.validate_executable_digests(
                receipt,
                cli=paths["stwo-zig"],
                oracle_cli=paths["cp11_dump"],
                trace_cli=paths["riscv-trace-dump"],
            )
            paths["cp11_dump"].write_bytes(b"tampered")
            with self.assertRaisesRegex(model.BundleError, "Rust cp11_dump digest"):
                model.validate_executable_digests(
                    receipt,
                    cli=paths["stwo-zig"],
                    oracle_cli=paths["cp11_dump"],
                    trace_cli=paths["riscv-trace-dump"],
                )

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
            "claim_order_swap": {
                "returncode": 1,
                "expected_error": "OodsNotMatching",
            },
        }
        summary["boundary_rejection_results"] = {
            name: {"returncode": 1} for name in model.BOUNDARY_REJECTION_KEYS
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

    def test_cli_summary_rejects_each_delegated_coverage_omission(self) -> None:
        summary = {
            "schema": "riscv_cli_evidence_v1",
            "profile": "exhaustive",
            "phase": "candidate",
            "release_status": "not_release_gated",
            "implementation_commit": COMMIT,
            "implementation_dirty": False,
            "executable_sha256": DIGEST,
            "multi_shard_addi_rows": 65_537,
            "total_steps": 131_078,
            **{
                field: DIGEST for field in (
                    "artifact_sha256", "benchmark_artifact_sha256", "benchmark_report_sha256",
                    "verify_receipt_sha256", "benchmark_verify_receipt_sha256",
                )
            },
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
            "boundary_rejection_results": {
                name: {"returncode": 1} for name in model.BOUNDARY_REJECTION_KEYS
            },
            "claim_order_swap": {"returncode": 1, "expected_error": "OodsNotMatching"},
        }
        for field, key in (
            ("boundary_rejection_results", "existing-report"),
            ("proof_wire_mutation_returncodes", "trailing"),
            ("hostile_artifact_results", "unknown-field"),
        ):
            with self.subTest(field=field), mock.patch.dict(summary[field], clear=False):
                removed = summary[field].pop(key)
                try:
                    with self.assertRaisesRegex(model.BundleError, "coverage|matrix"):
                        model.validate_cli_summary(summary, COMMIT, "candidate", DIGEST)
                finally:
                    summary[field][key] = removed
        summary.pop("claim_order_swap")
        with self.assertRaisesRegex(model.BundleError, "claim-order"):
            model.validate_cli_summary(summary, COMMIT, "candidate", DIGEST)

    def test_bundle_lifetime_matches_artifact_policy_and_expires(self) -> None:
        manifest = {"created_at_unix": 100, "expires_at_unix": 100 + 30 * 24 * 60 * 60}
        model.validate_lifetime(manifest, now=101)
        with self.assertRaisesRegex(model.BundleError, "expired"):
            model.validate_lifetime(manifest, now=manifest["expires_at_unix"] + 1)
        manifest["expires_at_unix"] -= 1
        with self.assertRaisesRegex(model.BundleError, "retention"):
            model.validate_lifetime(manifest, now=101)


if __name__ == "__main__":
    unittest.main()
