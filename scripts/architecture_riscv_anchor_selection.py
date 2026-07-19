#!/usr/bin/env python3
"""Select and bind one owner-produced exhaustive RISC-V anchor artifact."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


HEX40 = re.compile(r"^[0-9a-f]{40}$")
ARTIFACT_DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
ARTIFACT_NAME = re.compile(
    r"^riscv-exhaustive-bundle-([0-9a-f]{40})-([1-9][0-9]*)-([1-9][0-9]*)$"
)
REPOSITORY = "teddyjfpender/stwo-zig"
REPOSITORY_ID = 1152389958
OWNER_ID = 92999717
WORKFLOW_PATH = ".github/workflows/ci.yml"
PRODUCER_JOB_NAME = "RISC-V exhaustive release evidence"


class SelectionError(ValueError):
    pass


def strict_json(path: Path) -> Any:
    def unique(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise SelectionError(f"duplicate producer metadata key: {key}")
            result[key] = value
        return result

    return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique)


def positive_integer(value: Any, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise SelectionError(f"{label} is not a positive integer")
    return value


def select(
    *, run: dict[str, Any], jobs: dict[str, Any], artifacts: dict[str, Any],
    authority_commit: str,
) -> dict[str, Any]:
    if HEX40.fullmatch(authority_commit) is None:
        raise SelectionError("RISC-V authority commit is invalid")
    if (
        run.get("path") != WORKFLOW_PATH
        or run.get("event") != "workflow_dispatch"
        or run.get("head_branch") != "main"
        or run.get("head_sha") != authority_commit
        or run.get("repository", {}).get("full_name") != REPOSITORY
        or run.get("repository", {}).get("id") != REPOSITORY_ID
        or run.get("actor", {}).get("id") != OWNER_ID
        or run.get("triggering_actor", {}).get("id") != OWNER_ID
        or run.get("status") != "completed"
        or run.get("conclusion") != "success"
    ):
        raise SelectionError("RISC-V producer run is outside the authority boundary")
    run_id = positive_integer(run.get("id"), "producer run ID")
    attempt = positive_integer(run.get("run_attempt"), "producer run attempt")
    matched_jobs = [
        job for job in jobs.get("jobs", [])
        if isinstance(job, dict)
        and job.get("name") == PRODUCER_JOB_NAME
        and job.get("status") == "completed"
        and job.get("conclusion") == "success"
        and job.get("run_id") == run_id
        and job.get("run_attempt") == attempt
        and job.get("head_sha") == authority_commit
    ]
    if len(matched_jobs) != 1:
        raise SelectionError("RISC-V producer job is not uniquely successful")
    job_id = positive_integer(matched_jobs[0].get("id"), "producer job ID")
    live = [
        artifact for artifact in artifacts.get("artifacts", [])
        if isinstance(artifact, dict)
        and artifact.get("expired") is False
        and isinstance(artifact.get("name"), str)
        and ARTIFACT_NAME.fullmatch(artifact["name"]) is not None
        and artifact.get("workflow_run", {}).get("id") == run_id
        and artifact.get("workflow_run", {}).get("head_sha") == authority_commit
    ]
    if len(live) != 1:
        raise SelectionError("RISC-V producer does not have one exact live artifact")
    artifact = live[0]
    match = ARTIFACT_NAME.fullmatch(artifact["name"])
    assert match is not None
    anchor, name_run, name_attempt = match.groups()
    if (int(name_run), int(name_attempt)) != (run_id, attempt):
        raise SelectionError("RISC-V artifact name is not bound to its producer attempt")
    artifact_id = positive_integer(artifact.get("id"), "producer artifact ID")
    digest = artifact.get("digest")
    if not isinstance(digest, str) or ARTIFACT_DIGEST.fullmatch(digest) is None:
        raise SelectionError("RISC-V artifact digest is malformed")
    return {
        "schema": "architecture-riscv-anchor-selection-v1",
        "authority_commit": authority_commit,
        "anchor_candidate": anchor,
        "run_id": run_id,
        "run_attempt": attempt,
        "producer_job_id": job_id,
        "artifact_id": artifact_id,
        "artifact_name": artifact["name"],
        "artifact_digest": digest,
    }


def bind(
    *, selection: dict[str, Any], run: dict[str, Any], jobs: dict[str, Any],
    artifacts: dict[str, Any], commit: dict[str, Any], branches: list[Any],
    manifest: dict[str, Any], authority_commit: str, phase: str,
) -> dict[str, Any]:
    recomputed = select(
        run=run, jobs=jobs, artifacts=artifacts, authority_commit=authority_commit,
    )
    if selection != recomputed:
        raise SelectionError("RISC-V artifact selection changed before binding")
    candidate = selection["anchor_candidate"]
    tree = commit.get("tree", {}).get("sha")
    if commit.get("sha") != candidate or not isinstance(tree, str) or HEX40.fullmatch(tree) is None:
        raise SelectionError("RISC-V anchor commit/tree API identity is invalid")
    if manifest.get("schema") != "riscv-release-bundle-v3":
        raise SelectionError("RISC-V anchor manifest schema drifted")
    producer = manifest.get("producer")
    source_ref = producer.get("candidate", {}).get("source_ref") if isinstance(producer, dict) else None
    if not isinstance(source_ref, str) or not source_ref.startswith("refs/heads/"):
        raise SelectionError("RISC-V anchor source ref is not an explicit branch")
    branch = source_ref.removeprefix("refs/heads/")
    if not any(isinstance(item, dict) and item.get("name") == branch for item in branches):
        raise SelectionError("RISC-V anchor source branch no longer contains the commit")
    if phase not in {"candidate", "promoted"}:
        raise SelectionError("RISC-V anchor phase is invalid")
    expected = {
        "schema": "riscv-release-producer-trust-v1",
        "trust_root": "repository-owner-dispatch",
        "repository": {"full_name": REPOSITORY, "id": REPOSITORY_ID},
        "candidate": {
            "sha": candidate,
            "tree_oid": tree,
            "source_repository": REPOSITORY,
            "source_repository_id": REPOSITORY_ID,
            "source_ref": source_ref,
        },
        "workflow": {
            "path": WORKFLOW_PATH,
            "repository": REPOSITORY,
            "repository_id": REPOSITORY_ID,
            "ref": "refs/heads/main",
            "commit_sha": authority_commit,
        },
        "workflow_base": {"ref": "refs/heads/main", "sha": authority_commit},
        "event": "workflow_dispatch",
        "run": {"id": selection["run_id"], "attempt": selection["run_attempt"]},
        "actor": {"login": run.get("actor", {}).get("login"), "id": OWNER_ID},
        "triggering_actor": {
            "login": run.get("triggering_actor", {}).get("login"), "id": OWNER_ID,
        },
        "phase": phase,
        "artifact": {"name": selection["artifact_name"], "retention_days": 30},
    }
    if not all(
        isinstance(expected[name]["login"], str) and expected[name]["login"]
        for name in ("actor", "triggering_actor")
    ):
        raise SelectionError("RISC-V producer login identity is missing")
    if producer != expected:
        raise SelectionError("RISC-V manifest producer differs from authenticated API metadata")
    if (
        manifest.get("candidate_commit") != candidate
        or manifest.get("repository_tree_oid") != tree
        or manifest.get("phase") != phase
    ):
        raise SelectionError("RISC-V manifest statement identity differs from authenticated input")
    return expected


def write_json(path: Path, value: dict[str, Any]) -> None:
    path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    phases = parser.add_subparsers(dest="phase_name", required=True)
    choose = phases.add_parser("select")
    bind_parser = phases.add_parser("bind")
    for current in (choose, bind_parser):
        current.add_argument("--run", type=Path, required=True)
        current.add_argument("--jobs", type=Path, required=True)
        current.add_argument("--artifacts", type=Path, required=True)
        current.add_argument("--authority-commit", required=True)
        current.add_argument("--output", type=Path, required=True)
    bind_parser.add_argument("--selection", type=Path, required=True)
    bind_parser.add_argument("--commit", type=Path, required=True)
    bind_parser.add_argument("--branches", type=Path, required=True)
    bind_parser.add_argument("--manifest", type=Path, required=True)
    bind_parser.add_argument("--release-phase", choices=("candidate", "promoted"), required=True)
    args = parser.parse_args(argv)
    try:
        run = strict_json(args.run)
        jobs = strict_json(args.jobs)
        artifacts = strict_json(args.artifacts)
        if not all(isinstance(value, dict) for value in (run, jobs, artifacts)):
            raise SelectionError("RISC-V producer API roots must be objects")
        if args.phase_name == "select":
            value = select(
                run=run, jobs=jobs, artifacts=artifacts,
                authority_commit=args.authority_commit,
            )
        else:
            selection = strict_json(args.selection)
            commit = strict_json(args.commit)
            branches = strict_json(args.branches)
            manifest = strict_json(args.manifest)
            if not isinstance(selection, dict) or not isinstance(commit, dict) or not isinstance(manifest, dict) or not isinstance(branches, list):
                raise SelectionError("RISC-V anchor binding inputs have invalid roots")
            value = bind(
                selection=selection, run=run, jobs=jobs, artifacts=artifacts,
                commit=commit, branches=branches, manifest=manifest,
                authority_commit=args.authority_commit, phase=args.release_phase,
            )
        write_json(args.output, value)
    except (OSError, UnicodeError, json.JSONDecodeError, SelectionError) as error:
        print(f"RISC-V anchor selection: FAIL: {error}", file=sys.stderr)
        return 2
    print("RISC-V anchor selection: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
