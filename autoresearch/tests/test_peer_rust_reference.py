import importlib.util
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "reference" / "measure_peer_rust.py"
SPEC = importlib.util.spec_from_file_location("measure_peer_rust", SCRIPT)
assert SPEC and SPEC.loader
measure_peer_rust = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(measure_peer_rust)


class PeerRustReferenceTest(unittest.TestCase):
    def _documents(self):
        zig = {
            "binary_sha256": "1" * 64,
            "zig_version": "0.15.2",
            "results": {
                spec["class"]: {
                    "median_ms": 10.0,
                    "proof_sha256": "2" * 64,
                    "all_verified": True,
                }
                for spec in measure_peer_rust.WORKLOADS
            },
        }
        rust = {
            backend: {
                spec["class"]: {
                    "median_ms": 20.0 if backend == "scalar" else 5.0,
                    "samples_ms": [20.0] if backend == "scalar" else [5.0],
                    "proof_metrics": {"proof_wire_bytes": 100},
                }
                for spec in measure_peer_rust.WORKLOADS
            }
            for backend in measure_peer_rust.BACKENDS
        }
        parity = {
            spec["class"]: {
                "proof_sha256": "3" * 64,
                "scalar_equals_simd": True,
                "scalar_verified": True,
                "simd_verified": True,
            }
            for spec in measure_peer_rust.WORKLOADS
        }
        return measure_peer_rust.build_reference_documents(
            measured_at_utc="2026-07-21T00:00:00+00:00",
            host={"processor": "fixture"},
            warmups=1,
            samples=1,
            executable={"sha256": "4" * 64},
            toolchain={"rustc_version": "fixture", "cargo_version": "fixture"},
            zig=zig,
            rust=rust,
            parity=parity,
        )

    def test_scalar_and_simd_are_distinct_honest_backends(self):
        documents = self._documents()
        self.assertEqual(set(documents), {"scalar", "simd"})
        self.assertEqual(
            documents["scalar"]["rust_reference"]["backend_type"],
            "stwo::prover::backend::cpu::CpuBackend",
        )
        self.assertEqual(
            documents["simd"]["rust_reference"]["backend_type"],
            "stwo::prover::backend::simd::SimdBackend",
        )
        self.assertEqual(documents["scalar"]["suite_ratio_geomean_rust_over_zig_original"], 2.0)
        self.assertEqual(documents["simd"]["suite_ratio_geomean_rust_over_zig_original"], 0.5)

    def test_documents_bind_source_toolchain_executable_and_parity(self):
        for document in self._documents().values():
            reference = document["rust_reference"]
            self.assertEqual(reference["source_commit"], measure_peer_rust.RUST_UPSTREAM_COMMIT)
            self.assertEqual(reference["toolchain"], measure_peer_rust.RUST_TOOLCHAIN)
            self.assertEqual(reference["features"], ["parallel", "prover"])
            self.assertEqual(reference["executable"]["sha256"], "4" * 64)
            self.assertTrue(document["proof_equivalence_receipt"]["all_equal"])
            self.assertIn("rust_metric", document["timing_semantics"])
            self.assertEqual(len(document["per_workload"]), 3)


if __name__ == "__main__":
    unittest.main()
