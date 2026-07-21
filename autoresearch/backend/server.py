#!/usr/bin/env python3
"""stwo-perf backend: GitHub identities, CLI keys, intake queue, and ledger views.

The repository remains the source of truth for harness policy and promoted
history. This server stores only verified GitHub identities, revocable scoped
API keys, remote-submission queue state, and judge receipts awaiting promotion.

Run: STWO_PERF_HMAC_SECRET=<hex> GITHUB_CLIENT_ID=<id> \
     python3 autoresearch/backend/server.py --repo /path/to/stwo-zig --port 8787

Stdlib only. Bind to localhost and front with authenticated TLS in production.
Candidate source is never executed by this HTTP process; intake and judge workers
consume the durable queue in separate sandboxed processes.
"""

from __future__ import annotations

import argparse
import hmac
import json
import os
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "cli"))

import apikeys  # noqa: E402
import identity as identity_mod  # noqa: E402
import submissions as submissions_mod  # noqa: E402
from store import Store, StoreError  # noqa: E402
from stwo_perf import frontier, ledger, manifest as manifest_mod, qualification  # noqa: E402

MAX_BODY_BYTES = 1024 * 1024


def make_handler(repo: Path, secret: bytes, store: Store, client_id: str | None,
                 identity_resolver=None, max_active_per_user: int = 1,
                 admin_token: str | None = None):
    resolve_identity = identity_resolver or identity_mod.verify_github_token

    class Handler(BaseHTTPRequestHandler):
        server_version = "stwo-perf-backend/0.2"

        def _json(self, code: int, body: dict | list) -> None:
            data = json.dumps(body, separators=(",", ":")).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def _body(self) -> dict:
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError as exc:
                raise submissions_mod.SubmissionError("invalid Content-Length") from exc
            if length < 0 or length > MAX_BODY_BYTES:
                raise submissions_mod.SubmissionError("request body too large")
            try:
                body = json.loads(self.rfile.read(length) or b"{}")
            except json.JSONDecodeError as exc:
                raise submissions_mod.SubmissionError("request body is not valid JSON") from exc
            if not isinstance(body, dict):
                raise submissions_mod.SubmissionError("request body must be a JSON object")
            return body

        def _api_payload(self, scope: str) -> dict | None:
            auth = self.headers.get("Authorization", "")
            if not auth.startswith("Bearer "):
                self._json(401, {"error": "stwo-perf API key required"})
                return None
            try:
                payload = apikeys.verify(
                    auth.removeprefix("Bearer ").strip(), secret, store.revoked()
                )
                apikeys.require_scope(payload, scope)
                if not isinstance(payload.get("github_id"), int):
                    raise apikeys.KeyError_("legacy API key cannot mutate submissions; reissue it")
            except apikeys.KeyError_ as exc:
                self._json(401, {"error": str(exc)})
                return None
            return payload

        def _identity_for_payload(self, payload: dict) -> dict | None:
            user = store.snapshot()["users"].get(str(payload["github_id"]))
            if user is None:
                self._json(401, {"error": "API-key identity is no longer registered"})
                return None
            return user

        def _admin_ok(self) -> bool:
            supplied = self.headers.get("X-Stwo-Admin-Token", "")
            return bool(admin_token and hmac.compare_digest(supplied, admin_token))

        def log_message(self, fmt, *args):
            # Avoid recording bearer tokens, query values, or client addresses.
            sys.stderr.write(f"[backend] {fmt % args}\n")

        def do_GET(self):  # noqa: N802
            path = urllib.parse.urlsplit(self.path).path.rstrip("/") or "/"
            if path == "/v1/health":
                return self._json(200, {"ok": True, "queue_schema_version": 2})
            if path == "/v1/client-id":
                if not client_id:
                    return self._json(404, {"error": "client id not configured"})
                return self._json(200, {"github_client_id": client_id})
            if path == "/v1/feed":
                # Same contract as the committed autoresearch/site/feed.json
                # (schema/site-feed.md): one document, two transports. Consumers
                # key their caches on provenance.inputs_sha256 either way.
                feed_path = repo / "autoresearch" / "site" / "feed.json"
                try:
                    document = json.loads(feed_path.read_text(encoding="utf-8"))
                except (OSError, json.JSONDecodeError) as exc:
                    return self._json(500, {"error": f"feed unavailable: {exc}"})
                return self._json(200, document)
            if path == "/v1/leaderboard":
                try:
                    rows = ledger.load(repo)
                except (OSError, ledger.LedgerError) as exc:
                    return self._json(500, {"error": str(exc)})
                return self._json(200, {"rows": [row.values for row in rows]})
            if path.startswith("/v1/frontier/"):
                parts = path.strip("/").split("/")
                if len(parts) != 4:
                    return self._json(400, {
                        "error": "frontier path must be /v1/frontier/<board>/<class>"
                    })
                board, cls = parts[2], parts[3]
                if board not in ledger.BOARDS:
                    return self._json(400, {"error": f"unknown board: {board}"})
                try:
                    manifest = manifest_mod.load(repo)
                    manifest.validate_workload_class(
                        cls, board=board, include_disabled=True,
                    )
                    rows = ledger.load(repo)
                except manifest_mod.ManifestError as exc:
                    return self._json(400, {"error": str(exc)})
                except (OSError, ledger.LedgerError) as exc:
                    return self._json(500, {"error": str(exc)})
                view = frontier.view(rows, board, cls)
                return self._json(200, {
                    "board": board,
                    "class": cls,
                    "repository_frontier_commit": _repo_head(repo),
                    "frontier": [row.values for row in view.frontier],
                    "head": view.head.values if view.head else None,
                })
            if path == "/v1/me":
                payload = self._api_payload("identity:read")
                if payload is None:
                    return None
                user = self._identity_for_payload(payload)
                return None if user is None else self._json(200, {"identity": user})
            if path == "/v1/submissions":
                payload = self._api_payload("submissions:read")
                if payload is None:
                    return None
                user = self._identity_for_payload(payload)
                if user is None:
                    return None
                records = store.submissions_for(payload["github_id"], user["login"])
                return self._json(200, {
                    "submissions": [submissions_mod.public_record(item) for item in records]
                })
            if path.startswith("/v1/submissions/"):
                payload = self._api_payload("submissions:read")
                if payload is None:
                    return None
                submission_id = path.split("/")[-1]
                item = store.get_submission(submission_id)
                if item is None:
                    return self._json(404, {"error": "submission not found"})
                user = self._identity_for_payload(payload)
                if user is None:
                    return None
                visible = any(
                    int(identity.get("github_id", -1)) == int(payload["github_id"])
                    for identity in [item["author"], *[
                        co.get("identity", {}) for co in item.get("coauthors", [])
                    ]]
                )
                visible = visible or any(
                    co.get("login", "").casefold() == user["login"].casefold()
                    for co in item.get("coauthors", [])
                )
                if not visible:
                    return self._json(403, {"error": "submission belongs to another user"})
                return self._json(200, {"submission": submissions_mod.public_record(item)})
            return self._json(404, {"error": "not found"})

        def do_POST(self):  # noqa: N802
            path = urllib.parse.urlsplit(self.path).path.rstrip("/")
            try:
                body = self._body()
            except submissions_mod.SubmissionError as exc:
                return self._json(400, {"error": str(exc)})

            if path in ("/v1/auth/github/keys", "/v1/keys"):
                auth = self.headers.get("Authorization", "")
                if not auth.startswith("Bearer "):
                    return self._json(401, {"error": "GitHub bearer token required"})
                try:
                    verified = resolve_identity(auth.removeprefix("Bearer ").strip())
                except identity_mod.IdentityError as exc:
                    return self._json(401, {"error": str(exc)})
                registered = store.record_identity(verified)
                key, key_id = apikeys.issue(registered, secret)
                scopes = list(apikeys.DEFAULT_SCOPES)
                store.record_key(registered, key_id, scopes)
                return self._json(200, {
                    "identity": registered,
                    "login": registered["login"],
                    "key": key,
                    "key_id": key_id,
                    "scopes": scopes,
                })
            if path == "/v1/keys/verify":
                try:
                    payload = apikeys.verify(body.get("key", ""), secret, store.revoked())
                except apikeys.KeyError_ as exc:
                    return self._json(401, {"error": str(exc)})
                return self._json(200, {"valid": True, **payload})
            if path == "/v1/keys/revoke":
                payload = self._api_payload("identity:read")
                if payload is None:
                    return None
                try:
                    store.revoke_key(payload["key_id"])
                except StoreError as exc:
                    return self._json(400, {"error": str(exc)})
                return self._json(200, {"revoked": True, "key_id": payload["key_id"]})
            if path == "/v1/submissions":
                payload = self._api_payload("submissions:write")
                if payload is None:
                    return None
                author = self._identity_for_payload(payload)
                if author is None:
                    return None
                try:
                    manifest = manifest_mod.load(repo)
                    qualification.validate_receipt(
                        body.get("qualification", {}).get("receipt", {}), manifest,
                    )
                    if (manifest.qualification_policy.get(
                            "require_github_artifact_attestation", False)
                            and not body.get("qualification", {}).get("attestation")):
                        raise submissions_mod.SubmissionError(
                            "a GitHub artifact attestation is required by current policy"
                        )
                    runnable = {
                        group.board: set(manifest.class_names(
                            board=group.board, scored_only=True,
                        ))
                        for group in manifest.groups() if group.enabled
                    }
                    record = submissions_mod.validate_request(body, author, runnable)
                    created = store.create_submission(record, max_active_per_user)
                except (qualification.QualificationError, submissions_mod.SubmissionError,
                        manifest_mod.ManifestError, StoreError) as exc:
                    return self._json(400, {"error": str(exc)})
                return self._json(201, {"submission": submissions_mod.public_record(created)})
            if path.startswith("/v1/submissions/") and path.endswith("/coauthors/accept"):
                payload = self._api_payload("submissions:write")
                if payload is None:
                    return None
                user = self._identity_for_payload(payload)
                if user is None:
                    return None
                submission_id = path.split("/")[-3]
                try:
                    item = store.accept_coauthor(submission_id, user)
                except StoreError as exc:
                    return self._json(400, {"error": str(exc)})
                return self._json(200, {"submission": submissions_mod.public_record(item)})
            if path.startswith("/v1/submissions/") and path.endswith("/withdraw"):
                payload = self._api_payload("submissions:write")
                if payload is None:
                    return None
                submission_id = path.split("/")[-2]
                item = store.get_submission(submission_id)
                if item is None:
                    return self._json(404, {"error": "submission not found"})
                if int(item["author"]["github_id"]) != int(payload["github_id"]):
                    return self._json(403, {"error": "only the author may withdraw"})
                try:
                    updated = store.transition(
                        submission_id,
                        {"received", "validating", "awaiting_coauthors", "queued"},
                        "withdrawn", "withdrawn by author",
                    )
                except StoreError as exc:
                    return self._json(400, {"error": str(exc)})
                return self._json(200, {"submission": submissions_mod.public_record(updated)})
            if path == "/v1/admin/submissions/claim":
                if not self._admin_ok():
                    return self._json(401, {"error": "admin token required"})
                source_states = set(body.get("states", []))
                claimed_state = body.get("claimed_state")
                if not source_states or not isinstance(claimed_state, str):
                    return self._json(400, {"error": "states and claimed_state are required"})
                try:
                    item = store.claim_next(source_states, claimed_state, "claimed by worker API")
                except StoreError as exc:
                    return self._json(400, {"error": str(exc)})
                return self._json(200, {"submission": item})
            return self._json(404, {"error": "not found"})

    return Handler


