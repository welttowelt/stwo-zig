#!/usr/bin/env python3
"""Run a deterministic mixed SN PIE proving queue and fail closed on verification."""

from __future__ import annotations

import argparse
from concurrent.futures import Future, ThreadPoolExecutor
from dataclasses import dataclass
import importlib.util
import json
import math
import os
from pathlib import Path
import random
import re
import shlex
import shutil
import signal
import subprocess
import sys
import threading
import time
from typing import Callable, Protocol


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SEED = 20260715
PIE_INDICES = tuple(range(4))
TREE0_MERKLE_SUFFIX = ".tree0-merkle"
PIPELINE_CACHE_COUNTER_FIELDS = (
    "library_cache_hits",
    "library_cache_misses",
    "pipeline_cache_hits",
    "binary_archive_hits",
    "binary_archive_misses",
    "direct_compiles",
    "archive_populations",
    "archive_serializations",
)
PIPELINE_CACHE_SECONDS_FIELD = "pipeline_preparation_seconds"
PIPELINE_CACHE_FIELDS = frozenset((*PIPELINE_CACHE_COUNTER_FIELDS, PIPELINE_CACHE_SECONDS_FIELD))
PROTOCOL_PARAMETERS = {
    "channel": "blake2s",
    "channel_salt": 0,
    "log_blowup_factor": 1,
    "n_queries": 70,
    "interaction_pow_bits": 24,
    "query_pow_bits": 26,
    "fri_fold_step": 3,
    "fri_lifting": None,
    "fri_log_last_layer_degree_bound": 0,
}

_SESSION_MODULE_PATH = Path(__file__).with_name("sn_pie_metal_session.py")
_SESSION_SPEC = importlib.util.spec_from_file_location("sn_pie_metal_session", _SESSION_MODULE_PATH)
if _SESSION_SPEC is None or _SESSION_SPEC.loader is None:
    raise RuntimeError(f"failed to load persistent-session protocol: {_SESSION_MODULE_PATH}")
if _SESSION_SPEC.name in sys.modules:
    SESSION_PROTOCOL = sys.modules[_SESSION_SPEC.name]
else:
    SESSION_PROTOCOL = importlib.util.module_from_spec(_SESSION_SPEC)
    sys.modules[_SESSION_SPEC.name] = SESSION_PROTOCOL
    _SESSION_SPEC.loader.exec_module(SESSION_PROTOCOL)


@dataclass(frozen=True)
class SharedArtifacts:
    witness_programs: Path
    multiplicity_feeds: Path
    relation_templates: Path
    fixed_tables: Path
    preprocessed_evaluations: Path
    preprocessed_coefficients: Path
    tree0_root_hex: str


@dataclass(frozen=True)
class PieArtifacts:
    index: int
    name: str
    source_pie: Path
    adapted_input: Path | None
    schedule: Path
    witness_programs: Path | None
    multiplicity_feeds: Path | None
    composition: Path
    transcript_reference: Path | None
    quotient_reference: Path | None
    composition_program: Path | None = None


@dataclass(frozen=True)
class QueueConfig:
    runner: Path
    benchmark_script: Path
    budget_gib: str
    timeout_s: float
    shared: SharedArtifacts
    pies: tuple[PieArtifacts, ...]
    adapter_command: tuple[str, ...] | None
    adapter_timeout_s: float
    adapter_prefetch_depth: int = 0
    session_command: tuple[str, ...] | None = None
    session_startup_timeout_s: float = 30.0

    def pie(self, index: int) -> PieArtifacts:
        if index not in PIE_INDICES:
            raise ValueError(f"PIE index must be in {PIE_INDICES}: {index}")
        return self.pies[index]

    def witness_programs_for(self, pie: PieArtifacts) -> Path:
        return pie.witness_programs or self.shared.witness_programs

    def multiplicity_feeds_for(self, pie: PieArtifacts) -> Path:
        return pie.multiplicity_feeds or self.shared.multiplicity_feeds

    def composition_program_for(self, pie: PieArtifacts) -> Path:
        if pie.composition_program is not None:
            return pie.composition_program
        if pie.composition.suffix != ".bin":
            raise ValueError(f"{pie.name} composition must end in .bin")
        metal = pie.composition.with_suffix(".metal")
        if metal.is_file():
            return metal
        return pie.composition.with_suffix(".metallib")


@dataclass(frozen=True)
class BlockRequest:
    queue_position: int
    pie: PieArtifacts
    adapted_input: Path
    proof_output: Path
    benchmark_report: Path


@dataclass(frozen=True)
class ExecutionResult:
    launch_status: str
    returncode: int | None
    executor_wall_s: float
    report: dict[str, object] | None
    stdout_tail: str = ""
    stderr_tail: str = ""
    session_id: str | None = None
    session_block_wall_s: float | None = None
    runtime_reused: bool | None = None
    resident_arena_reused: bool | None = None
    preprocessed_state_reused: bool | None = None
    proof_bytes: int | None = None
    proof_sha256: str | None = None
    adapted_input_sha256: str | None = None
    rust_verifier: dict[str, object] | None = None


class Executor(Protocol):
    """Replace this interface with a persistent Zig executor without queue changes."""

    name: str

    def execute(self, request: BlockRequest) -> ExecutionResult: ...


@dataclass(frozen=True)
class AdaptationResult:
    status: str
    adapted_input: Path | None
    wall_s: float
    cache_hit: bool
    command: tuple[str, ...] | None = None
    max_rss_bytes: int | None = None
    peak_footprint_bytes: int | None = None
    failure_reason: str | None = None


@dataclass(frozen=True)
class AdaptationDelivery:
    result: AdaptationResult
    wait_s: float
    prefetched: bool
    ready_before_request: bool

    @property
    def feed_starved(self) -> bool:
        return self.prefetched and not self.ready_before_request

    @property
    def overlapped_wall_s(self) -> float:
        return max(0.0, self.result.wall_s - self.wait_s) if self.prefetched else 0.0


class InputAdapter(Protocol):
    name: str

    def prepare(self, pie: PieArtifacts, destination: Path, production: bool) -> AdaptationResult: ...


def _mapping(value: object, label: str) -> dict[str, object]:
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be an object")
    return value


def _string(mapping: dict[str, object], key: str) -> str:
    value = mapping.get(key)
    if not isinstance(value, str) or not value:
        raise ValueError(f"{key} must be a non-empty string")
    return value


def _path(base: Path, mapping: dict[str, object], key: str) -> Path:
    value = Path(_string(mapping, key)).expanduser()
    return value if value.is_absolute() else base / value


def _optional_path(base: Path, mapping: dict[str, object], key: str) -> Path | None:
    value = mapping.get(key)
    if value is None:
        return None
    if not isinstance(value, str) or not value:
        raise ValueError(f"{key} must be a non-empty string when present")
    path = Path(value).expanduser()
    return path if path.is_absolute() else base / path


