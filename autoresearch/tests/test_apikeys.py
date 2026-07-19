import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
import apikeys

SECRET = b"test-secret-32-bytes-long-please"


class ApiKeyTest(unittest.TestCase):
    def test_issue_verify_roundtrip(self):
        key, key_id = apikeys.issue({"login": "teddy", "github_id": 42}, SECRET)
        payload = apikeys.verify(key, SECRET)
        self.assertEqual(payload["login"], "teddy")
        self.assertEqual(payload["github_id"], 42)
        self.assertIn("submissions:write", payload["scopes"])
        self.assertEqual(payload["key_id"], key_id)

    def test_scope_is_enforced(self):
        key, _ = apikeys.issue(
            {"login": "teddy", "github_id": 42}, SECRET,
            scopes=["identity:read"],
        )
        payload = apikeys.verify(key, SECRET)
        with self.assertRaises(apikeys.KeyError_):
            apikeys.require_scope(payload, "submissions:write")

    def test_tampered_payload_rejected(self):
        key, _ = apikeys.issue("teddy", SECRET)
        body, _, sig = key[len(apikeys.PREFIX):].partition(".")
        tampered = apikeys.PREFIX + body[:-2] + "AA." + sig
        with self.assertRaises(apikeys.KeyError_):
            apikeys.verify(tampered, SECRET)

    def test_wrong_secret_rejected(self):
        key, _ = apikeys.issue("teddy", SECRET)
        with self.assertRaises(apikeys.KeyError_):
            apikeys.verify(key, b"another-secret-entirely-here!!!!")

    def test_revoked_key_rejected(self):
        key, key_id = apikeys.issue("teddy", SECRET)
        with self.assertRaises(apikeys.KeyError_):
            apikeys.verify(key, SECRET, revoked={key_id})

    def test_malformed_rejected(self):
        for bad in ("", "ark_", "nope", "ark_abc"):
            with self.assertRaises(apikeys.KeyError_):
                apikeys.verify(bad, SECRET)


if __name__ == "__main__":
    unittest.main()
