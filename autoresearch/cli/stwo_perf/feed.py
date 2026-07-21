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

from . import frontier, ledger, metrics, search_health
from .manifest import Manifest

FEED_SCHEMA_VERSION = 3

REQUEST_RESOURCE_KEYS = {
    "measurement_scope",
    "source",
    "measured_warmups",
    "measured_samples",
    "lifetime_peak_physical_footprint_bytes",
    "energy_nj",
    "instructions",
    "cycles",
    "canonical_proof_bytes",
    "complete",
    "unavailable_reason",
}

# Input roots whose uncommitted changes make a feed provenance-dishonest.
INPUT_ROOTS = (
    "autoresearch/MANIFEST.json",
    "autoresearch/ledger",
    "autoresearch/reference",
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


def _request_resources(lane: dict) -> dict | None:
    resources = lane.get("request_resources")
    if resources is None:
        return None
    if not isinstance(resources, dict) or set(resources) != REQUEST_RESOURCE_KEYS:
        raise FeedError("matrix lane request_resources has the wrong schema")
    if resources["measurement_scope"] != "verified_process_request_batch":
        raise FeedError("matrix lane request_resources has an invalid scope")
    warmups = resources["measured_warmups"]
    samples = resources["measured_samples"]
    if type(warmups) is not int or warmups < 0:
        raise FeedError("matrix lane request resource warmups must be nonnegative")
    if type(samples) is not int or samples <= 0:
        raise FeedError("matrix lane request resource samples must be positive")
    proof = lane.get("proof")
    proof_bytes = proof.get("bytes") if isinstance(proof, dict) else None
    if type(proof_bytes) is not int or resources["canonical_proof_bytes"] != proof_bytes:
        raise FeedError("matrix lane request resource proof bytes disagree")

    complete = resources["complete"]
    counters = (
        "lifetime_peak_physical_footprint_bytes",
        "energy_nj",
        "instructions",
        "cycles",
    )
    if type(complete) is not bool:
        raise FeedError("matrix lane request resource completeness must be boolean")
    if complete:
        if (
            resources["source"] != "darwin_proc_pid_rusage_v6"
            or resources["unavailable_reason"] is not None
        ):
            raise FeedError("matrix lane complete request resource source is invalid")
        if any(
            type(resources[counter]) is not int or resources[counter] <= 0
            for counter in counters
        ):
            raise FeedError("matrix lane complete request resource counters are invalid")
    else:
        reason = resources["unavailable_reason"]
        if resources["source"] != "unsupported":
            raise FeedError("matrix lane incomplete request resource source is invalid")
        if not isinstance(reason, str) or not reason.strip():
            raise FeedError("matrix lane incomplete request resource reason is missing")
        if any(resources[counter] is not None for counter in counters):
            raise FeedError("matrix lane unsupported request resource counters must be null")
    return dict(resources)


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
    request_resources = _request_resources(lane)
    if request_resources is not None:
        out["request_resources"] = request_resources
    return out


def _matrix_run_ids(index: dict) -> list[str]:
    runs = index.get("runs", {})
    return sorted(
        rid for rid, entry in runs.items()
        if isinstance(entry.get("kind"), str) and "matrix" in entry["kind"]
    )  # run ids sort chronologically by construction


def _latest_matrix(repo: Path, index: dict) -> dict | None:
    ids = _matrix_run_ids(index)
    return _matrix_from_run(repo, index, ids[-1]) if ids else None


def _baseline_matrix(repo: Path, index: dict) -> dict | None:
    """The earliest committed matrix run: the fixed pre-optimization reference
    vector that suite-level ratios are computed against (consumers pair
    workloads by name across baseline and latest and aggregate per-workload
    time ratios by geometric mean — the vector-toward-origin reading)."""
    ids = _matrix_run_ids(index)
    return _matrix_from_run(repo, index, ids[0]) if ids else None


def _matrix_from_run(repo: Path, index: dict, run_id: str) -> dict:
    latest_id = run_id
    entry = index["runs"][run_id]["report"]
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


def _promotion_scope(manifest: Manifest) -> dict:
    """The decided benchmark set: which boards a workload group actually owns.

    Boards absent here exist only as future scoring universe (schema/scoring.md);
    consumers must render them as out-of-scope, never as empty-but-live."""
    groups = {}
    for group in manifest.groups():
        groups[group.group_id] = {
            "board": group.board,
            "enabled": group.enabled,
            "disabled_reason": group.disabled_reason,
            "report_schema": group.report_schema,
            "workloads": {
                w.workload_id: {"class": w.workload_class, "native_unit": w.native_unit}
                for w in group.workloads
            },
        }
    owned = sorted({g.board for g in manifest.groups()})
    return {
        "class_registry": {
            cls.name: {
                "scored": cls.scored,
                "resource_profile": cls.resource_profile,
                "command_timeout_seconds": cls.command_timeout_seconds,
                "wall_clock_cap_seconds": cls.wall_clock_cap_seconds,
                "sampling": cls.sampling,
            }
            for cls in manifest.classes()
        },
        "groups": groups,
        "owned_boards": owned,
        "future_boards": sorted(set(ledger.BOARDS) - set(owned)),
        "baselines": {
            "riscv": "vectors/reports/riscv_baselines/",
            "core_cpu": "vectors/reports/benchmark_history/",
        },
    }


def _audit_age(repo: Path, base_commit: str) -> dict:
    try:
        commits = int(_git(repo, "rev-list", "--count", f"{base_commit}..HEAD"))
        base_time = int(_git(repo, "show", "-s", "--format=%ct", base_commit))
        head_time = int(_git(repo, "show", "-s", "--format=%ct", "HEAD"))
    except (FeedError, ValueError) as exc:
        return {
            "base_commit": base_commit,
            "commits": None,
            "seconds": None,
            "unavailable_reason": "audit_base_not_present_in_repository_history",
        }
    return {
        "base_commit": base_commit,
        "commits": commits,
        "seconds": max(0, head_time - base_time),
    }


def _audit_state(
    repo: Path,
    rows: list[ledger.Row],
    epoch_spec: dict,
    board: str,
    workload_class: str,
) -> dict:
    policy = metrics.policy_from_epoch(epoch_spec)
    state = metrics.audit_projection(
        rows,
        int(epoch_spec["epoch"]),
        board,
        workload_class,
        policy=policy,
    )
    evidence_total = state.claimed_observations + state.judged_observations
    coverage = state.neutral_observations
    return {
        "effective_score": state.effective_score,
        "audited_score": state.audited_score,
        "audited_through": state.audited_through,
        "audit_age": _audit_age(repo, state.audit_base),
        "unaudited_tail": {
            "count": len(state.unaudited_tail),
            "observation_ids": list(state.unaudited_tail),
        },
        "due": {
            "span": state.span_due,
            "span_reasons": list(state.span_reasons),
            "direct": state.direct_due,
        },
        "overdue": {
            "span": state.span_overdue_by > 0,
            "span_by_observations": state.span_overdue_by,
            "direct": state.direct_overdue_by > 0,
            "direct_by_observations": state.direct_overdue_by,
        },
        "span_coverage": {
            "eligible": coverage,
            "consumed": state.span_consumed,
            "pending": state.span_pending,
            "share": state.span_consumed / coverage if coverage else None,
        },
        "evidence_share": {
            "claimed": state.claimed_observations,
            "judged": state.judged_observations,
            "claimed_share": (
                state.claimed_observations / evidence_total if evidence_total else None
            ),
            "judged_share": (
                state.judged_observations / evidence_total if evidence_total else None
            ),
        },
    }


def _boards(
    repo: Path,
    manifest: Manifest,
    rows: list[ledger.Row],
    epoch_spec: dict,
) -> dict:
    epoch = int(epoch_spec["epoch"])
    metrics_policy = metrics.policy_from_epoch(epoch_spec)
    boards: dict = {}
    owned_boards = {group.board for group in manifest.groups()}
    for board in ledger.BOARDS:
        board_rows = [r for r in rows if r.values.get("board") == board]
        entries = [r.values for r in board_rows]
        board_frontier = {}
        classes = (
            manifest.class_names(
                board=board, scored_only=True, include_disabled=True,
            )
            if board in owned_boards else []
        )
        for cls in classes:
            view = frontier.view(board_rows, board, cls)
            board_frontier[cls] = {
                "head": view.head.values if view.head else None,
                "frontier": [r.values for r in view.frontier],
                "audit": _audit_state(
                    repo, rows, epoch_spec, board, cls,
                ),
            }
        boards[board] = {
            "entries": entries,
            "scored_classes": classes,
            "suite_score": (
                metrics.board_suite_score(
                    rows, epoch, board, classes, policy=metrics_policy,
                )
                if classes else None
            ),
            "frontier_by_class": board_frontier,
        }
    return boards


def _submissions(repo: Path, rows: list[ledger.Row]) -> list[dict]:
    # A submission may carry one row per moved class; headline with its
    # strongest ratio and prefer a promoted outcome.
    by_id: dict[str, ledger.Row] = {}
    for r in rows:
        current = by_id.get(r.submission_id)
        if current is None or r.judged_r < current.judged_r:
            by_id[r.submission_id] = r
    out = []
    subs_dir = repo / "autoresearch" / "submissions"
    if not subs_dir.is_dir():
        return out
    for sub in sorted(p for p in subs_dir.iterdir() if p.is_dir()):
        row = by_id.get(sub.name)
        title = None
        note_text = None
        note = sub / "note.md"
        if note.exists():
            note_text = note.read_text()
            lines = note_text.lstrip().splitlines()
            title = lines[0].lstrip("# ").strip() or None if lines else None
        record = {
            "id": sub.name,
            "title": title,
            "outcome": row.values.get("outcome") if row else "pending",
            "judged_r": row.judged_r if row else None,
            "verdict_kind": row.values.get("verdict_kind") if row else None,
            "workload_class": row.values.get("workload_class") if row else None,
            "solver": _solver(repo, sub.name),
            "note": note_text,
            "transcripts": _transcripts(sub),
        }
        span = _span_constituents(sub)
        if span:
            record["span_constituents"] = span
        out.append(record)
    return out


def _span_constituents(sub: Path) -> list[str] | None:
    """A combined-span verdict credits several individually-undetectable
    submissions as one measured delta; the site squashes them into one
    leaderboard entry using this list."""
    for verdict_path in sorted(sub.glob("verdict-*.json")):
        try:
            constituents = json.loads(verdict_path.read_text()).get("span_constituents")
        except (json.JSONDecodeError, OSError):
            continue
        if constituents:
            return [str(c) for c in constituents]
    return None


def _solver(repo: Path, submission_id: str) -> str | None:
    """Attribution from the repository itself: the mailmapped author of the
    commit that landed the submission directory (.mailmap maps working emails
    to canonical GitHub noreply identities — committed source of truth, no
    network lookups). Noreply addresses yield the exact login; otherwise the
    author name is the honest attribution."""
    out = _git(
        repo, "log", "--reverse", "--format=%aN%x00%aE", "--",
        f"autoresearch/submissions/{submission_id}",
    ).splitlines()
    if not out:
        return None
    name, _, email = out[0].partition("\x00")
    if email.endswith("@users.noreply.github.com"):
        local = email.split("@", 1)[0]
        return local.split("+", 1)[1] if "+" in local else local
    return name or None


_TRANSCRIPT_EXCERPT_CHARS = 700


def _transcripts(sub: Path) -> list[dict]:
    """Digest-bound transcript refs with a short leading excerpt; the full
    sanitized files stay in the repository as the source of truth."""
    delta_path = sub / "delta.json"
    if not delta_path.is_file():
        return []
    try:
        delta = json.loads(delta_path.read_text())
    except json.JSONDecodeError:
        return []
    refs = []
    for tpath, meta in sorted(delta.get("transcripts", {}).items()):
        file_path = sub / tpath
        excerpt = None
        if file_path.is_file():
            try:
                excerpt = file_path.read_text(errors="replace")[:_TRANSCRIPT_EXCERPT_CHARS]
            except OSError:
                excerpt = None
        refs.append({
            "label": tpath.split("/", 1)[-1],
            "sha256": meta.get("sha256"),
            "captured_by": meta.get("captured_by", "submitter"),
            "excerpt": excerpt,
        })
    return refs


def _references(repo: Path) -> dict:
    """Committed external reference measurements (autoresearch/reference/*.json)
    — e.g. the peer-Rust prover on the matched suite. Passed through verbatim;
    consumers must render the recorded method caveats with the numbers."""
    ref_dir = repo / "autoresearch" / "reference"
    if not ref_dir.is_dir():
        return {}
    out = {}
    paths = [
        path for path in sorted(ref_dir.glob("*.json"))
        if not path.name.endswith(".schema.json")
    ]
    paths.extend(sorted((ref_dir / "peer-series" / "runs").glob("*.json")))
    for path in paths:
        try:
            document = json.loads(path.read_text())
        except json.JSONDecodeError as exc:
            raise FeedError(f"reference file {path.name} is not valid JSON: {exc}")
        _validate_reference(path, document)
        if path.parent.name == "runs":
            key = "peer_series_run_" + path.stem.replace("-", "_")
        else:
            key = path.stem.replace("-", "_")
        if key in out:
            raise FeedError(f"duplicate reference key {key}")
        out[key] = document
    return out


def _validate_reference(path: Path, document: dict) -> None:
    kind = document.get("reference_kind")
    if kind == "upstream-rust-backend":
        name = document.get("name")
        rust = document.get("rust_reference", {})
        actual = (rust.get("backend_id"), rust.get("backend_type"))
        expected = {
            "peer-rust-scalar": (
                "cpu-scalar",
                "stwo::prover::backend::cpu::CpuBackend",
            ),
            "peer-rust-simd": (
                "simd",
                "stwo::prover::backend::simd::SimdBackend",
            ),
        }.get(name)
        if expected is None or actual != expected:
            raise FeedError(
                f"reference file {path.name} backend identity mismatch: "
                f"name={name!r}, backend={actual!r}"
            )
    elif kind == "peer-relative-series":
        peer = document.get("peer_source", {})
        if (
            peer.get("repository") != "https://github.com/ClementWalter/stwo"
            or peer.get("commit") != "07ea1ccca13351028da94e66babf79e7ce91437f"
        ):
            raise FeedError(f"reference file {path.name} peer source pin mismatch")
    elif document.get("schema") == "peer-relative-wide-fibonacci-series-point-v1":
        peer = document.get("peer_source", {})
        if (
            peer.get("repository") != "https://github.com/ClementWalter/stwo"
            or peer.get("commit") != "07ea1ccca13351028da94e66babf79e7ce91437f"
        ):
            raise FeedError(f"reference file {path.name} peer series pin mismatch")
        if [size.get("log_n_rows") for size in document.get("sizes", [])] != [14, 16, 18, 20]:
            raise FeedError(f"reference file {path.name} peer series size vector mismatch")


def _reference_input_files(repo: Path) -> list[Path]:
    ref_dir = repo / "autoresearch" / "reference"
    if not ref_dir.is_dir():
        return []
    paths = sorted(ref_dir.glob("*.json"))
    paths.extend(sorted((ref_dir / "peer-series" / "runs").glob("*.json")))
    return paths


def _notes_count(repo: Path) -> int:
    notes_dir = repo / "autoresearch" / "notes"
    if not notes_dir.is_dir():
        return 0
    return sum(1 for p in notes_dir.glob("*.md") if p.name != "README.md")


def _credited_log_effect(repo: Path, row) -> float:
    """Resolve row credit through Metrics v2 without coupling feed input APIs."""
    try:
        from . import metrics

        epoch = ledger.known_epochs(repo)[int(row.epoch)]
        policy = metrics.policy_from_epoch(epoch)
        return float(metrics.credited_log_effect(row, policy.shrinkage_lambda))
    except Exception as exc:
        raise search_health.SearchHealthError(
            f"credited log effect is unavailable for row {getattr(row, 'row_id', '?')}: {exc}"
        ) from exc


def build_search_health(manifest: Manifest, rows: list[ledger.Row]) -> dict:
    """Build the W10 projection from explicit row and verdict inputs."""
    try:
        return search_health.projection(
            manifest,
            rows,
            search_health.load_verdicts_by_evidence(manifest.root),
            credited_log_effect_fn=lambda row: _credited_log_effect(
                manifest.root, row
            ),
        )
    except search_health.SearchHealthError as exc:
        raise FeedError(f"cannot publish search health: {exc}") from exc


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
    baseline = _baseline_matrix(repo, history)
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
    submissions = repo / "autoresearch" / "submissions"
    if submissions.is_dir():
        for path in sorted(submissions.glob("*/*verdict*.json")):
            rel = path.relative_to(repo).as_posix()
            inputs[rel] = _sha256_file(path)
    inputs.update(extra_inputs)
    for path in _reference_input_files(repo):
        rel = str(path.relative_to(repo))
        inputs[rel] = _sha256_file(path)

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
        "promotion_scope": _promotion_scope(manifest),
        "boards": _boards(repo, manifest, rows, epoch),
        "search_health": build_search_health(manifest, rows),
        "metal_resident_progress": _metal_progress(latest),
        "latest_matrix": latest,
        "baseline_matrix": baseline,
        "references": _references(repo),
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
