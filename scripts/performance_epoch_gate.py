#!/usr/bin/env python3
"""Create and validate build-monorepo performance epoch evidence."""

try:
    import performance_epoch_gate_lib.controller as controller
except ModuleNotFoundError:
    import scripts.performance_epoch_gate_lib.controller as controller


def main(argv: list[str] | None = None) -> int:
    def run_oracle(binary, artifact, timeout):
        try:
            from scripts.native_proof_matrix_lib.artifacts import run_rust_oracle
        except ModuleNotFoundError:
            from native_proof_matrix_lib.artifacts import run_rust_oracle
        return run_rust_oracle(binary, artifact, timeout)

    return controller.main(argv, oracle_runner=run_oracle)


if __name__ == "__main__":
    raise SystemExit(main())
