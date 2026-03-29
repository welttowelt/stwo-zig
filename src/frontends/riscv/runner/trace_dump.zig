//! JSON trace serialization for cross-language equivalence testing.
//!
//! Produces a JSON document compatible with the Rust stark-v trace dumper,
//! enabling bit-exact comparison of final CPU state, step count, and
//! per-step program counters between the Zig and Rust runners.
//!
//! Format:
//! ```json
//! {
//!   "steps": [{"step": 0, "pc": 65536}, {"step": 1, "pc": 65540}, ...],
//!   "final_pc": 65544,
//!   "final_regs": [0, 42, ...],   // x0..x31
//!   "total_steps": 5
//! }
//! ```

const std = @import("std");
const trace_mod = @import("trace.zig");
const cpu_mod = @import("cpu.zig");

/// Write an execution trace to JSON format.
///
/// The output captures:
///   - Per-step program counter (for divergence diagnosis)
///   - Final values of all 32 registers
///   - Final program counter
///   - Total step count
///
/// Two traces are considered *equivalent* when `total_steps`, `final_pc`,
/// and all 32 `final_regs` entries match.  Per-step PCs are included so
/// that, on mismatch, the first diverging instruction can be pinpointed.
pub fn writeTraceJson(
    writer: anytype,
    exec_trace: *const trace_mod.Trace,
    final_cpu: cpu_mod.Cpu,
) !void {
    try writer.writeAll("{\"steps\":[");
    for (exec_trace.rows.items, 0..) |row, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.print("{{\"step\":{d},\"pc\":{d}}}", .{ row.clk, row.pc });
    }
    try writer.writeAll("],");
    try writer.print("\"final_pc\":{d},\"final_regs\":[", .{final_cpu.pc});
    for (0..32) |i| {
        if (i > 0) try writer.writeAll(",");
        try writer.print("{d}", .{final_cpu.readReg(@intCast(i))});
    }
    try writer.writeAll("],");
    try writer.print("\"total_steps\":{d}}}", .{exec_trace.step_count});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const runner = @import("mod.zig");

/// Build a minimal in-memory ELF with the given instructions at vaddr 0x10000.
fn buildTestElf(comptime n_insts: usize, instructions: [n_insts]u32) [84 + n_insts * 4]u8 {
    const code_size = n_insts * 4;
    var elf_buf: [84 + code_size]u8 = [_]u8{0} ** (84 + code_size);

    // ELF header
    elf_buf[0] = 0x7F;
    elf_buf[1] = 'E';
    elf_buf[2] = 'L';
    elf_buf[3] = 'F';
    elf_buf[4] = 1; // ELFCLASS32
    elf_buf[5] = 1; // ELFDATA2LSB
    elf_buf[6] = 1; // EI_VERSION
    elf_buf[16] = 2; // e_type = ET_EXEC
    elf_buf[18] = 0xF3; // e_machine = EM_RISCV
    elf_buf[20] = 1; // e_version
    // e_entry = 0x10000
    elf_buf[24] = 0x00;
    elf_buf[25] = 0x00;
    elf_buf[26] = 0x01;
    elf_buf[27] = 0x00;
    // e_phoff = 52
    elf_buf[28] = 52;
    // e_ehsize = 52
    elf_buf[40] = 52;
    // e_phentsize = 32
    elf_buf[42] = 32;
    // e_phnum = 1
    elf_buf[44] = 1;

    // Program header at offset 52
    elf_buf[52] = 1; // p_type = PT_LOAD
    elf_buf[56] = 84; // p_offset = 84
    // p_vaddr = 0x10000
    elf_buf[60] = 0x00;
    elf_buf[61] = 0x00;
    elf_buf[62] = 0x01;
    elf_buf[63] = 0x00;
    // p_filesz
    elf_buf[68] = code_size;
    // p_memsz
    elf_buf[72] = code_size;

    // Instructions at offset 84
    for (instructions, 0..) |inst_word, i| {
        const offset = 84 + i * 4;
        elf_buf[offset] = @truncate(inst_word);
        elf_buf[offset + 1] = @truncate(inst_word >> 8);
        elf_buf[offset + 2] = @truncate(inst_word >> 16);
        elf_buf[offset + 3] = @truncate(inst_word >> 24);
    }

    return elf_buf;
}

test "trace_dump: writeTraceJson produces well-formed JSON" {
    const alloc = std.testing.allocator;

    // ADDI x1, x0, 42  then  ECALL
    const elf = buildTestElf(2, .{
        0x02A00093, // ADDI x1, x0, 42
        0x00000073, // ECALL
    });

    var result = try runner.run(alloc, &elf, 1000);
    defer result.deinit();

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(alloc);

    try writeTraceJson(buf.writer(alloc), &result.execution_trace, result.cpu_final);

    // Parse the JSON to verify it is well-formed.
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, buf.items, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    // Verify total_steps
    const total_steps = root.get("total_steps").?.integer;
    try std.testing.expectEqual(@as(i64, 2), total_steps);

    // Verify final_pc is present and numeric
    const final_pc = root.get("final_pc").?.integer;
    try std.testing.expect(final_pc > 0);

    // Verify final_regs has 32 entries
    const final_regs = root.get("final_regs").?.array;
    try std.testing.expectEqual(@as(usize, 32), final_regs.items.len);

    // x1 should be 42
    try std.testing.expectEqual(@as(i64, 42), final_regs.items[1].integer);

    // x0 is always 0
    try std.testing.expectEqual(@as(i64, 0), final_regs.items[0].integer);

    // Verify steps array has 2 entries with correct PCs
    const steps = root.get("steps").?.array;
    try std.testing.expectEqual(@as(usize, 2), steps.items.len);
    try std.testing.expectEqual(@as(i64, 0x10000), steps.items[0].object.get("pc").?.integer);
    try std.testing.expectEqual(@as(i64, 0x10004), steps.items[1].object.get("pc").?.integer);
}

test "trace_dump: multi-instruction trace with register side-effects" {
    const alloc = std.testing.allocator;

    // x1 = 10, x2 = 20, x3 = x1 + x2 = 30, ECALL
    const elf = buildTestElf(4, .{
        0x00A00093, // ADDI x1, x0, 10
        0x01400113, // ADDI x2, x0, 20
        0x002081B3, // ADD  x3, x1, x2
        0x00000073, // ECALL
    });

    var result = try runner.run(alloc, &elf, 1000);
    defer result.deinit();

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(alloc);

    try writeTraceJson(buf.writer(alloc), &result.execution_trace, result.cpu_final);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, buf.items, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const final_regs = root.get("final_regs").?.array;

    // x1=10, x2=20, x3=30
    try std.testing.expectEqual(@as(i64, 10), final_regs.items[1].integer);
    try std.testing.expectEqual(@as(i64, 20), final_regs.items[2].integer);
    try std.testing.expectEqual(@as(i64, 30), final_regs.items[3].integer);

    const total_steps = root.get("total_steps").?.integer;
    try std.testing.expectEqual(@as(i64, 4), total_steps);
}
