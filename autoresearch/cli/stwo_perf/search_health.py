"""Pure search-health metrics, round decisions, and feed projection.

Search health is diagnostic.  This module deliberately has no dependency on
runner gates: it describes measurement power and cost without changing whether
correctness, resource, or promotion gates pass.
"""

from __future__ import annotations

import hashlib
import json
import math
import statistics
from dataclasses import asdict, dataclass, replace
from pathlib import Path
from typing import Callable, Mapping, Sequence


SCHEMA_VERSION = 1
DECISION_FILE = "search-health-decision.json"


class SearchHealthError(RuntimeError):
    pass


@dataclass(frozen=True)
class HistoryPoint:
    gradient_snr: float
    measurement_wall_seconds: float
    actual_rounds: int


@dataclass(frozen=True)
class RoundDecision:
    schema_version: int
    board: str
    workload_class: str
    trailing_window: int
    trailing_evidence_count: int
    trailing_median_gradient_snr: float | None
    gradient_snr_threshold: float
    configured_rounds: int
    auto_boost_rounds: int
    maximum_rounds: int
    target_rounds: int
    workload_count: int
    class_wall_deadline_seconds: float
    estimated_seconds_per_round: float | None
    deadline_round_limit: int | None
    auto_boost_applied: bool
    auto_boost_reason: str
    recorded_before_measurement: bool = True

    def to_dict(self) -> dict:
        return asdict(self)


def _finite(value: object, name: str, *, positive: bool = False) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise SearchHealthError(f"{name} must be numeric")
    result = float(value)
    if not math.isfinite(result) or (positive and result <= 0):
        qualifier = "positive and finite" if positive else "finite"
        raise SearchHealthError(f"{name} must be {qualifier}")
    return result


def directional_log_uncertainty(
    judged_r: float, ci_low: float, ci_high: float,
) -> float:
    """Return the log-CI radius toward neutral for one ratio observation."""
    ratio = _finite(judged_r, "judged_r", positive=True)
    low = _finite(ci_low, "ci_low", positive=True)
    high = _finite(ci_high, "ci_high", positive=True)
    if low > ratio or ratio > high:
        raise SearchHealthError("ratio must lie inside its confidence interval")
    point = math.log(ratio)
    if point < 0:
        uncertainty = math.log(high) - point
    elif point > 0:
        uncertainty = point - math.log(low)
    else:
        uncertainty = (math.log(high) - math.log(low)) / 2.0
    if uncertainty <= 0 or not math.isfinite(uncertainty):
        raise SearchHealthError("directional log uncertainty must be positive")
    return uncertainty


def gradient_snr(
    credited_log_effect: float,
    judged_r: float,
    ci_low: float,
    ci_high: float,
) -> float:
    """Absolute credited log effect divided by directional log uncertainty."""
    credit = _finite(credited_log_effect, "credited_log_effect")
    point = math.log(_finite(judged_r, "judged_r", positive=True))
    if credit and (point == 0 or math.copysign(1.0, credit) != math.copysign(1.0, point)):
        raise SearchHealthError("credited log effect points away from the measured effect")
    if abs(credit) > abs(point) + 1e-12:
        raise SearchHealthError("credited log effect exceeds the measured log effect")
    return abs(credit) / directional_log_uncertainty(
        judged_r, ci_low, ci_high
    )


def credited_ln_improvement_per_measurement_hour(
    credited_log_effect: float, measurement_wall_seconds: float,
) -> float:
    """Signed credited ``-ln(R)`` divided by complete measurement wall hours."""
    credit = _finite(credited_log_effect, "credited_log_effect")
    seconds = _finite(
        measurement_wall_seconds, "measurement_wall_seconds", positive=True
    )
    return -credit / (seconds / 3600.0)


