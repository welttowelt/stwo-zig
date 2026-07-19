import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "autoresearch" / "backend"))
sys.path.insert(0, str(ROOT / "autoresearch" / "cli"))
sys.path.insert(0, str(ROOT / "autoresearch" / "tests"))

import canonical  # noqa: E402
import intake  # noqa: E402
import promotion  # noqa: E402
import store as store_module  # noqa: E402
import submissions  # noqa: E402
import worker  # noqa: E402
from hermetic_fixture import (  # noqa: E402
    ALICE, FakeLock, HermeticRepos, git, passing_verdict,
)
from store import Store, StoreError  # noqa: E402
from stwo_perf import ledger, runner  # noqa: E402


class PipelineFailureInjectionTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.repos = HermeticRepos(self.root)
        self.store = Store(self.root / "store.json")

    def tearDown(self):
        self.tmp.cleanup()

    def submit(self) -> dict:
        record = submissions.validate_request(
            self.repos.payload(), ALICE, {"core_cpu"},
        )
        return self.store.create_submission(record)

    def intake(self) -> dict:
        self.submit()
        result = intake.process_one(
            self.store,
            self.repos.canonical,
            source_url_resolver=self.repos.source_url,
            attestation_verifier=self.repos.verify_attestation,
        )
        self.assertIsNotNone(result)
        return result

    def judge(self) -> tuple[dict, FakeLock]:
        queued = self.intake()
        self.assertEqual(queued["state"], "queued")
        lock = FakeLock()
        with mock.patch.dict(os.environ, {
            "JUDGE_HMAC_SECRET": "hermetic-signing",
            "JUDGE_HOLDOUT_SECRET": "hermetic-holdout",
        }):
            result = canonical.process_one(
                self.store,
                self.repos.canonical,
                evaluator=passing_verdict,
                lock_acquirer=lambda _repo: lock,
            )
        self.assertIsNotNone(result)
        return result, lock

    def assert_only_main_worktree(self):
        listing = git(self.repos.canonical, "worktree", "list", "--porcelain")
        worktrees = [
            Path(line.removeprefix("worktree ")).resolve()
            for line in listing.splitlines() if line.startswith("worktree ")
        ]
        self.assertEqual(worktrees, [self.repos.canonical.resolve()])

    def test_attestation_verifier_failure_rejects_before_source_is_pinned(self):
        item = self.submit()

        def unavailable(_receipt_file, _source):
            raise intake.IntakeError("attestation service unavailable")

        result = intake.process_one(
            self.store,
            self.repos.canonical,
            source_url_resolver=self.repos.source_url,
            attestation_verifier=unavailable,
        )
        self.assertEqual(result["state"], "rejected")
        self.assertIn("attestation service unavailable", result["worker_error"])
        ref = f"refs/autoresearch/source/{item['id']}"
        with self.assertRaises(subprocess.CalledProcessError):
            git(self.repos.canonical, "rev-parse", "--verify", ref)

    def test_clone_failure_rejects_without_advancing_to_queue(self):
        self.submit()
        missing = self.root / "missing-fork"
        result = intake.process_one(
            self.store,
            self.repos.canonical,
            source_url_resolver=lambda _url: str(missing),
            attestation_verifier=self.repos.verify_attestation,
        )
        self.assertEqual(result["state"], "rejected")
        self.assertIn("git clone failed", result["worker_error"])

    def test_benchmark_failure_rejects_and_releases_all_judge_resources(self):
        queued = self.intake()
        self.assertEqual(queued["state"], "queued")
        lock = FakeLock()

        def fail_benchmark(*_args, **_kwargs):
            raise runner.RunError("injected benchmark crash")

        with mock.patch.dict(os.environ, {
            "JUDGE_HMAC_SECRET": "hermetic-signing",
            "JUDGE_HOLDOUT_SECRET": "hermetic-holdout",
        }):
            result = canonical.process_one(
                self.store,
                self.repos.canonical,
                evaluator=fail_benchmark,
                lock_acquirer=lambda _repo: lock,
            )
        self.assertEqual(result["state"], "rejected")
        self.assertIn("injected benchmark crash", result["worker_error"])
        self.assertTrue(lock.released)
        self.assert_only_main_worktree()
        self.assertEqual(git(self.repos.canonical, "rev-parse", "HEAD"),
                         self.repos.frontier)

    def test_signing_failure_rejects_and_cleans_materialized_worktrees(self):
        queued = self.intake()
        self.assertEqual(queued["state"], "queued")
        lock = FakeLock()
        with mock.patch.dict(os.environ, {
            "JUDGE_HOLDOUT_SECRET": "hermetic-holdout",
        }):
            os.environ.pop("JUDGE_HMAC_SECRET", None)
            result = canonical.process_one(
                self.store,
                self.repos.canonical,
                evaluator=passing_verdict,
                lock_acquirer=lambda _repo: lock,
            )
        self.assertEqual(result["state"], "rejected")
        self.assertIn("JUDGE_HMAC_SECRET is not set", result["worker_error"])
        self.assertTrue(lock.released)
        self.assert_only_main_worktree()

    def test_push_failure_is_exactly_once_locally_and_resumable(self):
        judged, lock = self.judge()
        self.assertEqual(judged["state"], "promotable")
        self.assertTrue(lock.released)
        calls = []

        def flaky_push(_repo, remote, branch, expected_commit):
            calls.append((remote, branch, expected_commit))
            if len(calls) == 1:
                raise promotion.PromotionError("injected network outage")

        with mock.patch.dict(os.environ, {"JUDGE_HMAC_SECRET": "hermetic-signing"}):
            paused = promotion.process_one(
                self.store, self.repos.canonical, "publish", "main",
                push_fn=flaky_push,
            )
            first_tip = git(self.repos.canonical, "rev-parse", "HEAD")
            resumed = promotion.process_one(
                self.store, self.repos.canonical, "publish", "main",
                push_fn=flaky_push,
            )

        self.assertEqual(paused["state"], "promoting")
        self.assertIn("injected network outage", paused["worker_error"])
        self.assertEqual(resumed["state"], "promoted")
        self.assertEqual(first_tip, git(self.repos.canonical, "rev-parse", "HEAD"))
        self.assertEqual(calls[0][2], calls[1][2])
        self.assertEqual(len(ledger.load(self.repos.canonical)), 1)
        submission_dir = (
            self.repos.canonical / "autoresearch/submissions" / judged["id"]
        )
        self.assertEqual(sorted(path.name for path in submission_dir.iterdir()), [
            "delta.json", "judged-verdict.json", "note.md", "remote.json",
        ])

    def test_partial_promotion_stops_for_operator_repair(self):
        judged, _lock = self.judge()

        def fail_record(_repo, _record):
            raise promotion.PromotionError("injected disk failure")

        with mock.patch.dict(os.environ, {"JUDGE_HMAC_SECRET": "hermetic-signing"}):
            failed = promotion.process_one(
                self.store,
                self.repos.canonical,
                record_writer=fail_record,
            )
        self.assertEqual(failed["state"], "promotion_error")
        self.assertNotIn("promotion_commit", failed)
        self.assertEqual(git(self.repos.canonical, "rev-parse", "HEAD"),
                         judged["canonical_commit"])
        self.assertFalse((
            self.repos.canonical / "autoresearch/submissions" / judged["id"]
        ).exists())
        with self.assertRaisesRegex(RuntimeError, "requires repository repair"):
            worker.cycle(self.store, self.repos.canonical, True, None, "main")

    def test_frontier_move_marks_candidate_stale_without_merging_it(self):
        judged, _lock = self.judge()
        git(self.repos.canonical, "commit", "--allow-empty", "-m", "frontier moved")
        moved = git(self.repos.canonical, "rev-parse", "HEAD")
        with mock.patch.dict(os.environ, {"JUDGE_HMAC_SECRET": "hermetic-signing"}):
            stale = promotion.process_one(self.store, self.repos.canonical)
        self.assertEqual(stale["state"], "stale")
        self.assertEqual(git(self.repos.canonical, "rev-parse", "HEAD"), moved)
        self.assertNotEqual(moved, judged["canonical_commit"])


