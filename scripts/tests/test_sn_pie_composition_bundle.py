import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
from collections.abc import Iterable


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/sn_pie_composition_bundle.py"
TEMPLATE = ROOT / "vectors/cairo/sn_pie_2_composition.bin"
METALLIB = ROOT / "vectors/cairo/sn_pie_2_composition.metallib"
SPEC = importlib.util.spec_from_file_location("sn_pie_composition_bundle", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


SN1_LOGS = {
    "add_opcode": 21,
    "add_opcode_small": 22,
    "add_ap_opcode": 20,
    "assert_eq_opcode": 21,
    "assert_eq_opcode_imm": 20,
    "assert_eq_opcode_double_deref": 22,
    "blake_compress_opcode": 17,
    "call_opcode_abs": 10,
    "call_opcode_rel_imm": 19,
    "jnz_opcode_non_taken": 18,
    "jnz_opcode_taken": 21,
    "jump_opcode_double_deref": 10,
    "jump_opcode_rel": 12,
    "jump_opcode_rel_imm": 20,
    "mul_opcode": 18,
    "mul_opcode_small": 20,
    "ret_opcode": 19,
    "verify_instruction": 17,
    "blake_round": 21,
    "blake_g": 24,
    "triple_xor_32": 20,
    "bitwise_builtin": 11,
    "pedersen_builtin": 16,
    "poseidon_builtin": 14,
    "range_check_builtin": 20,
    "ec_op_builtin": 11,
    "partial_ec_mul_generic": 19,
    "pedersen_aggregator_window_bits_18": 16,
    "partial_ec_mul_window_bits_18": 21,
    "poseidon_aggregator": 13,
    "poseidon_3_partial_rounds_chain": 18,
    "poseidon_full_round_chain": 16,
    "cube_252": 20,
    "range_check_252_width_27": 20,
    "memory_address_to_id": 20,
    "memory_id_to_big": 18,
    "memory_id_to_small": 22,
}

FIB_25K_LOGS = {
    "add_opcode": 15,
    "add_opcode_small": 16,
    "add_ap_opcode": 4,
    "assert_eq_opcode": 15,
    "assert_eq_opcode_imm": 4,
    "call_opcode_rel_imm": 15,
    "jnz_opcode_non_taken": 4,
    "jnz_opcode_taken": 15,
    "ret_opcode": 15,
    "verify_instruction": 5,
    "memory_address_to_id": 14,
    "memory_id_to_big": 15,
    "memory_id_to_small": 16,
}

FIB_25K_FIXED = [
    "range_check_6",
    "range_check_8",
    "range_check_11",
    "range_check_12",
    "range_check_18",
    "range_check_20",
    "range_check_4_3",
    "range_check_4_4",
    "range_check_9_9",
    "range_check_7_2_5",
    "range_check_3_6_6_3",
    "range_check_4_4_4_4",
    "range_check_3_3_3_3_3",
    "verify_bitwise_xor_4",
    "verify_bitwise_xor_7",
    "verify_bitwise_xor_8",
    "verify_bitwise_xor_9",
]


def components(data: bytes | bytearray):
    offset = 40
    for _ in range(MODULE.u32(data, 28)):
        component_offset = offset
        label_len = MODULE.u16(data, offset)
        trace_log = MODULE.u32(data, offset + 8)
        evaluation_log = MODULE.u32(data, offset + 12)
        n_constraints = MODULE.u32(data, offset + 16)
        random_offset = MODULE.u32(data, offset + 20)
        span_count = MODULE.u32(data, offset + 24)
        preprocessed_count = MODULE.u32(data, offset + 28)
        denominator_count = MODULE.u32(data, offset + 32)
        ext_source_count = MODULE.u32(data, offset + 36)
        part_count = MODULE.u32(data, offset + 40)
        offset += 44
        label = data[offset : offset + label_len].decode()
        offset += label_len
        spans = [
            struct.unpack_from("<III", data, offset + index * 12)
            for index in range(span_count)
        ]
        offset += span_count * 12
        preprocessed = [MODULE.u32(data, offset + index * 4) for index in range(preprocessed_count)]
        offset += preprocessed_count * 4
        offset += denominator_count * 4
        offset += ext_source_count * 32
        program_offsets = []
        program_ranges = []
        for _ in range(part_count):
            program_len = MODULE.u32(data, offset + 4)
            program_offsets.append(offset + 16)
            program_ranges.append((offset + 16, program_len))
            offset += 16 + program_len
        yield {
            "offset": component_offset,
            "label": label,
            "trace_log": trace_log,
            "evaluation_log": evaluation_log,
            "n_constraints": n_constraints,
            "random_offset": random_offset,
            "spans": spans,
            "preprocessed": preprocessed,
            "program_offsets": program_offsets,
            "program_ranges": program_ranges,
        }


def write_proof(
    path: Path,
    logs: dict[str, int],
    fixed_components: Iterable[str] | None = None,
) -> None:
    claim = {}
    for label, log_size in logs.items():
        if label == "memory_id_to_big":
            claim[label] = {"big_log_sizes": [log_size]}
        else:
            claim[label] = {"log_size": log_size}
    for label in fixed_components or set():
        claim[label] = {}
    path.write_text(json.dumps({"claim": claim}))


def write_projection_proof(
    path: Path,
    logs: dict[str, int],
    fixed_components: Iterable[str],
    tree_columns: list[int],
    variant: str,
) -> None:
    claim = {}
    for label, log_size in logs.items():
        claim[label] = (
            {"big_log_sizes": [log_size]}
            if label == "memory_id_to_big"
            else {"log_size": log_size}
        )
    for label in fixed_components:
        claim[label] = {}
    interaction_claim = {label: {} for label in claim}
    trees = [[0] * count for count in tree_columns]
    path.write_text(
        json.dumps(
            {
                "claim": claim,
                "interaction_claim": interaction_claim,
                "stark_proof": {"sampled_values": trees, "queried_values": trees},
                "preprocessed_trace_variant": variant,
            }
        )
    )


def write_canonical_preprocessed(path: Path) -> None:
    identities = [f"column_{index}" for index in range(161)]
    sequence_indices = {
        4: 0,
        5: 17,
        6: 18,
        7: 49,
        8: 52,
        9: 58,
        10: 59,
        11: 60,
        12: 61,
        13: 62,
        14: 63,
        15: 70,
        16: 76,
        17: 84,
        18: 85,
        19: 95,
        20: 96,
        21: 100,
        22: 101,
        23: 102,
        24: 159,
        25: 160,
    }
    for log_size, index in sequence_indices.items():
        identities[index] = f"seq_{log_size}"
    for pedersen_index in range(56):
        identities[103 + pedersen_index] = f"pedersen_points_{pedersen_index}"
    with path.open("wb") as stream:
        stream.write(b"STWZPPC\0")
        stream.write(struct.pack("<II", 1, len(identities)))
        for identity in identities:
            encoded = identity.encode()
            stream.write(struct.pack("<HHIQ", len(encoded), 0, 0, 1))
            stream.write(encoded)
            stream.write(bytes(4))


def latest_metal_eval_prepare() -> Path | None:
    candidates = list((ROOT / ".zig-cache/o").glob("*/metal-eval-prepare"))
    candidates = [path for path in candidates if path.is_file()]
    return max(candidates, key=lambda path: path.stat().st_mtime) if candidates else None


class SnPieCompositionBundleTest(unittest.TestCase):
    def test_sn2_identity_retarget_is_byte_identical(self):
        template_data = TEMPLATE.read_bytes()
        logs = {item["label"]: item["trace_log"] for item in components(template_data)}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            proof = root / "sn2-proof.json"
            output = root / "composition.bin"
            write_proof(proof, logs)

            result = MODULE.retarget(TEMPLATE, proof, output)
            retargeted_data = output.read_bytes()

        self.assertEqual(retargeted_data, template_data)
        self.assertEqual(result["components"], 58)
        self.assertEqual(result["changed_components"], 0)
        self.assertEqual(result["max_evaluation_log_size"], 24)
        self.assertEqual(result["changes"], {})

    def test_sn1_retarget_loads_in_zig_with_existing_metallib(self):
        runner = latest_metal_eval_prepare()
        if runner is None or not METALLIB.is_file():
            self.skipTest("built metal-eval-prepare and the checked-in metallib are required")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            proof = root / "sn1-proof.json"
            output = root / "composition.bin"
            template_labels = [item["label"] for item in components(TEMPLATE.read_bytes())]
            write_proof(
                proof,
                SN1_LOGS,
                [label for label in template_labels if label not in SN1_LOGS],
            )
            result = MODULE.retarget(TEMPLATE, proof, output)
            completed = subprocess.run(
                [runner, output, METALLIB],
                cwd=ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

        loaded = json.loads(completed.stdout)
        self.assertEqual(result["changed_components"], 35)
        self.assertEqual(result["max_evaluation_log_size"], 25)
        self.assertEqual(loaded["components"], 58)
        self.assertEqual(loaded["programs"], 279)
        self.assertEqual(loaded["source_bytes"], 0)
        self.assertTrue(loaded["all_programs_compiled"])

    def test_fib_25k_projection_has_authenticated_30_component_geometry(self):
        template_data = TEMPLATE.read_bytes()
        template_components = list(components(template_data))
        template_logs = {
            component["label"]: component["trace_log"]
            for component in template_components
        }
        fib_labels = list(FIB_25K_LOGS) + FIB_25K_FIXED
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            template_proof = root / "sn2-proof.json"
            target_proof = root / "fib-25k-proof.json"
            preprocessed = root / "canonical.stwzppc"
            output = root / "composition.bin"
            manifest_path = root / "composition.projection.json"
            write_projection_proof(
                template_proof,
                template_logs,
                [],
                [161, 3449, 2268, 8],
                "canonical",
            )
            write_projection_proof(
                target_proof,
                FIB_25K_LOGS,
                FIB_25K_FIXED,
                [105, 396, 324, 8],
                "canonical_without_pedersen",
            )
            write_canonical_preprocessed(preprocessed)

            result = MODULE.retarget(
                TEMPLATE,
                target_proof,
                output,
                preprocessed,
                template_proof,
                True,
                manifest_path,
            )
            projected_data = output.read_bytes()
            manifest = json.loads(manifest_path.read_text())

        projected = list(components(projected_data))
        self.assertEqual(MODULE.u32(projected_data, 8), 2)
        self.assertEqual(MODULE.u32(projected_data, 28), 30)
        self.assertEqual(struct.unpack_from("<Q", projected_data, 16)[0], 186)
        self.assertEqual(MODULE.u32(projected_data, 24), 21)
        self.assertEqual([component["label"] for component in projected], fib_labels)
        self.assertEqual(result["changed_components"], 13)
        self.assertEqual(result["changed_preprocessed_components"], 3)

        next_constraint = 0
        span_ends = {1: 0, 2: 0}
        source_by_label = {component["label"]: component for component in template_components}
        for component in projected:
            self.assertEqual(component["random_offset"], next_constraint)
            next_constraint += component["n_constraints"]
            for tree, start, end in component["spans"]:
                if tree == 0:
                    self.assertEqual((start, end), (0, 0))
                else:
                    self.assertEqual(start, span_ends[tree])
                    span_ends[tree] = end
            source = source_by_label[component["label"]]
            self.assertEqual(len(source["program_ranges"]), len(component["program_ranges"]))
            for source_program, target_program in zip(
                source["program_ranges"], component["program_ranges"], strict=True
            ):
                self.assertEqual(
                    MODULE.semantic_program_payload(template_data, *source_program),
                    MODULE.semantic_program_payload(projected_data, *target_program),
                )
        self.assertEqual(next_constraint, 186)
        self.assertEqual(span_ends, {1: 396, 2: 324})
        self.assertEqual(
            {
                component["label"]: component["preprocessed"]
                for component in projected
                if component["label"].startswith("memory_")
            },
            {
                "memory_address_to_id": [63],
                "memory_id_to_big": [70],
                "memory_id_to_small": [76],
            },
        )
        self.assertEqual(manifest["format"], MODULE.PROJECTION_MANIFEST_FORMAT)
        self.assertEqual(manifest["target"]["tree_columns"], [105, 396, 324, 8])
        self.assertEqual(
            int(manifest["target"]["plan_hash"], 16),
            MODULE.projection_plan_hash(projected_data),
        )

    def test_projection_geometry_mismatch_fails_without_artifacts(self):
        template_data = TEMPLATE.read_bytes()
        template_logs = {
            component["label"]: component["trace_log"]
            for component in components(template_data)
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            template_proof = root / "sn2-proof.json"
            target_proof = root / "fib-25k-proof.json"
            preprocessed = root / "canonical.stwzppc"
            output = root / "composition.bin"
            manifest = root / "composition.projection.json"
            write_projection_proof(
                template_proof,
                template_logs,
                [],
                [161, 3449, 2268, 8],
                "canonical",
            )
            write_projection_proof(
                target_proof,
                FIB_25K_LOGS,
                FIB_25K_FIXED,
                [105, 395, 324, 8],
                "canonical_without_pedersen",
            )
            write_canonical_preprocessed(preprocessed)

            with self.assertRaisesRegex(
                ValueError, "projected composition spans do not match target proof geometry"
            ):
                MODULE.retarget(
                    TEMPLATE,
                    target_proof,
                    output,
                    preprocessed,
                    template_proof,
                    True,
                    manifest,
                )
            self.assertFalse(output.exists())
            self.assertFalse(manifest.exists())

    def test_component_set_change_requires_explicit_projection(self):
        template_data = TEMPLATE.read_bytes()
        first = next(components(template_data))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            proof = root / "small-program-proof.json"
            output = root / "composition.bin"
            write_proof(proof, {first["label"]: first["trace_log"]})

            with self.assertRaisesRegex(
                ValueError,
                "target proof changes the active component set; component projection is required",
            ):
                MODULE.retarget(TEMPLATE, proof, output)

            self.assertFalse(output.exists())

    def test_unsupported_headers_fail_without_output(self):
        template_data = TEMPLATE.read_bytes()
        cases = {
            "magic": b"INVALID!" + template_data[8:],
            "version": template_data[:8] + struct.pack("<I", 2) + template_data[12:],
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            proof = root / "proof.json"
            write_proof(proof, {})
            for name, data in cases.items():
                with self.subTest(name=name):
                    malformed = root / f"{name}.bin"
                    output = root / f"{name}.out"
                    malformed.write_bytes(data)
                    with self.assertRaisesRegex(ValueError, "unsupported composition bundle"):
                        MODULE.retarget(malformed, proof, output)
                    self.assertFalse(output.exists())

    def test_malformed_bundle_sections_fail_without_output(self):
        template_data = TEMPLATE.read_bytes()
        first = next(components(template_data))
        cases = {}
        invalid_component = bytearray(template_data)
        struct.pack_into("<H", invalid_component, first["offset"] + 2, 1)
        cases["component header"] = (invalid_component, "invalid component header")
        invalid_program = bytearray(template_data)
        struct.pack_into("<I", invalid_program, first["program_offsets"][0], 0)
        cases["program magic"] = (invalid_program, "invalid evaluation program")
        cases["trailing data"] = (template_data + b"x", "trailing composition bundle data")

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            proof = root / "proof.json"
            write_proof(proof, {})
            for name, (data, error) in cases.items():
                with self.subTest(name=name):
                    malformed = root / f"{name}.bin"
                    output = root / f"{name}.out"
                    malformed.write_bytes(data)
                    with self.assertRaisesRegex(ValueError, error):
                        MODULE.retarget(malformed, proof, output)
                    self.assertFalse(output.exists())

    def test_unsupported_memory_instances_fail_without_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            proof = root / "proof.json"
            output = root / "composition.bin"
            proof.write_text(
                json.dumps(
                    {"claim": {"memory_id_to_big": {"big_log_sizes": [18, 19]}}}
                )
            )
            with self.assertRaisesRegex(ValueError, "unsupported instances"):
                MODULE.retarget(TEMPLATE, proof, output)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
