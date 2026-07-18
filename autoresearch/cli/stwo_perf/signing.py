"""Judge verdict signing: HMAC-SHA256 over canonical JSON.

The judge runner holds JUDGE_HMAC_SECRET (a GitHub Actions secret available
only to judge/promote workflows). A searcher cannot mint a valid signature,
so a judged verdict is trusted iff its signature verifies — regardless of
where the file was found.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import os

SIGNATURE_KEY = "judge_signature"


class SigningError(RuntimeError):
    pass


def _secret() -> bytes:
    value = os.environ.get("JUDGE_HMAC_SECRET")
    if not value:
        raise SigningError("JUDGE_HMAC_SECRET is not set")
    return value.encode()


def canonical_payload(verdict: dict) -> bytes:
    body = {k: v for k, v in verdict.items() if k != SIGNATURE_KEY}
    return json.dumps(body, separators=(",", ":"), sort_keys=True).encode()


def sign(verdict: dict) -> dict:
    signature = hmac.new(_secret(), canonical_payload(verdict), hashlib.sha256).hexdigest()
    return {**verdict, SIGNATURE_KEY: signature}


def verify(verdict: dict) -> None:
    """Raises SigningError unless the verdict carries a valid judge signature."""
    signature = verdict.get(SIGNATURE_KEY)
    if not signature:
        raise SigningError("verdict has no judge signature")
    expected = hmac.new(_secret(), canonical_payload(verdict), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(signature, expected):
        raise SigningError("judge signature verification failed")
