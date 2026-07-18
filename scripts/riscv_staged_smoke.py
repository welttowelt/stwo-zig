#!/usr/bin/env python3
"""Staged riscv CLI smoke: prove, independently verify, and reject tampering.

Exercises the installed CLI end to end on a committed, cross-verified vector
ELF: `prove --elf` must produce a v2 artifact that a separate `verify
--artifact` invocation cryptographically accepts (printing its honest
release status), and a single-bit tamper of the public statement must be
rejected. Part of the riscv release gate; also runnable standalone.
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ELF = "vectors/riscv_elfs/branch_fib.elf"


def main() -> int:
    subprocess.run(["zig", "build", "stwo-zig", "-Doptimize=ReleaseFast"], cwd=ROOT, check=True)
    cli = ROOT / "zig-out" / "bin" / "stwo-zig"
    with tempfile.TemporaryDirectory() as tmp:
        artifact = Path(tmp) / "staged.json"
        report = Path(tmp) / "report.json"
        subprocess.run(
            [str(cli), "prove", "--elf", ELF, "--backend", "cpu", "--protocol",
             "functional", "--output", str(artifact), "--report-out", str(report)],
            cwd=ROOT, check=True, capture_output=True,
        )
        payload = json.loads(artifact.read_text())
        if payload["release_status"] != "not_release_gated":
            print("riscv staged smoke: artifact release status drifted", file=sys.stderr)
            return 1
        verify = subprocess.run(
            [str(cli), "verify", "--artifact", str(artifact)],
            cwd=ROOT, capture_output=True, text=True,
        )
        if verify.returncode != 0 or "proof VERIFIED" not in verify.stdout:
            print(f"riscv staged smoke: honest artifact rejected: {verify.stdout}"
                  f"{verify.stderr}", file=sys.stderr)
            return 1
        payload["statement"]["final_pc"] ^= 4
        tampered = Path(tmp) / "tampered.json"
        tampered.write_text(json.dumps(payload))
        tamper = subprocess.run(
            [str(cli), "verify", "--artifact", str(tampered)],
            cwd=ROOT, capture_output=True, text=True,
        )
        if tamper.returncode == 0:
            print("riscv staged smoke: TAMPERED ARTIFACT ACCEPTED", file=sys.stderr)
            return 1
    print("riscv staged smoke: prove, independent verify, and tamper rejection all hold")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
