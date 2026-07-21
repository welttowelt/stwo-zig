import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "autoresearch" / "backend"))
sys.path.insert(0, str(ROOT / "autoresearch" / "cli"))

import intake  # noqa: E402
from stwo_perf import qualification  # noqa: E402
from stwo_perf.manifest import Manifest  # noqa: E402


def git(repo, *args):
    return subprocess.run(
        ["git", *args], cwd=repo, check=True, capture_output=True, text=True,
    ).stdout.strip()


class IntakeAttestationTest(unittest.TestCase):
    def test_attestation_is_bound_to_signer_commit_ref_and_hosted_runner(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            git(repo, "init")
            git(repo, "config", "user.name", "Test")
            git(repo, "config", "user.email", "test@example.test")
            (repo / "src/core/fields").mkdir(parents=True)
            (repo / "autoresearch").mkdir()
            (repo / "src/core/fields/value.zig").write_text("one\n")
            (repo / "autoresearch/policy.txt").write_text("locked\n")
            git(repo, "add", ".")
            git(repo, "commit", "-m", "frontier")
            frontier = git(repo, "rev-parse", "HEAD")
            manifest = Manifest(repo, {
                "editable_paths": [{"glob": "src/core/fields/**", "min_rung": "s3"}],
                "locked_paths": ["autoresearch/**"],
                "workload_registry": {
                    "classes": {"small": {
                        "scored": True,
                        "resource": {
                            "profile": "standard",
                            "command_timeout_seconds": 60,
                            "wall_clock_cap_seconds": 60,
                        },
                        "sampling": {
                            "warmups": 1,
                            "samples_per_round": 1,
                            "min_rounds": 1,
                            "max_rounds": 1,
                        },
                    }},
                    "groups": {"native": {
                        "enabled": True,
                        "promotion_eligible": True,
                        "board": "core_cpu",
                        "build_step": "true",
                        "binary": "bin/native",
                        "report_schema": "native_proof_v6",
                        "workloads": {"wf": {
                            "class": "small",
                            "args": "--x",
                            "native_unit": "rows",
                        }},
                    }},
                },
            })
            (repo / "src/core/fields/value.zig").write_text("two\n")
            git(repo, "add", ".")
            git(repo, "commit", "-m", "candidate")
            candidate = git(repo, "rev-parse", "HEAD")
            git(repo, "update-ref", "refs/remotes/origin/feature", candidate)
            claim = {"board": "core_cpu", "workload_class": "small",
                     "dimension": "time", "shipping_index": 0.9}
            receipt = qualification.build_receipt(
                repo, manifest, frontier, "alice",
                {name: True for name in qualification.REQUIRED_CHECKS}, claim,
            )
            encoded = (json.dumps(receipt, indent=2, sort_keys=True) + "\n").encode()
            record = {
                "source": {
                    "repository": "https://github.com/alice/fork",
                    "commit": candidate, "frontier_commit": frontier,
                    "ref": "refs/heads/feature",
                },
                "qualification": {
                    "receipt": receipt,
                    "attestation": {
                        "artifact_digest": "sha256:" + hashlib.sha256(encoded).hexdigest(),
                        "url": "https://github.com/alice/fork/attestations/1",
                    },
                },
            }
            original = intake._run
            gh_calls = []

            def intercept(args, cwd=None):
                if args[:3] == ["gh", "attestation", "verify"]:
                    gh_calls.append(args)
                    return "verified"
                return original(args, cwd)

            with mock.patch.object(intake, "_run", side_effect=intercept):
                evidence = intake.verify_checkout(repo, manifest, record)
            self.assertTrue(evidence["attestation_verified"])
            command = gh_calls[0]
            self.assertIn("alice/fork/.github/workflows/qualify-fork.yml", command)
            self.assertIn(candidate, command)
            self.assertIn("refs/heads/feature", command)
            self.assertIn("--deny-self-hosted-runners", command)


if __name__ == "__main__":
    unittest.main()
