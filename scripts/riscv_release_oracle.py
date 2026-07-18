#!/usr/bin/env python3
"""CP-11 producer: build the pinned Stark-V oracle and compare shared boundaries.

Produces the machine-readable receipt required by
conformance/2026-07-18-riscv-release-goal.md. Every boundary named by the
contract appears in the receipt with an explicit status; boundaries whose
comparison is not yet implemented are recorded as "unimplemented" and the
receipt's overall verdict is FAIL-closed until every boundary passes. The
receipt never claims a comparison that did not run.

Producer:
  python3 scripts/riscv_release_oracle.py build-and-compare \
    --stark-v-source "$STARK_V_SOURCE" \
    --candidate "$(git rev-parse HEAD)" \
    --receipt-out zig-out/release-evidence/riscv/oracle-receipt.json

Validator:
  python3 scripts/riscv_release_oracle.py validate \
    --receipt zig-out/release-evidence/riscv/oracle-receipt.json
"""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PINNED = "d478f783055aa0d73a93768a433a3c6c31c91d1c"

# The trace-dump adapter is a thin serializer over the oracle's own runner
# crate (a duplicated standalone model is not acceptable per CP-11; a
# recorded overlay that only formats RunResult is). Its exact content is
# hashed into the receipt.
ADAPTER_REL = "crates/runner/src/bin/cp11_trace_dump.rs"
ADAPTER_SOURCE = '''//! CP-11 receipt adapter: serialize runner::run output, nothing more.
use std::env;
use std::fs;

fn main() {
    let args: Vec<String> = env::args().collect();
    let mut elf: Option<String> = None;
    let mut max: u64 = 1_000_000;
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--elf" => { i += 1; elf = Some(args[i].clone()); }
            "--max-steps" => { i += 1; max = args[i].parse().expect("max-steps"); }
            _ => {}
        }
        i += 1;
    }
    let bytes = fs::read(elf.expect("--elf required")).expect("read elf");
    let result = runner::run(&bytes, max).expect("run");
    let regs: Vec<String> = result.final_regs.iter().map(|r| r.to_string()).collect();
    println!(
        "{{\\"steps\\":[],\\"final_pc\\":{},\\"final_regs\\":[{}],\\"total_steps\\":{}}}",
        result.final_pc,
        regs.join(","),
        result.cycles
    );
}
'''

BOUNDARIES = [
    "decode",
    "execution",
    "per_family_witness_rows",
    "program_tuples",
    "ordered_accesses",
    "public_values",
    "memory_roots",
    "poseidon2_vectors",
    "relation_tuples",
    "relation_sums",
    "shared_transcript_prefix",
]


def _run(cmd: list[str], cwd: Path | None = None) -> str:
    return subprocess.run(cmd, cwd=cwd, check=True, capture_output=True, text=True).stdout


def _sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _tree_digest(source: Path) -> str:
    out = _run(["git", "ls-files", "-s"], cwd=source)
    return hashlib.sha256(out.encode()).hexdigest()


def build_oracle(source: Path, receipt: dict) -> Path:
    head = _run(["git", "rev-parse", "HEAD"], cwd=source).strip()
    if head != PINNED:
        raise SystemExit(f"oracle checkout at {head}, pinned {PINNED}")
    dirty = subprocess.run(
        ["git", "status", "--porcelain"], cwd=source, check=True, capture_output=True, text=True
    ).stdout.strip()
    if dirty:
        raise SystemExit("oracle checkout is not clean; refusing to build")
    submodule = _run(["git", "submodule", "status", "--recursive"], cwd=source)
    tree_digest = _tree_digest(source)

    adapter_path = source / ADAPTER_REL
    adapter_path.parent.mkdir(parents=True, exist_ok=True)
    adapter_path.write_text(ADAPTER_SOURCE)
    try:
        toolchain = _run(["rustc", "--version"], cwd=source).strip()
        build_cmd = ["cargo", "build", "--release", "-p", "runner"]
        _run(build_cmd, cwd=source)
        exe = source / "target" / "release" / "cp11_trace_dump"
        receipt["oracle"] = {
            "repository": "https://github.com/ClementWalter/stark-v",
            "commit": head,
            "tree_digest_sha256": tree_digest,
            "submodule_status": submodule.strip().splitlines(),
            "lockfile_sha256": _sha256_file(source / "Cargo.lock"),
            "toolchain": toolchain,
            "build_command": " ".join(build_cmd),
            "build_mode": "release",
            "adapter_overlay": {
                "path": ADAPTER_REL,
                "sha256": hashlib.sha256(ADAPTER_SOURCE.encode()).hexdigest(),
                "note": "thin serializer over the oracle's own runner crate; "
                "applied after tree digest, removed after build",
            },
            "executable_sha256": _sha256_file(exe),
            "host_arch": platform.machine(),
            "host_os": f"{platform.system()} {platform.release()}",
        }
        return exe
    finally:
        adapter_path.unlink(missing_ok=True)
        try:
            adapter_path.parent.rmdir()
        except OSError:
            pass


