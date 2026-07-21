import math
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "autoresearch" / "cli"))

from stwo_perf import runner, search_health  # noqa: E402
from stwo_perf.manifest import Workload, WorkloadGroup  # noqa: E402


POLICY = {
    "trailing_window": 3,
    "gradient_snr_threshold": 2.0,
    "auto_boost_rounds": 5,
    "maximum_rounds": 18,
}


def history(snr, seconds=150.0, rounds=15):
    return search_health.HistoryPoint(snr, seconds, rounds)


def decision(points, *, deadline=600.0, elapsed=0.0):
    return search_health.decide_rounds(
        board="core_cpu",
        workload_class="wide",
        configured_rounds=15,
        minimum_rounds=7,
        workload_count=1,
        class_wall_deadline_seconds=deadline,
        policy=POLICY,
        history=points,
        elapsed_before_measurement_seconds=elapsed,
    )


class PureMetricTest(unittest.TestCase):
    def test_gradient_snr_uses_credited_effect_and_directional_log_uncertainty(self):
        credit = -0.02
        expected_uncertainty = math.log(0.99) - math.log(0.95)
        self.assertAlmostEqual(
            search_health.gradient_snr(credit, 0.95, 0.92, 0.99),
            abs(credit) / expected_uncertainty,
        )

    def test_credited_improvement_rate_is_signed_and_deterministic(self):
        self.assertEqual(
            search_health.credited_ln_improvement_per_measurement_hour(-0.02, 1800),
            0.04,
        )
        self.assertEqual(
            search_health.credited_ln_improvement_per_measurement_hour(0.02, 1800),
            -0.04,
        )


class RoundDecisionTest(unittest.TestCase):
    def test_shrinking_effects_grow_rounds_only_to_bounded_maximum(self):
        result = decision([history(3.2), history(1.5), history(0.8)])
        self.assertEqual(result.trailing_median_gradient_snr, 1.5)
        self.assertTrue(result.auto_boost_applied)
        self.assertEqual(result.target_rounds, 18)
        self.assertLessEqual(
            result.target_rounds,
            result.configured_rounds + result.auto_boost_rounds,
        )
        self.assertLessEqual(result.target_rounds, result.maximum_rounds)

    def test_no_boost_at_or_above_threshold(self):
        result = decision([history(2.0), history(2.5), history(4.0)])
        self.assertFalse(result.auto_boost_applied)
        self.assertEqual(result.target_rounds, 15)
        self.assertEqual(
            result.auto_boost_reason,
            "trailing_median_at_or_above_threshold",
        )

    def test_target_is_bounded_by_remaining_class_deadline(self):
        # Historical complete wall cost is ten seconds per measured round.
        result = decision(
            [history(0.5)], deadline=200.0, elapsed=40.0,
        )
        self.assertEqual(result.deadline_round_limit, 16)
        self.assertEqual(result.target_rounds, 16)
        self.assertEqual(result.class_wall_deadline_seconds, 200.0)
        self.assertLessEqual(
            result.target_rounds * result.estimated_seconds_per_round,
            result.class_wall_deadline_seconds - 40.0,
        )

    def test_deadline_never_moves_when_low_snr_cannot_fit_a_boost(self):
        result = decision([history(0.5)], deadline=150.0)
        self.assertFalse(result.auto_boost_applied)
        self.assertEqual(result.target_rounds, 15)
        self.assertEqual(
            result.auto_boost_reason,
            "trailing_median_below_threshold_deadline_limited",
        )


