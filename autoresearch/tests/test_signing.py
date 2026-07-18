import os
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "cli"))
from stwo_perf import signing


class SigningTest(unittest.TestCase):
    def setUp(self):
        os.environ["JUDGE_HMAC_SECRET"] = "test-judge-secret"

    def tearDown(self):
        os.environ.pop("JUDGE_HMAC_SECRET", None)

    def test_sign_verify_roundtrip(self):
        verdict = {"kind": "judged", "score": {"R_geomean": 0.97}}
        signed = signing.sign(verdict)
        signing.verify(signed)  # must not raise

    def test_tampered_score_rejected(self):
        signed = signing.sign({"kind": "judged", "score": {"R_geomean": 0.97}})
        signed["score"]["R_geomean"] = 0.5
        with self.assertRaises(signing.SigningError):
            signing.verify(signed)

    def test_unsigned_rejected(self):
        with self.assertRaises(signing.SigningError):
            signing.verify({"kind": "judged"})

    def test_wrong_secret_rejected(self):
        signed = signing.sign({"kind": "judged"})
        os.environ["JUDGE_HMAC_SECRET"] = "different-secret"
        with self.assertRaises(signing.SigningError):
            signing.verify(signed)

    def test_missing_secret_errors(self):
        del os.environ["JUDGE_HMAC_SECRET"]
        with self.assertRaises(signing.SigningError):
            signing.sign({"kind": "judged"})


if __name__ == "__main__":
    unittest.main()
