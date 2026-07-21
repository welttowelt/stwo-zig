"""Fail-closed BA-03 activation checks for an autoresearch board."""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import re
from pathlib import Path
from typing import Any


SETTINGS_SCHEMA = "autoresearch_github_settings_receipt_v1"
REQUIRED_WORKFLOWS = {
    ".github/workflows/judge.yml": "autoresearch-judge",
    ".github/workflows/promote.yml": "autoresearch-promote",
}
REQUIRED_CHECKS = frozenset({"autoresearch-validate", "autoresearch-judge"})
RISCV_ORACLE_COMMIT = "d478f783055aa0d73a93768a433a3c6c31c91d1c"
RISCV_REPORT_SCHEMA = "riscv_proof_v1"
CLASSES = ("small", "wide", "deep")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


class ActivationError(ValueError):
    """Activation evidence is malformed or incomplete."""


def _canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def _positive(value: object) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and value > 0


def _load(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ActivationError(f"{label} is not valid JSON: {error}") from error
    if not isinstance(value, dict):
        raise ActivationError(f"{label} must be a JSON object")
    return value


def validate_settings_receipt(
    receipt: dict[str, Any],
    *,
    repository: str,
    now: dt.datetime | None = None,
    max_age_seconds: int = 3600,
) -> list[str]:
    """Validate a trusted-CI capture of repository ruleset state."""
    errors: list[str] = []
    if receipt.get("schema") != SETTINGS_SCHEMA:
        errors.append("GitHub settings receipt schema is unsupported")
    if receipt.get("repository") != repository:
        errors.append("GitHub settings receipt names a different repository")
    if receipt.get("default_branch") != "main":
        errors.append("GitHub settings receipt does not bind main")
    if receipt.get("source") != "github-api":
        errors.append("GitHub settings receipt is not an API observation")

    observed = receipt.get("observed_at")
    try:
        parsed = dt.datetime.fromisoformat(str(observed).replace("Z", "+00:00"))
        if parsed.tzinfo is None or parsed.utcoffset() is None:
            raise ValueError("timezone missing")
        current = now or dt.datetime.now(dt.timezone.utc)
        age = (current.astimezone(dt.timezone.utc) - parsed.astimezone(dt.timezone.utc)).total_seconds()
        if age < -300 or age > max_age_seconds:
            errors.append("GitHub settings receipt is stale or from the future")
    except ValueError:
        errors.append("GitHub settings receipt observation time is invalid")

    payload = receipt.get("payload")
    digest = receipt.get("payload_sha256")
    if not isinstance(payload, dict) or not SHA256_RE.fullmatch(str(digest or "")):
        errors.append("GitHub settings receipt payload binding is missing")
    elif hashlib.sha256(_canonical(payload)).hexdigest() != digest:
        errors.append("GitHub settings receipt payload digest mismatches")
    else:
        checks = payload.get("required_status_checks")
        if not isinstance(checks, list) or not REQUIRED_CHECKS.issubset(set(checks)):
            errors.append("main does not require the autoresearch validate and judge checks")
        if payload.get("ruleset_enforcement") != "active":
            errors.append("main ruleset is not active")
        if payload.get("non_fast_forward") is not True:
            errors.append("main does not reject non-fast-forward updates")
    return errors


def _workload_errors(group: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    workloads = group.get("workloads")
    if not isinstance(workloads, dict):
        return ["RISC-V workload registry is missing"]
    by_class = {
        name: [wid for wid, spec in workloads.items() if spec.get("class") == name]
        for name in CLASSES
    }
    for name, members in by_class.items():
        if len(members) < 2:
            errors.append(f"RISC-V {name} class needs at least two workloads")
    for workload_id, spec in workloads.items():
        args = str(spec.get("args", ""))
        if "bench --elf " not in args or "--backend cpu" not in args:
            errors.append(f"{workload_id} is not a production RISC-V CPU proof command")
        if "--protocol functional" not in args:
            errors.append(f"{workload_id} does not pin the functional protocol")
        if "{admission}" not in args:
            errors.append(f"{workload_id} does not use phase-aware admission")
        if spec.get("native_unit") != "executed instructions":
            errors.append(f"{workload_id} has the wrong native unit")

    generator = group.get("holdout_generator")
    if not isinstance(generator, dict) or generator.get("strategy") != "seeded_workload_pool_v1":
        errors.append("RISC-V holdout generator is not a real-program pool")
    else:
        pools = generator.get("pools")
        if not isinstance(pools, dict):
            errors.append("RISC-V holdout pools are missing")
        else:
            for name in CLASSES:
                pool = pools.get(name)
                if not isinstance(pool, list) or len(pool) < 2:
                    errors.append(f"RISC-V {name} holdout pool is too small")
                    continue
                for workload_id in pool:
                    spec = workloads.get(workload_id)
                    if not isinstance(spec, dict) or spec.get("class") != name:
                        errors.append(f"RISC-V {name} holdout references {workload_id!r} incorrectly")
    return errors


def _workflow_errors(root: Path) -> list[str]:
    errors: list[str] = []
    for relative, expected_name in REQUIRED_WORKFLOWS.items():
        path = root / relative
        if not path.is_file():
            errors.append(f"required workflow is not installed: {relative}")
            continue
        text = path.read_text(encoding="utf-8")
        if f"name: {expected_name}" not in text:
            errors.append(f"{relative} has the wrong workflow identity")
    return errors


def activation_errors(
    root: Path,
    *,
    board: str,
    settings_receipt: Path | None,
    repository: str,
    require_active: bool = True,
) -> list[str]:
    """Return all blockers to promotion-eligible board activation."""
    errors: list[str] = []
    manifest = _load(root / "autoresearch/MANIFEST.json", "autoresearch manifest")
    groups = manifest.get("workload_registry", {}).get("groups", {})
    matches = [value for value in groups.values() if value.get("board") == board]
    if len(matches) != 1:
        return [f"board {board} must have exactly one workload owner"]
    group = matches[0]
    if require_active and group.get("enabled") is not True:
        errors.append(f"board {board} is disabled")
    if require_active and group.get("promotion_eligible") is not True:
        errors.append(f"board {board} is not promotion eligible")
    if group.get("report_schema") != RISCV_REPORT_SCHEMA:
        errors.append("RISC-V board does not consume riscv_proof_v1")

    oracle = group.get("correctness_oracle")
    if not isinstance(oracle, dict):
        errors.append("RISC-V final correctness oracle is missing")
    else:
        if oracle.get("authority") != "stark-v" or oracle.get("commit") != RISCV_ORACLE_COMMIT:
            errors.append("RISC-V final correctness oracle is not pinned Stark-V")
        if oracle.get("final_validator") is not True:
            errors.append("Stark-V is not marked as the final validator")
        if "parallel" not in (oracle.get("required_features") or []):
            errors.append("Stark-V oracle does not require the parallel feature")
    errors.extend(_workload_errors(group))

    telemetry = group.get("mechanism_telemetry")
    if not isinstance(telemetry, dict) or telemetry.get("fail_closed") is not True:
        errors.append("RISC-V mechanism telemetry is not fail closed")
    elif not set(telemetry.get("required_fields") or []).issuperset({
        "total_steps", "n_components", "mean_proving_seconds", "statement_sha256",
    }):
        errors.append("RISC-V mechanism telemetry omits required proof fields")

    policy = group.get("gates_policy")
    if not isinstance(policy, dict) or not all(
        isinstance(policy.get(key), int) and policy[key] > 0
        for key in ("samples_per_round", "min_rounds", "max_rounds")
    ):
        errors.append("RISC-V board sampling policy is missing or invalid")

    anchors = manifest.get("harness", {}).get("anchor_prove_ms", {}).get(board, {})
    epoch = _load(root / "autoresearch/ledger/epochs.json", "autoresearch epochs")
    epochs = epoch.get("epochs") or []
    dispersion = (epochs[-1].get("aa_dispersion", {}).get(board, {}) if epochs else {})
    for name in CLASSES:
        if not _positive(anchors.get(name)):
            errors.append(f"RISC-V {name} anchor is not frozen")
        if not _positive(dispersion.get(name)):
            errors.append(f"RISC-V {name} A/A dispersion is not frozen")

    errors.extend(_workflow_errors(root))
    if settings_receipt is None:
        errors.append("fresh GitHub settings receipt is required")
    else:
        try:
            receipt = _load(settings_receipt, "GitHub settings receipt")
            errors.extend(validate_settings_receipt(receipt, repository=repository))
        except ActivationError as error:
            errors.append(str(error))
    return errors
