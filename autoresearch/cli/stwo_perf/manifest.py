"""MANIFEST.json loading, validation, and path policy queries."""

from __future__ import annotations

import fnmatch
import json
from dataclasses import dataclass
from pathlib import Path

RUNGS = ("s1", "s2", "s3", "s4", "s5")
ACCEPTANCE_FLOOR = "s3"


class ManifestError(RuntimeError):
    pass


@dataclass(frozen=True)
class Workload:
    workload_id: str
    workload_class: str
    args: str
    native_unit: str
    group_id: str = "native"


@dataclass(frozen=True)
class WorkloadGroup:
    group_id: str
    enabled: bool
    disabled_reason: str | None
    build_step: str
    binary: str
    report_schema: str
    workloads: list[Workload]


@dataclass(frozen=True)
class Manifest:
    root: Path
    raw: dict

    @property
    def editable(self) -> list[dict]:
        return list(self.raw["editable_paths"])

    @property
    def locked(self) -> list[str]:
        return list(self.raw["locked_paths"])

    @property
    def gates(self) -> dict:
        return dict(self.raw["gates_policy"])

    @property
    def anchor_commit(self) -> str | None:
        return self.raw["harness"].get("anchor_commit")

    def groups(self) -> list[WorkloadGroup]:
        """Workload groups in manifest order (registry v2)."""
        out = []
        for gid, spec in self.raw["workload_registry"]["groups"].items():
            out.append(WorkloadGroup(
                group_id=gid,
                enabled=bool(spec["enabled"]),
                disabled_reason=spec.get("disabled_reason"),
                build_step=spec["build_step"],
                binary=spec["binary"],
                report_schema=spec["report_schema"],
                workloads=[
                    Workload(wid, w["class"], w["args"], w["native_unit"], gid)
                    for wid, w in spec["workloads"].items()
                ],
            ))
        return out

    def group(self, group_id: str) -> WorkloadGroup:
        for g in self.groups():
            if g.group_id == group_id:
                return g
        raise ManifestError(f"unknown workload group: {group_id}")

    def workloads(self, workload_class: str | None = None,
                  include_disabled: bool = False) -> list[Workload]:
        """Workloads across groups; disabled groups excluded unless asked.

        Callers that iterate for execution must announce disabled groups
        loudly themselves (runner/workspace do) — this filter is for
        selection, never for silent dropping.
        """
        out = [
            w
            for g in self.groups()
            if include_disabled or g.enabled
            for w in g.workloads
        ]
        if workload_class:
            out = [w for w in out if w.workload_class == workload_class]
        return out

    def is_locked(self, path: str) -> bool:
        return any(_match(path, glob) for glob in self.locked)

    def is_editable(self, path: str) -> bool:
        return any(_match(path, e["glob"]) for e in self.editable)

    def path_rung(self, path: str) -> str | None:
        """Minimum acceptance rung for one path; None if not editable."""
        best: str | None = None
        for entry in self.editable:
            if _match(path, entry["glob"]):
                rung = entry["min_rung"]
                if best is None or RUNGS.index(rung) > RUNGS.index(best):
                    best = rung
        return best

    def judged_rung(self, declared: str, touched_paths: list[str]) -> str:
        """max(declared, highest rung mapped to any touched path); floor s3."""
        idx = max(RUNGS.index(declared), RUNGS.index(ACCEPTANCE_FLOOR))
        for path in touched_paths:
            rung = self.path_rung(path)
            if rung is not None:
                idx = max(idx, RUNGS.index(rung))
        return RUNGS[idx]

    def classify_touched(self, touched_paths: list[str]) -> tuple[list[str], list[str]]:
        """Split touched paths into (locked violations, non-editable strays)."""
        violations = [p for p in touched_paths if self.is_locked(p)]
        strays = [
            p for p in touched_paths if not self.is_locked(p) and not self.is_editable(p)
        ]
        return violations, strays


def _match(path: str, glob: str) -> bool:
    if glob.endswith("/**"):
        return path.startswith(glob[:-3] + "/") or path == glob[:-3]
    return fnmatch.fnmatch(path, glob)


def find_repo_root(start: Path | None = None) -> Path:
    cur = (start or Path.cwd()).resolve()
    for candidate in (cur, *cur.parents):
        if (candidate / "autoresearch" / "MANIFEST.json").exists():
            return candidate
    raise ManifestError(
        "not inside a stwo-perf repository (autoresearch/MANIFEST.json not found)"
    )


def load(root: Path | None = None) -> Manifest:
    repo = find_repo_root(root)
    path = repo / "autoresearch" / "MANIFEST.json"
    try:
        raw = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        raise ManifestError(f"invalid MANIFEST.json: {exc}") from exc
    _validate(raw)
    return Manifest(root=repo, raw=raw)


def _validate(raw: dict) -> None:
    for key in ("manifest_version", "harness", "editable_paths", "locked_paths",
                "workload_registry", "gates_policy"):
        if key not in raw:
            raise ManifestError(f"MANIFEST.json missing required key: {key}")
    for entry in raw["editable_paths"]:
        if entry.get("min_rung") not in RUNGS:
            raise ManifestError(f"editable path {entry.get('glob')} has invalid min_rung")
    registry = raw["workload_registry"]
    if "groups" not in registry:
        raise ManifestError(
            "workload_registry has no 'groups': flat v1 registries "
            "(build_step/binary/workloads at top level) were replaced by named "
            "groups in manifest_version 2 — wrap the flat triple in a group"
        )
    if not registry["groups"]:
        raise ManifestError("workload_registry.groups is empty")
    for gid, spec in registry["groups"].items():
        for key in ("enabled", "build_step", "binary", "report_schema", "workloads"):
            if key not in spec:
                raise ManifestError(f"workload group {gid} missing required key: {key}")
        if not isinstance(spec["enabled"], bool):
            raise ManifestError(f"workload group {gid}: 'enabled' must be a boolean")
        if not spec["enabled"] and not str(spec.get("disabled_reason") or "").strip():
            raise ManifestError(
                f"workload group {gid} is disabled without a disabled_reason; "
                "silent dark groups are not allowed"
            )
        for wid, w in spec["workloads"].items():
            if w.get("class") not in ("small", "wide", "deep"):
                raise ManifestError(f"workload {gid}/{wid} has invalid class")