def decide_rounds(
    *,
    board: str,
    workload_class: str,
    configured_rounds: int,
    minimum_rounds: int,
    workload_count: int,
    class_wall_deadline_seconds: float,
    policy: Mapping[str, object],
    history: Sequence[HistoryPoint],
    elapsed_before_measurement_seconds: float = 0.0,
) -> RoundDecision:
    """Choose a bounded round target from evidence available before measurement.

    Deadline capacity is estimated from the trailing complete-evaluation wall
    cost per measured workload round.  Runtime enforcement remains authoritative;
    this estimate can lower the target but can never move the class deadline.
    """
    try:
        trailing_window = int(policy["trailing_window"])
        threshold = float(policy["gradient_snr_threshold"])
        boost = int(policy["auto_boost_rounds"])
        maximum = int(policy["maximum_rounds"])
    except (KeyError, TypeError, ValueError) as exc:
        raise SearchHealthError("search-health policy is incomplete") from exc
    integer_values = {
        "trailing_window": trailing_window,
        "auto_boost_rounds": boost,
        "maximum_rounds": maximum,
        "configured_rounds": configured_rounds,
        "minimum_rounds": minimum_rounds,
        "workload_count": workload_count,
    }
    if any(type(value) is not int or value < 1 for value in integer_values.values()):
        raise SearchHealthError("round policy and workload count must be positive integers")
    if minimum_rounds > configured_rounds or configured_rounds > maximum:
        raise SearchHealthError("round bounds are inverted")
    if not math.isfinite(threshold) or threshold <= 0:
        raise SearchHealthError("gradient SNR threshold must be positive and finite")
    deadline_seconds = _finite(
        class_wall_deadline_seconds, "class_wall_deadline_seconds", positive=True
    )
    elapsed = _finite(elapsed_before_measurement_seconds, "elapsed_before_measurement_seconds")
    if elapsed < 0 or elapsed >= deadline_seconds:
        raise SearchHealthError("no class deadline remains for measurement")

    trailing = list(history[-trailing_window:])
    for point in trailing:
        _finite(point.gradient_snr, "history.gradient_snr")
        _finite(
            point.measurement_wall_seconds,
            "history.measurement_wall_seconds",
            positive=True,
        )
        if type(point.actual_rounds) is not int or point.actual_rounds < 1:
            raise SearchHealthError("history.actual_rounds must be a positive integer")
    median_snr = (
        float(statistics.median(point.gradient_snr for point in trailing))
        if trailing else None
    )
    per_round = (
        float(statistics.median(
            point.measurement_wall_seconds / point.actual_rounds
            for point in trailing
        ))
        if trailing else None
    )
    deadline_limit = None
    if per_round is not None:
        remaining = deadline_seconds - elapsed
        deadline_limit = math.floor(remaining / (per_round * workload_count))
        if deadline_limit < minimum_rounds:
            raise SearchHealthError(
                "remaining class deadline cannot support the minimum measured rounds"
            )

    desired = configured_rounds
    applied = False
    if median_snr is None:
        reason = "insufficient_trailing_evidence"
    elif median_snr >= threshold:
        reason = "trailing_median_at_or_above_threshold"
    else:
        desired = min(configured_rounds + boost, maximum)
        if deadline_limit is not None:
            desired = min(desired, deadline_limit)
        applied = desired > configured_rounds
        reason = (
            "trailing_median_below_threshold"
            if applied
            else "trailing_median_below_threshold_deadline_limited"
        )
    target = min(desired, maximum)
    if deadline_limit is not None:
        target = min(target, deadline_limit)
    target = max(minimum_rounds, target)

    return RoundDecision(
        schema_version=SCHEMA_VERSION,
        board=board,
        workload_class=workload_class,
        trailing_window=trailing_window,
        trailing_evidence_count=len(trailing),
        trailing_median_gradient_snr=median_snr,
        gradient_snr_threshold=threshold,
        configured_rounds=configured_rounds,
        auto_boost_rounds=boost,
        maximum_rounds=maximum,
        target_rounds=target,
        workload_count=workload_count,
        class_wall_deadline_seconds=deadline_seconds,
        estimated_seconds_per_round=per_round,
        deadline_round_limit=deadline_limit,
        auto_boost_applied=applied,
        auto_boost_reason=reason,
    )


