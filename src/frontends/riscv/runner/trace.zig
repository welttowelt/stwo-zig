//! Trace capture for RISC-V execution.
//!
//! Records per-instruction state snapshots during execution for use
//! by the STARK prover. Each trace row captures the CPU state before
//! and after instruction execution, plus the decoded instruction fields.

const std = @import("std");
const cpu_mod = @import("cpu.zig");
const decode_mod = @import("decode.zig");
const M31 = @import("../../../core/fields/m31.zig").M31;

const Cpu = cpu_mod.Cpu;
const Opcode = decode_mod.Opcode;
const DecodedInst = decode_mod.DecodedInst;

/// A single trace row recording one instruction's execution.
pub const TraceRow = struct {
    /// Clock cycle (step number).
    clk: u32,
    /// Program counter before execution.
    pc: u32,
    /// Decoded opcode.
    opcode: Opcode,
    /// Destination register index.
    rd: u5,
    /// Source register 1 index.
    rs1: u5,
    /// Source register 2 index.
    rs2: u5,
    /// Immediate value.
    imm: i32,
    /// Register values before execution.
    rs1_val: u32,
    rs2_val: u32,
    /// Register value written (rd_val after execution).
    rd_val: u32,
    /// Memory address accessed (0 if no memory access).
    mem_addr: u32,
    /// Memory value read/written (0 if no memory access).
    mem_val: u32,
    /// Whether this was a memory load.
    is_load: bool,
    /// Whether this was a memory store.
    is_store: bool,
    /// Whether a branch was taken.
    branch_taken: bool,
    /// PC after execution (next_pc).
    next_pc: u32,
};

/// Accumulated execution trace.
pub const Trace = struct {
    rows: std.ArrayList(TraceRow),
    initial_pc: u32,
    final_pc: u32,
    step_count: usize,

    pub fn init(allocator: std.mem.Allocator) Trace {
        return .{
            .rows = std.ArrayList(TraceRow).init(allocator),
            .initial_pc = 0,
            .final_pc = 0,
            .step_count = 0,
        };
    }

    pub fn deinit(self: *Trace) void {
        self.rows.deinit();
        self.* = undefined;
    }

    /// Append a trace row.
    pub fn append(self: *Trace, row: TraceRow) !void {
        try self.rows.append(row);
        self.step_count = self.rows.items.len;
    }

    /// Group trace rows by opcode family for per-component trace generation.
    pub fn groupByOpcodeFamily(self: *const Trace, allocator: std.mem.Allocator) !OpcodeFamilyCounts {
        var counts = OpcodeFamilyCounts{};
        for (self.rows.items) |row| {
            counts.increment(opcodeFamily(row.opcode));
        }
        _ = allocator;
        return counts;
    }

    /// Generate M31 columns for a specific opcode family.
    /// Returns columns in the order: clk, pc, rd, rs1, rs2, rs1_val, rs2_val, rd_val, ...flags
    pub fn columnsForFamily(
        self: *const Trace,
        allocator: std.mem.Allocator,
        family: OpcodeFamily,
        log_size: u32,
    ) !TraceColumns {
        const domain_size = @as(usize, 1) << @intCast(log_size);
        const n_cols = 10; // Basic columns: clk, pc, rd, rs1, rs2, rs1_val, rs2_val, rd_val, enabler, next_pc

        var columns: [n_cols][]M31 = undefined;
        for (0..n_cols) |i| {
            columns[i] = try allocator.alloc(M31, domain_size);
            @memset(columns[i], M31.zero());
        }

        var row_idx: usize = 0;
        for (self.rows.items) |row| {
            if (opcodeFamily(row.opcode) != family) continue;
            if (row_idx >= domain_size) break;

            columns[0][row_idx] = M31.fromCanonical(row.clk);
            columns[1][row_idx] = M31.fromCanonical(row.pc);
            columns[2][row_idx] = M31.fromCanonical(@as(u32, row.rd));
            columns[3][row_idx] = M31.fromCanonical(@as(u32, row.rs1));
            columns[4][row_idx] = M31.fromCanonical(@as(u32, row.rs2));
            columns[5][row_idx] = M31.fromCanonical(row.rs1_val);
            columns[6][row_idx] = M31.fromCanonical(row.rs2_val);
            columns[7][row_idx] = M31.fromCanonical(row.rd_val);
            columns[8][row_idx] = M31.one(); // enabler = 1 for real rows
            columns[9][row_idx] = M31.fromCanonical(row.next_pc);
            row_idx += 1;
        }

        return .{ .columns = columns, .n_real_rows = row_idx };
    }
};

pub const TraceColumns = struct {
    columns: [10][]M31,
    n_real_rows: usize,

    pub fn deinit(self: *TraceColumns, allocator: std.mem.Allocator) void {
        for (&self.columns) |col| allocator.free(col);
        self.* = undefined;
    }
};

