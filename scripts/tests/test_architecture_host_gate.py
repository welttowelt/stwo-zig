from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts.architecture_host_gate_lib import capture, controller, plan, validators
from scripts.build_architecture_receipt_lib.protocol import load_protocol


SHA = "1" * 40
TREE = "2" * 40


def protocol() -> dict[str, object]:
    return {
        "checkpoint_order": ["BG-00", "BG-15"],
        "host_roles": {
            "linux": {
                "allocated_checkpoints": ["BG-00"],
                "required_products": ["product"],
            }
        },
        "limits": {"max_json_bytes": 1_000_000},
    }


def architecture_plan() -> dict[str, object]:
    return {
        "evidence_phases": {name: ["BG-00"] for name in controller.EVIDENCE_NAMES},
        "roles": {
            "linux": {
                "commands": [{
                    "id": "gate", "phase": "BG-00",
                    "argv": ["gate", "generated/result.json"],
                    "required_inputs": ["authority.json"],
                    "generated_outputs": ["generated/result.json"],
                }],
                "products": [{
                    "product_id": "product", "phase": "BG-00",
                    "identity_path": "identity.json", "identity_command": None,
                    "artifact_path": None,
                }],
            }
        },
    }


def product(status: str = "PASS") -> dict[str, object]:
    return {
        "product_id": "product",
        "product_identity_sha256": "3" * 64 if status == "PASS" else None,
        "artifact_sha256": "4" * 64 if status == "PASS" else None,
        "executable_sha256": None,
        "status": status,
        "reason": "fixture",
    }


class ArchitectureHostGateTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        (self.root / "generated").mkdir()
        (self.root / "generated/result.json").write_text('{"status":"stale"}')
        (self.root / "authority.json").write_text('{"schema":"authority-v1"}')
        (self.root / "plan.json").write_text('{"schema":"fixture"}')

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_gate(self, executor, *, clean=True, product_status="PASS"):
        git_values = {
            ("rev-parse", f"{SHA}^{{tree}}"): TREE,
            ("rev-parse", "HEAD"): SHA,
        }
        output = self.root / "evidence"
        def validate_outputs(_command_id, outputs, _inputs, *, root, candidate):
            del candidate
            result = {}
            for path in outputs:
                if not path.is_file():
                    raise controller.ReceiptError(f"missing fixture output: {path}")
                result[path.relative_to(root).as_posix()] = capture.sha256_file(path)
            return result
        with (
            mock.patch.object(controller, "load_protocol", return_value=(protocol(), "x")),
            mock.patch.object(controller.plan, "load", return_value=architecture_plan()),
            mock.patch.object(controller, "_git", side_effect=lambda _root, *args: git_values[args]),
            mock.patch.object(controller, "_clean", return_value=clean),
            mock.patch.object(controller.products, "collect", return_value=product(product_status)),
            mock.patch.object(
                controller.validators, "validate_outputs", side_effect=validate_outputs,
            ),
            mock.patch.object(controller, "validate_evidence_manifest"),
        ):
            return controller.execute(
                root=self.root, role="linux", plan_path=self.root / "plan.json",
                protocol_path=self.root / "protocol.json",
                output_dir=output, candidate=SHA,
                timeout=1.0, run_id="7", run_attempt="1", repository="owner/repo",
                repository_id="8", workflow_sha=SHA, riscv_bundle=self.root / "bundle",
                riscv_trust_context=self.root / "trust.json",
                riscv_policy_context=self.root / "policy-context.json",
                riscv_phase="candidate",
                executor=executor,
            )

    def test_removes_stale_output_before_real_command_and_passes_fresh_output(self) -> None:
        def execute(argv, root, timeout):
            del timeout
            result = root / argv[1]
            self.assertFalse(result.exists())
            result.write_text('{"status":"PASS"}')
            return 0, b"ok", b"", 2_000_000

        _, manifest = self.run_gate(execute)
        self.assertEqual("PASS", manifest["checkpoints"]["BG-00"]["status"])
        self.assertEqual(1, len(manifest["commands"]))
        self.assertTrue((self.root / "authority.json").is_file())

    def test_rejects_required_input_mutation_without_deleting_it(self) -> None:
        def execute(argv, root, timeout):
            del timeout
            (root / "authority.json").write_text('{"schema":"substituted"}')
            (root / argv[1]).write_text('{"status":"PASS"}')
            return 0, b"ok", b"", 1

        _, manifest = self.run_gate(execute)
        self.assertEqual("NO-GO", manifest["checkpoints"]["BG-00"]["status"])
        self.assertTrue((self.root / "authority.json").is_file())

    def test_missing_required_input_never_invokes_expensive_command(self) -> None:
        (self.root / "authority.json").unlink()
        executor = mock.Mock()
        _, manifest = self.run_gate(executor)
        executor.assert_not_called()
        self.assertEqual("NO-GO", manifest["checkpoints"]["BG-00"]["status"])
        self.assertEqual(125, manifest["commands"][0]["exit_code"])
        self.assertIn(
            "required input admission failed",
            (self.root / "evidence/commands/000-gate.stderr").read_text(),
        )

    def test_missing_output_or_skipped_test_is_no_go(self) -> None:
        _, missing = self.run_gate(lambda *_: (0, b"ok", b"", 1))
        self.assertEqual("NO-GO", missing["checkpoints"]["BG-00"]["status"])
        (self.root / "evidence").rename(self.root / "old-evidence")

        def skipped(argv, root, timeout):
            del timeout
            (root / argv[1]).write_text('{"status":"PASS"}')
            return 0, b"1 skipped", b"", 1

        _, skipped_manifest = self.run_gate(skipped)
        self.assertEqual("NO-GO", skipped_manifest["checkpoints"]["BG-00"]["status"])

    def test_dirty_source_executes_nothing_and_is_no_go(self) -> None:
        executor = mock.Mock()
        _, manifest = self.run_gate(executor, clean=False)
        executor.assert_not_called()
        self.assertEqual([], manifest["commands"])
        self.assertEqual("NO-GO", manifest["checkpoints"]["BG-00"]["status"])

    def test_skip_parser_counts_once(self) -> None:
        self.assertEqual(3, capture.skipped_tests(b"3 tests skipped", b""))
        self.assertEqual(2, capture.skipped_tests(b"skipped=2", b""))


class ArchitecturePlanTest(unittest.TestCase):
    def test_checked_in_plan_exactly_covers_protocol_allocations(self) -> None:
        root = Path(__file__).resolve().parents[2]
        receipt_protocol, _ = load_protocol(
            root / "conformance/build-architecture-receipt-protocol-v1.json"
        )
        value = plan.load(
            root / "conformance/build-architecture-ci-plan-v1.json", receipt_protocol,
        )
        for role, policy in receipt_protocol["host_roles"].items():
            phases = {item["phase"] for item in value["roles"][role]["commands"]}
            self.assertEqual(set(policy["allocated_checkpoints"]), phases)

    def test_unknown_output_authority_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            output = root / "result.json"
            output.write_text('{"status":"PASS"}')
            with self.assertRaises(controller.ReceiptError):
                validators.validate_outputs(
                    "unknown-evidence", [output], [], root=root, candidate=SHA,
                )


if __name__ == "__main__":
    unittest.main()
