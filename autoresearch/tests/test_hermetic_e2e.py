import contextlib
import io
import json
import os
import stat
import sys
import tempfile
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
import server  # noqa: E402
from hermetic_fixture import (  # noqa: E402
    ALICE, BOB, FakeLock, HermeticRepos, git, passing_verdict,
)
from hermetic_http import HandlerTransport  # noqa: E402
from store import Store  # noqa: E402
from stwo_perf import config, ledger, signing  # noqa: E402
from stwo_perf.__main__ import main as cli_main  # noqa: E402


class HermeticEndToEndTest(unittest.TestCase):
    def test_cli_api_queue_judge_and_git_promotion(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repos = HermeticRepos(root)
            store = Store(root / "store.json")
            identities = {
                "alice-device-token": ALICE,
                "bob-device-token": BOB,
            }

            def resolve_identity(token):
                return dict(identities[token])

            handler = server.make_handler(
                repos.canonical,
                b"hermetic-api-signing-secret-32b",
                store,
                "hermetic-client-id",
                identity_resolver=resolve_identity,
            )
            handler.log_message = lambda _self, _fmt, *_args: None
            transport = HandlerTransport(handler)
            receipt_path = root / "qualification-receipt.json"
            receipt_path.write_text(
                json.dumps(repos.receipt, indent=2, sort_keys=True) + "\n"
            )
            note_path = root / "note.md"
            note_path.write_text(repos.payload()["note"])
            alice_config = root / "alice-config"
            bob_config = root / "bob-config"
            previous_cwd = Path.cwd()
            stdout = io.StringIO()
            stderr = io.StringIO()

            with mock.patch("urllib.request.urlopen", side_effect=transport.urlopen), \
                    contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                try:
                    os.chdir(repos.fork)
                    with mock.patch.dict(os.environ, {
                        "XDG_CONFIG_HOME": str(alice_config),
                        "STWO_PERF_API_URL": "https://backend.test",
                        "STWO_PERF_GITHUB_TOKEN": "alice-device-token",
                    }):
                        os.environ.pop("STWO_PERF_API_KEY", None)
                        self.assertEqual(cli_main(["apikey"]), 0)
                        alice_key = config.api_key()
                        self.assertIsNotNone(alice_key)
                        self.assertEqual(cli_main(["whoami"]), 0)
                        self.assertEqual(cli_main([
                            "submit-remote",
                            "--receipt", str(receipt_path),
                            "--repository", "https://github.com/alice/fork",
                            "--ref", "refs/heads/feature",
                            "--note-file", str(note_path),
                            "--coauthor", "bob",
                        ]), 0)

                    submitted = store.snapshot()["submissions"]
                    self.assertEqual(len(submitted), 1)
                    submission_id = submitted[0]["id"]
                    self.assertEqual(submitted[0]["state"], "received")
                    self.assertEqual(submitted[0]["coauthors"][0]["status"], "pending")

                    with mock.patch.dict(os.environ, {
                        "XDG_CONFIG_HOME": str(bob_config),
                        "STWO_PERF_API_URL": "https://backend.test",
                        "STWO_PERF_GITHUB_TOKEN": "bob-device-token",
                    }):
                        os.environ.pop("STWO_PERF_API_KEY", None)
                        self.assertEqual(cli_main(["apikey"]), 0)
                        bob_key = config.api_key()
                        self.assertIsNotNone(bob_key)
                        self.assertNotEqual(bob_key, alice_key)
                        self.assertEqual(
                            cli_main(["coauthor-accept", submission_id]), 0,
                        )

                    accepted = store.get_submission(submission_id)
                    self.assertEqual(accepted["state"], "received")
                    self.assertEqual(
                        accepted["coauthors"][0]["identity"]["github_id"],
                        BOB["github_id"],
                    )

                    attestation_calls = []

                    def verify_attestation(receipt_file, source):
                        repos.verify_attestation(receipt_file, source)
                        attestation_calls.append((receipt_file.read_bytes(), dict(source)))

                    queued = intake.process_one(
                        store,
                        repos.canonical,
                        source_url_resolver=repos.source_url,
                        attestation_verifier=verify_attestation,
                    )
                    self.assertEqual(queued["state"], "queued")
                    self.assertTrue(queued["intake_evidence"]["attestation_verified"])
                    self.assertEqual(len(attestation_calls), 1)

                    lock = FakeLock()
                    with mock.patch.dict(os.environ, {
                        "JUDGE_HMAC_SECRET": "hermetic-judge-signing",
                        "JUDGE_HOLDOUT_SECRET": "hermetic-hidden-holdout",
                    }):
                        judged = canonical.process_one(
                            store,
                            repos.canonical,
                            evaluator=passing_verdict,
                            lock_acquirer=lambda _repo: lock,
                        )
                        self.assertEqual(judged["state"], "promotable")
                        signing.verify(judged["judged_verdict"])
                        promoted = promotion.process_one(store, repos.canonical)
                    self.assertTrue(lock.released)
                    self.assertEqual(promoted["state"], "promoted")

                    with mock.patch.dict(os.environ, {
                        "XDG_CONFIG_HOME": str(alice_config),
                        "STWO_PERF_API_URL": "https://backend.test",
                        "STWO_PERF_API_KEY": alice_key,
                    }):
                        self.assertEqual(
                            cli_main(["submission-status", submission_id]), 0,
                        )
                finally:
                    os.chdir(previous_cwd)

            config_file = alice_config / "stwo-perf/config.json"
            self.assertEqual(stat.S_IMODE(config_file.stat().st_mode), 0o600)
            self.assertNotIn("alice-device-token", config_file.read_text())
            self.assertIn("remote submission queued", stdout.getvalue())
            self.assertIn("co-authorship accepted", stdout.getvalue())
            self.assertIn("promoted", stdout.getvalue())
            self.assertEqual(stderr.getvalue(), "")

            canonical_commit = promoted["canonical_commit"]
            promotion_commit = promoted["ledger_commit"]
            self.assertEqual(git(repos.canonical, "rev-parse", "HEAD"), promotion_commit)
            self.assertEqual(git(repos.canonical, "rev-parse", "HEAD^"), canonical_commit)
            self.assertEqual(
                git(repos.canonical, "rev-parse", f"{canonical_commit}^"),
                repos.frontier,
            )
            self.assertEqual(
                git(repos.canonical, "rev-parse", f"{canonical_commit}^{{tree}}"),
                repos.candidate_tree,
            )
            self.assertEqual(
                git(repos.canonical, "show", "-s", "--format=%an", canonical_commit),
                canonical.BOT_NAME,
            )
            message = git(
                repos.canonical, "show", "-s", "--format=%B", canonical_commit,
            )
            self.assertIn(
                "Co-authored-by: Alice Example "
                "<101+alice@users.noreply.github.com>",
                message,
            )
            self.assertIn(
                "Co-authored-by: Bob Example <202+bob@users.noreply.github.com>",
                message,
            )

            record_dir = repos.canonical / "autoresearch/submissions" / submission_id
            remote_record = json.loads((record_dir / "remote.json").read_text())
            self.assertEqual(remote_record["author"]["github_id"], ALICE["github_id"])
            self.assertEqual(
                remote_record["coauthors"][0]["identity"]["github_id"],
                BOB["github_id"],
            )
            delta = json.loads((record_dir / "delta.json").read_text())
            self.assertEqual(delta["candidate_tree"], repos.candidate_tree)
            self.assertEqual(delta["source_commit"], repos.candidate)
            rows = ledger.load(repos.canonical)
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0].submission_id, submission_id)
            self.assertEqual(rows[0].outcome, "promoted")

            endpoints = [(request["method"], request["target"])
                         for request in transport.requests]
            self.assertEqual(endpoints.count(("POST", "/v1/auth/github/keys")), 2)
            self.assertIn(("POST", "/v1/submissions"), endpoints)
            self.assertIn((
                "POST", f"/v1/submissions/{submission_id}/coauthors/accept",
            ), endpoints)
            self.assertIn(("GET", f"/v1/submissions/{submission_id}"), endpoints)


if __name__ == "__main__":
    unittest.main()
