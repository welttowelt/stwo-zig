//! RISC-V RV32IM runner — fetch/decode/execute loop with ELF loading.
//!
//! Provides a complete functional simulator for RV32IM programs.
//! Trace generation for STARK proving will be added in a later pass.

const std = @import("std");
pub const cpu = @import("cpu.zig");
pub const decode = @import("decode.zig");
pub const memory = @import("memory.zig");
pub const execute_mod = @import("execute.zig");
pub const elf_loader = @import("elf_loader.zig");

pub const Cpu = cpu.Cpu;
pub const Memory = memory.Memory;
pub const DecodedInst = decode.DecodedInst;
pub const Opcode = decode.Opcode;

/// Result of running a RISC-V program to completion.
pub const RunResult = struct {
    /// Final CPU state after execution halts.
    cpu_final: Cpu,
    /// Number of instructions executed.
    step_count: usize,
    // Trace data for STARK proving will be added later.
};

/// Run a RISC-V ELF program to completion (or until `max_steps`).
///
/// The program terminates when an ECALL instruction is encountered
/// or when `max_steps` is reached.
pub fn run(allocator: std.mem.Allocator, elf_bytes: []const u8, max_steps: usize) !RunResult {
    var mem = Memory.init(allocator);
    defer mem.deinit();

    const elf_info = try elf_loader.loadElf(elf_bytes, &mem);
    const default_stack: u32 = 0x7FFF_0000;
    var rv_cpu = Cpu.init(elf_info.entry_point, default_stack);

    var steps: usize = 0;
    while (steps < max_steps) : (steps += 1) {
        const inst_word = mem.readU32(rv_cpu.pc);
        const inst = DecodedInst.decode(inst_word) catch |err| {
            _ = err;
            break; // illegal instruction — halt
        };
        execute_mod.execute(&rv_cpu, &mem, inst) catch |err| switch (err) {
            error.Ecall => break,
            error.Ebreak => break,
        };
    }

    return .{
        .cpu_final = rv_cpu,
        .step_count = steps,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "runner: run minimal ELF to ecall" {
    // Build a tiny ELF that executes:
    //   0x10000: ADDI x1, x0, 42   (0x02A00093)
    //   0x10004: ECALL              (0x00000073)
    var mem_for_elf = Memory.init(std.testing.allocator);
    defer mem_for_elf.deinit();

    // We'll construct the ELF in-memory with 2 instructions.
    var elf_buf: [92]u8 = [_]u8{0} ** 92;

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
    // p_filesz = 8 (2 instructions)
    elf_buf[68] = 8;
    // p_memsz = 8
    elf_buf[72] = 8;

    // Instructions at offset 84
    // ADDI x1, x0, 42 = 0x02A00093
    elf_buf[84] = 0x93;
    elf_buf[85] = 0x00;
    elf_buf[86] = 0xA0;
    elf_buf[87] = 0x02;
    // ECALL = 0x00000073
    elf_buf[88] = 0x73;
    elf_buf[89] = 0x00;
    elf_buf[90] = 0x00;
    elf_buf[91] = 0x00;

    const result = try run(std.testing.allocator, &elf_buf, 1000);
    try std.testing.expectEqual(@as(u32, 42), result.cpu_final.readReg(1));
    try std.testing.expectEqual(@as(usize, 2), result.step_count);
}
