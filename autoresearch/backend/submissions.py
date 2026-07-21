"""Validation and public projection for authenticated remote submissions."""

from __future__ import annotations

import copy
import math
import re
import urllib.parse

SCHEMA_VERSION = 2
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
REF_RE = re.compile(r"^refs/heads/[A-Za-z0-9._/-]{1,200}$")
LOGIN_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$")
REPO_RE = re.compile(r"^[A-Za-z0-9._-]{1,100}$")
DIMENSIONS = {"time", "rss", "energy"}
MAX_NOTE_BYTES = 10 * 1024
MAX_COAUTHORS = 10
REQUIRED_NOTE_SECTIONS = (
    "Model and harness", "Hypothesis", "Changes", "Results", "Caveats",
)
SECRET_PATTERNS = (
    re.compile(r"ghp_[A-Za-z0-9]{20,}"),
    re.compile(r"github_pat_[A-Za-z0-9_]{20,}"),
    re.compile(r"sk-[A-Za-z0-9\-_]{20,}"),
    re.compile(r"AKIA[0-9A-Z]{16}"),
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
)


class SubmissionError(RuntimeError):
    pass


def _required_dict(parent: dict, key: str) -> dict:
    value = parent.get(key)
    if not isinstance(value, dict):
        raise SubmissionError(f"{key} must be an object")
    return value


def normalize_repository_url(value: object) -> str:
    if not isinstance(value, str):
        raise SubmissionError("source.repository must be a GitHub HTTPS URL")
    try:
        parsed = urllib.parse.urlsplit(value)
        port = parsed.port
    except ValueError as exc:
        raise SubmissionError("source.repository is not a valid URL") from exc
    parts = [part for part in parsed.path.strip("/").split("/") if part]
    if (parsed.scheme != "https" or parsed.hostname != "github.com" or len(parts) != 2
            or parsed.username or parsed.password or port or parsed.query or parsed.fragment):
        raise SubmissionError("source.repository must be https://github.com/<owner>/<repo>")
    owner, repo = parts
    repo = repo.removesuffix(".git")
    if not LOGIN_RE.fullmatch(owner) or not REPO_RE.fullmatch(repo):
        raise SubmissionError("source.repository has an invalid owner or repository name")
    return f"https://github.com/{owner}/{repo}"


