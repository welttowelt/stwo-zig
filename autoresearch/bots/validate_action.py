#!/usr/bin/env python3
"""PR validation bot: append-only ledger, locked paths, submission schema.

Runs on every PR (validate.yml). Exit 0 = pass; nonzero output lists findings.
Environment: BASE_REF (merge-base ref, default origin/main).
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "cli"))
from stwo_perf import ledger, manifest as manifest_mod, submitter  # noqa: E402

LEDGER = "autoresearch/ledger/promotions.tsv"


def _git(*args: str) -> str:
    proc = subprocess.run(["git", *args], capture_output=True, text=True)
    if proc.returncode != 0:
        raise SystemExit(f"git {' '.join(args)} failed: {proc.stderr.strip()}")
    return proc.stdout


def _show(ref: str, path: str) -> str | None:
    proc = subprocess.run(["git", "show", f"{ref}:{path}"], capture_output=True, text=True)
    return proc.stdout if proc.returncode == 0 else None


def main() -> int:
    base_ref = os.environ.get("BASE_REF", "origin/main")
    base = _git("merge-base", base_ref, "HEAD").strip()
    changed = [p for p in _git("diff", "--name-only", base, "HEAD").splitlines() if p]
    findings: list[str] = []

    m = manifest_mod.load(Path.cwd())
    is_promotion = os.environ.get("PROMOTION_BOT") == "1"
    labels = os.environ.get("PR_LABELS", "")
    new_submission_dirs = sorted(
        {Path(p).parts[2] for p in changed
         if p.startswith("autoresearch/submissions/") and len(Path(p).parts) > 3}
    )
    is_submission_pr = bool(new_submission_dirs) or "submission" in labels

    # 1. Forgery guard runs on EVERY PR: judged verdicts live signed on the
    #    judge-verdicts branch, never in the tree.
    for path in changed:
        if (path.endswith("judged-verdict.json") or path.startswith("judge-out/")
                or "/judge-out/" in path or path.startswith("verdicts/")):
            findings.append(f"judged verdict material in a PR is forbidden: {path}")

    # 2. Locked paths are enforced mechanically only on submission PRs; a
    #    governance PR (anchor freeze, epochs.json, workflow updates, harness
    #    fixes) is exactly the human-reviewed exception and passes here.
    if is_submission_pr:
        for path in changed:
            if path == LEDGER and is_promotion:
                continue
            if path.startswith("autoresearch/submissions/") or path.startswith("autoresearch/notes/"):
                continue  # submission and note additions are the point of the PR
            if m.is_locked(path):
                findings.append(f"locked path modified in a submission PR: {path}")

    # 2. Ledger append-only (checked even for the promotion bot).
    if LEDGER in changed:
        base_text = _show(base, LEDGER) or ""
        head_text = Path(LEDGER).read_text()
        try:
            ledger.verify_append_only(base_text, head_text)
        except ledger.LedgerError as exc:
            findings.append(f"ledger: {exc}")

    # 3. New submission directories must satisfy the schema.
    for name in new_submission_dirs:
        sub = Path("autoresearch/submissions") / name
        note = sub / "note.md"
        if not note.exists():
            findings.append(f"{name}: missing note.md")
            continue
        problems = submitter.validate_note(note.read_text())
        findings.extend(f"{name}: {p}" for p in problems)
        for required in ("verdict.json", "delta.json"):
            if not (sub / required).exists():
                findings.append(f"{name}: missing {required}")
        verdict_paths = [sub / "verdict.json", *sorted(sub.glob("verdict-*.json"))]
        verdicts = []
        verdict_sources = []
        for verdict_path in verdict_paths:
            if not verdict_path.exists():
                continue
            try:
                verdict = json.loads(verdict_path.read_text())
            except json.JSONDecodeError:
                findings.append(f"{name}: {verdict_path.name} is not valid JSON")
                continue
            verdicts.append(verdict)
            verdict_sources.append(verdict_path.name)
        try:
            submitter.check_claimed_verdicts(verdicts, verdict_sources)
        except submitter.SubmitError as exc:
            findings.append(f"{name}: {exc}")
        secrets = submitter.scan_transcripts(sub / "transcripts")
        findings.extend(f"{name}: transcript secret scan: {s}" for s in secrets)
        transcripts_dir = sub / "transcripts"
        transcript_files = (
            sorted(p.name for p in transcripts_dir.rglob("*") if p.is_file())
            if transcripts_dir.exists() else []
        )
        delta_path = sub / "delta.json"
        if delta_path.exists():
            try:
                delta = json.loads(delta_path.read_text())
            except json.JSONDecodeError:
                findings.append(f"{name}: delta.json is not valid JSON")
                delta = {}
            # Transcripts or an explicit recorded declination — never silence.
            declined = delta.get("transcripts_declined") is True
            if not transcript_files and not declined:
                findings.append(
                    f"{name}: transcripts/ is empty and delta.json does not record "
                    "an explicit declination (transcripts_declined) — sanitized "
                    "session transcripts are the submission-flow default"
                )
            if transcript_files and declined:
                findings.append(
                    f"{name}: delta.json declines transcripts but transcripts/ "
                    "contains files"
                )
            listed = delta.get("transcripts", {})
            for tpath, meta in listed.items():
                file_path = sub / tpath
                if not file_path.exists():
                    findings.append(f"{name}: delta.json names missing {tpath}")
                elif submitter._sha256(file_path) != meta.get("sha256"):
                    findings.append(f"{name}: transcript hash mismatch for {tpath}")
            listed_names = {tpath.split("/", 1)[-1] for tpath in listed}
            for fname in transcript_files:
                if fname not in listed_names:
                    findings.append(
                        f"{name}: transcripts/{fname} is not digest-bound in delta.json"
                    )

    if findings:
        print("validation findings:")
        for f in findings:
            print(f"  ✗ {f}")
        return 1
    print("✓ validation passed: locked paths intact, ledger append-only, submissions well-formed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
