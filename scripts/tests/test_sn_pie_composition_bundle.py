import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest


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


def components(data: bytes | bytearray):
    offset = 40
    for _ in range(MODULE.u32(data, 28)):
        component_offset = offset
        label_len = MODULE.u16(data, offset)
        trace_log = MODULE.u32(data, offset + 8)
        evaluation_log = MODULE.u32(data, offset + 12)
        span_count = MODULE.u32(data, offset + 24)
        preprocessed_count = MODULE.u32(data, offset + 28)
        denominator_count = MODULE.u32(data, offset + 32)
        ext_source_count = MODULE.u32(data, offset + 36)
        part_count = MODULE.u32(data, offset + 40)
        offset += 44
        label = data[offset : offset + label_len].decode()
        offset += label_len
        offset += span_count * 12
        offset += preprocessed_count * 4
        offset += denominator_count * 4
        offset += ext_source_count * 32
        program_offsets = []
        for _ in range(part_count):
            program_len = MODULE.u32(data, offset + 4)
            program_offsets.append(offset + 16)
            offset += 16 + program_len
        yield {
            "offset": component_offset,
            "label": label,
            "trace_log": trace_log,
            "evaluation_log": evaluation_log,
            "program_offsets": program_offsets,
        }


def write_proof(path: Path, logs: dict[str, int]) -> None:
    claim = {}
    for label, log_size in logs.items():
        if label == "memory_id_to_big":
            claim[label] = {"big_log_sizes": [log_size]}
        else:
            claim[label] = {"log_size": log_size}
    path.write_text(json.dumps({"claim": claim}))


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
            write_proof(proof, SN1_LOGS)
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