def require_audit_power(decision: RoundDecision) -> RoundDecision:
    """Raise a normal decision to the bounded audit target.

    Audits are sparse correctness-and-credit checkpoints. They always request
    the configured boost, even when ordinary trailing search evidence is not
    yet sufficient to trigger automatic boosting. The existing maximum and
    deadline bounds remain authoritative.
    """
    desired = min(
        decision.configured_rounds + decision.auto_boost_rounds,
        decision.maximum_rounds,
    )
    if decision.deadline_round_limit is not None:
        desired = min(desired, decision.deadline_round_limit)
    target = max(decision.target_rounds, desired)
    if target == decision.target_rounds and decision.auto_boost_applied:
        return decision
    return replace(
        decision,
        target_rounds=target,
        auto_boost_applied=target > decision.configured_rounds,
        auto_boost_reason=(
            "required_audit_power"
            if target > decision.configured_rounds
            else "required_audit_power_deadline_limited"
        ),
    )


def canonical_sha256(payload: object) -> str:
    encoded = json.dumps(
        payload, ensure_ascii=True, sort_keys=True, separators=(",", ":")
    ).encode("ascii")
    return "sha256:" + hashlib.sha256(encoded).hexdigest()


def decision_record(decision: RoundDecision) -> dict:
    payload = decision.to_dict()
    return {"decision": payload, "decision_sha256": canonical_sha256(payload)}


def evidence_block(
    decision: RoundDecision,
    *,
    actual_rounds_per_workload: Mapping[str, int],
    objective_wall_seconds: float,
    measurement_wall_seconds: float,
) -> dict:
    rounds = dict(sorted(actual_rounds_per_workload.items()))
    if not rounds or any(type(value) is not int or value < 1 for value in rounds.values()):
        raise SearchHealthError("actual rounds must be positive integers")
    objective = _finite(objective_wall_seconds, "objective_wall_seconds", positive=True)
    total = _finite(measurement_wall_seconds, "measurement_wall_seconds", positive=True)
    if objective > decision.class_wall_deadline_seconds:
        raise SearchHealthError("objective measurement exceeded the fixed class deadline")
    if total < objective:
        raise SearchHealthError("total measurement wall cannot be shorter than objective wall")
    record = decision_record(decision)
    return {
        "schema_version": SCHEMA_VERSION,
        **record,
        "actual_rounds": sum(rounds.values()),
        "actual_rounds_per_workload": rounds,
        "objective_wall_seconds": objective,
        "measurement_wall_seconds": total,
        "measurement_wall_hours": total / 3600.0,
        "gradient_snr": None,
        "credited_ln_improvement": None,
        "credited_ln_improvement_per_measurement_hour": None,
        "credit_status": "pending_ledger_adjudication",
    }


def load_verdicts_by_evidence(repo: Path) -> dict[str, dict]:
    """Index committed claimed and judged verdicts by canonical evidence digest."""
    result: dict[str, dict] = {}
    submissions = repo / "autoresearch" / "submissions"
    if not submissions.is_dir():
        return result
    for path in sorted(submissions.glob("*/*verdict*.json")):
        try:
            value = json.loads(path.read_text())
        except (json.JSONDecodeError, OSError):
            continue
        if not isinstance(value, dict):
            continue
        digest = canonical_sha256(value)
        existing = result.get(digest)
        if existing is not None and existing != value:
            raise SearchHealthError(f"evidence digest collision at {path}")
        result[digest] = value
    return result


def _row_value(row: object, name: str, default=None):
    values = getattr(row, "values", None)
    if isinstance(values, dict):
        return values.get(name, default)
    if isinstance(row, dict):
        return row.get(name, default)
    return getattr(row, name, default)


def _unavailable_point(row: object, reason: str) -> dict:
    return {
        "row_id": _row_value(row, "row_id"),
        "submission_id": _row_value(row, "submission_id"),
        "judged_at_utc": _row_value(row, "judged_at_utc"),
        "verdict_kind": _row_value(row, "verdict_kind"),
        "available": False,
        "unavailable_reason": reason,
    }


