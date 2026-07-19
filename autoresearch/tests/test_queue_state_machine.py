import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "autoresearch" / "backend"))

from store import (  # noqa: E402
    ACTIVE_STATES,
    ALL_STATES,
    STATE_TRANSITIONS,
    TERMINAL_STATES,
    Store,
    StoreError,
)


def identity(github_id=1, login="alice"):
    return {
        "github_id": github_id, "login": login, "name": login,
        "profile_url": f"https://github.com/{login}",
        "noreply_email": f"{github_id}+{login}@users.noreply.github.com",
    }


class QueueStateMachineTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / "store.json"
        self.store = Store(self.path)

    def tearDown(self):
        self.tmp.cleanup()

    def seed(self, state, coauthor_status="pending"):
        data = Store._empty()
        data["submissions"] = [{
            "id": "submission-1",
            "state": state,
            "created_utc": "2026-01-01T00:00:00Z",
            "updated_utc": "2026-01-01T00:00:00Z",
            "state_history": [{
                "state": state, "at": "2026-01-01T00:00:00Z", "detail": "fixture",
            }],
            "author": identity(),
            "coauthors": [{"login": "bob", "status": coauthor_status}],
            "source": {"commit": "a" * 40},
        }]
        self.path.write_text(json.dumps(data))

    def test_state_partition_and_graph_are_total(self):
        self.assertFalse(ACTIVE_STATES & TERMINAL_STATES)
        self.assertEqual(ACTIVE_STATES | TERMINAL_STATES, ALL_STATES)
        self.assertEqual(set(STATE_TRANSITIONS), ALL_STATES)
        for source, targets in STATE_TRANSITIONS.items():
            self.assertTrue(set(targets) <= ALL_STATES, source)
        for terminal in TERMINAL_STATES:
            self.assertEqual(STATE_TRANSITIONS[terminal], frozenset())

    def test_every_state_can_reach_a_terminal_state(self):
        def reaches_terminal(state, seen):
            if state in TERMINAL_STATES:
                return True
            return any(
                target not in seen and reaches_terminal(target, seen | {target})
                for target in STATE_TRANSITIONS[state]
            )

        for state in ALL_STATES:
            with self.subTest(state=state):
                self.assertTrue(reaches_terminal(state, {state}))

    def test_every_allowed_and_forbidden_state_pair(self):
        for source in sorted(ALL_STATES):
            for target in sorted(ALL_STATES):
                with self.subTest(source=source, target=target):
                    self.seed(source)
                    if target in STATE_TRANSITIONS[source]:
                        updated = self.store.transition(
                            "submission-1", {source}, target, "exhaustive test",
                        )
                        self.assertEqual(updated["state"], target)
                        self.assertEqual(updated["state_history"][-1]["state"], target)
                    else:
                        with self.assertRaisesRegex(StoreError, "forbidden"):
                            self.store.transition(
                                "submission-1", {source}, target, "must fail",
                            )
                        self.assertEqual(
                            self.store.get_submission("submission-1")["state"], source,
                        )

    def test_compare_and_swap_expected_state_is_enforced(self):
        self.seed("queued")
        with self.assertRaisesRegex(StoreError, "expected one of"):
            self.store.transition(
                "submission-1", {"received"}, "validating", "stale worker",
            )
        self.assertEqual(self.store.get_submission("submission-1")["state"], "queued")

    def test_claim_next_cannot_bypass_the_graph(self):
        self.seed("received")
        with self.assertRaisesRegex(StoreError, "forbidden"):
            self.store.claim_next({"received"}, "promoted", "malicious worker")
        self.assertEqual(self.store.get_submission("submission-1")["state"], "received")

    def test_attribution_is_mutable_only_before_queue_entry(self):
        mutable = {"received", "validating", "awaiting_coauthors"}
        for state in sorted(ALL_STATES):
            with self.subTest(state=state):
                self.seed(state)
                if state in mutable:
                    updated = self.store.accept_coauthor(
                        "submission-1", identity(2, "bob"),
                    )
                    self.assertEqual(updated["coauthors"][0]["status"], "accepted")
                    expected = "queued" if state == "awaiting_coauthors" else state
                    self.assertEqual(updated["state"], expected)
                else:
                    with self.assertRaisesRegex(StoreError, "attribution is frozen"):
                        self.store.accept_coauthor(
                            "submission-1", identity(2, "bob"),
                        )


if __name__ == "__main__":
    unittest.main()
