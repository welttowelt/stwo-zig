"""Encoder and fixture-identity tests for the riscv trace-vector gate."""

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import riscv_trace_vectors as rtv

ROOT = Path(__file__).resolve().parents[2]


class EncoderTest(unittest.TestCase):
    """Known-good encodings cross-checked against the Zig decoder's tests."""

    def test_addi(self):
        self.assertEqual(rtv.ADDI(1, 0, 10), 0x00A00093)
        self.assertEqual(rtv.ADDI(2, 0, 20), 0x01400113)

    def test_r_type(self):
        self.assertEqual(rtv.ADD(3, 1, 2), 0x002081B3)
        self.assertEqual(rtv.SUB(4, 2, 1), 0x40110233)
        self.assertEqual(rtv.XOR(8, 1, 2), 0x0020C433)

    def test_m_extension(self):
        self.assertEqual(rtv.DIV(1, 2, 3), 0x023140B3)
        self.assertEqual(rtv.MUL(5, 1, 2), 0x022082B3)

    def test_negative_immediate_wraps_to_twelve_bits(self):
        self.assertEqual((rtv.ADDI(1, 0, -1) >> 20) & 0xFFF, 0xFFF)

    def test_branch_immediate_scrambling_round_trips(self):
        # BLT x3, x4, -16: decode the scrambled fields back into the offset.
        word = rtv.BLT(3, 4, -16)
        imm = (
            ((word >> 31) & 1) << 12
            | ((word >> 7) & 1) << 11
            | ((word >> 25) & 0x3F) << 5
            | ((word >> 8) & 0xF) << 1
        )
        if imm & (1 << 12):
            imm -= 1 << 13
        self.assertEqual(imm, -16)

    def test_jal_immediate_scrambling_round_trips(self):
        word = rtv.JAL(5, 12)
        imm = (
            ((word >> 31) & 1) << 20
            | ((word >> 12) & 0xFF) << 12
            | ((word >> 20) & 1) << 11
            | ((word >> 21) & 0x3FF) << 1
        )
        self.assertEqual(imm, 12)

    def test_ecall(self):
        self.assertEqual(rtv.ECALL(), 0x00000073)


class FixtureIdentityTest(unittest.TestCase):
    def test_historical_ecall_fixture_layout_still_reproduces(self):
        # The pre-restoration alu_test.elf (ECALL-terminated) pins the ELF
        # layout contract; the committed vector now ends with the sentinel.
        historical = [
            rtv.ADDI(1, 0, 10), rtv.ADDI(2, 0, 20), rtv.ADD(3, 1, 2),
            rtv.SUB(4, 2, 1), rtv.ECALL(),
        ]
        elf = rtv.build_elf(historical)
        self.assertEqual(len(elf), 104)
        self.assertEqual(elf[0x18:0x1C], (0x00010000).to_bytes(4, "little"))

    def test_every_program_halts_with_the_oracle_sentinel(self):
        for name, program in rtv.PROGRAMS.items():
            self.assertEqual(program[-1], rtv.SENTINEL(), name)
        for name, (program, _symbols) in rtv.SYMBOL_PROGRAMS.items():
            self.assertEqual(program[-1], rtv.SENTINEL(), name)

    def test_vector_file_covers_every_program(self):
        payload = json.loads(
            (ROOT / "vectors" / "riscv_elfs" / "trace_vectors.json").read_text()
        )
        self.assertEqual(
            {v["name"] for v in payload["vectors"]},
            set(rtv.PROGRAMS) | set(rtv.SYMBOL_PROGRAMS),
        )
        self.assertEqual(payload["stark_v_commit"], rtv.pinned_stark_v_commit())


if __name__ == "__main__":
    unittest.main()
