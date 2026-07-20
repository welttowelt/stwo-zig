"""Append-only promotions ledger: parse, validate, append, and query."""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

SCHEMA_VERSION = 2

# v1 column set — frozen forever as the file header (the file is append-only,
# so the header can never change; later versions extend rows, not the header).
COLUMNS = [
    "schema_version", "harness_commit", "epoch", "judged_at_utc", "commit",
    "scope", "board", "workload_class", "outcome", "judged_r", "ci_low",
    "ci_high", "prove_ms", "native_mhz", "peak_rss_mib", "waits", "dispatches",
    "energy_j", "gates", "holdout", "submission_id", "predecessor", "supersedes",
]

# v2 appends verdict_kind: `judged` (signed judge verdict) or `claimed`
# (maintainer-adjudicated optimistic promotion; superseded by a judged row).
COLUMNS_V2 = COLUMNS + ["verdict_kind"]

_COLUMNS_BY_VERSION = {1: COLUMNS, 2: COLUMNS_V2}

VERDICT_KINDS = ("judged", "claimed")

OUTCOMES = ("promoted", "neutral", "rejected")

# Scoring boards (schema/scoring.md). Kernel results never enter the ledger.
BOARDS = (
    "core_cpu", "core_hybrid", "core_metal",
    "heavy_native", "heavy_cairo", "stream", "riscv",
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
        try:
            version = int(cells[0])
        except ValueError as exc:
            raise LedgerError(f"line {lineno}: schema_version is not an integer") from exc
        columns = _COLUMNS_BY_VERSION.get(version)
        if columns is None:
            raise LedgerError(f"line {lineno}: unknown schema_version {version}")
        if len(cells) != len(columns):
            raise LedgerError(
                f"line {lineno}: schema v{version} expects {len(columns)} columns, "
                f"got {len(cells)}"
            )
        values: dict = dict(zip(columns, cells))
        for col in _FLOAT_COLS:
            try:
                values[col] = float(values[col])
            except ValueError as exc:
                raise LedgerError(f"line {lineno}: column {col} is not a number") from exc
        for col in _OPT_FLOAT_COLS:
            values[col] = float(values[col]) if values[col] not in ("", "-") else None
        values["schema_version"] = version
        values["epoch"] = int(values["epoch"])
        if version == 1:
            # v1 predates the column; only the judge ever appended v1 rows.
            values["verdict_kind"] = "judged"
        elif values["verdict_kind"] not in VERDICT_KINDS:
            raise LedgerError(
                f"line {lineno}: verdict_kind must be one of {VERDICT_KINDS}"
            )
        rows.append(Row(values))
    return rows


def load(repo_root: Path) -> list[Row]:
    return parse(ledger_path(repo_root).read_text())


def serialize_row(values: dict) -> str:
    try:
        columns = _COLUMNS_BY_VERSION[int(values["schema_version"])]
    except (KeyError, ValueError) as exc:
        raise LedgerError("row schema_version is missing or unknown") from exc
    cells = []
    for col in columns:
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
    missing = [c for c in COLUMNS_V2 if c not in values]
    if missing:
        raise LedgerError(f"row missing columns: {missing}")
    if int(values["schema_version"]) != SCHEMA_VERSION:
        raise LedgerError("appends must use the current schema_version")
    if values.get("verdict_kind") not in VERDICT_KINDS:
        raise LedgerError(f"verdict_kind must be one of {VERDICT_KINDS}")
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


def aa_dispersion(repo_root: Path, board: str, workload_class: str) -> float | None:
    by_board = current_epoch(repo_root).get("aa_dispersion", {})
    value = by_board.get(board, {}).get(workload_class)
    return float(value) if value is not None else None
