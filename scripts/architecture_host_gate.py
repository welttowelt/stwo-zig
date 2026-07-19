#!/usr/bin/env python3
"""Execute the checked-in architecture phase plan and emit host evidence."""

try:
    import architecture_host_gate_lib.controller as controller
except ModuleNotFoundError:
    import scripts.architecture_host_gate_lib.controller as controller


def main(argv: list[str] | None = None) -> int:
    return controller.main(argv)


if __name__ == "__main__":
    raise SystemExit(main())
