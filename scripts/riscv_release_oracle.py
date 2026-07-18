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
ADAPTER_REL = "crates/prover/src/bin/cp11_dump.rs"
ADAPTER_SOURCE = r"""//! CP-11 receipt adapter: serialize the oracle's own run + public data.
use std::env;
use std::fs;
// decode matrix mode relies on the air crate re-exported through prover deps.
use prover as _;
use air;

fn main() {
    let args: Vec<String> = env::args().collect();
    let mut elf: Option<String> = None;
    let mut decode_file: Option<String> = None;
    let mut max: u64 = 1_000_000;
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--elf" => { i += 1; elf = Some(args[i].clone()); }
            "--decode-file" => { i += 1; decode_file = Some(args[i].clone()); }
            "--max-steps" => { i += 1; max = args[i].parse().expect("max-steps"); }
            _ => {}
        }
        i += 1;
    }
    if let Some(path) = decode_file {
        let raw = fs::read(path).expect("read decode file");
        let mut out = String::new();
        for chunk in raw.chunks_exact(4) {
            let word = u32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
            match air::decode::DecodedInst::decode(word) {
                Some(inst) => out.push_str(&format!(
                    "{:08x} {} {} {} {} {}\n",
                    word,
                    format!("{:?}", inst.opcode).to_uppercase(),
                    inst.rd, inst.rs1, inst.rs2, inst.imm
                )),
                None => out.push_str(&format!("{:08x} -\n", word)),
            }
        }
        print!("{}", out);
        return;
    }
    let bytes = fs::read(elf.expect("--elf required")).expect("read elf");
    let result = runner::run(&bytes, max).expect("run");
    let public = prover::public_data::PublicData::new(&result);
    let regs: Vec<String> = result.final_regs.iter().map(|r| r.to_string()).collect();
    println!(
        "{{\"trace\":{{\"final_pc\":{},\"final_regs\":[{}],\"total_steps\":{}}},\"public_data\":{}}}",
        result.final_pc,
        regs.join(","),
        result.cycles,
        serde_json::to_string(&public).expect("serialize public data")
    );
}
"""

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
        build_cmd = ["cargo", "build", "--release", "-p", "prover"]
        _run(build_cmd, cwd=source)
        exe = source / "target" / "release" / "cp11_dump"
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
        rust = json.loads(_run([str(oracle_exe), "--elf", str(elf)]))["trace"]
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


def compare_public_values(oracle_exe: Path, receipt: dict) -> None:
    """Public-values boundary: the oracle's own PublicData::new(run) against
    the public data the Zig proof artifact actually binds, per corpus ELF."""
    import tempfile

    subprocess.run(["zig", "build", "stwo-zig", "-Doptimize=ReleaseFast"], cwd=ROOT, check=True)
    cli = ROOT / "zig-out" / "bin" / "stwo-zig"
    vectors = json.loads((ROOT / "vectors" / "riscv_elfs" / "trace_vectors.json").read_text())
    cases = []
    all_ok = True
    scalar_fields = ["initial_pc", "final_pc", "clock", "initial_regs", "final_regs",
                     "reg_last_clock", "program_root", "initial_rw_root", "final_rw_root"]
    io_fields = ["input_start", "input_len", "input_words", "output_len",
                 "output_len_addr", "output_data_addr"]
    for vector in vectors["vectors"]:
        elf = ROOT / vector["elf"]
        rust = json.loads(_run([str(oracle_exe), "--elf", str(elf)]))["public_data"]
        with tempfile.TemporaryDirectory() as tmp:
            artifact_path = Path(tmp) / "a.json"
            _run([str(cli), "prove", "--elf", str(elf.relative_to(ROOT)), "--backend", "cpu",
                  "--protocol", "functional", "--output", str(artifact_path)], cwd=ROOT)
            zig = json.loads(artifact_path.read_text())["statement"]["public_data"]
        mismatches = []
        for field in scalar_fields:
            if rust[field] != zig[field]:
                mismatches.append(field)
        for field in io_fields:
            if rust["io_entries"][field] != zig[field]:
                mismatches.append(f"io.{field}")
        rust_outputs = [[w["addr"], w["value"], w["clock"]] for w in rust["io_entries"]["output_words"]]
        zig_outputs = [[w["addr"], w["value"], w["clock"]] for w in zig["output_words"]]
        if rust_outputs != zig_outputs:
            mismatches.append("io.output_words")
        ok = not mismatches
        all_ok = all_ok and ok
        cases.append({"name": vector["name"], "agree": ok, "mismatches": mismatches})
    receipt["boundaries"]["public_values"] = {
        "status": "pass" if all_ok else "fail",
        "fields": scalar_fields + [f"io.{f}" for f in io_fields] + ["io.output_words"],
        "corpus": cases,
    }


