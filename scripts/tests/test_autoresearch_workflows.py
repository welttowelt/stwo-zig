from __future__ import annotations

import json
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts.autoresearch_workflow_policy import (
    PolicyError,
    finalize_verdict,
    inspect_candidate,
)


ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = (
    ROOT / ".github/workflows/judge.yml",
    ROOT / ".github/workflows/promote.yml",
    ROOT / "autoresearch/workflows/judge.yml",
    ROOT / "autoresearch/workflows/promote.yml",
)
ACTION_RE = re.compile(r"uses:\s+[^@\s]+@([^\s]+)")


def git(repo: Path, *args: str) -> str:
    process = subprocess.run(
        ["git", *args], cwd=repo, capture_output=True, text=True, check=True,
    )
    return process.stdout.strip()


class WorkflowContractTest(unittest.TestCase):
    def test_all_third_party_actions_are_commit_pinned(self) -> None:
        for path in WORKFLOWS:
            text = path.read_text(encoding="utf-8")
            pins = ACTION_RE.findall(text)
            self.assertTrue(pins, path)
            self.assertTrue(all(re.fullmatch(r"[0-9a-f]{40}", pin) for pin in pins), path)

    def test_judge_identity_runner_and_authority_order(self) -> None:
        for path in (WORKFLOWS[0], WORKFLOWS[2]):
            text = path.read_text(encoding="utf-8")
            self.assertIn("name: autoresearch-judge", text)
            self.assertIn("runs-on: [self-hosted, macOS, stwo-judge]", text)
            evaluate, publish = text.split("\n  publish:\n", 1)
            self.assertIn("contents: read", evaluate)
            self.assertNotIn("secrets.JUDGE_HMAC_SECRET", evaluate)
            self.assertNotIn("contents: write", evaluate)
            self.assertIn("persist-credentials: false", evaluate)
            self.assertLess(
                evaluate.index("Validate event identity and locked paths"),
                evaluate.index("Evaluate with no promotion authority"),
            )
            self.assertIn("contents: write", publish)
            self.assertLess(
                publish.index("Revalidate immutable candidate and evidence binding"),
                publish.index("secrets.JUDGE_HMAC_SECRET"),
            )
            self.assertLess(
                publish.index("Sign the identity-bound verdict"),
                publish.index("Publish to the judge-only branch"),
            )

    def test_promote_identity_signature_and_board_authority(self) -> None:
        for path in (WORKFLOWS[1], WORKFLOWS[3]):
            text = path.read_text(encoding="utf-8")
            self.assertIn("name: autoresearch-promote", text)
            self.assertIn("permissions: {}", text)
            self.assertIn("contents: write", text)
            self.assertNotIn("pull-requests: write", text)
            self.assertNotIn("issues: write", text)
            self.assertLess(
                text.index("Validate main identity and refresh queued authority"),
                text.index("secrets.JUDGE_HMAC_SECRET"),
            )
            self.assertIn("python3 autoresearch/bots/promote_action.py", text)

        source = (ROOT / "autoresearch/bots/promote_action.py").read_text(encoding="utf-8")
        self.assertIn("signing.verify(verdict)", source)
        self.assertIn("require_current_promotion_authority(repo, verdict)", source)


class WorkflowPolicyTest(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.repo = Path(temporary.name)
        git(self.repo, "init", "-q")
        git(self.repo, "config", "user.name", "Test")
        git(self.repo, "config", "user.email", "test@example.com")
        source = self.repo / "src/prover"
        source.mkdir(parents=True)
        (source / "fri.zig").write_text("const value = 1;\n", encoding="utf-8")
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-qm", "base")
        self.base = git(self.repo, "rev-parse", "HEAD")

        (source / "fri.zig").write_text("const value = 2;\n", encoding="utf-8")
        submission = self.repo / "autoresearch/submissions/20260721-test"
        submission.mkdir(parents=True)
        (submission / "note.md").write_text("# Test\n", encoding="utf-8")
        (submission / "verdict.json").write_text("{}\n", encoding="utf-8")
        (submission / "delta.json").write_text("{}\n", encoding="utf-8")
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-qm", "candidate")
        self.candidate = git(self.repo, "rev-parse", "HEAD")

    def test_preflight_binds_candidate_tree_and_submission(self) -> None:
        receipt = inspect_candidate(self.repo, ROOT, self.base, self.candidate)
        self.assertEqual(receipt["base_commit"], self.base)
        self.assertEqual(receipt["candidate_commit"], self.candidate)
        self.assertEqual(receipt["submission_id"], "20260721-test")
        self.assertRegex(receipt["receipt_sha256"], r"^[0-9a-f]{64}$")

    def test_locked_candidate_change_is_rejected(self) -> None:
        workflow = self.repo / ".github/workflows"
        workflow.mkdir(parents=True)
        (workflow / "attack.yml").write_text("name: attack\n", encoding="utf-8")
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-qm", "locked change")
        with self.assertRaisesRegex(PolicyError, "locked paths changed"):
            inspect_candidate(self.repo, ROOT, self.base, "HEAD")

    def test_finalizer_rejects_identity_mismatch_and_replaces_sentinel(self) -> None:
        receipt = inspect_candidate(self.repo, ROOT, self.base, self.candidate)
        unsigned = self.repo / "unsigned.json"
        signed = self.repo / "signed.json"
        verdict = {
            "kind": "judged",
            "repo_commit": self.candidate[:12],
            "predecessor_commit": self.base[:12],
            "submission_id": receipt["submission_id"],
            "judge_signature": "sentinel",
        }
        unsigned.write_text(json.dumps(verdict), encoding="utf-8")
        with mock.patch.dict(os.environ, {"JUDGE_HMAC_SECRET": "test-authority"}):
            finalize_verdict(unsigned, receipt, signed)
        self.assertRegex(
            json.loads(signed.read_text(encoding="utf-8"))["judge_signature"],
            r"^[0-9a-f]{64}$",
        )

        verdict["repo_commit"] = "0" * 12
        unsigned.write_text(json.dumps(verdict), encoding="utf-8")
        with self.assertRaisesRegex(PolicyError, "repo_commit"):
            finalize_verdict(unsigned, receipt, signed)


if __name__ == "__main__":
    unittest.main()
