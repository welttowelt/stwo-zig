"""Authenticated GitHub ruleset evidence for BA-03 activation."""

from __future__ import annotations

import datetime as dt
import hashlib
import json
from typing import Any


SETTINGS_SCHEMA = "autoresearch_github_settings_receipt_v1"


class SettingsCaptureError(ValueError):
    """GitHub returned settings that cannot establish the activation policy."""


def _canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def _targets_default_branch(ruleset: dict[str, Any], default_branch: str) -> bool:
    ref_name = ruleset.get("conditions", {}).get("ref_name", {})
    include = ref_name.get("include", [])
    exclude = ref_name.get("exclude", [])
    target = f"refs/heads/{default_branch}"
    included = target in include or "~DEFAULT_BRANCH" in include
    excluded = target in exclude or "~DEFAULT_BRANCH" in exclude
    return included and not excluded


def settings_payload(
    repository: dict[str, Any],
    rulesets: list[dict[str, Any]],
) -> dict[str, Any]:
    """Reduce authenticated API responses to the branch-policy facts BA-03 uses."""
    default_branch = repository.get("default_branch")
    if not isinstance(default_branch, str) or not default_branch:
        raise SettingsCaptureError("repository response has no default branch")

    applicable = [
        ruleset for ruleset in rulesets
        if isinstance(ruleset, dict)
        and ruleset.get("enforcement") == "active"
        and _targets_default_branch(ruleset, default_branch)
    ]
    if not applicable:
        raise SettingsCaptureError("no active ruleset targets the default branch")

    checks: set[str] = set()
    non_fast_forward = False
    identities: list[dict[str, Any]] = []
    for ruleset in applicable:
        rules = ruleset.get("rules")
        if not isinstance(rules, list):
            raise SettingsCaptureError("ruleset response has no rules array")
        for rule in rules:
            if not isinstance(rule, dict):
                raise SettingsCaptureError("ruleset contains a malformed rule")
            rule_type = rule.get("type")
            if rule_type == "non_fast_forward":
                non_fast_forward = True
            if rule_type == "required_status_checks":
                required = rule.get("parameters", {}).get("required_status_checks")
                if not isinstance(required, list):
                    raise SettingsCaptureError("required status-check rule is malformed")
                for item in required:
                    context = item.get("context") if isinstance(item, dict) else None
                    if not isinstance(context, str) or not context:
                        raise SettingsCaptureError("required status-check context is invalid")
                    checks.add(context)
        ruleset_id = ruleset.get("id")
        if type(ruleset_id) is not int or ruleset_id <= 0:
            raise SettingsCaptureError("ruleset identity is invalid")
        identities.append({
            "id": ruleset_id,
            "name": ruleset.get("name"),
            "updated_at": ruleset.get("updated_at"),
        })

    return {
        "default_branch": default_branch,
        "non_fast_forward": non_fast_forward,
        "required_status_checks": sorted(checks),
        "ruleset_enforcement": "active",
        "rulesets": sorted(identities, key=lambda item: item["id"]),
    }


def build_settings_receipt(
    repository_name: str,
    repository: dict[str, Any],
    rulesets: list[dict[str, Any]],
    *,
    observed_at: dt.datetime | None = None,
) -> dict[str, Any]:
    payload = settings_payload(repository, rulesets)
    timestamp = observed_at or dt.datetime.now(dt.timezone.utc)
    if timestamp.tzinfo is None or timestamp.utcoffset() is None:
        raise SettingsCaptureError("observation time must be timezone-aware")
    return {
        "schema": SETTINGS_SCHEMA,
        "repository": repository_name,
        "default_branch": payload["default_branch"],
        "source": "github-api",
        "observed_at": timestamp.astimezone(dt.timezone.utc).isoformat().replace(
            "+00:00", "Z"
        ),
        "payload": payload,
        "payload_sha256": hashlib.sha256(_canonical(payload)).hexdigest(),
    }
