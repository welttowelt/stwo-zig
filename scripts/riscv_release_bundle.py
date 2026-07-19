#!/usr/bin/env python3
"""Pack or verify immutable, exact-source RISC-V release evidence."""

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from scripts.riscv_release_bundle_lib.controller import main  # noqa: E402


if __name__ == "__main__":
    raise SystemExit(main())
