"""Deterministic symbol-bearing ELF for nonempty public-input CP-11 parity."""

from __future__ import annotations

import hashlib
import struct
from pathlib import Path


CASE_NAME = "public_io_partial_word"
ELF_SHA256 = "a55facfb5444038a6544a499cfbf2c4845e73e032a5ebda882effc431e8115ee"
INPUT = bytes(range(1, 10))
INPUT_SHA256 = "47e4ee7f211f73265dd17658f6e21c1318bd6c81f37598e20a2756299542efcf"

CODE_VADDR = 0x0001_0000
INPUT_START = 0x0018_0000
INPUT_END = INPUT_START + 12
HALT_FLAG = 0x0010_0000
OUTPUT_LEN = 0x0010_0004
OUTPUT_DATA = 0x0010_0008
STACK_BOTTOM = 0x001F_FC00
STACK_TOP = 0x0020_0000
GLOBAL_POINTER = 0x0020_0800
OUTPUT_END = STACK_BOTTOM

INSTRUCTIONS = (
    0x0010_00B7,  # LUI x1, __halt_flag
    0x0018_0237,  # LUI x4, __input_start
    0x0002_2283,  # LW x5, 0(x4)
    0x0042_2303,  # LW x6, 4(x4)
    0x0082_2383,  # LW x7, 8(x4)
    0x0040_0113,  # ADDI x2, x0, 4
    0x0020_A223,  # SW x2, 4(x1)
    0x0050_A423,  # SW x5, 8(x1)
    0x0010_0113,  # ADDI x2, x0, 1
    0x0020_A023,  # SW x2, 0(x1)
)
SYMBOLS = (
    ("__text_start", CODE_VADDR),
    ("__text_len", len(INSTRUCTIONS) * 4),
    ("__data_start", STACK_TOP),
    ("__data_len", 0),
    ("__global_pointer$", GLOBAL_POINTER),
    ("__stack_bottom", STACK_BOTTOM),
    ("__stack_top", STACK_TOP),
    ("__input_start", INPUT_START),
    ("__input_end", INPUT_END),
    ("__halt_flag", HALT_FLAG),
    ("__output_len", OUTPUT_LEN),
    ("__output_data", OUTPUT_DATA),
    ("__output_end", OUTPUT_END),
)

ELF_HEADER_SIZE = 52
PROGRAM_HEADER_SIZE = 32
SECTION_HEADER_SIZE = 40
SYMBOL_ENTRY_SIZE = 16
SECTION_COUNT = 4
SHSTRTAB = b"\0.symtab\0.strtab\0.shstrtab\0"


def _section_header(
    payload: bytearray,
    offset: int,
    name: int,
    section_type: int,
    file_offset: int,
    size: int,
    link: int,
    entry_size: int,
) -> None:
    struct.pack_into(
        "<IIIIIIIIII",
        payload,
        offset,
        name,
        section_type,
        0,
        0,
        file_offset,
        size,
        link,
        1 if section_type == 2 else 0,
        1,
        entry_size,
    )


def build_elf() -> bytes:
    code = struct.pack(f"<{len(INSTRUCTIONS)}I", *INSTRUCTIONS)
    code_offset = ELF_HEADER_SIZE + PROGRAM_HEADER_SIZE
    symtab_offset = code_offset + len(code)
    symtab_size = (len(SYMBOLS) + 1) * SYMBOL_ENTRY_SIZE
    strtab = b"\0" + b"".join(name.encode() + b"\0" for name, _ in SYMBOLS)
    strtab_offset = symtab_offset + symtab_size
    shstrtab_offset = strtab_offset + len(strtab)
    section_headers_offset = shstrtab_offset + len(SHSTRTAB)
    payload = bytearray(section_headers_offset + SECTION_COUNT * SECTION_HEADER_SIZE)

    payload[:7] = b"\x7fELF\x01\x01\x01"
    struct.pack_into(
        "<HHIIIIIHHHHHH",
        payload,
        16,
        2,
        0xF3,
        1,
        CODE_VADDR,
        ELF_HEADER_SIZE,
        section_headers_offset,
        0,
        ELF_HEADER_SIZE,
        PROGRAM_HEADER_SIZE,
        1,
        SECTION_HEADER_SIZE,
        SECTION_COUNT,
        3,
    )
    struct.pack_into(
        "<IIIIIIII",
        payload,
        ELF_HEADER_SIZE,
        1,
        code_offset,
        CODE_VADDR,
        0,
        len(code),
        len(code),
        0,
        0,
    )
    payload[code_offset:code_offset + len(code)] = code

    string_offset = 1
    for index, (name, value) in enumerate(SYMBOLS, start=1):
        symbol_offset = symtab_offset + index * SYMBOL_ENTRY_SIZE
        struct.pack_into("<IIIBBH", payload, symbol_offset, string_offset, value, 0, 0x10, 0, 0xFFF1)
        string_offset += len(name) + 1
    payload[strtab_offset:strtab_offset + len(strtab)] = strtab
    payload[shstrtab_offset:shstrtab_offset + len(SHSTRTAB)] = SHSTRTAB

    _section_header(payload, section_headers_offset, 0, 0, 0, 0, 0, 0)
    _section_header(
        payload,
        section_headers_offset + SECTION_HEADER_SIZE,
        1,
        2,
        symtab_offset,
        symtab_size,
        2,
        SYMBOL_ENTRY_SIZE,
    )
    _section_header(
        payload,
        section_headers_offset + 2 * SECTION_HEADER_SIZE,
        9,
        3,
        strtab_offset,
        len(strtab),
        0,
        0,
    )
    _section_header(
        payload,
        section_headers_offset + 3 * SECTION_HEADER_SIZE,
        17,
        3,
        shstrtab_offset,
        len(SHSTRTAB),
        0,
        0,
    )
    result = bytes(payload)
    if hashlib.sha256(result).hexdigest() != ELF_SHA256:
        raise ValueError("nonempty public-input ELF generator drifted")
    if hashlib.sha256(INPUT).hexdigest() != INPUT_SHA256:
        raise ValueError("nonempty public-input bytes drifted")
    return result


def materialize(directory: Path) -> tuple[Path, Path, bytes]:
    elf = directory / f"{CASE_NAME}.elf"
    input_path = directory / f"{CASE_NAME}.input"
    elf.write_bytes(build_elf())
    input_path.write_bytes(INPUT)
    return elf, input_path, INPUT
