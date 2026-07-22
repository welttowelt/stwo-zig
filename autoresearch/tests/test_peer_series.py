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


PROCESS_RESOURCES = {
    "source": "darwin_usr_bin_time_l_v1",
    "peak_rss_bytes": 1024,
    "peak_memory_footprint_bytes": 2048,
    "energy_nj": None,
    "instructions": 100,
    "cycles": 200,
    "allocation_failure": False,
}


def abba_round(peer="peer_cpu", candidate="zig_cpu", peer_ms=10.0, candidate_ms=7.0):
    order = [peer, candidate, candidate, peer]
    values = [peer_ms, candidate_ms, candidate_ms, peer_ms]
    return {
        "round": 0,
        "order": order,
        "samples": [
            {
                "lane": lane,
                "verified_request_ms": value,
                "cold_process_ms": value + 1,
                "verified": True,
                "warmups_before_sample": 0,
                "abba_half": 1 if position < 2 else 2,
            }
            for position, (lane, value) in enumerate(zip(order, values))
        ],
    }


class PeerSeriesTest(unittest.TestCase):
    def test_abba_order_has_two_independent_opposite_order_halves(self):
        self.assertEqual(
            series.abba_order("cpu"),
            ["peer_cpu", "zig_cpu", "zig_cpu", "peer_cpu"],
        )
        self.assertEqual(
            series.abba_order("metal"),
            ["peer_metal", "zig_metal", "zig_metal", "peer_metal"],
        )

    def test_statistics_gate_uses_round_bootstrap_and_both_halves(self):
        rounds = []
        for round_index in range(series.MIN_ABBA_ROUNDS):
            record = abba_round(peer_ms=10 + round_index / 10, candidate_ms=7 + round_index / 10)
            record["round"] = round_index
            rounds.append(record)
        result = series._statistics(
            rounds, "peer_cpu", "zig_cpu", "verified_request_ms", "fixture",
        )
        self.assertLess(result["candidate_over_peer_median_ratio"], 0.8)
        self.assertLess(result["paired_bootstrap_95_ci"][1], 0.9)
        self.assertTrue(result["both_abba_halves_win"])
        self.assertTrue(result["gate"]["passed"])
        self.assertEqual(result["bootstrap_unit"], "ABBA round")

    def test_peer_sample_includes_input_in_verified_request_and_canonical_proof(self):
        report = {
            "schema": "peer-stwo-wide-fibonacci-adapter-v2",
            "peer_source_commit": series.PEER_COMMIT,
            "backend": "peer-metal",
            "backend_type": "stwo::prover::backend::cpu::CpuBackend",
            "cargo_features": ["parallel", "prover", "metal"],
            "n_columns": 100,
            "log_n_instances": 16,
            "warmups": 10,
            "samples": 1,
            "all_verified": True,
            "all_proofs_identical": True,
            "metal_device_admitted": True,
            "trace_generation_backend": "metal",
            "prove_samples_ms": [9.0],
            "verified_request_samples_ms": [10.0],
            "proof_canonical_sha256": "a" * 64,
            "proof_canonical_bytes": 1234,
            "timing_scope": {"total": "input + prove + encoding + hash + verify"},
            "security_bits": 13,
            "fri_queries": 3,
            "pow_bits": 10,
            "log_blowup_factor": 1,
            "log_last_layer_degree_bound": 0,
            "fold_step": 1,
        }

        def write_report(command, _cwd):
            Path(command[-1]).write_text(json.dumps(report))
            return "", 11.0, PROCESS_RESOURCES

        with tempfile.TemporaryDirectory() as raw:
            with mock.patch.object(series, "run_measured", side_effect=write_report):
                measured = series._one_peer(
                    Path("."), Path("peer-metal"), "peer_metal", 16, 10,
                    Path(raw), "fixture",
                )
        self.assertEqual(measured["protocol"]["security_bits"], 13)
        self.assertEqual(measured["proof_identity"]["scheme"], "sha256(serde_json(StarkProof))")
        self.assertEqual(measured["verified_request_ms"], 10.0)
        self.assertEqual(measured["process_resources"]["peak_rss_bytes"], 1024)

    def test_log22_zig_lane_uses_extreme_profile_and_requires_zero_fallback(self):
        cells = (1 << 22) * 100
        report = {
            "workload": {
                "name": "wide_fibonacci",
                "parameters": {"log_n_rows": 22, "sequence_len": 100},
            },
            "protocol": {
                "name": "functional",
                "pow_bits": 10,
                "log_blowup_factor": 1,
                "log_last_layer_degree_bound": 0,
                "n_queries": 3,
                "fold_step": 1,
            },
            "proof": {
                "verified_samples": 1,
                "all_samples_byte_identical": True,
                "samples": [{"sha256": "d" * 64, "bytes": 123}],
            },
            "resource_admission": {
                "profile": "extreme",
                "committed_cells": cells,
                "accounted_bytes": cells * 16,
                "accounted_bytes_per_committed_cell": 16,
            },
            "resources": {"complete": True},
            "runtime_admission": {"origin": "diagnostic_source_jit"},
            "backend_telemetry": {
                "total_cpu_fallbacks": 0,
                "valid": True,
                "samples": [{"metal_dispatches": 12, "cpu_fallbacks": 0}],
            },
            "timing": {
                "samples": [{
                    "prove_seconds": 0.4,
                    "request_seconds": 0.5,
                    "trace_row_mhz": 10.0,
                    "committed_mcells_per_second": 20.0,
                }],
            },
        }
        with mock.patch.object(
            series, "run_measured", return_value=(json.dumps(report), 501.0, PROCESS_RESOURCES),
        ) as run_mock:
            measured = series._one_zig(
                Path("."), Path("zig-metal"), "zig_metal", 22, 10,
            )
        command = run_mock.call_args.args[0]
        self.assertEqual(command[:4], ["zig-metal", "bench", "--metal-runtime", "source-jit"])
        self.assertEqual(command[-2:], ["--resource-profile", "extreme"])
        self.assertEqual(measured["resource_admission"]["accounted_bytes"], 6_710_886_400)
        self.assertEqual(measured["metal_cpu_fallbacks"], 0)
        self.assertEqual(measured["metal_dispatches"], 12)
        self.assertIsNone(measured["metal_synchronization_points"])

    def test_missing_extreme_resource_profile_is_actionable(self):
        result = mock.Mock(
            returncode=0,
            stdout="Usage: native-proof-bench --resource-profile standard or large",
            stderr="",
        )
        with mock.patch.object(series.subprocess, "run", return_value=result):
            with self.assertRaisesRegex(series.SeriesError, "large and extreme"):
                series.assert_resource_profiles(Path("."), Path("zig-cpu"))

    def test_proof_receipt_fails_closed_on_cpu_metal_mismatch(self):
        protocol = "p" * 64
        statement = "s" * 64

        def sample(lane, digest):
            return {
                "lane": lane,
                "proof_identity": {"digest": digest},
                "protocol_sha256": protocol,
                "statement_sha256": statement,
                "verified": True,
                "metal_cpu_fallbacks": 0 if lane == "zig_metal" else None,
                "metal_synchronization_points": None,
            }

        comparisons = {
            "cpu": {
                boundary: {"rounds": [{"samples": [sample("peer_cpu", "a"), sample("zig_cpu", "b")]}]}
                for boundary in series.BOUNDARIES
            },
            "metal": {
                boundary: {"rounds": [{"samples": [sample("peer_metal", "c"), sample("zig_metal", "b")]}]}
                for boundary in series.BOUNDARIES
            },
        }
        with self.assertRaisesRegex(series.SeriesError, "equivalence"):
            series._proof_receipt(comparisons)

    def test_point_validation_requires_log22_and_two_boundaries(self):
        def boundary(comparison, name):
            peer, candidate = series.COMPARISONS[comparison]
            rounds = []
            for round_index in range(series.MIN_ABBA_ROUNDS):
                record = abba_round(peer, candidate)
                record["round"] = round_index
                if name == "verified_request":
                    for item in record["samples"]:
                        item["warmups_before_sample"] = series.VERIFIED_WARMUPS
                rounds.append(record)
            return {"rounds": rounds}

        point = {
            "schema": series.SCHEMA,
            "series_id": series.SERIES_ID,
            "peer_source": {
                "repository": series.PEER_REPOSITORY,
                "commit": series.PEER_COMMIT,
            },
            "measurement_contract": {
                "abba_rounds": series.MIN_ABBA_ROUNDS,
                "verified_warmups": series.VERIFIED_WARMUPS,
            },
            "sizes": [
                {
                    "log_n_rows": log_size,
                    "n_columns": 100,
                    "comparisons": {
                        comparison: {
                            name: boundary(comparison, name) for name in series.BOUNDARIES
                        }
                        for comparison in series.COMPARISONS
                    },
                    "proof_equivalence": {
                        "all_samples_stable": True,
                        "peer_cpu_equals_peer_metal": True,
                        "zig_cpu_equals_zig_metal": True,
                        "peer_protocol_equals_zig_protocol": True,
                        "all_samples_verified": True,
                        "zig_metal_zero_cpu_fallbacks": True,
                    },
                }
                for log_size in series.LOG_SIZES
            ],
        }
        series.validate_point(point)
        incomplete = copy.deepcopy(point)
        incomplete["sizes"].pop()
        with self.assertRaisesRegex(series.SeriesError, "14,16,18,20,22"):
            series.validate_point(incomplete)
        missing_boundary = copy.deepcopy(point)
        del missing_boundary["sizes"][0]["comparisons"]["cpu"]["cold_process"]
        with self.assertRaisesRegex(series.SeriesError, "timing-boundary"):
            series.validate_point(missing_boundary)

    def test_immutable_writer_rejects_replacement(self):
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "point.json"
            series.write_immutable(path, {"value": 1})
            series.write_immutable(path, {"value": 1})
            with self.assertRaisesRegex(series.SeriesError, "immutable"):
                series.write_immutable(path, {"value": 2})


if __name__ == "__main__":
    unittest.main()
