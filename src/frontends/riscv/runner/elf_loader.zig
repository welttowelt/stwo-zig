//! ELF32 binary loader for RISC-V programs.
//!
//! Parses a minimal ELF32 binary and loads PT_LOAD segments into the
//! sparse `Memory` at their specified virtual addresses.

const std = @import("std");
const Memory = @import("memory.zig").Memory;
const MemoryLayout = @import("memory_state.zig").MemoryLayout;

pub const ElfError = error{
    InvalidMagic,
    Not32Bit,
    NotLittleEndian,
    NotRiscV,
    InvalidProgramHeader,
    BufferTooSmall,
    MissingReleaseAbiSymbol,
};

/// Information extracted from the ELF header after loading.
pub const ElfInfo = struct {
    entry_point: u32,
    segments_loaded: usize,
    stack_pointer: u32,
    global_pointer: u32,
    input_start: u32,
    input_end: u32,
    halt_flag: u32,
    output_len: u32,
    output_data: u32,
    output_end: u32,
    memory_layout: MemoryLayout,
};

// These addresses are part of the pinned Stark-V guest ABI. Linker symbols
// override them when a guest uses a custom memory layout.
pub const DEFAULT_STACK_POINTER: u32 = 0x0020_0000;
pub const DEFAULT_GLOBAL_POINTER: u32 = 0x0020_0800;
pub const DEFAULT_HALT_FLAG: u32 = 0x0010_0000;
pub const DEFAULT_OUTPUT_LEN: u32 = 0x0010_0004;
pub const DEFAULT_OUTPUT_DATA: u32 = 0x0010_0008;
pub const DEFAULT_OUTPUT_END: u32 = 0x001F_FC00;

// ELF32 constants
const ELF_MAGIC = [4]u8{ 0x7F, 'E', 'L', 'F' };
const ELFCLASS32: u8 = 1;
const ELFDATA2LSB: u8 = 1;
const EM_RISCV: u16 = 243;
const PT_LOAD: u32 = 1;

/// Complete linker contract required by the production Stark-V adapter.
pub const RELEASE_ABI_SYMBOLS = [_][]const u8{
    "__text_start",
    "__text_len",
    "__data_start",
    "__data_len",
    "__global_pointer$",
    "__stack_bottom",
    "__stack_top",
    "__input_start",
    "__input_end",
    "__halt_flag",
    "__output_len",
    "__output_data",
    "__output_end",
};

// ELF32 header offsets and sizes
const ELF_HDR_SIZE: usize = 52;
const PHDR_SIZE: usize = 32;