def _validate_decision_dict(decision: dict) -> None:
    if decision.get("schema_version") != SCHEMA_VERSION:
        raise SearchHealthError("search-health decision schema is unsupported")
    integer_fields = (
        "trailing_window", "trailing_evidence_count", "configured_rounds",
        "auto_boost_rounds", "maximum_rounds", "target_rounds", "workload_count",
    )
    for name in integer_fields:
        value = decision.get(name)
        minimum = 0 if name == "trailing_evidence_count" else 1
        if type(value) is not int or value < minimum:
            raise SearchHealthError(f"search-health decision {name} is invalid")
    if decision["trailing_evidence_count"] > decision["trailing_window"]:
        raise SearchHealthError("search-health trailing evidence exceeds its window")
    threshold = _finite(
        decision.get("gradient_snr_threshold"),
        "search_health.gradient_snr_threshold",
        positive=True,
    )
    median = decision.get("trailing_median_gradient_snr")
    if median is not None:
        median = _finite(median, "search_health.trailing_median_gradient_snr")
        if median < 0:
            raise SearchHealthError("search-health trailing median SNR is negative")
    configured = decision["configured_rounds"]
    target = decision["target_rounds"]
    maximum = decision["maximum_rounds"]
    boost = decision["auto_boost_rounds"]
    if target > maximum or target > configured + boost:
        raise SearchHealthError("search-health target exceeds its bounded policy")
    deadline_limit = decision.get("deadline_round_limit")
    estimate = decision.get("estimated_seconds_per_round")
    if deadline_limit is None:
        if estimate is not None:
            raise SearchHealthError("search-health cost estimate lacks a deadline bound")
    else:
        if type(deadline_limit) is not int or deadline_limit < 1 or target > deadline_limit:
            raise SearchHealthError("search-health target exceeds its deadline round bound")
        _finite(estimate, "search_health.estimated_seconds_per_round", positive=True)
    applied = decision.get("auto_boost_applied")
    reason = decision.get("auto_boost_reason")
    if type(applied) is not bool or not isinstance(reason, str) or not reason:
        raise SearchHealthError("search-health boost decision is malformed")
    if applied != (target > configured):
        raise SearchHealthError("search-health boost flag disagrees with its target")
    if reason == "insufficient_trailing_evidence":
        valid_reason = median is None and not applied
    elif reason == "trailing_median_at_or_above_threshold":
        valid_reason = median is not None and median >= threshold and not applied
    elif reason == "trailing_median_below_threshold":
        valid_reason = median is not None and median < threshold and applied
    elif reason == "trailing_median_below_threshold_deadline_limited":
        valid_reason = median is not None and median < threshold and not applied
    elif reason == "required_audit_power":
        valid_reason = applied
    elif reason == "required_audit_power_deadline_limited":
        valid_reason = not applied
    else:
        valid_reason = False
    if not valid_reason:
        raise SearchHealthError("search-health boost reason disagrees with its evidence")


