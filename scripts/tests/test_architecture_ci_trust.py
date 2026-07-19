from __future__ import annotations

import unittest
from unittest import mock

from scripts import architecture_ci_trust


SHA = "1" * 40


def environment(job: str = "architecture-linux", event: str = "workflow_dispatch") -> dict[str, str]:
    return {
        "GITHUB_ACTIONS": "true",
        "GITHUB_REPOSITORY": "teddyjfpender/stwo-zig",
        "GITHUB_REPOSITORY_ID": "1152389958",
        "GITHUB_REPOSITORY_OWNER_ID": "92999717",
        "GITHUB_WORKFLOW_REF": "teddyjfpender/stwo-zig/.github/workflows/ci.yml@refs/heads/main",
        "GITHUB_REF": "refs/heads/main",
        "GITHUB_JOB": job,
        "GITHUB_WORKFLOW_SHA": SHA,
        "GITHUB_SHA": SHA,
        "GITHUB_RUN_ID": "123",
        "GITHUB_RUN_ATTEMPT": "2",
        "GITHUB_EVENT_NAME": event,
    }


def metadata(event: str = "workflow_dispatch") -> dict[str, object]:
    return {
        "id": 123,
        "run_attempt": 2,
        "event": event,
        "head_branch": "main",
        "head_sha": SHA,
        "path": ".github/workflows/ci.yml",
        "repository": {"id": 1152389958},
        "actor": {"id": 92999717},
        "triggering_actor": {"id": 92999717},
    }


class ArchitectureCiTrustTest(unittest.TestCase):
    def validate(self, *, env=None, data=None, checkout=b"workflow", committed=b"workflow"):
        git = {
            ("rev-parse", "HEAD"): (SHA + "\n").encode(),
            ("status", "--porcelain", "--untracked-files=all"): b"",
            ("show", f"{SHA}:.github/workflows/ci.yml"): committed,
            ("rev-parse", "HEAD^{tree}"): ("2" * 40 + "\n").encode(),
        }
        with (
            mock.patch.object(architecture_ci_trust, "_git", side_effect=lambda *a: git[a]),
            mock.patch.object(architecture_ci_trust.Path, "read_bytes", return_value=checkout),
        ):
            return architecture_ci_trust.validate(
                metadata() if data is None else data,
                "architecture-linux",
                environment() if env is None else env,
            )

    def test_accepts_owner_dispatch_and_trusted_main_push(self) -> None:
        self.assertEqual(SHA, self.validate()["commit"])
        push = metadata("push")
        push["actor"] = {"id": 7}
        push["triggering_actor"] = {"id": 8}
        self.assertEqual(SHA, self.validate(env=environment(event="push"), data=push)["commit"])

    def test_rejects_pull_request_wrong_ref_and_nonowner_dispatch(self) -> None:
        pull = environment(event="pull_request")
        with self.assertRaisesRegex(architecture_ci_trust.TrustError, "reject pull"):
            self.validate(env=pull, data=metadata("pull_request"))
        wrong_ref = environment()
        wrong_ref["GITHUB_REF"] = "refs/pull/7/merge"
        with self.assertRaisesRegex(architecture_ci_trust.TrustError, "GITHUB_REF"):
            self.validate(env=wrong_ref)
        wrong_actor = metadata()
        wrong_actor["actor"] = {"id": 7}
        with self.assertRaisesRegex(architecture_ci_trust.TrustError, "actor"):
            self.validate(data=wrong_actor)

    def test_rejects_workflow_candidate_or_api_identity_substitution(self) -> None:
        wrong_candidate = environment()
        wrong_candidate["GITHUB_SHA"] = "3" * 40
        with self.assertRaisesRegex(architecture_ci_trust.TrustError, "same canonical"):
            self.validate(env=wrong_candidate)
        wrong_api = metadata()
        wrong_api["head_sha"] = "4" * 40
        with self.assertRaisesRegex(architecture_ci_trust.TrustError, "head_sha"):
            self.validate(data=wrong_api)

    def test_rejects_dirty_source_and_workflow_blob_substitution(self) -> None:
        with mock.patch.object(
            architecture_ci_trust,
            "_git",
            side_effect=lambda *a: (
                b" M scripts/architecture_ci_trust.py\n"
                if a[0] == "status"
                else (SHA + "\n").encode()
            ),
        ):
            with self.assertRaisesRegex(architecture_ci_trust.TrustError, "clean"):
                architecture_ci_trust.validate(metadata(), "architecture-linux", environment())
        with self.assertRaisesRegex(architecture_ci_trust.TrustError, "definition bytes"):
            self.validate(checkout=b"substituted")


if __name__ == "__main__":
    unittest.main()
