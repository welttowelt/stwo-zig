#!/usr/bin/env python3
"""Staged riscv CLI smoke: prove, independently verify, and reject tampering.

Exercises the installed CLI end to end on a committed, cross-verified vector
ELF: `prove --elf` must produce a v3 artifact that a separate `verify
--artifact` invocation cryptographically accepts (printing its honest
release status), and a single-bit tamper of the public statement must be
rejected. Part of the riscv release gate; also runnable standalone.
"""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ELF = "vectors/riscv_elfs/branch_fib.elf"
MULTI_SHARD_INSTRUCTIONS = 65_537
MULTI_SHARD_ELF_SHA256 = "3a65a4ad336fdef2f566472b74c738ce6671f0121e22f9a9f32f2a393a4893a8"
WITNESS_LAYOUT_SHA256 = "8896dea17812761ba2246e07508c6d11d455f08519984c0512ce9e7093143b79"


def write_multi_shard_elf(path: Path) -> None:
    sys.path.insert(0, str(ROOT / "scripts"))
    import riscv_trace_vectors as vectors  # pylint: disable=import-outside-toplevel

    elf = vectors.build_elf(
        [vectors.ADDI(1, 1, 1)] * MULTI_SHARD_INSTRUCTIONS
    )
    digest = hashlib.sha256(elf).hexdigest()
    if digest != MULTI_SHARD_ELF_SHA256:
        raise RuntimeError(f"multi-shard ELF digest drift: {digest}")
    path.write_bytes(elf)


def command(cli: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(cli), *args], cwd=ROOT, capture_output=True, text=True,
    )


def read_uleb(data: bytes, start: int) -> tuple[int, int]:
    value = 0
    shift = 0
    position = start
    while position < len(data) and shift < 70:
        byte = data[position]
        position += 1
        value |= (byte & 0x7f) << shift
        if not byte & 0x80:
            return value, position
        shift += 7
    raise ValueError("invalid postcard ULEB128")


def write_uleb(value: int) -> bytes:
    encoded = bytearray()
    while value >= 0x80:
        encoded.append((value & 0x7f) | 0x80)
        value >>= 7
    encoded.append(value)
    return bytes(encoded)


