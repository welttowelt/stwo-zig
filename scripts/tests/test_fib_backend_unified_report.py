import copy
import importlib.util
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "fib_backend_unified_report.py"
SPEC = importlib.util.spec_from_file_location("fib_backend_unified_report", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


def distribution(value):
    return {
        "median": value,
        "p25": value,
        "p75": value,
        "min": value,
        "max": value,
    }


def riscv_lane(fib_n, prove_s, total_s, process_s):
    cycles = 5 * fib_n - 3
    sample = {
        "fib_n": fib_n,
        "cycles": cycles,
        "prove_ms": prove_s * 1000,
        "cli_total_ms": total_s * 1000,
        "process_wall_s": process_s,
        "prove_mhz": cycles / prove_s / 1e6,
        "e2e_mhz": cycles / process_s / 1e6,
        "prove_fib_iterations_per_s": fib_n / prove_s,
        "e2e_fib_iterations_per_s": fib_n / process_s,
        "pcs_fri_accepted_by_shared_verifier": True,
        "soundness_status": "diagnostic_pcs_fri_only",
    }
    fields = (
        "prove_ms",
        "cli_total_ms",
        "process_wall_s",
        "prove_mhz",
        "e2e_mhz",
        "prove_fib_iterations_per_s",
        "e2e_fib_iterations_per_s",
    )
    return {
        "summary": {"samples": 1, **{field: distribution(sample[field]) for field in fields}},
        "raw_samples": [sample],
    }


def riscv_report(sizes=(25_000, 50_000)):
    return {
        "schema_version": 3,
        "benchmark": "riscv_fib_backend_compare",
        "status": "completed",
        "soundness_status": "diagnostic_pcs_fri_only",
        "no_trace_dependent_air_constraints": True,
        "shared_verifier": True,
        "sound_proof_evidence": False,
        "production_evidence": False,
        "correctness_parity_evidence": False,
        "protocol": {
            "hash": "blake2s",
            "log_blowup_factor": 1,
            "fri_log_last_layer_degree_bound": 0,
            "fri_fold_step": 1,
            "pow_bits": 10,
            "n_queries": 3,
        },
        "backends": {
            "cpu": {
                "label": "Zig CPU ReleaseFast with auto-SIMD hot paths",
                "binary": "/riscv-cpu",
                "sha256": "1" * 64,
            },
            "metal": {
                "label": "generic hybrid MetalProverEngine",
                "binary": "/riscv-metal",
                "sha256": "2" * 64,
            },
        },
        "rows": [
            {
                "fib_n": fib_n,
                "cycles": 5 * fib_n - 3,
                "cpu": riscv_lane(fib_n, 0.5, 0.7, 0.75),
                "metal": riscv_lane(fib_n, 0.25, 0.4, 0.45),
            }
            for fib_n in sizes
        ],
    }


def cairo_lane(fib_n, prove_s, total_s, process_s):
    cycles = 7 * fib_n + 16
    protocol = dict(MODULE.EXPECTED_CAIRO_PROTOCOL)
    sample = {
        "fib_n": fib_n,
        "cycles": cycles,
        "prove_s": prove_s,
        "constructed_internal_total_s": total_s,
        "process_wall_s": process_s,
        "native_prove_mhz": cycles / prove_s / 1e6,
        "native_end_to_end_mhz": cycles / process_s / 1e6,
        "fib_prove_iterations_per_s": fib_n / prove_s,
        "fib_end_to_end_iterations_per_s": fib_n / process_s,
        "proof_verified": True,
        "protocol": protocol,
    }
    fields = (
        "prove_s",
        "constructed_internal_total_s",
        "process_wall_s",
        "native_prove_mhz",
        "native_end_to_end_mhz",
        "fib_prove_iterations_per_s",
        "fib_end_to_end_iterations_per_s",
    )
    return {
        "summary": {"samples": 1, **{field: distribution(sample[field]) for field in fields}},
        "raw_samples": [sample],
    }


def cairo_report(sizes):
    return {
        "schema_version": 1,
        "benchmark": "cairo_fib_backend_compare",
        "status": "completed",
        "workload": "compiled Cairo recursive Fibonacci program",
        "cycle_semantics": "emitted Cairo opcode cycles; expected 7 * fib_n + 16",
        "protocol": dict(MODULE.EXPECTED_CAIRO_PROTOCOL),
        "measurement": {"repeats": 1},
        "artifacts": {"gpu_bench": {"sha256": "3" * 64}},
        "backends": {
            "rust-simd": {
                "gpu_bench_backend": "simd",
                "engine": "legacy",
                "acceleration": "cpu_simd",
            },
            "rust-metal": {
                "gpu_bench_backend": "metal",
                "engine": "legacy",
                "acceleration": "apple_metal_gpu",
            },
        },
        "environment": {"RAYON_NUM_THREADS": "16"},
        "rows": [
            {
                "fib_n": fib_n,
                "expected_cycles": 7 * fib_n + 16,
                "backends": {
                    "rust-simd": cairo_lane(fib_n, 1.0, 1.3, 1.4),
                    "rust-metal": cairo_lane(fib_n, 0.8, 1.1, 1.2),
                },
            }
            for fib_n in sizes
        ],
    }


class FibBackendUnifiedReportTests(unittest.TestCase):
    def test_merges_shards_and_separates_diagnostic_from_legacy_lanes(self):
        cairo = MODULE.merge_cairo_reports(
            [cairo_report((50_000,)), cairo_report((25_000,))]
        )
        unified = MODULE.build_unified_report(riscv_report(), cairo)

        self.assertEqual(unified["schema_version"], 2)
        self.assertEqual(unified["supersedes_unified_schema_version"], 1)
        self.assertFalse(unified["cross_vm_correctness_ranking_allowed"])
        self.assertFalse(unified["cross_vm_performance_ranking_allowed"])
        self.assertEqual(
            unified["evidence_classification"]["riscv"]["soundness_status"],
            "diagnostic_pcs_fri_only",
        )
        self.assertTrue(
            unified["evidence_classification"]["riscv"][
                "no_trace_dependent_air_constraints"
            ]
        )
        self.assertTrue(unified["evidence_classification"]["riscv"]["shared_verifier"])
        self.assertEqual([row["fib_n"] for row in unified["rows"]], [25_000, 50_000])
        self.assertEqual(tuple(unified["lane_order"]), MODULE.LANE_ORDER)
        self.assertEqual(
            unified["rows"][0]["lanes"]["riscv_zig_cpu"]["native_cycles"],
            124_997,
        )
        self.assertEqual(
            unified["rows"][0]["lanes"]["cairo_rust_simd"]["native_cycles"],
            175_016,
        )
        self.assertTrue(
            unified["lanes"]["cairo_rust_metal_hybrid"]["hybrid"]
        )
        self.assertTrue(
            unified["rows"][0]["lanes"]["riscv_zig_cpu"]["internal_total"]["directly_timed"]
        )
        self.assertFalse(
            unified["rows"][0]["lanes"]["cairo_rust_simd"]["internal_total"]["directly_timed"]
        )
        self.assertEqual(
            unified["rows"][0]["within_vm_backend_speedup"][
                "riscv_diagnostic_metal_over_cpu_auto_simd"
            ]["fresh_process_total"],
            0.75 / 0.45,
        )
        riscv_lane_result = unified["rows"][0]["lanes"]["riscv_zig_cpu"]
        self.assertEqual(riscv_lane_result["diagnostic_artifacts_accepted"], 1)
        self.assertFalse(riscv_lane_result["eligible_for_sound_performance_ranking"])
        self.assertNotIn("proofs_verified", riscv_lane_result)

        markdown = MODULE.render_markdown(unified)
        self.assertIn("Cross-VM correctness and performance ranking is refused", markdown)
        self.assertIn("RISC-V Diagnostic PCS/FRI Throughput", markdown)
        self.assertIn("no trace-dependent AIR", markdown)
        self.assertIn("`5*N-3`", markdown)
        self.assertIn("`7*N+16`", markdown)
        self.assertIn("Cairo Legacy Schema-v1 Source Results", markdown)
        self.assertIn("Rust Cairo hybrid Metal backend", markdown)
        self.assertNotIn("cross-VM workload rate", markdown)
        self.assertNotIn("verified fresh processes", markdown)
        self.assertEqual(markdown.count("| 25,000 |"), 10)

    def test_rejects_duplicate_cairo_rows_across_shards(self):
        with self.assertRaisesRegex(ValueError, "duplicate Cairo Fib N"):
            MODULE.merge_cairo_reports(
                [cairo_report((25_000,)), cairo_report((25_000,))]
            )

    def test_rejects_cairo_shard_configuration_drift(self):
        changed = cairo_report((50_000,))
        changed["protocol"]["n_queries"] = 3
        with self.assertRaisesRegex(ValueError, "shard mismatch for protocol"):
            MODULE.merge_cairo_reports([cairo_report((25_000,)), changed])

    def test_rejects_missing_cross_vm_size(self):
        with self.assertRaisesRegex(ValueError, "identical Fib N"):
            MODULE.build_unified_report(
                riscv_report(),
                cairo_report((25_000,)),
            )

    def test_rejects_cycle_formula_and_unverified_sample(self):
        bad_cycles = riscv_report()
        bad_cycles["rows"][0]["cycles"] += 1
        with self.assertRaisesRegex(ValueError, r"5\*N-3"):
            MODULE.build_unified_report(bad_cycles, cairo_report((25_000, 50_000)))

        unverified = cairo_report((25_000, 50_000))
        unverified["rows"][0]["backends"]["rust-metal"]["raw_samples"][0][
            "proof_verified"
        ] = False
        with self.assertRaisesRegex(ValueError, "unverified proof"):
            MODULE.build_unified_report(riscv_report(), unverified)

    def test_rejects_riscv_soundness_upgrade_or_ambiguous_verification(self):
        upgraded = riscv_report()
        upgraded["sound_proof_evidence"] = True
        with self.assertRaisesRegex(ValueError, "diagnostic classification mismatch"):
            MODULE.build_unified_report(upgraded, cairo_report((25_000, 50_000)))

        ambiguous = riscv_report()
        ambiguous["rows"][0]["cpu"]["raw_samples"][0]["proof_verified"] = True
        with self.assertRaisesRegex(ValueError, "ambiguous proof_verified evidence"):
            MODULE.build_unified_report(ambiguous, cairo_report((25_000, 50_000)))

        missing_acceptance = riscv_report()
        del missing_acceptance["rows"][0]["metal"]["raw_samples"][0][
            "pcs_fri_accepted_by_shared_verifier"
        ]
        with self.assertRaisesRegex(ValueError, "lacks shared-verifier PCS/FRI acceptance"):
            MODULE.build_unified_report(
                missing_acceptance,
                cairo_report((25_000, 50_000)),
            )

    def test_rejects_tampered_summary_and_unsupported_backend(self):
        tampered = riscv_report()
        tampered["rows"][0]["cpu"]["summary"]["prove_ms"]["median"] += 1
        with self.assertRaisesRegex(ValueError, "inconsistent with raw samples"):
            MODULE.build_unified_report(tampered, cairo_report((25_000, 50_000)))

        extra = cairo_report((25_000, 50_000))
        extra["backends"]["cuda"] = {
            "gpu_bench_backend": "cuda",
            "engine": "legacy",
            "acceleration": "nvidia_cuda_gpu",
        }
        for row in extra["rows"]:
            row["backends"]["cuda"] = copy.deepcopy(row["backends"]["rust-metal"])
        with self.assertRaisesRegex(ValueError, "unsupported Cairo backend"):
            MODULE.build_unified_report(riscv_report(), extra)


if __name__ == "__main__":
    unittest.main()
