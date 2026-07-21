import copy
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "autoresearch" / "cli"))

from stwo_perf import audits, ledger, manifest as manifest_mod, metrics, search_health  # noqa: E402
from test_ledger_v3 import HEADER, v3_values  # noqa: E402

ANCHOR = "8e58d7015e28a312eddc6f1eacc10e0c08ea85cc"
CANDIDATE = "f" * 40


def parsed(*values: dict) -> list[ledger.Row]:
    text = HEADER + "\n" + "\n".join(ledger.serialize_row(value) for value in values)
    return ledger.parse(text + "\n")


def promotion(name: str, index: int, **overrides) -> dict:
    values = {
        "submission_id": name,
        "judged_at_utc": f"2026-07-21T16:{index:02d}:00Z",
        "commit": f"{index:040x}",
        "predecessor": ANCHOR if index == 1 else f"{index - 1:040x}",
    }
    values.update(overrides)
    return v3_values(**values)


def evidence(name: str, index: int, kind: str, **overrides) -> dict:
    return promotion(name, index, evidence_kind=kind, **overrides)


def plan(values: list[dict]) -> dict:
    def resolve(value: str) -> str:
        return ANCHOR if value.endswith("^1") else value

    return audits.build_plan(
        manifest_mod.load(ROOT),
        parsed(*values),
        epoch=2,
        candidate_commit=CANDIDATE,
        source={"fixture": True, "ledger_sha256": "sha256:" + "a" * 64},
        board="core_cpu",
        workload_class="small",
        commit_resolver=resolve,
    )


