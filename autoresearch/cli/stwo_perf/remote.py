"""Authenticated client for the autoresearch intake API."""

from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request


class RemoteError(RuntimeError):
    pass


def request(api_url: str, path: str, api_key: str | None = None,
            method: str = "GET", body: dict | None = None,
            bearer_token: str | None = None) -> dict:
    """Send one JSON request and surface the backend's useful error text."""
    if api_key and bearer_token:
        raise RemoteError("choose an API key or a GitHub token, not both")
    parsed = urllib.parse.urlsplit(api_url)
    loopback = parsed.hostname in {"localhost", "127.0.0.1", "::1"}
    if parsed.scheme != "https" and not (parsed.scheme == "http" and loopback):
        raise RemoteError("API URL must use HTTPS (plain HTTP is allowed only on loopback)")
    headers = {"Accept": "application/json"}
    credential = api_key or bearer_token
    if credential:
        headers["Authorization"] = f"Bearer {credential}"
    data = None
    if body is not None:
        data = json.dumps(body, separators=(",", ":")).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(
        f"{api_url.rstrip('/')}/{path.lstrip('/')}", data=data,
        headers=headers, method=method,
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            payload = json.loads(response.read().decode())
    except urllib.error.HTTPError as exc:
        try:
            payload = json.loads(exc.read().decode())
            detail = payload.get("error", str(exc))
        except (json.JSONDecodeError, AttributeError):
            detail = str(exc)
        raise RemoteError(detail) from exc
    except (OSError, json.JSONDecodeError) as exc:
        raise RemoteError(f"backend request failed: {exc}") from exc
    if not isinstance(payload, dict):
        raise RemoteError("backend returned a non-object JSON response")
    return payload


def issue_key(api_url: str, github_token: str) -> dict:
    return request(
        api_url, "/v1/auth/github/keys", method="POST", body={},
        bearer_token=github_token,
    )


def revoke_key(api_url: str, api_key: str) -> dict:
    return request(api_url, "/v1/keys/revoke", api_key=api_key,
                   method="POST", body={})


def me(api_url: str, api_key: str) -> dict:
    return request(api_url, "/v1/me", api_key=api_key)


def frontier(api_url: str, board: str, workload_class: str) -> dict:
    return request(api_url, f"/v1/frontier/{board}/{workload_class}")


def submit(api_url: str, api_key: str, payload: dict) -> dict:
    return request(api_url, "/v1/submissions", api_key=api_key,
                   method="POST", body=payload)


def submissions(api_url: str, api_key: str,
                submission_id: str | None = None) -> dict:
    suffix = f"/{submission_id}" if submission_id else ""
    return request(api_url, f"/v1/submissions{suffix}", api_key=api_key)


def accept_coauthor(api_url: str, api_key: str, submission_id: str) -> dict:
    return request(
        api_url, f"/v1/submissions/{submission_id}/coauthors/accept",
        api_key=api_key, method="POST", body={},
    )


def withdraw(api_url: str, api_key: str, submission_id: str) -> dict:
    return request(
        api_url, f"/v1/submissions/{submission_id}/withdraw",
        api_key=api_key, method="POST", body={},
    )
