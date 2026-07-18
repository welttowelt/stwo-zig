import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "cli"))
from stwo_perf import manifest as manifest_mod

REPO_ROOT = Path(__file__).resolve().parents[2]


class ManifestTest(unittest.TestCase):
    def setUp(self):
        self.m = manifest_mod.load(REPO_ROOT)

    def test_locked_paths(self):
        self.assertTrue(self.m.is_locked("autoresearch/ledger/promotions.tsv"))
        self.assertTrue(self.m.is_locked("scripts/ci.py"))
        self.assertTrue(self.m.is_locked("build.zig"))
        self.assertFalse(self.m.is_locked("src/prover/fri.zig"))

    def test_editable_rungs(self):
        self.assertEqual(self.m.path_rung("src/backends/cpu_scalar/mod.zig"), "s3")
        self.assertEqual(self.m.path_rung("src/prover/work_pool.zig"), "s4")
        self.assertIsNone(self.m.path_rung("README.md"))

    def test_judged_rung_is_mechanical_max(self):
        rung = self.m.judged_rung("s3", ["src/prover/work_pool.zig"])
        self.assertEqual(rung, "s4")
        rung = self.m.judged_rung("s1", ["src/core/fields/m31.zig"])
        self.assertEqual(rung, "s3")  # acceptance floor

    def test_classify_touched(self):
        violations, strays = self.m.classify_touched(
            ["vectors/reports/x.json", "src/prover/fri.zig", "docs/random.md"]
        )
        self.assertEqual(violations, ["vectors/reports/x.json"])
        self.assertEqual(strays, ["docs/random.md"])

    def test_workload_registry(self):
        small = self.m.workloads("small", board="core_cpu")
        self.assertTrue(small)
        self.assertTrue(all(w.workload_class == "small" for w in small))

    def test_groups_native_enabled_riscv_disabled(self):
        by_id = {g.group_id: g for g in self.m.groups()}
        self.assertIn("native", by_id)
        self.assertIn("riscv", by_id)
        native, riscv = by_id["native"], by_id["riscv"]
        self.assertTrue(native.enabled)
        self.assertEqual(native.board, "core_cpu")
        self.assertEqual(native.binary, "zig-out/bin/native-proof-bench-cpu")
        self.assertEqual(native.report_schema, "native_proof_v6")
        self.assertEqual(len(native.workloads), 3)
        self.assertFalse(riscv.enabled)
        self.assertEqual(riscv.board, "riscv")
        self.assertEqual(riscv.disabled_reason, "stark-v adapter pending release gate")
        self.assertEqual(riscv.binary, "zig-out/bin/stwo-zig")
        self.assertEqual(riscv.build_step, "zig build stwo-zig -Doptimize=ReleaseFast")
        self.assertEqual({w.workload_id for w in riscv.workloads},
                         {"riscv_fib_small", "riscv_alu"})
        self.assertTrue(all(w.args.startswith("bench --elf ") for w in riscv.workloads))
        self.assertTrue(all("--backend cpu" in w.args for w in riscv.workloads))

    def test_disabled_group_workloads_excluded_by_default(self):
        default_ids = {w.workload_id for w in self.m.workloads(board="core_cpu")}
        self.assertNotIn("riscv_fib_small", default_ids)
        self.assertNotIn("riscv_alu", default_ids)
        all_ids = {
            w.workload_id
            for w in self.m.workloads(include_disabled=True, board="riscv")
        }
        self.assertIn("riscv_fib_small", all_ids)
        self.assertIn("riscv_alu", all_ids)
        # every default workload comes from an enabled group
        enabled = {g.group_id for g in self.m.groups() if g.enabled}
        self.assertTrue(all(
            w.group_id in enabled for w in self.m.workloads(board="core_cpu")
        ))

    def test_workload_selection_requires_board(self):
        with self.assertRaises(manifest_mod.ManifestError):
            self.m.workloads("small")

    def test_unknown_group_raises(self):
        with self.assertRaises(manifest_mod.ManifestError):
            self.m.group("does-not-exist")

    def test_board_selection_never_pools_groups(self):
        self.assertEqual(
            {w.group_id for w in self.m.workloads("small", board="core_cpu")},
            {"native"},
        )
        self.assertEqual(self.m.workloads("small", board="riscv"), [])
        self.assertEqual(
            {w.group_id for w in self.m.workloads(
                "small", include_disabled=True, board="riscv",
            )},
            {"riscv"},
        )


class RegistryValidationTest(unittest.TestCase):
    def _base_raw(self) -> dict:
        return {
            "manifest_version": 2,
            "harness": {"anchor_commit": None},
            "editable_paths": [],
            "locked_paths": [],
            "gates_policy": {},
            "workload_registry": {
                "groups": {
                    "native": {
                        "enabled": True,
                        "board": "core_cpu",
                        "build_step": "true",
                        "binary": "bin/bench",
                        "report_schema": "native_proof_v6",
                        "workloads": {
                            "wf": {"class": "small", "args": "--x", "native_unit": "rows"},
                        },
                    },
                },
            },
        }

    def test_grouped_registry_validates(self):
        manifest_mod._validate(self._base_raw())  # must not raise

    def test_flat_v1_registry_rejected_with_migration_hint(self):
        raw = self._base_raw()
        raw["workload_registry"] = {
            "build_step": "true", "binary": "bin/bench", "workloads": {},
        }
        with self.assertRaises(manifest_mod.ManifestError) as ctx:
            manifest_mod._validate(raw)
        self.assertIn("groups", str(ctx.exception))

    def test_disabled_group_without_reason_rejected(self):
        raw = self._base_raw()
        raw["workload_registry"]["groups"]["riscv"] = {
            "enabled": False,
            "board": "riscv",
            "build_step": "true",
            "binary": "bin/riscv",
            "report_schema": "riscv_proof_v1",
            "workloads": {},
        }
        with self.assertRaises(manifest_mod.ManifestError) as ctx:
            manifest_mod._validate(raw)
        self.assertIn("disabled_reason", str(ctx.exception))

    def test_group_missing_required_key_rejected(self):
        raw = self._base_raw()
        del raw["workload_registry"]["groups"]["native"]["report_schema"]
        with self.assertRaises(manifest_mod.ManifestError) as ctx:
            manifest_mod._validate(raw)
        self.assertIn("report_schema", str(ctx.exception))

    def test_invalid_workload_class_rejected(self):
        raw = self._base_raw()
        raw["workload_registry"]["groups"]["native"]["workloads"]["wf"]["class"] = "huge"
        with self.assertRaises(manifest_mod.ManifestError):
            manifest_mod._validate(raw)

    def test_unknown_report_schema_rejected(self):
        raw = self._base_raw()
        raw["workload_registry"]["groups"]["native"]["report_schema"] = "made_up_v99"
        with self.assertRaises(manifest_mod.ManifestError) as ctx:
            manifest_mod._validate(raw)
        self.assertIn("unsupported report_schema", str(ctx.exception))

    def test_duplicate_board_ownership_rejected(self):
        raw = self._base_raw()
        raw["workload_registry"]["groups"]["other"] = {
            "enabled": True,
            "board": "core_cpu",
            "build_step": "true",
            "binary": "bin/other",
            "report_schema": "native_proof_v6",
            "workloads": {},
        }
        with self.assertRaises(manifest_mod.ManifestError) as ctx:
            manifest_mod._validate(raw)
        self.assertIn("cross-group workload pooling", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()