def load_manifest(path: Path) -> QueueConfig:
    document = _mapping(json.loads(path.read_text()), "manifest")
    base = path.resolve().parent
    shared_doc = _mapping(document.get("shared"), "shared")
    shared = SharedArtifacts(
        witness_programs=_path(base, shared_doc, "witness_programs"),
        multiplicity_feeds=_path(base, shared_doc, "multiplicity_feeds"),
        relation_templates=_path(base, shared_doc, "relation_templates"),
        fixed_tables=_path(base, shared_doc, "fixed_tables"),
        preprocessed_evaluations=_path(base, shared_doc, "preprocessed_evaluations"),
        preprocessed_coefficients=_path(base, shared_doc, "preprocessed_coefficients"),
        tree0_root_hex=_string(shared_doc, "tree0_root_hex"),
    )
    pies_doc = document.get("pies")
    if not isinstance(pies_doc, list) or len(pies_doc) != len(PIE_INDICES):
        raise ValueError("pies must contain exactly four entries")
    pies_by_index: dict[int, PieArtifacts] = {}
    for raw in pies_doc:
        pie_doc = _mapping(raw, "pie")
        index = pie_doc.get("index")
        if not isinstance(index, int) or isinstance(index, bool) or index not in PIE_INDICES:
            raise ValueError(f"pie index must be in {PIE_INDICES}")
        if index in pies_by_index:
            raise ValueError(f"duplicate pie index: {index}")
        transcript_reference = _optional_path(base, pie_doc, "transcript_reference")
        quotient_reference = _optional_path(base, pie_doc, "quotient_reference")
        if (transcript_reference is None) != (quotient_reference is None):
            raise ValueError(
                f"pie {index} transcript_reference and quotient_reference "
                "must both be present or absent"
            )
        pies_by_index[index] = PieArtifacts(
            index=index,
            name=_string(pie_doc, "name"),
            source_pie=_path(base, pie_doc, "source_pie"),
            adapted_input=_optional_path(base, pie_doc, "adapted_input"),
            schedule=_path(base, pie_doc, "schedule"),
            witness_programs=_optional_path(base, pie_doc, "witness_programs"),
            multiplicity_feeds=_optional_path(base, pie_doc, "multiplicity_feeds"),
            composition=_path(base, pie_doc, "composition"),
            transcript_reference=transcript_reference,
            quotient_reference=quotient_reference,
            composition_program=_optional_path(base, pie_doc, "composition_program"),
        )
    if set(pies_by_index) != set(PIE_INDICES):
        raise ValueError(f"pie indices must be exactly {PIE_INDICES}")
    timeout = document.get("timeout_s", 1800.0)
    if not isinstance(timeout, (int, float)) or isinstance(timeout, bool) or timeout <= 0:
        raise ValueError("timeout_s must be positive")
    budget = document.get("budget_gib", "52")
    if not isinstance(budget, (str, int, float)) or isinstance(budget, bool):
        raise ValueError("budget_gib must be a string or number")
    benchmark_value = document.get("benchmark_script", str(ROOT / "scripts/sn_pie_metal_benchmark.py"))
    if not isinstance(benchmark_value, str) or not benchmark_value:
        raise ValueError("benchmark_script must be a non-empty string")
    benchmark_script = Path(benchmark_value).expanduser()
    if not benchmark_script.is_absolute():
        benchmark_script = base / benchmark_script
    adapter_doc = document.get("adapter")
    adapter_command: tuple[str, ...] | None = None
    adapter_timeout_s = 600.0
    adapter_prefetch_depth = 0
    if adapter_doc is not None:
        adapter = _mapping(adapter_doc, "adapter")
        command = adapter.get("command")
        if not isinstance(command, list) or not command or not all(isinstance(item, str) and item for item in command):
            raise ValueError("adapter.command must be a non-empty string array")
        adapter_command = tuple(command)
        timeout_value = adapter.get("timeout_s", adapter_timeout_s)
        if not isinstance(timeout_value, (int, float)) or isinstance(timeout_value, bool) or timeout_value <= 0:
            raise ValueError("adapter.timeout_s must be positive")
        adapter_timeout_s = float(timeout_value)
        prefetch_value = adapter.get("prefetch_depth", adapter_prefetch_depth)
        if not isinstance(prefetch_value, int) or isinstance(prefetch_value, bool) or prefetch_value < 0:
            raise ValueError("adapter.prefetch_depth must be a non-negative integer")
        adapter_prefetch_depth = prefetch_value
    session_doc = document.get("session")
    session_command: tuple[str, ...] | None = None
    session_startup_timeout_s = 30.0
    if session_doc is not None:
        session = _mapping(session_doc, "session")
        command = session.get("command")
        if not isinstance(command, list) or not command or not all(
            isinstance(item, str) and item for item in command
        ):
            raise ValueError("session.command must be a non-empty string array")
        session_command = tuple(command)
        startup_timeout = session.get("startup_timeout_s", session_startup_timeout_s)
        if (
            not isinstance(startup_timeout, (int, float))
            or isinstance(startup_timeout, bool)
            or not math.isfinite(float(startup_timeout))
            or startup_timeout <= 0
        ):
            raise ValueError("session.startup_timeout_s must be finite and positive")
        session_startup_timeout_s = float(startup_timeout)
    return QueueConfig(
        runner=_path(base, document, "runner"),
        benchmark_script=benchmark_script,
        budget_gib=str(budget),
        timeout_s=float(timeout),
        shared=shared,
        pies=tuple(pies_by_index[index] for index in PIE_INDICES),
        adapter_command=adapter_command,
        adapter_timeout_s=adapter_timeout_s,
        adapter_prefetch_depth=adapter_prefetch_depth,
        session_command=session_command,
        session_startup_timeout_s=session_startup_timeout_s,
    )


def validate_config(config: QueueConfig, production: bool = False) -> None:
    paths = {
        "runner": config.runner,
        "benchmark_script": config.benchmark_script,
        "witness_programs": config.shared.witness_programs,
        "multiplicity_feeds": config.shared.multiplicity_feeds,
        "relation_templates": config.shared.relation_templates,
        "fixed_tables": config.shared.fixed_tables,
        "preprocessed_evaluations": config.shared.preprocessed_evaluations,
        "preprocessed_coefficients": config.shared.preprocessed_coefficients,
        "retained_tree0": Path(f"{config.shared.preprocessed_evaluations}{TREE0_MERKLE_SUFFIX}"),
    }
    for pie in config.pies:
        paths.update({
            f"{pie.name}.schedule": pie.schedule,
            f"{pie.name}.composition": pie.composition,
            f"{pie.name}.composition_program": config.composition_program_for(pie),
        })
        if (pie.transcript_reference is None) != (pie.quotient_reference is None):
            raise ValueError(
                f"{pie.name} transcript_reference and quotient_reference must both be present or absent"
            )
        if pie.transcript_reference is not None:
            paths[f"{pie.name}.transcript_reference"] = pie.transcript_reference
            paths[f"{pie.name}.quotient_reference"] = pie.quotient_reference
        if pie.witness_programs is not None:
            paths[f"{pie.name}.witness_programs_override"] = pie.witness_programs
        if pie.multiplicity_feeds is not None:
            paths[f"{pie.name}.multiplicity_feeds_override"] = pie.multiplicity_feeds
        if not pie.source_pie.exists():
            raise ValueError(f"missing source PIE: {pie.name}: {pie.source_pie}")
        if not production and config.adapter_command is None:
            if pie.adapted_input is None or not pie.adapted_input.is_file():
                raise ValueError(f"{pie.name} requires an adapted_input cache or external adapter")
    missing = [f"{label}: {path}" for label, path in paths.items() if not path.is_file()]
    if missing:
        raise ValueError("missing queue artifacts:\n" + "\n".join(missing))
    if not re.fullmatch(r"[0-9a-fA-F]{64}", config.shared.tree0_root_hex):
        raise ValueError("tree0_root_hex must contain exactly 64 hexadecimal digits")
    if production and config.adapter_command is None:
        raise ValueError("production mode requires adapter.command for raw source_pie execution")
    if config.adapter_command is not None:
        command_template = "\0".join(config.adapter_command)
        for placeholder in ("{source_pie}", "{adapted_input}"):
            if placeholder not in command_template:
                raise ValueError(f"adapter.command must contain {placeholder}")


def seeded_queue(seed: int, length: int) -> list[int]:
    if length <= 0:
        raise ValueError("queue length must be positive")
    generator = random.Random(seed)
    return [generator.randrange(len(PIE_INDICES)) for _ in range(length)]


def benchmark_command(config: QueueConfig, request: BlockRequest) -> list[str]:
    pie = request.pie
    shared = config.shared
    command = [
        sys.executable,
        str(config.benchmark_script),
        "--input",
        str(request.adapted_input),
        "--mode",
        "full-proof",
        "--runner",
        str(config.runner),
        "--schedule",
        str(pie.schedule),
        "--witness-programs",
        str(config.witness_programs_for(pie)),
        "--multiplicity-feeds",
        str(config.multiplicity_feeds_for(pie)),
        "--relation-templates",
        str(shared.relation_templates),
        "--fixed-tables",
        str(shared.fixed_tables),
        "--composition",
        str(pie.composition),
        "--budget-gib",
        config.budget_gib,
        "--timeout",
        str(config.timeout_s),
        "--preprocessed-evaluations",
        str(shared.preprocessed_evaluations),
        "--preprocessed-coefficients",
        str(shared.preprocessed_coefficients),
        "--tree0-root-hex",
        shared.tree0_root_hex,
    ]
    if pie.transcript_reference is not None and pie.quotient_reference is not None:
        command.extend([
            "--transcript-reference",
            str(pie.transcript_reference),
            "--quotient-reference",
            str(pie.quotient_reference),
        ])
    command.extend([
        "--proof-output",
        str(request.proof_output),
        "--output",
        str(request.benchmark_report),
    ])
    return command


