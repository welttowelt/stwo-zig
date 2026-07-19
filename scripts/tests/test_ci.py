import re
import subprocess
import sys
import unittest
from pathlib import Path

from scripts.ci import command_plan
from scripts.release_evidence import gate_steps

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
        self.assertIn("- riscv-produce-candidate", workflow)
        self.assertIn("- riscv-produce-promoted", workflow)
        self.assertIn("candidate_sha:", workflow)
        self.assertIn("candidate_ref:", workflow)
        self.assertIn("producer_run_id:", workflow)
        self.assertIn("name: RISC-V exhaustive release evidence", workflow)
        self.assertIn("name: RISC-V fast release gate", workflow)
        self.assertIn(
            "github.event_name == 'workflow_dispatch' && github.ref == 'refs/heads/main'",
            workflow,
        )
        standard_or_strict = (
            "github.event_name != 'workflow_dispatch' || inputs.gate == 'standard' ||\n"
            "      inputs.gate == 'strict'"
        )
        self.assertEqual(2, workflow.count(standard_or_strict))
        self.assertIn("inputs.gate == 'riscv-candidate' && 'candidate' || 'promoted'", workflow)
        self.assertIn("id: riscv-release-state", workflow)
        self.assertIn("RISCV_ADAPTER_RELEASE_GATED = true", workflow)
        self.assertIn("https://github.com/ClementWalter/stark-v", workflow)
        self.assertIn("STARK_V_REVISION: d478f783055aa0d73a93768a433a3c6c31c91d1c", workflow)
        self.assertIn("rustup toolchain install nightly-2026-01-29 --profile minimal", workflow)
        self.assertIn("submodule update --init --recursive --depth=1", workflow)
        self.assertIn("STWO_ZIG_RISCV_ORACLE_CACHE_DIR", workflow)
        self.assertIn("actions/cache@0057852bfaa89a56745cba8c7296529d2fc39830", workflow)
        self.assertIn("name: Enforce owner-dispatched cache writer scope", workflow)
        self.assertIn('test "$GITHUB_REPOSITORY" = teddyjfpender/stwo-zig', workflow)
        self.assertIn('test "$GITHUB_EVENT_NAME" = workflow_dispatch', workflow)
        self.assertIn('test "$GITHUB_REF" = refs/heads/main', workflow)
        self.assertIn("id: riscv-oracle-cache", workflow)
        self.assertIn("riscv_release_oracle.py cache-key", workflow)
        self.assertIn(
            "key: riscv-oracle-${{ steps.riscv-oracle-cache.outputs.key_sha256 }}",
            workflow,
        )
        self.assertNotIn("Restore authenticated Stark-V helper cache", workflow)
        self.assertIn(
            "restore-keys: riscv-cpu-static-v1-${{ runner.os }}-zig-0.15.2-",
            workflow,
        )
        self.assertIn("python3 scripts/riscv_release_gate.py", workflow)
        self.assertIn("--strict", workflow)
        self.assertIn('--candidate "$RISCV_CANDIDATE_SHA"', workflow)
        self.assertIn("python3 scripts/riscv_release_bundle.py pack", workflow)
        self.assertIn("python3 scripts/riscv_release_bundle.py verify", workflow)
        self.assertIn("--trust-context", workflow)
        self.assertIn(
            "riscv-exhaustive-bundle-${{ env.RISCV_CANDIDATE_SHA }}-${{ github.run_id }}-${{ github.run_attempt }}",
            workflow,
        )
        self.assertIn("riscv_release_bundle.py verify-anchor", workflow)
        self.assertIn("riscv_release_challenge.py issue", workflow)
        self.assertIn("riscv_release_challenge.py execute", workflow)
        self.assertIn("stwo-zig-riscv-cpu-static", workflow)
        self.assertIn("riscv_sandbox_adversary.py", workflow)
        self.assertIn("riscv_candidate_sandbox_probe.c", workflow)
        self.assertIn('"--protocol", "secure"', (
            ROOT / "scripts/riscv_release_challenge_lib/execution.py"
        ).read_text(encoding="utf-8"))
        self.assertIn("actions/artifacts/${{ steps.riscv-producer.outputs.artifact_id }}/zip", workflow)
        self.assertIn('test "$actual_digest" = "${{ steps.riscv-producer.outputs.artifact_digest }}"', workflow)
        self.assertIn('python3 "$RUNNER_TEMP/riscv_release_policy.py" extract', workflow)
        self.assertNotIn("actions/download-artifact@", workflow)
        fast = workflow.split("  riscv-fast-release-gate:", 1)[1].split(
            "  architecture-session:", 1
        )[0]
        self.assertNotIn("riscv_staged_smoke.py", fast)
        self.assertNotIn("--profile fast", fast)
        self.assertIn("riscv-release-challenge-result-v1", fast)
        self.assertIn("riscv_release_bundle.py verify-anchor", fast)
        self.assertLess(
            fast.index("riscv_release_challenge.py issue"),
            fast.index("riscv_release_challenge.py execute"),
        )
        self.assertLess(fast.index("actual_digest="), fast.index("riscv_release_policy.py\" extract"))
        self.assertLess(
            fast.index("riscv_release_policy.py\" extract"),
            fast.index("name: Verify reusable exhaustive anchor"),
        )
        self.assertIn("if-no-files-found: error", workflow)

    def test_fast_riscv_gate_cannot_cancel_or_confuse_anchor_and_candidate(self) -> None:
        workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        self.assertIn("group: riscv-exhaustive-${{", workflow)
        self.assertIn("group: riscv-fast-${{ inputs.candidate_sha }}-${{ inputs.producer_run_id }}", workflow)
        self.assertEqual(2, workflow.count("cancel-in-progress: false"))
        self.assertIn("timeout-minutes: 3", workflow)
        self.assertIn(".timing.wall_duration_ns <= 180000000000", workflow)
        self.assertIn('[[ "$RISCV_CANDIDATE_SHA" =~ ^[0-9a-f]{40}$ ]]', workflow)
        self.assertIn('[[ "$RISCV_CANDIDATE_REF" == refs/heads/* ]]', workflow)
        self.assertIn("branches-where-head", workflow)
        self.assertIn('test "$producer_event" = workflow_dispatch', workflow)
        self.assertIn('test "$(jq -r .repository.id <<<"$producer")" = "$TRUSTED_REPOSITORY_ID"', workflow)
        self.assertIn('test "$(jq -r .actor.id <<<"$producer")" = "$TRUSTED_OWNER_ID"', workflow)
        self.assertIn('test "$(jq -r .triggering_actor.id <<<"$producer")" = "$TRUSTED_OWNER_ID"', workflow)
        self.assertIn('.name == "RISC-V exhaustive release evidence"', workflow)
        self.assertIn('.conclusion == "success"', workflow)
        self.assertIn("artifact_digest=$digest", workflow)
        self.assertIn("anchor_candidate=$anchor_candidate", workflow)
        self.assertIn("riscv-exhaustive-bundle-[0-9a-f]{40}", workflow)
        self.assertIn(".candidate.sha", workflow)
        self.assertIn('test "$(jq -r .head_sha <<<"$run")" = "$GITHUB_SHA"', workflow)
        self.assertNotIn('test "$(jq -r .conclusion <<<"$producer")" = success', workflow)

    def test_riscv_oracle_cache_identity_precedes_exact_restore(self) -> None:
        workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        producer = workflow.split("  riscv-release-evidence:", 1)[1].split(
            "  riscv-fast-release-gate:", 1
        )[0]
        install = producer.index("name: Install pinned Rust toolchains")
        checkout = producer.index("name: Checkout pinned Stark-V oracle")
        recursive = producer.index("submodule update --init --recursive --depth=1")
        trusted_scope = producer.index("name: Enforce owner-dispatched cache writer scope")
        identity = producer.index("name: Compute exact Stark-V helper cache identity")
        restore = producer.index("uses: actions/cache@")
        self.assertLess(install, checkout)
        self.assertLess(checkout, recursive)
        self.assertLess(recursive, trusted_scope)
        self.assertLess(trusted_scope, identity)
        self.assertLess(identity, restore)
        self.assertNotIn("hashFiles(", producer)

    def test_riscv_policy_is_trusted_before_candidate_code_executes(self) -> None:
        workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        producer = workflow.split("  riscv-release-evidence:", 1)[1].split(
            "  riscv-fast-release-gate:", 1
        )[0]
        trusted_checkout = producer.index("name: Checkout trusted main release policy")
        capture = producer.index("name: Capture trusted main release policy")
        candidate_checkout = producer.index("name: Checkout exact candidate")
        compare = producer.index("name: Require candidate release policy matches trusted main")
        candidate_execution = producer.index("name: Detect promoted adapter")
        self.assertLess(trusted_checkout, capture)
        self.assertLess(capture, candidate_checkout)
        self.assertLess(candidate_checkout, compare)
        self.assertLess(compare, candidate_execution)
        self.assertIn('--policy-context "$RUNNER_TEMP/riscv-policy-match.json"', producer)

        fast = workflow.split("  riscv-fast-release-gate:", 1)[1]
        self.assertLess(
            fast.index("name: Resolve producer workflow trust root"),
            fast.index("name: Checkout current trusted-main release policy"),
        )
        self.assertLess(
            fast.index("name: Require candidate release policy matches current trusted main"),
            fast.index("name: Require requested release phase"),
        )
        self.assertLess(
            fast.index("name: Require candidate release policy matches current trusted main"),
            fast.index("name: Restore exact-candidate Zig build cache"),
        )
        self.assertLess(
            fast.index("name: Restore exact-candidate Zig build cache"),
            fast.index("name: Build focused static candidate prover and diagnostic"),
        )

    def test_riscv_jobs_initialize_runner_paths_at_step_runtime(self) -> None:
        workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        producer = workflow.split("  riscv-release-evidence:", 1)[1].split(
            "  riscv-fast-release-gate:", 1
        )[0]
        fast = workflow.split("  riscv-fast-release-gate:", 1)[1].split(
            "  architecture-session:", 1
        )[0]
        self.assertNotIn("${{ runner.tool_cache }}", producer)
        self.assertNotIn("${{ runner.temp }}", fast)
        self.assertIn("$RUNNER_TOOL_CACHE/stwo-zig/riscv-oracle", producer)
        self.assertIn("$RUNNER_TEMP/riscv-exhaustive-bundle", fast)

    def test_architecture_dispatch_is_a_protected_multi_host_receipt_protocol(self) -> None:
        workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        self.assertIn("- architecture", workflow)
        jobs = {
            job: workflow.split(f"  {job}:", 1)[1].split("\n  architecture-", 1)[0]
            for job in (
                "architecture-session",
                "architecture-linux",
                "architecture-macos",
                "architecture-verify",
            )
        }
        for job, body in jobs.items():
            self.assertIn("inputs.gate == 'architecture'", body)
            self.assertIn("github.ref == 'refs/heads/main'", body)
            self.assertIn("python3 scripts/architecture_ci_trust.py", body)
            self.assertIn(f"--expected-job {job}", body)
        self.assertNotIn("pull_request", "".join(jobs.values()))

        linux = jobs["architecture-linux"]
        macos = jobs["architecture-macos"]
        verifier = jobs["architecture-verify"]
        self.assertIn("verify-anchor", (
            ROOT / "conformance/build-architecture-ci-plan-v1.json"
        ).read_text(encoding="utf-8"))
        self.assertNotIn("build-and-compare", linux)
        self.assertIn(
            'artifact_name="build-architecture-linux-$GITHUB_SHA-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"',
            linux,
        )
        self.assertIn(
            'artifact_name="build-architecture-macos-$GITHUB_SHA-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"',
            macos,
        )
        self.assertIn("path: ${{ runner.temp }}/linux.json", linux)
        self.assertIn("path: ${{ runner.temp }}/macos.json", macos)
        self.assertIn("actions/artifacts/$artifact_id/zip", verifier)
        self.assertNotIn("actions/download-artifact@", verifier)
        self.assertIn("architecture_ci_artifact.py select", verifier)
        self.assertIn("architecture_ci_artifact.py extract", verifier)
        self.assertIn("build_architecture_receipt.py verify", verifier)
        self.assertIn("needs: [architecture-session, architecture-linux, architecture-macos]", verifier)

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
        self.assertEqual(3, build_graph.count('"scripts/zig_protocol_test.py"'))
        gate_archive = "zig-out/release-evidence/native/interop-history"
        self.assertEqual(1, build.count(gate_archive))
        self.assertEqual(1, build.count('"--archive-dir"'))
        self.assertEqual(2, build.count("b.addSystemCommand(native_interop_gate_command)"))
        transitive_commands = {
            'b.addSystemCommand(&.{ "zig", "build", "test-riscv", optimize_arg })': 2,
            'b.addSystemCommand(&.{ "zig", "build", "test-riscv-prover", optimize_arg })': 2,
            'b.addSystemCommand(&.{ "python3", "scripts/riscv_trace_vectors.py" })': 2,
            # One additional standalone public API-parity build target is expected.
            'b.addSystemCommand(&.{ "python3", "scripts/check_api_parity.py" })': 3,
        }
        for command, expected_count in transitive_commands.items():
            self.assertEqual(expected_count, build.count(command))
        self.assertEqual(
            0,
            subprocess.run(
                ["git", "check-ignore", "-q", gate_archive],
                cwd=ROOT,
                check=False,
            ).returncode,
        )
        interop_steps = [step for step in gate_steps("strict") if step["name"] == "interop"]
        self.assertEqual(1, len(interop_steps))
        self.assertIn(f"--archive-dir {gate_archive}", interop_steps[0]["command"])

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
        metal_job = workflow.split("  metal-acceptance:", 1)[1].split(
            "  riscv-release-evidence:", 1
        )[0]
        self.assertIn(
            "xcode-select --print-path | grep -q '^/Applications/Xcode'",
            metal_job,
        )
        self.assertIn("xcrun --sdk macosx --find metal", metal_job)
        self.assertIn("xcrun --sdk macosx --find metallib", metal_job)
        self.assertIn("name: Setup Python", metal_job)
        self.assertIn('python-version: "3.13"', metal_job)
        self.assertIn(
            "zig build metal-eval-prepare -Doptimize=ReleaseFast", metal_job
        )
        self.assertIn(
            "zig build metal-eval-source -Doptimize=ReleaseFast", metal_job
        )
        self.assertIn("zig-out/bin/metal-eval-source", metal_job)
        self.assertIn("-mmacosx-version-min=14.0", metal_job)
        self.assertIn("-std=metal3.1", metal_job)
        self.assertIn("-fno-fast-math", metal_job)
        self.assertIn("-Werror", metal_job)
        self.assertIn("STWO_ZIG_COMPOSITION_METALLIB", metal_job)
        self.assertIn("STWO_ZIG_ALLOW_EXPLICIT_NO_METAL_DEVICE=1", metal_job)
        self.assertIn(
            "SnPieCompositionBundleTest.test_sn1_retarget_loads_in_zig_with_existing_metallib",
            metal_job,
        )
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
        self.assertNotIn("--probe", metal_job)
        self.assertNotIn("metal-core-aot-probe", metal_job)
        self.assertNotIn("metal-core-aot-acceptance -Doptimize", metal_job)
        self.assertIn(
            "uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02  # v4",
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
            "const install_metal_eval_prepare = b.addInstallArtifact(",
            metal_products,
        )
        self.assertIn(
            "metal_eval_prepare_step.dependOn(&install_metal_eval_prepare.step);",
            metal_products,
        )
        self.assertNotIn(
            "b.getInstallStep().dependOn(&install_metal_eval_prepare.step);",
            metal_products,
        )
        self.assertIn(
            "const install_metal_eval_source = b.addInstallArtifact(",
            metal_products,
        )
        self.assertIn(
            "metal_eval_source_step.dependOn(&install_metal_eval_source.step);",
            metal_products,
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