def compare_execution(oracle_exe: Path, receipt: dict) -> None:
    """Executor-corpus boundary: the committed trace-vector ELFs through both
    implementations, over the equivalence contract fields."""
    subprocess.run(
        ["zig", "build", "riscv-trace-dump", "-Doptimize=ReleaseFast"], cwd=ROOT, check=True
    )
    zig_exe = ROOT / "zig-out" / "bin" / "riscv-trace-dump"
    vectors = json.loads((ROOT / "vectors" / "riscv_elfs" / "trace_vectors.json").read_text())
    if vectors["stark_v_commit"] != PINNED:
        raise SystemExit("trace vectors pinned to a different oracle commit")
    cases = []
    all_ok = True
    for vector in vectors["vectors"]:
        elf = ROOT / vector["elf"]
        rust = json.loads(_run([str(oracle_exe), "--elf", str(elf)]))
        zig = json.loads(_run([str(zig_exe), "--elf", str(elf)], cwd=ROOT))
        ok = all(rust[k] == zig[k] for k in ("total_steps", "final_pc", "final_regs"))
        all_ok = all_ok and ok
        cases.append(
            {
                "name": vector["name"],
                "elf_sha256": vector["elf_sha256"],
                "agree": ok,
                "total_steps": zig["total_steps"],
                "final_pc": zig["final_pc"],
            }
        )
    receipt["boundaries"]["execution"] = {
        "status": "pass" if all_ok else "fail",
        "fields": ["total_steps", "final_pc", "final_regs"],
        "corpus": cases,
    }
    # Decode agreement is implied per-corpus by execution agreement only for
    # executed paths; the exhaustive decode matrix remains its own boundary.


def build_and_compare(args) -> int:
    source = Path(args.stark_v_source).resolve()
    receipt: dict = {
        "schema": "riscv-oracle-receipt-v1",
        "candidate_commit": args.candidate,
        "boundaries": {name: {"status": "unimplemented"} for name in BOUNDARIES},
    }
    oracle_exe = build_oracle(source, receipt)
    compare_execution(oracle_exe, receipt)
    receipt["verdict"] = (
        "PASS"
        if all(b.get("status") == "pass" for b in receipt["boundaries"].values())
        else "FAIL"
    )
    out = Path(args.receipt_out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(receipt, indent=1) + "\n")
    print(f"receipt written: {out} (verdict {receipt['verdict']})")
    for name, boundary in receipt["boundaries"].items():
        print(f"  {name}: {boundary['status']}")
    return 0 if receipt["verdict"] == "PASS" else 1


def validate(args) -> int:
    receipt = json.loads(Path(args.receipt).read_text())
    errors = []
    if receipt.get("schema") != "riscv-oracle-receipt-v1":
        errors.append("unknown receipt schema")
    if receipt.get("oracle", {}).get("commit") != PINNED:
        errors.append("receipt oracle commit is not the pinned revision")
    for name in BOUNDARIES:
        status = receipt.get("boundaries", {}).get(name, {}).get("status")
        if status != "pass":
            errors.append(f"boundary {name}: {status or 'missing'}")
    if receipt.get("verdict") != "PASS":
        errors.append(f"verdict {receipt.get('verdict')}")
    for error in errors:
        print(f"oracle receipt: {error}", file=sys.stderr)
    if not errors:
        print("oracle receipt: all boundaries pass at the pinned revision")
    return 1 if errors else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="mode", required=True)
    p = sub.add_parser("build-and-compare")
    p.add_argument("--stark-v-source", required=True)
    p.add_argument("--candidate", required=True)
    p.add_argument("--receipt-out", required=True)
    p = sub.add_parser("validate")
    p.add_argument("--receipt", required=True)
    args = parser.parse_args(argv)
    return build_and_compare(args) if args.mode == "build-and-compare" else validate(args)


if __name__ == "__main__":
    raise SystemExit(main())