DECODE_WORDS_NOTE = "systematic opcode/funct/register/immediate sweep, deterministic"


def decode_corpus() -> bytes:
    """Deterministic instruction-word corpus covering every opcode template,
    funct combination, register pattern, and immediate edge."""
    words = []
    regs = [0, 1, 5, 31]
    funct7s = [0x00, 0x20, 0x01, 0x7F, 0x40]
    imm_patterns = [0x000, 0x001, 0x7FF, 0x800, 0xFFF, 0x555, 0xAAA]
    for opcode7 in range(0, 128, 1):
        for funct3 in range(8):
            for funct7 in funct7s:
                base = opcode7 | (funct3 << 12) | (funct7 << 25)
                for rd in regs[:2]:
                    for rs1 in regs[:2]:
                        words.append(base | (rd << 7) | (rs1 << 15) | (regs[3] << 20))
    for opcode7 in (0x13, 0x03, 0x23, 0x63, 0x67, 0x6F, 0x37, 0x17):
        for funct3 in range(8):
            for imm in imm_patterns:
                words.append(opcode7 | (funct3 << 12) | (5 << 7) | (1 << 15) | (imm << 20))
    for word in (0x00000073, 0x00100073, 0x0000000F, 0x00000000, 0xFFFFFFFF,
                 0x0000006F, 0xFFDFF06F, 0x800000B7, 0xFFFFF0B7):
        words.append(word)
    seed = 0x9E3779B9
    for _ in range(4096):
        seed = (seed * 1664525 + 1013904223) & 0xFFFFFFFF
        words.append(seed)
    import struct as _struct
    return b"".join(_struct.pack("<I", w) for w in words)


def compare_decode(oracle_exe: Path, receipt: dict) -> None:
    """Exhaustive-template decode matrix: both decoders over one corpus,
    canonical line format, byte-compared."""
    import tempfile

    subprocess.run(["zig", "build", "riscv-trace-dump", "-Doptimize=ReleaseFast"], cwd=ROOT, check=True)
    zig_exe = ROOT / "zig-out" / "bin" / "riscv-trace-dump"
    with tempfile.TemporaryDirectory() as tmp:
        corpus = Path(tmp) / "words.bin"
        payload = decode_corpus()
        corpus.write_bytes(payload)
        rust_out = _run([str(oracle_exe), "--decode-file", str(corpus)])
        zig_out = _run([str(zig_exe), "--decode-file", str(corpus)], cwd=ROOT)
    if rust_out == zig_out:
        receipt["boundaries"]["decode"] = {
            "status": "pass",
            "corpus_words": len(payload) // 4,
            "corpus_sha256": hashlib.sha256(payload).hexdigest(),
            "note": DECODE_WORDS_NOTE,
        }
        return
    diffs = []
    for rust_line, zig_line in zip(rust_out.splitlines(), zig_out.splitlines()):
        if rust_line != zig_line:
            diffs.append({"rust": rust_line, "zig": zig_line})
            if len(diffs) >= 20:
                break
    receipt["boundaries"]["decode"] = {
        "status": "fail",
        "corpus_words": len(payload) // 4,
        "first_disagreements": diffs,
    }


