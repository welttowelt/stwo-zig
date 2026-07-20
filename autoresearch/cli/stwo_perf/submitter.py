"""Submission packaging: note schema, transcript redaction, delta binding."""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import re
import shutil
from pathlib import Path

from .manifest import Manifest
from .runner import changed_paths

REQUIRED_SECTIONS = ["Model and harness", "Hypothesis", "Changes", "Results", "Caveats"]
NOTE_MAX_BYTES = 10 * 1024

# Fail-closed secret patterns for transcript scanning.
SECRET_PATTERNS = [
    re.compile(p)
    for p in (
        r"ghp_[A-Za-z0-9]{20,}",
        r"github_pat_[A-Za-z0-9_]{20,}",
        r"sk-[A-Za-z0-9\-_]{20,}",
        r"AKIA[0-9A-Z]{16}",
        r"-----BEGIN [A-Z ]*PRIVATE KEY-----",
        r"(?i)(api[_-]?key|secret|token)\s*[:=]\s*['\"][A-Za-z0-9\-_]{16,}['\"]",
        r"xox[baprs]-[A-Za-z0-9\-]{10,}",
    )
]


class SubmitError(RuntimeError):
    pass


def validate_note(text: str) -> list[str]:
    """Return the list of problems; empty means valid."""
    problems = []
    if len(text.encode()) > NOTE_MAX_BYTES:
        problems.append(f"note exceeds {NOTE_MAX_BYTES // 1024} KiB")
    if not text.lstrip().startswith("# "):
        problems.append("note must start with a '# <title>' heading")
    position = 0
    for section in REQUIRED_SECTIONS:
        marker = f"## {section}"
        found = text.find(marker)
        if found == -1:
            problems.append(f"missing required section: '{marker}'")
        elif found < position:
            problems.append(f"section out of order: '{marker}'")
        else:
            position = found
    return problems


def resolve_transcripts(transcript_dir: Path | None, transcripts_declined: bool) -> list[Path]:
    """Transcript consent: sanitized sessions are the submission-flow default;
    the one legitimate absence is the submitter's explicit, recorded
    declination. Silent omission is refused."""
    if transcript_dir is None and not transcripts_declined:
        raise SubmitError(
            "transcripts are part of the submission flow: pass --transcripts <dir> "
            "with the sanitized session transcripts, or record an explicit "
            "declination with --transcripts-declined"
        )
    if transcript_dir is not None and transcripts_declined:
        raise SubmitError("--transcripts and --transcripts-declined are mutually exclusive")
    if transcript_dir is None:
        return []
    files = sorted(p for p in transcript_dir.rglob("*") if p.is_file())
    if not files:
        raise SubmitError(
            f"transcript directory {transcript_dir} contains no files; include "
            "at least one sanitized session transcript or record an explicit "
            "declination with --transcripts-declined"
        )
    findings = scan_transcripts(transcript_dir)
    if findings:
        raise SubmitError(
            "transcript secret scan failed (fix and re-run, never bypass):\n  - "
            + "\n  - ".join(findings)
        )
    return files


def scan_transcripts(transcript_dir: Path) -> list[str]:
    """Return secret findings as 'file: pattern' strings; empty means clean."""
    findings = []
    if not transcript_dir.exists():
        return findings
    for path in sorted(transcript_dir.rglob("*")):
        if not path.is_file():
            continue
        try:
            text = path.read_text(errors="replace")
        except OSError as exc:
            raise SubmitError(f"cannot read transcript {path}: {exc}") from exc
        for pattern in SECRET_PATTERNS:
            if pattern.search(text):
                findings.append(f"{path.name}: matches {pattern.pattern[:32]}…")
    return findings


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def package(
    repo_root: Path,
    manifest: Manifest,
    slug: str,
    note_file: Path,
    verdict_files: list[Path],
    transcript_dir: Path | None,
    model: str,
    transcripts_declined: bool = False,
) -> Path:
    """Assemble autoresearch/submissions/<utc-date>-<slug>/ after all checks."""
    note_text = note_file.read_text()
    problems = validate_note(note_text)
    if model.lower() not in note_text.lower():
        problems.append(f"note must name the model ('{model}') in Model and harness")
    if problems:
        raise SubmitError("note.md rejected:\n  - " + "\n  - ".join(problems))

    # One mechanism, one diff — but every workload class the change moves may
    # carry its own paired verdict, so the whole improvement is credited to
    # the suite score instead of one class swallowing the others' gains.
    if not verdict_files:
        raise SubmitError("at least one claimed verdict is required")
    verdicts = [json.loads(v.read_text()) for v in verdict_files]
    seen_classes: set[str] = set()
    for source, verdict in zip(verdict_files, verdicts):
        if verdict.get("kind") == "judged":
            raise SubmitError("submissions carry claimed verdicts; only the judge emits judged")
        cls = str((verdict.get("declared_objective") or {}).get("workload_class"))
        if cls in seen_classes:
            raise SubmitError(f"duplicate verdict for class {cls} ({source})")
        seen_classes.add(cls)
    verdict = verdicts[0]

    # Prior notes/submissions on the same branch are legitimate (mirrors the
    # carve-out in runner._gates and validate_action).
    touched = [
        p for p in changed_paths(repo_root)
        if not p.startswith("autoresearch/submissions/")
        and not p.startswith("autoresearch/notes/")
        and not p.startswith("autoresearch/.runs/")
    ]
    violations, _ = manifest.classify_touched(touched)
    if violations:
        raise SubmitError(f"locked paths modified: {violations[:10]}")

    transcript_files = resolve_transcripts(transcript_dir, transcripts_declined)

    date = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d")
    sub_dir = repo_root / "autoresearch" / "submissions" / f"{date}-{slug}"
    if sub_dir.exists():
        raise SubmitError(f"submission directory already exists: {sub_dir}")
    sub_dir.mkdir(parents=True)

    (sub_dir / "note.md").write_text(note_text)
    shutil.copy2(verdict_files[0], sub_dir / "verdict.json")
    for extra, extra_verdict in zip(verdict_files[1:], verdicts[1:]):
        cls = str(extra_verdict["declared_objective"]["workload_class"])
        shutil.copy2(extra, sub_dir / f"verdict-{cls}.json")

    transcripts_meta = {}
    tdir = sub_dir / "transcripts"
    tdir.mkdir()
    for src in transcript_files:
        dest = tdir / src.name
        shutil.copy2(src, dest)
        transcripts_meta[f"transcripts/{src.name}"] = {
            "sha256": _sha256(dest),
            "captured_by": "submitter",
        }

    delta = {
        "schema_version": 1,
        "predecessor_commit": verdict.get("predecessor_commit"),
        "declared_objective": verdict.get("declared_objective"),
        "declared_scope": verdict.get("scope"),
        "files": {p: f"sha256:{_sha256(repo_root / p)}" for p in touched if (repo_root / p).is_file()},
        "transcripts": transcripts_meta,
        "transcripts_declined": transcripts_declined,
    }
    (sub_dir / "delta.json").write_text(json.dumps(delta, indent=2) + "\n")
    return sub_dir
