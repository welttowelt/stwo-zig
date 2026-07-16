import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "cairo_fib_backend_compare.py"
SPEC = importlib.util.spec_from_file_location("cairo_fib_backend_compare", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


def record(
    *,
    fib_n=25_000,
    backend="simd",
    engine="legacy",
    cycles=None,
    proof_kb=1234.5,
    program="/tmp/compiled.json",
):
    prove_samples = [1.25, 0.75]
    verify_ms_samples = [6.5, 6.0]
    return {
        "program": program,
        "backend": backend,
        "engine": engine,
        "n": fib_n,
        "cycle_count": MODULE.expected_cycles(fib_n) if cycles is None else cycles,
        "pie_n_steps": None,
        "bootloader_overhead_pct": None,
        "prove_s_cold": prove_samples[0],
        "prove_s_warm": prove_samples[1],
        "prove_s_warm_median": prove_samples[1],
        "prove_s_total": sum(prove_samples),
        "prove_s_samples": prove_samples,
        "proofs_requested": len(prove_samples),
        "proofs_verified": len(prove_samples),
        "all_proofs_verified": True,
        "proof_byte_equal": True,
        "verify_ms": verify_ms_samples[0],
        "verify_ms_total": sum(verify_ms_samples),
        "verify_ms_samples": verify_ms_samples,
        "proof_kb": proof_kb,
        "vm_s": 0.2,
        "adapt_s": 0.1,
        "mhz": round(MODULE.expected_cycles(fib_n) / prove_samples[1] / 1_000_000, 3),
        "security_bits": 96,
        "n_queries": 70,
        "pow_bits": 26,
        "fold_step": 3,
    }


def sample_from_record(value, spec, process_wall_s=2.5):
    parsed = MODULE.parse_gpu_bench_output(
        json.dumps(value),
        value["n"],
        spec,
        Path(value["program"]),
        value["proofs_requested"],
    )
    parsed["process_wall_s"] = process_wall_s
    parsed["amortized_process_wall_s"] = process_wall_s / parsed["proofs_per_process"]
    parsed["process_overhead_s"] = (
        process_wall_s - parsed["prove_s_total"] - parsed["verify_s_total"]
    )
    parsed["sustained_native_mhz"] = (
        parsed["cycles"] * parsed["proofs_per_process"] / process_wall_s / 1_000_000
    )
    parsed["sustained_fib_iterations_per_s"] = (
        parsed["fib_n"] * parsed["proofs_per_process"] / process_wall_s
    )
    return parsed


class CairoFibBackendCompareTests(unittest.TestCase):
    def test_backend_specs_default_to_real_rust_simd(self):
        self.assertEqual(
            MODULE.parse_backend_specs(None),
            [MODULE.BackendSpec("rust-simd", "simd", "legacy")],
        )
        self.assertEqual(
            MODULE.parse_backend_spec("native-simd=simd:gpu-native"),
            MODULE.BackendSpec("native-simd", "simd", "gpu-native"),
        )
        self.assertEqual(
            MODULE.parse_backend_spec("metal=metal:legacy"),
            MODULE.BackendSpec("metal", "metal", "legacy"),
        )
        self.assertEqual(
            MODULE.parse_backend_spec("apple-gpu=metal"),
            MODULE.BackendSpec("apple-gpu", "metal", "legacy"),
        )

    def test_backend_spec_rejects_unimplemented_pairs_and_duplicates(self):
        with self.assertRaisesRegex(ValueError, "metal/gpu-native"):
            MODULE.parse_backend_spec("metal=metal:gpu-native")
        with self.assertRaisesRegex(ValueError, "unsupported gpu_bench backend"):
            MODULE.parse_backend_spec("fake=vulkan:legacy")
        with self.assertRaisesRegex(ValueError, "unique"):
            MODULE.parse_backend_specs(["a=simd", "a=simd:gpu-native"])

    def test_command_forces_resident_verified_proofs_per_process(self):
        command = MODULE.build_command(
            Path("/gpu_bench"),
            Path("/compiled.json"),
            25_000,
            MODULE.BackendSpec("simd", "simd", "legacy"),
            2,
        )
        self.assertEqual(command[-3:], ["--reps", "2", "--reuse-input"])
        self.assertEqual(command[command.index("--reps") + 1], "2")
        self.assertEqual(command[command.index("--backend") + 1], "simd")

        metal_command = MODULE.build_command(
            Path("/gpu_bench"),
            Path("/compiled.json"),
            25_000,
            MODULE.BackendSpec("metal", "metal", "legacy"),
            3,
        )
        self.assertEqual(metal_command[metal_command.index("--backend") + 1], "metal")
        self.assertEqual(metal_command[metal_command.index("--engine") + 1], "legacy")

    def test_environment_removes_proof_bypass_controls(self):
        environment = MODULE.benchmark_environment(
            {
                "PATH": "/bin",
                "STWO_ADAPT_ONLY": "1",
                "STWO_DUMP_INPUT": "/tmp/input",
                "STWO_BENCH_TRACE": "json",
                "STWO_METAL_WITNESS_UPLOAD_MODE": "private",
                "STWO_CAIRO_LOW_MEMORY": "1",
            },
            rayon_threads=16,
        )
        self.assertEqual(environment, {"PATH": "/bin", "RAYON_NUM_THREADS": "16"})

    def test_parse_verified_record_normalizes_timings_and_rates(self):
        spec = MODULE.BackendSpec("rust-simd", "simd", "legacy")
        parsed = MODULE.parse_gpu_bench_output(
            json.dumps(record()),
            25_000,
            spec,
            Path("/tmp/compiled.json"),
            2,
        )
        self.assertEqual(parsed["cycles"], 175_016)
        self.assertAlmostEqual(parsed["execute_adapt_s"], 0.3)
        self.assertAlmostEqual(parsed["verify_s_total"], 0.0125)
        self.assertAlmostEqual(parsed["resident_batch_internal_total_s"], 2.3125)
        self.assertFalse(parsed["resident_batch_internal_total"]["directly_timed"])
        self.assertAlmostEqual(parsed["cold_native_mhz"], 175_016 / 1.25 / 1_000_000)
        self.assertAlmostEqual(parsed["warm_native_mhz"], 175_016 / 0.75 / 1_000_000)
        self.assertTrue(parsed["proof_verified"])

    def test_parse_verified_metal_record_preserves_backend_identity(self):
        spec = MODULE.BackendSpec("metal", "metal", "legacy")
        parsed = MODULE.parse_gpu_bench_output(
            json.dumps(record(backend="metal")),
            25_000,
            spec,
            Path("/tmp/compiled.json"),
            2,
        )
        self.assertEqual(parsed["gpu_bench_record"]["backend"], "metal")
        self.assertEqual(parsed["gpu_bench_record"]["engine"], "legacy")

    def test_parse_rejects_missing_verification(self):
        value = record()
        value["all_proofs_verified"] = False
        with self.assertRaisesRegex(ValueError, "all_proofs_verified"):
            MODULE.parse_gpu_bench_output(
                json.dumps(value),
                25_000,
                MODULE.BackendSpec("rust-simd", "simd", "legacy"),
                Path("/tmp/compiled.json"),
                2,
            )

    def test_parse_rejects_cycle_backend_and_protocol_mismatch(self):
        spec = MODULE.BackendSpec("rust-simd", "simd", "legacy")
        with self.assertRaisesRegex(ValueError, "geometry mismatch"):
            MODULE.parse_gpu_bench_output(
                json.dumps(record(cycles=123)), 25_000, spec, Path("/tmp/compiled.json"), 2
            )
        with self.assertRaisesRegex(ValueError, "backend identity"):
            MODULE.parse_gpu_bench_output(
                json.dumps(record(backend="cuda")),
                25_000,
                spec,
                Path("/tmp/compiled.json"),
                2,
            )
        value = record()
        value["n_queries"] = 3
        with self.assertRaisesRegex(ValueError, "protocol mismatch"):
            MODULE.parse_gpu_bench_output(
                json.dumps(value), 25_000, spec, Path("/tmp/compiled.json"), 2
            )

    def test_parser_ignores_diagnostic_json_but_requires_one_main_record(self):
        output = "\n".join(
            [
                json.dumps({"rep": 0, "phase_totals": {}}),
                json.dumps(record()),
            ]
        )
        parsed = MODULE.parse_gpu_bench_output(
            output,
            25_000,
            MODULE.BackendSpec("rust-simd", "simd", "legacy"),
            Path("/tmp/compiled.json"),
            2,
        )
        self.assertEqual(parsed["cycles"], 175_016)
        with self.assertRaisesRegex(ValueError, "exactly one"):
            MODULE.parse_gpu_bench_output(
                output + "\n" + json.dumps(record()),
                25_000,
                MODULE.BackendSpec("rust-simd", "simd", "legacy"),
                Path("/tmp/compiled.json"),
                2,
            )

    def test_collect_report_supports_named_backends_and_outer_repetitions(self):
        specs = [
            MODULE.BackendSpec("legacy-simd", "simd", "legacy"),
            MODULE.BackendSpec("native-simd", "simd", "gpu-native"),
            MODULE.BackendSpec("metal", "metal", "legacy"),
        ]
        calls = []

        def runner(binary, compiled, fib_n, spec, proofs_per_process, timeout_s, environment):
            calls.append((fib_n, spec.name))
            value = record(
                fib_n=fib_n,
                backend=spec.backend,
                engine=spec.engine,
                program=str(compiled),
            )
            return sample_from_record(value, spec)

        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "gpu_bench"
            compiled = Path(directory) / "compiled.json"
            binary.write_bytes(b"binary")
            compiled.write_text("{}")
            report = MODULE.collect_report(
                binary=binary,
                compiled_json=compiled,
                sizes=[25_000, 50_000],
                backends=specs,
                proofs_per_process=2,
                warmups=1,
                repeats=2,
                timeout_s=1,
                pause_s=0,
                environment={"RAYON_NUM_THREADS": "16"},
                sample_runner=runner,
            )

        self.assertEqual(len(calls), 18)
        self.assertEqual(report["status"], "completed")
        self.assertEqual(
            set(report["rows"][0]["backends"]),
            {"legacy-simd", "native-simd", "metal"},
        )
        self.assertEqual(
            report["rows"][0]["backends"]["legacy-simd"]["summary"]["samples"],
            2,
        )
        self.assertEqual(report["backends"]["metal"]["acceleration"], "apple_metal_gpu")
        self.assertFalse(report["measurement"]["internal_total"]["directly_timed"])
        self.assertEqual(report["schema_version"], 2)

    def test_collect_report_fails_closed_on_cross_backend_geometry_mismatch(self):
        specs = [
            MODULE.BackendSpec("a", "simd", "legacy"),
            MODULE.BackendSpec("b", "simd", "gpu-native"),
        ]

        def runner(binary, compiled, fib_n, spec, proofs_per_process, timeout_s, environment):
            value = record(
                fib_n=fib_n,
                engine=spec.engine,
                proof_kb=1000.0 if spec.name == "a" else 1001.0,
                program=str(compiled),
            )
            return sample_from_record(value, spec)

        with self.assertRaisesRegex(RuntimeError, "geometry mismatch"):
            MODULE.collect_report(
                binary=Path("/gpu_bench"),
                compiled_json=Path("/compiled.json"),
                sizes=[25_000],
                backends=specs,
                proofs_per_process=2,
                warmups=0,
                repeats=1,
                timeout_s=1,
                pause_s=0,
                environment={},
                sample_runner=runner,
            )


if __name__ == "__main__":
    unittest.main()