class SubprocessExecutor:
    name = "subprocess"

    def __init__(self, config: QueueConfig):
        self.config = config

    def execute(self, request: BlockRequest) -> ExecutionResult:
        command = benchmark_command(self.config, request)
        started = time.perf_counter()
        try:
            process = subprocess.run(
                command,
                cwd=ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=self.config.timeout_s + 60.0,
                check=False,
            )
            launch_status = "completed" if process.returncode == 0 else "failed"
            stdout, stderr = process.stdout, process.stderr
            returncode: int | None = process.returncode
        except subprocess.TimeoutExpired as error:
            launch_status = "timed_out"
            stdout = error.stdout if isinstance(error.stdout, str) else ""
            stderr = error.stderr if isinstance(error.stderr, str) else ""
            returncode = None
        report: dict[str, object] | None = None
        if request.benchmark_report.is_file():
            try:
                report = _mapping(json.loads(request.benchmark_report.read_text()), "benchmark report")
            except (json.JSONDecodeError, ValueError):
                launch_status = "invalid_output"
        elif launch_status == "completed":
            launch_status = "invalid_output"
        return ExecutionResult(
            launch_status=launch_status,
            returncode=returncode,
            executor_wall_s=time.perf_counter() - started,
            report=report,
            stdout_tail=stdout[-4096:],
            stderr_tail=stderr[-4096:],
        )


class PersistentSessionExecutor:
    """Execute strict-order blocks through one versioned Zig proving session."""

    name = "persistent_session"

    def __init__(
        self,
        config: QueueConfig,
        command: tuple[str, ...],
        startup_timeout_s: float | None = None,
        daemon_stderr_path: Path | None = None,
    ):
        if not command:
            raise ValueError("persistent session command must not be empty")
        self.config = config
        self.command = command
        self.daemon_stderr_path = daemon_stderr_path
        self.daemon_stderr = None
        self.client = SESSION_PROTOCOL.PersistentSessionClient(
            command,
            startup_timeout_s=(
                config.session_startup_timeout_s
                if startup_timeout_s is None
                else startup_timeout_s
            ),
        )
        self.ready: dict[str, object] | None = None
        self.failed = False

    def execute(self, request: BlockRequest) -> ExecutionResult:
        started = time.perf_counter()
        if self.failed:
            return ExecutionResult(
                launch_status="not_started",
                returncode=None,
                executor_wall_s=0.0,
                report=None,
                stderr_tail="persistent session is already failed",
            )
        try:
            if self.ready is None:
                if self.daemon_stderr_path is not None:
                    self.daemon_stderr = self.daemon_stderr_path.open("xb")
                    self.client.daemon_stderr = self.daemon_stderr
                self.ready = self.client.start()
            pie = request.pie
            shared = self.config.shared
            session_request = SESSION_PROTOCOL.ProveRequest(
                sequence=self.client.next_sequence,
                request_id=f"queue-{request.queue_position:04d}-{pie.name.lower()}",
                artifacts=SESSION_PROTOCOL.SessionArtifacts(
                    adapted_input=request.adapted_input.resolve(),
                    schedule=pie.schedule.resolve(),
                    witness_programs=self.config.witness_programs_for(pie).resolve(),
                    multiplicity_feeds=self.config.multiplicity_feeds_for(pie).resolve(),
                    relation_templates=shared.relation_templates.resolve(),
                    fixed_tables=shared.fixed_tables.resolve(),
                    composition=pie.composition.resolve(),
                    composition_program=self.config.composition_program_for(pie).resolve(),
                    preprocessed_evaluations=shared.preprocessed_evaluations.resolve(),
                    preprocessed_tree0_merkle=Path(
                        f"{shared.preprocessed_evaluations}{TREE0_MERKLE_SUFFIX}"
                    ).resolve(),
                    preprocessed_coefficients=shared.preprocessed_coefficients.resolve(),
                    transcript_reference=(
                        pie.transcript_reference.resolve()
                        if pie.transcript_reference is not None
                        else None
                    ),
                    quotient_reference=(
                        pie.quotient_reference.resolve()
                        if pie.quotient_reference is not None
                        else None
                    ),
                ),
                proof_output=request.proof_output.resolve(),
                report_output=request.benchmark_report.resolve(),
                budget_gib=self.config.budget_gib,
                tree0_root_hex=shared.tree0_root_hex.lower(),
            )
            verified = self.client.prove(session_request, timeout_s=self.config.timeout_s)
            report = _mapping(
                json.loads(request.benchmark_report.read_text()),
                "persistent benchmark report",
            )
            return ExecutionResult(
                launch_status="completed",
                returncode=0,
                executor_wall_s=time.perf_counter() - started,
                report=report,
                session_id=self.client.session_id,
                session_block_wall_s=verified.session_block_wall_s,
                runtime_reused=verified.runtime_reused,
                resident_arena_reused=verified.resident_arena_reused,
                preprocessed_state_reused=verified.preprocessed_state_reused,
                proof_bytes=verified.proof_bytes,
                proof_sha256=verified.proof_sha256,
                adapted_input_sha256=verified.adapted_input_sha256,
                rust_verifier=verified.rust_verifier,
            )
        except (OSError, ValueError, json.JSONDecodeError, SESSION_PROTOCOL.SessionProtocolError) as error:
            self.failed = True
            return ExecutionResult(
                launch_status="failed",
                returncode=None,
                executor_wall_s=time.perf_counter() - started,
                report=None,
                stderr_tail=str(error)[-4096:],
                session_id=self.client.session_id,
            )

    def close(self) -> None:
        try:
            if self.client.process is not None:
                self.client.close()
        finally:
            if self.daemon_stderr is not None:
                self.daemon_stderr.close()
                self.daemon_stderr = None


def _time_resource_usage(stderr: str) -> tuple[int | None, int | None]:
    rss_match = re.search(r"(?m)^\s*(\d+)\s+maximum resident set size\s*$", stderr)
    footprint_match = re.search(r"(?m)^\s*(\d+)\s+peak memory footprint\s*$", stderr)
    return (
        int(rss_match.group(1)) if rss_match else None,
        int(footprint_match.group(1)) if footprint_match else None,
    )


