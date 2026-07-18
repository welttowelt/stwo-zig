import hashlib
import json
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

from scripts.riscv_release_gate_lib.contract import (
    BOUNDARIES,
    ORACLE_REPOSITORY,
    PINNED_ORACLE,
    phase_errors,
    receipt_errors,
    expected_case_result_keys,
)
from scripts.riscv_release_gate_lib import controller
from scripts.riscv_release_gate_lib.controller import command_plan
from scripts.riscv_release_evidence import _strict_object


COMMIT = "a" * 40
DIGEST = "b" * 64


def valid_receipt(now: int) -> dict[str, object]:
    boundaries = {name: {"status": "pass"} for name in BOUNDARIES}
    keys = expected_case_result_keys(("alu",))
    digests = {key: DIGEST for key in keys}
    for boundary in BOUNDARIES:
        encoded = json.dumps(
            boundaries[boundary], sort_keys=True, separators=(",", ":")
        ).encode()
        digests[f"{boundary}/aggregate"] = hashlib.sha256(encoded).hexdigest()
    return {
        "schema": "riscv-oracle-receipt-v2",
        "candidate_commit": COMMIT,
        "created_at_unix": now,
        "witness_layout_digest_sha256": DIGEST,
        "corpus_digest_sha256": DIGEST,
        "expected_case_result_keys": keys,
        "case_result_digests": digests,
        "verdict": "PASS",
        "oracle": {
            "repository": ORACLE_REPOSITORY,
            "commit": PINNED_ORACLE,
            "clean": True,
            "tree_digest_sha256": DIGEST,
            "lockfile_sha256": DIGEST,
            "executable_sha256": DIGEST,
            "toolchain": "rustc 1.90",
            "build_command": "cargo build --locked --release -p prover",
            "build_mode": "release",
            "host_arch": "aarch64",
            "host_os": "macOS",
            "submodule_status": [],
            "adapter_overlay": {
                "path": "crates/prover/src/bin/cp11_dump.rs",
                "sha256": DIGEST,
            },
        },
        "boundaries": boundaries,
    }


class PhaseContractTests(unittest.TestCase):
    def test_candidate_requires_one_reasoned_deferred_adapter_and_typed_flag(self) -> None:
        registry = (
            'pub const RISCV_ADAPTER_RELEASE_GATED = false; requireRiscVAdmission; '
            '{"adapter":"stark-v-rv32im-elf","air":"stark_v_rv32im",'
            '"status":"release_gated","isa":"rv32im","backends":["cpu"]} '
            '{"adapter":"stark-v-rv32im-elf","status":"not_release_gated",'
            '"isa":"rv32im","backends":["cpu"],"reason":"soundness gates pending"}'
        )
        artifact = 'pub const RELEASE_STATUS = "not_release_gated";'
        cli = 'const Flag = enum { experimental }; _ = Flag.experimental; "--experimental";'
        self.assertEqual([], phase_errors("candidate", registry, artifact, cli))

        self.assertIn(
            "CLI lacks the typed --experimental admission flag",
            phase_errors("candidate", registry, artifact, ""),
        )
        self.assertIn(
            "registry admission switch does not select the promoted phase",
            phase_errors("promoted", registry, 'pub const RELEASE_STATUS = "release_gated";', cli),
        )
        self.assertIn(
            "deferred Stark-V registry entry lacks a non-empty reason",
            phase_errors("candidate", registry.replace("soundness gates pending", ""), artifact, cli),
        )

    def test_promoted_requires_atomic_registry_artifact_and_flag_transition(self) -> None:
        registry = (
            'pub const RISCV_ADAPTER_RELEASE_GATED = true; requireRiscVAdmission; '
            '{"adapter":"stark-v-rv32im-elf","air":"stark_v_rv32im",'
            '"status":"release_gated","isa":"rv32im","backends":["cpu"]} '
            '{"adapter":"stark-v-rv32im-elf","status":"not_release_gated",'
            '"isa":"rv32im","backends":["cpu"],"reason":"pending"}'
        )
        artifact = 'pub const RELEASE_STATUS = "release_gated";'
        cli = 'const Flag = enum { experimental }; _ = Flag.experimental; "--experimental";'
        self.assertEqual([], phase_errors("promoted", registry, artifact, cli))

        mixed = phase_errors(
            "promoted",
            registry.replace("= true", "= false"),
            'pub const RELEASE_STATUS = "not_release_gated";',
            cli,
        )
        self.assertTrue(any("admission switch" in error for error in mixed))
        self.assertTrue(any("RELEASE_STATUS" in error for error in mixed))


