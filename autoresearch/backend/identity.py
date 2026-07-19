"""GitHub identity verification and safe git-attribution metadata."""

from __future__ import annotations

import json
import re
import urllib.error
import urllib.request

GITHUB_USER_URL = "https://api.github.com/user"
LOGIN_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$")


class IdentityError(RuntimeError):
    pass


def from_github_payload(payload: dict) -> dict:
    """Normalize the stable fields needed for authentication and git credit."""
    login = payload.get("login")
    github_id = payload.get("id")
    if not isinstance(login, str) or not LOGIN_RE.fullmatch(login):
        raise IdentityError("GitHub response has an invalid login")
    if not isinstance(github_id, int) or github_id <= 0:
        raise IdentityError("GitHub response has an invalid numeric id")
    display_name = payload.get("name")
    if not isinstance(display_name, str) or not display_name.strip():
        display_name = login
    safe_name = " ".join(display_name.split()).replace("<", "").replace(">", "") or login
    return {
        "github_id": github_id,
        "login": login,
        "name": safe_name[:128],
        "profile_url": f"https://github.com/{login}",
        # Always use the GitHub-recognized private noreply form. Do not store a
        # user's possibly-private profile email in the backend or receipts.
        "noreply_email": f"{github_id}+{login}@users.noreply.github.com",
    }


def verify_github_token(token: str, opener=None) -> dict:
    """Exchange a GitHub bearer token for a normalized, stable identity."""
    if not token:
        raise IdentityError("GitHub bearer token required")
    req = urllib.request.Request(
        GITHUB_USER_URL,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "stwo-perf-backend/0.2",
        },
    )
    open_url = opener or urllib.request.urlopen
    try:
        with open_url(req, timeout=15) as resp:
            payload = json.loads(resp.read().decode())
    except (OSError, urllib.error.HTTPError, json.JSONDecodeError) as exc:
        raise IdentityError("GitHub token rejected") from exc
    return from_github_payload(payload)


def author_env(identity: dict, bot_name: str, bot_email: str) -> dict[str, str]:
    """Environment fragment for an explicitly selected author and committer."""
    return {
        "GIT_AUTHOR_NAME": str(identity["name"]),
        "GIT_AUTHOR_EMAIL": str(identity["noreply_email"]),
        "GIT_COMMITTER_NAME": bot_name,
        "GIT_COMMITTER_EMAIL": bot_email,
    }


def coauthor_trailer(identity: dict) -> str:
    return f"Co-authored-by: {identity['name']} <{identity['noreply_email']}>"
