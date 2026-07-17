"""Static contract and bounded workload model for Native proof matrices."""

from __future__ import annotations

import argparse
import hashlib
from typing import NamedTuple


REPORT_SCHEMA_VERSION = 1
SUMMARY_SCHEMA_VERSION = 1
SUMMARY_PROTOCOL = "native_proof_cross_backend_matrix_v1"

DEFAULT_WORKLOADS = ("10:8", "12:16")
DEFAULT_WARMUPS = 1
DEFAULT_SAMPLES = 5
DEFAULT_PROTOCOL = "functional"
DEFAULT_COOLDOWN_SECONDS = 1.0

MAX_MATRIX_ROWS = 12
MAX_LOG_ROWS = 22
MAX_SEQUENCE_LEN = 512
MAX_COMMITTED_TRACE_CELLS = 1 << 25
MAX_WARMUPS = 10
MAX_SAMPLES = 21
MAX_COOLDOWN_SECONDS = 300.0
MAX_TIMEOUT_SECONDS = 3600.0
MAX_TOTAL_REQUEST_CELLS = 1 << 30

LANES = ("cpu", "metal")
EXPECTED_BACKENDS = {
    "cpu": "cpu_native",
    "metal": "metal_hybrid",
}
PROTOCOL_PRESETS = {
    "smoke": {
        "name": "smoke",
        "pow_bits": 0,
        "log_blowup_factor": 1,
        "log_last_layer_degree_bound": 0,
        "n_queries": 3,
        "fold_step": 1,
    },
    "functional": {
        "name": "functional",
        "pow_bits": 10,
        "log_blowup_factor": 1,
        "log_last_layer_degree_bound": 0,
        "n_queries": 3,
        "fold_step": 1,
    },
}
HEADLINE_REQUIREMENT_KEYS = {
    "verified_unprofiled",
    "sampling_contract",
    "functional_protocol",
    "release_fast",
    "clean_complete_provenance",
    "thread_parallelism_enabled",
    "byte_identical_verified_samples",
    "backend_telemetry_valid",
}
BACKEND_COUNTER_KEYS = {
    "host_merkle_commits",
    "resident_merkle_commits",
    "metal_quotient_dispatches",
    "metal_sampled_value_dispatches",
    "metal_circle_transform_dispatches",
    "metal_circle_lde_dispatches",
    "metal_fri_circle_fold_dispatches",
    "metal_fri_line_fold_dispatches",
    "metal_qm31_coordinate_dispatches",
    "cpu_small_merkle_commits",
    "cpu_streaming_merkle_commits",
    "cpu_sampled_value_evaluations",
    "cpu_small_circle_interpolations",
    "cpu_small_circle_evaluations",
    "cpu_small_circle_ldes",
}
PIPELINE_CACHE_COUNTER_KEYS = {
    "library_cache_hits",
    "library_cache_misses",
    "pipeline_cache_hits",
    "binary_archive_hits",
    "binary_archive_misses",
    "direct_compiles",
    "archive_populations",
    "archive_serializations",
}
PIPELINE_CACHE_SECONDS_KEY = "pipeline_preparation_seconds"
ACCELERATED_CLASSIFICATIONS = {
    "accelerated_with_fallbacks",
    "accelerated_without_fallbacks",
}
RATE_RELATIVE_TOLERANCE = 1e-12
RATE_ABSOLUTE_TOLERANCE = 1e-15


class MatrixError(RuntimeError):
    """A benchmark artifact failed the matrix contract."""


class Workload(NamedTuple):
    log_rows: int
    sequence_len: int

    @property
    def rows(self) -> int:
        return 1 << self.log_rows

    @property
    def committed_trace_cells(self) -> int:
        return self.rows * self.sequence_len

    @property
    def slug(self) -> str:
        return f"log-{self.log_rows}-sequence-{self.sequence_len}"

    def as_dict(self) -> dict[str, int]:
        return {
            "log_rows": self.log_rows,
            "rows": self.rows,
            "sequence_len": self.sequence_len,
            "committed_trace_cells": self.committed_trace_cells,
        }


def parse_workload(value: str) -> Workload:
    parts = value.replace(",", ":").split(":")
    if len(parts) != 2:
        raise argparse.ArgumentTypeError("workload must be LOG_ROWS:SEQUENCE_LEN")
    try:
        workload = Workload(int(parts[0]), int(parts[1]))
    except ValueError as error:
        raise argparse.ArgumentTypeError("workload values must be integers") from error
    try:
        validate_workload(workload)
    except ValueError as error:
        raise argparse.ArgumentTypeError(str(error)) from error
    return workload


def validate_workload(workload: Workload) -> None:
    if workload.log_rows <= 0 or workload.log_rows > MAX_LOG_ROWS:
        raise ValueError(f"log rows must be in [1, {MAX_LOG_ROWS}]")
    if workload.sequence_len < 2 or workload.sequence_len > MAX_SEQUENCE_LEN:
        raise ValueError(f"sequence length must be in [2, {MAX_SEQUENCE_LEN}]")
    if workload.committed_trace_cells > MAX_COMMITTED_TRACE_CELLS:
        raise ValueError(
            "workload exceeds committed trace cell limit "
            f"({workload.committed_trace_cells} > {MAX_COMMITTED_TRACE_CELLS})"
        )


def workload_descriptor_sha256(workload: Workload, protocol_name: str) -> str:
    protocol = PROTOCOL_PRESETS[protocol_name]
    description = (
        f"wide_fibonacci|log_rows={workload.log_rows}"
        f"|sequence_len={workload.sequence_len}"
        f"|pow_bits={protocol['pow_bits']}"
        f"|blowup={protocol['log_blowup_factor']}"
        f"|last={protocol['log_last_layer_degree_bound']}"
        f"|queries={protocol['n_queries']}"
        f"|fold={protocol['fold_step']}"
    )
    return hashlib.sha256(description.encode()).hexdigest()
