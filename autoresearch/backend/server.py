#!/usr/bin/env python3
"""stwo-perf backend: GitHub-verified API keys and read-only ledger views.

Deliberately thin — the git repository is the source of truth for submissions,
notes, and promotions. The backend only (1) verifies a GitHub identity and
issues HMAC API keys for bots/CI, (2) serves leaderboard/frontier JSON parsed
from a local checkout, and (3) proxies the device-flow client id so the CLI
does not embed one.

Run: STWO_PERF_HMAC_SECRET=<hex> GITHUB_CLIENT_ID=<id> \
     python3 autoresearch/backend/server.py --repo /path/to/stwo-zig --port 8787

Stdlib only. Front with a TLS-terminating proxy in real deployments.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import threading
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "cli"))

import apikeys  # noqa: E402
from stwo_perf import frontier, ledger  # noqa: E402

STORE_LOCK = threading.Lock()


class Store:
    """File-backed key registry + revocations."""

    def __init__(self, path: Path):
        self.path = path

    def _load_unlocked(self) -> dict:
        if not self.path.exists():
            return {"keys": [], "revoked": []}
        return json.loads(self.path.read_text())

    def record_key(self, login: str, key_id: str) -> None:
        with STORE_LOCK:
            data = self._load_unlocked()
            data["keys"].append({"login": login, "key_id": key_id})
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_suffix(".tmp")
            tmp.write_text(json.dumps(data, indent=2))
            os.replace(tmp, self.path)  # atomic: readers never see a torn file

    def revoked(self) -> set[str]:
        with STORE_LOCK:
            return set(self._load_unlocked().get("revoked", []))


def github_login(token: str) -> str | None:
    req = urllib.request.Request(
        "https://api.github.com/user",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read().decode()).get("login")
    except OSError:
        return None


def make_handler(repo: Path, secret: bytes, store: Store, client_id: str | None):
    class Handler(BaseHTTPRequestHandler):
        server_version = "stwo-perf-backend/0.1"

        def _json(self, code: int, body: dict) -> None:
            data = json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, fmt, *args):  # quieter logs, no client addresses
            sys.stderr.write(f"[backend] {fmt % args}\n")

        def do_GET(self):  # noqa: N802
            import urllib.parse
            path = urllib.parse.urlsplit(self.path).path
            if path == "/v1/health":
                return self._json(200, {"ok": True})
            if path == "/v1/client-id":
                if not client_id:
                    return self._json(404, {"error": "client id not configured"})
                return self._json(200, {"github_client_id": client_id})
            if path == "/v1/leaderboard":
                try:
                    rows = ledger.load(repo)
                except (OSError, ledger.LedgerError) as exc:
                    return self._json(500, {"error": str(exc)})
                return self._json(200, {"rows": [r.values for r in rows]})
            if path.startswith("/v1/frontier/"):
                parts = path.strip("/").split("/")
                if len(parts) != 4:
                    return self._json(400, {
                        "error": "frontier path must be /v1/frontier/<board>/<class>"
                    })
                board, cls = parts[2], parts[3]
                if board not in ledger.BOARDS:
                    return self._json(400, {"error": f"unknown board: {board}"})
                if cls not in ("small", "wide", "deep"):
                    return self._json(400, {"error": "class must be small|wide|deep"})
                try:
                    rows = ledger.load(repo)
                except (OSError, ledger.LedgerError) as exc:
                    return self._json(500, {"error": str(exc)})
                v = frontier.view(rows, board, cls)
                return self._json(200, {
                    "board": board,
                    "class": cls,
                    "frontier": [r.values for r in v.frontier],
                    "head": v.head.values if v.head else None,
                })
            return self._json(404, {"error": "not found"})

        def do_POST(self):  # noqa: N802
            if self.path == "/v1/keys":
                auth = self.headers.get("Authorization", "")
                if not auth.startswith("Bearer "):
                    return self._json(401, {"error": "GitHub bearer token required"})
                login = github_login(auth.removeprefix("Bearer ").strip())
                if not login:
                    return self._json(401, {"error": "GitHub token rejected"})
                key, key_id = apikeys.issue(login, secret)
                store.record_key(login, key_id)
                return self._json(200, {"login": login, "key": key, "key_id": key_id})
            if self.path == "/v1/keys/verify":
                length = int(self.headers.get("Content-Length", "0"))
                body = json.loads(self.rfile.read(length) or b"{}")
                try:
                    payload = apikeys.verify(body.get("key", ""), secret, store.revoked())
                except apikeys.KeyError_ as exc:
                    return self._json(401, {"error": str(exc)})
                return self._json(200, {"valid": True, **payload})
            return self._json(404, {"error": "not found"})

    return Handler


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, help="path to a stwo-zig checkout")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--store", default="backend-store.json")
    args = parser.parse_args()

    secret_hex = os.environ.get("STWO_PERF_HMAC_SECRET")
    if not secret_hex:
        print("STWO_PERF_HMAC_SECRET is required (hex)", file=sys.stderr)
        return 1
    secret = bytes.fromhex(secret_hex)
    client_id = os.environ.get("GITHUB_CLIENT_ID")
    repo = Path(args.repo).resolve()
    store = Store(Path(args.store).resolve())

    server = ThreadingHTTPServer(
        ("127.0.0.1", args.port), make_handler(repo, secret, store, client_id)
    )
    print(f"stwo-perf backend on 127.0.0.1:{args.port} (repo: {repo})")
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
