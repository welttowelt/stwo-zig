#!/usr/bin/env python3
"""Ratchet source ownership and layout rules from CONTRIBUTING.md."""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_BASELINE = ROOT / "docs/conformance/source-baseline.json"
IMPORT_RE = re.compile(r'@import\("([^"\n]+)"\)')
ROOT_ALLOWLIST = frozenset({
    "std_shims_freestanding.zig",
    "stwo.zig",
    "stwo_deep.zig",
    "tests.zig",
})
FORBIDDEN_TARGETS = {
    "core": frozenset({"backend", "backends", "prover", "frontends", "integrations", "examples", "bench", "tools"}),
    "backend": frozenset({"backends", "frontends", "integrations", "examples", "tools"}),
    "prover": frozenset({"backends", "frontends", "integrations", "examples", "tools"}),
    "backends": frozenset({"frontends", "integrations", "examples", "tools"}),
    "frontends": frozenset({"backends", "integrations", "tools"}),
}


@dataclass(frozen=True, order=True)
class Finding:
    key: str
    message: str


def relative_import(source: Path, imported: str, src_root: Path) -> Path | None:
    if not imported.endswith(".zig") or not imported.startswith("."):
        return None
    resolved = (source.parent / imported).resolve()
    try:
        return resolved.relative_to(src_root.resolve())
    except ValueError:
        return None


def is_generated(text: str) -> bool:
    header = "\n".join(text.splitlines()[:8]).lower()
    return "generated" in header and "generator" in header


def scan(repo: Path) -> list[Finding]:
    src_root = repo / "src"
    findings: list[Finding] = []
    for source in sorted(src_root.rglob("*.zig")):
        relative = source.relative_to(src_root)
        text = source.read_text(encoding="utf-8")
        line_count = len(text.splitlines())
        if line_count > 850 and not is_generated(text):
            findings.append(Finding(
                f"file-size:{relative.as_posix()}",
                f"{relative}: {line_count} lines exceeds the 850-line manual-source ceiling",
            ))

        if len(relative.parts) == 1 and relative.name not in ROOT_ALLOWLIST:
            findings.append(Finding(
                f"root-source:{relative.name}",
                f"{relative}: executable, test, or implementation source belongs in a responsibility directory",
            ))

        source_layer = relative.parts[0] if len(relative.parts) > 1 else None
        forbidden = FORBIDDEN_TARGETS.get(source_layer, frozenset())
        if not forbidden:
            continue
        for imported in IMPORT_RE.findall(text):
            target = relative_import(source, imported, src_root)
            if target is None or len(target.parts) < 2:
                continue
            target_layer = target.parts[0]
            if target_layer in forbidden:
                findings.append(Finding(
                    f"dependency:{relative.as_posix()}->{target.as_posix()}",
                    f"{relative}: {source_layer} must not import {target_layer} ({imported})",
                ))
    return sorted(set(findings))


def load_baseline(path: Path) -> dict[str, dict[str, str]]:
    if not path.exists():
        return {}
    payload = json.loads(path.read_text(encoding="utf-8"))
    if payload.get("version") != 1 or not isinstance(payload.get("findings"), list):
        raise ValueError(f"invalid source conformance baseline: {path}")
    result: dict[str, dict[str, str]] = {}
    for entry in payload["findings"]:
        if not isinstance(entry, dict):
            raise ValueError(f"invalid baseline finding in {path}")
        key = entry.get("key")
        reason = entry.get("reason")
        plan = entry.get("plan")
        if not isinstance(key, str) or not key:
            raise ValueError(f"invalid baseline finding in {path}")
        if not isinstance(reason, str) or not reason or not isinstance(plan, str) or not plan:
            raise ValueError(f"baseline finding lacks reason/plan: {key}")
        if key in result:
            raise ValueError(f"duplicate baseline finding: {key}")
        result[key] = entry
    return result


def write_baseline(path: Path, findings: list[Finding]) -> None:
    payload = {
        "version": 1,
        "findings": [
            {
                "key": finding.key,
                "reason": "Legacy source-layout debt present when the conformance ratchet was introduced.",
                "plan": "docs/design/2026-07-17-source-conformance.md",
            }
            for finding in findings
        ],
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=ROOT)
    parser.add_argument("--baseline", type=Path, default=DEFAULT_BASELINE)
    parser.add_argument("--update-baseline", action="store_true")
    parser.add_argument("--strict", action="store_true", help="reject baseline findings as well as new findings")
    args = parser.parse_args(argv)

    repo = args.repo.resolve()
    baseline_path = args.baseline if args.baseline.is_absolute() else repo / args.baseline
    findings = scan(repo)
    if args.update_baseline:
        write_baseline(baseline_path, findings)
        try:
            display_path = baseline_path.relative_to(repo)
        except ValueError:
            display_path = baseline_path
        print(f"wrote {len(findings)} findings to {display_path}")
        return 0

    try:
        baseline = load_baseline(baseline_path)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(error, file=sys.stderr)
        return 2

    current = {finding.key: finding for finding in findings}
    new_keys = sorted(current.keys() - baseline.keys())
    stale_keys = sorted(baseline.keys() - current.keys())
    for key in new_keys:
        print(f"error: {current[key].message}", file=sys.stderr)
    for key in stale_keys:
        print(f"error: stale baseline entry must be removed: {key}", file=sys.stderr)

    if args.strict and current:
        for finding in findings:
            if finding.key not in new_keys:
                print(f"error: {finding.message}", file=sys.stderr)
        return 1
    if new_keys or stale_keys:
        return 1
    print(f"source conformance: {len(findings)} explained legacy findings, no new violations")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
