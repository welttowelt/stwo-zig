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
    ELF_CORPUS_BOUNDARIES,
    GENERATED_CORPUS_KEYS,
    EXPECTED_LIMITATION_REQUESTS,
    IMPLEMENTATION_REPOSITORY,
    ORACLE_REPOSITORY,
    PINNED_ORACLE,
    core_purity_errors,
    divergence_errors,
    divergence_ledger_errors,
    frontend_layering_errors,
    oracle_limitation_source_errors,
    phase_errors,
    receipt_errors,
    expected_case_result_keys,
    _relation_case_errors,
)
from scripts.riscv_release_gate_lib import controller
from scripts.riscv_release_gate_lib.controller import command_plan
from scripts.riscv_release_evidence import _strict_object


COMMIT = "a" * 40
DIGEST = "b" * 64


def valid_receipt(now: int) -> dict[str, object]:
    boundaries = {
        name: {
            "status": "pass",
            **({"corpus": [{"name": "alu", "agree": True}]}
               if name in ELF_CORPUS_BOUNDARIES else {}),
        }
        for name in BOUNDARIES
    }
    for name in ("relation_tuples", "relation_sums"):
        boundaries[name]["corpus"][0].update({
            "proof_admission": {"status": "supported"},
            "proof_admitted": True,
            "evidence_mode": "balanced_full",
        })
    keys = expected_case_result_keys(("alu",))
    digests = {key: DIGEST for key in keys}
    for boundary in BOUNDARIES:
        encoded = json.dumps(
            boundaries[boundary], sort_keys=True, separators=(",", ":")
        ).encode()
        digests[f"{boundary}/aggregate"] = hashlib.sha256(encoded).hexdigest()
        if boundary in ELF_CORPUS_BOUNDARIES:
            case = boundaries[boundary]["corpus"][0]
            digests[f"{boundary}/alu"] = hashlib.sha256(
                json.dumps(case, sort_keys=True, separators=(",", ":")).encode()
            ).hexdigest()
        if boundary in GENERATED_CORPUS_KEYS:
            digests[GENERATED_CORPUS_KEYS[boundary]] = digests[f"{boundary}/aggregate"]
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
        "implementation": {
            "repository": IMPLEMENTATION_REPOSITORY,
            "commit": COMMIT,
            "clean": True,
            "executables": {
                "riscv-trace-dump": DIGEST,
                "stwo-zig": DIGEST,
            },
        },
        "boundaries": boundaries,
    }


def limitation_core() -> dict[str, object]:
    return {
        "schema": "riscv-mulh-limitation-v1",
        "limitation_id": "stark-v-signed-mulh",
        "oracle_commit": PINNED_ORACLE,
        "family": "mulh",
        "family_rows": 3,
        "signed_rows": 2,
        "unsigned_rows": 1,
        "raw_nonzero_entries": 60,
        "raw_stream_sha256": "1" * 64,
        "range811_requests": 24,
        "range811_stream_sha256": "2" * 64,
        "invalid_request_count": 8,
        "invalid_requests_sha256": "3" * 64,
        "invalid_requests": [
            {
                "row": row,
                "opcode_id": opcode,
                "request_index": request,
                "tuple": list(values),
                "classification": "range_check_8_11_value_out_of_range",
            }
            for row, opcode, request, values in EXPECTED_LIMITATION_REQUESTS
        ],
        "outcome": "preprocessed_registration_rejected",
        "source": {
            "elf_sha256": DIGEST,
            "input_sha256": hashlib.sha256(b"").hexdigest(),
        },
    }


