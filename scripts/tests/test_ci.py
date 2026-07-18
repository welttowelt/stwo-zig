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
        self.assertIn("name: Metal AOT reproducible build", workflow)
        self.assertIn("run: python3 scripts/ci.py\n", workflow)
        self.assertIn("run: python3 scripts/ci.py --strict\n", workflow)
        self.assertIn("inputs.gate == 'strict'", workflow)

    def test_hosted_ci_exposes_fail_closed_riscv_candidate_evidence_lane(self) -> None:
        workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        self.assertIn("- riscv-candidate", workflow)
        self.assertIn("- riscv-promoted", workflow)
        self.assertIn("name: RISC-V release evidence", workflow)
        self.assertIn("startsWith(inputs.gate, 'riscv-')", workflow)
        self.assertEqual(2, workflow.count("!startsWith(inputs.gate, 'riscv-')"))
        self.assertIn("inputs.gate == 'riscv-candidate' && 'candidate' || 'promoted'", workflow)
        self.assertIn("id: riscv-release-state", workflow)
        self.assertIn("RISCV_ADAPTER_RELEASE_GATED = true", workflow)
        self.assertIn("steps.riscv-release-state.outputs.promoted == 'true'", workflow)
        self.assertIn("https://github.com/ClementWalter/stark-v", workflow)
        self.assertIn("STARK_V_REVISION: d478f783055aa0d73a93768a433a3c6c31c91d1c", workflow)
        self.assertIn("python3 scripts/riscv_release_gate.py", workflow)
        self.assertIn("--strict", workflow)
        self.assertIn('--phase "$RISCV_GATE_PHASE"', workflow)
        self.assertIn('--candidate "$(git rev-parse HEAD)"', workflow)
        self.assertIn("name: riscv-${{ env.RISCV_GATE_PHASE }}-evidence-${{ github.sha }}", workflow)
        self.assertIn("if-no-files-found: error", workflow)

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

    def test_hosted_metal_gate_builds_reproducible_aot_and_compiles_broader_graph(
        self,
    ) -> None:
        workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        self.assertIn(
            "xcode-select --print-path | grep -q '^/Applications/Xcode'",
            workflow,
        )
        self.assertIn("xcrun --sdk macosx --find metal", workflow)
        self.assertIn("xcrun --sdk macosx --find metallib", workflow)
        self.assertIn(
            "zig build metal-core-aot -Doptimize=ReleaseSafe",
            workflow,
        )
        self.assertIn("run: zig build metal-check -Doptimize=ReleaseSafe", workflow)
        self.assertNotIn("run: zig build metal-test", workflow)
        self.assertIn("python3 scripts/metal_core_aot_receipt.py build", workflow)
        self.assertIn("--builder zig-out/bin/metal-core-aot", workflow)
        self.assertIn("--output-dir \"$RUNNER_TEMP/native-metal-core-aot-acceptance\"", workflow)
        self.assertIn(
            '--receipt-out "$RUNNER_TEMP/native-metal-core-aot-acceptance/receipt.json"',
            workflow,
        )
        self.assertIn('--commit "$GITHUB_SHA"', workflow)
        self.assertNotIn("--probe", workflow)
        self.assertNotIn("metal-core-aot-probe", workflow)
        self.assertNotIn("metal-core-aot-acceptance -Doptimize", workflow)
        self.assertIn(
            "uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4",
            workflow,
        )
        for artifact in (
            "receipt.json",
            "receipt.json.sha256",
            "build-a",
            "build-b",
        ):
            self.assertIn(
                f"${{{{ runner.temp }}}}/native-metal-core-aot-acceptance/{artifact}",
                workflow,
            )
        self.assertIn("if-no-files-found: error", workflow)

        metal_products = (ROOT / "build_support/metal_products.zig").read_text(
            encoding="utf-8"
        )
        self.assertIn(
            "metal_check_step.dependOn(&metal_tests.step);", metal_products
        )
        self.assertNotIn(
            "metal_check_step.dependOn(&run_metal_tests.step);", metal_products
        )

    def test_safe_metal_math_compiles_with_macos_14_and_15_sdks(self) -> None:
        policy = (
            ROOT / "src/backends/metal/runtime/compile_options.h"
        ).read_text(encoding="utf-8")
        self.assertIn(
            "defined(__MAC_OS_X_VERSION_MAX_ALLOWED) && "
            "__MAC_OS_X_VERSION_MAX_ALLOWED >= 150000",
            policy,
        )
        self.assertIn("options.mathMode = MTLMathModeSafe;", policy)
        self.assertEqual(2, policy.count("options.fastMathEnabled = NO;"))
        self.assertIn("options.languageVersion = MTLLanguageVersion3_1;", policy)

        sources = (
            ROOT / "src/tools/metal_core_aot/probe.m",
            ROOT / "src/backends/metal/runtime/initialization.m",
            ROOT / "src/backends/metal/runtime/dynamic_evaluation.m",
        )
        for source in sources:
            text = source.read_text(encoding="utf-8")
            self.assertIn("stwo_zig_configure_safe_metal_compile_options(options);", text)
            self.assertNotIn("configure_eval_compile_options", text)
            self.assertNotIn("options.mathMode", text)
            self.assertNotIn("options.fastMathEnabled", text)

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
