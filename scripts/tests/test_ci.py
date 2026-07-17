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

    def test_release_gates_run_the_complete_test_graph_in_requested_mode(self) -> None:
        build = (ROOT / "build.zig").read_text(encoding="utf-8")
        full_test_command = 'b.addSystemCommand(&.{ "zig", "build", "test", optimize_arg })'
        self.assertEqual(2, build.count(full_test_command))
        self.assertIn(
            'b.addSystemCommand(&.{ "zig", "test", "src/stwo_deep.zig", zig_optimize_arg })',
            build,
        )

    def test_hosted_metal_gate_is_compile_only(self) -> None:
        workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        self.assertIn("run: zig build metal-check -Doptimize=ReleaseSafe", workflow)
        self.assertNotIn("run: zig build metal-test", workflow)

        build = (ROOT / "build.zig").read_text(encoding="utf-8")
        self.assertIn("metal_check_step.dependOn(&metal_tests.step);", build)
        self.assertNotIn("metal_check_step.dependOn(&run_metal_tests.step);", build)

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
