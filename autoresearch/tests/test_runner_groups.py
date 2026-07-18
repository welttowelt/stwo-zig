"""Group-aware runner behavior: loud skips and honest missing-binary failures."""

import contextlib
import io
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "cli"))
from stwo_perf import manifest as manifest_mod, runner
from stwo_perf.manifest import Manifest

FAKE_REPORT = (
    '{"timing":{"prove_seconds":{"median":0.001}},'
    '"proof":{"verified_samples":1,"all_samples_byte_identical":true},'
    '"resources":{"peak_rss_kib":1024}}'
)

GATES_POLICY = {
    "ci_level": 0.95,
    "theta_floor": 0.01,
    "dispersion_multiplier": 2.0,
    "targeted_class_budget": 1.02,
    "matrix_row_budget": 1.05,
    "warmups": 0,
    "samples_per_round": 1,
    "min_rounds": 3,
    "max_rounds": 3,
    "wall_clock_cap_seconds": {"small": 60, "wide": 60, "deep": 60},
}


def make_raw(riscv_enabled: bool, native_binary: str = "bin/fakebench") -> dict:
    riscv = {
        "enabled": riscv_enabled,
        "build_step": "true",
        "binary": "bin/missing-riscv-bench",
        "report_schema": "riscv_proof_v1",
        "workloads": {
            "riscv_alu": {
                "class": "wide",
                "args": "--elf vectors/riscv_elfs/alu_test.elf "
                        "--warmups {warmups} --samples {samples}",
                "native_unit": "executed instructions",
            },
        },
    }
    if not riscv_enabled:
        riscv["disabled_reason"] = "stark-v adapter pending release gate"
    return {
        "manifest_version": 2,
        "harness": {"anchor_commit": None},
        "editable_paths": [],
        "locked_paths": [],
        "gates_policy": GATES_POLICY,
        "workload_registry": {
            "groups": {
                "native": {
                    "enabled": True,
                    "build_step": "true",
                    "binary": native_binary,
                    "report_schema": "native_proof_v4",
                    "workloads": {
                        "wf_small": {
                            "class": "small",
                            "args": "--warmups {warmups} --samples {samples}",
                            "native_unit": "trace rows",
                        },
                    },
                },
                "riscv": riscv,
            },
        },
    }


class RunnerGroupTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        bench = self.root / "bin" / "fakebench"
        bench.parent.mkdir(parents=True)
        bench.write_text(f"#!/bin/sh\necho '{FAKE_REPORT}'\n")
        os.chmod(bench, 0o755)
        self.out_dir = self.root / "runs"

    def tearDown(self):
        self.tmp.cleanup()

    def _manifest(self, **kwargs) -> Manifest:
        raw = make_raw(**kwargs)
        manifest_mod._validate(raw)  # fixture must be a valid v2 manifest
        return Manifest(root=self.root, raw=raw)

    def test_disabled_group_is_skipped_loudly_with_reason(self):
        m = self._manifest(riscv_enabled=False)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            result = runner.evaluate_aa(self.root, m, "small", self.out_dir)
        self.assertIn(
            "skipped group riscv: stark-v adapter pending release gate",
            buf.getvalue(),
        )
        self.assertEqual(
            result["skipped_groups"],
            [{"group": "riscv", "reason": "stark-v adapter pending release gate"}],
        )
        self.assertEqual(result["workload"], "wf_small")

    def test_announce_helper_reports_every_disabled_group(self):
        m = self._manifest(riscv_enabled=False)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            skipped = runner.announce_skipped_groups(m)
        self.assertEqual([s["group"] for s in skipped], ["riscv"])
        self.assertIn("skipped group riscv:", buf.getvalue())

    def test_disabled_group_workloads_never_run(self):
        m = self._manifest(riscv_enabled=False)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf), self.assertRaises(runner.RunError) as ctx:
            runner.evaluate_aa(self.root, m, "wide", self.out_dir)
        self.assertIn("no workloads registered for class wide", str(ctx.exception))
        self.assertIn("skipped group riscv", buf.getvalue())

    def test_enabled_group_with_missing_binary_fails_clearly(self):
        m = self._manifest(riscv_enabled=True)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf), self.assertRaises(runner.RunError) as ctx:
            runner.evaluate_aa(self.root, m, "wide", self.out_dir)
        message = str(ctx.exception)
        self.assertIn("riscv", message)
        self.assertIn("bin/missing-riscv-bench", message)
        self.assertIn("refusing to fabricate", message)
        # no fabricated report may exist for the missing binary
        self.assertFalse(list(self.out_dir.glob("riscv_alu.*.json")))

    def test_bench_once_checks_binary_before_running(self):
        m = self._manifest(riscv_enabled=True)
        self.out_dir.mkdir(parents=True, exist_ok=True)
        workload = m.workloads("wide")[0]
        with self.assertRaises(runner.RunError) as ctx:
            runner.bench_once(self.root, m, workload, 0, 1, self.out_dir, "a1")
        self.assertIn("not found", str(ctx.exception))

    def test_enabled_native_group_still_scores(self):
        m = self._manifest(riscv_enabled=False)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            result = runner.evaluate_aa(self.root, m, "small", self.out_dir)
        self.assertEqual(result["rounds"], 3)
        self.assertEqual(result["aa_r"], 1.0)


if __name__ == "__main__":
    unittest.main()
