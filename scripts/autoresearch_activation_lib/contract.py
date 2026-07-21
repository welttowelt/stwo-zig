"""Fail-closed BA-03 activation checks for an autoresearch board."""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import math
import re
from pathlib import Path
from typing import Any

try:
    from riscv_release_gate_lib.contract import receipt_errors
except ModuleNotFoundError:
    from scripts.riscv_release_gate_lib.contract import receipt_errors


SETTINGS_SCHEMA = "autoresearch_github_settings_receipt_v2"
REQUIRED_WORKFLOWS = {
    ".github/workflows/judge.yml": "autoresearch-judge",
    ".github/workflows/promote.yml": "autoresearch-promote",
}
REQUIRED_CHECKS = frozenset({"autoresearch-validate", "autoresearch-judge"})
RISCV_ORACLE_COMMIT = "d478f783055aa0d73a93768a433a3c6c31c91d1c"
RISCV_REPORT_SCHEMA = "riscv_proof_v2"
RISCV_RESOURCE_TELEMETRY = {
    "fail_closed": True,
    "source": "darwin.proc_pid_rusage.RUSAGE_INFO_V6",
    "scope": "self_process_lifetime",
    "sampling_points": ["before_warmups", "after_verified_samples"],
    "fields": [
        "lifetime_max_phys_footprint_bytes", "energy_nj", "instructions", "cycles",
    ],
}
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
GITHUB_ACTIONS_INTEGRATION_ID = 15368
APPROVED_BYPASS_ACTORS = frozenset({
    (GITHUB_ACTIONS_INTEGRATION_ID, "Integration", "always"),
})


class ActivationError(ValueError):
    """Activation evidence is malformed or incomplete."""


def _canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def _positive(value: object) -> bool:
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(value)
        and value > 0
    )


def _strict_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON field: {key}")
        result[key] = value
    return result


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
        check_identities: set[tuple[str, int]] = set()
        if isinstance(checks, list):
            for item in checks:
                if (
                    not isinstance(item, dict)
                    or not isinstance(item.get("context"), str)
                    or type(item.get("integration_id")) is not int
                ):
                    errors.append("main required status-check identity is malformed")
                    continue
                check_identities.add((item["context"], item["integration_id"]))
        required_identities = {
            (context, GITHUB_ACTIONS_INTEGRATION_ID) for context in REQUIRED_CHECKS
        }
        if not required_identities.issubset(check_identities):
            errors.append("main does not require the autoresearch validate and judge checks")
        bypasses = payload.get("bypass_actors")
        bypass_identities: set[tuple[int, str, str]] = set()
        if not isinstance(bypasses, list):
            errors.append("main ruleset bypass actors are missing")
        else:
            for item in bypasses:
                if not isinstance(item, dict):
                    errors.append("main ruleset bypass actor is malformed")
                    continue
                identity = (
                    item.get("actor_id"),
                    item.get("actor_type"),
                    item.get("bypass_mode"),
                )
                if type(identity[0]) is not int or not all(
                    isinstance(value, str) and value for value in identity[1:]
                ):
                    errors.append("main ruleset bypass actor is malformed")
                    continue
                bypass_identities.add(identity)
            if not bypass_identities.issubset(APPROVED_BYPASS_ACTORS):
                errors.append("main ruleset has an unapproved bypass actor")
        if payload.get("ruleset_enforcement") != "active":
            errors.append("main ruleset is not active")
        if payload.get("non_fast_forward") is not True:
            errors.append("main does not reject non-fast-forward updates")
    return errors


def _board_classes(
    manifest: dict[str, Any], group: dict[str, Any], errors: list[str],
) -> list[str]:
    registry = manifest.get("workload_registry", {}).get("classes")
    workloads = group.get("workloads")
    if not isinstance(registry, dict) or not registry:
        errors.append("manifest workload class registry is missing")
        return []
    if not isinstance(workloads, dict):
        return []
    exposed = {
        spec.get("class") for spec in workloads.values() if isinstance(spec, dict)
    }
    unknown = sorted(exposed - set(registry))
    if unknown:
        errors.append("RISC-V workloads reference unknown classes: " + ", ".join(unknown))
    unscored = sorted(
        name for name in exposed & set(registry)
        if not isinstance(registry[name], dict)
        or registry[name].get("scored") is not True
    )
    if unscored:
        errors.append("RISC-V workloads use unscored classes: " + ", ".join(unscored))
    return [
        name for name, spec in registry.items()
        if isinstance(spec, dict) and spec.get("scored") is True and name in exposed
    ]


