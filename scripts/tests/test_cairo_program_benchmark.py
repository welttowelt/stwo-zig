from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parents[1]
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from cairo_program_benchmark_lib import (  # noqa: E402
    LANES,
    PROGRAMS,
    PROGRAM_BY_SLUG,
    EvidenceError,
    ProvenanceError,
    benchmark_environment,
    build_command,
    collect_report,
    compile_cache,
    load_compile_manifest,
    parse_gpu_bench_output,
    resolve_cases,
    resolve_lanes,
    runtime_provenance,
    validate_compile_manifest,
)


def run(command: list[str], cwd: Path) -> None:
    subprocess.run(command, cwd=cwd, check=True, capture_output=True, text=True)


def initialize_repository(root: Path) -> None:
    run(["git", "init", "-q"], root)
    run(["git", "config", "user.name", "Test Author"], root)
    run(["git", "config", "user.email", "test@example.com"], root)


def commit_all(root: Path) -> None:
    run(["git", "add", "."], root)
    run(["git", "commit", "-q", "-m", "fixture"], root)


def write_program_sources(root: Path) -> None:
    for program in PROGRAMS:
        source = root / program.source_relative
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_text(f"// deterministic {program.slug}\n")


def write_fake_compiler(path: Path) -> None:
    path.write_text(
        """#!/usr/bin/env python3
import json
import pathlib
import sys
if '--version' in sys.argv:
    print('cairo-compile 0.14.0.1')
    raise SystemExit(0)
source = pathlib.Path(sys.argv[1])
output = pathlib.Path(sys.argv[sys.argv.index('--output') + 1])
output.write_text(json.dumps({
    'compiler_version': '0.14.0.1',
    'source_text': source.read_text(),
}, sort_keys=True))
"""
    )
    path.chmod(0o755)


def gpu_record(
    *,
    compiled: Path,
    size: int,
    lane: str,
    cycles: int,
    proofs: int = 3,
) -> dict[str, object]:
    prove = [2.0] + [1.0 + 0.1 * index for index in range(proofs - 1)]
    verify_ms = [5.0] + [4.0] * (proofs - 1)
    warm = sorted(prove[1:])
    middle = len(warm) // 2
    warm_median = (
        warm[middle]
        if len(warm) % 2
        else (warm[middle - 1] + warm[middle]) / 2.0
    )
    return {
        "program": str(compiled),
        "backend": lane,
        "engine": "legacy",
        "n": size,
        "cycle_count": cycles,
        "pie_n_steps": None,
        "bootloader_overhead_pct": None,
        "prove_s_cold": prove[0],
        "prove_s_warm": min(prove[1:]),
        "prove_s_warm_median": warm_median,
        "prove_s_total": sum(prove),
        "prove_s_samples": prove,
        "proofs_requested": proofs,
        "proofs_verified": proofs,
        "all_proofs_verified": True,
        "proof_byte_equal": True,
        "verify_ms": verify_ms[0],
        "verify_ms_total": sum(verify_ms),
        "verify_ms_samples": verify_ms,
        "proof_kb": 123.5,
        "vm_s": 0.2,
        "adapt_s": 0.1,
        "security_bits": 96,
        "n_queries": 70,
        "pow_bits": 26,
        "fold_step": 3,
    }


def parse_record(
    *,
    compiled: Path,
    program_slug: str,
    size: int,
    lane_key: str,
    cycles: int,
    proofs: int = 3,
) -> dict[str, object]:
    record = gpu_record(
        compiled=compiled,
        size=size,
        lane=lane_key,
        cycles=cycles,
        proofs=proofs,
    )
    return parse_gpu_bench_output(
        json.dumps(record),
        program=PROGRAM_BY_SLUG[program_slug],
        size=size,
        lane=LANES[lane_key],
        compiled=compiled,
        proofs_per_process=proofs,
    )