def _repo_head(repo: Path) -> str | None:
    import subprocess
    proc = subprocess.run(
        ["git", "rev-parse", "HEAD^{commit}"], cwd=repo,
        capture_output=True, text=True,
    )
    return proc.stdout.strip() if proc.returncode == 0 else None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, help="path to a stwo-zig checkout")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--store", default="backend-store.json")
    parser.add_argument("--max-active-per-user", type=int,
                        help="override MANIFEST qualification policy")
    args = parser.parse_args()

    secret_hex = os.environ.get("STWO_PERF_HMAC_SECRET")
    if not secret_hex:
        print("STWO_PERF_HMAC_SECRET is required (hex)", file=sys.stderr)
        return 1
    try:
        secret = bytes.fromhex(secret_hex)
    except ValueError:
        print("STWO_PERF_HMAC_SECRET must be valid hex", file=sys.stderr)
        return 1
    if len(secret) < 32:
        print("STWO_PERF_HMAC_SECRET must decode to at least 32 bytes", file=sys.stderr)
        return 1
    client_id = os.environ.get("GITHUB_CLIENT_ID")
    admin_token = os.environ.get("STWO_PERF_ADMIN_TOKEN")
    repo = Path(args.repo).resolve()
    store = Store(Path(args.store).resolve())
    try:
        policy_limit = int(manifest_mod.load(repo).qualification_policy["max_active_per_user"])
    except (manifest_mod.ManifestError, KeyError, TypeError, ValueError) as exc:
        print(f"cannot load qualification policy: {exc}", file=sys.stderr)
        return 1
    active_limit = args.max_active_per_user or policy_limit
    if active_limit < 1:
        print("--max-active-per-user must be positive", file=sys.stderr)
        return 1

    server = ThreadingHTTPServer(
        ("127.0.0.1", args.port),
        make_handler(
            repo, secret, store, client_id,
            max_active_per_user=active_limit,
            admin_token=admin_token,
        ),
    )
    print(f"stwo-perf backend on 127.0.0.1:{args.port} (repo: {repo})")
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
