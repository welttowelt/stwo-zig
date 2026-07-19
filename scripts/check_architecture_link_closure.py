#!/usr/bin/env python3
"""Inspect architecture binaries against focused linkage policy."""

try:
    from architecture_host_gate_lib.link_closure import main
except ModuleNotFoundError:
    from scripts.architecture_host_gate_lib.link_closure import main


if __name__ == "__main__":
    raise SystemExit(main())