class ReceiptContractTests(unittest.TestCase):
    def test_receipt_json_rejects_duplicate_fields_at_every_depth(self) -> None:
        with self.assertRaisesRegex(ValueError, "duplicate JSON field: status"):
            json.loads(
                '{"oracle":{"status":"clean","status":"dirty"}}',
                object_pairs_hook=_strict_object,
            )

    def test_complete_current_candidate_receipt_passes(self) -> None:
        now = int(time.time())
        self.assertEqual(
            [],
            receipt_errors(valid_receipt(now), COMMIT, now=now, vector_names=("alu",)),
        )

    def test_receipt_rejects_wrong_candidate_staleness_and_missing_boundary(self) -> None:
        now = int(time.time())
        receipt = valid_receipt(now - 90_000)
        receipt["candidate_commit"] = "c" * 40
        receipt["boundaries"]["relation_sums"] = {"status": "unimplemented"}
        errors = receipt_errors(receipt, COMMIT, now=now, vector_names=("alu",))
        self.assertIn("oracle receipt belongs to another candidate", errors)
        self.assertIn("oracle receipt is expired or from the future", errors)
        self.assertIn("boundary relation_sums is unimplemented", errors)

    def test_legacy_pass_bit_cannot_substitute_for_required_provenance(self) -> None:
        receipt = {
            "schema": "riscv-oracle-receipt-v1",
            "candidate_commit": COMMIT,
            "verdict": "PASS",
            "oracle": {"commit": PINNED_ORACLE},
            "boundaries": {name: {"status": "pass"} for name in BOUNDARIES},
        }
        errors = receipt_errors(receipt, COMMIT, now=0, vector_names=("alu",))
        self.assertIn("unknown oracle receipt schema", errors)
        self.assertIn("oracle receipt does not attest a clean source tree", errors)
        self.assertIn("witness layout digest is not a lowercase SHA-256 digest", errors)
        self.assertIn("per-case result digests are missing", errors)

    def test_case_digest_manifest_must_cover_every_boundary_and_vector_exactly(self) -> None:
        now = int(time.time())
        receipt = valid_receipt(now)
        receipt["expected_case_result_keys"] = receipt["expected_case_result_keys"][:-1]
        receipt["case_result_digests"].pop("shared_transcript_prefix/alu")
        receipt["case_result_digests"]["invented/case"] = DIGEST
        errors = receipt_errors(receipt, COMMIT, now=now, vector_names=("alu",))
        self.assertIn("expected case-result key manifest is incomplete or non-canonical", errors)
        self.assertIn("case-result digest keys do not exactly cover the declared corpus", errors)


