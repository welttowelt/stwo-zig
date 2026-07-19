"""Deterministically derive a fresh, safe cross-shard RV32IM challenge."""

from __future__ import annotations

import hashlib
import json
import struct
from dataclasses import dataclass


DOMAIN = b"stwo-zig/riscv/release-challenge/program/v1\0"
INPUT_START = 0x0010_0000
HALT_FLAG = 0x0011_0000
OUTPUT_LEN = HALT_FLAG + 4
OUTPUT_DATA = HALT_FLAG + 8
MIN_ITERATIONS = 65_536
CODE_VADDR = 0x0001_0000
STACK_BOTTOM = 0x001F_FC00
STACK_TOP = 0x0020_0000
GLOBAL_POINTER = 0x0020_0800


def _mask(value: int, bits: int) -> int:
    return value & ((1 << bits) - 1)


def _i(imm: int, rs1: int, funct3: int, rd: int) -> int:
    return _mask(imm, 12) << 20 | rs1 << 15 | funct3 << 12 | rd << 7 | 0x13


def _addi(rd: int, rs1: int, imm: int) -> int:
    return _i(imm, rs1, 0, rd)


def _lui(rd: int, immediate: int) -> int:
    return immediate & 0xFFFFF000 | rd << 7 | 0x37


def _sw(rs2: int, rs1: int, immediate: int) -> int:
    immediate = _mask(immediate, 12)
    return (immediate >> 5) << 25 | rs2 << 20 | rs1 << 15 | 2 << 12 | (immediate & 0x1F) << 7 | 0x23


def _blt(rs1: int, rs2: int, immediate: int) -> int:
    immediate = _mask(immediate, 13)
    return (
        (immediate >> 12) << 31 | ((immediate >> 5) & 0x3F) << 25
        | rs2 << 20 | rs1 << 15 | 4 << 12 | ((immediate >> 1) & 0xF) << 8
        | ((immediate >> 11) & 1) << 7 | 0x63
    )


def _build_elf(words: list[int], symbols: dict[str, int]) -> bytes:
    code = b"".join(struct.pack("<I", word) for word in words)
    code_offset = 84
    string_table = b"\0"
    name_offsets: dict[str, int] = {}
    for name in symbols:
        name_offsets[name] = len(string_table)
        string_table += name.encode() + b"\0"
    symbol_table = bytes(16)
    for name, value in symbols.items():
        symbol_table += struct.pack("<IIIBBH", name_offsets[name], value, 0, 0x10, 0, 0xFFF1)
    section_names = b"\0.symtab\0.strtab\0.shstrtab\0"
    symbol_offset = code_offset + len(code)
    string_offset = symbol_offset + len(symbol_table)
    names_offset = string_offset + len(string_table)
    section_offset = names_offset + len(section_names)

    def section(name: int, kind: int, offset: int, size: int, link: int, info: int, entry: int) -> bytes:
        return struct.pack("<IIIIIIIIII", name, kind, 0, 0, offset, size, link, info, 1, entry)

    sections = b"".join((
        section(0, 0, 0, 0, 0, 0, 0),
        section(1, 2, symbol_offset, len(symbol_table), 2, 1, 16),
        section(9, 3, string_offset, len(string_table), 0, 0, 0),
        section(17, 3, names_offset, len(section_names), 0, 0, 0),
    ))
    header = struct.pack(
        "<4sBBBBB7xHHIIIIIHHHHHH", b"\x7fELF", 1, 1, 1, 0, 0,
        2, 0xF3, 1, CODE_VADDR, 52, section_offset, 0, 52, 32, 1, 40, 4, 3,
    )
    program = struct.pack("<IIIIIIII", 1, code_offset, CODE_VADDR, 0, len(code), len(code), 0, 0)
    return header + program + code + symbol_table + string_table + section_names + sections


class HashStream:
    """Versioned SHA-256 counter stream with unbiased bounded sampling."""

    def __init__(self, seed: bytes) -> None:
        self.seed = seed
        self.counter = 0
        self.buffer = b""

    def take(self, size: int) -> bytes:
        while len(self.buffer) < size:
            self.buffer += hashlib.sha256(
                b"stwo-zig/riscv/release-challenge/stream/v1\0"
                + self.seed + self.counter.to_bytes(8, "big")
            ).digest()
            self.counter += 1
        result, self.buffer = self.buffer[:size], self.buffer[size:]
        return result

    def below(self, bound: int) -> int:
        if bound <= 0:
            raise ValueError("sampling bound must be positive")
        limit = (1 << 64) - ((1 << 64) % bound)
        while True:
            value = int.from_bytes(self.take(8), "big")
            if value < limit:
                return value % bound

