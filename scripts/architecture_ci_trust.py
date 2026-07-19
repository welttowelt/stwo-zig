#!/usr/bin/env python3
"""Validate protected GitHub Actions authority before architecture evidence runs."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Mapping


ROOT = Path(__file__).resolve().parents[1]
PROTOCOL = ROOT / "conformance/build-architecture-receipt-protocol-v1.json"
HEX40 = re.compile(r"^[0-9a-f]{40}$")
DECIMAL = re.compile(r"^[1-9][0-9]*$")


class TrustError(ValueError):
    """The workflow run is outside the architecture receipt trust boundary."""


def _strict_json(path: Path) -> object:
    def reject(pairs: list[tuple[str, object]]) -> dict[str, object]:
        result = {}
        for key, value in pairs:
            if key in result:
                raise TrustError(f"duplicate JSON key: {key}")
            result[key] = value
        return result

    return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=reject)


def _git(*arguments: str) -> bytes:
    completed = subprocess.run(
        ("git", *arguments), cwd=ROOT, check=False, capture_output=True,
    )
    if completed.returncode != 0:
        raise TrustError(f"git {' '.join(arguments)} failed")
    return completed.stdout


def validate(
    metadata: object,
    expected_job: str,
    environment: Mapping[str, str] | None = None,
) -> dict[str, str]:
    env = os.environ if environment is None else environment
    protocol = _strict_json(PROTOCOL)
    if not isinstance(protocol, dict) or not isinstance(metadata, dict):
        raise TrustError("trust inputs are malformed")
    trust = protocol["trust"]
    expected = {
        "GITHUB_ACTIONS": "true",
        "GITHUB_REPOSITORY": trust["repository"],
        "GITHUB_REPOSITORY_ID": str(trust["repository_id"]),
        "GITHUB_REPOSITORY_OWNER_ID": str(trust["repository_owner_id"]),
        "GITHUB_WORKFLOW_REF": trust["workflow_ref"],
        "GITHUB_REF": "refs/heads/main",
        "GITHUB_JOB": expected_job,
    }
    for name, value in expected.items():
        if env.get(name) != value:
            raise TrustError(f"trusted workflow environment mismatch: {name}")
    workflow_sha = env.get("GITHUB_WORKFLOW_SHA", "")
    source_sha = env.get("GITHUB_SHA", "")
    if HEX40.fullmatch(workflow_sha) is None or source_sha != workflow_sha:
        raise TrustError("workflow and candidate must be the same canonical main commit")
    run_id = env.get("GITHUB_RUN_ID", "")
    run_attempt = env.get("GITHUB_RUN_ATTEMPT", "")
    if DECIMAL.fullmatch(run_id) is None or DECIMAL.fullmatch(run_attempt) is None:
        raise TrustError("workflow run identity is not canonical")

    event = env.get("GITHUB_EVENT_NAME")
    if event not in {"push", "workflow_dispatch"}:
        raise TrustError("architecture receipts reject pull requests and untrusted events")
    required_metadata = {
        "id": int(run_id),
        "run_attempt": int(run_attempt),
        "event": event,
        "head_branch": "main",
        "head_sha": workflow_sha,
        "path": trust["workflow_path"],
    }
    for field, value in required_metadata.items():
        if metadata.get(field) != value:
            raise TrustError(f"workflow API metadata mismatch: {field}")
    repository = metadata.get("repository")
    if not isinstance(repository, dict) or repository.get("id") != trust["repository_id"]:
        raise TrustError("workflow API repository identity mismatch")
    if event == "workflow_dispatch":
        for field in ("actor", "triggering_actor"):
            actor = metadata.get(field)
            if not isinstance(actor, dict) or actor.get("id") != trust["repository_owner_id"]:
                raise TrustError(f"owner-authenticated dispatch mismatch: {field}")

    head = _git("rev-parse", "HEAD").decode().strip()
    if head != source_sha or _git("status", "--porcelain", "--untracked-files=all"):
        raise TrustError("architecture evidence requires the clean workflow commit")
    workflow_path = trust["workflow_path"]
    checked_out = (ROOT / workflow_path).read_bytes()
    committed = _git("show", f"{workflow_sha}:{workflow_path}")
    if checked_out != committed:
        raise TrustError("workflow definition bytes differ from GITHUB_WORKFLOW_SHA")
    return {
        "commit": source_sha,
        "tree": _git("rev-parse", "HEAD^{tree}").decode().strip(),
        "workflow_sha256": hashlib.sha256(checked_out).hexdigest(),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-metadata", type=Path, required=True)
    parser.add_argument("--expected-job", required=True)
    args = parser.parse_args(argv)
    try:
        result = validate(_strict_json(args.run_metadata), args.expected_job)
    except (TrustError, OSError, UnicodeError, json.JSONDecodeError) as error:
        print(f"architecture CI trust: FAIL: {error}", file=sys.stderr)
        return 2
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
