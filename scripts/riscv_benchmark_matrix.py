#!/usr/bin/env python3
"""Produce or validate staged RISC-V benchmark matrix v2 evidence.

The full run covers the 16 committed execution-corpus rows and all 16 crypto
rows. Pinned ``cp11_dump`` output is the semantic correctness oracle;
``stark-v-bench`` is a separately identified timing lane. This evidence is
always diagnostic and never promotion eligible.

Build the focused Zig products before running:

  zig build stwo-zig-riscv-cpu riscv-trace-dump -Doptimize=ReleaseFast

Then run:

  python3 scripts/riscv_benchmark_matrix.py run \
    --stark-v-source /path/to/stark-v \
    --artifact-dir zig-out/riscv-matrix-v2 \
    --report-out zig-out/riscv-matrix-v2.json
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from scripts import riscv_benchmark_matrix_contract as contract  # noqa: E402
from scripts import riscv_benchmark_matrix_model as model  # noqa: E402
from scripts import riscv_benchmark_matrix_runner as controller  # noqa: E402


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    run = commands.add_parser("run", help="produce a staged matrix report")
    run.add_argument("--stark-v-source", required=True, type=Path)
    run.add_argument("--artifact-dir", required=True, type=Path)
    run.add_argument("--report-out", required=True, type=Path)
    run.add_argument("--candidate-cli", type=Path, default=controller.DEFAULT_CANDIDATE_CLI)
    run.add_argument("--trace-cli", type=Path, default=controller.DEFAULT_TRACE_CLI)
    run.add_argument("--oracle-cache-dir", type=Path)
    run.add_argument("--warmups", type=int, default=1)
    run.add_argument("--samples", type=int, default=3)
    run.add_argument(
        "--row",
        action="append",
        help="run one exact row ID; repeat to filter (filtered evidence stays incomplete)",
    )
    run.add_argument("--allow-dirty", action="store_true", help=argparse.SUPPRESS)

    validate = commands.add_parser("validate", help="validate an existing report")
    validate.add_argument("--report", required=True, type=Path)
    validate.add_argument("--require-complete", action="store_true")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "validate":
            report = contract.strict_json_file(args.report.resolve(), "matrix report")
            workloads, _fixtures = model.load_workloads(ROOT)
            expected = [workload.row_id for workload in workloads]
            contract.validate_report(
                report,
                expected_row_ids=expected if args.require_complete else None,
                require_complete=args.require_complete,
            )
            contract.validate_artifact_tree(report)
            print(
                f"riscv benchmark matrix: valid ({report['summary']['row_count']} rows, "
                f"status={report['status']}, promotion_eligible=false)"
            )
            return 0
        report = controller.produce(
            stark_v_source=args.stark_v_source,
            artifact_dir=args.artifact_dir,
            report_out=args.report_out,
            candidate_cli=args.candidate_cli,
            trace_cli=args.trace_cli,
            cache_dir=args.oracle_cache_dir,
            warmups=args.warmups,
            samples=args.samples,
            selected_ids=args.row,
            allow_dirty=args.allow_dirty,
        )
    except (
        OSError,
        ValueError,
        contract.MatrixContractError,
        model.MatrixModelError,
        controller.MatrixRunError,
    ) as error:
        print(f"riscv benchmark matrix: FAIL: {error}", file=sys.stderr)
        return 1
    print(
        f"riscv benchmark matrix: {report['status']} "
        f"({report['summary']['ok_count']}/{report['summary']['row_count']} rows; "
        "promotion_eligible=false)"
    )
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
