"""HMAC-signed API keys bound to a GitHub identity.

Key format: ark_<base64url(payload)>.<base64url(hmac-sha256(payload, secret))>
Payload: {"login": ..., "issued_utc": ..., "key_id": ...}. Stateless verify;
revocation is a key_id denylist in the store.
"""

from __future__ import annotations

import base64
import datetime as dt
import hashlib
import hmac
import json
import secrets

PREFIX = "ark_"


class KeyError_(RuntimeError):
    pass


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def _unb64(text: str) -> bytes:
    pad = "=" * (-len(text) % 4)
    return base64.urlsafe_b64decode(text + pad)


def issue(login: str, secret: bytes) -> tuple[str, str]:
    """Returns (key, key_id)."""
    payload = {
        "login": login,
        "issued_utc": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "key_id": secrets.token_hex(8),
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
    payload = json.loads(raw)
    if revoked and payload.get("key_id") in revoked:
        raise KeyError_("key revoked")
    return payload