class CacheOrCommandAdapter:
    """Resolve an explicit adapted cache or execute a raw-PIE adapter command."""

    name = "cache_or_external_command"

    def __init__(self, config: QueueConfig):
        self.config = config

    def prepare(self, pie: PieArtifacts, destination: Path, production: bool) -> AdaptationResult:
        if not production and pie.adapted_input is not None and pie.adapted_input.is_file():
            return AdaptationResult(
                status="completed",
                adapted_input=pie.adapted_input,
                wall_s=0.0,
                cache_hit=True,
            )
        if self.config.adapter_command is None:
            return AdaptationResult(
                status="failed",
                adapted_input=None,
                wall_s=0.0,
                cache_hit=False,
                failure_reason="missing_external_adapter",
            )
        values = {
            "source_pie": str(pie.source_pie),
            "adapted_input": str(destination),
            "pie_index": pie.index,
            "pie_name": pie.name,
        }
        try:
            command = tuple(token.format(**values) for token in self.config.adapter_command)
        except (KeyError, ValueError) as error:
            return AdaptationResult(
                status="failed",
                adapted_input=None,
                wall_s=0.0,
                cache_hit=False,
                command=self.config.adapter_command,
                failure_reason=f"invalid_adapter_template: {error}",
            )
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.unlink(missing_ok=True)
        timed_command = ["/usr/bin/time", "-lp", *command]
        started = time.perf_counter()
        try:
            process = subprocess.run(
                timed_command,
                cwd=ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=self.config.adapter_timeout_s,
                check=False,
            )
            wall_s = time.perf_counter() - started
        except subprocess.TimeoutExpired as error:
            stderr = error.stderr if isinstance(error.stderr, str) else ""
            max_rss, peak_footprint = _time_resource_usage(stderr)
            return AdaptationResult(
                status="timed_out",
                adapted_input=None,
                wall_s=time.perf_counter() - started,
                cache_hit=False,
                command=command,
                max_rss_bytes=max_rss,
                peak_footprint_bytes=peak_footprint,
                failure_reason="adapter_timed_out",
            )
        max_rss, peak_footprint = _time_resource_usage(process.stderr)
        reason = None
        if process.returncode != 0:
            reason = f"adapter_exit_{process.returncode}"
        elif not destination.is_file() or destination.stat().st_size <= 8:
            reason = "adapter_missing_output"
        else:
            with destination.open("rb") as adapted_file:
                if adapted_file.read(8) != b"STWZCPI\0":
                    reason = "adapter_invalid_output_magic"
        return AdaptationResult(
            status="completed" if reason is None else "failed",
            adapted_input=destination if reason is None else None,
            wall_s=wall_s,
            cache_hit=False,
            command=command,
            max_rss_bytes=max_rss,
            peak_footprint_bytes=peak_footprint,
            failure_reason=reason,
        )

    def prepare_prefetch(
        self,
        pie: PieArtifacts,
        destination: Path,
        production: bool,
        cancel_event: threading.Event,
    ) -> AdaptationResult:
        """Run an adapter command that can be cancelled with its whole process group."""
        if cancel_event.is_set():
            return AdaptationResult("cancelled", None, 0.0, False, failure_reason="adapter_cancelled")
        if not production and pie.adapted_input is not None and pie.adapted_input.is_file():
            return self.prepare(pie, destination, production)
        if self.config.adapter_command is None:
            return self.prepare(pie, destination, production)
        values = {
            "source_pie": str(pie.source_pie),
            "adapted_input": str(destination),
            "pie_index": pie.index,
            "pie_name": pie.name,
        }
        try:
            command = tuple(token.format(**values) for token in self.config.adapter_command)
        except (KeyError, ValueError) as error:
            return AdaptationResult(
                "failed",
                None,
                0.0,
                False,
                command=self.config.adapter_command,
                failure_reason=f"invalid_adapter_template: {error}",
            )
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.unlink(missing_ok=True)
        timed_command = ["/usr/bin/time", "-lp", *command]
        started = time.perf_counter()
        try:
            process = subprocess.Popen(
                timed_command,
                cwd=ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                start_new_session=True,
            )
        except OSError as error:
            return AdaptationResult(
                "failed",
                None,
                time.perf_counter() - started,
                False,
                command=command,
                failure_reason=f"adapter_launch_failed: {error}",
            )

        deadline = started + self.config.adapter_timeout_s
        cancelled = False
        timed_out = False
        stdout = ""
        stderr = ""
        while True:
            try:
                stdout, stderr = process.communicate(timeout=0.1)
                break
            except subprocess.TimeoutExpired:
                cancelled = cancel_event.is_set()
                timed_out = time.perf_counter() >= deadline
                if not cancelled and not timed_out:
                    continue
                self._terminate_process_group(process)
                stdout, stderr = process.communicate()
                break
        wall_s = time.perf_counter() - started
        max_rss, peak_footprint = _time_resource_usage(stderr)
        if cancelled or timed_out:
            destination.unlink(missing_ok=True)
            return AdaptationResult(
                "cancelled" if cancelled else "timed_out",
                None,
                wall_s,
                False,
                command=command,
                max_rss_bytes=max_rss,
                peak_footprint_bytes=peak_footprint,
                failure_reason="adapter_cancelled" if cancelled else "adapter_timed_out",
            )
        reason = None
        if process.returncode != 0:
            reason = f"adapter_exit_{process.returncode}"
        elif not destination.is_file() or destination.stat().st_size <= 8:
            reason = "adapter_missing_output"
        else:
            with destination.open("rb") as adapted_file:
                if adapted_file.read(8) != b"STWZCPI\0":
                    reason = "adapter_invalid_output_magic"
        if reason is not None:
            destination.unlink(missing_ok=True)
        return AdaptationResult(
            "completed" if reason is None else "failed",
            destination if reason is None else None,
            wall_s,
            False,
            command=command,
            max_rss_bytes=max_rss,
            peak_footprint_bytes=peak_footprint,
            failure_reason=reason,
        )

    @staticmethod
    def _terminate_process_group(process: subprocess.Popen[str]) -> None:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        try:
            process.wait(timeout=2.0)
            return
        except subprocess.TimeoutExpired:
            pass
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def _positive_number(value: object) -> float | None:
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        converted = float(value)
        if math.isfinite(converted) and converted > 0:
            return converted
    return None


def _nonnegative_number(value: object) -> float | None:
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        converted = float(value)
        if math.isfinite(converted) and converted >= 0:
            return converted
    return None


def _pipeline_cache_delta(value: object) -> dict[str, int | float] | None:
    if not isinstance(value, dict) or set(value) != PIPELINE_CACHE_FIELDS:
        return None
    counters: dict[str, int | float] = {}
    for field in PIPELINE_CACHE_COUNTER_FIELDS:
        counter = value[field]
        if not isinstance(counter, int) or isinstance(counter, bool) or counter < 0:
            return None
        counters[field] = counter
    seconds = _nonnegative_number(value[PIPELINE_CACHE_SECONDS_FIELD])
    if seconds is None:
        return None
    counters[PIPELINE_CACHE_SECONDS_FIELD] = seconds
    return counters


def _production_provenance(report: dict[str, object]) -> tuple[bool, bool, bool]:
    self_contained = report.get("self_contained") is True
    parity_fixture_used = report.get("parity_fixture_used") is not False
    proof_derived_artifact_used = report.get("proof_derived_artifact_used") is not False
    return self_contained, parity_fixture_used, proof_derived_artifact_used


def _provenance_completeness(report: dict[str, object]) -> tuple[bool, str | None, bool]:
    statement_self_derived = report.get("statement_self_derived")
    if not isinstance(statement_self_derived, bool):
        evidence = report.get("provenance_evidence")
        statement_self_derived = (
            evidence.get("runner_statement_self_derived")
            if isinstance(evidence, dict)
            else False
        )
    digest = report.get("artifact_manifest_digest")
    if digest is None:
        manifest = report.get("artifact_manifest")
        digest = manifest.get("sha256") if isinstance(manifest, dict) else None
    valid_digest = (
        digest
        if isinstance(digest, str)
        and SESSION_PROTOCOL.SHA256_PATTERN.fullmatch(digest) is not None
        else None
    )
    declared_complete = report.get("provenance_complete")
    provenance_complete = (
        declared_complete is True
        if isinstance(declared_complete, bool)
        else valid_digest is not None
    )
    return statement_self_derived is True, valid_digest, provenance_complete and valid_digest is not None


def _protocol_parameters(report: dict[str, object]) -> tuple[dict[str, object] | None, bool]:
    protocol = report.get("protocol")
    if not isinstance(protocol, dict) or set(protocol) != set(PROTOCOL_PARAMETERS):
        return None, False
    for key, expected in PROTOCOL_PARAMETERS.items():
        actual = protocol[key]
        if isinstance(expected, int):
            if not isinstance(actual, int) or isinstance(actual, bool) or actual != expected:
                return None, False
        elif actual != expected or type(actual) is not type(expected):
            return None, False
    return protocol, True


def _pow_telemetry(report: dict[str, object]) -> dict[str, object]:
    telemetry = report.get("pow_telemetry")
    if not isinstance(telemetry, dict):
        cli_report = report.get("cli_report")
        cli = cli_report if isinstance(cli_report, dict) else {}
        telemetry = {
            "scope": cli.get("pow_timing_scope"),
            "interaction": {
                field: cli.get(f"interaction_pow_{field}")
                for field in ("nonce", "wall_s", "mode", "bits", "invocations")
            },
            "query": {
                field: cli.get(f"query_pow_{field}")
                for field in ("nonce", "wall_s", "mode", "bits", "invocations")
            },
        }
    normalized: dict[str, object] = {
        "scope": telemetry.get("scope"),
        "complete": True,
    }
    for prefix, expected_bits in (("interaction", 24), ("query", 26)):
        raw = telemetry.get(prefix)
        stage = raw if isinstance(raw, dict) else {}
        wall_s = _nonnegative_number(stage.get("wall_s"))
        nonce = stage.get("nonce")
        mode = stage.get("mode")
        bits = stage.get("bits")
        invocations = stage.get("invocations")
        valid = (
            wall_s is not None
            and isinstance(nonce, int)
            and not isinstance(nonce, bool)
            and nonce >= 0
            and mode in {"self_ground", "fixture_forced"}
            and bits == expected_bits
            and invocations == 1
            and not isinstance(invocations, bool)
        )
        normalized[prefix] = {
            "nonce": nonce,
            "wall_s": wall_s,
            "mode": mode,
            "bits": bits,
            "invocations": invocations,
        }
        normalized["complete"] = normalized["complete"] and valid
    normalized["complete"] = (
        normalized["complete"]
        and normalized["scope"] == "cpu_nonce_search_or_fixture_validation_only"
    )
    return normalized


def _canonical_rust_verifier_evidence(
    value: object,
    proof_sha256: object,
) -> dict[str, object] | None:
    if (
        not isinstance(proof_sha256, str)
        or SESSION_PROTOCOL.SHA256_PATTERN.fullmatch(proof_sha256) is None
    ):
        return None
    try:
        return SESSION_PROTOCOL._rust_verifier_evidence(
            value,
            "queue rust_verifier",
            proof_sha256=proof_sha256,
        )
    except SESSION_PROTOCOL.SessionProtocolError:
        return None