@dataclass(frozen=True)
class DerivedProgram:
    seed_sha256: str
    input_bytes: bytes
    instruction_words: tuple[int, ...]
    loop_iterations: int
    elf_bytes: bytes

    @property
    def input_sha256(self) -> str:
        return hashlib.sha256(self.input_bytes).hexdigest()

    @property
    def elf_sha256(self) -> str:
        return hashlib.sha256(self.elf_bytes).hexdigest()

    @property
    def spec(self) -> dict[str, object]:
        return {
            "schema": "riscv-safe-cross-shard-program-v1",
            "grammar": "rv32i-addi-loop-public-output-no-mulh-v1",
            "loop_iterations": self.loop_iterations,
            "public_output_words": list(self.public_output_words),
            "instruction_words": list(self.instruction_words),
            "input_sha256": self.input_sha256,
            "elf_sha256": self.elf_sha256,
        }

    @property
    def public_output_words(self) -> tuple[int, ...]:
        seed = bytes.fromhex(self.seed_sha256)
        return tuple(int.from_bytes(seed[offset:offset + 4], "little") for offset in range(0, 16, 4))


def canonical_bytes(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def _load_u32(rd: int, value: int) -> list[int]:
    upper = (value + 0x800) & 0xFFFFF000
    lower = (value - upper) & 0xFFF
    if lower >= 0x800:
        lower -= 0x1000
    return [_lui(rd, upper), _addi(rd, rd, lower)]


def _epilogue(output_words: tuple[int, ...]) -> list[int]:
    words = [_lui(31, HALT_FLAG)]
    for index, value in enumerate(output_words):
        words.extend(_load_u32(30, value))
        words.append(_sw(30, 31, 8 + index * 4))
    words.extend([
        _addi(30, 0, len(output_words) * 4),
        _sw(30, 31, 4),
        _addi(30, 0, 1),
        _sw(30, 31, 0),
    ])
    return words


def _safe_prefix(rng: HashStream) -> list[int]:
    """Executed ADDI-only challenge data stays in the proven family."""
    words = []
    for _ in range(16):
        words.append(_addi(4 + rng.below(11), 4 + rng.below(11), 1 + rng.below(2_047)))
    return words


def derive(nonce: bytes, identity: dict[str, object]) -> DerivedProgram:
    if len(nonce) != 32:
        raise ValueError("challenge nonce must contain exactly 32 bytes")
    seed = hashlib.sha256(DOMAIN + nonce + canonical_bytes(identity)).digest()
    rng = HashStream(seed)
    iterations = MIN_ITERATIONS
    words = _safe_prefix(rng)
    words.extend([
        _addi(1, 0, 0),
        _lui(2, MIN_ITERATIONS),
        _addi(1, 1, 1),
        _blt(1, 2, -4),
    ])
    output_words = tuple(
        int.from_bytes(seed[offset:offset + 4], "little") for offset in range(0, 16, 4)
    )
    words.extend(_epilogue(output_words))
    # Nonempty public input is deliberately disabled: the current Zig AIR does
    # not yet balance it in LogUp. The nonce still changes the committed ELF.
    input_bytes = b""
    symbols = {
        "__text_start": CODE_VADDR,
        "__text_len": len(words) * 4,
        "__data_start": STACK_TOP,
        "__data_len": 0,
        "__global_pointer$": GLOBAL_POINTER,
        "__stack_bottom": STACK_BOTTOM,
        "__stack_top": STACK_TOP,
        "__input_start": INPUT_START,
        "__input_end": INPUT_START + len(input_bytes),
        "__halt_flag": HALT_FLAG,
        "__output_len": OUTPUT_LEN,
        "__output_data": OUTPUT_DATA,
        "__output_end": STACK_BOTTOM,
    }
    elf = _build_elf(words, symbols)
    return DerivedProgram(seed.hex(), input_bytes, tuple(words), iterations, elf)
