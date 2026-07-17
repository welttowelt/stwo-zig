"""Public contract for the canonical Cairo program benchmark harness."""

from .catalog import PROGRAMS, PROGRAM_BY_SLUG, ProgramSpec, resolve_cases
from .controller import collect_report, resolve_lanes, summarize
from .evidence import (
    LANES,
    PROTOCOL,
    EvidenceError,
    Lane,
    benchmark_environment,
    build_command,
    parse_gpu_bench_output,
    run_sample,
)
from .provenance import (
    ProvenanceError,
    atomic_write_json,
    compile_cache,
    load_compile_manifest,
    runtime_provenance,
    sha256_file,
    validate_compile_manifest,
)

__all__ = [
    "LANES",
    "PROGRAMS",
    "PROGRAM_BY_SLUG",
    "PROTOCOL",
    "EvidenceError",
    "Lane",
    "ProgramSpec",
    "ProvenanceError",
    "atomic_write_json",
    "benchmark_environment",
    "build_command",
    "collect_report",
    "compile_cache",
    "load_compile_manifest",
    "parse_gpu_bench_output",
    "resolve_cases",
    "resolve_lanes",
    "run_sample",
    "runtime_provenance",
    "sha256_file",
    "summarize",
    "validate_compile_manifest",
]