class CatalogTests(unittest.TestCase):
    def test_catalog_contains_canonical_nine_programs(self) -> None:
        self.assertEqual(
            [program.slug for program in PROGRAMS],
            [
                "fib",
                "sha2",
                "sha2-chain",
                "sha3",
                "sha3-chain",
                "blake",
                "blake-chain",
                "mat-mul",
                "ec",
            ],
        )

    def test_program_specific_size_semantics_are_not_conflated(self) -> None:
        self.assertEqual(PROGRAM_BY_SLUG["sha2"].size_unit, "input_bytes")
        self.assertEqual(PROGRAM_BY_SLUG["sha2-chain"].size_unit, "hashes")
        self.assertEqual(PROGRAM_BY_SLUG["mat-mul"].size_unit, "matrix_dimension")
        self.assertEqual(PROGRAM_BY_SLUG["ec"].size_unit, "point_doublings")

    def test_case_parser_enforces_program_specific_alignment(self) -> None:
        with self.assertRaisesRegex(ValueError, "divisible by 8"):
            resolve_cases(["sha3=65"])
        cases = resolve_cases(["sha3=64,1024", "ec=64"])
        self.assertEqual(cases[0][1], (64, 1024))

    def test_case_parser_rejects_duplicate_programs(self) -> None:
        with self.assertRaisesRegex(ValueError, "only one case"):
            resolve_cases(["fib=25000", "fib=50000"])

    def test_lane_labels_are_explicitly_rust_and_never_zig(self) -> None:
        lanes = resolve_lanes(None)
        self.assertEqual([lane.key for lane in lanes], ["simd", "metal"])
        for lane in lanes:
            record = lane.as_record()
            self.assertIn("Rust stwo-cairo", record["label"])
            self.assertFalse(record["is_zig_backend"])


class EvidenceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.compiled = Path("/tmp/canonical-compiled.json")

    def test_sha_accepts_positive_emitted_cycles_without_fib_formula(self) -> None:
        sample = parse_record(
            compiled=self.compiled,
            program_slug="sha2-chain",
            size=8,
            lane_key="simd",
            cycles=3_010,
        )
        self.assertEqual(sample["cycles"], 3_010)
        self.assertEqual(sample["cycle_gate"], "emitted_positive")
        self.assertEqual(sample["verification_oracle"], "Rust stwo-cairo verify_cairo")

    def test_fib_retains_optional_exact_cycle_gate(self) -> None:
        accepted = parse_record(
            compiled=self.compiled,
            program_slug="fib",
            size=25_000,
            lane_key="metal",
            cycles=175_016,
        )
        self.assertEqual(accepted["cycle_gate"], "exact")
        with self.assertRaisesRegex(EvidenceError, "exact cycle gate"):
            parse_record(
                compiled=self.compiled,
                program_slug="fib",
                size=25_000,
                lane_key="metal",
                cycles=175_015,
            )

    def test_every_requested_proof_must_be_verified(self) -> None:
        record = gpu_record(
            compiled=self.compiled,
            size=8,
            lane="simd",
            cycles=3_010,
        )
        record["proofs_verified"] = 2
        record["all_proofs_verified"] = False
        with self.assertRaisesRegex(EvidenceError, "verify every"):
            parse_gpu_bench_output(
                json.dumps(record),
                program=PROGRAM_BY_SLUG["sha2-chain"],
                size=8,
                lane=LANES["simd"],
                compiled=self.compiled,
                proofs_per_process=3,
            )

    def test_resident_proofs_must_be_byte_equal(self) -> None:
        record = gpu_record(
            compiled=self.compiled,
            size=64,
            lane="metal",
            cycles=15_000,
        )
        record["proof_byte_equal"] = False
        with self.assertRaisesRegex(EvidenceError, "byte-identical"):
            parse_gpu_bench_output(
                json.dumps(record),
                program=PROGRAM_BY_SLUG["ec"],
                size=64,
                lane=LANES["metal"],
                compiled=self.compiled,
                proofs_per_process=3,
            )

    def test_cold_warm_and_total_metrics_preserve_scope(self) -> None:
        sample = parse_record(
            compiled=self.compiled,
            program_slug="sha2-chain",
            size=8,
            lane_key="simd",
            cycles=3_010,
        )
        self.assertEqual(sample["cold_prove_s"], 2.0)
        self.assertEqual(sample["warm_prove_s"], 1.05)
        self.assertEqual(sample["prove_s_total"], 4.1)
        self.assertAlmostEqual(sample["execute_adapt_s"], 0.3)

    def test_command_is_locked_to_legacy_rust_backend(self) -> None:
        command = build_command(
            Path("/tmp/gpu_bench"), self.compiled, 8, LANES["metal"], 3
        )
        self.assertEqual(command[command.index("--backend") + 1], "metal")
        self.assertEqual(command[command.index("--engine") + 1], "legacy")
        self.assertIn("--reuse-input", command)

    def test_process_wall_is_measured_around_the_whole_subprocess(self) -> None:
        from cairo_program_benchmark_lib import run_sample

        record = gpu_record(
            compiled=self.compiled,
            size=8,
            lane="simd",
            cycles=3_010,
        )

        def runner(*_args: object, **_kwargs: object) -> subprocess.CompletedProcess[str]:
            return subprocess.CompletedProcess([], 0, json.dumps(record), "")

        ticks = iter((10.0, 15.0))
        sample = run_sample(
            binary=Path("/tmp/gpu_bench"),
            compiled=self.compiled,
            program=PROGRAM_BY_SLUG["sha2-chain"],
            size=8,
            lane=LANES["simd"],
            proofs_per_process=3,
            timeout_s=10.0,
            environment={},
            runner=runner,
            clock=lambda: next(ticks),
        )
        self.assertEqual(sample["process_wall_s"], 5.0)
        self.assertAlmostEqual(sample["sustained_cycle_mhz"], 0.001806)

    def test_environment_scrubs_proof_bypass_flags(self) -> None:
        environment = benchmark_environment(
            {"PATH": "/bin", "STWO_ADAPT_ONLY": "1", "STWO_DUMP_PROOF": "/tmp/x"},
            rayon_threads=4,
        )
        self.assertNotIn("STWO_ADAPT_ONLY", environment)
        self.assertNotIn("STWO_DUMP_PROOF", environment)
        self.assertEqual(environment["RAYON_NUM_THREADS"], "4")


