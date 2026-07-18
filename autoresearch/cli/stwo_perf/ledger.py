"""Append-only promotions ledger: parse, validate, append, and query."""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

SCHEMA_VERSION = 1

COLUMNS = [
    "schema_version", "harness_commit", "epoch", "judged_at_utc", "commit",
    "scope", "board", "workload_class", "outcome", "judged_r", "ci_low",
    "ci_high", "prove_ms", "native_mhz", "peak_rss_mib", "waits", "dispatches",
    "energy_j", "gates", "holdout", "submission_id", "predecessor", "supersedes",
]

OUTCOMES = ("promoted", "neutral", "rejected")

# Scoring boards (schema/scoring.md). Kernel results never enter the ledger.
BOARDS = (
    "core_cpu", "core_hybrid", "core_metal",
    "heavy_native", "heavy_cairo", "stream",
)

_FLOAT_COLS = {"judged_r", "ci_low", "ci_high", "prove_ms", "native_mhz", "peak_rss_mib"}
_OPT_FLOAT_COLS = {"waits", "dispatches", "energy_j"}


class LedgerError(RuntimeError):
    pass


@dataclass(frozen=True)
class Row:
    values: dict

    def __getattr__(self, name: str):
        try:
            return self.values[name]
        except KeyError as exc:
            raise AttributeError(name) from exc

    @property
    def gates_passed(self) -> bool:
        return self.values["gates"] == "G1..G5:pass"


def ledger_path(repo_root: Path) -> Path:
    return repo_root / "autoresearch" / "ledger" / "promotions.tsv"


def epochs_path(repo_root: Path) -> Path:
    return repo_root / "autoresearch" / "ledger" / "epochs.json"


def parse(text: str) -> list[Row]:
    lines = [ln for ln in text.splitlines() if ln.strip()]
    if not lines:
        raise LedgerError("ledger is empty (missing header)")
    header = lines[0].split("\t")
    if header != COLUMNS:
        raise LedgerError(
            "ledger header does not match schema v1; rows must be read per their "
            f"own schema_version (got {len(header)} columns)"
        )
    rows = []
    for lineno, line in enumerate(lines[1:], start=2):
        cells = line.split("\t")
        if len(cells) != len(COLUMNS):
            raise LedgerError(f"line {lineno}: expected {len(COLUMNS)} columns, got {len(cells)}")
        values: dict = dict(zip(COLUMNS, cells))
        for col in _FLOAT_COLS:
            try:
                values[col] = float(values[col])
            except ValueError as exc:
                raise LedgerError(f"line {lineno}: column {col} is not a number") from exc
        for col in _OPT_FLOAT_COLS:
            values[col] = float(values[col]) if values[col] not in ("", "-") else None
        values["schema_version"] = int(values["schema_version"])
        values["epoch"] = int(values["epoch"])
        rows.append(Row(values))
    return rows


def load(repo_root: Path) -> list[Row]:
    return parse(ledger_path(repo_root).read_text())


def serialize_row(values: dict) -> str:
    cells = []
    for col in COLUMNS:
        v = values.get(col)
        if v is None:
            cells.append("")
        elif isinstance(v, float):
            cells.append(f"{v:.6f}")
        else:
            cells.append(str(v))
        if "\t" in cells[-1] or "\n" in cells[-1]:
            raise LedgerError(f"column {col} contains a separator character")
    return "\t".join(cells)


def append(repo_root: Path, values: dict) -> None:
    """Append one row after validating schema, epoch, and time ordering."""
    missing = [c for c in COLUMNS if c not in values]
    if missing:
        raise LedgerError(f"row missing columns: {missing}")
    if int(values["schema_version"]) != SCHEMA_VERSION:
        raise LedgerError("appends must use the current schema_version")
    if values.get("outcome") not in OUTCOMES:
        raise LedgerError(f"outcome must be one of {OUTCOMES}")
    if values.get("board") not in BOARDS:
        raise LedgerError(f"board must be one of {BOARDS}")
    epochs = known_epochs(repo_root)
    if int(values["epoch"]) not in epochs:
        raise LedgerError(f"unknown epoch {values['epoch']}; open it in epochs.json first")
    rows = load(repo_root)
    if rows and str(values["judged_at_utc"]) < str(rows[-1].judged_at_utc):
        raise LedgerError("judged_at_utc must be monotonically non-decreasing")
    with ledger_path(repo_root).open("a") as fh:
        fh.write(serialize_row(values) + "\n")


def verify_append_only(base_text: str, head_text: str) -> None:
    """CI check: head must equal base plus zero or more appended rows."""
    if not head_text.startswith(base_text):
        raise LedgerError(
            "ledger is not append-only versus the base revision: existing rows "
            "were edited, reordered, or removed"
        )
    parse(head_text)


def known_epochs(repo_root: Path) -> dict[int, dict]:
    data = json.loads(epochs_path(repo_root).read_text())
    return {int(e["epoch"]): e for e in data["epochs"]}


def current_epoch(repo_root: Path) -> dict:
    epochs = known_epochs(repo_root)
    return epochs[max(epochs)]


def aa_dispersion(repo_root: Path, workload_class: str) -> float | None:
    value = current_epoch(repo_root).get("aa_dispersion", {}).get(workload_class)
    return float(value) if value is not None else None
