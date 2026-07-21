#!/usr/bin/env python3
"""Capture authenticated GitHub ruleset evidence for BA-03 activation."""

from __future__ import annotations

import argparse
import json
import os
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

from autoresearch_activation_lib.github import (
    SettingsCaptureError,
    build_settings_receipt,
)


API = "https://api.github.com"


def _api(path: str, token: str) -> object:
    request = urllib.request.Request(
        f"{API}{path}",
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "User-Agent": "stwo-zig-autoresearch-activation",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except (urllib.error.URLError, json.JSONDecodeError) as error:
        raise SettingsCaptureError(f"GitHub API request failed for {path}: {error}") from error


def _atomic_write(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    encoded = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", default="teddyjfpender/stwo-zig")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not token:
        parser.error("GH_TOKEN or GITHUB_TOKEN is required")

    repository = _api(f"/repos/{args.repository}", token)
    summaries = _api(f"/repos/{args.repository}/rulesets?per_page=100", token)
    if not isinstance(repository, dict) or not isinstance(summaries, list):
        raise SettingsCaptureError("GitHub API returned an unexpected response shape")
    rulesets = []
    for summary in summaries:
        ruleset_id = summary.get("id") if isinstance(summary, dict) else None
        if type(ruleset_id) is not int:
            raise SettingsCaptureError("GitHub ruleset summary has no numeric ID")
        detail = _api(f"/repos/{args.repository}/rulesets/{ruleset_id}", token)
        if not isinstance(detail, dict):
            raise SettingsCaptureError("GitHub ruleset detail is not an object")
        rulesets.append(detail)

    receipt = build_settings_receipt(args.repository, repository, rulesets)
    _atomic_write(args.output.resolve(), receipt)
    print(f"captured GitHub settings receipt: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
