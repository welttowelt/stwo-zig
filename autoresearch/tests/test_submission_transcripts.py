import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "cli"))
from stwo_perf import submitter  # noqa: E402


class TranscriptConsentTest(unittest.TestCase):
    def test_silent_omission_refused(self):
        with self.assertRaisesRegex(submitter.SubmitError, "declination"):
            submitter.resolve_transcripts(None, transcripts_declined=False)

    def test_explicit_declination_accepted(self):
        self.assertEqual(submitter.resolve_transcripts(None, transcripts_declined=True), [])

    def test_transcripts_and_declination_mutually_exclusive(self):
        with tempfile.TemporaryDirectory() as raw:
            with self.assertRaisesRegex(submitter.SubmitError, "mutually exclusive"):
                submitter.resolve_transcripts(Path(raw), transcripts_declined=True)

    def test_empty_directory_refused(self):
        with tempfile.TemporaryDirectory() as raw:
            with self.assertRaisesRegex(submitter.SubmitError, "no files"):
                submitter.resolve_transcripts(Path(raw), transcripts_declined=False)

    def test_sanitized_transcripts_accepted(self):
        with tempfile.TemporaryDirectory() as raw:
            session = Path(raw) / "session-01.md"
            session.write_text("# session\nuser: make it faster\nassistant: measured first\n")
            files = submitter.resolve_transcripts(Path(raw), transcripts_declined=False)
            self.assertEqual([p.name for p in files], ["session-01.md"])

    def test_secret_scan_still_fails_closed(self):
        with tempfile.TemporaryDirectory() as raw:
            leaky = Path(raw) / "session-01.md"
            leaky.write_text("token: ghp_0123456789abcdefghijklmnopqrstuvwxyz\n")
            with self.assertRaisesRegex(submitter.SubmitError, "secret scan"):
                submitter.resolve_transcripts(Path(raw), transcripts_declined=False)


if __name__ == "__main__":
    unittest.main()
