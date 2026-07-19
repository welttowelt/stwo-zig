"""Cheap central revalidation of fork submissions before scarce judge time."""

from __future__ import annotations

import json
import hashlib
import subprocess
import tempfile
from pathlib import Path

from store import Store

import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "cli"))
from stwo_perf import manifest as manifest_mod, qualification  # noqa: E402


class IntakeError(RuntimeError):
    pass


def _run(args: list[str], cwd: Path | None = None) -> str:
    proc = subprocess.run(args, cwd=cwd, capture_output=True, text=True)
    if proc.returncode != 0:
        detail = proc.stderr.strip() or proc.stdout.strip()
        raise IntakeError(f"{args[0]} {args[1] if len(args) > 1 else ''} failed: {detail}")
    return proc.stdout.strip()


def _branch(ref: str) -> str:
    prefix = "refs/heads/"
    if not ref.startswith(prefix):
        raise IntakeError("source ref is not a branch")
    return ref.removeprefix(prefix)


def verify_checkout(checkout: Path, manifest: manifest_mod.Manifest,
                    record: dict, verify_attestation: bool = True) -> dict:
    source = record["source"]
    branch = _branch(source["ref"])
    branch_head = _run(
        ["git", "rev-parse", f"refs/remotes/origin/{branch}^{{commit}}"], checkout,
    )
    if branch_head != source["commit"]:
        raise IntakeError("fork branch moved after submission; submit its new head explicitly")
    try:
        evidence = qualification.verify_receipt(
            checkout, manifest, record["qualification"]["receipt"],
        )
    except qualification.QualificationError as exc:
        raise IntakeError(str(exc)) from exc

    attestation = record["qualification"].get("attestation")
    attestation_verified = False
    if attestation and verify_attestation:
        receipt_file = checkout / ".git" / "autoresearch-receipt.json"
        receipt_bytes = (
            json.dumps(record["qualification"]["receipt"], indent=2, sort_keys=True) + "\n"
        ).encode()
        receipt_file.write_bytes(receipt_bytes)
        actual_digest = "sha256:" + hashlib.sha256(receipt_bytes).hexdigest()
        if actual_digest != attestation["artifact_digest"]:
            raise IntakeError("attested artifact digest does not match the receipt")
        repository = source["repository"].removeprefix("https://github.com/")
        signer = f"{repository}/.github/workflows/qualify-fork.yml"
        _run([
            "gh", "attestation", "verify", str(receipt_file),
            "--repo", repository,
            "--signer-workflow", signer,
            "--source-digest", source["commit"],
            "--source-ref", source["ref"],
            "--deny-self-hosted-runners",
        ])
        attestation_verified = True

    return {
        "candidate_tree": evidence.candidate_tree,
        "patch_digest": evidence.patch_digest,
        "locked_tree_digest": evidence.locked_tree_digest,
        "changed_paths": evidence.changed_paths,
        "attestation_verified": attestation_verified,
    }


def validate_remote(record: dict, canonical_repo: Path,
                    verify_attestation: bool = True) -> dict:
    manifest = manifest_mod.load(canonical_repo)
    source = record["source"]
    requires_attestation = manifest.qualification_policy.get(
        "require_github_artifact_attestation", False
    )
    if requires_attestation and not record["qualification"].get("attestation"):
        raise IntakeError("current policy requires a GitHub artifact attestation")
    if requires_attestation and not verify_attestation:
        raise IntakeError("current policy forbids skipping artifact verification")
    branch = _branch(source["ref"])
    with tempfile.TemporaryDirectory(prefix="autoresearch-intake-") as tmp:
        checkout = Path(tmp) / "source"
        _run([
            "git", "clone", "--no-checkout", "--filter=blob:none", "--single-branch",
            "--branch", branch, source["repository"], str(checkout),
        ])
        # Fetching the named branch is not enough if the frontier is no longer
        # in its shallow negotiation. Require the exact canonical object.
        _run(["git", "fetch", "origin", source["frontier_commit"]], checkout)
        evidence = verify_checkout(checkout, manifest, record, verify_attestation)
        source_ref = f"refs/autoresearch/source/{record['id']}"
        _run([
            "git", "fetch", "--no-tags", source["repository"],
            f"{source['ref']}:{source_ref}",
        ], canonical_repo)
        fetched = _run(["git", "rev-parse", f"{source_ref}^{{commit}}"], canonical_repo)
        if fetched != source["commit"]:
            raise IntakeError("fork branch moved while central intake was pinning it")
        try:
            qualification.verify_receipt(
                canonical_repo, manifest, record["qualification"]["receipt"],
            )
        except qualification.QualificationError as exc:
            raise IntakeError(f"canonical object verification failed: {exc}") from exc
        evidence["source_ref"] = source_ref
        return evidence


def process_one(store: Store, canonical_repo: Path,
                verify_attestation: bool = True) -> dict | None:
    item = store.claim_next({"received"}, "validating", "claimed by intake worker")
    if item is None:
        return None
    try:
        evidence = validate_remote(item, canonical_repo, verify_attestation)
    except (IntakeError, OSError) as exc:
        return store.transition(
            item["id"], {"validating"}, "rejected", "central intake rejected source",
            {"worker_error": str(exc)},
        )
    latest = store.get_submission(item["id"]) or item
    waiting = any(co["status"] != "accepted" for co in latest.get("coauthors", []))
    state = "awaiting_coauthors" if waiting else "queued"
    detail = (
        "source verified; waiting for requested co-author consent"
        if waiting else "source identity and tree policy centrally verified"
    )
    return store.transition(
        item["id"], {"validating"}, state, detail, {"intake_evidence": evidence},
    )