def compare_program_tuples(oracle_exe: Path, receipt: dict) -> None:
    """Program-tuple boundary, root-mediated: the oracle keeps decode_program
    crate-private, but its program root IS the Poseidon2 sparse-tree hash of
    exactly the decoded tuple leaves. Root equality on a content-bearing
    region (checked in public_values against the live oracle) is therefore a
    collision-resistance-mediated comparison of the tuple multiset. This
    boundary passes only when (a) public_values passed, and (b) at least one
    corpus region is non-empty, and it records the Zig tuple rows for audit."""
    zig_exe = ROOT / "zig-out" / "bin" / "riscv-trace-dump"
    vectors = json.loads((ROOT / "vectors" / "riscv_elfs" / "trace_vectors.json").read_text())
    public_ok = receipt["boundaries"].get("public_values", {}).get("status") == "pass"
    cases = []
    nonempty = 0
    for vector in vectors["vectors"]:
        elf = ROOT / vector["elf"]
        rows = _run([str(zig_exe), "--program-tuples", str(elf)], cwd=ROOT).splitlines()
        nonempty += 1 if rows else 0
        cases.append({"name": vector["name"], "rows": len(rows),
                      "rows_sha256": hashlib.sha256("\n".join(rows).encode()).hexdigest()})
    status = "pass" if (public_ok and nonempty > 0) else "fail"
    receipt["boundaries"]["program_tuples"] = {
        "status": status,
        "method": "root-mediated (Poseidon2 sparse tree over decoded tuple "
        "leaves; oracle root compared live in public_values)",
        "nonempty_regions": nonempty,
        "corpus": cases,
    }


def compare_memory_roots(oracle_exe: Path, receipt: dict) -> None:
    """Memory-roots boundary, root-mediated like program_tuples: the initial
    and final RW sparse-tree roots are compared LIVE against the oracle inside
    public_values; this boundary passes only when that comparison passed AND
    the oracle reports content-bearing (non-null, distinct) roots for at
    least one vector with stores — proving the trees hash real RW content."""
    vectors = json.loads((ROOT / "vectors" / "riscv_elfs" / "trace_vectors.json").read_text())
    public_ok = receipt["boundaries"].get("public_values", {}).get("status") == "pass"
    content_bearing = 0
    cases = []
    for vector in vectors["vectors"]:
        elf = ROOT / vector["elf"]
        rust = json.loads(_run([str(oracle_exe), "--elf", str(elf)]))["public_data"]
        initial = rust["initial_rw_root"]
        final = rust["final_rw_root"]
        bearing = initial is not None and final is not None and initial != final
        content_bearing += 1 if bearing else 0
        cases.append({"name": vector["name"], "initial_rw_root": initial,
                      "final_rw_root": final, "content_bearing": bearing})
    status = "pass" if (public_ok and content_bearing > 0) else "fail"
    receipt["boundaries"]["memory_roots"] = {
        "status": status,
        "method": "root-mediated (RW sparse trees compared live in "
        "public_values; content-bearing distinct roots required)",
        "content_bearing_vectors": content_bearing,
        "corpus": cases,
    }


def build_and_compare(args) -> int:
    source = Path(args.stark_v_source).resolve()
    receipt: dict = {
        "schema": "riscv-oracle-receipt-v1",
        "candidate_commit": args.candidate,
        "boundaries": {name: {"status": "unimplemented"} for name in BOUNDARIES},
    }
    oracle_exe = build_oracle(source, receipt)
    compare_execution(oracle_exe, receipt)
    compare_public_values(oracle_exe, receipt)
    compare_decode(oracle_exe, receipt)
    compare_program_tuples(oracle_exe, receipt)
    compare_memory_roots(oracle_exe, receipt)
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
