from __future__ import annotations

import datetime as dt
import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from scripts.autoresearch_activation_lib.contract import (
    SETTINGS_SCHEMA,
    activation_errors,
    validate_settings_receipt,
)
from scripts.autoresearch_activation_lib.github import (
    SettingsCaptureError,
    build_settings_receipt,
)


def canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def settings_receipt() -> dict:
    payload = {
        "ruleset_enforcement": "active",
        "non_fast_forward": True,
        "required_status_checks": ["autoresearch-validate", "autoresearch-judge"],
    }
    return {
        "schema": SETTINGS_SCHEMA,
        "repository": "teddyjfpender/stwo-zig",
        "default_branch": "main",
        "source": "github-api",
        "observed_at": "2026-07-21T12:00:00+00:00",
        "payload": payload,
        "payload_sha256": hashlib.sha256(canonical(payload)).hexdigest(),
    }


class SettingsReceiptTest(unittest.TestCase):
    def test_valid_receipt_binds_required_checks(self) -> None:
        errors = validate_settings_receipt(
            settings_receipt(),
            repository="teddyjfpender/stwo-zig",
            now=dt.datetime(2026, 7, 21, 12, 15, tzinfo=dt.timezone.utc),
        )
        self.assertEqual(errors, [])

    def test_digest_and_check_tampering_fail(self) -> None:
        receipt = settings_receipt()
        receipt["payload"]["required_status_checks"] = ["autoresearch-validate"]
        errors = validate_settings_receipt(
            receipt,
            repository="teddyjfpender/stwo-zig",
            now=dt.datetime(2026, 7, 21, 12, 15, tzinfo=dt.timezone.utc),
        )
        self.assertIn("GitHub settings receipt payload digest mismatches", errors)

    def test_authenticated_capture_reduces_active_main_rules(self) -> None:
        receipt = build_settings_receipt(
            "example/repo",
            {"default_branch": "main"},
            [{
                "id": 17,
                "name": "main",
                "enforcement": "active",
                "updated_at": "2026-07-21T12:00:00Z",
                "conditions": {
                    "ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []},
                },
                "rules": [
                    {"type": "non_fast_forward"},
                    {
                        "type": "required_status_checks",
                        "parameters": {"required_status_checks": [
                            {"context": "autoresearch-judge", "integration_id": None},
                            {"context": "autoresearch-validate", "integration_id": None},
                        ]},
                    },
                ],
            }],
            observed_at=dt.datetime(2026, 7, 21, 12, 0, tzinfo=dt.timezone.utc),
        )
        self.assertEqual(receipt["source"], "github-api")
        self.assertEqual(
            receipt["payload"]["required_status_checks"],
            ["autoresearch-judge", "autoresearch-validate"],
        )
        self.assertTrue(receipt["payload"]["non_fast_forward"])
        self.assertEqual(
            validate_settings_receipt(
                receipt,
                repository="example/repo",
                now=dt.datetime(2026, 7, 21, 12, 1, tzinfo=dt.timezone.utc),
            ),
            [],
        )

    def test_capture_rejects_ruleset_for_another_branch(self) -> None:
        with self.assertRaises(SettingsCaptureError):
            build_settings_receipt(
                "example/repo",
                {"default_branch": "main"},
                [{
                    "id": 17,
                    "name": "release",
                    "enforcement": "active",
                    "updated_at": "2026-07-21T12:00:00Z",
                    "conditions": {
                        "ref_name": {
                            "include": ["refs/heads/release"],
                            "exclude": [],
                        },
                    },
                    "rules": [{"type": "non_fast_forward"}],
                }],
            )


class ActivationContractTest(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "autoresearch/ledger").mkdir(parents=True)
        (self.root / ".github/workflows").mkdir(parents=True)
        workloads = {}
        pools = {}
        for workload_class in ("small", "wide", "deep"):
            members = []
            for index in range(2):
                workload_id = f"riscv_{workload_class}_{index}"
                members.append(workload_id)
                workloads[workload_id] = {
                    "class": workload_class,
                    "args": (
                        f"bench --elf vectors/{workload_id}.elf --backend cpu "
                        "--protocol functional {admission} --warmups {warmups} "
                        "--samples {samples}"
                    ),
                    "native_unit": "executed instructions",
                }
            pools[workload_class] = members
        manifest = {
            "harness": {"anchor_prove_ms": {
                "riscv": {"small": 1.0, "wide": 2.0, "deep": 3.0},
            }},
            "workload_registry": {
                "classes": {
                    name: {"scored": True}
                    for name in ("small", "wide", "deep", "xlarge", "huge")
                },
                "groups": {"riscv": {
                "enabled": True,
                "promotion_eligible": True,
                "board": "riscv",
                "report_schema": "riscv_proof_v1",
                "correctness_oracle": {
                    "authority": "stark-v",
                    "commit": "d478f783055aa0d73a93768a433a3c6c31c91d1c",
                    "required_features": ["parallel"],
                    "final_validator": True,
                },
                "gates_policy": {
                    "samples_per_round": 1, "min_rounds": 3, "max_rounds": 5,
                },
                "mechanism_telemetry": {
                    "fail_closed": True,
                    "required_fields": [
                        "total_steps", "n_components", "mean_proving_seconds",
                        "statement_sha256",
                    ],
                },
                "holdout_generator": {
                    "strategy": "seeded_workload_pool_v1", "pools": pools,
                },
                "workloads": workloads,
            }}},
        }
        (self.root / "autoresearch/MANIFEST.json").write_text(json.dumps(manifest))
        epochs = {"epochs": [{"aa_dispersion": {"riscv": {
            "small": 0.01, "wide": 0.01, "deep": 0.01,
        }}}]}
        (self.root / "autoresearch/ledger/epochs.json").write_text(json.dumps(epochs))
        (self.root / ".github/workflows/judge.yml").write_text(
            "name: autoresearch-judge\n"
        )
        (self.root / ".github/workflows/promote.yml").write_text(
            "name: autoresearch-promote\n"
        )
        self.receipt = self.root / "settings.json"
        receipt = settings_receipt()
        receipt["observed_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
        self.receipt.write_text(json.dumps(receipt))

    def test_complete_activation_contract_passes(self) -> None:
        self.assertEqual(activation_errors(
            self.root,
            board="riscv",
            settings_receipt=self.receipt,
            repository="teddyjfpender/stwo-zig",
        ), [])

    def test_disabled_board_and_irrelevant_holdout_fail(self) -> None:
        path = self.root / "autoresearch/MANIFEST.json"
        manifest = json.loads(path.read_text())
        group = manifest["workload_registry"]["groups"]["riscv"]
        group["enabled"] = False
        group["promotion_eligible"] = False
        group["holdout_generator"]["pools"]["small"] = ["unknown", "missing"]
        path.write_text(json.dumps(manifest))
        errors = activation_errors(
            self.root,
            board="riscv",
            settings_receipt=self.receipt,
            repository="teddyjfpender/stwo-zig",
        )
        self.assertIn("board riscv is disabled", errors)
        self.assertIn("board riscv is not promotion eligible", errors)
        self.assertTrue(any("holdout references" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
