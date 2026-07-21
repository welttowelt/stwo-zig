import copy
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "reference" / "measure_peer_series.py"
SPEC = importlib.util.spec_from_file_location("measure_peer_series", SCRIPT)
assert SPEC and SPEC.loader
series = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(series)


def sample(lane, request_ms, prove_ms, digest):
    return {
        "lane": lane,
        "reported_prove_ms": prove_ms,
        "verified_request_ms": request_ms,
        "process_wall_ms": request_ms + 2,
        "proof_identity": {"scheme": "fixture", "digest": digest, "bytes_hashed": 10},
        "verified": True,
        "timing_scope": {"total": "fixture"},
    }


class PeerSeriesTest(unittest.TestCase):
    def test_interleave_rotation_balances_every_position(self):
        orders = [series.interleave_order(0, round_index) for round_index in range(4)]
        for lane in series.LANES:
            self.assertEqual(sorted(order.index(lane) for order in orders), [0, 1, 2, 3])

    def test_summary_computes_peer_ratios_and_pairwise_proof_receipt(self):
        samples = []
        for round_index in range(3):
            samples.extend([
                sample("peer_cpu", 10 + round_index, 9, "a" * 64),
                sample("peer_metal", 8 + round_index, 7, "a" * 64),
                sample("zig_cpu", 20 + round_index, 18, "b" * 64),
                sample("zig_metal", 12 + round_index, 11, "b" * 64),
            ])
        summary = series.summarize_size(14, samples)
        self.assertEqual(
            summary["ratios"]["zig_cpu_over_peer_cpu_verified_request"],
            21 / 11,
        )
        self.assertEqual(
            summary["ratios"]["zig_metal_over_peer_metal_verified_request"],
            13 / 9,
        )
        receipt = summary["proof_equivalence"]
        self.assertTrue(receipt["peer_cpu_equals_peer_metal"])
        self.assertTrue(receipt["zig_cpu_equals_zig_metal"])
        self.assertFalse(receipt["cross_implementation_byte_equality_claimed"])

    def test_proof_mismatch_fails_closed(self):
        samples = [
            sample("peer_cpu", 1, 1, "a" * 64),
            sample("peer_metal", 1, 1, "c" * 64),
            sample("zig_cpu", 1, 1, "b" * 64),
            sample("zig_metal", 1, 1, "b" * 64),
        ]
        with self.assertRaisesRegex(series.SeriesError, "proof equivalence"):
            series.summarize_size(14, samples)

    def test_peer_sample_retains_concrete_protocol_and_backend_receipt(self):
        report = {
            "schema": "peer-stwo-wide-fibonacci-adapter-v1",
            "peer_source_commit": series.PEER_COMMIT,
            "backend": "peer-metal",
            "backend_type": "stwo::prover::backend::cpu::CpuBackend",
            "cargo_features": ["parallel", "prover", "metal"],
            "n_columns": 100,
            "log_n_instances": 14,
            "all_verified": True,
            "all_proofs_identical": True,
            "metal_device_admitted": True,
            "prove_samples_ms": [9.0],
            "total_samples_ms": [10.0],
            "proof_debug_sha256": "a" * 64,
            "proof_debug_bytes": 1234,
            "timing_scope": {"total": "prove + verify"},
            "trace_generation_backend": "cpu-parallel",
            "security_bits": 13,
            "fri_queries": 3,
            "pow_bits": 10,
            "commitments": 4,
            "proof_size_bytes": 5678,
        }

        def write_report(command, _cwd):
            Path(command[-1]).write_text(json.dumps(report))
            return "", 11.0

        with tempfile.TemporaryDirectory() as raw:
            with mock.patch.object(series, "run", side_effect=write_report):
                measured = series._one_peer(
                    Path("."), Path("peer-metal"), "peer_metal", 14, 1, Path(raw)
                )
        self.assertEqual(measured["protocol"]["security_bits"], 13)
        self.assertEqual(measured["protocol"]["pcs_config"], "PcsConfig::default()")
        self.assertTrue(measured["metal_device_admitted"])

    def test_large_zig_lane_uses_large_profile_and_requires_zero_fallback(self):
        report = {
            "workload": {
                "name": "wide_fibonacci",
                "parameters": {"log_n_rows": 20, "sequence_len": 100},
            },
            "protocol": {"name": "functional"},
            "proof": {
                "verified_samples": 1,
                "all_samples_byte_identical": True,
                "samples": [{"sha256": "d" * 64, "bytes": 123}],
            },
            "runtime_admission": {"origin": "diagnostic_source_jit"},
            "backend_telemetry": {"total_cpu_fallbacks": 0, "valid": True},
            "timing": {"samples": [{"prove_seconds": 0.4, "request_seconds": 0.5}]},
        }
        with mock.patch.object(series, "run", return_value=(json.dumps(report), 501.0)) as run_mock:
            measured = series._one_zig(Path("."), Path("zig-metal"), "zig_metal", 20, 1)
        command = run_mock.call_args.args[0]
        self.assertEqual(
            command[:4],
            ["zig-metal", "bench", "--metal-runtime", "source-jit"],
        )
        self.assertEqual(command[-2:], ["--resource-profile", "large"])
        self.assertEqual(measured["resource_profile"], "large")
        self.assertEqual(
            measured["metal_runtime"]["origin"], "diagnostic_source_jit",
        )

    def test_missing_large_resource_profile_has_an_actionable_blocker(self):
        result = mock.Mock(returncode=0, stdout="Usage: native-proof-bench", stderr="")
        with mock.patch.object(series.subprocess, "run", return_value=result):
            with self.assertRaisesRegex(series.SeriesError, "Issue #44 W1"):
                series.assert_large_resource_profile(Path("."), Path("zig-cpu"))

    def test_point_validation_requires_the_complete_size_vector(self):
        point = {
            "schema": series.SCHEMA,
            "series_id": series.SERIES_ID,
            "peer_source": {
                "repository": series.PEER_REPOSITORY,
                "commit": series.PEER_COMMIT,
            },
            "sizes": [
                {
                    "log_n_rows": log_size,
                    "n_columns": 100,
                    "medians": {lane: {} for lane in series.LANES},
                    "proof_equivalence": {
                        "all_samples_stable": True,
                        "peer_cpu_equals_peer_metal": True,
                        "zig_cpu_equals_zig_metal": True,
                        "all_samples_verified": True,
                    },
                }
                for log_size in series.LOG_SIZES
            ],
        }
        series.validate_point(point)
        incomplete = copy.deepcopy(point)
        incomplete["sizes"].pop()
        with self.assertRaisesRegex(series.SeriesError, "exact log sizes"):
            series.validate_point(incomplete)

    def test_immutable_writer_rejects_replacement(self):
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "point.json"
            series.write_immutable(path, {"value": 1})
            series.write_immutable(path, {"value": 1})
            with self.assertRaisesRegex(series.SeriesError, "immutable"):
                series.write_immutable(path, {"value": 2})


if __name__ == "__main__":
    unittest.main()
