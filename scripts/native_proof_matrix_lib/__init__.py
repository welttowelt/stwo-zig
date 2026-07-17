"""Public helpers for the Native CPU/Metal proof matrix controller."""

from .artifacts import (
    atomic_write_bytes,
    atomic_write_json,
    output_dir_lock,
    require_unprofiled_environment,
    run_lane,
)
from .contract import validate_pair, validate_report
from .controller import run_matrix
from .model import (
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
    parse_workload,
    validate_workload,
    workload_descriptor_sha256,
)

__all__ = [
    "BACKEND_COUNTER_KEYS",
    "DEFAULT_COOLDOWN_SECONDS",
    "DEFAULT_PROTOCOL",
    "DEFAULT_SAMPLES",
    "DEFAULT_WARMUPS",
    "DEFAULT_WORKLOADS",
    "MAX_COMMITTED_TRACE_CELLS",
    "MatrixError",
    "PIPELINE_CACHE_COUNTER_KEYS",
    "PIPELINE_CACHE_SECONDS_KEY",
    "SUMMARY_PROTOCOL",
    "Workload",
    "atomic_write_bytes",
    "atomic_write_json",
    "output_dir_lock",
    "parse_workload",
    "run_lane",
    "run_matrix",
    "require_unprofiled_environment",
    "validate_pair",
    "validate_report",
    "validate_workload",
    "workload_descriptor_sha256",
]
