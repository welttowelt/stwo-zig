#!/usr/bin/env python3
"""Pack or verify immutable, exact-source RISC-V release evidence."""

try:
    from riscv_release_bundle_lib.controller import main
except ModuleNotFoundError:
    from scripts.riscv_release_bundle_lib.controller import main


if __name__ == "__main__":
    raise SystemExit(main())
