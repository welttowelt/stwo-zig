import math
import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
ANCHOR = "0" * 40
sys.path.insert(0, str(ROOT / "autoresearch" / "cli"))

from stwo_perf import ledger, metrics  # noqa: E402
from test_ledger_v3 import HEADER, v3_values  # noqa: E402


def rows(*values: dict) -> list[ledger.Row]:
    lines = [ledger.serialize_row(value) for value in values]
    return ledger.parse(HEADER + "\n" + "\n".join(lines) + "\n")


def promotion(name: str, index: int, **overrides) -> dict:
    values = {
        "submission_id": name,
        "judged_at_utc": f"2026-07-21T16:{index:02d}:00Z",
        "commit": f"{index:040x}",
        "predecessor": f"{index - 1:040x}",
    }
    values.update(overrides)
    return v3_values(
        **values,
    )


def evidence(name: str, index: int, kind: str, **overrides) -> dict:
    return promotion(name, index, evidence_kind=kind, **overrides)


class ShrinkageTest(unittest.TestCase):
    def test_directional_improvement_radius(self):
        got = metrics.neutralward_log_credit(0.9, 0.85, 0.95, 1.0)
        self.assertAlmostEqual(got, math.log(0.95))

    def test_directional_regression_radius(self):
        got = metrics.neutralward_log_credit(1.1, 1.05, 1.2, 1.0)
        self.assertAlmostEqual(got, math.log(1.05))

    def test_ci_crossing_neutral_has_zero_credit(self):
        self.assertEqual(metrics.neutralward_log_credit(0.98, 0.95, 1.01, 1.0), 0.0)

    def test_public_row_credit_helper_matches_direct_and_shrunken_rules(self):
        promoted = rows(promotion(
            "promoted", 1, judged_r=0.9, ci_low=0.85, ci_high=0.95
        ))[0]
        direct = rows(evidence(
            "audit", 1, "direct_audit", outcome="rejected",
            judged_r=1.1, ci_low=1.05, ci_high=1.15,
        ))[0]
        self.assertAlmostEqual(
            metrics.credited_log_effect(promoted, 1.0), math.log(0.95)
        )
        self.assertAlmostEqual(
            metrics.credited_log_effect(direct, 1.0), math.log(1.1)
        )


