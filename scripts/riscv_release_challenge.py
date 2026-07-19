#!/usr/bin/env python3
"""Issue and execute trusted fresh challenges for the RISC-V release gate."""

try:
    from riscv_release_challenge_lib.controller import main
except ModuleNotFoundError:
    from scripts.riscv_release_challenge_lib.controller import main


if __name__ == "__main__":
    raise SystemExit(main())
