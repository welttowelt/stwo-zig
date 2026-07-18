"""Canonical RISC-V witness and ordered-access boundary comparisons."""

from __future__ import annotations

import hashlib
import json
import subprocess
from pathlib import Path


def load_trace_vectors(root: Path, pinned: str, receipt: dict) -> dict:
    manifest_path = root / "vectors" / "riscv_elfs" / "trace_vectors.json"
    manifest_bytes = manifest_path.read_bytes()
    vectors = json.loads(manifest_bytes)
    if vectors["stark_v_commit"] != pinned:
        raise SystemExit("trace vectors pinned to a different oracle commit")

    digest = hashlib.sha256()
    digest.update(manifest_bytes)
    for vector in vectors["vectors"]:
        elf = root / vector["elf"]
        elf_bytes = elf.read_bytes()
        actual = hashlib.sha256(elf_bytes).hexdigest()
        if actual != vector["elf_sha256"]:
            raise SystemExit(f"ELF digest mismatch for {vector['name']}: {actual}")
        digest.update(vector["name"].encode())
        digest.update(b"\0")
        digest.update(elf_bytes)
    receipt["corpus_digest_sha256"] = digest.hexdigest()
    return vectors


def _run(command: list[str], cwd: Path | None = None) -> str:
    return subprocess.run(
        command,
        cwd=cwd,
        check=True,
        capture_output=True,
        text=True,
    ).stdout


def _first_line_difference(rust: str, zig: str) -> dict[str, object] | None:
    rust_lines = rust.splitlines()
    zig_lines = zig.splitlines()
    for index in range(max(len(rust_lines), len(zig_lines))):
        rust_line = rust_lines[index] if index < len(rust_lines) else None
        zig_line = zig_lines[index] if index < len(zig_lines) else None
        if rust_line != zig_line:
            return {"line": index + 1, "rust": rust_line, "zig": zig_line}
    return None


def _witness_layout(output: str) -> bytes:
    layout = []
    lines = output.splitlines()
    for index, line in enumerate(lines):
        if not line.startswith("family="):
            continue
        fields = dict(part.split("=", 1) for part in line.split())
        if index + 1 >= len(lines) or not lines[index + 1].startswith("names="):
            raise SystemExit(f"malformed witness layout after {fields['family']}")
        layout.append(
            f"family={fields['family']} columns={fields['columns']}\n{lines[index + 1]}\n"
        )
    if not layout:
        raise SystemExit("witness dump contains no family layouts")
    return "".join(layout).encode()


def _compare_canonical_dump(
    oracle_exe: Path,
    receipt: dict,
    root: Path,
    pinned: str,
    *,
    boundary: str,
    rust_flag: str,
    zig_flag: str,
) -> None:
    zig_exe = root / "zig-out" / "bin" / "riscv-trace-dump"
    vectors = load_trace_vectors(root, pinned, receipt)
    cases = []
    layouts: set[str] = set()
    all_ok = True
    for vector in vectors["vectors"]:
        elf = root / vector["elf"]
        rust = _run([str(oracle_exe), rust_flag, "--elf", str(elf)])
        zig = _run([str(zig_exe), zig_flag, str(elf)], cwd=root)
        rust_digest = hashlib.sha256(rust.encode()).hexdigest()
        zig_digest = hashlib.sha256(zig.encode()).hexdigest()
        agree = rust == zig
        all_ok = all_ok and agree
        case = {
            "name": vector["name"],
            "elf_sha256": vector["elf_sha256"],
            "agree": agree,
            "rust_sha256": rust_digest,
            "zig_sha256": zig_digest,
            "bytes": len(zig.encode()),
            "records": sum(1 for line in zig.splitlines() if line.startswith("row="))
            if boundary == "per_family_witness_rows"
            else len(zig.splitlines()),
        }
        if agree:
            receipt["case_result_digests"][f"{boundary}/{vector['name']}"] = zig_digest
            if boundary == "per_family_witness_rows":
                layouts.add(hashlib.sha256(_witness_layout(zig)).hexdigest())
        else:
            case["first_disagreement"] = _first_line_difference(rust, zig)
        cases.append(case)

    layout_ok = boundary != "per_family_witness_rows" or len(layouts) == 1
    if boundary == "per_family_witness_rows" and layout_ok:
        receipt["witness_layout_digest_sha256"] = next(iter(layouts))
    receipt["boundaries"][boundary] = {
        "status": "pass" if all_ok and layout_ok else "fail",
        "comparison": "byte-for-byte canonical serialization of production buffers",
        "corpus": cases,
    }
    if boundary == "per_family_witness_rows":
        receipt["boundaries"][boundary]["layout_digests"] = sorted(layouts)


def compare_per_family_witness_rows(
    oracle_exe: Path,
    receipt: dict,
    root: Path,
    pinned: str,
) -> None:
    _compare_canonical_dump(
        oracle_exe,
        receipt,
        root,
        pinned,
        boundary="per_family_witness_rows",
        rust_flag="--witness-rows",
        zig_flag="--witness-rows",
    )


def compare_ordered_accesses(
    oracle_exe: Path,
    receipt: dict,
    root: Path,
    pinned: str,
) -> None:
    _compare_canonical_dump(
        oracle_exe,
        receipt,
        root,
        pinned,
        boundary="ordered_accesses",
        rust_flag="--ordered-accesses",
        zig_flag="--ordered-accesses",
    )