class CreditAlgebraTest(unittest.TestCase):
    def test_promotions_compound_shrunken_credit(self):
        first = promotion("first", 1, judged_r=0.9, ci_low=0.85, ci_high=0.95)
        second = promotion("second", 2, judged_r=0.8, ci_low=0.75, ci_high=0.85)
        score = metrics.score_class(
            rows(first, second), 2, "core_cpu", "small", shrinkage_lambda=1.0
        )
        expected_log = sum(
            metrics.neutralward_log_credit(*triple, 1.0)
            for triple in ((0.9, 0.85, 0.95), (0.8, 0.75, 0.85))
        )
        self.assertAlmostEqual(score.ratio, math.exp(expected_log))

    def test_promoted_span_credits_disjoint_neutral_observations(self):
        a = promotion("a", 1, outcome="neutral", judged_r=0.99, ci_low=0.97, ci_high=1.01)
        b = promotion("b", 2, outcome="neutral", judged_r=0.98, ci_low=0.96, ci_high=1.01)
        span = evidence(
            "span", 3, "span_audit",
            covers=[a["observation_id"], b["observation_id"]],
            judged_r=0.94, ci_low=0.92, ci_high=0.97,
        )
        score = metrics.score_class(
            rows(a, b, span), 2, "core_cpu", "small", shrinkage_lambda=1.0
        )
        self.assertEqual([event.evidence_kind for event in score.active_events], ["span_audit"])

    def test_span_cannot_cover_promoted_or_rejected_observation(self):
        promoted = promotion("a", 1)
        span = evidence(
            "span", 2, "span_audit", covers=[promoted["observation_id"]]
        )
        with self.assertRaisesRegex(metrics.MetricsError, "only gate-passing neutral"):
            metrics.score_class(
                rows(promoted, span), 2, "core_cpu", "small", shrinkage_lambda=1.0
            )

    def test_neutral_span_consumes_coverage_without_credit(self):
        neutral = promotion("a", 1, outcome="neutral", judged_r=0.99, ci_low=0.97, ci_high=1.01)
        first = evidence(
            "span-a", 2, "span_audit", outcome="neutral",
            covers=[neutral["observation_id"]], judged_r=1.0, ci_low=0.98, ci_high=1.02,
        )
        second = evidence(
            "span-b", 3, "span_audit", outcome="neutral",
            covers=[neutral["observation_id"]], judged_r=1.0, ci_low=0.98, ci_high=1.02,
        )
        with self.assertRaisesRegex(metrics.MetricsError, "coverage is not disjoint"):
            metrics.score_class(
                rows(neutral, first, second), 2, "core_cpu", "small",
                shrinkage_lambda=1.0,
            )

    def test_direct_audit_replaces_exact_active_set_and_anchors_score(self):
        promoted = promotion("promoted", 1)
        neutral = promotion(
            "neutral", 2, outcome="neutral", judged_r=0.98, ci_low=0.96, ci_high=1.01
        )
        span = evidence(
            "span", 3, "span_audit", covers=[neutral["observation_id"]],
            judged_r=0.94, ci_low=0.92, ci_high=0.97,
        )
        audit = evidence(
            "audit", 4, "direct_audit", outcome="rejected",
            predecessor=ANCHOR,
            judged_r=1.1, ci_low=1.05, ci_high=1.15,
            credit_replaces=[promoted["row_id"], span["row_id"]],
        )
        score = metrics.score_class(
            rows(promoted, neutral, span, audit), 2, "core_cpu", "small",
            shrinkage_lambda=1.0, audit_anchor_commit=ANCHOR,
        )
        self.assertAlmostEqual(score.ratio, 1.1)
        self.assertAlmostEqual(score.audited_ratio, 1.1)
        self.assertEqual(score.audited_through, audit["commit"])
        self.assertEqual([event.row_id for event in score.active_events], [audit["row_id"]])

    def test_direct_audit_rejects_missing_or_surplus_replacement(self):
        promoted = promotion("promoted", 1)
        audit = evidence(
            "audit", 2, "direct_audit", outcome="neutral",
            predecessor=ANCHOR,
            judged_r=1.0, ci_low=0.98, ci_high=1.02,
        )
        with self.assertRaisesRegex(metrics.MetricsError, "exact active set"):
            metrics.score_class(
                rows(promoted, audit), 2, "core_cpu", "small",
                shrinkage_lambda=1.0, audit_anchor_commit=ANCHOR,
            )

    def test_direct_audits_chain_and_score_equals_audit_product(self):
        first = promotion("first", 1)
        audit_a = evidence(
            "audit-a", 2, "direct_audit", outcome="neutral",
            predecessor=ANCHOR,
            judged_r=0.9, ci_low=0.85, ci_high=0.95,
            credit_replaces=[first["row_id"]],
        )
        second = promotion("second", 3)
        audit_b = evidence(
            "audit-b", 4, "direct_audit", outcome="promoted",
            predecessor=audit_a["commit"], judged_r=0.8, ci_low=0.75, ci_high=0.85,
            credit_replaces=[second["row_id"]],
        )
        score = metrics.score_class(
            rows(first, audit_a, second, audit_b), 2, "core_cpu", "small",
            shrinkage_lambda=1.0, audit_anchor_commit=ANCHOR,
        )
        self.assertAlmostEqual(score.ratio, 0.9 * 0.8)
        self.assertAlmostEqual(score.audited_ratio, score.ratio)

    def test_direct_audit_chain_predecessor_is_enforced(self):
        audit_a = evidence(
            "audit-a", 1, "direct_audit", outcome="neutral",
            judged_r=1.0, ci_low=0.98, ci_high=1.02,
        )
        audit_b = evidence(
            "audit-b", 2, "direct_audit", outcome="neutral",
            judged_r=1.0, ci_low=0.98, ci_high=1.02,
            predecessor="f" * 40,
        )
        with self.assertRaisesRegex(metrics.MetricsError, "does not chain"):
            metrics.score_class(
                rows(audit_a, audit_b), 2, "core_cpu", "small",
                shrinkage_lambda=1.0, audit_anchor_commit=ANCHOR,
            )

    def test_first_direct_audit_must_name_epoch_anchor(self):
        audit = evidence(
            "audit", 1, "direct_audit", outcome="neutral",
            predecessor="f" * 40, judged_r=1.0, ci_low=0.98, ci_high=1.02,
        )
        with self.assertRaisesRegex(metrics.MetricsError, "audit anchor"):
            metrics.score_class(
                rows(audit), 2, "core_cpu", "small",
                shrinkage_lambda=1.0, audit_anchor_commit=ANCHOR,
            )