def _block_has_canonical_rust_verification(block: dict[str, object]) -> bool:
    return _canonical_rust_verifier_evidence(
        block.get("rust_verifier"),
        block.get("proof_sha256"),
    ) is not None


def block_record(
    request: BlockRequest,
    execution: ExecutionResult,
    adaptation_delivery: AdaptationDelivery,
    end_to_end_block_latency_s: float,
) -> dict[str, object]:
    adaptation = adaptation_delivery.result
    report = execution.report or {}
    input_report = report.get("input") if isinstance(report.get("input"), dict) else {}
    resources = report.get("resource_usage") if isinstance(report.get("resource_usage"), dict) else {}
    cycles_value = input_report.get("adapted_cycles")
    cycles = cycles_value if isinstance(cycles_value, int) and not isinstance(cycles_value, bool) and cycles_value > 0 else None
    prove_wall_s = _positive_number(report.get("prove_wall_s"))
    prove_mhz = _positive_number(report.get("prove_mhz"))
    prove_timing_scope = report.get("prove_timing_scope")
    process_wall_s = _positive_number(report.get("wall_s"))
    self_contained, parity_fixture_used, proof_derived_artifact_used = (
        _production_provenance(report)
    )
    statement_self_derived, artifact_manifest_digest, provenance_complete = (
        _provenance_completeness(report)
    )
    protocol_parameters, protocol_complete = _protocol_parameters(report)
    pow_telemetry = _pow_telemetry(report)
    pipeline_cache_delta = _pipeline_cache_delta(report.get("pipeline_cache_delta"))
    reasons: list[str] = []
    if adaptation.status != "completed" or adaptation.adapted_input is None:
        reasons.append(adaptation.failure_reason or f"adapter_{adaptation.status}")
    if execution.launch_status != "completed" or execution.returncode != 0:
        reasons.append(f"executor_{execution.launch_status}")
    if report.get("status") != "completed":
        reasons.append(f"benchmark_{report.get('status', 'missing')}")
    if report.get("proof_verified") is not True:
        reasons.append("proof_unverified")
    if report.get("proving_speed_verified") is not True:
        reasons.append("proving_speed_unverified")
    if cycles is None:
        reasons.append("missing_adapted_cycles")
    if prove_wall_s is None or prove_mhz is None:
        reasons.append("missing_verified_prove_timing")
    elif prove_timing_scope != SESSION_PROTOCOL.PROVE_TIMING_SCOPE:
        reasons.append("invalid_prove_timing_scope")
    elif cycles is not None and not math.isclose(
        prove_mhz,
        cycles / prove_wall_s / 1_000_000,
        rel_tol=1e-12,
        abs_tol=1e-12,
    ):
        reasons.append("invalid_prove_mhz")
    input_path = input_report.get("path")
    input_sha256 = input_report.get("sha256")
    expected_input_path = str(request.adapted_input.resolve())
    if input_path != expected_input_path:
        reasons.append("adapted_input_path_mismatch")
    if (
        not isinstance(input_sha256, str)
        or SESSION_PROTOCOL.SHA256_PATTERN.fullmatch(input_sha256) is None
    ):
        reasons.append("missing_adapted_input_sha256")
    elif execution.adapted_input_sha256 is not None:
        if execution.adapted_input_sha256 != input_sha256:
            reasons.append("adapted_input_sha256_mismatch")
    else:
        try:
            if SESSION_PROTOCOL.sha256_file(request.adapted_input) != input_sha256:
                reasons.append("adapted_input_sha256_mismatch")
        except OSError:
            reasons.append("adapted_input_unreadable")
    proof_size = request.proof_output.stat().st_size if request.proof_output.is_file() else 0
    proof_sha256: str | None = None
    if proof_size <= 0:
        reasons.append("missing_proof_output")
    elif execution.proof_bytes is not None and execution.proof_bytes != proof_size:
        reasons.append("proof_output_size_mismatch")
    else:
        try:
            proof_sha256 = SESSION_PROTOCOL.sha256_file(request.proof_output)
        except OSError:
            reasons.append("proof_output_unreadable")
    if execution.proof_sha256 is not None:
        if SESSION_PROTOCOL.SHA256_PATTERN.fullmatch(execution.proof_sha256) is None:
            reasons.append("invalid_proof_sha256")
        elif proof_sha256 is not None and execution.proof_sha256 != proof_sha256:
            reasons.append("proof_sha256_mismatch")
    rust_verifier = _canonical_rust_verifier_evidence(
        report.get("rust_verifier"),
        proof_sha256,
    )
    if rust_verifier is None:
        reasons.append("rust_verifier_evidence_invalid")
    if execution.session_id is not None:
        if execution.rust_verifier is None:
            reasons.append("rust_verifier_session_evidence_missing")
        elif rust_verifier != execution.rust_verifier:
            reasons.append("rust_verifier_session_report_mismatch")
    cold_overhead = None
    if process_wall_s is not None and prove_wall_s is not None:
        cold_overhead = max(0.0, process_wall_s - prove_wall_s)
    orchestrator_overhead = None
    if process_wall_s is not None:
        orchestrator_overhead = max(
            0.0,
            end_to_end_block_latency_s - adaptation_delivery.wait_s - process_wall_s,
        )
    prove_max_rss = resources.get("max_rss_bytes")
    prove_peak_footprint = resources.get("peak_footprint_bytes")
    max_rss_values = [
        value for value in (prove_max_rss, adaptation.max_rss_bytes)
        if isinstance(value, int) and not isinstance(value, bool)
    ]
    footprint_values = [
        value for value in (prove_peak_footprint, adaptation.peak_footprint_bytes)
        if isinstance(value, int) and not isinstance(value, bool)
    ]
    return {
        "queue_position": request.queue_position,
        "pie_index": request.pie.index,
        "pie": request.pie.name,
        "source_pie": str(request.pie.source_pie.resolve()),
        "adapted_input": str(request.adapted_input.resolve()),
        "input_mode": "preadapted_cache" if adaptation.cache_hit else "external_adapter",
        "adapted_cache_hit": adaptation.cache_hit,
        "status": "verified" if not reasons else "failed",
        "failure_reasons": reasons,
        "proof_verified": report.get("proof_verified") is True,
        "rust_verifier": rust_verifier,
        "self_contained": self_contained,
        "parity_fixture_used": parity_fixture_used,
        "proof_derived_artifact_used": proof_derived_artifact_used,
        "statement_self_derived": statement_self_derived,
        "artifact_manifest_digest": artifact_manifest_digest,
        "provenance_complete": provenance_complete,
        "protocol": protocol_parameters,
        "protocol_complete": protocol_complete,
        "pow_telemetry": pow_telemetry,
        "pow_telemetry_complete": pow_telemetry["complete"],
        "interaction_pow_wall_s": pow_telemetry["interaction"]["wall_s"],
        "query_pow_wall_s": pow_telemetry["query"]["wall_s"],
        "adapted_cycles": cycles,
        "prove_wall_s": prove_wall_s,
        "prove_mhz": prove_mhz,
        "prove_timing_scope": prove_timing_scope,
        "execution_adaptation_wall_s": adaptation.wall_s,
        "adaptation_wait_s": adaptation_delivery.wait_s,
        "adaptation_overlapped_wall_s": adaptation_delivery.overlapped_wall_s,
        "adaptation_prefetched": adaptation_delivery.prefetched,
        "adaptation_ready_before_request": adaptation_delivery.ready_before_request,
        "feed_starved": adaptation_delivery.feed_starved,
        "end_to_end_block_latency_s": end_to_end_block_latency_s,
        "process_wall_s": process_wall_s,
        "session_id": execution.session_id,
        "session_block_wall_s": execution.session_block_wall_s,
        "metal_runtime_reused": execution.runtime_reused,
        "resident_arena_reused": execution.resident_arena_reused,
        "preprocessed_state_reused": execution.preprocessed_state_reused,
        "pipeline_cache_delta": pipeline_cache_delta,
        "cold_process_overhead_s": cold_overhead,
        "benchmark_executor_wall_s": execution.executor_wall_s,
        "orchestrator_overhead_s": orchestrator_overhead,
        "max_rss_bytes": max(max_rss_values) if max_rss_values else None,
        "peak_footprint_bytes": max(footprint_values) if footprint_values else None,
        "adaptation_max_rss_bytes": adaptation.max_rss_bytes,
        "adaptation_peak_footprint_bytes": adaptation.peak_footprint_bytes,
        "prove_max_rss_bytes": prove_max_rss,
        "prove_peak_footprint_bytes": prove_peak_footprint,
        "proof_output": str(request.proof_output.resolve()),
        "proof_bytes": proof_size,
        "proof_sha256": proof_sha256,
        "adapted_input_sha256": input_sha256 if isinstance(input_sha256, str) else None,
        "benchmark_report": str(request.benchmark_report.resolve()),
        "benchmark_status": report.get("status"),
        "adapter_status": adaptation.status,
        "adapter_command": list(adaptation.command) if adaptation.command else None,
        "executor_status": execution.launch_status,
        "exit_code": execution.returncode,
        "stderr_tail": execution.stderr_tail,
    }