/// Load an ELF32 RISC-V binary into `mem`.
///
/// Returns the entry point and the number of segments loaded.
pub fn loadElf(elf_bytes: []const u8, mem: *Memory) (ElfError || error{OutOfMemory})!ElfInfo {
    try validateIdentity(elf_bytes);

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
        const p_memsz = readU32LE(phdr[20..24]);

        if (p_filesz > p_memsz or @as(usize, p_offset) + @as(usize, p_filesz) > elf_bytes.len) {
            return ElfError.InvalidProgramHeader;
        }

        const segment_data = elf_bytes[p_offset .. p_offset + p_filesz];
        mem.loadSegment(p_vaddr, segment_data);
        mem.loadZeroes(p_vaddr +% p_filesz, p_memsz - p_filesz);
        segments_loaded += 1;
    }

    const output_len = findSymbolValue(elf_bytes, "__output_len") orelse DEFAULT_OUTPUT_LEN;
    const input_start = findSymbolValue(elf_bytes, "__input_start") orelse output_len;
    const input_end = findSymbolValue(elf_bytes, "__input_end") orelse input_start;
    const halt_flag = findSymbolValue(elf_bytes, "__halt_flag") orelse DEFAULT_HALT_FLAG;
    const output_data = findSymbolValue(elf_bytes, "__output_data") orelse DEFAULT_OUTPUT_DATA;
    const output_end = findSymbolValue(elf_bytes, "__output_end") orelse DEFAULT_OUTPUT_END;
    const stack_pointer = findSymbolValue(elf_bytes, "__stack_top") orelse DEFAULT_STACK_POINTER;
    const stack_bottom = findSymbolValue(elf_bytes, "__stack_bottom") orelse if (findSymbolValue(
        elf_bytes,
        "__stack_size",
    )) |size| stack_pointer -% size else stack_pointer;
    const program_base = findSymbolValue(elf_bytes, "__text_start") orelse e_entry;
    const program_end = program_base +% (findSymbolValue(elf_bytes, "__text_len") orelse 0);
    const data_base = findSymbolValue(elf_bytes, "__data_start") orelse stack_bottom;
    const data_end = data_base +% (findSymbolValue(elf_bytes, "__data_len") orelse 0);
    var io_base = @min(halt_flag, @min(output_len, output_data));
    var io_end = @max(output_end, @max(output_data, @max(output_len, halt_flag)));
    io_end = io_end +| 1;
    if (input_start < input_end) {
        io_base = @min(io_base, input_start);
        io_end = @max(io_end, input_end);
    }
    const memory_layout = MemoryLayout{
        .program_base = program_base,
        .program_end = program_end,
        .data_base = data_base,
        .data_end = data_end,
        .stack_bottom = stack_bottom,
        .stack_top = stack_pointer,
        .io_base = io_base,
        .io_end = io_end,
        .input_base = input_start,
        .input_end = input_end,
        .output_len_addr = output_len,
        .output_data_addr = output_data,
        .output_base = output_len,
        .output_end = output_end,
    };

    return .{
        .entry_point = e_entry,
        .segments_loaded = segments_loaded,
        .stack_pointer = stack_pointer,
        .global_pointer = findSymbolValue(elf_bytes, "__global_pointer$") orelse DEFAULT_GLOBAL_POINTER,
        .input_start = input_start,
        .input_end = input_end,
        .halt_flag = halt_flag,
        .output_len = output_len,
        .output_data = output_data,
        .output_end = output_end,
        .memory_layout = memory_layout,
    };
}

