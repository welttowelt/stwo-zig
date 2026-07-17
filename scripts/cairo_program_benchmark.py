#!/usr/bin/env python3
"""Compile and benchmark the canonical Cairo suite through Rust stwo-cairo."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from cairo_program_benchmark_lib import (  # noqa: E402
    EvidenceError,
    ProvenanceError,
    atomic_write_json,
    collect_report,
    compile_cache,
    resolve_cases,
    resolve_lanes,
)


def _compile_parser(subparsers: argparse._SubParsersAction) -> None:
    parser = subparsers.add_parser(
        "compile-cache",
        help="compile all nine Cairo programs into a hash-locked external cache",
    )
    parser.add_argument("--program-root", type=Path, required=True)
    parser.add_argument(
        "--source-repo", type=Path, required=True, help="clean Git repository root"
    )
    parser.add_argument("--compiler", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument(
        "--allow-non-headline",
        action="store_true",
        help="allow a diagnostic cache manifest when the source repository is dirty",
    )


def _run_parser(subparsers: argparse._SubParsersAction) -> None:
    parser = subparsers.add_parser(
        "run",
        help="run verified Rust stwo-cairo SIMD/Metal proof comparisons",
    )
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--gpu-bench", type=Path, required=True)
    parser.add_argument(
        "--gpu-bench-repo",
        type=Path,
        required=True,
        help="stwo_cairo_prover directory containing Cargo.lock and rust-toolchain.toml",
    )
    parser.add_argument(
        "--rust-stwo-repo",
        type=Path,
        required=True,
        help="clean Rust Stwo path-dependency checkout",
    )
    parser.add_argument(
        "--case",
        action="append",
        metavar="PROGRAM=N[,N...]",
        help="repeatable bounded program sizes; omission selects the canonical suite",
    )
    parser.add_argument(
        "--lane",
        action="append",
        choices=("simd", "metal"),
        help="Rust stwo-cairo legacy lane; omission selects both",
    )
    parser.add_argument("--warmups", type=int, default=1)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--proofs-per-process", type=int, default=3)
    parser.add_argument("--timeout-s", type=float, default=900.0)
    parser.add_argument("--pause-s", type=float, default=1.0)
    parser.add_argument("--rayon-threads", type=int)
    parser.add_argument("--output", type=Path)
    parser.add_argument(
        "--allow-non-headline",
        action="store_true",
        help="run diagnostic evidence despite provenance or sample-count blockers",
    )


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    _compile_parser(subparsers)
    _run_parser(subparsers)
    return parser.parse_args(argv)


def _compile(args: argparse.Namespace) -> dict[str, object]:
    return compile_cache(
        program_root=args.program_root,
        source_repo=args.source_repo,
        compiler=args.compiler,
        output_dir=args.output_dir,
        manifest_path=args.manifest,
        allow_non_headline=args.allow_non_headline,
    )


def _run(args: argparse.Namespace) -> dict[str, object]:
    cases = resolve_cases(args.case)
    lanes = resolve_lanes(args.lane)
    report = collect_report(
        manifest_path=args.manifest.expanduser().resolve(),
        gpu_bench=args.gpu_bench.expanduser().resolve(),
        gpu_bench_repo=args.gpu_bench_repo.expanduser().resolve(),
        rust_stwo_repo=args.rust_stwo_repo.expanduser().resolve(),
        cases=cases,
        lanes=lanes,
        warmups=args.warmups,
        repeats=args.repeats,
        proofs_per_process=args.proofs_per_process,
        timeout_s=args.timeout_s,
        pause_s=args.pause_s,
        rayon_threads=args.rayon_threads,
        allow_non_headline=args.allow_non_headline,
    )
    if args.output is not None:
        atomic_write_json(args.output.expanduser().resolve(), report)
    return report


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        document = _compile(args) if args.command == "compile-cache" else _run(args)
    except (EvidenceError, ProvenanceError, RuntimeError, ValueError) as error:
        print(f"Cairo program benchmark failed: {error}", file=sys.stderr)
        return 1
    sys.stdout.write(json.dumps(document, indent=2, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
