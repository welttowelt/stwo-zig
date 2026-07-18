"""Site feed: compile every checked-in evidence source into one JSON file.

This is the publication contract between the repository and any website:
`stwo-perf feed` reads only committed sources of truth (MANIFEST, the
promotions ledger, epochs, the benchmark history archive, submissions,
notes) and emits a deterministic `autoresearch/site/feed.json` — same
commit, same bytes. The schema is documented in schema/site-feed.md and is
project-generic; stwo-zig is its first producer.
"""

from __future__ import annotations

import hashlib
import json
import subprocess
from pathlib import Path

from . import frontier, ledger
from .manifest import Manifest

FEED_SCHEMA_VERSION = 1
CLASSES = ("small", "wide", "deep")

# Input roots whose uncommitted changes make a feed provenance-dishonest.
INPUT_ROOTS = (
    "autoresearch/MANIFEST.json",
    "autoresearch/ledger",
    "autoresearch/submissions",
    "autoresearch/notes",
    "vectors/reports/benchmark_history",
)


class FeedError(RuntimeError):
    pass


def _sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def _git(repo: Path, *args: str) -> str:
    proc = subprocess.run(["git", *args], cwd=repo, capture_output=True, text=True)
    if proc.returncode != 0:
        raise FeedError(f"git {' '.join(args)} failed: {proc.stderr.strip()[:200]}")
    return proc.stdout.strip()


def dirty_inputs(repo: Path) -> list[str]:
    """Input paths with uncommitted changes; publishing them under HEAD's
    commit hash would be a provenance lie (contract guarantee 1).

    Parses raw porcelain output: the two status columns may legitimately be
    spaces, so the line must not be stripped before slicing.
    """
    proc = subprocess.run(
        ["git", "status", "--porcelain"], cwd=repo, capture_output=True, text=True
    )
    if proc.returncode != 0:
        raise FeedError(f"git status failed: {proc.stderr.strip()[:200]}")
    dirty = []
    for line in proc.stdout.splitlines():
        if len(line) < 4:
            continue
        path = line[3:].strip().strip('"')
        if any(path == root or path.startswith(root + "/") for root in INPUT_ROOTS):
            dirty.append(path)
    return sorted(dirty)


def _median(metric) -> float | None:
    if isinstance(metric, dict) and metric.get("median") is not None:
        return float(metric["median"])
    return None


def _sample_counter(telemetry: dict, key: str) -> float | None:
    """Median of a per-sample counter across all sample records."""
    import statistics
    values = [
        s[key] for s in (telemetry.get("samples") or [])
        if isinstance(s, dict) and isinstance(s.get(key), (int, float))
    ]
    return statistics.median(values) if values else None


def _lane_summary(lane: dict) -> dict:
    metrics = lane.get("metrics", {})
    telemetry = lane.get("backend_telemetry", {}) or {}
    prove_s = _median(metrics.get("prove_seconds"))
    request_s = _median(metrics.get("request_seconds"))
    rss_kib = _median(metrics.get("peak_rss_kib"))
    out = {
        "prove_ms": round(prove_s * 1000.0, 6) if prove_s is not None else None,
        "native_mhz": _median(metrics.get("native_mhz")),
        "request_ms": round(request_s * 1000.0, 6) if request_s is not None else None,
        "peak_rss_mib": round(rss_kib / 1024.0, 2) if rss_kib is not None else None,
    }
    fallbacks = _sample_counter(telemetry, "cpu_fallbacks")
    if fallbacks is not None:
        out["cpu_fallbacks_per_proof"] = fallbacks
    dispatches = _sample_counter(telemetry, "metal_dispatches")
    if dispatches is not None:
        out["metal_dispatches_per_proof"] = dispatches
    return out


def _latest_matrix(repo: Path, index: dict) -> dict | None:
    runs = index.get("runs", {})
    matrix_runs = {
        rid: entry for rid, entry in runs.items()
        if isinstance(entry.get("kind"), str) and "matrix" in entry["kind"]
    }
    if not matrix_runs:
        return None
    latest_id = max(matrix_runs)  # run ids sort chronologically by construction
    entry = matrix_runs[latest_id]["report"]
    report_path = repo / "vectors/reports/benchmark_history" / entry["path"]
    if not report_path.is_file():
        raise FeedError(f"history index names a missing report: {entry['path']}")
    actual = _sha256_file(report_path)
    if entry.get("sha256") and actual != entry["sha256"]:
        raise FeedError(f"report digest mismatch for run {latest_id}: index says "
                        f"{entry['sha256'][:12]}, file is {actual[:12]}")
    report = json.loads(report_path.read_text())
    rows = []
    for row in report.get("rows", []):
        workload = row.get("workload", {})
        rows.append({
            "name": workload.get("name"),
            "parameters": workload.get("parameters"),
            "native_unit": workload.get("native_unit"),
            "native_units": workload.get("native_units"),
            "committed_trace_cells": workload.get("committed_trace_cells"),
            "headline_eligible": row.get("headline_eligible"),
            "proof_parity": row.get("proof_parity"),
            "proof_bytes": row.get("proof_bytes"),
            "lanes": {
                lane_name: _lane_summary(lane)
                for lane_name, lane in row.get("lanes", {}).items()
            },
        })
    return {
        "run_id": latest_id,
        "protocol": report.get("protocol"),
        "generated_at": report.get("generated_at"),
        "repo_commit": report.get("configuration", {}).get("provenance", {}).get("git_commit"),
        "rows": rows,
    }


