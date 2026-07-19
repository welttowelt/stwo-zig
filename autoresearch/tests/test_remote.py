import io
import sys
import unittest
import urllib.error
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "autoresearch" / "cli"))

from stwo_perf import remote  # noqa: E402


class Response:
    def __init__(self, body):
        self.body = body

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def read(self):
        return self.body


class RemoteClientTest(unittest.TestCase):
    def test_submission_uses_configured_api_key_as_bearer(self):
        seen = {}

        def open_request(req, timeout):
            seen["authorization"] = req.get_header("Authorization")
            seen["method"] = req.method
            seen["timeout"] = timeout
            return Response(b'{"submission":{"id":"one"}}')

        with mock.patch("urllib.request.urlopen", side_effect=open_request):
            result = remote.submit("https://judge.example", "ark_secret", {"x": 1})
        self.assertEqual(result["submission"]["id"], "one")
        self.assertEqual(seen["authorization"], "Bearer ark_secret")
        self.assertEqual(seen["method"], "POST")

    def test_backend_json_error_is_preserved(self):
        error = urllib.error.HTTPError(
            "https://judge.example/v1/me", 401, "Unauthorized", {},
            io.BytesIO(b'{"error":"key revoked"}'),
        )
        with mock.patch("urllib.request.urlopen", side_effect=error):
            with self.assertRaisesRegex(remote.RemoteError, "key revoked"):
                remote.me("https://judge.example", "ark_revoked")


if __name__ == "__main__":
    unittest.main()
