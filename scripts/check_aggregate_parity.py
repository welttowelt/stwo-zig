#!/usr/bin/env python3
"""Validate focused/aggregate Native behavior and verification parity."""

try:
    from architecture_host_gate_lib.aggregate_parity import main
except ModuleNotFoundError:
    from scripts.architecture_host_gate_lib.aggregate_parity import main


if __name__ == "__main__":
    raise SystemExit(main())