def limitation_case(boundary: str) -> dict[str, object]:
    core = limitation_core()
    diagnostic = (
        "stark-v adapter: error=UnsupportedProofFamily "
        "stage=statement_validation_before_first_commitment "
        "limitation=stark-v-signed-mulh"
    )
    return {
        "name": "mul_div",
        "elf_sha256": DIGEST,
        "proof_admission": {
            "status": "fail_closed_known_limitation",
            "known_limitation": "stark-v-signed-mulh",
        },
        "proof_admitted": False,
        "evidence_mode": "pinned_known_limitation",
        "agree": True,
        "comparison_outcome": "exact_pinned_limitation_fail_closed",
        "observation": (
            "raw_relation_requests" if boundary == "relation_tuples"
            else "preprocessed_registration"
        ),
        "limitation_evidence": {
            "normalized_core": core,
            "normalized_core_sha256": hashlib.sha256(
                json.dumps(core, sort_keys=True, separators=(",", ":")).encode()
            ).hexdigest(),
            "production_rejection": {
                "exit_code": 1,
                "stdout_sha256": hashlib.sha256(b"").hexdigest(),
                "stderr_sha256": hashlib.sha256((diagnostic + "\n").encode()).hexdigest(),
                "diagnostic": diagnostic,
                "proof_artifact_absent": True,
                "report_artifact_absent": True,
                "temporary_residue_absent": True,
            },
        },
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


class DivergenceContractTests(unittest.TestCase):
    @staticmethod
    def ledger(*rows: str) -> str:
        return "\n".join((
            "# Upstream divergence ledger",
            "",
            "## Active divergences",
            "",
            "| Lane | Boundary | Current | Oracle | Release status |",
            "| --- | --- | --- | --- | --- |",
            *rows,
            "",
            "## Closure requirements",
        ))

    def test_current_signed_mulh_oracle_defect_is_documented_but_allowlisted(self) -> None:
        errors = divergence_errors(Path(__file__).resolve().parents[2])
        self.assertFalse(
            any("Signed `MULH` carry relation" in error for error in errors)
        )

    def test_known_oracle_limitation_cannot_be_hidden_or_loosely_waived(self) -> None:
        missing = divergence_ledger_errors(self.ledger())
        self.assertTrue(any("known oracle limitation" in error for error in missing))

        disguised = divergence_ledger_errors(self.ledger(
            "| RISC-V | Signed `MULH` carry relation | zig | rust | Deferred without condition. |"
        ))
        self.assertTrue(
            any("allowlisted divergence lacks its conditional status" in error for error in disguised)
        )

    def test_signed_mulh_fix_marker_is_machine_enforced(self) -> None:
        self.assertEqual([], oracle_limitation_source_errors("// FIX(stark-v-signed-mulh): pinned"))
        self.assertEqual(
            ["signed-MULH oracle limitation lacks FIX(stark-v-signed-mulh)"],
            oracle_limitation_source_errors("// defect mentioned without the stable marker"),
        )

    def test_only_code_owned_conditional_rows_are_allowlisted(self) -> None:
        ledger = self.ledger(
            "| RISC-V | PCS geometry | zig | rust | Allowed only with the self-check. |",
            "| RISC-V | Interaction transcript | zig | rust | Allowed only with the transcript receipt. |",
        )
        self.assertEqual([], divergence_ledger_errors(ledger, pinned_oracle="f" * 40))

        invented = self.ledger(
            "| RISC-V | Invented waiver | zig | rust | Allowed only with tests. |"
        )
        self.assertIn(
            "release-blocking divergence remains active: RISC-V / Invented waiver",
            divergence_ledger_errors(invented, pinned_oracle="f" * 40),
        )

    def test_architectural_divergences_cannot_be_hidden(self) -> None:
        ledger = self.ledger(
            "| RISC-V | PCS geometry | zig | rust | Allowed only with the self-check. |",
        )
        self.assertIn(
            "required architectural divergence is missing: RISC-V / Interaction transcript",
            divergence_ledger_errors(ledger, pinned_oracle="f" * 40),
        )


class LayeringContractTests(unittest.TestCase):
    @staticmethod
    def write(root: Path, relative: str, source: str) -> None:
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(source, encoding="utf-8")

    def test_core_purity_resolves_and_rejects_concrete_dependency_edges(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write(root, "src/frontends/riscv/air.zig", "pub const ok = true;\n")
            self.write(
                root,
                "src/core/protocol.zig",
                'const air = @import("../frontends/riscv/air.zig");\n',
            )
            errors = core_purity_errors(root)
            self.assertEqual(1, len(errors))
            self.assertIn("src/core/protocol.zig imports frontends/riscv/air.zig", errors[0])

    def test_frontend_layering_rejects_cli_backend_placeholders_and_giant_files(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write(root, "src/tools/prove/cli.zig", "pub const ok = true;\n")
            self.write(
                root,
                "src/frontends/riscv/prover.zig",
                'const cli = @import("../../tools/prove/cli.zig");\n'
                "const Mode = enum { silent };\n"
                + "const value = 0;\n" * 850,
            )
            errors = frontend_layering_errors(root)
            self.assertTrue(any("imports tools/prove/cli.zig" in error for error in errors))
            self.assertTrue(any("manual ceiling 850" in error for error in errors))
            self.assertTrue(any("active placeholder markers: silent" in error for error in errors))

    def test_comments_and_strings_do_not_create_placeholder_findings(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write(
                root,
                "src/frontends/riscv/air.zig",
                '// legacy placeholder silent\nconst label = "silent";\n',
            )
            self.assertEqual([], frontend_layering_errors(root))


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

    def test_per_corpus_rows_and_digests_are_bound_not_only_declared(self) -> None:
        now = int(time.time())
        receipt = valid_receipt(now)
        receipt["boundaries"]["execution"]["corpus"] = [
            {"name": "alu", "agree": False}
        ]
        errors = receipt_errors(receipt, COMMIT, now=now, vector_names=("alu",))
        self.assertIn("case-result digest does not bind execution/alu", errors)
        self.assertIn("boundary case execution/alu does not attest agreement", errors)

        receipt = valid_receipt(now)
        receipt["boundaries"]["execution"]["corpus"] = []
        errors = receipt_errors(receipt, COMMIT, now=now, vector_names=("alu",))
        self.assertIn(
            "boundary execution corpus is incomplete, duplicated, or non-canonical",
            errors,
        )

    def test_signed_mulh_limitation_mode_is_exact_and_fail_closed(self) -> None:
        admission = {
            "status": "fail_closed_known_limitation",
            "known_limitation": "stark-v-signed-mulh",
        }
        for boundary in ("relation_tuples", "relation_sums"):
            self.assertEqual(
                [], _relation_case_errors(limitation_case(boundary), boundary, admission)
            )

        relabeled = limitation_case("relation_tuples")
        relabeled["evidence_mode"] = "balanced_full"
        relabeled["proof_admitted"] = True
        errors = _relation_case_errors(
            relabeled, "relation_tuples", admission
        )
        self.assertTrue(any("not exact pinned-limitation" in error for error in errors))
        self.assertTrue(any("proof-admitted" in error for error in errors))

        skipped = limitation_case("relation_sums")
        skipped.pop("limitation_evidence")
        skipped["comparison_outcome"] = "skipped"
        errors = _relation_case_errors(skipped, "relation_sums", admission)
        self.assertTrue(any("exact fail-closed outcome" in error for error in errors))
        self.assertTrue(any("incomplete limitation evidence" in error for error in errors))

    def test_limitation_rejects_malformed_matrix_and_artifact_creation(self) -> None:
        admission = {
            "status": "fail_closed_known_limitation",
            "known_limitation": "stark-v-signed-mulh",
        }
        malformed = limitation_case("relation_tuples")
        malformed["limitation_evidence"]["normalized_core"]["invalid_requests"][0][
            "request_index"
        ] = 9
        malformed["limitation_evidence"]["production_rejection"][
            "proof_artifact_absent"
        ] = False
        errors = _relation_case_errors(malformed, "relation_tuples", admission)
        self.assertTrue(any("request matrix is not exact" in error for error in errors))
        self.assertTrue(any("no-artifact contract" in error for error in errors))

        noncanonical = limitation_case("relation_tuples")
        noncanonical["limitation_evidence"]["normalized_core"]["invalid_requests"][0][
            "tuple"
        ][1] = (1 << 31) - 1
        errors = _relation_case_errors(noncanonical, "relation_tuples", admission)
        self.assertTrue(any("invalid request record" in error for error in errors))

        wrong_source = limitation_case("relation_tuples")
        wrong_source["limitation_evidence"]["normalized_core"]["source"][
            "elf_sha256"
        ] = "c" * 64
        errors = _relation_case_errors(wrong_source, "relation_tuples", admission)
        self.assertTrue(any("not bound to the live source" in error for error in errors))

    def test_mulhu_diagnostic_requires_nonzero_family_evidence_and_stays_unadmitted(self) -> None:
        admission = {
            "status": "diagnostic_balanced_family_fail_closed",
            "known_limitation": "stark-v-signed-mulh",
        }
        case = {
            "name": "mulhu_only",
            "proof_admission": admission,
            "proof_admitted": False,
            "evidence_mode": "balanced_full",
            "agree": True,
            "mulh_nonzero_entries": 1,
        }
        self.assertEqual(
            [], _relation_case_errors(case, "relation_tuples", admission)
        )
        case["mulh_nonzero_entries"] = 0
        case["proof_admitted"] = True
        errors = _relation_case_errors(case, "relation_tuples", admission)
        self.assertTrue(any("no nonzero MULH" in error for error in errors))
        self.assertTrue(any("proof-admission verdict" in error for error in errors))

    def test_relation_cases_bind_the_live_manifest_elf_digest(self) -> None:
        now = int(time.time())
        receipt = valid_receipt(now)
        receipt["boundaries"]["relation_tuples"]["corpus"][0]["elf_sha256"] = "c" * 64
        with mock.patch(
            "scripts.riscv_release_gate_lib.contract.trace_vector_contract",
            return_value=(("alu",), {"alu": {"status": "supported"}}, {"alu": DIGEST}),
        ):
            errors = receipt_errors(receipt, COMMIT, now=now, vector_names=("alu",))
        self.assertIn(
            "boundary case relation_tuples/alu is not bound to the live ELF digest",
            errors,
        )


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
        self.assertTrue(any("check_riscv_release_contract.py --structure" in row for row in rendered))
        self.assertTrue(any("check_riscv_release_contract.py --core-purity" in row for row in rendered))
        self.assertTrue(any("check_riscv_release_contract.py --frontend-layering" in row for row in rendered))
        self.assertTrue(any("riscv_staged_smoke.py --phase candidate" in row for row in rendered))
        self.assertTrue(any("unittest discover -s scripts/tests -p test_*.py" in row for row in rendered))
        self.assertFalse(any("riscv_release_oracle.py" in row for row in rendered))
        self.assertEqual("zig build release-gate -Doptimize=ReleaseFast", rendered[-1])
        self.assertFalse(any("test-riscv-prover" in row for row in rendered))

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
        self.assertNotIn("zig build release-gate -Doptimize=ReleaseFast", rendered)
        self.assertEqual(1, rendered.count("zig build release-gate-strict -Doptimize=ReleaseFast"))
        self.assertFalse(any("test-riscv-prover" in row for row in rendered))
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
        self.assertIn("riscv_release_evidence.py", rendered[-1])

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

    def test_candidate_and_promoted_controllers_refuse_any_active_blocker(self) -> None:
        blocker = "release-blocking divergence remains active: RISC-V / Public statement"
        for phase in ("candidate", "promoted"):
            with (
                self.subTest(phase=phase),
                tempfile.TemporaryDirectory() as repository,
                tempfile.TemporaryDirectory() as output,
            ):
                root = Path(repository)
                candidate = self.repository(root)
                calls: list[list[str]] = []

                def runner(command: list[str], _: Path) -> dict[str, object]:
                    calls.append(command)
                    raise AssertionError("controller executed commands after a contract failure")

                evidence_dir = Path(output) / "session"
                report = evidence_dir / "gate.json"
                with (
                    mock.patch.object(controller, "repository_contract_errors", return_value=[blocker]),
                    mock.patch.object(controller, "_tool_versions", return_value={}),
                    mock.patch.object(controller, "_artifact_digests", return_value={}),
                ):
                    code = controller.run_gate(
                        [["must-not-run"]],
                        phase=phase,
                        candidate=candidate,
                        evidence_dir=evidence_dir,
                        report_out=report,
                        root=root,
                        runner=runner,
                    )
                payload = json.loads(report.read_text(encoding="utf-8"))
                self.assertEqual(1, code)
                self.assertEqual([], calls)
                self.assertEqual("FAIL", payload["status"])
                self.assertIn(blocker, payload["failures"])

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
