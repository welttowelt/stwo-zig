"""HMAC-signed CLI/API keys bound to a verified GitHub identity.

Key format: ark_<base64url(payload)>.<base64url(hmac-sha256(payload, secret))>
Payload v2 includes the stable numeric GitHub id, login snapshot, scopes,
issuance time, and key id. Verification is stateless except for the key-id
revocation denylist in the store.
"""

from __future__ import annotations

import base64
import datetime as dt
import hashlib
import hmac
import json
import secrets

PREFIX = "ark_"
DEFAULT_SCOPES = ("identity:read", "submissions:read", "submissions:write")


class KeyError_(RuntimeError):
    pass


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def _unb64(text: str) -> bytes:
    pad = "=" * (-len(text) % 4)
    return base64.urlsafe_b64decode(text + pad)


def issue(identity: dict | str, secret: bytes,
          scopes: tuple[str, ...] | list[str] = DEFAULT_SCOPES) -> tuple[str, str]:
    """Returns (key, key_id)."""
    # Accept a login string for v1 callers/tests while all server-issued keys
    # use the stable GitHub identity object.
    if isinstance(identity, str):
        login = identity
        github_id = None
    else:
        login = str(identity["login"])
        github_id = int(identity["github_id"])
    payload = {
        "schema_version": 2,
        "github_id": github_id,
        "login": login,
        "issued_utc": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "key_id": secrets.token_hex(8),
        "scopes": sorted(set(scopes)),
    }
    raw = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode()
    sig = hmac.new(secret, raw, hashlib.sha256).digest()
    return f"{PREFIX}{_b64(raw)}.{_b64(sig)}", payload["key_id"]


def verify(key: str, secret: bytes, revoked: set[str] | None = None) -> dict:
    """Returns the payload or raises KeyError_."""
    if not key.startswith(PREFIX) or "." not in key:
        raise KeyError_("malformed key")
    body, _, sig_text = key[len(PREFIX):].partition(".")
    try:
        raw = _unb64(body)
        sig = _unb64(sig_text)
    except Exception as exc:  # noqa: BLE001 - any decode failure is invalid
        raise KeyError_("malformed key encoding") from exc
    expected = hmac.new(secret, raw, hashlib.sha256).digest()
    if not hmac.compare_digest(sig, expected):
        raise KeyError_("bad signature")
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise KeyError_("malformed key payload") from exc
    if not isinstance(payload, dict) or not isinstance(payload.get("login"), str):
        raise KeyError_("malformed key payload")
    if revoked and payload.get("key_id") in revoked:
        raise KeyError_("key revoked")
    # Original v1 keys remain usable for read-only compatibility but cannot
    # authenticate identity-bearing submission mutations.
    payload.setdefault("schema_version", 1)
    payload.setdefault("scopes", ["identity:read"])
    return payload


def require_scope(payload: dict, scope: str) -> None:
    if scope not in payload.get("scopes", []):
        raise KeyError_(f"API key lacks required scope: {scope}")