def _metal_progress(latest_matrix: dict | None) -> dict | None:
    """Board-4 progress metrics: fallbacks trending to zero."""
    if not latest_matrix:
        return None
    fallbacks = [
        row["lanes"]["metal"].get("cpu_fallbacks_per_proof")
        for row in latest_matrix["rows"]
        if "metal" in row.get("lanes", {})
    ]
    fallbacks = [f for f in fallbacks if isinstance(f, (int, float))]
    if not fallbacks:
        return None
    import statistics
    return {
        "cpu_fallbacks_per_proof_median": statistics.median(fallbacks),
        "rows_with_zero_fallbacks": sum(1 for f in fallbacks if f == 0),
        "rows_total": len(fallbacks),
    }


def _boards(repo: Path, rows: list[ledger.Row]) -> dict:
    boards: dict = {}
    for board in ledger.BOARDS:
        board_rows = [r for r in rows if r.values.get("board") == board]
        entries = [r.values for r in board_rows]
        board_frontier = {}
        for cls in CLASSES:
            view = frontier.view(board_rows, cls)
            board_frontier[cls] = {
                "head": view.head.values if view.head else None,
                "frontier": [r.values for r in view.frontier],
            }
        boards[board] = {"entries": entries, "frontier_by_class": board_frontier}
    return boards


def _submissions(repo: Path, rows: list[ledger.Row]) -> list[dict]:
    by_id = {r.submission_id: r for r in rows}
    out = []
    subs_dir = repo / "autoresearch" / "submissions"
    if not subs_dir.is_dir():
        return out
    for sub in sorted(p for p in subs_dir.iterdir() if p.is_dir()):
        row = by_id.get(sub.name)
        title = None
        note = sub / "note.md"
        if note.exists():
            lines = note.read_text().lstrip().splitlines()
            title = lines[0].lstrip("# ").strip() or None if lines else None
        out.append({
            "id": sub.name,
            "title": title,
            "outcome": row.values.get("outcome") if row else "pending",
            "judged_r": row.judged_r if row else None,
        })
    return out


def _notes_count(repo: Path) -> int:
    notes_dir = repo / "autoresearch" / "notes"
    if not notes_dir.is_dir():
        return 0
    return sum(1 for p in notes_dir.glob("*.md") if p.name != "README.md")


def build_feed(manifest: Manifest, allow_dirty: bool = False) -> dict:
    repo = manifest.root
    dirty = dirty_inputs(repo)
    if dirty and not allow_dirty:
        raise FeedError(
            "input paths have uncommitted changes; a feed would attribute them "
            f"to HEAD dishonestly: {dirty[:5]} (commit first, or pass allow_dirty "
            "for a feed explicitly marked dirty)"
        )
    rows = ledger.load(repo)
    history_index_path = repo / "vectors/reports/benchmark_history/index.json"
    history = (
        json.loads(history_index_path.read_text()) if history_index_path.exists() else {}
    )
    latest = _latest_matrix(repo, history)
    epoch = ledger.current_epoch(repo)
    extra_inputs = {}
    if latest is not None:
        run_entry = history.get("runs", {}).get(latest["run_id"], {}).get("report", {})
        if run_entry.get("path"):
            rel = "vectors/reports/benchmark_history/" + run_entry["path"]
            extra_inputs[rel] = _sha256_file(repo / rel)

    inputs = {}
    for rel in (
        "autoresearch/MANIFEST.json",
        "autoresearch/ledger/promotions.tsv",
        "autoresearch/ledger/epochs.json",
        "vectors/reports/benchmark_history/index.json",
    ):
        path = repo / rel
        if path.exists():
            inputs[rel] = _sha256_file(path)
    inputs.update(extra_inputs)

    head = _git(repo, "rev-parse", "HEAD")
    head_time = _git(repo, "show", "-s", "--format=%cI", "HEAD")

    return {
        "feed_schema_version": FEED_SCHEMA_VERSION,
        "project": {
            "slug": "stwo-zig",
            "name": "Stwo in Zig with Metal",
            "harness": "stwo-perf",
            "contract": manifest.raw["harness"].get("contract"),
        },
        "provenance": {
            "repo_commit": head[:12] if head else None,
            "repo_commit_time": head_time or None,
            "dirty_inputs": dirty if dirty else [],
            "inputs_sha256": inputs,
            "determinism": (
                "pure function of the named inputs; a committed feed names the "
                "commit it was generated FROM (one-commit lag by construction) — "
                "verify via inputs_sha256, not commit equality"
            ),
        },
        "anchor": {
            "frozen": manifest.anchor_commit is not None,
            "commit": manifest.anchor_commit,
            "prove_ms": manifest.raw["harness"].get("anchor_prove_ms"),
        },
        "epoch": {
            "number": epoch["epoch"],
            "aa_dispersion": epoch.get("aa_dispersion"),
        },
        "boards": _boards(repo, rows),
        "metal_resident_progress": _metal_progress(latest),
        "latest_matrix": latest,
        "history": {
            "runs": [
                {"run_id": rid, "kind": e.get("kind"),
                 "report_sha256": e.get("report", {}).get("sha256"),
                 "bundle": e.get("bundle") is not None}
                for rid, e in sorted(history.get("runs", {}).items())
            ],
            "comparisons": len(history.get("comparisons", [])),
        },
        "submissions": _submissions(repo, rows),
        "notes_count": _notes_count(repo),
    }


def encode(feed: dict) -> bytes:
    return (json.dumps(feed, indent=1, sort_keys=True) + "\n").encode()


def write_feed(manifest: Manifest, out_path: Path | None = None,
               allow_dirty: bool = False) -> Path:
    out = out_path or (manifest.root / "autoresearch" / "site" / "feed.json")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(encode(build_feed(manifest, allow_dirty=allow_dirty)))
    return out
