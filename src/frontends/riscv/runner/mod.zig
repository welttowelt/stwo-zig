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
pub const trace = @import("trace.zig");
pub const trace_dump = @import("trace_dump.zig");

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
    /// Execution trace for STARK proving.
    execution_trace: trace.Trace,

    pub fn deinit(self: *RunResult) void {
        self.execution_trace.deinit();
        self.* = undefined;
    }
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
    var exec_trace = trace.Trace.init(allocator);
    exec_trace.initial_pc = rv_cpu.pc;

    var steps: usize = 0;
    while (steps < max_steps) : (steps += 1) {
        const pc_before = rv_cpu.pc;
        const inst_word = mem.readU32(rv_cpu.pc);
        const inst = DecodedInst.decode(inst_word) catch break;

        // Capture pre-execution register values.
        const rs1_val = rv_cpu.readReg(inst.rs1);
        const rs2_val = rv_cpu.readReg(inst.rs2);

        // Capture memory address and value for load/store instructions
        // BEFORE execution modifies CPU state.
        var mem_addr: u32 = 0;
        var mem_val: u32 = 0;
        const is_load = switch (inst.opcode) {
            .LB, .LBU, .LH, .LHU, .LW => true,
            else => false,
        };
        const is_store = switch (inst.opcode) {
            .SB, .SH, .SW => true,
            else => false,
        };

        if (is_load or is_store) {
            mem_addr = rs1_val +% @as(u32, @bitCast(inst.imm));
            if (is_load) {
                // For loads, capture the value at the address before execution.
                mem_val = switch (inst.opcode) {
                    .LB, .LBU => @as(u32, mem.readByte(mem_addr)),
                    .LH, .LHU => @as(u32, mem.readU16(mem_addr)),
                    .LW => mem.readU32(mem_addr),
                    else => 0,
                };
            } else {
                // For stores, capture the value being stored (from rs2).
                mem_val = rs2_val;
            }
        }

        // Execute the instruction.
        var halted = false;
        execute_mod.execute(&rv_cpu, &mem, inst) catch |err| switch (err) {
            error.Ecall => {
                halted = true;
            },
            error.Ebreak => {
                halted = true;
            },
        };

        const rd_val = rv_cpu.readReg(inst.rd);

        // Record trace row.
        try exec_trace.append(.{
            .clk = @intCast(steps),
            .pc = pc_before,
            .opcode = inst.opcode,
            .rd = inst.rd,
            .rs1 = inst.rs1,
            .rs2 = inst.rs2,
            .imm = inst.imm,
            .rs1_val = rs1_val,
            .rs2_val = rs2_val,
            .rd_val = rd_val,
            .mem_addr = mem_addr,
            .mem_val = mem_val,
            .is_load = is_load,
            .is_store = is_store,
            .branch_taken = (rv_cpu.pc != pc_before + 4),
            .next_pc = rv_cpu.pc,
        });

        if (halted) break;
    }

    exec_trace.final_pc = rv_cpu.pc;

    return .{
        .cpu_final = rv_cpu,
        .step_count = steps,
        .execution_trace = exec_trace,
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

    var result = try run(std.testing.allocator, &elf_buf, 1000);
    defer result.deinit();
    try std.testing.expectEqual(@as(u32, 42), result.cpu_final.readReg(1));
    try std.testing.expectEqual(@as(usize, 2), result.step_count);
    try std.testing.expectEqual(@as(usize, 2), result.execution_trace.rows.items.len);
}

test "runner: mem_addr and mem_val captured for load/store" {
    // Build a tiny ELF that executes:
    //   0x10000: ADDI x1, x0, 0x55   (0x05500093)  -- x1 = 0x55
    //   0x10004: ADDI x2, x0, 0x100  (0x10000113)  -- x2 = 0x100 (store addr)
    //   0x10008: SW   x1, 0(x2)      (0x00112023)  -- mem[0x100] = 0x55
    //   0x1000C: LW   x3, 0(x2)      (0x00012183)  -- x3 = mem[0x100] = 0x55
    //   0x10010: ECALL                (0x00000073)
    const n_insts = 5;
    const code_size = n_insts * 4;
    const elf_size = 84 + code_size;
    var elf_buf: [elf_size]u8 = [_]u8{0} ** elf_size;

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
    const instructions = [n_insts]u32{
        0x05500093, // ADDI x1, x0, 0x55
        0x10000113, // ADDI x2, x0, 0x100
        0x00112023, // SW x1, 0(x2)
        0x00012183, // LW x3, 0(x2)
        0x00000073, // ECALL
    };
    for (instructions, 0..) |inst_word, i| {
        const offset = 84 + i * 4;
        elf_buf[offset] = @truncate(inst_word);
        elf_buf[offset + 1] = @truncate(inst_word >> 8);
        elf_buf[offset + 2] = @truncate(inst_word >> 16);
        elf_buf[offset + 3] = @truncate(inst_word >> 24);
    }

    var result = try run(std.testing.allocator, &elf_buf, 1000);
    defer result.deinit();

    const rows = result.execution_trace.rows.items;
    try std.testing.expectEqual(@as(usize, 5), rows.len);

    // Row 0: ADDI - no memory access
    try std.testing.expectEqual(@as(u32, 0), rows[0].mem_addr);
    try std.testing.expectEqual(@as(u32, 0), rows[0].mem_val);
    try std.testing.expect(!rows[0].is_load);
    try std.testing.expect(!rows[0].is_store);

    // Row 2: SW x1, 0(x2) - store addr=0x100, val=0x55
    try std.testing.expect(rows[2].is_store);
    try std.testing.expectEqual(@as(u32, 0x100), rows[2].mem_addr);
    try std.testing.expectEqual(@as(u32, 0x55), rows[2].mem_val);

    // Row 3: LW x3, 0(x2) - load addr=0x100, val=0x55
    try std.testing.expect(rows[3].is_load);
    try std.testing.expectEqual(@as(u32, 0x100), rows[3].mem_addr);
    try std.testing.expectEqual(@as(u32, 0x55), rows[3].mem_val);

    // Verify final register state
    try std.testing.expectEqual(@as(u32, 0x55), result.cpu_final.readReg(3));
}