def _validated_point(
    row: object,
    verdict: dict,
    credited_log_effect_fn: Callable[[object], float],
) -> dict:
    evidence = verdict.get("search_health")
    if not isinstance(evidence, dict) or evidence.get("schema_version") != SCHEMA_VERSION:
        raise SearchHealthError("verdict search_health evidence is absent or unsupported")
    decision = evidence.get("decision")
    if not isinstance(decision, dict):
        raise SearchHealthError("search_health.decision must be an object")
    if evidence.get("decision_sha256") != canonical_sha256(decision):
        raise SearchHealthError("search-health decision digest does not match")
    if decision.get("recorded_before_measurement") is not True:
        raise SearchHealthError("search-health decision was not recorded before measurement")
    if decision.get("board") != _row_value(row, "board") or decision.get(
        "workload_class"
    ) != _row_value(row, "workload_class"):
        raise SearchHealthError("search-health decision board/class does not match row")
    _validate_decision_dict(decision)
    configured = decision["configured_rounds"]
    target = decision["target_rounds"]
    actual = evidence.get("actual_rounds")
    rounds = evidence.get("actual_rounds_per_workload")
    if (
        type(actual) is not int
        or actual < 1
        or not isinstance(rounds, dict)
        or not rounds
        or any(type(value) is not int or value < 1 for value in rounds.values())
        or sum(rounds.values()) != actual
    ):
        raise SearchHealthError("search-health actual rounds are invalid")
    if any(value > target for value in rounds.values()):
        raise SearchHealthError("actual rounds exceed the pre-measurement target")
    if len(rounds) != decision["workload_count"]:
        raise SearchHealthError("actual workload count differs from the decision")
    seconds = _finite(
        evidence.get("measurement_wall_seconds"),
        "search_health.measurement_wall_seconds",
        positive=True,
    )
    objective_seconds = _finite(
        evidence.get("objective_wall_seconds"),
        "search_health.objective_wall_seconds",
        positive=True,
    )
    deadline = _finite(
        decision.get("class_wall_deadline_seconds"),
        "search_health.class_wall_deadline_seconds",
        positive=True,
    )
    if objective_seconds > deadline or seconds < objective_seconds:
        raise SearchHealthError("search-health wall evidence violates its deadline")
    hours = _finite(
        evidence.get("measurement_wall_hours"),
        "search_health.measurement_wall_hours",
        positive=True,
    )
    if not math.isclose(hours, seconds / 3600.0, rel_tol=0.0, abs_tol=1e-15):
        raise SearchHealthError("search-health wall hours do not match wall seconds")
    if (
        evidence.get("credit_status") != "pending_ledger_adjudication"
        or evidence.get("gradient_snr") is not None
        or evidence.get("credited_ln_improvement") is not None
        or evidence.get("credited_ln_improvement_per_measurement_hour") is not None
    ):
        raise SearchHealthError("verdict claims credit before ledger adjudication")
    ledger_seconds = _row_value(row, "measurement_seconds")
    ledger_rounds = _row_value(row, "measurement_rounds")
    if ledger_seconds is None or not math.isclose(
        float(ledger_seconds), seconds, rel_tol=0.0, abs_tol=5e-7
    ):
        raise SearchHealthError("verdict wall seconds do not match the ledger row")
    if ledger_rounds != actual:
        raise SearchHealthError("verdict rounds do not match the ledger row")
    credit = _finite(credited_log_effect_fn(row), "credited_log_effect")
    snr = gradient_snr(
        credit,
        float(_row_value(row, "judged_r")),
        float(_row_value(row, "ci_low")),
        float(_row_value(row, "ci_high")),
    )
    improvement = -credit
    return {
        "row_id": _row_value(row, "row_id"),
        "submission_id": _row_value(row, "submission_id"),
        "judged_at_utc": _row_value(row, "judged_at_utc"),
        "verdict_kind": _row_value(row, "verdict_kind"),
        "available": True,
        "gradient_snr": snr,
        "configured_rounds": configured,
        "actual_rounds": actual,
        "actual_rounds_per_workload": dict(sorted(rounds.items())),
        "auto_boost_reason": decision.get("auto_boost_reason"),
        "auto_boost_target_rounds": target,
        "measurement_wall_hours": hours,
        "credited_ln_improvement": improvement,
        "credited_ln_improvement_per_measurement_hour": (
            credited_ln_improvement_per_measurement_hour(credit, seconds)
        ),
    }