/// The 16 stark-v opcode families.
pub const OpcodeFamily = enum(u8) {
    base_alu_reg,
    base_alu_imm,
    shifts_reg,
    shifts_imm,
    lt_reg,
    lt_imm,
    branch_eq,
    branch_lt,
    lui,
    auipc,
    jalr,
    jal,
    load_store,
    mul,
    mulh,
    div,
};

pub const N_FAMILIES: usize = @typeInfo(OpcodeFamily).@"enum".fields.len;

/// Map an opcode to its family.
pub fn opcodeFamily(op: Opcode) OpcodeFamily {
    return switch (op) {
        .ADD, .SUB, .XOR, .OR, .AND => .base_alu_reg,
        .ADDI, .XORI, .ORI, .ANDI => .base_alu_imm,
        .SLL, .SRL, .SRA => .shifts_reg,
        .SLLI, .SRLI, .SRAI => .shifts_imm,
        .SLT, .SLTU => .lt_reg,
        .SLTI, .SLTIU => .lt_imm,
        .BEQ, .BNE => .branch_eq,
        .BLT, .BGE, .BLTU, .BGEU => .branch_lt,
        .LUI => .lui,
        .AUIPC => .auipc,
        .JALR => .jalr,
        .JAL => .jal,
        .LB, .LBU, .LH, .LHU, .LW, .SB, .SH, .SW => .load_store,
        .MUL => .mul,
        .MULH, .MULHSU, .MULHU => .mulh,
        .DIV, .DIVU, .REM, .REMU => .div,
        .ECALL, .EBREAK => .base_alu_reg, // fallback
    };
}

pub const OpcodeFamilyCounts = struct {
    counts: [N_FAMILIES]usize = .{0} ** N_FAMILIES,

    pub fn increment(self: *OpcodeFamilyCounts, family: OpcodeFamily) void {
        self.counts[@intFromEnum(family)] += 1;
    }

    pub fn get(self: *const OpcodeFamilyCounts, family: OpcodeFamily) usize {
        return self.counts[@intFromEnum(family)];
    }

    pub fn total(self: *const OpcodeFamilyCounts) usize {
        var t: usize = 0;
        for (self.counts) |c| t += c;
        return t;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "trace: opcodeFamily mapping" {
    try std.testing.expectEqual(OpcodeFamily.base_alu_reg, opcodeFamily(.ADD));
    try std.testing.expectEqual(OpcodeFamily.base_alu_reg, opcodeFamily(.SUB));
    try std.testing.expectEqual(OpcodeFamily.base_alu_imm, opcodeFamily(.ADDI));
    try std.testing.expectEqual(OpcodeFamily.shifts_reg, opcodeFamily(.SLL));
    try std.testing.expectEqual(OpcodeFamily.branch_eq, opcodeFamily(.BEQ));
    try std.testing.expectEqual(OpcodeFamily.load_store, opcodeFamily(.LW));
    try std.testing.expectEqual(OpcodeFamily.load_store, opcodeFamily(.SW));
    try std.testing.expectEqual(OpcodeFamily.mul, opcodeFamily(.MUL));
    try std.testing.expectEqual(OpcodeFamily.div, opcodeFamily(.DIV));
    try std.testing.expectEqual(OpcodeFamily.jal, opcodeFamily(.JAL));
    try std.testing.expectEqual(OpcodeFamily.lui, opcodeFamily(.LUI));
}

test "trace: OpcodeFamilyCounts" {
    var counts = OpcodeFamilyCounts{};
    counts.increment(.base_alu_reg);
    counts.increment(.base_alu_reg);
    counts.increment(.jal);
    try std.testing.expectEqual(@as(usize, 2), counts.get(.base_alu_reg));
    try std.testing.expectEqual(@as(usize, 1), counts.get(.jal));
    try std.testing.expectEqual(@as(usize, 3), counts.total());
}

test "trace: Trace append and grouping" {
    const alloc = std.testing.allocator;
    var t = Trace.init(alloc);
    defer t.deinit();

    try t.append(.{
        .clk = 0, .pc = 0x1000, .opcode = .ADD,
        .rd = 1, .rs1 = 2, .rs2 = 3, .imm = 0,
        .rs1_val = 10, .rs2_val = 20, .rd_val = 30,
        .mem_addr = 0, .mem_val = 0,
        .is_load = false, .is_store = false,
        .branch_taken = false, .next_pc = 0x1004,
    });
    try t.append(.{
        .clk = 1, .pc = 0x1004, .opcode = .ADDI,
        .rd = 4, .rs1 = 1, .rs2 = 0, .imm = 5,
        .rs1_val = 30, .rs2_val = 0, .rd_val = 35,
        .mem_addr = 0, .mem_val = 0,
        .is_load = false, .is_store = false,
        .branch_taken = false, .next_pc = 0x1008,
    });

    const counts = try t.groupByOpcodeFamily(alloc);
    try std.testing.expectEqual(@as(usize, 1), counts.get(.base_alu_reg));
    try std.testing.expectEqual(@as(usize, 1), counts.get(.base_alu_imm));
    try std.testing.expectEqual(@as(usize, 2), counts.total());
}