class SeriesTest(unittest.TestCase):
    def setUp(self):
        self.decision = search_health.decide_rounds(
            board="future_board",
            workload_class="xlarge",
            configured_rounds=3,
            minimum_rounds=3,
            workload_count=1,
            class_wall_deadline_seconds=60,
            policy={
                "trailing_window": 2,
                "gradient_snr_threshold": 2.0,
                "auto_boost_rounds": 2,
                "maximum_rounds": 5,
            },
            history=[],
        )
        self.block = search_health.evidence_block(
            self.decision,
            actual_rounds_per_workload={"future_workload": 3},
            objective_wall_seconds=6.0,
            measurement_wall_seconds=10.0,
        )
        self.verdict = {"kind": "claimed", "search_health": self.block}
        self.row = SimpleNamespace(values={
            "schema_version": 3,
            "row_id": "sha256:" + "1" * 64,
            "evidence_sha256": search_health.canonical_sha256(self.verdict),
            "submission_id": "future",
            "judged_at_utc": "2026-07-21T10:00:00Z",
            "verdict_kind": "claimed",
            "board": "future_board",
            "workload_class": "xlarge",
            "measurement_seconds": 10.0,
            "measurement_rounds": 3,
            "judged_r": 0.95,
            "ci_low": 0.92,
            "ci_high": 0.99,
        })

    def test_series_and_decay_are_deterministic_from_explicit_inputs(self):
        verdicts = {self.row.values["evidence_sha256"]: self.verdict}
        first = search_health.class_series(
            [self.row], verdicts, trailing_window=2,
            credited_log_effect_fn=lambda _row: -0.02,
        )
        second = search_health.class_series(
            [self.row], verdicts, trailing_window=2,
            credited_log_effect_fn=lambda _row: -0.02,
        )
        self.assertEqual(first, second)
        self.assertEqual(first["latest"]["configured_rounds"], 3)
        self.assertEqual(first["latest"]["actual_rounds"], 3)
        self.assertEqual(first["latest"]["measurement_wall_hours"], 10 / 3600)
        self.assertEqual(len(first["decay"]), 1)

    def test_legacy_row_remains_readable_but_unavailable(self):
        legacy = SimpleNamespace(values={
            **self.row.values,
            "schema_version": 2,
            "verdict_kind": "judged",
        })
        built = search_health.class_series(
            [legacy], {}, trailing_window=2,
            credited_log_effect_fn=lambda _row: -0.02,
        )
        self.assertFalse(built["available"])
        self.assertEqual(
            built["time_series"][0]["unavailable_reason"],
            "legacy_row_has_no_search_health_evidence",
        )

    def test_missing_judged_v3_evidence_fails_publication_closed(self):
        judged = SimpleNamespace(values={
            **self.row.values,
            "verdict_kind": "judged",
        })
        with self.assertRaisesRegex(
            search_health.SearchHealthError, "evidence.*missing"
        ):
            search_health.class_series(
                [judged], {}, trailing_window=2,
                credited_log_effect_fn=lambda _row: -0.02,
            )

    def test_projection_uses_manifest_classes_without_a_fixed_class_list(self):
        group = WorkloadGroup(
            group_id="future",
            enabled=True,
            promotion_eligible=True,
            disabled_reason=None,
            board="future_board",
            build_step="true",
            binary="bin/bench",
            report_schema="native_proof_v6",
            workloads=[Workload(
                "future_workload", "xlarge", "--x", "rows", "future"
            )],
        )
        manifest = SimpleNamespace(
            search_health_policy={
                "trailing_window": 2,
                "gradient_snr_threshold": 2.0,
                "auto_boost_rounds": 2,
                "maximum_rounds": 5,
            },
            groups=lambda: [group],
        )
        verdicts = {self.row.values["evidence_sha256"]: self.verdict}
        built = search_health.projection(
            manifest, [self.row], verdicts,
            credited_log_effect_fn=lambda _row: -0.02,
        )
        self.assertIn("xlarge", built["boards"]["future_board"]["classes"])


class GateIsolationTest(unittest.TestCase):
    def test_search_health_wall_evidence_cannot_change_correctness_gates(self):
        workload = Workload("w", "small", "--x", "rows", "native")
        common = dict(
            workload=workload,
            ratios=[0.9, 0.9, 0.9],
            r=0.9,
            ci=(0.88, 0.92),
            a_median_ms=10.0,
            b_median_ms=9.0,
            rss_ratio=None,
        )
        fast = runner.WorkloadScore(**common, measurement_seconds=1.0)
        slow = runner.WorkloadScore(**common, measurement_seconds=1000.0)
        manifest = mock.Mock()
        manifest.raw = {"harness": {"anchor_prove_ms": {}}}
        manifest.classify_touched.return_value = ([], [])
        manifest.group.return_value = SimpleNamespace(report_schema="native_proof_v6")
        policy = {
            "targeted_class_budget": 1.02,
            "matrix_row_budget": 1.05,
            "request_budget": 1.05,
            "rss_budget": 1.05,
        }
        with mock.patch.object(runner, "changed_paths", return_value=[]):
            before = runner._gates(
                ROOT, manifest, [fast], policy, False, None, "small", "core_cpu"
            )
            after = runner._gates(
                ROOT, manifest, [slow], policy, False, None, "small", "core_cpu"
            )
        self.assertEqual(before, after)


if __name__ == "__main__":
    unittest.main()
