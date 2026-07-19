import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "autoresearch" / "backend"))

from store import Store, StoreError  # noqa: E402


def person(github_id=1, login="alice"):
    return {
        "github_id": github_id, "login": login, "name": login,
        "profile_url": f"https://github.com/{login}",
        "noreply_email": f"{github_id}+{login}@users.noreply.github.com",
    }


def record(commit="b" * 40, coauthors=None, tree=None):
    value = {
        "author": person(),
        "coauthors": coauthors or [],
        "source": {"commit": commit},
        "claim": {"board": "core_cpu", "workload_class": "small",
                  "dimension": "time", "shipping_index": 0.9},
    }
    if tree:
        value["qualification"] = {"receipt": {"candidate_tree": tree}}
    return value


class StoreTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.tmp.name) / "store.json")

    def tearDown(self):
        self.tmp.cleanup()

    def test_active_limit_and_commit_deduplication(self):
        first = self.store.create_submission(record())
        self.assertEqual(first["state"], "received")
        with self.assertRaises(StoreError):
            self.store.create_submission(record("c" * 40))
        self.store.transition(first["id"], {"received"}, "validating", "test")
        self.store.transition(first["id"], {"validating"}, "rejected", "test")
        with self.assertRaises(StoreError):
            self.store.create_submission(record())

    def test_coauthor_consent_releases_verified_submission(self):
        item = self.store.create_submission(record(coauthors=[{
            "login": "bob", "status": "pending",
        }]))
        self.store.transition(item["id"], {"received"}, "validating", "intake")
        self.store.transition(
            item["id"], {"validating"}, "awaiting_coauthors", "source verified",
        )
        updated = self.store.accept_coauthor(item["id"], person(2, "bob"))
        self.assertEqual(updated["state"], "queued")
        self.assertEqual(updated["coauthors"][0]["identity"]["github_id"], 2)

    def test_key_revocation_is_durable(self):
        self.store.record_key(person(), "key-1", ["identity:read"])
        self.store.revoke_key("key-1")
        self.assertEqual(self.store.revoked(), {"key-1"})

    def test_same_tree_cannot_grind_a_new_holdout_seed(self):
        first = self.store.create_submission(record(tree="a" * 40))
        self.store.transition(first["id"], {"received"}, "validating", "test")
        self.store.transition(first["id"], {"validating"}, "rejected", "test")
        with self.assertRaisesRegex(StoreError, "tree was already submitted"):
            self.store.create_submission(record("c" * 40, tree="a" * 40))


if __name__ == "__main__":
    unittest.main()
