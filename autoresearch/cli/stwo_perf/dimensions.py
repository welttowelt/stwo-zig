"""Pure resource-vector estimation, budget admission, and Pareto ordering."""

from __future__ import annotations

import math
from dataclasses import dataclass

from . import stats


RESOURCE_DIMENSIONS = ("peak_rss_mib", "energy_j", "proof_bytes")
PARETO_DIMENSIONS = ("prove_ms", *RESOURCE_DIMENSIONS)


class DimensionError(RuntimeError):
    pass


@dataclass(frozen=True)
class RatioEstimate:
    ratio: float
    ci: tuple[float, float]
    observations: int


@dataclass(frozen=True)
class DimensionFailure:
    dimension: str
    reason: str
    observed_upper: float | None
    budget_upper: float | None


@dataclass(frozen=True)
class BudgetAssessment:
    estimates: dict[str, RatioEstimate]
    failures: tuple[DimensionFailure, ...]

    @property
    def passed(self) -> bool:
        return not self.failures


def paired_ratio_estimate(
    predecessor: list[float],
    candidate: list[float],
    *,
    ci_level: float,
    seed: int,
) -> RatioEstimate:
    """Estimate candidate/predecessor from aligned positive observations."""
    if not predecessor or len(predecessor) != len(candidate):
        raise DimensionError("paired dimension samples must be non-empty and aligned")
    if not 0 < ci_level < 1:
        raise DimensionError("dimension CI level must be between zero and one")
    values = [*predecessor, *candidate]
    if any(
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(float(value))
        or float(value) <= 0
        for value in values
    ):
        raise DimensionError("dimension samples must be positive finite numbers")
    ratios = [float(b) / float(a) for a, b in zip(predecessor, candidate)]
    return RatioEstimate(
        ratio=stats.hodges_lehmann(ratios),
        ci=stats.bootstrap_ci(ratios, level=ci_level, seed=seed),
        observations=len(ratios),
    )


def exact_ratio(predecessor: float, candidate: float) -> RatioEstimate:
    """Represent a deterministic dimension such as canonical proof byte size."""
    values = (predecessor, candidate)
    if any(
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(float(value))
        or float(value) <= 0
        for value in values
    ):
        raise DimensionError("exact dimension values must be positive and finite")
    ratio = float(candidate) / float(predecessor)
    return RatioEstimate(ratio=ratio, ci=(ratio, ratio), observations=1)


def assess_budgets(
    estimates: dict[str, RatioEstimate | None],
    budgets: dict[str, float],
    *,
    required: tuple[str, ...] = RESOURCE_DIMENSIONS,
) -> BudgetAssessment:
    """Fail closed when a required vector cell is absent or exceeds its budget."""
    unknown = (set(estimates) | set(budgets) | set(required)) - set(RESOURCE_DIMENSIONS)
    if unknown:
        raise DimensionError(f"unknown resource dimensions: {sorted(unknown)}")
    failures: list[DimensionFailure] = []
    admitted: dict[str, RatioEstimate] = {}
    for dimension in required:
        budget = budgets.get(dimension)
        if (
            isinstance(budget, bool)
            or not isinstance(budget, (int, float))
            or not math.isfinite(float(budget))
            or float(budget) <= 0
        ):
            failures.append(DimensionFailure(
                dimension, "budget_missing", None,
                float(budget) if isinstance(budget, (int, float)) else None,
            ))
            continue
        estimate = estimates.get(dimension)
        if estimate is None:
            failures.append(DimensionFailure(
                dimension, "measurement_missing", None, float(budget),
            ))
            continue
        _validate_estimate(dimension, estimate)
        admitted[dimension] = estimate
        if estimate.ci[1] > float(budget):
            failures.append(DimensionFailure(
                dimension, "budget_exceeded", estimate.ci[1], float(budget),
            ))
    return BudgetAssessment(admitted, tuple(failures))


def pareto_dominates(a: dict[str, float | None], b: dict[str, float | None]) -> bool:
    """Return strict complete-vector dominance; incomplete rows claim no tradeoff."""
    if any(dimension not in a or dimension not in b for dimension in PARETO_DIMENSIONS):
        return False
    a_values = [a[dimension] for dimension in PARETO_DIMENSIONS]
    b_values = [b[dimension] for dimension in PARETO_DIMENSIONS]
    if any(value is None for value in (*a_values, *b_values)):
        return False
    av = [float(value) for value in a_values if value is not None]
    bv = [float(value) for value in b_values if value is not None]
    if any(not math.isfinite(value) or value <= 0 for value in (*av, *bv)):
        raise DimensionError("Pareto vectors must contain positive finite values")
    return all(left <= right for left, right in zip(av, bv)) and any(
        left < right for left, right in zip(av, bv)
    )


def _validate_estimate(dimension: str, estimate: RatioEstimate) -> None:
    low, high = estimate.ci
    if (
        not all(math.isfinite(value) and value > 0 for value in (estimate.ratio, low, high))
        or low > estimate.ratio
        or estimate.ratio > high
        or estimate.observations < 1
    ):
        raise DimensionError(f"{dimension} ratio estimate is invalid")
