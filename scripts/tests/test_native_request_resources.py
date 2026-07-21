from __future__ import annotations

import unittest

from scripts.tests.native_proof_matrix_support import MODULE, args, make_report


class NativeRequestResourceTests(unittest.TestCase):
    def test_request_resources_are_bound_to_request_and_proof(self) -> None:
        workload = MODULE.Workload.wide_fibonacci(10, 8)
        mutations = (
            ("measured_warmups", 9, "warmups differ"),
            ("measured_samples", 4, "samples differ"),
            ("canonical_proof_bytes", 1, "proof bytes disagree"),
            ("energy_nj", 0, "must be positive"),
        )
        for field, value, message in mutations:
            report = make_report("cpu", workload)
            report["resources"][field] = value
            with self.subTest(field=field), self.assertRaisesRegex(
                MODULE.MatrixError, message
            ):
                MODULE.validate_report(report, "cpu", workload, args())

        report = make_report("cpu", workload)
        report["resources"].update({
            "source": "unsupported",
            "lifetime_peak_physical_footprint_bytes": None,
            "energy_nj": None,
            "instructions": None,
            "cycles": None,
            "complete": False,
            "unavailable_reason": "proc_pid_rusage_v6 is available only on Darwin",
        })
        _, blockers = MODULE.validate_report(report, "cpu", workload, args())
        self.assertIn("cpu_request_resources_incomplete", blockers)


if __name__ == "__main__":
    unittest.main()
