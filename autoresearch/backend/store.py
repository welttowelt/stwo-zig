"""Atomic file-backed identities, API-key registry, and submission queue."""

from __future__ import annotations

import contextlib
import copy
import datetime as dt
import json
import os
import secrets
import threading
import uuid
from pathlib import Path

try:  # Unix judge/server hosts; retain a thread lock on other platforms.
    import fcntl
except ImportError:  # pragma: no cover - Windows is not a supported judge host.
    fcntl = None

SCHEMA_VERSION = 2
ACTIVE_STATES = {
    "received", "validating", "awaiting_coauthors", "queued", "judging",
    "promotable", "promoting", "promotion_error",
}
TERMINAL_STATES = {"promoted", "neutral", "rejected", "stale", "withdrawn"}
ALL_STATES = ACTIVE_STATES | TERMINAL_STATES
STATE_TRANSITIONS = {
    "received": frozenset({"validating", "withdrawn"}),
    "validating": frozenset({
        "awaiting_coauthors", "queued", "rejected", "withdrawn",
    }),
    "awaiting_coauthors": frozenset({"queued", "withdrawn"}),
    "queued": frozenset({"judging", "withdrawn"}),
    "judging": frozenset({"promotable", "neutral", "rejected", "stale"}),
    "promotable": frozenset({"promoting"}),
    "promoting": frozenset({"promoting", "promoted", "stale", "promotion_error"}),
    # Only an authenticated operator may perform this recovery via the admin
    # claim endpoint, after repairing the canonical checkout.
    "promotion_error": frozenset({"promotable"}),
    "promoted": frozenset(),
    "neutral": frozenset(),
    "rejected": frozenset(),
    "stale": frozenset(),
    "withdrawn": frozenset(),
}
_THREAD_LOCK = threading.RLock()


class StoreError(RuntimeError):
    pass


def _utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def require_transition(source: str, target: str) -> None:
    if source not in ALL_STATES or target not in ALL_STATES:
        raise StoreError(f"invalid submission transition: {source} -> {target}")
    if target not in STATE_TRANSITIONS[source]:
        raise StoreError(f"forbidden submission transition: {source} -> {target}")


