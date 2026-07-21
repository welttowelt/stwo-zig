import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "cli"))
from stwo_perf import submitter

VALID_NOTE = """# Batch quotient inversions

## Model and harness
Claude Fable 5, stwo-perf.

## Hypothesis
Inversion chains are the wall.

## Changes
Batch in bounded tiles.

## Results
R 0.98.

## Caveats
None.
"""


class NoteValidationTest(unittest.TestCase):
    def test_valid_note_passes(self):
        self.assertEqual(submitter.validate_note(VALID_NOTE), [])

    def test_missing_section_flagged(self):
        broken = VALID_NOTE.replace("## Caveats\nNone.\n", "")
        problems = submitter.validate_note(broken)
        self.assertTrue(any("Caveats" in p for p in problems))

    def test_out_of_order_flagged(self):
        swapped = VALID_NOTE.replace(
            "## Hypothesis\nInversion chains are the wall.\n\n## Changes",
            "## Changes\nBatch in bounded tiles.\n\n## Hypothesis",
        )
        problems = submitter.validate_note(swapped)
        self.assertTrue(problems)

    def test_oversized_note_flagged(self):
        big = VALID_NOTE + "x" * (submitter.NOTE_MAX_BYTES)
        problems = submitter.validate_note(big)
        self.assertTrue(any("KiB" in p for p in problems))

    def test_missing_title_flagged(self):
        problems = submitter.validate_note(VALID_NOTE.replace("# Batch", "Batch"))
        self.assertTrue(any("title" in p for p in problems))


class SecretScanTest(unittest.TestCase):
    def _scan(self, content: str) -> list[str]:
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "session.jsonl").write_text(content)
            return submitter.scan_transcripts(Path(tmp))

    def test_clean_transcript_passes(self):
        self.assertEqual(self._scan("user: make it faster\nassistant: batching."), [])

    def test_github_token_caught(self):
        self.assertTrue(self._scan("token ghp_" + "a" * 30))

    def test_private_key_caught(self):
        self.assertTrue(self._scan("-----BEGIN RSA PRIVATE KEY-----"))

    def test_aws_key_caught(self):
        self.assertTrue(self._scan("AKIA" + "A" * 16))

    def test_generic_assignment_caught(self):
        self.assertTrue(self._scan('api_key = "abcdef0123456789abcdef"'))


class CheckClaimedVerdictsTest(unittest.TestCase):
    @staticmethod
    def _verdict(board, workload_class, kind="claimed"):
        return {
            "kind": kind,
            "declared_objective": {"board": board, "workload_class": workload_class},
        }

    def test_same_class_across_boards_is_legitimate(self):
        submitter.check_claimed_verdicts(
            [self._verdict("core_cpu", "small"), self._verdict("core_metal", "small")],
            ["a.json", "b.json"],
        )

    def test_same_board_and_class_is_duplicate(self):
        with self.assertRaisesRegex(submitter.SubmitError, "core_metal/small"):
            submitter.check_claimed_verdicts(
                [self._verdict("core_metal", "small"),
                 self._verdict("core_metal", "small")],
                ["a.json", "b.json"],
            )

    def test_missing_board_defaults_to_core_cpu(self):
        bare = {"kind": "claimed", "declared_objective": {"workload_class": "wide"}}
        with self.assertRaisesRegex(submitter.SubmitError, "core_cpu/wide"):
            submitter.check_claimed_verdicts(
                [bare, self._verdict("core_cpu", "wide")], ["a.json", "b.json"],
            )

    def test_judged_verdict_refused(self):
        with self.assertRaisesRegex(submitter.SubmitError, "judge"):
            submitter.check_claimed_verdicts(
                [self._verdict("core_cpu", "small", kind="judged")], ["a.json"],
            )


if __name__ == "__main__":
    unittest.main()
