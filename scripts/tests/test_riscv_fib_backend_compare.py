import contextlib
import copy
import importlib.util
import io
import json
import types
import unittest
from unittest import mock
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "riscv_fib_backend_compare.py"
SPEC = importlib.util.spec_from_file_location("riscv_fib_backend_compare", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


SAMPLE = """\
Execute:  113.9ms  (2499997 cycles, 21948 kHz)
Prove:    306.3ms
Trace cells: preprocessed=8061026 main=94452144 implicit-zero=165675936 committed=94452144
Committed cells/cycle: 37.78
Verify:   0.6ms
Total:    420.9ms
Run+Prove:420.2ms  (5949.5 kHz)
"""


class FibBackendCompareTests(unittest.TestCase):
    def test_parse_diagnostic_pcs_fri_sample(self):
        parsed = MODULE.parse_benchmark_output(SAMPLE)
        self.assertEqual(parsed["cycles"], 2_499_997)
        self.assertEqual(parsed["trace_cells"]["committed"], 94_452_144)
        self.assertAlmostEqual(parsed["prove_mhz"], 2_499_997 / 306.3 / 1000)
        self.assertAlmostEqual(parsed["cli_total_mhz"], 2_499_997 / 420.9 / 1000)
        self.assertTrue(parsed["pcs_fri_accepted_by_shared_verifier"])
        self.assertEqual(parsed["soundness_status"], "diagnostic_pcs_fri_only")
        self.assertNotIn("proof_verified", parsed)

    def test_emitted_report_classification_is_fail_closed(self):
        args = types.SimpleNamespace(
            sizes=[500_000],
            warmups=0,
            repeats=1,
            pow_bits=10,
            n_queries=3,
            timeout_s=1.0,
            pause_s=0.0,
            cpu_bin=MODULE_PATH,
            metal_bin=MODULE_PATH,
            output=None,
        )
        sample = MODULE.attach_e2e_metrics(
            MODULE.parse_benchmark_output(SAMPLE),
            500_000,
            0.47,
        )

        stdout = io.StringIO()
        stderr = io.StringIO()
        with (
            mock.patch.object(MODULE, "parse_args", return_value=args),
            mock.patch.object(MODULE, "run_sample", side_effect=lambda *unused: copy.deepcopy(sample)),
            contextlib.redirect_stdout(stdout),
            contextlib.redirect_stderr(stderr),
        ):
            self.assertEqual(MODULE.main(), 0)

        report = json.loads(stdout.getvalue())
        self.assertEqual(report["schema_version"], 3)
        self.assertEqual(report["soundness_status"], "diagnostic_pcs_fri_only")
        self.assertTrue(report["no_trace_dependent_air_constraints"])
        self.assertTrue(report["shared_verifier"])
        self.assertFalse(report["sound_proof_evidence"])
        self.assertFalse(report["production_evidence"])
        self.assertFalse(report["correctness_parity_evidence"])

        for backend in ("cpu", "metal"):
            raw_sample = report["rows"][0][backend]["raw_samples"][0]
            self.assertTrue(raw_sample["pcs_fri_accepted_by_shared_verifier"])
            self.assertEqual(raw_sample["soundness_status"], "diagnostic_pcs_fri_only")
            self.assertNotIn("proof_verified", raw_sample)

        rendered = stdout.getvalue()
        self.assertNotIn('"proof_verified"', rendered)
        self.assertNotIn('"proof_acceptance"', rendered)

    def test_parse_rejects_missing_verification(self):
        with self.assertRaisesRegex(ValueError, "verify timing"):
            MODULE.parse_benchmark_output(SAMPLE.replace("Verify:   0.6ms\n", ""))

    def test_parse_rejects_missing_total(self):
        with self.assertRaisesRegex(ValueError, "total timing"):
            MODULE.parse_benchmark_output(SAMPLE.replace("Total:    420.9ms\n", ""))

    def test_attach_e2e_metrics(self):
        parsed = MODULE.attach_e2e_metrics(
            MODULE.parse_benchmark_output(SAMPLE),
            500_000,
            0.47,
        )
        self.assertAlmostEqual(parsed["e2e_mhz"], 2_499_997 / 0.47 / 1_000_000)
        self.assertAlmostEqual(parsed["prove_fib_iterations_per_s"], 500_000 / 0.3063)
        self.assertAlmostEqual(parsed["e2e_fib_iterations_per_s"], 500_000 / 0.47)
        self.assertAlmostEqual(parsed["process_overhead_ms"], 49.1)

    def test_attach_e2e_metrics_rejects_wrong_cycle_count(self):
        with self.assertRaisesRegex(ValueError, "cycles inconsistent"):
            MODULE.attach_e2e_metrics(
                MODULE.parse_benchmark_output(SAMPLE),
                500_001,
                0.47,
            )

    def test_geometry_key_rejects_cycle_mismatch(self):
        lhs = MODULE.parse_benchmark_output(SAMPLE)
        rhs = dict(lhs)
        rhs["cycles"] += 1
        self.assertNotEqual(MODULE.geometry_key(lhs), MODULE.geometry_key(rhs))


if __name__ == "__main__":
    unittest.main()
