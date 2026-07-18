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


def _sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def _git(repo: Path, *args: str) -> str:
    proc = subprocess.run(["git", *args], cwd=repo, capture_output=True, text=True)
    return proc.stdout.strip() if proc.returncode == 0 else ""


def _median(metric) -> float | None:
    if isinstance(metric, dict) and metric.get("median") is not None:
        return float(metric["median"])
    return None


def _lane_summary(lane: dict) -> dict:
    metrics = lane.get("metrics", {})
    telemetry = lane.get("backend_telemetry", {}) or {}
    prove_s = _median(metrics.get("prove_seconds"))
    rss_kib = _median(metrics.get("peak_rss_kib"))
    out = {
        "prove_ms": round(prove_s * 1000.0, 6) if prove_s is not None else None,
        "native_mhz": _median(metrics.get("native_mhz")),
        "request_ms": (
            round(_median(metrics.get("request_seconds")) * 1000.0, 6)
            if _median(metrics.get("request_seconds")) is not None else None
        ),
        "peak_rss_mib": round(rss_kib / 1024.0, 2) if rss_kib is not None else None,
    }
    # Per-proof counters live in the per-sample telemetry records.
    samples = telemetry.get("samples") or []
    first = samples[0] if samples and isinstance(samples[0], dict) else {}
    fallbacks = first.get("cpu_fallbacks")
    if fallbacks is not None:
        out["cpu_fallbacks_per_proof"] = fallbacks
    dispatches = first.get("metal_dispatches")
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
    report_path = repo / "vectors/reports/benchmark_history" / matrix_runs[latest_id]["report"]["path"]
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
    return {
        "cpu_fallbacks_per_proof_median": sorted(fallbacks)[len(fallbacks) // 2],
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
    for sub in sorted(p for p in subs_dir.iterdir() if p.is_dir()):
        row = by_id.get(sub.name)
        title = None
        note = sub / "note.md"
        if note.exists():
            first = note.read_text().lstrip().splitlines()[0]
            title = first.lstrip("# ").strip() or None
        out.append({
            "id": sub.name,
            "title": title,
            "outcome": row.values.get("outcome") if row else "pending",
            "judged_r": row.judged_r if row else None,
        })
    return out


def build_feed(manifest: Manifest) -> dict:
    repo = manifest.root
    rows = ledger.load(repo)
    history_index_path = repo / "vectors/reports/benchmark_history/index.json"
    history = (
        json.loads(history_index_path.read_text()) if history_index_path.exists() else {}
    )
    latest = _latest_matrix(repo, history)
    epoch = ledger.current_epoch(repo)

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

    head = _git(repo, "rev-parse", "HEAD")
    head_time = _git(repo, "show", "-s", "--format=%cI", "HEAD")

    return {
        "feed_schema_version": FEED_SCHEMA_VERSION,
        "project": {
            "slug": "stwo-zig",
            "name": "Stwo in Zig with Metal",
            "harness": "stwo-perf",
            "contract": manifest.raw["harness"]["contract"],
        },
        "provenance": {
            "repo_commit": head[:12] if head else None,
            "repo_commit_time": head_time or None,
            "inputs_sha256": inputs,
            "determinism": "same commit + same inputs => byte-identical feed",
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
        "notes_count": len(list((repo / "autoresearch" / "notes").glob("*.md"))) - 1,
    }


def encode(feed: dict) -> bytes:
    return (json.dumps(feed, indent=1, sort_keys=True) + "\n").encode()


def write_feed(manifest: Manifest, out_path: Path | None = None) -> Path:
    out = out_path or (manifest.root / "autoresearch" / "site" / "feed.json")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(encode(build_feed(manifest)))
    return out