def _workload_errors(group: dict[str, Any], classes: list[str]) -> list[str]:
    errors: list[str] = []
    workloads = group.get("workloads")
    if not isinstance(workloads, dict):
        return ["RISC-V workload registry is missing"]
    by_class = {
        name: [wid for wid, spec in workloads.items() if spec.get("class") == name]
        for name in classes
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
            for name in classes:
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


def _release_anchor_errors(root: Path, oracle: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    binding = oracle.get("release_anchor")
    if not isinstance(binding, dict):
        return ["RISC-V Stark-V release anchor is not pinned"]
    if set(binding) != {"receipt", "sha256", "candidate_commit"}:
        errors.append("RISC-V release anchor binding has unexpected fields")
    relative = binding.get("receipt")
    digest = binding.get("sha256")
    candidate = binding.get("candidate_commit")
    if not isinstance(relative, str) or not relative or Path(relative).is_absolute():
        return errors + ["RISC-V release anchor path is invalid"]
    if not SHA256_RE.fullmatch(str(digest or "")):
        errors.append("RISC-V release anchor digest is invalid")
    if not COMMIT_RE.fullmatch(str(candidate or "")):
        errors.append("RISC-V release anchor candidate is invalid")

    repository = root.resolve()
    path = (repository / relative).resolve()
    try:
        path.relative_to(repository)
    except ValueError:
        return errors + ["RISC-V release anchor escapes the repository"]
    if not path.is_file():
        return errors + ["RISC-V release anchor receipt is missing"]
    raw = path.read_bytes()
    if SHA256_RE.fullmatch(str(digest or "")) and hashlib.sha256(raw).hexdigest() != digest:
        errors.append("RISC-V release anchor receipt digest mismatches")
    try:
        receipt = json.loads(raw, object_pairs_hook=_strict_object)
    except (UnicodeDecodeError, ValueError):
        return errors + ["RISC-V release anchor receipt is not valid JSON"]
    if not isinstance(receipt, dict):
        return errors + ["RISC-V release anchor receipt must be an object"]
    created_at = receipt.get("created_at_unix")
    validation_time = (
        created_at if isinstance(created_at, int) and not isinstance(created_at, bool)
        else None
    )
    try:
        evidence_errors = receipt_errors(receipt, str(candidate), now=validation_time)
    except (OSError, ValueError, KeyError, TypeError) as error:
        errors.append(f"RISC-V release anchor validation failed: {error}")
    else:
        if evidence_errors:
            errors.append(
                "RISC-V release anchor fails the full evidence contract "
                f"({len(evidence_errors)} findings): {evidence_errors[0]}"
            )
    return errors


def _release_phase_errors(root: Path) -> list[str]:
    capability = root / "src/products/riscv_cpu/capabilities.zig"
    artifact = root / "src/interop/riscv_artifact.zig"
    if not capability.is_file() or not artifact.is_file():
        return ["RISC-V release phase sources are missing"]
    capability_source = capability.read_text(encoding="utf-8")
    artifact_source = artifact.read_text(encoding="utf-8")
    errors = []
    if re.search(r"pub\s+const\s+adapter_release_gated\s*=\s*true\s*;", capability_source) is None:
        errors.append("RISC-V adapter is not release gated")
    if re.search(r'pub\s+const\s+RELEASE_STATUS\s*=\s*"release_gated"\s*;', artifact_source) is None:
        errors.append("RISC-V artifact status is not release gated")
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
    board_classes = _board_classes(manifest, group, errors)
    if not board_classes:
        errors.append(f"board {board} exposes no scored workload classes")
    if require_active and group.get("enabled") is not True:
        errors.append(f"board {board} is disabled")
    if require_active and group.get("promotion_eligible") is not True:
        errors.append(f"board {board} is not promotion eligible")
    if group.get("report_schema") != RISCV_REPORT_SCHEMA:
        errors.append("RISC-V board does not consume riscv_proof_v2")

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
        errors.extend(_release_anchor_errors(root, oracle))
    errors.extend(_release_phase_errors(root))
    errors.extend(_workload_errors(group, board_classes))

    telemetry = group.get("mechanism_telemetry")
    if not isinstance(telemetry, dict) or telemetry.get("fail_closed") is not True:
        errors.append("RISC-V mechanism telemetry is not fail closed")
    elif not set(telemetry.get("required_fields") or []).issuperset({
        "total_steps", "n_components", "mean_proving_seconds", "statement_sha256",
    }):
        errors.append("RISC-V mechanism telemetry omits required proof fields")

    if group.get("resource_telemetry") != RISCV_RESOURCE_TELEMETRY:
        errors.append(
            "RISC-V resource telemetry does not fail closed on Darwin "
            "RUSAGE_INFO_V6 sampling"
        )

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
    for name in board_classes:
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
