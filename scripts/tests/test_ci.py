import re
import sys
import unittest
from pathlib import Path

from scripts.ci import command_plan

ROOT = Path(__file__).resolve().parents[2]
PINNED_ACTION_RE = re.compile(r"^\s*uses:\s*[^@\s]+@[0-9a-f]{40}(?:\s+#.*)?$")


class CiTests(unittest.TestCase):
    def test_standard_plan_runs_tooling_then_release_gate(self) -> None:
        plan = command_plan(False, "ReleaseFast")
        self.assertEqual(sys.executable, plan[0][0])
        self.assertIn("scripts/tests", plan[0])
        self.assertEqual(
            ["zig", "build", "release-gate", "-Doptimize=ReleaseFast"],
            plan[1],
        )

    def test_strict_plan_selects_strict_gate(self) -> None:
        self.assertEqual("release-gate-strict", command_plan(True, "ReleaseSafe")[1][2])

    def test_hosted_ci_exposes_standard_and_strict_shared_entrypoints(self) -> None:
        workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        self.assertIn("run: python3 scripts/ci.py\n", workflow)
        self.assertIn("run: python3 scripts/ci.py --strict\n", workflow)
        self.assertIn("inputs.gate == 'strict'", workflow)

    def test_hosted_ci_accepts_exact_commit_aot_evidence_tags(self) -> None:
        workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        self.assertIn('tags: ["aot-evidence-*"]', workflow)

    def test_release_gates_run_the_complete_test_graph_in_requested_mode(self) -> None:
        build = (ROOT / "build.zig").read_text(encoding="utf-8")
        verification_products = (
            ROOT / "build_support/verification_products.zig"
        ).read_text(encoding="utf-8")
        build_graph = build + verification_products
        full_test_command = 'b.addSystemCommand(&.{ "zig", "build", "test", optimize_arg })'
        self.assertEqual(2, build.count(full_test_command))
        self.assertIn(
            'b.addSystemCommand(&.{ "zig", "test", "src/stwo_deep.zig", zig_optimize_arg })',
            build_graph,
        )
        self.assertEqual(
            3,
            build_graph.count(
                'b.addSystemCommand(&.{ "zig", "test", "src/stwo_deep.zig", zig_optimize_arg })'
            ),
        )

    def test_pre_push_and_hosted_ci_use_the_same_standard_entrypoint(self) -> None:
        pre_push = (ROOT / ".githooks/pre-push").read_text(encoding="utf-8")
        self.assertIn("exec python3 scripts/ci.py", pre_push)
        self.assertNotIn("zig build", pre_push)

        workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        self.assertIn("run: python3 scripts/ci.py\n", workflow)

    def test_hosted_metal_gate_accepts_aot_core_and_compiles_broader_graph(self) -> None:
        workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        self.assertIn(
            "run: zig build metal-core-aot-acceptance -Doptimize=ReleaseSafe",
            workflow,
        )
        self.assertIn("run: zig build metal-check -Doptimize=ReleaseSafe", workflow)
        self.assertNotIn("run: zig build metal-test", workflow)
        self.assertIn("python3 scripts/metal_core_aot_receipt.py", workflow)
        self.assertIn(
            "uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4",
            workflow,
        )
        self.assertIn("if-no-files-found: error", workflow)

        aot_products = (ROOT / "build_support/metal_core_aot.zig").read_text(
            encoding="utf-8"
        )
        self.assertIn('"metal-core-aot-acceptance"', aot_products)
        self.assertIn('build_bundle.addArgs(&.{ "build", "--output-dir" });', aot_products)
        self.assertIn('run_probe.addArg("--trust-anchor");', aot_products)

        probe = (ROOT / "src/tools/metal_core_aot/probe.m").read_text(
            encoding="utf-8"
        )
        self.assertIn("library.functionNames", probe)
        self.assertIn("actual.count != expected_count", probe)
        self.assertIn("function.functionConstantsDictionary.count != 0u", probe)

        metal_products = (ROOT / "build_support/metal_products.zig").read_text(
            encoding="utf-8"
        )
        self.assertIn(
            "metal_check_step.dependOn(&metal_tests.step);", metal_products
        )
        self.assertNotIn(
            "metal_check_step.dependOn(&run_metal_tests.step);", metal_products
        )

    def test_all_hosted_actions_are_commit_pinned(self) -> None:
        workflows = sorted((ROOT / ".github/workflows").glob("*.yml"))
        self.assertTrue(workflows)
        for workflow in workflows:
            for line_number, line in enumerate(workflow.read_text(encoding="utf-8").splitlines(), 1):
                if "uses:" not in line:
                    continue
                self.assertRegex(
                    line,
                    PINNED_ACTION_RE,
                    f"{workflow.relative_to(ROOT)}:{line_number} must pin an action commit",
                )


if __name__ == "__main__":
    unittest.main()
