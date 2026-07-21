import copy
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "autoresearch" / "backend"))

import submissions  # noqa: E402


AUTHOR = {
    "github_id": 1, "login": "alice", "name": "Alice",
    "profile_url": "https://github.com/alice",
    "noreply_email": "1+alice@users.noreply.github.com",
}
CLAIM = {"board": "core_cpu", "workload_class": "small",
         "dimension": "time", "shipping_index": 0.9}
NOTE = """# Faster field loop

## Model and harness
Agent and stwo-perf.
## Hypothesis
Fewer loads.
## Changes
Loop change.
## Results
Public R 0.9.
## Caveats
Central judge pending.
"""


def request():
    receipt = {
        "schema_version": 1, "candidate_commit": "b" * 40,
        "frontier_commit": "a" * 40, "submitter_login": "alice",
        "claim": copy.deepcopy(CLAIM),
    }
    return {
        "schema_version": 2,
        "source": {
            "repository": "https://github.com/alice/stwo-zig-fork",
            "commit": "b" * 40, "frontier_commit": "a" * 40,
            "ref": "refs/heads/faster",
        },
        "qualification": {"receipt": receipt},
        "claim": copy.deepcopy(CLAIM), "note": NOTE, "coauthors": ["bob"],
    }


class SubmissionValidationTest(unittest.TestCase):
    def test_valid_request_binds_identity_source_and_claim(self):
        value = submissions.validate_request(
            request(), AUTHOR, {"core_cpu": {"small", "wide", "deep", "xlarge", "huge"}},
        )
        self.assertEqual(value["author"]["github_id"], 1)
        self.assertEqual(value["coauthors"], [{"login": "bob", "status": "pending"}])

    def test_other_users_repository_is_rejected(self):
        body = request()
        body["source"]["repository"] = "https://github.com/mallory/stwo-zig"
        with self.assertRaises(submissions.SubmissionError):
            submissions.validate_request(body, AUTHOR, {"core_cpu": {"small"}})

    def test_receipt_claim_mismatch_is_rejected(self):
        body = request()
        body["claim"]["shipping_index"] = 0.8
        with self.assertRaises(submissions.SubmissionError):
            submissions.validate_request(body, AUTHOR, {"core_cpu": {"small"}})

    def test_board_owned_classes_fail_closed(self):
        body = request()
        body["claim"]["workload_class"] = "huge"
        body["qualification"]["receipt"]["claim"] = copy.deepcopy(body["claim"])
        with self.assertRaisesRegex(submissions.SubmissionError, "not runnable on riscv"):
            body["claim"]["board"] = "riscv"
            body["qualification"]["receipt"]["claim"] = copy.deepcopy(body["claim"])
            submissions.validate_request(
                body, AUTHOR, {"riscv": {"small", "wide", "deep"}},
            )

        body = request()
        body["claim"]["workload_class"] = "invented"
        body["qualification"]["receipt"]["claim"] = copy.deepcopy(body["claim"])
        with self.assertRaisesRegex(submissions.SubmissionError, "not runnable"):
            submissions.validate_request(body, AUTHOR, {"core_cpu": {"small"}})

    def test_repository_parser_accepts_real_github_name_characters(self):
        self.assertEqual(
            submissions.normalize_repository_url("https://github.com/alice/repo.name_1.git"),
            "https://github.com/alice/repo.name_1",
        )


if __name__ == "__main__":
    unittest.main()