def _max_integer(records: list[dict[str, object]], key: str) -> int | None:
    values = [value for record in records if isinstance((value := record.get(key)), int) and not isinstance(value, bool)]
    return max(values) if values else None


def _sum_number(records: list[dict[str, object]], key: str) -> float:
    return sum(float(value) for record in records if isinstance((value := record.get(key)), (int, float)) and not isinstance(value, bool))


def _aggregate_pipeline_cache_delta(
    blocks: list[dict[str, object]],
    measurement_complete: bool,
) -> tuple[bool, dict[str, int | float] | None]:
    deltas = [block.get("pipeline_cache_delta") for block in blocks]
    complete = measurement_complete and bool(deltas) and all(
        _pipeline_cache_delta(delta) is not None for delta in deltas
    )
    if not complete:
        return False, None
    return True, {
        **{
            field: sum(int(delta[field]) for delta in deltas if isinstance(delta, dict))
            for field in PIPELINE_CACHE_COUNTER_FIELDS
        },
        PIPELINE_CACHE_SECONDS_FIELD: sum(
            float(delta[PIPELINE_CACHE_SECONDS_FIELD])
            for delta in deltas
            if isinstance(delta, dict)
        ),
    }


def write_json_atomic(path: Path, document: dict[str, object]) -> None:
    encoded = json.dumps(document, indent=2) + "\n"
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(encoded)
    temporary.replace(path)


def _block_stem(position: int, pie: PieArtifacts) -> str:
    return f"block-{position:04d}-{pie.name.lower().replace('_', '-')}"


def require_fresh_outputs(output_dir: Path, report_path: Path) -> None:
    """Refuse ambiguous delivery into an existing queue artifact directory."""
    if output_dir.exists():
        if not output_dir.is_dir():
            raise ValueError(f"queue output is not a directory: {output_dir}")
        entries = list(output_dir.iterdir())
        if entries:
            raise ValueError(f"queue output directory is not empty: {output_dir}")
    else:
        output_dir.mkdir(parents=True)
    if report_path.exists():
        raise ValueError(f"queue report already exists; refusing stale output: {report_path}")


class AdaptationPrefetcher:
    """One-worker, order-preserving, bounded lookahead for raw PIE adaptation."""

    def __init__(
        self,
        config: QueueConfig,
        indices: list[int],
        output_dir: Path,
        adapter: InputAdapter,
        production: bool,
        depth: int,
    ):
        if depth <= 0:
            raise ValueError("prefetch depth must be positive")
        self.config = config
        self.indices = indices
        self.adapter = adapter
        self.production = production
        self.depth = depth
        self.staging_dir = output_dir / f".adapt-prefetch-{os.getpid()}-{id(self):x}"
        self.staging_dir.mkdir(parents=True, exist_ok=False)
        self.cancel_event = threading.Event()
        self.pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="sn-pie-adapter")
        self.futures: dict[int, Future[AdaptationResult]] = {}
        self.destinations: dict[int, Path] = {}
        self.next_position = 1
        self.max_pending = 0
        self.closed = False

    def destination(self, position: int) -> Path:
        destination = self.destinations.get(position)
        if destination is None:
            pie = self.config.pie(self.indices[position])
            destination = self.staging_dir / f"{_block_stem(position, pie)}.adapted.stwzcpi"
            self.destinations[position] = destination
        return destination

    def fill(self) -> None:
        while len(self.futures) < self.depth and self.next_position < len(self.indices):
            position = self.next_position
            self.next_position += 1
            pie = self.config.pie(self.indices[position])
            destination = self.destination(position)
            self.futures[position] = self.pool.submit(self._prepare, pie, destination)
            self.max_pending = max(self.max_pending, len(self.futures))

    def take(self, position: int) -> AdaptationDelivery:
        future = self.futures.pop(position, None)
        if future is None:
            return AdaptationDelivery(
                AdaptationResult("failed", None, 0.0, False, failure_reason="prefetch_order_violation"),
                0.0,
                True,
                False,
            )
        ready = future.done()
        wait_started = time.perf_counter()
        try:
            result = future.result()
        except Exception as error:  # Fail closed and preserve a checkpointable block result.
            result = AdaptationResult(
                "failed",
                None,
                time.perf_counter() - wait_started,
                False,
                failure_reason=f"adapter_exception: {type(error).__name__}: {error}",
            )
        return AdaptationDelivery(result, time.perf_counter() - wait_started, True, ready)

    def cleanup_position(self, position: int) -> None:
        destination = self.destinations.get(position)
        if destination is not None:
            destination.unlink(missing_ok=True)

    def shutdown(self, cancel: bool) -> None:
        if self.closed:
            return
        self.closed = True
        if cancel:
            self.cancel_event.set()
            for future in self.futures.values():
                future.cancel()
        self.pool.shutdown(wait=True, cancel_futures=cancel)
        shutil.rmtree(self.staging_dir, ignore_errors=True)

    def _prepare(self, pie: PieArtifacts, destination: Path) -> AdaptationResult:
        prefetch_method = getattr(self.adapter, "prepare_prefetch", None)
        if callable(prefetch_method):
            return prefetch_method(pie, destination, self.production, self.cancel_event)
        if self.cancel_event.is_set():
            return AdaptationResult("cancelled", None, 0.0, False, failure_reason="adapter_cancelled")
        return self.adapter.prepare(pie, destination, self.production)


def run_queue(
    config: QueueConfig,
    indices: list[int],
    seed: int,
    output_dir: Path,
    report_path: Path,
    executor: Executor,
    adapter: InputAdapter,
    production: bool = False,
    clock: Callable[[], float] = time.perf_counter,
    adapter_prefetch_depth: int | None = None,
) -> tuple[dict[str, object], int]:
    prefetch_depth = config.adapter_prefetch_depth if adapter_prefetch_depth is None else adapter_prefetch_depth
    if not isinstance(prefetch_depth, int) or isinstance(prefetch_depth, bool) or prefetch_depth < 0:
        raise ValueError("adapter prefetch depth must be a non-negative integer")
    require_fresh_outputs(output_dir, report_path)
    blocks: list[dict[str, object]] = []
    started = clock()
    queue_status = "running"
    prefetcher = (
        AdaptationPrefetcher(config, indices, output_dir, adapter, production, prefetch_depth)
        if prefetch_depth > 0 and indices
        else None
    )
    loop_completed = False
    try:
        for position, index in enumerate(indices):
            pie = config.pie(index)
            stem = _block_stem(position, pie)
            block_started = clock()
            if prefetcher is None:
                adapted_destination = output_dir / f"{stem}.adapted.stwzcpi"
                adaptation = adapter.prepare(pie, adapted_destination, production)
                delivery = AdaptationDelivery(adaptation, adaptation.wall_s, False, False)
            elif position == 0:
                adapted_destination = prefetcher.destination(position)
                adaptation = adapter.prepare(pie, adapted_destination, production)
                delivery = AdaptationDelivery(adaptation, adaptation.wall_s, False, False)
            else:
                adapted_destination = prefetcher.destination(position)
                delivery = prefetcher.take(position)
                adaptation = delivery.result
            request = BlockRequest(
                queue_position=position,
                pie=pie,
                adapted_input=adaptation.adapted_input or adapted_destination,
                proof_output=output_dir / f"{stem}.proof",
                benchmark_report=output_dir / f"{stem}.benchmark.json",
            )
            if adaptation.status == "completed" and adaptation.adapted_input is not None:
                if prefetcher is not None:
                    prefetcher.fill()
                execution = executor.execute(request)
            else:
                execution = ExecutionResult("not_started", None, 0.0, None)
            record = block_record(request, execution, delivery, clock() - block_started)
            blocks.append(record)
            queue_status = "running" if record["status"] == "verified" else "failed"
            checkpoint = queue_document(
                indices,
                seed,
                executor.name,
                adapter.name,
                production,
                blocks,
                clock() - started,
                queue_status,
                prefetch_depth,
                prefetcher.max_pending if prefetcher is not None else 0,
            )
            write_json_atomic(report_path, checkpoint)
            print(
                f"queue block={position} pie={pie.name} status={record['status']} "
                f"cycles={record['adapted_cycles']} prove_wall_s={record['prove_wall_s']} "
                f"mhz={record['prove_mhz']} adaptation_wait_s={record['adaptation_wait_s']} "
                f"feed_starved={record['feed_starved']}",
                file=sys.stderr,
                flush=True,
            )
            if prefetcher is not None:
                prefetcher.cleanup_position(position)
            if record["status"] != "verified":
                break
        loop_completed = True
    finally:
        if prefetcher is not None:
            prefetcher.shutdown(cancel=not loop_completed or queue_status == "failed")
    session_shutdown_status: str | None = None
    session_close_error: str | None = None
    if isinstance(executor, PersistentSessionExecutor):
        try:
            executor.close()
            session_shutdown_status = "completed"
        except (OSError, SESSION_PROTOCOL.SessionProtocolError) as error:
            session_shutdown_status = "failed"
            session_close_error = str(error)
    queue_wall_s = clock() - started
    all_verified = len(blocks) == len(indices) and all(block["status"] == "verified" for block in blocks)
    session_closed = session_shutdown_status in (None, "completed")
    queue_status = "completed" if all_verified and session_closed else "failed"
    document = queue_document(
        indices,
        seed,
        executor.name,
        adapter.name,
        production,
        blocks,
        queue_wall_s,
        queue_status,
        prefetch_depth,
        prefetcher.max_pending if prefetcher is not None else 0,
        session_shutdown_status,
        session_close_error,
    )
    acceptance = document["production_streaming_acceptance"]
    diagnostic_class = (
        "verified_diagnostic"
        if acceptance["complete_provenance"] and acceptance["complete_protocol"]
        else "verified_incomplete_evidence"
    )
    forbidden_provenance = production and not (
        acceptance["self_contained_proofs"]
        and acceptance["no_parity_fixtures"]
        and acceptance["no_proof_derived_artifacts"]
        and acceptance["complete_provenance"]
        and acceptance["complete_protocol"]
    )
    if forbidden_provenance:
        document["status"] = "production_rejected"
        document["throughput_evidence_class"] = diagnostic_class
        document["summary"]["sustained_mhz"] = None
        document["summary"]["sustained_end_to_end_mhz"] = None
    elif acceptance["passed"]:
        document["throughput_evidence_class"] = "production_self_contained"
    else:
        document["throughput_evidence_class"] = diagnostic_class
    write_json_atomic(report_path, document)
    return document, 0 if queue_status == "completed" and not forbidden_provenance else 1


