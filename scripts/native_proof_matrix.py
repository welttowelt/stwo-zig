#!/usr/bin/env python3
"""Run a bounded, parity-gated Native CPU/Metal proof matrix."""

from __future__ import annotations

import argparse
import json
import math
import subprocess
import sys
import tempfile
import time
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from native_proof_matrix_lib import (  # noqa: E402
    BACKEND_COUNTER_KEYS,
    DEFAULT_COOLDOWN_SECONDS,
    DEFAULT_PROTOCOL,
    DEFAULT_SAMPLES,
    DEFAULT_WARMUPS,
    DEFAULT_WORKLOADS,
    MAX_COMMITTED_TRACE_CELLS,
    MatrixError,
    PIPELINE_CACHE_COUNTER_KEYS,
    PIPELINE_CACHE_SECONDS_KEY,
    SUMMARY_PROTOCOL,
    Workload,
    atomic_write_bytes,
    output_dir_lock,
    parse_workload,
    run_lane,
    run_matrix,
    require_unprofiled_environment,
    validate_pair,
    validate_report,
    validate_workload,
    workload_descriptor_sha256,
)
from native_proof_matrix_lib.model import (  # noqa: E402
    MAX_COOLDOWN_SECONDS,
    MAX_LOG_ROWS,
    MAX_MATRIX_ROWS,
    MAX_SAMPLES,
    MAX_SEQUENCE_LEN,
    MAX_TIMEOUT_SECONDS,
    MAX_TOTAL_REQUEST_CELLS,
    MAX_WARMUPS,
)


ROOT = SCRIPT_DIR.parent


def resolve_workloads(
    args: argparse.Namespace,
    parser: argparse.ArgumentParser,
) -> list[Workload]:
    explicit = args.workload or []
    has_product = args.log_rows is not None or args.sequence_lens is not None
    if explicit and has_product:
        parser.error("--workload cannot be combined with --log-rows/--sequence-lens")
    if has_product:
        if args.log_rows is None or args.sequence_lens is None:
            parser.error("--log-rows and --sequence-lens must be provided together")
        workloads = [
            Workload(log_rows, sequence_len)
            for log_rows in args.log_rows
            for sequence_len in args.sequence_lens
        ]
    elif explicit:
        workloads = explicit
    else:
        workloads = [parse_workload(value) for value in DEFAULT_WORKLOADS]

    try:
        for workload in workloads:
            validate_workload(workload)
    except ValueError as error:
        parser.error(str(error))
    if len(workloads) > MAX_MATRIX_ROWS:
        parser.error(f"matrix may contain at most {MAX_MATRIX_ROWS} workload rows")
    if len(set(workloads)) != len(workloads):
        parser.error("matrix workload rows must be unique")
    return workloads


def validate_controller_args(
    args: argparse.Namespace,
    parser: argparse.ArgumentParser,
) -> None:
    if args.warmups < 0 or args.warmups > MAX_WARMUPS:
        parser.error(f"warmups must be in [0, {MAX_WARMUPS}]")
    if args.samples <= 0 or args.samples > MAX_SAMPLES:
        parser.error(f"samples must be in [1, {MAX_SAMPLES}]")
    if (
        not math.isfinite(args.cooldown_seconds)
        or args.cooldown_seconds < 0
        or args.cooldown_seconds > MAX_COOLDOWN_SECONDS
    ):
        parser.error(f"cooldown must be in [0, {MAX_COOLDOWN_SECONDS}] seconds")
    if (
        not math.isfinite(args.timeout_seconds)
        or args.timeout_seconds <= 0
        or args.timeout_seconds > MAX_TIMEOUT_SECONDS
    ):
        parser.error(f"timeout must be in (0, {MAX_TIMEOUT_SECONDS}] seconds")
    request_cells = sum(
        workload.committed_trace_cells for workload in args.workloads
    ) * 2 * (args.warmups + args.samples)
    if request_cells > MAX_TOTAL_REQUEST_CELLS:
        parser.error(
            "matrix exceeds aggregate cell budget "
            f"({request_cells} > {MAX_TOTAL_REQUEST_CELLS})"
        )


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--workload",
        action="append",
        type=parse_workload,
        help="bounded matrix row as LOG_ROWS:SEQUENCE_LEN; repeat for more rows",
    )
    parser.add_argument(
        "--log-rows",
        type=int,
        nargs="+",
        help="log2 row counts; forms a product with --sequence-lens",
    )
    parser.add_argument(
        "--sequence-lens",
        type=int,
        nargs="+",
        help="trace widths; forms a product with --log-rows",
    )
    parser.add_argument("--warmups", type=int, default=DEFAULT_WARMUPS)
    parser.add_argument("--samples", type=int, default=DEFAULT_SAMPLES)
    parser.add_argument(
        "--protocol",
        choices=("smoke", "functional"),
        default=DEFAULT_PROTOCOL,
    )
    parser.add_argument(
        "--cooldown-seconds",
        type=float,
        default=DEFAULT_COOLDOWN_SECONDS,
    )
    parser.add_argument("--timeout-seconds", type=float, default=900.0)
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path(tempfile.gettempdir()) / "stwo-native-proof-matrix",
    )
    parser.add_argument(
        "--cpu-bin",
        type=Path,
        default=ROOT / "zig-out/bin/native-proof-bench-cpu",
    )
    parser.add_argument(
        "--metal-bin",
        type=Path,
        default=ROOT / "zig-out/bin/native-proof-bench-metal",
    )
    parser.add_argument(
        "--allow-non-headline",
        action="store_true",
        help="return success after valid parity when formal headline gates fail",
    )
    args = parser.parse_args(argv)
    args.workloads = resolve_workloads(args, parser)
    validate_controller_args(args, parser)
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        document = run_matrix(args)
    except (MatrixError, OSError) as error:
        print(f"native proof matrix failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps(document, sort_keys=True))
    if not document["summary"]["all_rows_headline_eligible"] and not args.allow_non_headline:
        print(
            "native proof matrix parity passed but formal headline gates failed; "
            "use --allow-non-headline only for diagnostic evidence",
            file=sys.stderr,
        )
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