class CommandPlanTests(unittest.TestCase):
    def test_candidate_plan_contains_phase_smoke_but_no_oracle_in_non_strict_mode(self) -> None:
        plan = command_plan(
            strict=False,
            phase="candidate",
            stark_v_source=None,
            candidate=COMMIT,
            evidence_dir=Path("/evidence"),
        )
        rendered = [" ".join(command) for command in plan]
        self.assertTrue(any("check_riscv_release_contract.py --all --phase candidate" in row for row in rendered))
        self.assertTrue(any("riscv_staged_smoke.py --phase candidate" in row for row in rendered))
        self.assertTrue(any("unittest scripts.tests.test_riscv_release_gate" in row for row in rendered))
        self.assertFalse(any("riscv_release_oracle.py" in row for row in rendered))
        self.assertEqual("zig build release-gate -Doptimize=ReleaseFast", rendered[-1])

    def test_strict_plan_generates_then_validates_candidate_bound_oracle_evidence(self) -> None:
        source = Path("/oracle")
        plan = command_plan(
            strict=True,
            phase="candidate",
            stark_v_source=source,
            candidate=COMMIT,
            evidence_dir=Path("/evidence"),
        )
        rendered = [" ".join(command) for command in plan]
        strict_index = rendered.index("zig build release-gate-strict -Doptimize=ReleaseFast")
        producer_index = next(i for i, row in enumerate(rendered) if "build-and-compare" in row)
        oracle_validate_index = next(
            i for i, row in enumerate(rendered) if "riscv_release_oracle.py validate" in row
        )
        evidence_index = next(i for i, row in enumerate(rendered) if "riscv_release_evidence.py" in row)
        self.assertLess(strict_index, producer_index)
        self.assertLess(producer_index, oracle_validate_index)
        self.assertLess(oracle_validate_index, evidence_index)
        self.assertIn(f"--candidate {COMMIT}", rendered[producer_index])
        self.assertIn(f"--candidate {COMMIT}", rendered[evidence_index])
        self.assertIn("zig build riscv-release-gate -Doptimize=ReleaseFast", rendered[-1])
        self.assertIn("-Driscv-release-phase=candidate", rendered[-1])
        self.assertIn("-Driscv-evidence-dir=/evidence", rendered[-1])

    def test_strict_plan_refuses_an_opaque_oracle_location(self) -> None:
        with self.assertRaisesRegex(ValueError, "--stark-v-source"):
            command_plan(
                strict=True,
                phase="candidate",
                stark_v_source=None,
                candidate=COMMIT,
                evidence_dir=Path("/evidence"),
            )