def queue_document(
    indices: list[int],
    seed: int,
    executor_name: str,
    adapter_name: str,
    production: bool,
    blocks: list[dict[str, object]],
    queue_wall_s: float,
    status: str,
    adapter_prefetch_depth: int = 0,
    max_adapter_prefetch_pending: int = 0,
    session_shutdown_status: str | None = None,
    session_close_error: str | None = None,
) -> dict[str, object]:
    all_verified = (
        len(blocks) == len(indices)
        and all(block["status"] == "verified" for block in blocks)
        and all(_block_has_canonical_rust_verification(block) for block in blocks)
    )
    measurement_complete = all_verified and status == "completed"
    total_cycles = sum(
        int(value)
        for block in blocks
        if isinstance((value := block.get("adapted_cycles")), int) and not isinstance(value, bool)
    )
    total_prove_wall_s = _sum_number(blocks, "prove_wall_s")
    total_adaptation_wall_s = _sum_number(blocks, "execution_adaptation_wall_s")
    persistent = executor_name == PersistentSessionExecutor.name
    session_ids = {
        value for block in blocks
        if isinstance((value := block.get("session_id")), str) and value
    }
    runtime_reuse_verified = (
        all_verified and persistent and all(block.get("metal_runtime_reused") is True for block in blocks)
    )
    resident_arena_reuse_verified = (
        all_verified and persistent and any(block.get("resident_arena_reused") is True for block in blocks)
    )
    preprocessed_state_reuse_verified = (
        all_verified and persistent and any(block.get("preprocessed_state_reused") is True for block in blocks)
    )
    delivered_proofs_verified = all_verified and all(
        isinstance(block.get("proof_sha256"), str)
        and SESSION_PROTOCOL.SHA256_PATTERN.fullmatch(str(block["proof_sha256"])) is not None
        and isinstance(block.get("proof_bytes"), int)
        and int(block["proof_bytes"]) > 0
        for block in blocks
    )
    strict_order_verified = all_verified and all(
        block.get("queue_position") == position
        and block.get("pie_index") == indices[position]
        for position, block in enumerate(blocks)
    )
    seeded_random_order_verified = indices == seeded_queue(seed, len(indices)) if indices else False
    first_block = blocks[0] if blocks else None
    first_cycles = (
        int(first_block["adapted_cycles"])
        if first_block is not None
        and isinstance(first_block.get("adapted_cycles"), int)
        and not isinstance(first_block.get("adapted_cycles"), bool)
        else None
    )
    first_latency = _positive_number(first_block.get("end_to_end_block_latency_s")) if first_block else None
    session_block_wall_s = _sum_number(blocks, "session_block_wall_s")
    prove_mhz_values = [
        float(value)
        for block in blocks
        if (value := _positive_number(block.get("prove_mhz"))) is not None
    ]
    self_contained_proofs = all_verified and all(
        block.get("self_contained") is True for block in blocks
    )
    parity_fixture_blocks = sum(block.get("parity_fixture_used") is not False for block in blocks)
    proof_derived_artifact_blocks = sum(
        block.get("proof_derived_artifact_used") is not False for block in blocks
    )
    statement_self_derived_blocks = sum(
        block.get("statement_self_derived") is True for block in blocks
    )
    provenance_complete_blocks = sum(
        block.get("provenance_complete") is True for block in blocks
    )
    complete_provenance = all_verified and all(
        block.get("statement_self_derived") is True
        and block.get("provenance_complete") is True
        and isinstance(block.get("artifact_manifest_digest"), str)
        and SESSION_PROTOCOL.SHA256_PATTERN.fullmatch(
            str(block["artifact_manifest_digest"])
        ) is not None
        for block in blocks
    )
    complete_protocol = all_verified and all(
        block.get("protocol_complete") is True
        and block.get("protocol") == PROTOCOL_PARAMETERS
        for block in blocks
    )
    pow_telemetry_complete = all_verified and all(
        block.get("pow_telemetry_complete") is True for block in blocks
    )
    pipeline_cache_telemetry_complete, pipeline_cache_delta = (
        _aggregate_pipeline_cache_delta(blocks, measurement_complete)
    )
    production_acceptance = {
        "standard_queue_length": len(indices) in (10, 100),
        "seeded_random_indices_0_through_3": seeded_random_order_verified,
        "raw_pie_adaptation_per_block": production
        and all(block.get("adapted_cache_hit") is False for block in blocks),
        "persistent_metal_session": persistent and len(session_ids) == 1,
        "clean_session_shutdown": persistent and session_shutdown_status == "completed",
        "strict_sequential_proof_order": strict_order_verified,
        "bounded_adaptation_prefetch_enabled": adapter_prefetch_depth > 0
        and max_adapter_prefetch_pending <= adapter_prefetch_depth,
        "cryptographic_verification": all_verified,
        "proof_delivery_with_sha256": delivered_proofs_verified,
        "self_contained_proofs": self_contained_proofs,
        "no_parity_fixtures": parity_fixture_blocks == 0,
        "no_proof_derived_artifacts": proof_derived_artifact_blocks == 0,
        "complete_provenance": complete_provenance,
        "complete_protocol": complete_protocol,
        "pow_telemetry_complete": pow_telemetry_complete,
    }
    production_acceptance["passed"] = status == "completed" and all(production_acceptance.values())
    if persistent:
        proof_execution = "send one proof at a time to one strict-order persistent proving session"
    else:
        proof_execution = "launch one benchmark subprocess and verify one proof per block"
    if adapter_prefetch_depth > 0:
        execution_model = (
            "adapt the current block, prefetch bounded future raw PIEs while the current sequential proof runs, then "
            + proof_execution
        )
    else:
        execution_model = "adapt each raw PIE or record a cache hit, then " + proof_execution
    limitations = [
        "A preadapted cache hit measures proving and verification, not raw PIE ingestion or execution.",
        "Transcript and quotient references are optional paired diagnostics; their use is reported and rejects production acceptance.",
        "Current schedules and semantic artifacts remain proof-derived, so the prepared corpus is not yet self-contained production execution.",
    ]
    if persistent:
        limitations.insert(
            0,
            "Persistent mode reports runtime, resident-arena, and preprocessed-state reuse only when both session capability and per-block result validation succeed.",
        )
    else:
        limitations[0:0] = [
            "This baseline starts a fresh Python benchmark and Zig process for every block.",
            "It does not reuse a Metal runtime, resident arena, compiled kernels, or preprocessed device state.",
        ]
    return {
        "schema_version": 3,
        "benchmark": "sn_pie_metal_queue",
        "status": "completed" if all_verified and status == "completed" else status,
        "seed": seed,
        "requested_length": len(indices),
        "completed_blocks": len(blocks),
        "queue_indices": indices,
        "executor": executor_name,
        "adapter": adapter_name,
        "production": production,
        "adapter_prefetch_depth": adapter_prefetch_depth,
        "session_shutdown_status": session_shutdown_status,
        "session_close_error": session_close_error,
        "execution_model": execution_model,
        "input_policy": (
            "raw source_pie must be adapted per block"
            if production
            else "preadapted caches are allowed but are explicitly reported and are not raw execution"
        ),
        "prefetch_storage_policy": (
            "one current adapted input plus at most adapter_prefetch_depth future inputs; generated staging files are removed after consumption or cancellation"
            if adapter_prefetch_depth > 0
            else "legacy per-block adapted destinations are retained"
        ),
        "blocks": blocks,
        "production_streaming_acceptance": production_acceptance,
        "summary": {
            "all_proofs_verified": all_verified,
            "adapted_cycles": total_cycles,
            "queue_wall_s": queue_wall_s,
            "sustained_mhz": total_cycles / queue_wall_s / 1_000_000 if measurement_complete and queue_wall_s > 0 else None,
            "sustained_end_to_end_mhz": total_cycles / queue_wall_s / 1_000_000 if measurement_complete and queue_wall_s > 0 else None,
            "total_prove_wall_s": total_prove_wall_s,
            "sum_execution_adaptation_wall_s": total_adaptation_wall_s,
            "sum_adaptation_wait_s": _sum_number(blocks, "adaptation_wait_s"),
            "sum_adaptation_overlapped_wall_s": _sum_number(blocks, "adaptation_overlapped_wall_s"),
            "feed_starved_blocks": sum(block.get("feed_starved") is True for block in blocks),
            "prefetched_blocks": sum(block.get("adaptation_prefetched") is True for block in blocks),
            "max_adapter_prefetch_pending": max_adapter_prefetch_pending,
            "adapter_prefetch_workers": 1 if adapter_prefetch_depth > 0 else 0,
            "active_adapted_input_depth_bound": adapter_prefetch_depth + 1 if adapter_prefetch_depth > 0 else 1,
            "sum_end_to_end_block_latency_s": _sum_number(blocks, "end_to_end_block_latency_s"),
            "aggregate_prove_mhz": total_cycles / total_prove_wall_s / 1_000_000 if measurement_complete and total_prove_wall_s > 0 else None,
            "aggregate_prove_only_mhz": total_cycles / total_prove_wall_s / 1_000_000 if measurement_complete and total_prove_wall_s > 0 else None,
            "peak_verified_prove_only_mhz": max(prove_mhz_values) if measurement_complete and prove_mhz_values else None,
            "cold_first_block_end_to_end_mhz": first_cycles / first_latency / 1_000_000 if measurement_complete and first_cycles is not None and first_latency is not None else None,
            "persistent_session_service_mhz": total_cycles / session_block_wall_s / 1_000_000 if measurement_complete and persistent and session_block_wall_s > 0 else None,
            "cold_queue_overhead_s": max(0.0, queue_wall_s - total_prove_wall_s) if measurement_complete else None,
            "sum_process_wall_s": _sum_number(blocks, "process_wall_s"),
            "sum_cold_process_overhead_s": _sum_number(blocks, "cold_process_overhead_s"),
            "sum_session_block_wall_s": session_block_wall_s,
            "persistent_session_count": len(session_ids) if persistent else 0,
            "metal_runtime_reuse_verified": runtime_reuse_verified if persistent else None,
            "resident_arena_reuse_verified": resident_arena_reuse_verified if persistent else None,
            "preprocessed_state_reuse_verified": preprocessed_state_reuse_verified if persistent else None,
            "self_contained_proofs": self_contained_proofs,
            "parity_fixture_blocks": parity_fixture_blocks,
            "proof_derived_artifact_blocks": proof_derived_artifact_blocks,
            "statement_self_derived_blocks": statement_self_derived_blocks,
            "provenance_complete_blocks": provenance_complete_blocks,
            "protocol_complete_blocks": sum(
                block.get("protocol_complete") is True for block in blocks
            ),
            "pow_telemetry_complete_blocks": sum(
                block.get("pow_telemetry_complete") is True for block in blocks
            ),
            "sum_interaction_pow_wall_s": _sum_number(blocks, "interaction_pow_wall_s"),
            "sum_query_pow_wall_s": _sum_number(blocks, "query_pow_wall_s"),
            "pipeline_cache_telemetry_complete": pipeline_cache_telemetry_complete,
            "pipeline_cache_delta": pipeline_cache_delta,
            "peak_max_rss_bytes": _max_integer(blocks, "max_rss_bytes"),
            "peak_footprint_bytes": _max_integer(blocks, "peak_footprint_bytes"),
        },
        "failure_policy": (
            "stop at the first unverified/missing proof, terminate the persistent proving session when active, cancel queued "
            "adaptation, terminate the active adapter process group, remove staged adapted inputs, and keep sustained_mhz null"
        ),
        "limitations": limitations,
    }


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description=__doc__)
    value.add_argument("--manifest", type=Path, required=True)
    value.add_argument("--length", type=int, default=10, help="10 and 100 are standard; any positive length is accepted")
    value.add_argument("--seed", type=int, default=DEFAULT_SEED)
    value.add_argument("--output-dir", type=Path, required=True)
    value.add_argument("--output", type=Path, help="Defaults to OUTPUT_DIR/queue-report.json")
    value.add_argument(
        "--production",
        action="store_true",
        help="Require raw source PIE adaptation for every block; preadapted caches are forbidden",
    )
    value.add_argument(
        "--adapter-prefetch-depth",
        type=int,
        help="Upcoming raw PIEs to adapt on one CPU worker while Metal proves; default uses adapter.prefetch_depth (0)",
    )
    value.add_argument(
        "--session-command",
        help="Shell-like argv for an explicit persistent prover session; overrides manifest session.command",
    )
    value.add_argument(
        "--session-startup-timeout",
        type=float,
        help="Override manifest session.startup_timeout_s",
    )
    return value


