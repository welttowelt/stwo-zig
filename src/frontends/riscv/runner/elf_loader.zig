//! ELF32 binary loader for RISC-V programs.
//!
//! Parses a minimal ELF32 binary and loads PT_LOAD segments into the
//! sparse `Memory` at their specified virtual addresses.

const std = @import("std");
const Memory = @import("memory.zig").Memory;

pub const ElfError = error{
    InvalidMagic,
    Not32Bit,
    NotLittleEndian,
    NotRiscV,
    InvalidProgramHeader,
    BufferTooSmall,
};

/// Information extracted from the ELF header after loading.
pub const ElfInfo = struct {
    entry_point: u32,
    segments_loaded: usize,
};

// ELF32 constants
const ELF_MAGIC = [4]u8{ 0x7F, 'E', 'L', 'F' };
const ELFCLASS32: u8 = 1;
const ELFDATA2LSB: u8 = 1;
const EM_RISCV: u16 = 243;
const PT_LOAD: u32 = 1;

// ELF32 header offsets and sizes
const ELF_HDR_SIZE: usize = 52;
const PHDR_SIZE: usize = 32;

/// Load an ELF32 RISC-V binary into `mem`.
///
/// Returns the entry point and the number of segments loaded.
pub fn loadElf(elf_bytes: []const u8, mem: *Memory) (ElfError || error{OutOfMemory})!ElfInfo {
    if (elf_bytes.len < ELF_HDR_SIZE) return ElfError.BufferTooSmall;

    // Validate magic.
    if (!std.mem.eql(u8, elf_bytes[0..4], &ELF_MAGIC)) return ElfError.InvalidMagic;

    // EI_CLASS must be ELFCLASS32.
    if (elf_bytes[4] != ELFCLASS32) return ElfError.Not32Bit;

    // EI_DATA must be ELFDATA2LSB (little-endian).
    if (elf_bytes[5] != ELFDATA2LSB) return ElfError.NotLittleEndian;

    // e_machine (offset 18, 2 bytes LE) must be EM_RISCV.
    const e_machine = readU16LE(elf_bytes[18..20]);
    if (e_machine != EM_RISCV) return ElfError.NotRiscV;

    // e_entry (offset 24, 4 bytes LE)
    const e_entry = readU32LE(elf_bytes[24..28]);

    // e_phoff (offset 28, 4 bytes LE) — offset to program header table.
    const e_phoff = readU32LE(elf_bytes[28..32]);

    // e_phnum (offset 44, 2 bytes LE) — number of program headers.
    const e_phnum = readU16LE(elf_bytes[44..46]);

    var segments_loaded: usize = 0;

    // Iterate program headers and load PT_LOAD segments.
    for (0..e_phnum) |i| {
        const ph_offset = @as(usize, e_phoff) + i * PHDR_SIZE;
        if (ph_offset + PHDR_SIZE > elf_bytes.len) return ElfError.InvalidProgramHeader;

        const phdr = elf_bytes[ph_offset .. ph_offset + PHDR_SIZE];

        const p_type = readU32LE(phdr[0..4]);
        if (p_type != PT_LOAD) continue;

        const p_offset = readU32LE(phdr[4..8]);
        const p_vaddr = readU32LE(phdr[8..12]);
        const p_filesz = readU32LE(phdr[16..20]);

        if (@as(usize, p_offset) + @as(usize, p_filesz) > elf_bytes.len) {
            return ElfError.InvalidProgramHeader;
        }

        const segment_data = elf_bytes[p_offset .. p_offset + p_filesz];
        mem.loadSegment(p_vaddr, segment_data);
        segments_loaded += 1;
    }

    return .{
        .entry_point = e_entry,
        .segments_loaded = segments_loaded,
    };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn readU16LE(bytes: *const [2]u8) u16 {
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}

fn readU32LE(bytes: *const [4]u8) u32 {
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// A minimal hand-crafted ELF32 RISC-V binary with one PT_LOAD segment
/// containing 4 bytes of data loaded at vaddr 0x10000.
fn makeMinimalElf() [88]u8 {
    var buf = [_]u8{0} ** 88;

    // ELF magic
    buf[0] = 0x7F;
    buf[1] = 'E';
    buf[2] = 'L';
    buf[3] = 'F';
    // EI_CLASS = ELFCLASS32
    buf[4] = 1;
    // EI_DATA = ELFDATA2LSB
    buf[5] = 1;
    // EI_VERSION
    buf[6] = 1;

    // e_type = ET_EXEC (2)
    buf[16] = 2;
    buf[17] = 0;

    // e_machine = EM_RISCV (243 = 0xF3)
    buf[18] = 0xF3;
    buf[19] = 0;

    // e_version
    buf[20] = 1;

    // e_entry = 0x00010000
    buf[24] = 0x00;
    buf[25] = 0x00;
    buf[26] = 0x01;
    buf[27] = 0x00;

    // e_phoff = 52 (immediately after ELF header)
    buf[28] = 52;
    buf[29] = 0;
    buf[30] = 0;
    buf[31] = 0;

    // e_shoff = 0 (no section headers)

    // e_ehsize = 52
    buf[40] = 52;
    buf[41] = 0;

    // e_phentsize = 32
    buf[42] = 32;
    buf[43] = 0;

    // e_phnum = 1
    buf[44] = 1;
    buf[45] = 0;

    // --- Program header at offset 52 ---

    // p_type = PT_LOAD (1)
    buf[52] = 1;

    // p_offset = 84 (data starts at byte 84 in the file)
    buf[56] = 84;

    // p_vaddr = 0x00010000
    buf[60] = 0x00;
    buf[61] = 0x00;
    buf[62] = 0x01;
    buf[63] = 0x00;

    // p_paddr = 0x00010000
    buf[64] = 0x00;
    buf[65] = 0x00;
    buf[66] = 0x01;
    buf[67] = 0x00;

    // p_filesz = 4
    buf[68] = 4;

    // p_memsz = 4
    buf[72] = 4;

    // p_flags = PF_R | PF_X (5)
    buf[76] = 5;

    // p_align = 4
    buf[80] = 4;

    // --- Segment data at offset 84: ADDI x1, x0, 42 = 0x02A00093 ---
    buf[84] = 0x93;
    buf[85] = 0x00;
    buf[86] = 0xA0;
    buf[87] = 0x02;

    return buf;
}

test "loadElf parses minimal ELF header" {
    var mem = @import("memory.zig").Memory.init(std.testing.allocator);
    defer mem.deinit();

    const elf = makeMinimalElf();
    const info = try loadElf(&elf, &mem);

    try std.testing.expectEqual(@as(u32, 0x00010000), info.entry_point);
    try std.testing.expectEqual(@as(usize, 1), info.segments_loaded);

    // Verify the instruction was loaded at the correct address.
    try std.testing.expectEqual(@as(u32, 0x02A00093), mem.readU32(0x00010000));
}

test "loadElf rejects bad magic" {
    var mem = @import("memory.zig").Memory.init(std.testing.allocator);
    defer mem.deinit();

    var elf = makeMinimalElf();
    elf[0] = 0x00; // corrupt magic
    const result = loadElf(&elf, &mem);
    try std.testing.expectError(ElfError.InvalidMagic, result);
}

test "loadElf rejects non-RISC-V" {
    var mem = @import("memory.zig").Memory.init(std.testing.allocator);
    defer mem.deinit();

    var elf = makeMinimalElf();
    elf[18] = 0x03; // e_machine = EM_386
    elf[19] = 0x00;
    const result = loadElf(&elf, &mem);
    try std.testing.expectError(ElfError.NotRiscV, result);
}

test "loadElf rejects truncated input" {
    var mem = @import("memory.zig").Memory.init(std.testing.allocator);
    defer mem.deinit();

    const short = [_]u8{0x7F} ++ "ELF".*;
    const result = loadElf(&short, &mem);
    try std.testing.expectError(ElfError.BufferTooSmall, result);
}
