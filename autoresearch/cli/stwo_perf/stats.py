"""Paired-ratio statistics: Hodges-Lehmann estimate and bootstrap CI.

Deterministic: every resample uses a caller-supplied seed so a verdict is
reproducible from its inputs. Stdlib only.
"""

from __future__ import annotations

import math
import random
import statistics


def hodges_lehmann(ratios: list[float]) -> float:
    """Median of pairwise means (Walsh averages) — robust location estimate."""
    if not ratios:
        raise ValueError("no ratios")
    walsh = [
        (ratios[i] + ratios[j]) / 2.0
        for i in range(len(ratios))
        for j in range(i, len(ratios))
    ]
    return statistics.median(walsh)


def bootstrap_ci(
    ratios: list[float],
    level: float = 0.95,
    iterations: int = 4000,
    seed: int = 0,
) -> tuple[float, float]:
    """Percentile bootstrap CI of the Hodges-Lehmann estimate over paired ratios."""
    if len(ratios) < 3:
        raise ValueError("need at least 3 paired rounds for a CI")
    rng = random.Random(seed)
    n = len(ratios)
    estimates = []
    for _ in range(iterations):
        sample = [ratios[rng.randrange(n)] for _ in range(n)]
        estimates.append(hodges_lehmann(sample))
    estimates.sort()
    alpha = (1.0 - level) / 2.0
    lo = estimates[max(0, math.floor(alpha * iterations))]
    hi = estimates[min(iterations - 1, math.ceil((1.0 - alpha) * iterations) - 1)]
    return (lo, hi)


def geometric_mean(values: list[float]) -> float:
    if not values:
        raise ValueError("no values")
    if any(v <= 0 for v in values):
        raise ValueError("geometric mean requires positive values")
    return math.exp(sum(math.log(v) for v in values) / len(values))


def mad(values: list[float]) -> float:
    med = statistics.median(values)
    return statistics.median([abs(v - med) for v in values])


def theta(dispersion: float | None, floor: float, multiplier: float) -> float:
    """Promotion threshold: max(floor, multiplier x measured A/A dispersion)."""
    if dispersion is None:
        return floor
    return max(floor, multiplier * dispersion)