class ProvenanceFixture(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.source_repo = self.root / "program-repo"
        self.source_repo.mkdir()
        initialize_repository(self.source_repo)
        write_program_sources(self.source_repo)
        commit_all(self.source_repo)
        self.compiler = self.root / "cairo-compile"
        write_fake_compiler(self.compiler)
        self.cache = self.root / "cache"
        self.manifest = self.root / "compile-manifest.json"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def compile(self, *, allow_non_headline: bool = False) -> dict[str, object]:
        return compile_cache(
            program_root=self.source_repo,
            source_repo=self.source_repo,
            compiler=self.compiler,
            output_dir=self.cache,
            manifest_path=self.manifest,
            allow_non_headline=allow_non_headline,
        )

    def runtime_repositories(self) -> tuple[Path, Path, Path]:
        gpu_repo = self.root / "stwo-cairo"
        gpu_repo.mkdir()
        initialize_repository(gpu_repo)
        (gpu_repo / ".gitignore").write_text("target/\n")
        (gpu_repo / "Cargo.lock").write_text("lock\n")
        (gpu_repo / "rust-toolchain.toml").write_text("[toolchain]\nchannel='nightly'\n")
        source = gpu_repo / "gpu_bench.rs"
        source.write_text("fn main() {}\n")
        commit_all(gpu_repo)
        release = gpu_repo / "target/release"
        release.mkdir(parents=True)
        binary = release / "gpu_bench"
        binary.write_text("binary\n")
        binary.chmod(0o755)
        dependency = release / "gpu_bench.d"
        dependency.write_text(f"{binary}: {source}\n")

        stwo_repo = self.root / "stwo"
        stwo_repo.mkdir()
        initialize_repository(stwo_repo)
        (stwo_repo / "Cargo.toml").write_text("[workspace]\n")
        commit_all(stwo_repo)
        return binary, gpu_repo, stwo_repo


class ProvenanceTests(ProvenanceFixture):
    def test_compile_cache_hashes_all_nine_artifacts(self) -> None:
        document = self.compile()
        self.assertTrue(document["provenance"]["headline_eligible"])
        self.assertEqual(set(document["programs"]), set(PROGRAM_BY_SLUG))
        for record in document["programs"].values():
            self.assertEqual(len(record["source"]["sha256"]), 64)
            self.assertEqual(len(record["compiled"]["sha256"]), 64)
            self.assertEqual(record["compiled"]["compiler_version"], "0.14.0.1")

    def test_dirty_source_repository_is_rejected_before_compilation(self) -> None:
        (self.source_repo / "untracked.txt").write_text("dirty\n")
        with self.assertRaisesRegex(ProvenanceError, "dirty_cairo_program"):
            self.compile()

    def test_manifest_detects_source_and_artifact_drift(self) -> None:
        self.compile()
        document = load_compile_manifest(self.manifest)
        source = self.source_repo / PROGRAM_BY_SLUG["sha2"].source_relative
        source.write_text("// changed\n")
        artifact = self.cache / PROGRAM_BY_SLUG["ec"].artifact_relative
        artifact.write_text("{}")
        _, blockers = validate_compile_manifest(
            document, [PROGRAM_BY_SLUG["sha2"], PROGRAM_BY_SLUG["ec"]]
        )
        self.assertIn("dirty_cairo_program_source_repository", blockers)
        self.assertIn("sha2_source_hash_changed", blockers)
        self.assertIn("ec_compiled_hash_changed", blockers)

    def test_runtime_provenance_hashes_binary_and_clean_revisions(self) -> None:
        binary, gpu_repo, stwo_repo = self.runtime_repositories()
        record, blockers = runtime_provenance(
            gpu_bench=binary,
            gpu_bench_repo=gpu_repo,
            rust_stwo_repo=stwo_repo,
        )
        self.assertEqual(blockers, [])
        self.assertEqual(len(record["gpu_bench"]["sha256"]), 64)
        self.assertTrue(record["stwo_cairo_repository"]["clean"])
        self.assertTrue(record["rust_stwo_repository"]["clean"])

    def test_runtime_provenance_rejects_dirty_or_stale_source(self) -> None:
        binary, gpu_repo, stwo_repo = self.runtime_repositories()
        source = gpu_repo / "gpu_bench.rs"
        future = time.time() + 2
        source.write_text("fn changed() {}\n")
        os.utime(source, (future, future))
        _, blockers = runtime_provenance(
            gpu_bench=binary,
            gpu_bench_repo=gpu_repo,
            rust_stwo_repo=stwo_repo,
        )
        self.assertIn("dirty_stwo_cairo_repository", blockers)
        self.assertIn("gpu_bench_has_newer_dependencies", blockers)

    def test_non_headline_controller_preserves_process_wall_metrics(self) -> None:
        self.compile()
        binary, gpu_repo, stwo_repo = self.runtime_repositories()
        calls: list[tuple[str, int, str]] = []

        def sample_runner(**kwargs: object) -> dict[str, object]:
            program = kwargs["program"]
            size = kwargs["size"]
            lane = kwargs["lane"]
            compiled = kwargs["compiled"]
            assert hasattr(program, "slug") and hasattr(lane, "key")
            calls.append((program.slug, size, lane.key))
            cycles = 3_010 if program.slug == "sha2-chain" else 10_000
            sample = parse_record(
                compiled=compiled,
                program_slug=program.slug,
                size=size,
                lane_key=lane.key,
                cycles=cycles,
            )
            wall = 5.0
            sample.update(
                {
                    "process_wall_s": wall,
                    "amortized_process_wall_s": wall / 3,
                    "process_overhead_s": wall
                    - sample["prove_s_total"]
                    - sample["verify_s_total"],
                    "sustained_cycle_mhz": cycles * 3 / wall / 1_000_000,
                    "sustained_size_units_per_s": size * 3 / wall,
                    "resident_batch_internal_total_s": sample["execute_adapt_s"]
                    + sample["prove_s_total"]
                    + sample["verify_s_total"],
                }
            )
            return sample

        report = collect_report(
            manifest_path=self.manifest,
            gpu_bench=binary,
            gpu_bench_repo=gpu_repo,
            rust_stwo_repo=stwo_repo,
            cases=resolve_cases(["sha2-chain=8"]),
            lanes=resolve_lanes(None),
            warmups=0,
            repeats=1,
            proofs_per_process=3,
            timeout_s=10.0,
            pause_s=0.0,
            rayon_threads=2,
            allow_non_headline=True,
            sample_runner=sample_runner,
        )
        self.assertFalse(report["headline_eligible"])
        self.assertIn(
            "insufficient_measured_repeats", report["provenance"]["blockers"]
        )
        row = report["rows"][0]
        self.assertEqual(row["emitted_cycle_count"], 3_010)
        self.assertEqual(
            row["lanes"]["metal"]["summary"]["process_wall_s"]["median"], 5.0
        )
        self.assertEqual(calls, [("sha2-chain", 8, "simd"), ("sha2-chain", 8, "metal")])


if __name__ == "__main__":
    unittest.main()