class Store:
    """Small durable store suitable for one server plus local queue workers."""

    def __init__(self, path: Path):
        self.path = path
        self.lock_path = path.with_suffix(path.suffix + ".lock")

    @staticmethod
    def _empty() -> dict:
        return {
            "schema_version": SCHEMA_VERSION,
            "users": {},
            "keys": [],
            "revoked": [],
            "submissions": [],
        }

    def _load_unlocked(self) -> dict:
        if not self.path.exists():
            return self._empty()
        try:
            data = json.loads(self.path.read_text())
        except (OSError, json.JSONDecodeError) as exc:
            raise StoreError(f"cannot load backend store: {exc}") from exc
        # Transparently migrate the original {keys, revoked} v1 store.
        if "schema_version" not in data:
            data = {**self._empty(), **data}
        if data.get("schema_version") != SCHEMA_VERSION:
            raise StoreError(f"unsupported backend store schema: {data.get('schema_version')}")
        for key, default in self._empty().items():
            data.setdefault(key, copy.deepcopy(default))
        return data

    def _write_unlocked(self, data: dict) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_name(f".{self.path.name}.{os.getpid()}.tmp")
        tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, self.path)

    @contextlib.contextmanager
    def _locked(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with _THREAD_LOCK:
            fd = os.open(self.lock_path, os.O_CREAT | os.O_RDWR, 0o600)
            try:
                if fcntl is not None:
                    fcntl.flock(fd, fcntl.LOCK_EX)
                yield
            finally:
                if fcntl is not None:
                    fcntl.flock(fd, fcntl.LOCK_UN)
                os.close(fd)

    def _mutate(self, fn):
        with self._locked():
            data = self._load_unlocked()
            result = fn(data)
            self._write_unlocked(data)
            return result

    def snapshot(self) -> dict:
        with self._locked():
            return copy.deepcopy(self._load_unlocked())

    def record_identity(self, identity: dict) -> dict:
        normalized = copy.deepcopy(identity)

        def mutate(data):
            key = str(normalized["github_id"])
            previous = data["users"].get(key, {})
            data["users"][key] = {
                **previous,
                **normalized,
                "verified_utc": _utc_now(),
            }
            return copy.deepcopy(data["users"][key])

        return self._mutate(mutate)

    def record_key(self, identity: dict, key_id: str, scopes: list[str]) -> None:
        def mutate(data):
            data["keys"].append({
                "github_id": identity["github_id"],
                "login": identity["login"],
                "key_id": key_id,
                "scopes": list(scopes),
                "issued_utc": _utc_now(),
            })

        self._mutate(mutate)

    def revoked(self) -> set[str]:
        return set(self.snapshot().get("revoked", []))

    def revoke_key(self, key_id: str) -> None:
        def mutate(data):
            known = any(item.get("key_id") == key_id for item in data["keys"])
            if not known:
                raise StoreError("API key is not registered")
            if key_id not in data["revoked"]:
                data["revoked"].append(key_id)

        self._mutate(mutate)

    def create_submission(self, record: dict, max_active_per_user: int = 1) -> dict:
        def mutate(data):
            author_id = int(record["author"]["github_id"])
            active = [
                item for item in data["submissions"]
                if int(item["author"]["github_id"]) == author_id
                and item["state"] in ACTIVE_STATES
            ]
            if len(active) >= max_active_per_user:
                raise StoreError(
                    f"user already has {len(active)} active submission(s); "
                    f"limit is {max_active_per_user}"
                )
            source_commit = record["source"]["commit"]
            if any(item["source"]["commit"] == source_commit for item in data["submissions"]):
                raise StoreError("candidate commit was already submitted")
            candidate_tree = (
                record.get("qualification", {}).get("receipt", {}).get("candidate_tree")
            )
            if candidate_tree and any(
                item.get("qualification", {}).get("receipt", {}).get("candidate_tree")
                == candidate_tree
                for item in data["submissions"]
            ):
                raise StoreError("candidate tree was already submitted")
            now = _utc_now()
            item = {
                **copy.deepcopy(record),
                "id": record.get("id") or str(uuid.uuid4()),
                "state": "received",
                "created_utc": now,
                "updated_utc": now,
                "state_history": [{"state": "received", "at": now, "detail": "accepted by API"}],
            }
            data["submissions"].append(item)
            return copy.deepcopy(item)

        return self._mutate(mutate)

    def get_submission(self, submission_id: str) -> dict | None:
        for item in self.snapshot()["submissions"]:
            if item["id"] == submission_id:
                return item
        return None

    def submissions_for(self, github_id: int, login: str | None = None) -> list[dict]:
        return [
            item for item in self.snapshot()["submissions"]
            if int(item["author"]["github_id"]) == int(github_id)
            or any(
                int(co.get("identity", {}).get("github_id", -1)) == int(github_id)
                or bool(login and co.get("login", "").casefold() == login.casefold())
                for co in item.get("coauthors", [])
            )
        ]

    def transition(self, submission_id: str, expected: set[str], state: str,
                   detail: str, fields: dict | None = None) -> dict:
        if state not in ALL_STATES:
            raise StoreError(f"invalid submission state: {state}")

        def mutate(data):
            item = next((s for s in data["submissions"] if s["id"] == submission_id), None)
            if item is None:
                raise StoreError("submission not found")
            if item["state"] not in expected:
                raise StoreError(
                    f"submission is {item['state']}; expected one of {sorted(expected)}"
                )
            now = _utc_now()
            actual_state = state
            actual_detail = detail
            if (state == "awaiting_coauthors"
                    and all(co["status"] == "accepted" for co in item.get("coauthors", []))):
                actual_state = "queued"
                actual_detail = "source verified and all requested co-authors accepted"
            require_transition(item["state"], actual_state)
            item["state"] = actual_state
            item["updated_utc"] = now
            item["state_history"].append({
                "state": actual_state, "at": now, "detail": actual_detail,
            })
            if fields:
                item.update(copy.deepcopy(fields))
            return copy.deepcopy(item)

        return self._mutate(mutate)

    def claim_next(self, source_states: set[str], claimed_state: str,
                   detail: str) -> dict | None:
        if not source_states or not source_states.issubset(ALL_STATES):
            raise StoreError("worker source states are invalid")
        if claimed_state not in ALL_STATES:
            raise StoreError("worker claimed state is invalid")
        for source_state in source_states:
            require_transition(source_state, claimed_state)

        def mutate(data):
            candidates = [s for s in data["submissions"] if s["state"] in source_states]
            if not candidates:
                return None
            item = sorted(candidates, key=lambda s: (s["created_utc"], s["id"]))[0]
            now = _utc_now()
            item["state"] = claimed_state
            item["updated_utc"] = now
            item["state_history"].append({"state": claimed_state, "at": now, "detail": detail})
            return copy.deepcopy(item)

        return self._mutate(mutate)

    def accept_coauthor(self, submission_id: str, identity: dict) -> dict:
        def mutate(data):
            item = next((s for s in data["submissions"] if s["id"] == submission_id), None)
            if item is None:
                raise StoreError("submission not found")
            if item["state"] not in {"received", "validating", "awaiting_coauthors"}:
                raise StoreError("attribution is frozen once a submission enters the judge queue")
            requested = next(
                (co for co in item.get("coauthors", [])
                 if co["login"].casefold() == identity["login"].casefold()),
                None,
            )
            if requested is None:
                raise StoreError("this GitHub login was not requested as a co-author")
            requested["status"] = "accepted"
            requested["identity"] = copy.deepcopy(identity)
            requested["accepted_utc"] = _utc_now()
            now = _utc_now()
            item["updated_utc"] = now
            if (item["state"] == "awaiting_coauthors"
                    and all(co["status"] == "accepted" for co in item.get("coauthors", []))):
                require_transition(item["state"], "queued")
                item["state"] = "queued"
                item["state_history"].append({
                    "state": "queued", "at": now,
                    "detail": "all requested co-authors accepted",
                })
            return copy.deepcopy(item)

        return self._mutate(mutate)
