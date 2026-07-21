"""Pareto frontier and anchor-drift budgets, computed from the ledger only."""

from __future__ import annotations

import math
from dataclasses import dataclass

from . import ledger


@dataclass(frozen=True)
class FrontierView:
    board: str
    workload_class: str
    frontier: list[ledger.Row]
    superseded: list[ledger.Row]
    head: ledger.Row | None


def _dominates(a: ledger.Row, b: ledger.Row) -> bool:
    """Lower is better on every tracked dimension; missing dims are excluded."""
    pairs = [
        (a.prove_ms, b.prove_ms),
        (a.peak_rss_mib, b.peak_rss_mib),
        (a.energy_j, b.energy_j),
        (a.proof_bytes, b.proof_bytes),
    ]
    strictly = False
    for av, bv in pairs:
        if av is None or bv is None:
            continue
        if av > bv:
            return False
        if av < bv:
            strictly = True
    return strictly


def effective_rows(rows: list[ledger.Row]) -> list[ledger.Row]:
    """Only promoted rows shape the frontier; superseded rows drop out.

    Neutral and rejected rows stay in the ledger as the search record but
    never enter dominance or drift computations (playbook F.5/F.6).
    """
    out = []
    for row in ledger.resolve_corrections(rows):
        if row.values.get("outcome") != "promoted":
            continue
        out.append(row)
    return out


def view(rows: list[ledger.Row], board: str, workload_class: str) -> FrontierView:
    eligible = [
        r for r in effective_rows(rows)
        if r.board == board and r.workload_class == workload_class
    ]
    frontier = [
        r for r in eligible
        if not any(o is not r and _dominates(o, r) for o in eligible)
    ]
    superseded = [r for r in eligible if r not in frontier]
    head = eligible[-1] if eligible else None
    return FrontierView(board, workload_class, frontier, superseded, head)


def board_suite_score(
    rows: list[ledger.Row], board: str, scored_classes: list[str], epoch: int,
) -> dict:
    """Canonical board score over its manifest-declared scored classes.

    Each effective promoted row compounds its measured candidate/predecessor
    ratio inside one explicit scoring epoch. Opening a new class universe opens
    a new epoch whose anchor absorbs history, so old three-class rows cannot
    dilute the five-class score. A class untouched in the current epoch
    contributes the multiplicative identity. Neutral, rejected, superseded,
    other-board, and other-epoch rows do not contribute.
    """
    if not scored_classes or len(scored_classes) != len(set(scored_classes)):
        raise ValueError("scored_classes must be a unique non-empty list")
    class_ratios = {workload_class: 1.0 for workload_class in scored_classes}
    promoted_rows = {workload_class: 0 for workload_class in scored_classes}
    for row in effective_rows(rows):
        if (
            row.epoch != epoch
            or row.board != board
            or row.workload_class not in class_ratios
        ):
            continue
        ratio = float(row.judged_r)
        if not math.isfinite(ratio) or ratio <= 0:
            raise ValueError("effective promoted ratios must be positive and finite")
        class_ratios[row.workload_class] *= ratio
        promoted_rows[row.workload_class] += 1
    ratio_geomean = math.prod(class_ratios.values()) ** (1.0 / len(class_ratios))
    return {
        "method": "manifest_scored_class_compounded_geomean_v1",
        "epoch": epoch,
        "classes": list(scored_classes),
        "class_ratios": class_ratios,
        "promoted_rows": promoted_rows,
        "ratio_geomean": ratio_geomean,
        "index": 100.0 * ratio_geomean,
        "speedup": 1.0 / ratio_geomean,
    }


def drift_vs_anchor(
    rows: list[ledger.Row],
    board: str,
    workload_class: str,
    anchor_prove_ms: float,
    matrix_budget: float,
    targeted_budget: float,
) -> dict:
    """Cumulative drift of the class HEAD against the frozen anchor.

    Budgets are fixed against the anchor, never the predecessor: after any
    promotion no cell may sit worse than anchor x budget.
    """
    v = view(rows, board, workload_class)
    if v.head is None:
        return {"head": None, "ratio": None, "within_targeted": True, "within_matrix": True}
    ratio = v.head.prove_ms / anchor_prove_ms
    return {
        "head": v.head,
        "ratio": ratio,
        "within_targeted": ratio <= targeted_budget,
        "within_matrix": ratio <= matrix_budget,
    }
