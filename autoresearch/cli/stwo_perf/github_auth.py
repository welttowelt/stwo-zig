"""GitHub device-flow login and minimal API helpers. Stdlib urllib only."""

from __future__ import annotations

import json
import time
import urllib.error
import urllib.parse
import urllib.request

from . import config

DEVICE_CODE_URL = "https://github.com/login/device/code"
TOKEN_URL = "https://github.com/login/oauth/access_token"
API_ROOT = "https://api.github.com"
DEFAULT_SCOPE = "repo read:user"


class AuthError(RuntimeError):
    pass


def _post_form(url: str, fields: dict) -> dict:
    data = urllib.parse.urlencode(fields).encode()
    req = urllib.request.Request(url, data=data, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode())


def device_login(client_id: str) -> str:
    """Run the device flow; returns the access token. Prints the user code."""
    start = _post_form(DEVICE_CODE_URL, {"client_id": client_id, "scope": DEFAULT_SCOPE})
    if "device_code" not in start:
        raise AuthError(f"device flow start failed: {start}")
    print(f"Open {start['verification_uri']} and enter code: {start['user_code']}")
    interval = int(start.get("interval", 5))
    deadline = time.time() + int(start.get("expires_in", 900))
    while time.time() < deadline:
        time.sleep(interval)
        poll = _post_form(
            TOKEN_URL,
            {
                "client_id": client_id,
                "device_code": start["device_code"],
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            },
        )
        if "access_token" in poll:
            return poll["access_token"]
        error = poll.get("error")
        if error == "authorization_pending":
            continue
        if error == "slow_down":
            interval += 5
            continue
        raise AuthError(f"device flow failed: {error}")
    raise AuthError("device flow timed out")


def api_get(path: str, token: str | None = None) -> dict:
    token = token or config.github_token()
    headers = {"Accept": "application/vnd.github+json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(f"{API_ROOT}{path}", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        raise AuthError(f"GitHub API {path} failed: HTTP {exc.code}") from exc


def whoami(token: str | None = None) -> str:
    return str(api_get("/user", token).get("login", "unknown"))