class AuditPlanningTest(unittest.TestCase):
    def test_significant_span_is_planned_once(self):
        neutral = [
            promotion(
                f"neutral-{index}", index, outcome="neutral",
                judged_r=0.995, ci_low=0.98, ci_high=1.01,
            )
            for index in range(1, 5)
        ]
        first = plan(neutral)
        self.assertEqual(len(first["items"]), 1)
        item = first["items"][0]
        self.assertEqual(item["evidence_kind"], "span_audit")
        self.assertEqual(item["predecessor_commit"], ANCHOR)
        self.assertEqual(
            item["covers"], [value["observation_id"] for value in neutral]
        )
        span = evidence(
            "span", 5, "span_audit", covers=item["covers"],
            judged_r=0.94, ci_low=0.92, ci_high=0.97,
        )
        self.assertEqual(plan([*neutral, span])["items"], [])

    def test_null_span_consumes_once_and_contributes_zero(self):
        neutral = [
            promotion(
                f"neutral-{index}", index, outcome="neutral",
                judged_r=0.999, ci_low=0.98, ci_high=1.01,
            )
            for index in range(1, 5)
        ]
        covers = [value["observation_id"] for value in neutral]
        span = evidence(
            "span", 5, "span_audit", outcome="neutral", covers=covers,
            judged_r=1.0, ci_low=0.98, ci_high=1.02,
        )
        all_rows = parsed(*neutral, span)
        score = metrics.score_class(
            all_rows, 2, "core_cpu", "small", shrinkage_lambda=1.0,
            audit_anchor_commit=ANCHOR,
        )
        self.assertEqual(score.ratio, 1.0)
        self.assertEqual(plan([*neutral, span])["items"], [])

    def test_failed_span_guards_consume_no_audit_slot(self):
        neutral = [
            promotion(
                f"neutral-{index}", index, outcome="neutral",
                judged_r=0.999, ci_low=0.98, ci_high=1.01,
            )
            for index in range(1, 5)
        ]
        failed = evidence(
            "failed-span", 5, "span_audit", outcome="rejected",
            gates="G3:fail",
            covers=[value["observation_id"] for value in neutral],
        )
        retry = plan([*neutral, failed])
        self.assertEqual(len(retry["items"]), 1)
        self.assertEqual(retry["items"][0]["evidence_kind"], "span_audit")

    def test_span_through_interleaved_promotion_is_blocked(self):
        neutral = [
            promotion(
                f"neutral-{index}", index, outcome="neutral",
                judged_r=0.999, ci_low=0.98, ci_high=1.01,
            )
            for index in range(1, 5)
        ]
        interleaved = promotion("promoted", 3)
        values = [neutral[0], neutral[1], interleaved, neutral[2], neutral[3]]
        result = plan(values)
        self.assertEqual(len(result["items"]), 1)
        self.assertFalse(result["items"][0]["runnable"])
        self.assertEqual(
            result["items"][0]["blocked_reason"],
            "span constituents are not the contiguous promotion tail",
        )

    def test_direct_plan_replaces_exact_active_credit_set(self):
        promotions = [promotion(f"p-{index}", index) for index in range(1, 13)]
        result = plan(promotions)
        self.assertEqual(len(result["items"]), 1)
        item = result["items"][0]
        self.assertEqual(item["evidence_kind"], "direct_audit")
        self.assertEqual(item["predecessor_commit"], ANCHOR)
        self.assertEqual(
            item["credit_replaces"], [value["row_id"] for value in promotions]
        )

    def test_failed_direct_guards_consume_no_audit_slot(self):
        promotions = [promotion(f"p-{index}", index) for index in range(1, 13)]
        failed = evidence(
            "failed-direct", 13, "direct_audit", outcome="rejected",
            gates="G1:fail", predecessor=ANCHOR, credit_replaces=[],
        )
        retry = plan([*promotions, failed])
        self.assertEqual(len(retry["items"]), 1)
        self.assertEqual(retry["items"][0]["evidence_kind"], "direct_audit")
        self.assertEqual(
            retry["items"][0]["credit_replaces"],
            [value["row_id"] for value in promotions],
        )

    def test_plan_contract_cannot_select_guards_none(self):
        promotions = [promotion(f"p-{index}", index) for index in range(1, 13)]
        result = plan(promotions)
        contract = result["items"][0]["execution_contract"]
        self.assertEqual(contract["guards_mode"], "all")
        self.assertTrue(contract["judged"])
        self.assertTrue(contract["oracle_required"])
        self.assertNotIn('"guards_mode":"none"', str(result))

    def test_authority_recomputation_rejects_forged_due_item(self):
        source = audits.source_binding(ROOT)
        result = audits.build_plan(
            manifest_mod.load(ROOT),
            ledger.load(ROOT),
            epoch=2,
            candidate_commit=source["candidate_commit"],
            source=source,
        )
        forged = {
            "epoch": 2,
            "board": "core_cpu",
            "workload_class": "small",
            "evidence_kind": "direct_audit",
            "predecessor_commit": ANCHOR,
            "candidate_commit": result["source"]["candidate_commit"],
            "authority_ledger_sha256": result["source"]["ledger_sha256"],
            "covers": [],
            "credit_replaces": [],
            "span_reasons": [],
            "runnable": True,
            "blocked_reason": None,
            "execution_contract": {
                "judged": True,
                "guards_mode": "all",
                "oracle_required": True,
                "audit_power": "required_bounded_boost",
                "scope": "s5",
                "dimension": "time",
            },
        }
        forged = {"item_id": audits._canonical_digest(forged), **forged}
        tampered = copy.deepcopy(result)
        tampered["items"] = [forged]
        body = {key: value for key, value in tampered.items() if key != "plan_sha256"}
        tampered["plan_sha256"] = audits._canonical_digest(body)
        with self.assertRaisesRegex(audits.AuditError, "not currently due"):
            audits.validate_plan(ROOT, tampered)


class AuditPowerTest(unittest.TestCase):
    def test_sparse_history_still_gets_bounded_audit_boost(self):
        decision = search_health.decide_rounds(
            board="core_cpu",
            workload_class="small",
            configured_rounds=5,
            minimum_rounds=3,
            workload_count=1,
            class_wall_deadline_seconds=60.0,
            policy={
                "trailing_window": 8,
                "gradient_snr_threshold": 2.0,
                "auto_boost_rounds": 5,
                "maximum_rounds": 25,
            },
            history=[],
        )
        boosted = search_health.require_audit_power(decision)
        self.assertEqual(boosted.target_rounds, 10)
        self.assertEqual(boosted.auto_boost_reason, "required_audit_power")
        self.assertTrue(boosted.auto_boost_applied)


if __name__ == "__main__":
    unittest.main()
