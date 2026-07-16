import importlib.util
import hashlib
import io
import json
from unittest import mock
from pathlib import Path
import re
import struct
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "sn_pie_metal_benchmark.py"
SPEC = importlib.util.spec_from_file_location("sn_pie_metal_benchmark", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class SnPieMetalBenchmarkTest(unittest.TestCase):
    @staticmethod
    def touch_tree0_companion(evaluations: Path) -> Path:
        companion = MODULE.tree0_merkle_companion(evaluations)
        companion.touch()
        return companion

    def test_streams_adapted_cycle_count(self):
        header = bytearray(64)
        header[:8] = b"STWZCPI\0"
        struct.pack_into("<I", header, 8, 1)
        struct.pack_into("<Q", header, 40, 1234)
        struct.pack_into("<I", header, 56, 2)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "input.stwzcpi"
            with path.open("wb") as stream:
                stream.write(header)
                stream.write(struct.pack("<Q", 3))
                stream.write(bytes(3 * 12))
                stream.write(struct.pack("<Q", 5))
                stream.write(bytes(5 * 12))
            self.assertEqual(MODULE.adapted_counts(path), (8, 1234))

    def test_resource_usage_parser(self):
        stderr = "real 1.25\nuser 0.75\nsys 0.10\n  4096 maximum resident set size\n  8192 peak memory footprint\n"
        self.assertEqual(
            MODULE.parse_time(stderr),
            {
                "time_real_s": 1.25,
                "time_user_s": 0.75,
                "time_sys_s": 0.10,
                "max_rss_bytes": 4096,
                "peak_footprint_bytes": 8192,
            },
        )

    def test_atomic_stderr_output_replaces_complete_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "runner.stderr"
            path.write_text("stale")
            MODULE.write_text_atomic(path, "first\nsecond\n")
            self.assertEqual(path.read_text(), "first\nsecond\n")
            self.assertEqual(list(path.parent.glob(f".{path.name}.*")), [])

    def test_benchmark_environment_drops_inherited_sn2_controls(self):
        with mock.patch.dict(
            MODULE.os.environ,
            {
                "PATH": "/bin",
                "STWO_ZIG_SN2_LOG_STAGE_TIMINGS": "1",
                "STWO_ZIG_SN2_REPAIR_COLUMN_613_LDE": "1",
            },
            clear=True,
        ):
            self.assertEqual(MODULE.benchmark_environment(), {"PATH": "/bin"})

    def test_base_eval_diagnostic_requires_explicit_root_mode_flag(self):
        environment = {}
        MODULE.apply_diagnostic_environment(environment, "base-root", False)
        self.assertNotIn("STWO_ZIG_SN2_LOG_BASE_EVAL_DIGESTS", environment)
        MODULE.apply_diagnostic_environment(environment, "base-root", True, "ab" * 32)
        self.assertEqual(environment["STWO_ZIG_SN2_LOG_BASE_EVAL_DIGESTS"], "1")
        self.assertEqual(environment["STWO_ZIG_SN2_INPUT_SHA256"], "ab" * 32)
        with self.assertRaisesRegex(ValueError, "root/proof mode"):
            MODULE.apply_diagnostic_environment({}, "prepare", True, "ab" * 32)

    def test_base_eval_dump_requires_diagnostic_and_complete_pair(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "column.u32le"
            environment = {"STWO_ZIG_SN2_LOG_BASE_EVAL_DIGESTS": "1"}
            MODULE.apply_base_eval_dump_environment(environment, 5080, output)
            self.assertEqual(environment["STWO_ZIG_SN2_DUMP_BASE_EVAL_LOGICAL_ID"], "5080")
            self.assertEqual(environment["STWO_ZIG_SN2_DUMP_BASE_EVAL_PATH"], str(output.resolve()))
            with self.assertRaisesRegex(ValueError, "provided together"):
                MODULE.apply_base_eval_dump_environment(environment, 5080, None)
            with self.assertRaisesRegex(ValueError, "requires"):
                MODULE.apply_base_eval_dump_environment({}, 5080, output)

    def test_parser_accepts_per_pie_protocol_artifacts(self):
        argv = [
            str(SCRIPT),
            "--input",
            "/tmp/pie.stwzcpi",
            "--witness-programs",
            "/tmp/witness.bin",
            "--multiplicity-feeds",
            "/tmp/feeds.bin",
            "--relation-templates",
            "/tmp/relations.bin",
            "--fixed-tables",
            "/tmp/fixed.bin",
            "--composition",
            "/tmp/composition.bin",
        ]
        with mock.patch.object(sys, "argv", argv):
            args = MODULE.parser().parse_args()
        self.assertEqual(args.witness_programs, Path("/tmp/witness.bin"))
        self.assertEqual(args.multiplicity_feeds, Path("/tmp/feeds.bin"))
        self.assertEqual(args.relation_templates, Path("/tmp/relations.bin"))
        self.assertEqual(args.fixed_tables, Path("/tmp/fixed.bin"))
        self.assertEqual(args.composition, Path("/tmp/composition.bin"))

    def test_runner_command_has_exact_protocol_artifact_abi(self):
        argv = [
            str(SCRIPT),
            "--input",
            "/tmp/pie.stwzcpi",
            "--runner",
            "/tmp/runner",
            "--schedule",
            "/tmp/schedule.json",
            "--budget-gib",
            "52",
            "--witness-programs",
            "/tmp/witness.bin",
            "--multiplicity-feeds",
            "/tmp/feeds.bin",
            "--relation-templates",
            "/tmp/relations.bin",
            "--fixed-tables",
            "/tmp/fixed.bin",
            "--composition",
            "/tmp/composition.bin",
        ]
        with mock.patch.object(sys, "argv", argv):
            args = MODULE.parser().parse_args()
        artifacts = MODULE.protocol_artifacts(args)
        self.assertEqual(
            artifacts,
            (
                Path("/tmp/witness.bin"),
                Path("/tmp/feeds.bin"),
                Path("/tmp/relations.bin"),
                Path("/tmp/fixed.bin"),
                Path("/tmp/composition.bin"),
            ),
        )
        command = MODULE.runner_command(args, artifacts)
        self.assertEqual(len(command), 8)
        self.assertEqual(command[3:], [str(path) for path in artifacts])
        self.assertEqual(command[2], "52")

    def test_full_proof_mode_requests_every_gate(self):
        with tempfile.TemporaryDirectory() as directory:
            evaluations = Path(directory) / "preprocessed.spill"
            coefficients = Path(directory) / "preprocessed.stwzppc"
            transcript = Path(directory) / "transcript.json"
            quotient = Path(directory) / "quotient.bin"
            evaluations.touch()
            companion = self.touch_tree0_companion(evaluations)
            coefficients.touch()
            transcript.touch()
            quotient.touch()
            proof_output = Path(directory) / "proof.bin"
            environment = {}
            MODULE.apply_mode_environment(
                environment,
                "full-proof",
                evaluations,
                coefficients,
                "ab" * 32,
                transcript,
                quotient,
                proof_output,
            )
        self.assertEqual(environment["STWO_ZIG_SN2_COMMIT_TREE_COUNT"], "4")
        for name in (
            "STWO_ZIG_SN2_PREPARE_METAL",
            "STWO_ZIG_SN2_EXECUTE_WITNESS",
            "STWO_ZIG_SN2_EXECUTE_RELATIONS",
            "STWO_ZIG_SN2_EXECUTE_COMPOSITION",
            "STWO_ZIG_SN2_EXECUTE_OODS",
            "STWO_ZIG_SN2_EXECUTE_PROOF",
            "STWO_ZIG_SN2_VERIFY_PROOF",
            "STWO_ZIG_SN2_REPLAY_TRANSCRIPT_AFTER_TREE2",
        ):
            self.assertEqual(environment[name], "1")
        self.assertEqual(environment["STWO_ZIG_SN2_PREPROCESSED_COEFFS"], str(coefficients.resolve()))
        self.assertEqual(environment["STWO_ZIG_SN2_TRANSCRIPT_REFERENCE"], str(transcript.resolve()))
        self.assertEqual(environment["STWO_ZIG_SN2_QUOTIENT_REFERENCE"], str(quotient.resolve()))
        self.assertEqual(environment["STWO_ZIG_SN2_PROOF_OUTPUT"], str(proof_output.resolve()))
        self.assertEqual(companion, Path(f"{evaluations}.tree0-merkle"))

    def test_full_proof_accepts_reference_free_execution_without_replay(self):
        with tempfile.TemporaryDirectory() as directory:
            evaluations = Path(directory) / "preprocessed.spill"
            coefficients = Path(directory) / "preprocessed.stwzppc"
            evaluations.touch()
            self.touch_tree0_companion(evaluations)
            coefficients.touch()
            proof_output = Path(directory) / "proof.bin"
            environment = {}
            MODULE.apply_mode_environment(
                environment,
                "full-proof",
                evaluations,
                coefficients,
                "ab" * 32,
                None,
                None,
                proof_output,
            )
        self.assertEqual(environment["STWO_ZIG_SN2_EXECUTE_PROOF"], "1")
        self.assertEqual(environment["STWO_ZIG_SN2_VERIFY_PROOF"], "1")
        self.assertNotIn("STWO_ZIG_SN2_TRANSCRIPT_REFERENCE", environment)
        self.assertNotIn("STWO_ZIG_SN2_QUOTIENT_REFERENCE", environment)
        self.assertNotIn("STWO_ZIG_SN2_REPLAY_TRANSCRIPT_AFTER_TREE2", environment)

    def test_full_proof_rejects_unpaired_reference_artifacts(self):
        with tempfile.TemporaryDirectory() as directory:
            evaluations = Path(directory) / "preprocessed.spill"
            coefficients = Path(directory) / "preprocessed.stwzppc"
            transcript = Path(directory) / "transcript.json"
            evaluations.touch()
            self.touch_tree0_companion(evaluations)
            coefficients.touch()
            transcript.touch()
            with self.assertRaisesRegex(ValueError, "provided together"):
                MODULE.apply_mode_environment(
                    {},
                    "full-proof",
                    evaluations,
                    coefficients,
                    "ab" * 32,
                    transcript,
                    None,
                    Path(directory) / "proof.bin",
                )

    def test_artifact_manifest_measures_all_current_inputs(self):
        names = (
            "input.stwzcpi",
            "runner",
            "schedule.json",
            "witness.bin",
            "feeds.bin",
            "relations.bin",
            "fixed.bin",
            "composition.bin",
            "evaluations.bin",
            "coefficients.bin",
            "transcript.json",
            "quotient.bin",
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = {name: root / name for name in names}
            for index, path in enumerate(paths.values()):
                path.write_bytes(bytes([index]) * (index + 1))
            tree0 = MODULE.tree0_merkle_companion(paths["evaluations.bin"])
            tree0.write_bytes(b"tree0")
            args = mock.Mock(
                input=paths["input.stwzcpi"],
                schedule=paths["schedule.json"],
                preprocessed_evaluations=paths["evaluations.bin"],
                preprocessed_coefficients=paths["coefficients.bin"],
                transcript_reference=paths["transcript.json"],
                quotient_reference=paths["quotient.bin"],
            )
            protocol = tuple(
                paths[name]
                for name in ("witness.bin", "feeds.bin", "relations.bin", "fixed.bin", "composition.bin")
            )
            entries = MODULE.input_artifact_entries(args, protocol)
            manifest = MODULE.artifact_manifest(entries, 1.25, 0.5)
            measured_contents = {
                name: Path(entry["path"]).read_bytes() for name, entry in entries.items()
            }

        self.assertEqual(
            set(entries),
            {
                "adapted_input",
                "schedule",
                "witness_programs",
                "multiplicity_feeds",
                "relation_templates",
                "fixed_tables",
                "composition",
                "preprocessed_evaluations",
                "preprocessed_coefficients",
                "tree0_merkle",
                "transcript_reference",
                "quotient_reference",
            },
        )
        for name, entry in entries.items():
            contents = measured_contents[name]
            self.assertEqual(entry["bytes"], len(contents), name)
            self.assertEqual(entry["sha256"], hashlib.sha256(contents).hexdigest(), name)
            self.assertIn("format_version", entry, name)
            self.assertIn("generator", entry, name)
            self.assertIn("source_digests", entry, name)
            self.assertIn("provenance", entry, name)
        self.assertEqual(entries["schedule"]["provenance"], "proof_derived")
        self.assertEqual(entries["composition"]["provenance"], "proof_derived")
        self.assertEqual(entries["transcript_reference"]["provenance"], "diagnostic_fixture")
        expected_manifest_digest = hashlib.sha256(
            json.dumps(entries, sort_keys=True, separators=(",", ":")).encode("utf-8")
        ).hexdigest()
        self.assertEqual(manifest["sha256"], expected_manifest_digest)
        self.assertEqual(manifest["hash_timing"]["total_wall_s"], 1.75)
        self.assertTrue(manifest["hash_timing"]["prove_wall_s_excludes_hashing"])

    def test_proof_manifest_entry_identifies_runner_and_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            proof = Path(directory) / "proof.bin"
            proof.write_bytes(b"verified proof")
            source_entries = {
                "adapted_input": {"sha256": "11" * 32},
                "schedule": {"sha256": "22" * 32},
            }
            entry = MODULE.proof_artifact_entry(
                proof,
                "ab" * 32,
                ["/runner", "schedule", "29"],
                source_entries,
                {"runner_version": "v1", "compiler_identity": "zig-test"},
            )
        self.assertEqual(entry["bytes"], len(b"verified proof"))
        self.assertEqual(entry["provenance"], "canonical_generated")
        self.assertEqual(entry["generator"]["executable_sha256"], "ab" * 32)
        self.assertEqual(entry["generator"]["arguments"], ["schedule", "29"])
        self.assertEqual(entry["source_digests"], ["11" * 32, "22" * 32])
        self.assertFalse(entry["source_chain_complete"])

    def test_full_proof_refuses_preexisting_proof_output(self):
        with tempfile.TemporaryDirectory() as directory:
            evaluations = Path(directory) / "preprocessed.spill"
            coefficients = Path(directory) / "preprocessed.stwzppc"
            proof_output = Path(directory) / "proof.bin"
            evaluations.touch()
            self.touch_tree0_companion(evaluations)
            coefficients.touch()
            proof_output.write_bytes(b"stale")
            with self.assertRaisesRegex(ValueError, "already exists"):
                MODULE.apply_mode_environment(
                    {},
                    "full-proof",
                    evaluations,
                    coefficients,
                    "ab" * 32,
                    None,
                    None,
                    proof_output,
                )

    def test_authoritative_provenance_is_fail_closed(self):
        entries = {
            "schedule": {"provenance": "proof_derived"},
            "proof": {"provenance": "canonical_generated"},
        }
        explicit = MODULE.authoritative_provenance(
            "full-proof",
            "completed",
            {"proof_verified": True},
            {
                "self_contained": True,
                "statement_self_derived": True,
                "parity_fixture_used": False,
                "proof_derived_artifact_used": False,
            },
            entries,
            None,
            None,
        )
        self.assertFalse(explicit["self_contained"])
        self.assertFalse(explicit["parity_fixture_used"])
        self.assertTrue(explicit["proof_derived_artifact_used"])

        missing_runner_evidence = MODULE.authoritative_provenance(
            "full-proof",
            "completed",
            {"proof_verified": True},
            {},
            {"proof": {"provenance": "canonical_generated"}},
            None,
            None,
        )
        self.assertFalse(missing_runner_evidence["self_contained"])
        self.assertTrue(missing_runner_evidence["parity_fixture_used"])
        self.assertTrue(missing_runner_evidence["proof_derived_artifact_used"])

        fixture_argument = MODULE.authoritative_provenance(
            "full-proof",
            "completed",
            {"proof_verified": True},
            {"parity_fixture_used": False, "proof_derived_artifact_used": False},
            {"proof": {"provenance": "canonical_generated"}},
            Path("transcript.json"),
            Path("quotient.bin"),
        )
        self.assertTrue(fixture_argument["parity_fixture_used"])

    def test_pow_telemetry_separates_self_ground_and_fixture_costs(self):
        report = MODULE.pow_telemetry({
            "pow_timing_scope": "cpu_nonce_search_or_fixture_validation_only",
            "interaction_pow_nonce": 11,
            "interaction_pow_wall_s": 0.25,
            "interaction_pow_mode": "self_ground",
            "interaction_pow_bits": 24,
            "interaction_pow_invocations": 1,
            "query_pow_nonce": 12,
            "query_pow_wall_s": 0.01,
            "query_pow_mode": "fixture_forced",
            "query_pow_bits": 26,
            "query_pow_invocations": 1,
        })
        self.assertTrue(report["complete"])
        self.assertEqual(report["interaction"]["mode"], "self_ground")
        self.assertEqual(report["query"]["mode"], "fixture_forced")

        malformed = MODULE.pow_telemetry({
            "pow_timing_scope": "cpu_nonce_search_or_fixture_validation_only",
            "interaction_pow_nonce": 11,
            "interaction_pow_wall_s": 0.25,
            "interaction_pow_mode": "mixed",
            "interaction_pow_bits": 24,
            "interaction_pow_invocations": 2,
        })
        self.assertFalse(malformed["complete"])

    def test_canonical_protocol_evidence_rejects_shape_type_and_value_drift(self):
        canonical = {
            "protocol": dict(MODULE.CANONICAL_PROOF_PROTOCOL),
            "protocol_complete": True,
        }
        protocol, complete = MODULE.canonical_protocol_evidence(canonical)
        self.assertEqual(protocol, MODULE.CANONICAL_PROOF_PROTOCOL)
        self.assertTrue(complete)
        self.assertEqual(
            MODULE.protocol_gate("completed", canonical),
            ("completed", MODULE.CANONICAL_PROOF_PROTOCOL, True),
        )
        self.assertEqual(
            MODULE.protocol_gate("completed", None),
            ("invalid_protocol", None, False),
        )

        invalid = []
        for name, replacement in (
            ("extra", 0),
            ("channel_salt", False),
            ("n_queries", 70.0),
            ("query_pow_bits", 25),
            ("fri_lifting", 0),
        ):
            document = {
                "protocol": dict(MODULE.CANONICAL_PROOF_PROTOCOL),
                "protocol_complete": True,
            }
            document["protocol"][name] = replacement
            invalid.append(document)
        missing = {
            "protocol": dict(MODULE.CANONICAL_PROOF_PROTOCOL),
            "protocol_complete": True,
        }
        del missing["protocol"]["channel"]
        invalid.extend((missing, {"protocol": canonical["protocol"]}, None))
        for document in invalid:
            with self.subTest(document=document):
                self.assertEqual(
                    MODULE.canonical_protocol_evidence(document),
                    (None, False),
                )

    def test_main_emits_reference_free_fail_closed_manifest_report(self):
        header = bytearray(64)
        header[:8] = b"STWZCPI\0"
        struct.pack_into("<I", header, 8, 1)
        struct.pack_into("<Q", header, 40, 7)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            input_path = root / "input.stwzcpi"
            runner = root / "runner"
            schedule = root / "schedule.json"
            evaluations = root / "evaluations.bin"
            coefficients = root / "coefficients.bin"
            proof = root / "proof.bin"
            output = root / "report.json"
            input_path.write_bytes(header)
            runner.write_bytes(b"runner")
            schedule.write_bytes(b"{}")
            evaluations.write_bytes(b"eval")
            coefficients.write_bytes(b"coeff")
            self.touch_tree0_companion(evaluations).write_bytes(b"tree")
            protocol = []
            for name in ("witness", "feeds", "relations", "fixed", "composition"):
                path = root / f"{name}.bin"
                path.write_bytes(name.encode("ascii"))
                protocol.append(path)
            composition_source = protocol[4].with_suffix(".metal")
            composition_source.write_text("kernel void generated_air() {}")
            argv = [
                str(SCRIPT),
                "--input",
                str(input_path),
                "--mode",
                "full-proof",
                "--runner",
                str(runner),
                "--schedule",
                str(schedule),
                "--witness-programs",
                str(protocol[0]),
                "--multiplicity-feeds",
                str(protocol[1]),
                "--relation-templates",
                str(protocol[2]),
                "--fixed-tables",
                str(protocol[3]),
                "--composition",
                str(protocol[4]),
                "--preprocessed-evaluations",
                str(evaluations),
                "--preprocessed-coefficients",
                str(coefficients),
                "--tree0-root-hex",
                "ab" * 32,
                "--proof-output",
                str(proof),
                "--output",
                str(output),
            ]

            def completed_gate(command, environment, timeout):
                del command, timeout
                self.assertNotIn("STWO_ZIG_SN2_TRANSCRIPT_REFERENCE", environment)
                self.assertNotIn("STWO_ZIG_SN2_QUOTIENT_REFERENCE", environment)
                self.assertNotIn("STWO_ZIG_SN2_REPLAY_TRANSCRIPT_AFTER_TREE2", environment)
                self.assertEqual(
                    environment["STWO_ZIG_SN2_COMPOSITION_SOURCE"],
                    str(composition_source.resolve()),
                )
                proof.write_bytes(b"proof")
                cli = {
                    "proof_verified": True,
                    "prove_wall_s": 2.0,
                    "prove_timing_scope": MODULE.PROVE_TIMING_SCOPE,
                    "protocol": dict(MODULE.CANONICAL_PROOF_PROTOCOL),
                    "protocol_complete": True,
                    "self_contained": False,
                    "statement_self_derived": True,
                    "parity_fixture_used": False,
                    "proof_derived_artifact_used": True,
                }
                return "completed", 0, 3.0, json.dumps(cli), "real 3.0\n"

            stdout = io.StringIO()
            with (
                mock.patch.object(sys, "argv", argv),
                mock.patch.object(MODULE, "run_gate", side_effect=completed_gate),
                mock.patch.object(MODULE, "hardware", return_value={}),
                mock.patch.object(sys, "stdout", stdout),
            ):
                self.assertEqual(MODULE.main(), 0)
            report = json.loads(output.read_text())

        self.assertEqual(json.loads(stdout.getvalue()), report)
        self.assertEqual(report["schema_version"], 3)
        self.assertFalse(report["self_contained"])
        self.assertFalse(report["parity_fixture_used"])
        self.assertTrue(report["proof_derived_artifact_used"])
        self.assertTrue(report["proof_verified"])
        self.assertEqual(report["protocol"], MODULE.CANONICAL_PROOF_PROTOCOL)
        self.assertTrue(report["protocol_complete"])
        self.assertIn("proof", report["artifact_manifest"]["entries"])
        self.assertIn("composition_source", report["artifact_manifest"]["entries"])
        self.assertEqual(report["artifact_manifest"]["entries"]["proof"]["bytes"], 5)
        self.assertTrue(
            report["artifact_manifest"]["hash_timing"]["runner_process_wall_s_excludes_hashing"]
        )

    def test_root_mode_requires_retained_tree_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            evaluations = Path(directory) / "preprocessed.spill"
            evaluations.touch()
            expected = Path(f"{evaluations}.tree0-merkle")
            with self.assertRaisesRegex(ValueError, re.escape(str(expected))):
                MODULE.apply_mode_environment(
                    {},
                    "base-root",
                    evaluations,
                    None,
                    "ab" * 32,
                    None,
                    None,
                    None,
                )

    def test_missing_retained_tree_cache_does_not_launch_runner(self):
        header = bytearray(64)
        header[:8] = b"STWZCPI\0"
        struct.pack_into("<I", header, 8, 1)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            input_path = root / "input.stwzcpi"
            input_path.write_bytes(header)
            runner = root / "runner"
            schedule = root / "schedule.json"
            artifact = root / "artifact.bin"
            evaluations = root / "preprocessed.spill"
            output = root / "benchmark.json"
            for path in (runner, schedule, artifact, evaluations):
                path.touch()
            argv = [
                str(SCRIPT),
                "--input",
                str(input_path),
                "--mode",
                "base-root",
                "--runner",
                str(runner),
                "--schedule",
                str(schedule),
                "--preprocessed-evaluations",
                str(evaluations),
                "--tree0-root-hex",
                "ab" * 32,
                "--output",
                str(output),
            ]
            with (
                mock.patch.object(sys, "argv", argv),
                mock.patch.object(MODULE, "DEFAULT_ARTIFACTS", (artifact,) * 5),
                mock.patch.object(MODULE, "run_gate") as run_gate,
            ):
                with self.assertRaisesRegex(SystemExit, r"\.tree0\-merkle"):
                    MODULE.main()
                run_gate.assert_not_called()
                self.assertFalse(output.exists())

    def test_mhz_requires_full_verified_proof_and_prover_wall_time(self):
        partial = MODULE.verified_metrics(
            "interaction-root",
            "completed",
            {"proof_verified": True, "prove_wall_s": 2.0, "commitment_gpu_ms": 1.0},
            8_000_000,
            4.0,
        )
        self.assertFalse(partial["proof_verified"])
        self.assertFalse(partial["proving_speed_verified"])
        self.assertIsNone(partial["prove_mhz"])
        self.assertIsNone(partial["cold_process_mhz"])

        missing_wall = MODULE.verified_metrics(
            "full-proof",
            "completed",
            {"proof_verified": True, "commitment_gpu_ms": 1.0},
            8_000_000,
            4.0,
        )
        self.assertTrue(missing_wall["proof_verified"])
        self.assertFalse(missing_wall["proving_speed_verified"])
        self.assertIsNone(missing_wall["prove_mhz"])
        self.assertEqual(missing_wall["cold_process_mhz"], 2.0)

        wrong_scope = MODULE.verified_metrics(
            "full-proof",
            "completed",
            {"proof_verified": True, "prove_wall_s": 2.0, "prove_timing_scope": "gpu_kernel_sum"},
            8_000_000,
            4.0,
        )
        self.assertFalse(wrong_scope["proving_speed_verified"])
        self.assertIsNone(wrong_scope["prove_mhz"])

        non_finite = MODULE.verified_metrics(
            "full-proof",
            "completed",
            {
                "proof_verified": True,
                "prove_wall_s": float("inf"),
                "prove_timing_scope": MODULE.PROVE_TIMING_SCOPE,
            },
            8_000_000,
            4.0,
        )
        self.assertFalse(non_finite["proving_speed_verified"])
        self.assertIsNone(non_finite["prove_mhz"])

        verified = MODULE.verified_metrics(
            "full-proof",
            "completed",
            {
                "proof_verified": True,
                "prove_wall_s": 2.0,
                "prove_timing_scope": MODULE.PROVE_TIMING_SCOPE,
            },
            8_000_000,
            4.0,
        )
        self.assertTrue(verified["proving_speed_verified"])
        self.assertEqual(verified["prove_mhz"], 4.0)
        self.assertEqual(verified["cold_process_mhz"], 2.0)


if __name__ == "__main__":
    unittest.main()