class DueStateTest(unittest.TestCase):
    def test_span_due_considers_only_gate_passing_neutral_promotions(self):
        neutral = promotion(
            "neutral", 1, outcome="neutral", judged_r=0.98,
            ci_low=0.96, ci_high=1.01,
        )
        promoted = promotion("promoted", 2)
        rejected = promotion("rejected", 3, outcome="rejected")
        gate_failed = promotion(
            "gate-failed", 4, outcome="neutral", gates="G3:fail"
        )
        state = metrics.due_state(
            rows(neutral, promoted, rejected, gate_failed),
            2, "core_cpu", "small",
            policy=metrics.AuditPolicy(1.0, 2, 4, 0.5, ANCHOR),
        )
        self.assertEqual(state.span_covers, (neutral["observation_id"],))
        self.assertFalse(state.span_due)
        self.assertTrue(state.direct_audit_due)

    def test_cadence_and_subfloor_triggers_are_deterministic(self):
        values = [
            promotion(
                f"neutral-{index}", index, outcome="neutral",
                judged_r=0.99, ci_low=0.97, ci_high=1.01,
            )
            for index in range(1, 5)
        ]
        policy = metrics.AuditPolicy(1.0, 4, 4, 0.01, ANCHOR)
        state = metrics.due_state(
            rows(*values), 2, "core_cpu", "small", policy=policy
        )
        self.assertTrue(state.span_due)
        self.assertEqual(state.span_reasons, ("landed_cadence", "subfloor_effect"))
        self.assertEqual(state.span_covers, tuple(value["observation_id"] for value in values))
        self.assertTrue(state.direct_audit_due)

    def test_neutral_span_clears_span_due_but_not_direct_due(self):
        values = [
            promotion(
                f"neutral-{index}", index, outcome="neutral",
                judged_r=0.995, ci_low=0.98, ci_high=1.01,
            )
            for index in range(1, 5)
        ]
        span = evidence(
            "span", 5, "span_audit", outcome="neutral",
            covers=[value["observation_id"] for value in values],
            judged_r=1.0, ci_low=0.98, ci_high=1.02,
        )
        state = metrics.due_state(
            rows(*values, span), 2, "core_cpu", "small",
            policy=metrics.AuditPolicy(1.0, 4, 4, 0.01, ANCHOR),
        )
        self.assertFalse(state.span_due)
        self.assertTrue(state.direct_audit_due)


class CurrentLedgerGoldenTest(unittest.TestCase):
    def test_current_core_metal_wide_score_is_stable(self):
        score = metrics.score_class(
            ledger.load(ROOT), 1, "core_metal", "wide", shrinkage_lambda=1.0
        )
        self.assertAlmostEqual(score.ratio, 0.4383268248312496, places=15)
        self.assertIsNone(score.audited_through)


class EpochPolicyTest(unittest.TestCase):
    def test_metrics_epoch_was_appended_without_mutating_epoch_one(self):
        epochs = ledger.known_epochs(ROOT)
        self.assertEqual(sorted(epochs), [1, 2])
        self.assertNotIn("metrics_v2", epochs[1])
        policy = metrics.policy_from_epoch(epochs[2])
        self.assertEqual(
            policy,
            metrics.AuditPolicy(
                1.0, 4, 12, 0.01,
                "8e58d7015e28a312eddc6f1eacc10e0c08ea85cc",
            ),
        )

    def test_metrics_epoch_pins_complete_resource_budgets_for_every_class(self):
        for workload_class in ("small", "wide", "deep", "xlarge", "huge"):
            self.assertEqual(
                ledger.resource_budgets(ROOT, workload_class),
                {
                    "peak_rss_mib": 1.05,
                    "energy_j": 1.05,
                    "proof_bytes": 1.0,
                },
            )

    def test_metrics_epoch_resource_budgets_fail_closed(self):
        malformed = {
            "metrics_v2": {
                "resource_budgets": {
                    "small": {
                        "peak_rss_mib": 1.05,
                        "energy_j": None,
                        "proof_bytes": 1.0,
                    }
                }
            }
        }
        with mock.patch.object(ledger, "current_epoch", return_value=malformed):
            with self.assertRaisesRegex(ledger.LedgerError, "positive and finite"):
                ledger.resource_budgets(ROOT, "small")
            with self.assertRaisesRegex(ledger.LedgerError, "missing for class"):
                ledger.resource_budgets(ROOT, "wide")

    def test_legacy_epoch_has_no_dimensional_policy(self):
        with mock.patch.object(
            ledger, "current_epoch", return_value={"epoch": 1},
        ):
            self.assertIsNone(ledger.resource_budgets(ROOT, "small"))


if __name__ == "__main__":
    unittest.main()
