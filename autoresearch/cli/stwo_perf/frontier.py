"""Pareto frontier and anchor-drift budgets, computed from the ledger only."""

from __future__ import annotations

from dataclasses import dataclass

from . import ledger


@dataclass(frozen=True)
class FrontierView:
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
    superseded_keys = {r.supersedes for r in rows if r.supersedes}
    out = []
    for row in rows:
        key = f"{row.judged_at_utc}+{row.commit}"
        if key in superseded_keys:
            continue
        if row.values.get("outcome") != "promoted":
            continue
        out.append(row)
    return out


def view(rows: list[ledger.Row], workload_class: str) -> FrontierView:
    eligible = [r for r in effective_rows(rows) if r.workload_class == workload_class]
    frontier = [
        r for r in eligible
        if not any(o is not r and _dominates(o, r) for o in eligible)
    ]
    superseded = [r for r in eligible if r not in frontier]
    head = eligible[-1] if eligible else None
    return FrontierView(workload_class, frontier, superseded, head)


def drift_vs_anchor(
    rows: list[ledger.Row],
    workload_class: str,
    anchor_prove_ms: float,
    matrix_budget: float,
    targeted_budget: float,
) -> dict:
    """Cumulative drift of the class HEAD against the frozen anchor.

    Budgets are fixed against the anchor, never the predecessor: after any
    promotion no cell may sit worse than anchor x budget.
    """
    v = view(rows, workload_class)
    if v.head is None:
        return {"head": None, "ratio": None, "within_targeted": True, "within_matrix": True}
    ratio = v.head.prove_ms / anchor_prove_ms
    return {
        "head": v.head,
        "ratio": ratio,
        "within_targeted": ratio <= targeted_budget,
        "within_matrix": ratio <= matrix_budget,
    }