class StoreFailureInjectionTest(unittest.TestCase):
    @staticmethod
    def record() -> dict:
        return {
            "author": dict(ALICE),
            "coauthors": [],
            "source": {"commit": "b" * 40},
            "claim": {
                "board": "core_cpu", "workload_class": "small",
                "dimension": "time", "shipping_index": 0.9,
            },
        }

    def test_failed_atomic_replace_preserves_last_committed_snapshot(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "store.json"
            store = Store(path)
            store.record_identity(ALICE)
            before = path.read_bytes()
            with mock.patch.object(
                store_module.os, "replace", side_effect=OSError("disk full"),
            ):
                with self.assertRaisesRegex(OSError, "disk full"):
                    store.record_identity({**ALICE, "name": "Mutated"})
            self.assertEqual(path.read_bytes(), before)
            self.assertEqual(store.snapshot()["users"]["101"]["name"], "Alice Example")

    def test_corrupt_store_is_rejected_instead_of_silently_reinitialized(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "store.json"
            path.write_text('{"schema_version": 2, "submissions": [')
            with self.assertRaisesRegex(StoreError, "cannot load backend store"):
                Store(path).snapshot()

    def test_concurrent_claimers_cannot_claim_the_same_submission(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = Store(Path(tmp) / "store.json")
            item = store.create_submission(self.record())
            barrier = threading.Barrier(3)
            results = []
            errors = []

            def claim():
                try:
                    barrier.wait()
                    results.append(store.claim_next(
                        {"received"}, "validating", "concurrent claimant",
                    ))
                except Exception as exc:  # surfaced by the main test thread
                    errors.append(exc)

            threads = [threading.Thread(target=claim) for _ in range(2)]
            for thread in threads:
                thread.start()
            barrier.wait()
            for thread in threads:
                thread.join()

            self.assertEqual(errors, [])
            claimed = [result for result in results if result is not None]
            self.assertEqual([result["id"] for result in claimed], [item["id"]])
            self.assertEqual(results.count(None), 1)
            self.assertEqual(store.get_submission(item["id"])["state"], "validating")


if __name__ == "__main__":
    unittest.main()
