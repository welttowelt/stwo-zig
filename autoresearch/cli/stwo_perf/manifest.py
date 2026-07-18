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

    def workloads(self, workload_class: str | None = None) -> list[Workload]:
        registry = self.raw["workload_registry"]["workloads"]
        out = [
            Workload(wid, spec["class"], spec["args"], spec["native_unit"])
            for wid, spec in registry.items()
        ]
        if workload_class:
            out = [w for w in out if w.workload_class == workload_class]
        return out

    def build_step(self) -> str:
        return self.raw["workload_registry"]["build_step"]

    def binary(self) -> str:
        return self.raw["workload_registry"]["binary"]

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
    for wid, spec in raw["workload_registry"]["workloads"].items():
        if spec.get("class") not in ("small", "wide", "deep"):
            raise ManifestError(f"workload {wid} has invalid class")