def main() -> int:
    args = parser().parse_args()
    try:
        config = load_manifest(args.manifest)
        validate_config(config, args.production)
        indices = seeded_queue(args.seed, args.length)
        prefetch_depth = (
            config.adapter_prefetch_depth
            if args.adapter_prefetch_depth is None
            else args.adapter_prefetch_depth
        )
        if prefetch_depth < 0:
            raise ValueError("adapter prefetch depth must be a non-negative integer")
        session_command = (
            tuple(shlex.split(args.session_command))
            if args.session_command is not None
            else config.session_command
        )
        if args.session_command is not None and not session_command:
            raise ValueError("session command must not be empty")
        session_startup_timeout_s = (
            config.session_startup_timeout_s
            if args.session_startup_timeout is None
            else args.session_startup_timeout
        )
        if not math.isfinite(session_startup_timeout_s) or session_startup_timeout_s <= 0:
            raise ValueError("session startup timeout must be finite and positive")
    except (OSError, json.JSONDecodeError, ValueError) as error:
        raise SystemExit(str(error)) from error
    args.output_dir.mkdir(parents=True, exist_ok=True)
    output = args.output or args.output_dir / "queue-report.json"
    if not output.parent.is_dir():
        raise SystemExit(f"queue report parent does not exist: {output.parent}")
    executor: Executor = (
        PersistentSessionExecutor(
            config,
            session_command,
            session_startup_timeout_s,
            args.output_dir / "session-daemon.stderr.log",
        )
        if session_command is not None
        else SubprocessExecutor(config)
    )
    try:
        document, exit_code = run_queue(
            config,
            indices,
            args.seed,
            args.output_dir,
            output,
            executor,
            CacheOrCommandAdapter(config),
            args.production,
            adapter_prefetch_depth=prefetch_depth,
        )
    except ValueError as error:
        raise SystemExit(str(error)) from error
    sys.stdout.write(json.dumps(document, indent=2) + "\n")
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
