#!/usr/bin/env python3
"""Produce and verify versioned Zig build-architecture receipts."""

try:
    import build_architecture_receipt_lib.controller as controller
except ModuleNotFoundError:
    import scripts.build_architecture_receipt_lib.controller as controller


def main(argv: list[str] | None = None) -> int:
    return controller.main(argv)


if __name__ == "__main__":
    raise SystemExit(main())