def validate_request(
    body: dict,
    author: dict,
    allowed_board_classes: dict[str, set[str]],
) -> dict:
    if not isinstance(body, dict) or body.get("schema_version") != SCHEMA_VERSION:
        raise SubmissionError(f"schema_version must be {SCHEMA_VERSION}")
    source = _required_dict(body, "source")
    receipt = _required_dict(_required_dict(body, "qualification"), "receipt")
    claim = _required_dict(body, "claim")

    repository = normalize_repository_url(source.get("repository"))
    repository_owner = urllib.parse.urlsplit(repository).path.strip("/").split("/", 1)[0]
    if repository_owner.casefold() != author["login"].casefold():
        raise SubmissionError("source repository must be owned by the API-key GitHub user")
    commit = source.get("commit")
    frontier_commit = source.get("frontier_commit")
    ref = source.get("ref")
    if not isinstance(commit, str) or not COMMIT_RE.fullmatch(commit):
        raise SubmissionError("source.commit must be a full lowercase 40-hex SHA")
    if not isinstance(frontier_commit, str) or not COMMIT_RE.fullmatch(frontier_commit):
        raise SubmissionError("source.frontier_commit must be a full lowercase 40-hex SHA")
    ref_parts = ref.removeprefix("refs/heads/").split("/") if isinstance(ref, str) else []
    if (not isinstance(ref, str) or not REF_RE.fullmatch(ref) or ".." in ref
            or "//" in ref or ref.endswith(("/", "."))
            or any(part.startswith(".") or part.endswith(".lock") for part in ref_parts)):
        raise SubmissionError("source.ref must be a safe refs/heads/<branch> ref")
    if receipt.get("candidate_commit") != commit:
        raise SubmissionError("qualification receipt candidate does not match source.commit")
    if receipt.get("frontier_commit") != frontier_commit:
        raise SubmissionError("qualification receipt frontier does not match source.frontier_commit")
    if receipt.get("submitter_login", "").casefold() != author["login"].casefold():
        raise SubmissionError("qualification receipt submitter does not match API-key owner")
    if receipt.get("claim") != claim:
        raise SubmissionError("qualification receipt claim does not match submitted claim")

    board = claim.get("board")
    workload_class = claim.get("workload_class")
    dimension = claim.get("dimension")
    score = claim.get("shipping_index")
    if board not in allowed_board_classes:
        raise SubmissionError(f"claim.board is not runnable: {board}")
    if workload_class not in allowed_board_classes[board]:
        allowed = "|".join(sorted(allowed_board_classes[board]))
        raise SubmissionError(
            f"claim.workload_class is not runnable on {board}; expected one of {allowed}"
        )
    if dimension not in DIMENSIONS:
        raise SubmissionError("claim.dimension must be time|rss|energy")
    if (not isinstance(score, (int, float)) or isinstance(score, bool)
            or not math.isfinite(score) or score <= 0):
        raise SubmissionError("claim.shipping_index must be a positive number")

    note = body.get("note")
    if not isinstance(note, str) or not note.strip():
        raise SubmissionError("note must be a non-empty Markdown string")
    if len(note.encode()) > MAX_NOTE_BYTES:
        raise SubmissionError(f"note exceeds {MAX_NOTE_BYTES // 1024} KiB")
    if not note.lstrip().startswith("# "):
        raise SubmissionError("note must start with a '# <title>' heading")
    cursor = 0
    for section in REQUIRED_NOTE_SECTIONS:
        position = note.find(f"## {section}")
        if position < cursor:
            raise SubmissionError(f"note is missing or misorders section: {section}")
        cursor = position
    if any(pattern.search(note) for pattern in SECRET_PATTERNS):
        raise SubmissionError("note appears to contain a credential or private key")

    requested = body.get("coauthors", [])
    if not isinstance(requested, list) or len(requested) > MAX_COAUTHORS:
        raise SubmissionError(f"coauthors must be a list of at most {MAX_COAUTHORS} logins")
    coauthors = []
    seen = {author["login"].casefold()}
    for login in requested:
        if not isinstance(login, str) or not LOGIN_RE.fullmatch(login):
            raise SubmissionError(f"invalid coauthor login: {login!r}")
        folded = login.casefold()
        if folded in seen:
            raise SubmissionError(f"duplicate author/coauthor login: {login}")
        seen.add(folded)
        coauthors.append({"login": login, "status": "pending"})

    qualification = copy.deepcopy(body["qualification"])
    attestation = qualification.get("attestation")
    if attestation is not None:
        if not isinstance(attestation, dict):
            raise SubmissionError("qualification.attestation must be an object")
        digest = attestation.get("artifact_digest")
        if not isinstance(digest, str) or not DIGEST_RE.fullmatch(digest):
            raise SubmissionError("qualification.attestation.artifact_digest is invalid")
        url = attestation.get("url")
        parsed = urllib.parse.urlsplit(url) if isinstance(url, str) else None
        if (url is not None and (parsed is None or parsed.scheme != "https"
                or parsed.hostname not in {"github.com", "api.github.com"})):
            raise SubmissionError("qualification.attestation.url must be a GitHub HTTPS URL")

    return {
        "schema_version": SCHEMA_VERSION,
        "author": copy.deepcopy(author),
        "coauthors": coauthors,
        "source": {
            "repository": repository,
            "commit": commit,
            "frontier_commit": frontier_commit,
            "ref": ref,
        },
        "qualification": qualification,
        "claim": {
            "board": board,
            "workload_class": workload_class,
            "dimension": dimension,
            "shipping_index": float(score),
        },
        "note": note,
    }


def public_record(record: dict, include_internal: bool = False) -> dict:
    """Return an API-safe copy; never expose worker-only diagnostics by default."""
    out = copy.deepcopy(record)
    out.pop("judged_verdict", None)
    if not include_internal:
        out.pop("worker_error", None)
    return out