def proof_wire_mutations(proof_hex: str) -> dict[str, str]:
    raw = bytes.fromhex(proof_hex)
    position = 0
    # PcsConfig: five ULEB scalars, then Option<u32> lifting log size.
    for _ in range(5):
        _, position = read_uleb(raw, position)
    lifting_tag = raw[position]
    position += 1
    if lifting_tag == 1:
        _, position = read_uleb(raw, position)
    elif lifting_tag != 0:
        raise ValueError("invalid postcard lifting-log option")
    commitments_start = position
    _, commitments_end = read_uleb(raw, commitments_start)
    length_bomb = (raw[:commitments_start] + write_uleb(1 << 32) +
                   raw[commitments_end:])
    return {
        "trailing": (raw + b"\x00").hex(),
        "truncated": raw[:-1].hex(),
        "length-bomb": length_bomb.hex(),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--phase", choices=("candidate", "promoted"), default="candidate")
    parser.add_argument("--evidence-dir", type=Path)
    args = parser.parse_args()
    candidate = args.phase == "candidate"
    expected_status = "not_release_gated" if candidate else "release_gated"

    subprocess.run(["zig", "build", "stwo-zig", "-Doptimize=ReleaseFast"], cwd=ROOT, check=True)
    cli = ROOT / "zig-out" / "bin" / "stwo-zig"
    registry = json.loads(command(cli, "applications").stdout)
    deferred = {entry["adapter"]: entry for entry in registry["deferred_adapters"]}
    applications = {entry.get("adapter"): entry for entry in registry["applications"]}
    if candidate:
        if deferred.get("stark-v-rv32im-elf", {}).get("status") != expected_status:
            print("riscv staged smoke: candidate registry is not fail closed", file=sys.stderr)
            return 1
    elif applications.get("stark-v-rv32im-elf", {}).get("status") != expected_status:
        print("riscv staged smoke: promoted registry entry is absent", file=sys.stderr)
        return 1

    if args.evidence_dir:
        evidence_dir = args.evidence_dir.resolve()
        evidence_dir.mkdir(parents=True, exist_ok=False)
        workspace = contextlib.nullcontext(str(evidence_dir))
    else:
        workspace = tempfile.TemporaryDirectory()

    with workspace as tmp:
        multi_shard_elf = Path(tmp) / "multi_shard_addi.elf"
        write_multi_shard_elf(multi_shard_elf)
        artifact = Path(tmp) / "proof.json"
        report = Path(tmp) / "report.json"
        benchmark_report = Path(tmp) / "benchmark.json"
        denied_artifact = Path(tmp) / "denied.json"
        denied_report = Path(tmp) / "denied-report.json"
        admission = [
            "prove", "--elf", str(multi_shard_elf), "--backend", "cpu", "--protocol", "functional",
            "--output", str(denied_artifact), "--report-out", str(denied_report),
        ]
        if not candidate:
            admission.append("--experimental")
        denied = command(cli, *admission)
        if denied.returncode == 0 or denied_artifact.exists() or denied_report.exists():
            expectation = "missing" if candidate else "present"
            print(f"riscv staged smoke: --experimental {expectation} was admitted",
                  file=sys.stderr)
            return 1

        irrelevant = command(
            cli, "verify", "--artifact", "does-not-exist.json", "--experimental",
        )
        if irrelevant.returncode == 0:
            print("riscv staged smoke: irrelevant --experimental was admitted", file=sys.stderr)
            return 1

        prove_args = [
            "prove", "--elf", str(multi_shard_elf), "--backend", "cpu", "--protocol", "functional",
            "--output", str(artifact), "--report-out", str(report),
        ]
        if candidate:
            prove_args.append("--experimental")
        prove = command(cli, *prove_args)
        if prove.returncode != 0:
            print(f"riscv staged smoke: prove failed: {prove.stdout}{prove.stderr}",
                  file=sys.stderr)
            return 1
        if not artifact.is_file() or not report.is_file():
            print("riscv staged smoke: atomic artifact/report publication is incomplete",
                  file=sys.stderr)
            return 1
        payload = json.loads(artifact.read_text())
        report_payload = json.loads(report.read_text())
        provenance = payload.get("provenance", {})
        source = payload.get("source", {})
        statement = payload.get("statement", {})
        if payload.get("artifact_kind") != "stwo_riscv_proof" or \
                payload.get("schema_version") != 3 or \
                payload.get("exchange_mode") != "riscv_proof_json_wire_v3":
            print("riscv staged smoke: artifact is not the exact schema-v3 contract",
                  file=sys.stderr)
            return 1
        if source.get("elf_sha256") != MULTI_SHARD_ELF_SHA256 or \
                source.get("input_sha256") != hashlib.sha256(b"").hexdigest():
            print("riscv staged smoke: artifact source identity drifted", file=sys.stderr)
            return 1
        implementation_commit = provenance.get("implementation_commit", "")
        if len(implementation_commit) != 40 or \
                any(byte not in "0123456789abcdef" for byte in implementation_commit) or \
                not isinstance(provenance.get("implementation_dirty"), bool) or \
                provenance.get("witness_layout_sha256") != WITNESS_LAYOUT_SHA256:
            print("riscv staged smoke: artifact build/layout provenance is incomplete",
                  file=sys.stderr)
            return 1
        if statement.get("segment_ordinal") != 0 or statement.get("segment_count") != 1:
            print("riscv staged smoke: artifact segment geometry drifted", file=sys.stderr)
            return 1
        if payload["release_status"] != expected_status or \
                report_payload["release_status"] != expected_status:
            print("riscv staged smoke: artifact/report release status drifted", file=sys.stderr)
            return 1
        if report_payload["experimental"] is not candidate:
            print("riscv staged smoke: report lost typed admission state", file=sys.stderr)
            return 1
        family_counts: dict[int, int] = {}
        for component in payload["statement"]["components"]:
            family = component["family"]
            family_counts[family] = family_counts.get(family, 0) + 1
        if report_payload["total_steps"] != MULTI_SHARD_INSTRUCTIONS or \
                max(family_counts.values(), default=0) < 2:
            print("riscv staged smoke: installed CLI proof did not cross a family shard",
                  file=sys.stderr)
            return 1
        statement_digest = report_payload["statement_sha256"]
        verify = command(
            cli, "verify", "--artifact", str(artifact), "--protocol", "functional",
            "--expect-statement-digest", statement_digest,
        )
        if verify.returncode != 0 or "proof VERIFIED" not in verify.stdout:
            print(f"riscv staged smoke: honest artifact rejected: {verify.stdout}"
                  f"{verify.stderr}", file=sys.stderr)
            return 1
        wrong_digest = "00" * 32 if statement_digest != "00" * 32 else "11" * 32
        wrong_statement = command(
            cli, "verify", "--artifact", str(artifact), "--protocol", "functional",
            "--expect-statement-digest", wrong_digest,
        )
        if wrong_statement.returncode == 0:
            print("riscv staged smoke: wrong external statement digest accepted",
                  file=sys.stderr)
            return 1
        downgrade = command(
            cli, "verify", "--artifact", str(artifact),
            "--expect-statement-digest", statement_digest,
        )
        if downgrade.returncode == 0:
            print("riscv staged smoke: functional artifact passed default secure policy",
                  file=sys.stderr)
            return 1
        payload["statement"]["final_pc"] ^= 4
        tampered = Path(tmp) / "tampered.json"
        tampered.write_text(json.dumps(payload))
        tamper = command(
            cli, "verify", "--artifact", str(tampered), "--protocol", "functional",
            "--expect-statement-digest", statement_digest,
        )
        if tamper.returncode == 0:
            print("riscv staged smoke: TAMPERED ARTIFACT ACCEPTED", file=sys.stderr)
            return 1
        provenance_tampered = Path(tmp) / "provenance-tampered.json"
        payload = json.loads(artifact.read_text())
        payload["provenance"]["witness_layout_sha256"] = "00" * 32
        provenance_tampered.write_text(json.dumps(payload))
        provenance_tamper = command(
            cli, "verify", "--artifact", str(provenance_tampered),
            "--protocol", "functional", "--expect-statement-digest", statement_digest,
        )
        if provenance_tamper.returncode == 0:
            print("riscv staged smoke: MUTATED PROVENANCE ACCEPTED", file=sys.stderr)
            return 1
        expected_wire_errors = {
            "trailing": "TrailingProofBytes",
            "truncated": "EndOfStream",
            "length-bomb": "InvalidProofShape",
        }
        proof_wire_results: dict[str, dict[str, object]] = {}
        for mutation, proof_hex in proof_wire_mutations(
                json.loads(artifact.read_text())["proof_bytes_hex"]).items():
            mutated_payload = json.loads(artifact.read_text())
            mutated_payload["proof_bytes_hex"] = proof_hex
            mutation_path = Path(tmp) / f"proof-{mutation}.json"
            mutation_path.write_text(json.dumps(mutated_payload))
            result = command(
                cli, "verify", "--artifact", str(mutation_path),
                "--protocol", "functional",
                "--expect-statement-digest", statement_digest,
            )
            expected_error = expected_wire_errors[mutation]
            proof_wire_results[mutation] = {
                "returncode": result.returncode,
                "expected_error": expected_error,
                "stderr_sha256": hashlib.sha256(result.stderr.encode()).hexdigest(),
            }
            if result.returncode == 0 or expected_error not in result.stderr:
                print(f"riscv staged smoke: {mutation} proof wire did not fail as "
                      f"{expected_error}: {result.stderr}",
                      file=sys.stderr)
                return 1
        bench_args = [
            "bench", "--elf", ELF, "--backend", "cpu", "--protocol", "functional",
            "--warmups", "0", "--samples", "2", "--report-out", str(benchmark_report),
        ]
        if candidate:
            bench_args.append("--experimental")
        benchmark = command(cli, *bench_args)
        if benchmark.returncode != 0:
            print(f"riscv staged smoke: benchmark failed: {benchmark.stdout}{benchmark.stderr}",
                  file=sys.stderr)
            return 1
        benchmark_payload = json.loads(benchmark_report.read_text())
        if benchmark_payload["schema"] != "riscv_proof_v1" or \
                benchmark_payload["release_status"] != expected_status or \
                benchmark_payload["verified_samples"] != 2:
            print("riscv staged smoke: benchmark report contract drifted", file=sys.stderr)
            return 1

        if args.evidence_dir:
            digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
            summary = {
                "schema": "riscv_cli_evidence_v1",
                "phase": args.phase,
                "release_status": expected_status,
                "generator": "scripts/riscv_trace_vectors.py::build_elf",
                "multi_shard_instruction": "ADDI x1,x1,1",
                "multi_shard_instruction_count": MULTI_SHARD_INSTRUCTIONS,
                "multi_shard_elf_sha256": MULTI_SHARD_ELF_SHA256,
                "total_steps": report_payload["total_steps"],
                "n_components": report_payload["n_components"],
                "family_component_counts": family_counts,
                "statement_sha256": statement_digest,
                "artifact_sha256": digest(artifact),
                "report_sha256": digest(report),
                "benchmark_report_sha256": digest(benchmark_report),
                "tampered_artifact_sha256": digest(tampered),
                "independent_verify_returncode": verify.returncode,
                "wrong_statement_returncode": wrong_statement.returncode,
                "policy_downgrade_returncode": downgrade.returncode,
                "tamper_returncode": tamper.returncode,
                "proof_wire_mutation_returncodes": proof_wire_results,
            }
            (Path(tmp) / "summary.json").write_text(
                json.dumps(summary, indent=2, sort_keys=True) + "\n"
            )
    print(f"riscv {args.phase} smoke: admission, prove, independent verify, "
          "policy, and tamper gates all hold")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