class ExecutionEvidenceTests(unittest.TestCase):
    @staticmethod
    def repository(path: Path) -> str:
        subprocess.run(["git", "init", "-q"], cwd=path, check=True)
        subprocess.run(["git", "config", "user.email", "gate@example.invalid"], cwd=path, check=True)
        subprocess.run(["git", "config", "user.name", "Gate Test"], cwd=path, check=True)
        subprocess.run(["git", "commit", "--allow-empty", "-qm", "candidate"], cwd=path, check=True)
        return subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=path, check=True, capture_output=True, text=True
        ).stdout.strip()

    def test_execution_is_fail_fast_and_report_names_only_executed_commands(self) -> None:
        with tempfile.TemporaryDirectory() as repository, tempfile.TemporaryDirectory() as output:
            root = Path(repository)
            candidate = self.repository(root)
            calls: list[list[str]] = []

            def runner(command: list[str], _: Path) -> dict[str, object]:
                calls.append(command)
                return {
                    "command": command,
                    "command_shell": " ".join(command),
                    "exit_code": 9,
                    "started_at_unix_ns": 1,
                    "duration_ns": 1,
                    "skipped_tests": 0,
                    "stdout_sha256": DIGEST,
                    "stderr_sha256": DIGEST,
                    "stdout_tail": "",
                    "stderr_tail": "failed",
                }

            evidence_dir = Path(output) / "session"
            report = evidence_dir / "gate.json"
            with (
                mock.patch.object(controller, "repository_contract_errors", return_value=[]),
                mock.patch.object(controller, "_tool_versions", return_value={}),
                mock.patch.object(controller, "_artifact_digests", return_value={}),
            ):
                code = controller.run_gate(
                    [["first"], ["must-not-run"]],
                    phase="candidate",
                    candidate=candidate,
                    evidence_dir=evidence_dir,
                    report_out=report,
                    root=root,
                    runner=runner,
                )
            payload = json.loads(report.read_text(encoding="utf-8"))
            self.assertEqual(1, code)
            self.assertEqual([["first"]], calls)
            self.assertEqual("FAIL", payload["status"])
            self.assertEqual(1, len(payload["commands"]))
            self.assertIn("command failed: first", payload["failures"])

    def test_clean_success_records_every_executed_command(self) -> None:
        with tempfile.TemporaryDirectory() as repository, tempfile.TemporaryDirectory() as output:
            root = Path(repository)
            candidate = self.repository(root)

            def runner(command: list[str], _: Path) -> dict[str, object]:
                return {
                    "command": command,
                    "command_shell": " ".join(command),
                    "exit_code": 0,
                    "started_at_unix_ns": 1,
                    "duration_ns": 1,
                    "skipped_tests": 0,
                    "stdout_sha256": DIGEST,
                    "stderr_sha256": DIGEST,
                    "stdout_tail": "ok",
                    "stderr_tail": "",
                }

            evidence_dir = Path(output) / "session"
            report = evidence_dir / "gate.json"
            with (
                mock.patch.object(controller, "repository_contract_errors", return_value=[]),
                mock.patch.object(controller, "_tool_versions", return_value={}),
                mock.patch.object(controller, "_artifact_digests", return_value={}),
            ):
                code = controller.run_gate(
                    [["one"], ["two"]],
                    phase="candidate",
                    candidate=candidate,
                    evidence_dir=evidence_dir,
                    report_out=report,
                    root=root,
                    runner=runner,
                )
            payload = json.loads(report.read_text(encoding="utf-8"))
            self.assertEqual(0, code)
            self.assertEqual("PASS", payload["status"])
            self.assertEqual(["one", "two"], [row["command"][0] for row in payload["commands"]])
            self.assertEqual("", payload["git"]["initial_porcelain"])
            self.assertEqual("", payload["git"]["final_porcelain"])
            self.assertEqual([], list(evidence_dir.glob(".*.tmp")))

    def test_zero_exit_with_skipped_required_tests_still_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as repository, tempfile.TemporaryDirectory() as output:
            root = Path(repository)
            candidate = self.repository(root)
            calls: list[list[str]] = []

            def runner(command: list[str], _: Path) -> dict[str, object]:
                calls.append(command)
                return {
                    "command": command,
                    "command_shell": " ".join(command),
                    "exit_code": 0,
                    "started_at_unix_ns": 1,
                    "duration_ns": 1,
                    "skipped_tests": 1,
                    "stdout_sha256": DIGEST,
                    "stderr_sha256": DIGEST,
                    "stdout_tail": "1 skipped",
                    "stderr_tail": "",
                }

            evidence_dir = Path(output) / "session"
            report = evidence_dir / "gate.json"
            with (
                mock.patch.object(controller, "repository_contract_errors", return_value=[]),
                mock.patch.object(controller, "_tool_versions", return_value={}),
                mock.patch.object(controller, "_artifact_digests", return_value={}),
            ):
                code = controller.run_gate(
                    [["tests"], ["must-not-run"]],
                    phase="candidate",
                    candidate=candidate,
                    evidence_dir=evidence_dir,
                    report_out=report,
                    root=root,
                    runner=runner,
                )
            payload = json.loads(report.read_text(encoding="utf-8"))
            self.assertEqual(1, code)
            self.assertEqual([["tests"]], calls)
            self.assertIn("required tests were skipped: tests", payload["failures"])

    def test_subprocess_timeout_is_an_explicit_failed_command_receipt(self) -> None:
        timeout = subprocess.TimeoutExpired(
            ["slow"],
            0.25,
            output="partial output",
            stderr="partial error",
        )
        with mock.patch.object(controller.subprocess, "run", side_effect=timeout):
            record = controller._capture(["slow"], Path.cwd(), 0.25)
        self.assertEqual(124, record["exit_code"])
        self.assertTrue(record["timed_out"])
        self.assertEqual(0.25, record["timeout_seconds"])
        self.assertIn("partial output", record["stdout_tail"])
        self.assertIn("timed out after 0.25s", record["stderr_tail"])

    def test_existing_evidence_directory_is_rejected_without_overwrite(self) -> None:
        with tempfile.TemporaryDirectory() as repository, tempfile.TemporaryDirectory() as output:
            root = Path(repository)
            candidate = self.repository(root)
            evidence_dir = Path(output) / "session"
            evidence_dir.mkdir()
            marker = evidence_dir / "prior.json"
            marker.write_text("prior", encoding="utf-8")
            code = controller.run_gate(
                [],
                phase="candidate",
                candidate=candidate,
                evidence_dir=evidence_dir,
                report_out=evidence_dir / "gate.json",
                root=root,
            )
            self.assertEqual(1, code)
            self.assertEqual("prior", marker.read_text(encoding="utf-8"))
            self.assertFalse((evidence_dir / "gate.json").exists())


if __name__ == "__main__":
    unittest.main()
