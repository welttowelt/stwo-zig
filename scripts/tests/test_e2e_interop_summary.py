#!/usr/bin/env python3
"""Unit tests for e2e interop summary accounting."""

from __future__ import annotations

import importlib.util
import subprocess
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "scripts" / "e2e_interop.py"


def load_module():
    spec = importlib.util.spec_from_file_location("e2e_interop", MODULE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load module from {MODULE_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ComputeSummaryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.mod = load_module()

    def test_full_success_accounting(self) -> None:
        examples = ["plonk", "xor"]
        steps = [
            {"name": "plonk_rust_to_zig_verify", "status": "ok"},
            {"name": "plonk_zig_to_rust_verify", "status": "ok"},
            {"name": "xor_rust_to_zig_verify", "status": "ok"},
            {"name": "xor_zig_to_rust_verify", "status": "ok"},
            {
                "name": "plonk_rust_to_zig_tamper_reject",
                "status": "ok",
                "expect_failure": True,
                "rejection_class": self.mod.REJECTION_CLASS_VERIFIER,
            },
            {
                "name": "plonk_rust_to_zig_generator_tamper_reject",
                "status": "ok",
                "expect_failure": True,
                "rejection_class": self.mod.REJECTION_CLASS_METADATA,
            },
        ]

        summary = self.mod.compute_summary(examples=examples, steps=steps)
        self.assertEqual(summary["cases_total"], 4)
        self.assertEqual(summary["cases_executed"], 4)
        self.assertEqual(summary["cases_passed"], 4)
        self.assertEqual(summary["cases_failed"], 0)
        self.assertEqual(summary["tamper_cases_total"], 4 * len(self.mod.ACTIVE_MUTATIONS))
        self.assertEqual(summary["tamper_cases_executed"], 2)
        self.assertEqual(summary["tamper_cases_passed"], 2)
        self.assertEqual(summary["tamper_cases_failed"], 0)
        self.assertEqual(
            summary["tamper_rejection_classes"],
            {
                self.mod.REJECTION_CLASS_VERIFIER: 1,
                self.mod.REJECTION_CLASS_METADATA: 1,
            },
        )

    def test_partial_failure_accounting(self) -> None:
        examples = ["state_machine", "wide_fibonacci"]
        steps = [
            {"name": "state_machine_rust_to_zig_verify", "status": "ok"},
            {"name": "state_machine_zig_to_rust_verify", "status": "failed"},
            {
                "name": "state_machine_zig_to_rust_tamper_reject",
                "status": "failed",
                "expect_failure": True,
                "rejection_class": self.mod.REJECTION_CLASS_OTHER,
            },
            {
                "name": "state_machine_zig_to_rust_statement_tamper_reject",
                "status": "ok",
                "expect_failure": True,
                "rejection_class": self.mod.REJECTION_CLASS_VERIFIER,
            },
        ]

        summary = self.mod.compute_summary(examples=examples, steps=steps)
        self.assertEqual(summary["cases_total"], 4)
        self.assertEqual(summary["cases_executed"], 2)
        self.assertEqual(summary["cases_passed"], 1)
        self.assertEqual(summary["cases_failed"], 1)
        self.assertEqual(summary["tamper_cases_total"], 4 * len(self.mod.ACTIVE_MUTATIONS))
        self.assertEqual(summary["tamper_cases_executed"], 2)
        self.assertEqual(summary["tamper_cases_passed"], 1)
        self.assertEqual(summary["tamper_cases_failed"], 1)
        self.assertEqual(
            summary["tamper_rejection_classes"],
            {
                self.mod.REJECTION_CLASS_OTHER: 1,
                self.mod.REJECTION_CLASS_VERIFIER: 1,
            },
        )

    def test_panics_and_signals_are_robustness_failures(self) -> None:
        panic = self.mod.classify_rejection(
            "",
            "thread 'main' panicked at verifier.rs:1: index out of bounds",
            return_code=101,
        )
        signal = self.mod.classify_rejection("", "", return_code=-6)
        self.assertEqual(panic, self.mod.REJECTION_CLASS_ROBUSTNESS)
        self.assertEqual(signal, self.mod.REJECTION_CLASS_ROBUSTNESS)

    def test_controlled_verifier_error_remains_semantic_rejection(self) -> None:
        rejection = self.mod.classify_rejection(
            "",
            "Error: malformed proof rejected at verifier safety boundary",
            return_code=1,
        )
        self.assertEqual(rejection, self.mod.REJECTION_CLASS_VERIFIER)

    def test_run_step_refuses_to_accept_a_verifier_panic(self) -> None:
        steps = []
        process = subprocess.CompletedProcess(
            ["verifier"],
            101,
            stdout="",
            stderr="thread 'main' panicked at verifier.rs:1: index out of bounds",
        )
        with mock.patch.object(self.mod.subprocess, "run", return_value=process):
            with self.assertRaisesRegex(RuntimeError, "expected non-zero exit code"):
                self.mod.run_step(
                    name="panic_is_not_rejection",
                    cmd=["verifier"],
                    steps=steps,
                    expect_failure=True,
                    required_rejection_class=self.mod.REJECTION_CLASS_VERIFIER,
                )
        self.assertEqual(steps[0]["status"], "failed")
        self.assertEqual(
            steps[0]["rejection_class"],
            self.mod.REJECTION_CLASS_ROBUSTNESS,
        )


if __name__ == "__main__":
    unittest.main()
