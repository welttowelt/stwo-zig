import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "autoresearch" / "backend"))

import identity  # noqa: E402


class IdentityTest(unittest.TestCase):
    def test_normalizes_stable_github_attribution(self):
        value = identity.from_github_payload({
            "id": 42, "login": "alice-dev", "name": " Alice <admin>\n Example ",
            "email": "private@example.test",
        })
        self.assertEqual(value["github_id"], 42)
        self.assertEqual(value["name"], "Alice admin Example")
        self.assertEqual(value["noreply_email"], "42+alice-dev@users.noreply.github.com")
        self.assertNotIn("private", str(value))

    def test_invalid_login_rejected(self):
        with self.assertRaises(identity.IdentityError):
            identity.from_github_payload({"id": 42, "login": "bad/login"})

    def test_coauthor_trailer_uses_verified_noreply_address(self):
        person = identity.from_github_payload({"id": 7, "login": "bob", "name": None})
        self.assertEqual(
            identity.coauthor_trailer(person),
            "Co-authored-by: bob <7+bob@users.noreply.github.com>",
        )


if __name__ == "__main__":
    unittest.main()
