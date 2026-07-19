from __future__ import annotations

import copy
import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts.architecture_host_gate_lib import aggregate_parity as check_aggregate_parity
from scripts.architecture_host_gate_lib import link_closure as check_architecture_link_closure
from scripts.product_identity_lib import canonical_identity_sha256


def proof() -> dict[str, object]:
    value = {field: None for field in check_aggregate_parity.ARTIFACT_FIELDS}
    value.update({
        "schema_version": 1,
        "exchange_mode": "proof_exchange_json_wire_v1",
        "generator": "zig",
        "example": "wide_fibonacci",
        "prove_mode": "prove",
        "upstream_commit": "1" * 40,
        "proof_bytes_hex": "00",
    })
    return value


def identity(name: str) -> dict[str, object]:
    frontend = "aggregate" if name == "stwo-zig" else "native-examples"
    protocol = (
        "aggregate-compat-v1+cpu"
        if name == "stwo-zig" else "native-examples-v1+lifted-pcs-v1"
    )
    value = {
        "schema_version": 2,
        "name": name,
        "frontend": frontend,
        "backend": "cpu",
        "role": "cli",
        "protocol_features": protocol,
        "protocol_manifest_sha256": hashlib.sha256(protocol.encode()).hexdigest(),
        "identity_sha256": "0" * 64,
        "implementation_repository": "https://github.com/teddyjfpender/stwo-zig",
        "implementation_commit": "2" * 40,
        "implementation_tree": "3" * 40,
        "implementation_dirty": False,
        "dirty_content_sha256": None,
        "zig_version": "0.15.2",
        "target_arch": "aarch64",
        "target_os": "macos",
        "target_abi": "none",
        "cpu_model": "apple_m1",
        "cpu_features_sha256": "4" * 64,
        "optimize": "ReleaseFast",
        "runtime_manifest": "none",
        "sdk_manifest": "none",
        "aot_manifest": "none",
    }
    value["identity_sha256"] = canonical_identity_sha256(value)
    return value


def report(product: str, proof_digest: str) -> dict[str, object]:
    return {
        "schema_version": 6,
        "product_identity": identity(product),
        "backend": "cpu_native",
        "evidence_class": "profiled_diagnostic",
        "profiled": True,
        "provenance": {"optimization": "ReleaseFast", "complete": True},
        "protocol": {"name": "smoke", "n_queries": 1},
        "workload": {
            "name": "wide_fibonacci", "parameters": {"log_n_rows": 8, "sequence_len": 8},
        },
        "session": {"max_circle_log": 9},
        "runtime_admission": None,
        "proof": {
            "samples": [{"bytes": 1, "sha256": proof_digest}],
            "verified_samples": 1,
            "all_samples_byte_identical": True,
            "artifact": {"path": "/tmp/proof.json", "sha256": proof_digest},
        },
        "backend_telemetry": None,
        "timing": {
            "stage_profiles": [{
                "schema_version": 1,
                "runtime": "ReleaseFast",
                "example": "wide_fibonacci",
                "stages": [{
                    "id": "main_trace_commit", "label": "Main trace commit",
                    "seconds": 0.1, "children": None,
                }],
            }],
        },
        "throughput": {"diagnostic_native_mhz": 1.0},
    }


def verify(product: str, artifact: dict[str, object], proof_digest: str) -> dict[str, object]:
    return {
        "schema_version": 1,
        "status": "verified",
        "product": identity(product),
        "artifact_schema_version": 1,
        "upstream_commit": artifact["upstream_commit"],
        "exchange_mode": artifact["exchange_mode"],
        "security_policy": "smoke",
        "claimed_generator": artifact["generator"],
        "air": artifact["example"],
        "proof_bytes": 1,
        "proof_sha256": proof_digest,
    }


class AggregateParityTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.artifact = proof()
        self.proof_digest = hashlib.sha256(b"\x00").hexdigest()
        self.paths = {
            "focused_path": self.root / "focused.json",
            "aggregate_path": self.root / "aggregate.json",
            "focused_report_path": self.root / "focused-report.json",
            "aggregate_report_path": self.root / "aggregate-report.json",
            "focused_verify_path": self.root / "focused-verify.json",
            "aggregate_verify_path": self.root / "aggregate-verify.json",
        }
        self.documents = {
            "focused_path": self.artifact,
            "aggregate_path": copy.deepcopy(self.artifact),
            "focused_report_path": report("stwo-native-cpu", self.proof_digest),
            "aggregate_report_path": report("stwo-zig", self.proof_digest),
            "focused_verify_path": verify("stwo-native-cpu", self.artifact, self.proof_digest),
            "aggregate_verify_path": verify("stwo-zig", self.artifact, self.proof_digest),
        }
        self._write()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _write(self) -> None:
        for name, value in self.documents.items():
            self.paths[name].write_text(json.dumps(value, sort_keys=True), encoding="utf-8")

    def _rejects(self, path_name: str, mutate) -> None:
        mutate(self.documents[path_name])
        self._write()
        with self.assertRaises(check_aggregate_parity.ParityError):
            check_aggregate_parity.validate(**self.paths)

    def test_accepts_semantic_and_independently_verified_parity(self) -> None:
        receipt = check_aggregate_parity.validate(**self.paths)
        self.assertEqual("PASS", receipt["status"])
        self.assertEqual(receipt["artifacts"]["focused"], receipt["artifacts"]["aggregate"])

    def test_rejects_mismatched_statement(self) -> None:
        self._rejects("aggregate_path", lambda value: value.update(generator="rust"))

    def test_rejects_mismatched_report_workload(self) -> None:
        self._rejects(
            "aggregate_report_path",
            lambda value: value["workload"].update(parameters={"log_n_rows": 9}),
        )

    def test_rejects_mismatched_protocol(self) -> None:
        self._rejects(
            "aggregate_report_path", lambda value: value["protocol"].update(n_queries=2),
        )

    def test_rejects_mismatched_stage_topology(self) -> None:
        self._rejects(
            "aggregate_report_path",
            lambda value: value["timing"]["stage_profiles"][0]["stages"][0].update(id="oods"),
        )

    def test_ignores_stage_duration_noise(self) -> None:
        self.documents["aggregate_report_path"]["timing"]["stage_profiles"][0]["stages"][0]["seconds"] = 9.5
        self._write()
        self.assertEqual("PASS", check_aggregate_parity.validate(**self.paths)["status"])

    def test_rejects_timing_schema_drift(self) -> None:
        self._rejects(
            "aggregate_report_path",
            lambda value: value["timing"].update(warmup_request_seconds=[]),
        )

    def test_rejects_throughput_schema_drift(self) -> None:
        self._rejects(
            "aggregate_report_path",
            lambda value: value["throughput"].update(extra_rate=1.0),
        )

    def test_rejects_forged_verify_receipt(self) -> None:
        self._rejects(
            "aggregate_verify_path",
            lambda value: value.update(proof_sha256="f" * 64),
        )


class LinkClosureTest(unittest.TestCase):
    def test_cpu_and_metal_policies_are_explicit(self) -> None:
        self.assertIn("Metal", check_architecture_link_closure.POLICY["stwo-native-cpu"]["forbidden"])
        self.assertIn("Metal", check_architecture_link_closure.POLICY["stwo-native-metal"]["required"])

    @mock.patch.object(check_architecture_link_closure, "sha256_file", return_value="1" * 64)
    @mock.patch.object(check_architecture_link_closure, "check_dynamic", return_value=[])
    @mock.patch.object(check_architecture_link_closure, "inspect_dynamic")
    def test_report_binds_exact_binary_and_inspector(self, inspect_dynamic, _check, _sha) -> None:
        inspect_dynamic.return_value = mock.Mock(inspector="otool", output="Metal\nFoundation\nlibobjc")
        report_value = check_architecture_link_closure.inspect(
            "stwo-native-metal", Path("metal-bin"), None,
        )
        self.assertEqual("PASS", report_value["status"])
        self.assertEqual("1" * 64, report_value["binary"]["sha256"])


if __name__ == "__main__":
    unittest.main()