def class_series(
    rows: Sequence[object],
    verdicts_by_evidence: Mapping[str, dict],
    *,
    trailing_window: int,
    credited_log_effect_fn: Callable[[object], float],
) -> dict:
    """Build one deterministic board/class time series from explicit inputs."""
    if type(trailing_window) is not int or trailing_window < 1:
        raise SearchHealthError("trailing_window must be a positive integer")
    points = []
    for row in rows:
        if int(_row_value(row, "schema_version", 0)) < 3:
            points.append(_unavailable_point(
                row, "legacy_row_has_no_search_health_evidence"
            ))
            continue
        digest = _row_value(row, "evidence_sha256")
        verdict = verdicts_by_evidence.get(digest)
        if verdict is None:
            error = "verdict_bound_by_ledger_evidence_is_missing"
            if _row_value(row, "verdict_kind") == "judged":
                raise SearchHealthError(error)
            points.append(_unavailable_point(row, error))
            continue
        try:
            points.append(_validated_point(row, verdict, credited_log_effect_fn))
        except (SearchHealthError, TypeError, ValueError) as exc:
            if _row_value(row, "verdict_kind") == "judged":
                raise SearchHealthError(
                    f"judged row {_row_value(row, 'row_id')} has invalid search-health evidence: {exc}"
                ) from exc
            points.append(_unavailable_point(row, f"invalid_search_health_evidence: {exc}"))

    available = [point for point in points if point["available"]]
    decay = []
    for index, point in enumerate(available):
        window = available[max(0, index + 1 - trailing_window):index + 1]
        hours = sum(item["measurement_wall_hours"] for item in window)
        improvement = sum(item["credited_ln_improvement"] for item in window)
        decay.append({
            "judged_at_utc": point["judged_at_utc"],
            "row_id": point["row_id"],
            "points": len(window),
            "credited_ln_improvement_per_measurement_hour": improvement / hours,
        })
    trailing = available[-trailing_window:]
    trailing_hours = sum(point["measurement_wall_hours"] for point in trailing)
    trailing_improvement = sum(point["credited_ln_improvement"] for point in trailing)
    return {
        "available": bool(available),
        "available_points": len(available),
        "unavailable_points": len(points) - len(available),
        "trailing_window": trailing_window,
        "trailing": {
            "points": len(trailing),
            "median_gradient_snr": (
                float(statistics.median(point["gradient_snr"] for point in trailing))
                if trailing else None
            ),
            "measurement_wall_hours": trailing_hours if trailing else None,
            "credited_ln_improvement": trailing_improvement if trailing else None,
            "credited_ln_improvement_per_measurement_hour": (
                trailing_improvement / trailing_hours if trailing else None
            ),
        },
        "latest": available[-1] if available else None,
        "time_series": points,
        "decay": decay,
    }


def projection(
    manifest,
    rows: Sequence[object],
    verdicts_by_evidence: Mapping[str, dict],
    *,
    credited_log_effect_fn: Callable[[object], float],
) -> dict:
    """Build manifest-shaped board/class search health without fixed classes."""
    policy = manifest.search_health_policy
    classes_by_board: dict[str, set[str]] = {}
    for group in manifest.groups():
        classes_by_board.setdefault(group.board, set()).update(
            workload.workload_class for workload in group.workloads
        )
    for row in rows:
        board = str(_row_value(row, "board"))
        workload_class = str(_row_value(row, "workload_class"))
        classes_by_board.setdefault(board, set()).add(workload_class)
    boards = {}
    for board in sorted(classes_by_board):
        classes = {}
        for workload_class in sorted(classes_by_board[board]):
            selected = [
                row for row in rows
                if _row_value(row, "board") == board
                and _row_value(row, "workload_class") == workload_class
            ]
            classes[workload_class] = class_series(
                selected,
                verdicts_by_evidence,
                trailing_window=int(policy["trailing_window"]),
                credited_log_effect_fn=credited_log_effect_fn,
            )
        boards[board] = {"classes": classes}
    return {
        "schema_version": SCHEMA_VERSION,
        "policy": dict(policy),
        "boards": boards,
    }


def history_from_class_series(series: Mapping[str, object]) -> list[HistoryPoint]:
    result = []
    for point in series.get("time_series", []):
        if not isinstance(point, dict) or point.get("available") is not True:
            continue
        result.append(HistoryPoint(
            gradient_snr=float(point["gradient_snr"]),
            measurement_wall_seconds=float(point["measurement_wall_hours"]) * 3600.0,
            actual_rounds=int(point["actual_rounds"]),
        ))
    return result
