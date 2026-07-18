"""Standalone working notes: one markdown file per note under notes/."""

from __future__ import annotations

import datetime as dt
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path

TITLE_MAX = 200
BODY_MAX = 50 * 1024


class NoteError(RuntimeError):
    pass


@dataclass(frozen=True)
class Note:
    path: Path
    title: str
    author: str
    created_utc: str
    body: str


def notes_dir(repo_root: Path) -> Path:
    return repo_root / "autoresearch" / "notes"


def _slugify(title: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
    return slug[:60] or "note"


def _git_author(repo_root: Path) -> str:
    proc = subprocess.run(
        ["git", "config", "user.name"], cwd=repo_root, capture_output=True, text=True
    )
    return proc.stdout.strip() or "unknown"


def add(repo_root: Path, title: str, body: str) -> Path:
    if not title or len(title) > TITLE_MAX:
        raise NoteError(f"title required, max {TITLE_MAX} characters")
    if len(body.encode()) > BODY_MAX:
        raise NoteError(f"note body exceeds {BODY_MAX // 1024} KiB")
    now = dt.datetime.now(dt.timezone.utc)
    stamp = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    fname = f"{now.strftime('%Y%m%d-%H%M%S')}-{_slugify(title)}.md"
    path = notes_dir(repo_root) / fname
    front = (
        f"---\ntitle: {title}\nauthor: {_git_author(repo_root)}\n"
        f"created_utc: {stamp}\n---\n\n"
    )
    path.write_text(front + body.rstrip() + "\n")
    return path


def _parse(path: Path) -> Note | None:
    text = path.read_text()
    match = re.match(r"---\n(.*?)\n---\n\n?(.*)", text, re.DOTALL)
    if not match:
        return None
    meta: dict[str, str] = {}
    for line in match.group(1).splitlines():
        key, _, value = line.partition(":")
        meta[key.strip()] = value.strip()
    return Note(
        path=path,
        title=meta.get("title", path.stem),
        author=meta.get("author", "unknown"),
        created_utc=meta.get("created_utc", ""),
        body=match.group(2),
    )


def list_notes(repo_root: Path, author: str | None = None) -> list[Note]:
    out = []
    for path in sorted(notes_dir(repo_root).glob("*.md"), reverse=True):
        if path.name == "README.md":
            continue
        note = _parse(path)
        if note and (author is None or note.author == author):
            out.append(note)
    return out


def search(repo_root: Path, query: str, author: str | None = None) -> list[Note]:
    q = query.lower()
    return [n for n in list_notes(repo_root, author) if q in n.title.lower()]
