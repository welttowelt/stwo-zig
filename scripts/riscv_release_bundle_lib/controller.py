"""CLI orchestration for immutable exhaustive evidence bundles."""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

from . import model


ROOT = Path(__file__).resolve().parents[2]


def producer_identity(args: argparse.Namespace) -> dict[str, object]:
    return {
        "repository": args.producer_repository,
        "workflow_ref": args.producer_workflow_ref,
        "run_id": args.producer_run_id,
        "run_attempt": args.producer_run_attempt,
        "event": args.producer_event,
        "head_sha": args.candidate,
    }


def validate_oracle_receipt(root: Path, receipt: Path, candidate: str) -> None:
    result = subprocess.run(
        [
            sys.executable,
            "scripts/riscv_release_evidence.py",
            "--receipt",
            str(receipt),
            "--candidate",
            candidate,
        ],
        cwd=root,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        diagnostic = (result.stderr or result.stdout).strip()
        raise model.BundleError(f"oracle receipt invalid: {diagnostic}")


def pack(args: argparse.Namespace) -> int:
    root = args.root.resolve()
    evidence = args.evidence_dir.resolve()
    output = args.output_dir.resolve()
    created_output = False
    try:
        tree = model.require_clean_head(root, args.candidate)
        if output.exists():
            raise model.BundleError(f"output directory already exists: {output}")
        gate = model.strict_json(evidence / "release-gate.json")
        oracle = model.strict_json(evidence / "oracle-receipt.json")
        summary = model.strict_json(evidence / "cli/summary.json")
        model.validate_gate_report(gate, args.candidate, args.phase)
        validate_oracle_receipt(root, evidence / "oracle-receipt.json", args.candidate)
        executable_sha256 = model.sha256_file(args.cli)
        model.validate_cli_summary(summary, args.candidate, args.phase, executable_sha256)

        output.mkdir(parents=True, exist_ok=False)
        created_output = True
        for name, relative in model.FILE_LAYOUT.items():
            source = {
                "release-gate.json": evidence / "release-gate.json",
                "oracle-receipt.json": evidence / "oracle-receipt.json",
                "cli/summary.json": evidence / "cli/summary.json",
                "bin/stwo-zig": args.cli,
            }[name]
            destination = output / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, destination)

        files = {
            name: model.file_record(output / relative)
            for name, relative in model.FILE_LAYOUT.items()
        }
        domains = model.source_domains(root)
        domains["oracle_build"] = model.oracle_domain(oracle)
        domains["toolchains"] = {
            "schema": "release-gate-toolchains-v1",
            "sha256": model.canonical_sha256(gate.get("toolchains")),
        }
        manifest = {
            "schema": model.SCHEMA,
            "phase": args.phase,
            "candidate_commit": args.candidate,
            "repository_tree_oid": tree,
            "coverage": model.COVERAGE,
            "producer": producer_identity(args),
            "domains": domains,
            "files": files,
        }
        model.atomic_write_json(output / "manifest.json", manifest)
        print(f"riscv release bundle: packed exhaustive evidence at {output}")
        return 0
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        if created_output and output.exists():
            shutil.rmtree(output)
        print(f"riscv release bundle: {error}", file=sys.stderr)
        return 1


def verify(args: argparse.Namespace) -> int:
    root = args.root.resolve()
    bundle = args.bundle.resolve()
    try:
        tree = model.require_clean_head(root, args.candidate)
        manifest = model.strict_json(bundle / "manifest.json")
        if manifest.get("schema") != model.SCHEMA:
            raise model.BundleError("bundle schema drifted")
        if (manifest.get("phase"), manifest.get("candidate_commit")) != (
            args.phase, args.candidate,
        ):
            raise model.BundleError("bundle is not bound to the requested phase and candidate")
        if manifest.get("repository_tree_oid") != tree:
            raise model.BundleError("bundle repository tree identity drifted")
        if manifest.get("coverage") != model.COVERAGE:
            raise model.BundleError("bundle exhaustive coverage declaration drifted")
        producer = manifest.get("producer")
        expected_producer = {
            "repository": args.producer_repository,
            "workflow_ref": args.producer_workflow_ref,
            "run_id": args.producer_run_id,
            "run_attempt": args.producer_run_attempt,
            "event": "push",
            "head_sha": args.candidate,
        }
        if producer != expected_producer:
            raise model.BundleError("bundle producer identity does not match the selected push run")
        files = model.validate_files(bundle, manifest)
        gate = model.strict_json(files["release-gate.json"])
        oracle = model.strict_json(files["oracle-receipt.json"])
        summary = model.strict_json(files["cli/summary.json"])
        model.validate_gate_report(gate, args.candidate, args.phase)
        validate_oracle_receipt(root, files["oracle-receipt.json"], args.candidate)
        model.validate_cli_summary(
            summary, args.candidate, args.phase, model.sha256_file(files["bin/stwo-zig"]),
        )
        domains = model.source_domains(root)
        domains["oracle_build"] = model.oracle_domain(oracle)
        domains["toolchains"] = {
            "schema": "release-gate-toolchains-v1",
            "sha256": model.canonical_sha256(gate.get("toolchains")),
        }
        if manifest.get("domains") != domains:
            raise model.BundleError("bundle source/toolchain content domains drifted")
        print("riscv release bundle: exact-source exhaustive evidence is valid")
        return 0
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"riscv release bundle: {error}", file=sys.stderr)
        return 1


def add_identity_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--phase", choices=("candidate", "promoted"), required=True)
    parser.add_argument("--producer-repository", required=True)
    parser.add_argument("--producer-workflow-ref", required=True)
    parser.add_argument("--producer-run-id", required=True)
    parser.add_argument("--producer-run-attempt", required=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    subparsers = parser.add_subparsers(dest="command", required=True)
    command = subparsers.add_parser("pack")
    add_identity_arguments(command)
    command.add_argument("--producer-event", choices=("push",), required=True)
    command.add_argument("--evidence-dir", type=Path, required=True)
    command.add_argument("--cli", type=Path, required=True)
    command.add_argument("--output-dir", type=Path, required=True)
    command.set_defaults(handler=pack)
    command = subparsers.add_parser("verify")
    add_identity_arguments(command)
    command.add_argument("--bundle", type=Path, required=True)
    command.set_defaults(handler=verify)
    args = parser.parse_args(argv)
    return args.handler(args)
