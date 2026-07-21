import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "cli"))
from stwo_perf import runner  # noqa: E402
from stwo_perf.manifest import Workload, WorkloadGroup  # noqa: E402


def fake_manifest(guards: dict) -> mock.Mock:
    m = mock.Mock()
    m.raw = {"workload_registry": {"guards": guards}}
    return m


GROUP = WorkloadGroup(
    group_id="native", enabled=True, promotion_eligible=True,
    disabled_reason=None, board="core_cpu",
    build_step="zig build bench", binary="zig-out/bin/bench",
    report_schema="native_proof_v7", workloads=[],
)

GUARDS = {
    "workloads": {
        "guard_blake": {"args": "--example blake", "native_unit": "rounds"},
        "guard_xor": {"args": "--example xor", "native_unit": "rows"},
        "guard_plonk": {"args": "--example plonk", "native_unit": "rows"},
    },
    "impact_map": {
        "rules": [
            {"prefixes": ["src/prover/"], "guards": "all"},
            {"prefixes": ["src/core/crypto/"], "guards": ["guard_blake"]},
            {"prefixes": ["src/backends/metal/"], "guards": []},
        ]
    },
}


class SelectGuardsTest(unittest.TestCase):
    def test_generic_prover_paths_select_every_guard(self):
        got = runner.select_guards(
            fake_manifest(GUARDS), ["src/prover/fri.zig"], GROUP
        )
        self.assertEqual(sorted(w.workload_id for w in got),
                         ["guard_blake", "guard_plonk", "guard_xor"])

    def test_specific_paths_select_their_mapped_guards(self):
        got = runner.select_guards(
            fake_manifest(GUARDS), ["src/core/crypto/blake.zig"], GROUP
        )
        self.assertEqual([w.workload_id for w in got], ["guard_blake"])

    def test_unmatched_source_path_fails_closed_to_all(self):
        got = runner.select_guards(
            fake_manifest(GUARDS), ["src/mystery/new_area.zig"], GROUP
        )
        self.assertEqual(len(got), 3)

    def test_out_of_scope_metal_paths_select_none(self):
        got = runner.select_guards(
            fake_manifest(GUARDS), ["src/backends/metal/kernels.metal"], GROUP
        )
        self.assertEqual(got, [])

    def test_non_source_paths_are_ignored(self):
        got = runner.select_guards(
            fake_manifest(GUARDS), ["autoresearch/submissions/x/note.md"], GROUP
        )
        self.assertEqual(got, [])


class CrossArmDigestTest(unittest.TestCase):
    def test_cross_arm_digest_mismatch_raises_conformance_failure(self):
        workload = Workload("w", "small", "--x {warmups} {samples}", "u", "native")
        policy = {
            "warmups": 1, "samples_per_round": 1, "min_rounds": 1,
            "max_rounds": 1, "theta_floor": 0.01,
            "wall_clock_cap_seconds": {"small": 60},
        }
        arms = iter([
            runner.ArmResult(1.0, 1, True, None, "/tmp/a", proof_digest="aaa"),
            runner.ArmResult(1.0, 1, True, None, "/tmp/b", proof_digest="bbb"),
        ])
        with mock.patch.object(runner, "bench_once", side_effect=lambda *a, **k: next(arms)):
            with self.assertRaisesRegex(runner.RunError, "cross-arm proof digest"):
                runner.paired_rounds(
                    Path("/a"), Path("/b"), mock.Mock(), workload, policy, Path("/tmp")
                )


class GateFoldingTest(unittest.TestCase):
    def test_failed_guard_fails_g4(self):
        policy = {"targeted_class_budget": 1.02}
        with mock.patch.object(runner, "changed_paths", return_value=[]):
            manifest = mock.Mock()
            manifest.raw = {"harness": {"anchor_prove_ms": {}}}
            manifest.classify_touched.return_value = ([], [])
            gates = runner._gates(
                Path("."), manifest, [], policy, False, None, "small", "core_cpu",
                guard_results={"guard_xor": {"pass": False, "ci": [1.0, 1.2]}},
            )
        self.assertFalse(gates["G4"]["pass"])
        self.assertIn("guard_xor", gates["G4"]["detail"])

    def test_missing_oracle_fails_g1_when_required(self):
        policy = {"targeted_class_budget": 1.02, "require_rust_oracle": True}
        with mock.patch.object(runner, "changed_paths", return_value=[]):
            manifest = mock.Mock()
            manifest.raw = {"harness": {"anchor_prove_ms": {}}}
            manifest.classify_touched.return_value = ([], [])
            score = mock.Mock(request_ratio=None, rss_ratio=None)
            gates = runner._gates(
                Path("."), manifest, [score], policy, False, None, "small",
                "core_cpu", oracle_results=[],
            )
        self.assertFalse(gates["G1"]["pass"])


if __name__ == "__main__":
    unittest.main()
