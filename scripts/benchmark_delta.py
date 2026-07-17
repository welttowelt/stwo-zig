#!/usr/bin/env python3
"""Compare compatible benchmark reports and preserve their exact source bytes."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import tempfile
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator


DELTA_PROTOCOL = "benchmark_delta_v1"
DELTA_SCHEMA_VERSION = 1
ARCHIVE_SCHEMA_VERSION = 1
MAX_REPORT_BYTES = 128 * 1024 * 1024
UPSTREAM_PROTOCOL = "upstream_family_matrix_v1"
NATIVE_PROTOCOL = "native_proof_cross_backend_matrix_v3"
SUPPORTED_PROTOCOLS = {UPSTREAM_PROTOCOL, NATIVE_PROTOCOL}


class DeltaError(RuntimeError):
    """A report pair is invalid or cannot be compared safely."""


class IncompatibleReports(DeltaError):
    """Individually valid reports do not describe the same benchmark."""


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), allow_nan=False
    ).encode("utf-8")


def digest_json(value: Any) -> str:
    return hashlib.sha256(canonical_bytes(value)).hexdigest()


def atomic_write(path: Path, contents: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            dir=path.parent, prefix=f".{path.name}.", delete=False
        ) as temporary:
            temporary_path = Path(temporary.name)
            temporary.write(contents)
            temporary.flush()
            os.fsync(temporary.fileno())
        os.replace(temporary_path, path)
    except BaseException:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)
        raise


def encoded_json(document: dict[str, Any]) -> bytes:
    return (
        json.dumps(document, indent=2, sort_keys=True, allow_nan=False) + "\n"
    ).encode("utf-8")


def require_object(value: Any, context: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise DeltaError(f"{context} must be an object")
    return value


def require_list(value: Any, context: str) -> list[Any]:
    if not isinstance(value, list):
        raise DeltaError(f"{context} must be an array")
    return value


def require_number(value: Any, context: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise DeltaError(f"{context} must be numeric")
    result = float(value)
    if not math.isfinite(result) or result < 0:
        raise DeltaError(f"{context} must be finite and non-negative")
    return result


def optional_number(value: Any, context: str) -> float | None:
    if value is None:
        return None
    return require_number(value, context)


def nested(document: dict[str, Any], path: tuple[str, ...], context: str) -> Any:
    value: Any = document
    for name in path:
        value = require_object(value, context).get(name)
        if value is None:
            raise DeltaError(f"{context}.{'.'.join(path)} is missing")
    return value


def load_report(path: Path, label: str) -> tuple[dict[str, Any], bytes, dict[str, Any]]:
    resolved = path.resolve(strict=True)
    if not resolved.is_file():
        raise DeltaError(f"{label} is not a regular file: {resolved}")
    raw = resolved.read_bytes()
    if len(raw) == 0 or len(raw) > MAX_REPORT_BYTES:
        raise DeltaError(f"{label} byte length is outside the accepted bounds")
    try:
        document = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise DeltaError(f"{label} is not one valid UTF-8 JSON document") from error
    document = require_object(document, label)
    protocol = document.get("protocol")
    if protocol not in SUPPORTED_PROTOCOLS:
        raise DeltaError(f"{label} has unsupported protocol: {protocol!r}")
    source = {
        "path": str(resolved),
        "sha256": hashlib.sha256(raw).hexdigest(),
        "bytes": len(raw),
        "report_protocol": protocol,
    }
    return document, raw, source


def metric_delta(
    baseline: float | None, current: float | None, direction: str
) -> dict[str, Any]:
    if baseline is None or current is None:
        if baseline is not None or current is not None:
            raise IncompatibleReports("metric availability differs between reports")
        return {
            "baseline": None,
            "current": None,
            "absolute_delta": None,
            "percent_delta": None,
            "improvement_percent": None,
            "speedup": None,
        }
    absolute = current - baseline
    if baseline == 0:
        percent = 0.0 if current == 0 else None
    else:
        percent = absolute / baseline * 100.0
    improvement = (
        None
        if percent is None
        else (-percent if direction == "lower_is_better" else percent)
    )
    if direction == "lower_is_better":
        speedup = baseline / current if current != 0 else None
    else:
        speedup = current / baseline if baseline != 0 else None
    return {
        "baseline": baseline,
        "current": current,
        "absolute_delta": absolute,
        "percent_delta": percent,
        "improvement_percent": improvement,
        "speedup": speedup,
    }


def metric_record(
    name: str,
    unit: str,
    direction: str,
    baseline: float | None,
    current: float | None,
) -> dict[str, Any]:
    return {
        "metric": name,
        "unit": unit,
        "direction": direction,
        "classification": "unclassified",
        **metric_delta(baseline, current, direction),
    }


def compare_upstream(
    baseline: dict[str, Any], current: dict[str, Any]
) -> tuple[dict[str, Any], list[dict[str, Any]], dict[str, Any]]:
    baseline_settings = require_object(baseline.get("settings"), "baseline.settings")
    current_settings = require_object(current.get("settings"), "current.settings")
    if baseline_settings != current_settings:
        raise IncompatibleReports("upstream benchmark settings differ")
    baseline_families = require_list(
        baseline.get("upstream_families"), "baseline.upstream_families"
    )
    current_families = require_list(
        current.get("upstream_families"), "current.upstream_families"
    )
    if baseline_families != current_families:
        raise IncompatibleReports("upstream family workload keys or order differ")

    baseline_rows = require_list(baseline.get("families"), "baseline.families")
    current_rows = require_list(current.get("families"), "current.families")
    if len(baseline_rows) != len(current_rows):
        raise IncompatibleReports("upstream family row counts differ")
    comparisons: list[dict[str, Any]] = []
    workload_keys: list[dict[str, Any]] = []
    for index, (baseline_value, current_value) in enumerate(
        zip(baseline_rows, current_rows, strict=True)
    ):
        base_row = require_object(baseline_value, f"baseline.families[{index}]")
        curr_row = require_object(current_value, f"current.families[{index}]")
        family = base_row.get("family")
        mapped = base_row.get("mapped_workload")
        if not isinstance(family, str) or not family:
            raise DeltaError(f"baseline.families[{index}].family is invalid")
        if family != curr_row.get("family") or mapped != curr_row.get("mapped_workload"):
            raise IncompatibleReports(f"upstream workload key differs at row {index}")
        workload_key = {"family": family, "mapped_workload": mapped}
        workload_keys.append(workload_key)
        for lane in ("rust", "zig"):
            base_lane = require_object(base_row.get(lane), f"baseline.{family}.{lane}")
            curr_lane = require_object(curr_row.get(lane), f"current.{family}.{lane}")
            metrics = [
                metric_record(
                    "prove_avg_seconds",
                    "seconds",
                    "lower_is_better",
                    require_number(nested(base_lane, ("prove", "avg_seconds"), lane), f"baseline.{family}.{lane}.prove.avg_seconds"),
                    require_number(nested(curr_lane, ("prove", "avg_seconds"), lane), f"current.{family}.{lane}.prove.avg_seconds"),
                ),
                metric_record(
                    "verify_avg_seconds",
                    "seconds",
                    "lower_is_better",
                    require_number(nested(base_lane, ("verify", "avg_seconds"), lane), f"baseline.{family}.{lane}.verify.avg_seconds"),
                    require_number(nested(curr_lane, ("verify", "avg_seconds"), lane), f"current.{family}.{lane}.verify.avg_seconds"),
                ),
                metric_record(
                    "peak_rss_kb",
                    "kilobytes",
                    "lower_is_better",
                    optional_number(base_lane.get("peak_rss_kb"), f"baseline.{family}.{lane}.peak_rss_kb"),
                    optional_number(curr_lane.get("peak_rss_kb"), f"current.{family}.{lane}.peak_rss_kb"),
                ),
            ]
            comparisons.append(
                {
                    "row_index": index,
                    "workload_key": workload_key,
                    "lane": lane,
                    "metrics": metrics,
                }
            )
    identity = {
        "report_protocol": UPSTREAM_PROTOCOL,
        "settings": baseline_settings,
        "ordered_workloads": workload_keys,
    }
    revisions = {
        "baseline": {"status": baseline.get("status")},
        "current": {"status": current.get("status")},
    }
    return identity, comparisons, revisions


NATIVE_STABLE_PROVENANCE = (
    "zig_version",
    "optimization",
    "target_os",
    "target_arch",
    "cpu_count",
    "simd_pack_width",
    "single_threaded",
    "thread_parallelism_enabled",
    "environment_overrides",
)
NATIVE_STABLE_CONFIGURATION = (
    "proof_protocol",
    "warmups_per_lane",
    "samples_per_lane",
    "cooldown_seconds",
    "execution",
    "formal",
    "bounds",
)


def selected_fields(value: dict[str, Any], names: tuple[str, ...], context: str) -> dict[str, Any]:
    missing = [name for name in names if name not in value]
    if missing:
        raise DeltaError(f"{context} is missing compatibility fields: {', '.join(missing)}")
    return {name: value[name] for name in names}


def native_lane_metrics(
    lane: dict[str, Any], context: str
) -> dict[str, dict[str, float]]:
    summaries = require_object(lane.get("metrics"), f"{context}.metrics")
    result: dict[str, dict[str, float]] = {}
    for name, value in summaries.items():
        summary = require_object(value, f"{context}.metrics.{name}")
        result[name] = {
            "median": require_number(
                summary.get("median"), f"{context}.metrics.{name}.median"
            ),
            "mad": require_number(
                summary.get("mad"), f"{context}.metrics.{name}.mad"
            ),
        }
    return result


def native_metric_shape(name: str) -> tuple[str, str]:
    if name.endswith("_seconds"):
        return "seconds", "lower_is_better"
    if name.endswith("_mhz"):
        return "megahertz", "higher_is_better"
    if name.endswith("_per_second"):
        return "million_cells_per_second", "higher_is_better"
    raise DeltaError(f"unsupported native metric direction: {name}")


def native_row_evidence(
    baseline: dict[str, Any], current: dict[str, Any], index: int
) -> dict[str, Any]:
    evidence: dict[str, Any] = {}
    for label, row in (("baseline", baseline), ("current", current)):
        eligible = row.get("headline_eligible")
        blockers = row.get("headline_blockers")
        if not isinstance(eligible, bool):
            raise DeltaError(f"{label}.rows[{index}].headline_eligible must be boolean")
        blockers = require_list(blockers, f"{label}.rows[{index}].headline_blockers")
        if any(not isinstance(blocker, str) or not blocker for blocker in blockers):
            raise DeltaError(f"{label}.rows[{index}].headline_blockers is invalid")
        evidence[label] = {
            "headline_eligible": eligible,
            "headline_blockers": blockers,
        }
    evidence["stable_for_claim"] = (
        evidence["baseline"]["headline_eligible"]
        and evidence["current"]["headline_eligible"]
    )
    return evidence


def classify_native_metric(
    metric: dict[str, Any], baseline_mad: float, current_mad: float, stable: bool
) -> None:
    noise_band = baseline_mad + current_mad
    metric.update(
        {
            "baseline_mad": baseline_mad,
            "current_mad": current_mad,
            "noise_band": noise_band,
            "stable_for_claim": stable,
        }
    )
    if not stable:
        metric["classification"] = "diagnostic_unstable"
        metric["evidence_class"] = "diagnostic_only"
    elif abs(metric["absolute_delta"]) <= noise_band:
        metric["classification"] = "inconclusive"
        metric["evidence_class"] = "headline"
    else:
        improved = (
            metric["absolute_delta"] < 0
            if metric["direction"] == "lower_is_better"
            else metric["absolute_delta"] > 0
        )
        metric["classification"] = "improvement" if improved else "regression"
        metric["evidence_class"] = "headline"


def compare_native(
    baseline: dict[str, Any], current: dict[str, Any]
) -> tuple[dict[str, Any], list[dict[str, Any]], dict[str, Any]]:
    if baseline.get("schema_version") != 3 or current.get("schema_version") != 3:
        raise IncompatibleReports("native matrix schema_version must be 3")
    base_configuration = require_object(
        baseline.get("configuration"), "baseline.configuration"
    )
    curr_configuration = require_object(
        current.get("configuration"), "current.configuration"
    )
    base_settings = selected_fields(
        base_configuration, NATIVE_STABLE_CONFIGURATION, "baseline.configuration"
    )
    curr_settings = selected_fields(
        curr_configuration, NATIVE_STABLE_CONFIGURATION, "current.configuration"
    )
    base_provenance = require_object(
        base_configuration.get("provenance"), "baseline.configuration.provenance"
    )
    curr_provenance = require_object(
        curr_configuration.get("provenance"), "current.configuration.provenance"
    )
    base_host = selected_fields(
        base_provenance, NATIVE_STABLE_PROVENANCE, "baseline.configuration.provenance"
    )
    curr_host = selected_fields(
        curr_provenance, NATIVE_STABLE_PROVENANCE, "current.configuration.provenance"
    )
    base_oracle = require_object(
        baseline.get("correctness_scope"), "baseline.correctness_scope"
    )
    curr_oracle = require_object(
        current.get("correctness_scope"), "current.correctness_scope"
    )
    if base_settings != curr_settings:
        raise IncompatibleReports("native matrix proof or sampling settings differ")
    if base_host != curr_host:
        raise IncompatibleReports("native matrix OS/architecture/SIMD/threading settings differ")
    if base_oracle != curr_oracle:
        raise IncompatibleReports("native matrix correctness-oracle classification differs")

    baseline_rows = require_list(baseline.get("rows"), "baseline.rows")
    current_rows = require_list(current.get("rows"), "current.rows")
    if len(baseline_rows) != len(current_rows):
        raise IncompatibleReports("native matrix row counts differ")
    comparisons: list[dict[str, Any]] = []
    workload_keys: list[dict[str, Any]] = []
    for index, (baseline_value, current_value) in enumerate(
        zip(baseline_rows, current_rows, strict=True)
    ):
        base_row = require_object(baseline_value, f"baseline.rows[{index}]")
        curr_row = require_object(current_value, f"current.rows[{index}]")
        descriptor = base_row.get("descriptor_sha256")
        if not isinstance(descriptor, str) or len(descriptor) != 64:
            raise DeltaError(f"baseline.rows[{index}].descriptor_sha256 is invalid")
        for field in ("index", "descriptor_sha256", "workload", "lane_order"):
            if base_row.get(field) != curr_row.get(field):
                raise IncompatibleReports(f"native workload descriptor/order differs at row {index}: {field}")
        for field in ("proof_digest_sha256", "proof_bytes"):
            if base_row.get(field) != curr_row.get(field):
                raise IncompatibleReports(
                    f"native proof identity differs at row {index}: {field}; "
                    "the workload semantics are not comparable"
                )
        base_rust = require_object(
            base_row.get("rust_oracle"), f"baseline.rows[{index}].rust_oracle"
        )
        curr_rust = require_object(
            curr_row.get("rust_oracle"), f"current.rows[{index}].rust_oracle"
        )
        for oracle, context in (
            (base_rust, "baseline"),
            (curr_rust, "current"),
        ):
            if oracle.get("verified") is not True or oracle.get("status") != "passed":
                raise IncompatibleReports(
                    f"{context} Rust oracle did not verify row {index}"
                )
        for field in ("toolchain", "upstream_commit", "binary_sha256"):
            if base_rust.get(field) != curr_rust.get(field):
                raise IncompatibleReports(
                    f"native Rust oracle contract differs at row {index}: {field}"
                )
        workload_key = {
            "descriptor_sha256": descriptor,
            "workload": base_row.get("workload"),
        }
        workload_keys.append(workload_key)
        evidence = native_row_evidence(base_row, curr_row, index)
        base_lanes = require_object(base_row.get("lanes"), f"baseline.rows[{index}].lanes")
        curr_lanes = require_object(curr_row.get("lanes"), f"current.rows[{index}].lanes")
        if set(base_lanes) != {"cpu", "metal"} or set(curr_lanes) != {"cpu", "metal"}:
            raise IncompatibleReports(f"native lanes must be exactly cpu and metal at row {index}")
        for lane_name in ("cpu", "metal"):
            base_lane = require_object(base_lanes[lane_name], f"baseline.rows[{index}].lanes.{lane_name}")
            curr_lane = require_object(curr_lanes[lane_name], f"current.rows[{index}].lanes.{lane_name}")
            if base_lane.get("backend") != curr_lane.get("backend"):
                raise IncompatibleReports(f"native backend identity differs at row {index}, lane {lane_name}")
            base_metrics = native_lane_metrics(base_lane, f"baseline.rows[{index}].lanes.{lane_name}")
            curr_metrics = native_lane_metrics(curr_lane, f"current.rows[{index}].lanes.{lane_name}")
            if set(base_metrics) != set(curr_metrics):
                raise IncompatibleReports(f"native metric keys differ at row {index}, lane {lane_name}")
            metrics = []
            for metric_name in sorted(base_metrics):
                unit, direction = native_metric_shape(metric_name)
                metrics.append(
                    metric_record(
                        metric_name,
                        unit,
                        direction,
                        base_metrics[metric_name]["median"],
                        curr_metrics[metric_name]["median"],
                    )
                )
                classify_native_metric(
                    metrics[-1],
                    base_metrics[metric_name]["mad"],
                    curr_metrics[metric_name]["mad"],
                    evidence["stable_for_claim"],
                )
            comparisons.append(
                {
                    "row_index": index,
                    "workload_key": workload_key,
                    "lane": lane_name,
                    "evidence": evidence,
                    "metrics": metrics,
                }
            )

    identity = {
        "report_protocol": NATIVE_PROTOCOL,
        "settings": base_settings,
        "host_execution": base_host,
        "correctness_scope": base_oracle,
        "ordered_workloads": workload_keys,
    }
    revisions = {
        "baseline": {
            "git_commit": base_provenance.get("git_commit"),
            "git_dirty": base_provenance.get("git_dirty"),
            "binaries": base_configuration.get("binaries"),
            "timeout_seconds": base_configuration.get("timeout_seconds"),
            "rust_oracle_binary_sha256": sorted(
                {
                    row["rust_oracle"]["binary_sha256"]
                    for row in baseline_rows
                }
            ),
        },
        "current": {
            "git_commit": curr_provenance.get("git_commit"),
            "git_dirty": curr_provenance.get("git_dirty"),
            "binaries": curr_configuration.get("binaries"),
            "timeout_seconds": curr_configuration.get("timeout_seconds"),
            "rust_oracle_binary_sha256": sorted(
                {
                    row["rust_oracle"]["binary_sha256"]
                    for row in current_rows
                }
            ),
        },
    }
    return identity, comparisons, revisions


def compare_reports(
    baseline_path: Path, current_path: Path, timestamp: str
) -> tuple[dict[str, Any], bytes, bytes]:
    baseline, baseline_raw, baseline_source = load_report(baseline_path, "baseline")
    current, current_raw, current_source = load_report(current_path, "current")
    document: dict[str, Any] = {
        "schema_version": DELTA_SCHEMA_VERSION,
        "protocol": DELTA_PROTOCOL,
        "generated_at": timestamp,
        "report_kind": (
            baseline["protocol"]
            if baseline["protocol"] == current["protocol"]
            else f"{baseline['protocol']}->{current['protocol']}"
        ),
        "sources": {"baseline": baseline_source, "current": current_source},
        "normalizations": [],
    }
    try:
        if baseline["protocol"] != current["protocol"]:
            raise IncompatibleReports("benchmark report protocols differ")
        if baseline["protocol"] == UPSTREAM_PROTOCOL:
            identity, comparisons, revisions = compare_upstream(baseline, current)
        else:
            identity, comparisons, revisions = compare_native(baseline, current)
    except IncompatibleReports as error:
        document.update(
            {
                "status": "incomparable",
                "incompatibilities": [str(error)],
                "comparison_identity": None,
                "revisions": None,
                "comparisons": [],
                "comparison_summary": None,
            }
        )
        return document, baseline_raw, current_raw
    document.update(
        {
            "status": "comparable",
            "incompatibilities": [],
            "comparison_identity": {**identity, "sha256": digest_json(identity)},
            "revisions": revisions,
            "comparisons": comparisons,
            "comparison_summary": comparison_summary(comparisons),
        }
    )
    return document, baseline_raw, current_raw


def comparison_summary(comparisons: list[dict[str, Any]]) -> dict[str, Any]:
    rows: dict[int, bool] = {}
    for comparison in comparisons:
        evidence = comparison.get("evidence")
        if evidence is not None:
            rows[comparison["row_index"]] = evidence["stable_for_claim"]
    if not rows:
        return {
            "rows": len({comparison["row_index"] for comparison in comparisons}),
            "performance_claim_eligible_rows": None,
            "diagnostic_only_rows": [],
        }
    return {
        "rows": len(rows),
        "performance_claim_eligible_rows": sum(rows.values()),
        "diagnostic_only_rows": [index for index, eligible in rows.items() if not eligible],
    }


def parse_timestamp(value: str | None) -> str:
    if value is None:
        return datetime.now(timezone.utc).isoformat(timespec="seconds").replace(
            "+00:00", "Z"
        )
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise DeltaError("timestamp must be ISO-8601 with a timezone") from error
    if parsed.tzinfo is None:
        raise DeltaError("timestamp must include a timezone")
    return value


@contextmanager
def archive_lock(archive_dir: Path) -> Iterator[None]:
    archive_dir.mkdir(parents=True, exist_ok=True)
    lock_path = archive_dir / ".benchmark-delta.lock"
    try:
        descriptor = os.open(lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError as error:
        raise DeltaError(f"benchmark archive is locked: {archive_dir}") from error
    try:
        os.write(descriptor, f"pid={os.getpid()}\n".encode())
        os.fsync(descriptor)
        yield
    finally:
        os.close(descriptor)
        lock_path.unlink(missing_ok=True)


def archive_blob(
    archive_dir: Path, category: str, kind: str, raw: bytes, sha256: str
) -> str:
    relative = Path(category) / kind / f"{sha256}.json"
    destination = archive_dir / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        if not destination.is_file() or destination.read_bytes() != raw:
            raise DeltaError(f"content-addressed archive collision: {destination}")
    else:
        try:
            with destination.open("xb") as output:
                output.write(raw)
                output.flush()
                os.fsync(output.fileno())
        except FileExistsError:
            if destination.read_bytes() != raw:
                raise DeltaError(f"content-addressed archive collision: {destination}")
    return relative.as_posix()


def update_archive(
    archive_dir: Path,
    document: dict[str, Any],
    baseline_raw: bytes,
    current_raw: bytes,
) -> dict[str, Any]:
    with archive_lock(archive_dir):
        sources = document["sources"]
        baseline_relative = archive_blob(
            archive_dir,
            "reports",
            sources["baseline"]["report_protocol"],
            baseline_raw,
            sources["baseline"]["sha256"],
        )
        current_relative = archive_blob(
            archive_dir,
            "reports",
            sources["current"]["report_protocol"],
            current_raw,
            sources["current"]["sha256"],
        )
        core_delta = encoded_json(document)
        delta_sha256 = hashlib.sha256(core_delta).hexdigest()
        delta_relative = archive_blob(
            archive_dir, "deltas", DELTA_PROTOCOL, core_delta, delta_sha256
        )
        index_path = archive_dir / "index.json"
        if index_path.exists():
            try:
                index = json.loads(index_path.read_text(encoding="utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError) as error:
                raise DeltaError("benchmark archive index is invalid") from error
            if not isinstance(index, dict) or index.get("schema_version") != ARCHIVE_SCHEMA_VERSION:
                raise DeltaError("benchmark archive index schema is incompatible")
        else:
            index = {
                "schema_version": ARCHIVE_SCHEMA_VERSION,
                "artifacts": {},
                "deltas": {},
                "comparisons": [],
            }
        artifacts = require_object(index.get("artifacts"), "archive.artifacts")
        for source, relative in (
            (sources["baseline"], baseline_relative),
            (sources["current"], current_relative),
        ):
            expected = {"path": relative, "bytes": source["bytes"]}
            existing = artifacts.get(source["sha256"])
            if existing is not None and existing != expected:
                raise DeltaError("archive artifact index conflicts with immutable content")
            artifacts[source["sha256"]] = expected
        deltas = index.setdefault("deltas", {})
        deltas = require_object(deltas, "archive.deltas")
        expected_delta = {"path": delta_relative, "bytes": len(core_delta)}
        existing_delta = deltas.get(delta_sha256)
        if existing_delta is not None and existing_delta != expected_delta:
            raise DeltaError("archive delta index conflicts with immutable content")
        deltas[delta_sha256] = expected_delta
        comparison = {
            "archived_at": document["generated_at"],
            "report_kind": document["report_kind"],
            "status": document["status"],
            "comparison_identity_sha256": (
                document["comparison_identity"]["sha256"]
                if document["comparison_identity"] is not None
                else None
            ),
            "baseline_sha256": sources["baseline"]["sha256"],
            "current_sha256": sources["current"]["sha256"],
            "delta_sha256": delta_sha256,
            "delta_path": delta_relative,
        }
        comparison["id"] = digest_json(comparison)
        comparisons = require_list(index.get("comparisons"), "archive.comparisons")
        existing_ids = {
            entry.get("id")
            for entry in comparisons
            if isinstance(entry, dict) and isinstance(entry.get("id"), str)
        }
        if comparison["id"] not in existing_ids:
            comparisons.append(comparison)
        comparisons.sort(key=lambda entry: (entry["archived_at"], entry["id"]))
        atomic_write(index_path, encoded_json(index))
    return {
        "directory": str(archive_dir.resolve()),
        "index": str((archive_dir / "index.json").resolve()),
        "baseline_artifact": baseline_relative,
        "current_artifact": current_relative,
        "delta_artifact": delta_relative,
        "delta_sha256": delta_sha256,
        "delta_representation": "core_delta_without_archive_block",
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--current", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--archive-dir", type=Path)
    parser.add_argument(
        "--timestamp",
        help="ISO-8601 output/archive timestamp; intended for reproducible automation",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        timestamp = parse_timestamp(args.timestamp)
        document, baseline_raw, current_raw = compare_reports(
            args.baseline, args.current, timestamp
        )
        if args.archive_dir is not None:
            document["archive"] = update_archive(
                args.archive_dir, document, baseline_raw, current_raw
            )
        atomic_write(args.output, encoded_json(document))
    except (DeltaError, OSError) as error:
        print(f"benchmark delta failed: {error}", file=os.sys.stderr)
        return 1
    return 0 if document["status"] == "comparable" else 2


if __name__ == "__main__":
    raise SystemExit(main())
