#!/usr/bin/env python3
"""Exercise the Linux candidate sandbox against active escape attempts."""

from __future__ import annotations

import argparse
import tempfile
import time
from pathlib import Path

try:
    from riscv_release_challenge_lib.execution import CandidateSandbox
except ModuleNotFoundError:
    from scripts.riscv_release_challenge_lib.execution import CandidateSandbox


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="riscv-sandbox-adversary-") as directory:
        root = Path(directory)
        elf = root / "challenge.elf"
        input_path = root / "challenge.input"
        elf.write_bytes(b"probe")
        input_path.write_bytes(b"")
        sandbox = CandidateSandbox(
            root / "sandbox",
            cli=args.probe,
            trace_cli=args.probe,
            elf=elf,
            input_path=input_path,
            deadline_ns=time.monotonic_ns() + 15_000_000_000,
        )
        try:
            sandbox.run("candidate-sandbox-adversary", ["/bin/prover"])
            time.sleep(2.25)
            sandbox.collect_outputs({"probe-pass": root / "probe-pass"})
        finally:
            sandbox.close()
        if not (root / "probe-pass").is_file():
            raise SystemExit("candidate sandbox adversary did not publish its pass marker")
    print("riscv candidate sandbox adversary: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
