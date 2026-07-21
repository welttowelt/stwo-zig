"""Group-aware runner behavior: loud skips and honest missing-binary failures."""

import contextlib
import hashlib
import io
import json
import os
import shlex
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "cli"))
from stwo_perf import manifest as manifest_mod, runner
from stwo_perf.manifest import Manifest

FAKE_REPORT = (
    '{"schema_version":6,"timing":{"prove_seconds":{"median":0.001}},'
    '"proof":{"verified_samples":1,"all_samples_byte_identical":true,'
    '"samples":[{"sha256":"' + "a" * 64 + '"}]},'
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
        "board": "riscv",
        "build_step": "true",
        "binary": "bin/missing-riscv-bench",
        "report_schema": "riscv_proof_v1",
        "mechanism_telemetry": {
            "fail_closed": True,
            "required_fields": [
                "total_steps", "n_components", "mean_execution_seconds",
                "mean_witness_seconds", "mean_proving_seconds",
                "mean_verification_seconds", "statement_sha256",
                "transcript_state_blake2s",
            ],
        },
        "workloads": {
            "riscv_alu": {
                "class": "wide",
                "args": "--elf vectors/riscv_elfs/alu_test.elf "
                        "{admission} --warmups {warmups} --samples {samples}",
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
        "qualification_policy": {
            "required_checks": ["allowed_diff"],
            "max_active_per_user": 1,
        },
        "workload_registry": {
            "groups": {
                "native": {
                    "enabled": True,
                    "board": "core_cpu",
                    "build_step": "true",
                    "binary": native_binary,
                    "report_schema": "native_proof_v6",
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

    def _set_riscv_phase(self, promoted: bool) -> None:
        capability = self.root / "src/products/riscv_cpu/capabilities.zig"
        artifact = self.root / "src/interop/riscv_artifact.zig"
        capability.parent.mkdir(parents=True, exist_ok=True)
        artifact.parent.mkdir(parents=True, exist_ok=True)
        capability.write_text(
            f"pub const adapter_release_gated = {str(promoted).lower()};\n",
            encoding="utf-8",
        )
        artifact.write_text(
            'pub const RELEASE_STATUS = "'
            + ("release_gated" if promoted else "not_release_gated")
            + '";\n',
            encoding="utf-8",
        )

    def _riscv_manifest(self) -> Manifest:
        raw = make_raw(riscv_enabled=True)
        raw["workload_registry"]["groups"]["riscv"]["binary"] = "bin/fakebench"
        manifest_mod._validate(raw)
        return Manifest(root=self.root, raw=raw)

    @staticmethod
    def _riscv_artifact(status: str, proof_hex: str = "0102",
                        implementation_commit: str = "b" * 40) -> dict:
        return {
            "artifact_kind": "stwo_riscv_proof",
            "schema_version": 3,
            "exchange_mode": "riscv_proof_json_wire_v3",
            "release_status": status,
            "generator": "zig",
            "air": "stark_v_rv32im",
            "backend": "cpu",
            "protocol": "functional",
            "source": {"elf_sha256": "1" * 64, "input_sha256": "2" * 64},
            "provenance": {
                "oracle_repository": "https://github.com/ClementWalter/stark-v",
                "oracle_commit": "d478f783055aa0d73a93768a433a3c6c31c91d1c",
                "implementation_repository": "https://github.com/teddyjfpender/stwo-zig",
                "implementation_commit": implementation_commit,
                "implementation_dirty": False,
                "witness_layout_sha256": "3" * 64,
            },
            "pcs_config": {},
            "statement": {},
            "interaction_claim": {},
            "proof_bytes_hex": proof_hex,
        }

    def _riscv_run(self, status: str, experimental: bool,
                    proof_hex: str = "0102", mutate_report=None,
                    implementation_commit: str = "b" * 40):
        commands = []

        def fake_run(command, _root, timeout):
            del timeout
            commands.append(command)
            parts = shlex.split(command)
            proof_path = Path(parts[parts.index("--proof-out") + 1])
            artifact = self._riscv_artifact(
                status, proof_hex, implementation_commit,
            )
            encoded = json.dumps(artifact, separators=(",", ":")).encode()
            proof_path.write_bytes(encoded)
            report = {
                "schema": "riscv_proof_v1",
                "release_status": status,
                "mode": "bench",
                "experimental": experimental,
                "profiled": False,
                "warmups": 0,
                "samples": 1,
                "verified_samples": 1,
                "total_steps": 32,
                "n_components": 2,
                "throughput_numerator": "vm_steps",
                "median_seconds": 0.004,
                "throughput_mhz": 0.008,
                "mean_execution_seconds": 0.0005,
                "mean_witness_seconds": 0.0005,
                "mean_proving_seconds": 0.003,
                "mean_verification_seconds": 0.0002,
                "sample_seconds": [0.004],
                "statement_sha256": "4" * 64,
                "transcript_state_blake2s": "5" * 64,
                "implementation_commit": implementation_commit,
                "implementation_dirty": False,
                "executable_sha256": "6" * 64,
                "artifact_sha256": hashlib.sha256(encoded).hexdigest(),
                "proof_path": str(proof_path),
            }
            if mutate_report:
                mutate_report(report)
            return json.dumps(report)

        return commands, fake_run

    @staticmethod
    def _riscv_verify_receipt(report: dict, artifact: dict) -> dict:
        proof = bytes.fromhex(artifact["proof_bytes_hex"])
        return {
            "schema": "riscv_verify_v1",
            "status": "verified",
            "artifact_kind": artifact["artifact_kind"],
            "artifact_schema_version": artifact["schema_version"],
            "release_status": artifact["release_status"],
            "security_policy": artifact["protocol"],
            "statement_sha256": report["statement_sha256"],
            "proof_bytes": len(proof),
            "proof_sha256": hashlib.sha256(proof).hexdigest(),
            "transcript_state_blake2s": report["transcript_state_blake2s"],
            "implementation_commit": report["implementation_commit"],
            "implementation_dirty": report["implementation_dirty"],
            "executable_sha256": report["executable_sha256"],
        }

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
            runner.evaluate_aa(self.root, m, "wide", self.out_dir, board="riscv")
        self.assertIn("no enabled workloads registered for board riscv", str(ctx.exception))
        self.assertIn("skipped group riscv", buf.getvalue())

    def test_enabled_group_with_missing_binary_fails_clearly(self):
        m = self._manifest(riscv_enabled=True)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf), self.assertRaises(runner.RunError) as ctx:
            runner.evaluate_aa(self.root, m, "wide", self.out_dir, board="riscv")
        message = str(ctx.exception)
        self.assertIn("riscv", message)
        self.assertIn("bin/missing-riscv-bench", message)
        self.assertIn("refusing to fabricate", message)
        # no fabricated report may exist for the missing binary
        self.assertFalse(list(self.out_dir.glob("riscv_alu.*.json")))

    def test_bench_once_checks_binary_before_running(self):
        m = self._manifest(riscv_enabled=True)
        self.out_dir.mkdir(parents=True, exist_ok=True)
        workload = m.workloads("wide", board="riscv")[0]
        with self.assertRaises(runner.RunError) as ctx:
            runner.bench_once(self.root, m, workload, 0, 1, self.out_dir, "a1")
        self.assertIn("not found", str(ctx.exception))

    def test_bench_once_rejects_wrong_report_schema(self):
        bench = self.root / "bin" / "fakebench"
        bench.write_text(
            "#!/bin/sh\n"
            "echo '{\"schema_version\":5,\"timing\":{\"prove_seconds\":"
            "{\"median\":0.001}},\"proof\":{\"verified_samples\":1,"
            "\"all_samples_byte_identical\":true}}'\n"
        )
        m = self._manifest(riscv_enabled=False)
        workload = m.workloads("small", board="core_cpu")[0]
        with self.assertRaises(runner.RunError) as ctx:
            runner.bench_once(self.root, m, workload, 0, 1, self.out_dir, "a1")
        self.assertIn("expected native_proof_v6", str(ctx.exception))
        self.assertFalse((self.out_dir / "wf_small.a1.json").exists())

    def test_bench_once_rejects_duplicate_report_fields(self):
        bench = self.root / "bin" / "fakebench"
        bench.write_text(
            "#!/bin/sh\n"
            "echo '{\"schema_version\":6,\"schema_version\":6}'\n"
        )
        manifest = self._manifest(riscv_enabled=False)
        workload = manifest.workloads("small", board="core_cpu")[0]
        with self.assertRaisesRegex(runner.RunError, "non-JSON output"):
            runner.bench_once(
                self.root, manifest, workload, 0, 1, self.out_dir, "a1",
            )

    def test_enabled_native_group_still_scores(self):
        m = self._manifest(riscv_enabled=False)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            result = runner.evaluate_aa(self.root, m, "small", self.out_dir)
        self.assertEqual(result["rounds"], 3)
        self.assertEqual(result["aa_r"], 1.0)

    def test_riscv_bench_uses_staged_admission_and_canonical_proof_digest(self):
        self._set_riscv_phase(promoted=False)
        manifest = self._riscv_manifest()
        workload = manifest.workloads("wide", board="riscv")[0]
        commands, fake_run = self._riscv_run("not_release_gated", True)
        with mock.patch.object(runner, "_run", side_effect=fake_run):
            result = runner.bench_once(
                self.root, manifest, workload, 0, 1, self.out_dir, "a1",
            )
        self.assertIn("--experimental", shlex.split(commands[0]))
        self.assertEqual(hashlib.sha256(bytes.fromhex("0102")).hexdigest(),
                         result.proof_digest)
        self.assertEqual(result.mechanism["total_steps"], 32)
        self.assertEqual(result.mechanism["statement_sha256"], "4" * 64)

    def test_riscv_bench_uses_promoted_admission_without_experimental(self):
        self._set_riscv_phase(promoted=True)
        manifest = self._riscv_manifest()
        workload = manifest.workloads("wide", board="riscv")[0]
        commands, fake_run = self._riscv_run("release_gated", False)
        with mock.patch.object(runner, "_run", side_effect=fake_run):
            runner.bench_once(
                self.root, manifest, workload, 0, 1, self.out_dir, "a1",
            )
        self.assertNotIn("--experimental", shlex.split(commands[0]))

    def test_riscv_proof_digest_ignores_commit_bearing_artifact_fields(self):
        self._set_riscv_phase(promoted=True)
        manifest = self._riscv_manifest()
        workload = manifest.workloads("wide", board="riscv")[0]
        _commands, first = self._riscv_run("release_gated", False)
        with mock.patch.object(runner, "_run", side_effect=first):
            a = runner.bench_once(
                self.root, manifest, workload, 0, 1, self.out_dir, "a1",
            )
        _commands, second = self._riscv_run(
            "release_gated", False, implementation_commit="c" * 40,
        )
        with mock.patch.object(runner, "_run", side_effect=second):
            b = runner.bench_once(
                self.root, manifest, workload, 0, 1, self.out_dir, "b1",
            )
        self.assertEqual(a.proof_digest, b.proof_digest)
        self.assertNotEqual(
            hashlib.sha256((self.out_dir / "riscv_alu.a1.proof.json").read_bytes()).hexdigest(),
            hashlib.sha256((self.out_dir / "riscv_alu.b1.proof.json").read_bytes()).hexdigest(),
        )

    def test_riscv_bench_rejects_mixed_release_state(self):
        self._set_riscv_phase(promoted=False)
        artifact = self.root / "src/interop/riscv_artifact.zig"
        artifact.write_text('pub const RELEASE_STATUS = "release_gated";\n')
        manifest = self._riscv_manifest()
        workload = manifest.workloads("wide", board="riscv")[0]
        with self.assertRaisesRegex(runner.RunError, "release states disagree"):
            runner.bench_once(
                self.root, manifest, workload, 0, 1, self.out_dir, "a1",
            )

    def test_riscv_bench_rejects_forged_artifact_digest(self):
        self._set_riscv_phase(promoted=True)
        manifest = self._riscv_manifest()
        workload = manifest.workloads("wide", board="riscv")[0]
        _commands, fake_run = self._riscv_run(
            "release_gated", False,
            mutate_report=lambda report: report.update(artifact_sha256="0" * 64),
        )
        with mock.patch.object(runner, "_run", side_effect=fake_run), \
                self.assertRaisesRegex(runner.RunError, "artifact_sha256"):
            runner.bench_once(
                self.root, manifest, workload, 0, 1, self.out_dir, "a1",
            )

    def test_riscv_bench_rejects_noncanonical_proof_hex(self):
        self._set_riscv_phase(promoted=True)
        manifest = self._riscv_manifest()
        workload = manifest.workloads("wide", board="riscv")[0]
        _commands, fake_run = self._riscv_run("release_gated", False, "ABCD")
        with mock.patch.object(runner, "_run", side_effect=fake_run), \
                self.assertRaisesRegex(runner.RunError, "canonical lowercase"):
            runner.bench_once(
                self.root, manifest, workload, 0, 1, self.out_dir, "a1",
            )

    def test_riscv_bench_rejects_missing_required_mechanism_field(self):
        self._set_riscv_phase(promoted=True)
        manifest = self._riscv_manifest()
        workload = manifest.workloads("wide", board="riscv")[0]
        _commands, fake_run = self._riscv_run(
            "release_gated", False,
            mutate_report=lambda report: report.pop("statement_sha256"),
        )
        with mock.patch.object(runner, "_run", side_effect=fake_run), \
                self.assertRaisesRegex(runner.RunError, "statement_sha256"):
            runner.bench_once(
                self.root, manifest, workload, 0, 1, self.out_dir, "a1",
            )

    def test_riscv_workload_requires_explicit_admission_token(self):
        self._set_riscv_phase(promoted=True)
        raw = make_raw(riscv_enabled=True)
        riscv = raw["workload_registry"]["groups"]["riscv"]
        riscv["binary"] = "bin/fakebench"
        riscv["workloads"]["riscv_alu"]["args"] = "--elf alu.elf"
        manifest_mod._validate(raw)
        manifest = Manifest(self.root, raw)
        workload = manifest.workloads("wide", board="riscv")[0]
        with self.assertRaisesRegex(runner.RunError, "lacks.*admission"):
            runner.bench_once(
                self.root, manifest, workload, 0, 1, self.out_dir, "a1",
            )

    def test_seeded_riscv_holdout_is_deterministic_and_changes_elf(self):
        raw = make_raw(riscv_enabled=True)
        riscv = raw["workload_registry"]["groups"]["riscv"]
        riscv["workloads"].update({
            "riscv_sort": {
                "class": "wide",
                "args": "--elf vectors/riscv_elfs/bubble_sort.elf {admission} "
                        "--warmups {warmups} --samples {samples}",
                "native_unit": "executed instructions",
            },
            "riscv_collatz": {
                "class": "wide",
                "args": "--elf vectors/riscv_elfs/collatz.elf {admission} "
                        "--warmups {warmups} --samples {samples}",
                "native_unit": "executed instructions",
            },
        })
        riscv["holdout_generator"] = {
            "strategy": "seeded_workload_pool_v1",
            "pools": {"wide": ["riscv_sort", "riscv_collatz"]},
        }
        manifest_mod._validate(raw)
        manifest = Manifest(self.root, raw)
        first = runner.draw_holdout(manifest, "wide", 12345, board="riscv")
        second = runner.draw_holdout(manifest, "wide", 12345, board="riscv")
        self.assertIsNotNone(first)
        self.assertEqual(first, second)
        primary = manifest.workloads("wide", board="riscv")[0]
        self.assertNotEqual(first.args, primary.args)
        self.assertRegex(first.args, r"riscv_elfs/(bubble_sort|collatz)\.elf")

    def test_correctness_oracle_dispatches_by_group(self):
        native = self._manifest(riscv_enabled=False)
        native_workload = native.workloads("small", board="core_cpu")[0]
        with mock.patch.object(
            runner, "_native_rust_oracle_check", return_value={"oracle": "native"},
        ) as native_check, mock.patch.object(
            runner, "_riscv_stark_v_oracle_check", return_value={"oracle": "riscv"},
        ) as riscv_check:
            self.assertEqual(
                "native",
                runner.rust_oracle_check(
                    self.root, native, native_workload, self.out_dir,
                )["oracle"],
            )
            native_check.assert_called_once()
            riscv_check.assert_not_called()

        riscv = self._riscv_manifest()
        riscv_workload = riscv.workloads("wide", board="riscv")[0]
        with mock.patch.object(
            runner, "_native_rust_oracle_check", return_value={"oracle": "native"},
        ) as native_check, mock.patch.object(
            runner, "_riscv_stark_v_oracle_check", return_value={"oracle": "riscv"},
        ) as riscv_check:
            self.assertEqual(
                "riscv",
                runner.rust_oracle_check(
                    self.root, riscv, riscv_workload, self.out_dir,
                )["oracle"],
            )
            riscv_check.assert_called_once()
            native_check.assert_not_called()

    def test_riscv_oracle_validates_anchor_and_retained_artifact_without_rebuild(self):
        self._set_riscv_phase(promoted=True)
        script = self.root / "scripts/riscv_release_evidence.py"
        script.parent.mkdir(parents=True)
        script.write_text("# fixture\n")
        manifest = self._riscv_manifest()
        group = manifest.group("riscv")
        object.__setattr__(group, "correctness_oracle", {
            "authority": "stark-v",
            "commit": "d478f783055aa0d73a93768a433a3c6c31c91d1c",
        })
        workload = manifest.workloads("wide", board="riscv")[0]
        _bench_commands, bench_run = self._riscv_run("release_gated", False)
        with mock.patch.object(runner, "_run", side_effect=bench_run):
            runner.bench_once(
                self.root, manifest, workload, 0, 1, self.out_dir, "b1",
            )
        anchor = self.root / "release-anchor.json"
        anchor.write_text(json.dumps({
            "schema": "riscv-oracle-receipt-v2",
            "candidate_commit": "a" * 40,
            "verdict": "PASS",
            "oracle": {
                "commit": "d478f783055aa0d73a93768a433a3c6c31c91d1c",
            },
        }))
        report = json.loads((self.out_dir / "riscv_alu.b1.json").read_text())
        artifact = json.loads(
            (self.out_dir / "riscv_alu.b1.proof.json").read_text()
        )
        commands = []

        def fake_run(command, _root, timeout):
            del timeout
            commands.append(command)
            if " verify " in f" {command} ":
                return json.dumps(self._riscv_verify_receipt(report, artifact))
            return "anchor valid"

        with mock.patch.dict(os.environ, {
            "STWO_ZIG_RISCV_RELEASE_ANCHOR_RECEIPT": str(anchor),
        }), \
                mock.patch.object(runner, "_run", side_effect=fake_run):
            result = runner._riscv_stark_v_oracle_check(
                self.root, group, workload, self.out_dir,
            )
        self.assertEqual(result["oracle"], "pinned-stark-v-release-anchor")
        self.assertTrue(any("riscv_release_evidence.py" in command and
                            "--at-receipt-time" in command for command in commands))
        self.assertTrue(any(" verify " in f" {command} " for command in commands))
        self.assertFalse(any("build-and-compare" in command for command in commands))
        self.assertFalse(any("stwo-interop-rs" in command for command in commands))

    def test_riscv_oracle_requires_precomputed_release_anchor(self):
        manifest = self._riscv_manifest()
        group = manifest.group("riscv")
        object.__setattr__(group, "correctness_oracle", {
            "authority": "stark-v",
            "commit": "d478f783055aa0d73a93768a433a3c6c31c91d1c",
        })
        workload = manifest.workloads("wide", board="riscv")[0]
        with mock.patch.dict(os.environ, {}, clear=True), \
                self.assertRaisesRegex(runner.RunError, "RELEASE_ANCHOR_RECEIPT"):
            runner._riscv_stark_v_oracle_check(
                self.root, group, workload, self.out_dir,
            )

    def test_riscv_oracle_rejects_forged_verification_receipt(self):
        report = {
            "statement_sha256": "4" * 64,
            "transcript_state_blake2s": "5" * 64,
            "implementation_commit": "b" * 40,
            "implementation_dirty": False,
            "executable_sha256": "6" * 64,
        }
        artifact = self._riscv_artifact("release_gated")
        receipt = self._riscv_verify_receipt(report, artifact)
        receipt["proof_sha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "proof_sha256 differs"):
            runner._validate_riscv_verify_receipt(
                json.dumps(receipt), report, artifact, artifact["proof_bytes_hex"],
            )

    def test_riscv_oracle_rejects_unpinned_group_authority(self):
        manifest = self._riscv_manifest()
        group = manifest.group("riscv")
        workload = manifest.workloads("wide", board="riscv")[0]
        with self.assertRaisesRegex(runner.RunError, "not bound to the pinned"):
            runner._riscv_stark_v_oracle_check(
                self.root, group, workload, self.out_dir,
            )

    def test_board_selection_does_not_pool_enabled_groups(self):
        m = self._manifest(riscv_enabled=True)
        with mock.patch.object(runner, "build_arm") as build, \
                mock.patch.object(runner, "paired_rounds") as paired:
            paired.return_value = runner.WorkloadScore(
                workload=m.workloads("small", board="core_cpu")[0],
                ratios=[1.0, 1.0, 1.0],
                r=1.0,
                ci=(1.0, 1.0),
                a_median_ms=1.0,
                b_median_ms=1.0,
                rss_ratio=None,
            )
            result = runner.evaluate_aa(
                self.root, m, "small", self.out_dir, board="core_cpu",
            )
        self.assertEqual(result["workload"], "wf_small")
        self.assertEqual(result["board"], "core_cpu")
        self.assertEqual(paired.call_args.args[3].group_id, "native")
        self.assertEqual(build.call_args.kwargs["groups"][0].group_id, "native")

    def test_group_sampling_policy_reaches_paired_runner(self):
        raw = make_raw(riscv_enabled=False)
        native = raw["workload_registry"]["groups"]["native"]
        native["gates_policy"] = {
            "warmups": 1,
            "samples_per_round": 2,
            "min_rounds": 4,
            "max_rounds": 5,
            "wall_clock_cap_seconds": {"small": 17},
        }
        manifest_mod._validate(raw)
        manifest = Manifest(self.root, raw)
        score = runner.WorkloadScore(
            workload=manifest.workloads("small", board="core_cpu")[0],
            ratios=[1.0] * 4,
            r=1.0,
            ci=(1.0, 1.0),
            a_median_ms=1.0,
            b_median_ms=1.0,
            rss_ratio=None,
        )
        with mock.patch.object(runner, "build_arm"), \
                mock.patch.object(runner, "paired_rounds", return_value=score) as paired:
            runner.evaluate_aa(
                self.root, manifest, "small", self.out_dir, board="core_cpu",
            )
        policy = paired.call_args.args[4]
        self.assertEqual(
            (policy["warmups"], policy["samples_per_round"],
             policy["min_rounds"], policy["max_rounds"]),
            (1, 2, 4, 5),
        )
        self.assertEqual(policy["wall_clock_cap_seconds"]["small"], 17)

    def test_out_of_scope_stray_fails_g2(self):
        m = self._manifest(riscv_enabled=False)
        with mock.patch.object(
            runner, "changed_paths", return_value=["docs/out-of-scope.md"],
        ):
            gates = runner._gates(
                self.root, m, [], GATES_POLICY, False, None, "small", "core_cpu",
            )
        self.assertFalse(gates["G2"]["pass"])
        self.assertIn("outside editable set", gates["G2"]["detail"])

    def test_riscv_score_without_verified_mechanism_fails_g3(self):
        manifest = self._riscv_manifest()
        score = runner.WorkloadScore(
            workload=manifest.workloads("wide", board="riscv")[0],
            ratios=[1.0],
            r=1.0,
            ci=(1.0, 1.0),
            a_median_ms=1.0,
            b_median_ms=1.0,
            rss_ratio=None,
            mechanism_verified=False,
        )
        with mock.patch.object(runner, "changed_paths", return_value=[]):
            gates = runner._gates(
                self.root, manifest, [score], GATES_POLICY, False, None,
                "wide", "riscv",
            )
        self.assertFalse(gates["G3"]["pass"])
        self.assertIn("0/1 workloads", gates["G3"]["detail"])

    def test_paired_round_rejects_riscv_semantic_telemetry_drift(self):
        manifest = self._riscv_manifest()
        workload = manifest.workloads("wide", board="riscv")[0]
        stable = {
            "total_steps": 32,
            "n_components": 2,
            "statement_sha256": "4" * 64,
            "transcript_state_blake2s": "5" * 64,
        }
        a = runner.ArmResult(
            1.0, 1, True, None, "a.json", proof_digest="7" * 64,
            mechanism=stable,
        )
        b = runner.ArmResult(
            1.0, 1, True, None, "b.json", proof_digest="7" * 64,
            mechanism={**stable, "statement_sha256": "8" * 64},
        )
        with mock.patch.object(runner, "bench_once", side_effect=[a, b]), \
                self.assertRaisesRegex(runner.RunError, "semantic mechanism telemetry"):
            runner.paired_rounds(
                self.root, self.root, manifest, workload, GATES_POLICY, self.out_dir,
            )

    def test_paired_round_rejects_non_identical_proof_bytes(self):
        m = self._manifest(riscv_enabled=False)
        workload = m.workloads("small", board="core_cpu")[0]
        non_identical = runner.ArmResult(1.0, 1, False, None, "a.json")
        identical = runner.ArmResult(1.0, 1, True, None, "b.json")
        with mock.patch.object(
            runner, "bench_once", side_effect=[non_identical, identical],
        ), self.assertRaises(runner.RunError) as ctx:
            runner.paired_rounds(
                self.root, self.root, m, workload, GATES_POLICY, self.out_dir,
            )
        self.assertIn("proof bytes changed", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()