/// Rejects compatibility ELFs before the production adapter starts execution.
/// `loadElf` continues to provide documented defaults for diagnostic callers.
pub fn validateReleaseAbi(elf_bytes: []const u8) ElfError!void {
    try validateIdentity(elf_bytes);
    for (RELEASE_ABI_SYMBOLS) |symbol| {
        if (findSymbolValue(elf_bytes, symbol) == null)
            return ElfError.MissingReleaseAbiSymbol;
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn readU16LE(bytes: *const [2]u8) u16 {
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}

fn validateIdentity(elf_bytes: []const u8) ElfError!void {
    if (elf_bytes.len < ELF_HDR_SIZE) return ElfError.BufferTooSmall;
    if (!std.mem.eql(u8, elf_bytes[0..4], &ELF_MAGIC)) return ElfError.InvalidMagic;
    if (elf_bytes[4] != ELFCLASS32) return ElfError.Not32Bit;
    if (elf_bytes[5] != ELFDATA2LSB) return ElfError.NotLittleEndian;
    if (readU16LE(elf_bytes[18..20]) != EM_RISCV) return ElfError.NotRiscV;
}

fn readU32LE(bytes: *const [4]u8) u32 {
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

fn findSymbolValue(elf_bytes: []const u8, wanted: []const u8) ?u32 {
    if (elf_bytes.len < ELF_HDR_SIZE) return null;
    const shoff = @as(usize, readU32LE(elf_bytes[32..36]));
    const shentsize = @as(usize, readU16LE(elf_bytes[46..48]));
    const shnum = @as(usize, readU16LE(elf_bytes[48..50]));
    if (shoff == 0 or shentsize < 40) return null;

    for (0..shnum) |i| {
        const section_offset = shoff + i * shentsize;
        if (section_offset + 40 > elf_bytes.len) return null;
        const section = elf_bytes[section_offset .. section_offset + 40];
        if (readU32LE(section[4..8]) != 2) continue; // SHT_SYMTAB

        const symbols_offset = @as(usize, readU32LE(section[16..20]));
        const symbols_size = @as(usize, readU32LE(section[20..24]));
        const string_section_index = @as(usize, readU32LE(section[24..28]));
        const symbol_size = @as(usize, readU32LE(section[36..40]));
        if (symbol_size < 16 or symbols_offset + symbols_size > elf_bytes.len) return null;
        if (string_section_index >= shnum) return null;

        const strings_header_offset = shoff + string_section_index * shentsize;
        if (strings_header_offset + 40 > elf_bytes.len) return null;
        const strings_header = elf_bytes[strings_header_offset .. strings_header_offset + 40];
        const strings_offset = @as(usize, readU32LE(strings_header[16..20]));
        const strings_size = @as(usize, readU32LE(strings_header[20..24]));
        if (strings_offset + strings_size > elf_bytes.len) return null;
        const strings = elf_bytes[strings_offset .. strings_offset + strings_size];

        var symbol_offset = symbols_offset;
        while (symbol_offset + symbol_size <= symbols_offset + symbols_size) : (symbol_offset += symbol_size) {
            const symbol = elf_bytes[symbol_offset .. symbol_offset + symbol_size];
            const name_offset = @as(usize, readU32LE(symbol[0..4]));
            if (name_offset >= strings.len) continue;
            const tail = strings[name_offset..];
            const name_end = std.mem.indexOfScalar(u8, tail, 0) orelse continue;
            if (std.mem.eql(u8, tail[0..name_end], wanted)) {
                return readU32LE(symbol[4..8]);
            }
        }
    }
    return null;
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
    try std.testing.expectEqual(DEFAULT_STACK_POINTER, info.stack_pointer);
    try std.testing.expectEqual(DEFAULT_GLOBAL_POINTER, info.global_pointer);
    try std.testing.expectEqual(DEFAULT_HALT_FLAG, info.halt_flag);
    try std.testing.expectEqual(DEFAULT_OUTPUT_LEN, info.output_len);
    try std.testing.expectEqual(DEFAULT_OUTPUT_DATA, info.output_data);
    try std.testing.expectEqual(DEFAULT_OUTPUT_END, info.output_end);
    try std.testing.expectEqual(DEFAULT_OUTPUT_LEN, info.input_start);
    try std.testing.expectEqual(DEFAULT_OUTPUT_LEN, info.input_end);
    try std.testing.expectEqual(@as(u32, 0x00010000), info.memory_layout.program_base);
    try std.testing.expectEqual(DEFAULT_HALT_FLAG, info.memory_layout.io_base);
    try std.testing.expectEqual(DEFAULT_OUTPUT_END + 1, info.memory_layout.io_end);

    // Verify the instruction was loaded at the correct address.
    try std.testing.expectEqual(@as(u32, 0x02A00093), mem.readU32(0x00010000));
}

test "release ABI preflight rejects compatibility and malformed ELFs" {
    const compatibility_elf = makeMinimalElf();
    try std.testing.expectError(
        ElfError.MissingReleaseAbiSymbol,
        validateReleaseAbi(&compatibility_elf),
    );
    try std.testing.expectError(
        ElfError.BufferTooSmall,
        validateReleaseAbi("not an ELF"),
    );
}

test "loadElf materializes unaccessed BSS words" {
    var mem = @import("memory.zig").Memory.init(std.testing.allocator);
    defer mem.deinit();

    var elf = makeMinimalElf();
    elf[72] = 8; // p_memsz exceeds the four file-backed bytes.
    _ = try loadElf(&elf, &mem);

    var addresses = std.AutoHashMap(u32, void).init(std.testing.allocator);
    defer addresses.deinit();
    try mem.addAlignedWordAddresses(&addresses);
    try std.testing.expect(addresses.contains(0x00010004));
    try std.testing.expectEqual(@as(u32, 0), mem.readU32(0x00010004));
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
