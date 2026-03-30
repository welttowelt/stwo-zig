//! Trace capture for RISC-V execution.
//!
//! Records per-instruction state snapshots during execution for use
//! by the STARK prover. Each trace row captures the CPU state before
//! and after instruction execution, plus the decoded instruction fields.

const std = @import("std");
const cpu_mod = @import("cpu.zig");
const decode_mod = @import("decode.zig");
const M31 = @import("../../../core/fields/m31.zig").M31;
const trace_columns = @import("../air/trace_columns.zig");

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
    allocator: std.mem.Allocator,
    initial_pc: u32,
    final_pc: u32,
    step_count: usize,

    pub fn init(allocator: std.mem.Allocator) Trace {
        return .{
            .rows = .{},
            .allocator = allocator,
            .initial_pc = 0,
            .final_pc = 0,
            .step_count = 0,
        };
    }

    pub fn deinit(self: *Trace) void {
        self.rows.deinit(self.allocator);
        self.* = undefined;
    }

    /// Append a trace row.
    pub fn append(self: *Trace, row: TraceRow) !void {
        try self.rows.append(self.allocator, row);
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
        const n_cols = nColumnsForFamily(family);

        var columns: [MAX_FAMILY_COLUMNS][]M31 = undefined;
        var initialized: usize = 0;
        errdefer {
            for (0..initialized) |i| allocator.free(columns[i]);
        }
        for (0..n_cols) |i| {
            columns[i] = try allocator.alloc(M31, domain_size);
            @memset(columns[i], M31.zero());
            initialized = i + 1;
        }

        var row_idx: usize = 0;
        for (self.rows.items) |row| {
            if (opcodeFamily(row.opcode) != family) continue;
            if (row_idx >= domain_size) break;

            fillFamilyColumns(&columns, row_idx, row, family);
            row_idx += 1;
        }

        return .{ .columns = columns, .n_columns = n_cols, .n_real_rows = row_idx };
    }
};

/// Maximum number of columns across all opcode families.
pub const MAX_FAMILY_COLUMNS: usize = 25; // LoadStoreColumns has the most

pub const TraceColumns = struct {
    columns: [MAX_FAMILY_COLUMNS][]M31,
    n_columns: usize,
    n_real_rows: usize,

    pub fn deinit(self: *TraceColumns, allocator: std.mem.Allocator) void {
        for (0..self.n_columns) |i| allocator.free(self.columns[i]);
        self.* = undefined;
    }
};

/// Return the number of trace columns for a given opcode family,
/// matching the column layout defined in air/trace_columns.zig.
pub fn nColumnsForFamily(family: OpcodeFamily) u32 {
    return switch (family) {
        .base_alu_reg => trace_columns.BaseAluRegColumns.N_COLUMNS,
        .base_alu_imm => trace_columns.BaseAluImmColumns.N_COLUMNS,
        .shifts_reg => trace_columns.ShiftsRegColumns.N_COLUMNS,
        .shifts_imm => trace_columns.ShiftsImmColumns.N_COLUMNS,
        .lt_reg => trace_columns.LtRegColumns.N_COLUMNS,
        .lt_imm => trace_columns.LtImmColumns.N_COLUMNS,
        .branch_eq => trace_columns.BranchEqColumns.N_COLUMNS,
        .branch_lt => trace_columns.BranchLtColumns.N_COLUMNS,
        .lui => trace_columns.LuiColumns.N_COLUMNS,
        .auipc => trace_columns.AuipcColumns.N_COLUMNS,
        .jalr => trace_columns.JalrColumns.N_COLUMNS,
        .jal => trace_columns.JalColumns.N_COLUMNS,
        .load_store => trace_columns.LoadStoreColumns.N_COLUMNS,
        .mul => trace_columns.MulColumns.N_COLUMNS,
        .mulh => trace_columns.MulhColumns.N_COLUMNS,
        .div => trace_columns.DivColumns.N_COLUMNS,
    };
}

/// Helper to cast a signed imm to M31 (field element).
/// Negative values are mapped to P - |imm| (modular negation).
fn immToM31(imm: i32) M31 {
    if (imm >= 0) {
        return M31.fromU64(@intCast(imm));
    } else {
        // M31 modulus is 2^31 - 1. Map negative to mod-reduced positive.
        const abs: u32 = @intCast(-@as(i64, imm));
        return M31.zero().sub(M31.fromU64(abs));
    }
}

/// Convert a u32 RISC-V value to M31 with proper modular reduction.
inline fn u32ToM31(v: u32) M31 {
    return M31.fromU64(v);
}

/// Fill family-specific column data for a single trace row at the given index.
/// Column ordering must match the struct field order in air/trace_columns.zig.
/// All u32 values from the execution trace are reduced modulo P via u32ToM31.
pub fn fillFamilyColumns(
    columns: *[MAX_FAMILY_COLUMNS][]M31,
    row_idx: usize,
    row: TraceRow,
    family: OpcodeFamily,
) void {
    switch (family) {
        .base_alu_reg => {
            // BaseAluRegColumns: clk, pc, rd, rs1, rs2, rd_val, rs1_val, rs2_val,
            //   result, is_add, is_sub, is_xor, is_or, is_and, enabler, instruction_word
            const rs1m = u32ToM31(row.rs1_val);
            const rs2m = u32ToM31(row.rs2_val);
            const is_add: bool = (row.opcode == .ADD);
            const is_sub: bool = (row.opcode == .SUB);
            const is_xor: bool = (row.opcode == .XOR);
            const is_or: bool = (row.opcode == .OR);
            const is_and: bool = (row.opcode == .AND);
            const is_real = is_add or is_sub or is_xor or is_or or is_and;
            // result computed in M31 arithmetic so constraints hold
            const result = if (is_add) rs1m.add(rs2m) else if (is_sub) rs1m.sub(rs2m) else u32ToM31(row.rd_val);
            columns[0][row_idx] = u32ToM31(row.clk);
            columns[1][row_idx] = u32ToM31(row.pc);
            columns[2][row_idx] = M31.fromCanonical(@as(u32, row.rd));
            columns[3][row_idx] = M31.fromCanonical(@as(u32, row.rs1));
            columns[4][row_idx] = M31.fromCanonical(@as(u32, row.rs2));
            columns[5][row_idx] = u32ToM31(row.rd_val);
            columns[6][row_idx] = rs1m;
            columns[7][row_idx] = rs2m;
            columns[8][row_idx] = result;
            columns[9][row_idx] = if (is_add) M31.one() else M31.zero();
            columns[10][row_idx] = if (is_sub) M31.one() else M31.zero();
            columns[11][row_idx] = if (is_xor) M31.one() else M31.zero();
            columns[12][row_idx] = if (is_or) M31.one() else M31.zero();
            columns[13][row_idx] = if (is_and) M31.one() else M31.zero();
            columns[14][row_idx] = if (is_real) M31.one() else M31.zero(); // enabler
            columns[15][row_idx] = M31.zero(); // instruction_word (placeholder)
        },
        .base_alu_imm => {
            // BaseAluImmColumns: clk, pc, rd, rs1, imm, rd_val, rs1_val, result,
            //   is_addi, is_xori, is_ori, is_andi, enabler, imm_sign, instruction_word
            const rs1m = u32ToM31(row.rs1_val);
            const immm = immToM31(row.imm);
            // For ADDI, result = rs1_val + imm in M31 arithmetic
            const result = switch (row.opcode) {
                .ADDI => rs1m.add(immm),
                else => u32ToM31(row.rd_val), // bitwise ops use rd_val directly
            };
            columns[0][row_idx] = u32ToM31(row.clk);
            columns[1][row_idx] = u32ToM31(row.pc);
            columns[2][row_idx] = M31.fromCanonical(@as(u32, row.rd));
            columns[3][row_idx] = M31.fromCanonical(@as(u32, row.rs1));
            columns[4][row_idx] = immm;
            columns[5][row_idx] = u32ToM31(row.rd_val);
            columns[6][row_idx] = rs1m;
            columns[7][row_idx] = result;
            columns[8][row_idx] = if (row.opcode == .ADDI) M31.one() else M31.zero();
            columns[9][row_idx] = if (row.opcode == .XORI) M31.one() else M31.zero();
            columns[10][row_idx] = if (row.opcode == .ORI) M31.one() else M31.zero();
            columns[11][row_idx] = if (row.opcode == .ANDI) M31.one() else M31.zero();
            columns[12][row_idx] = M31.one(); // enabler
            columns[13][row_idx] = if (row.imm < 0) M31.one() else M31.zero();
            columns[14][row_idx] = M31.zero(); // instruction_word (placeholder)
        },
        .branch_eq => {
            // BranchEqColumns: clk, pc, rs1, rs2, rs1_val, rs2_val, is_beq, is_bne,
            //   enabler, branch_target, diff, diff_inv, is_equal, instruction_word
            const rs1m = u32ToM31(row.rs1_val);
            const rs2m = u32ToM31(row.rs2_val);
            const diff_m31 = rs1m.sub(rs2m); // diff in M31 arithmetic
            const is_eq: bool = (row.rs1_val == row.rs2_val);
            const target: u32 = @bitCast(@as(i32, @bitCast(row.pc)) +% row.imm);
            columns[0][row_idx] = u32ToM31(row.clk);
            columns[1][row_idx] = u32ToM31(row.pc);
            columns[2][row_idx] = M31.fromCanonical(@as(u32, row.rs1));
            columns[3][row_idx] = M31.fromCanonical(@as(u32, row.rs2));
            columns[4][row_idx] = rs1m;
            columns[5][row_idx] = rs2m;
            columns[6][row_idx] = if (row.opcode == .BEQ) M31.one() else M31.zero();
            columns[7][row_idx] = if (row.opcode == .BNE) M31.one() else M31.zero();
            columns[8][row_idx] = M31.one(); // enabler
            columns[9][row_idx] = u32ToM31(target);
            columns[10][row_idx] = diff_m31;
            // diff_inv: multiplicative inverse in M31 (0 if diff=0)
            columns[11][row_idx] = if (!diff_m31.isZero()) diff_m31.invUncheckedNonZero() else M31.zero();
            columns[12][row_idx] = if (is_eq) M31.one() else M31.zero();
            columns[13][row_idx] = M31.zero(); // instruction_word (placeholder)
        },
        .lui => {
            // LuiColumns: clk, pc, rd, rd_val, imm_u, result, enabler,
            //   result_lo, result_hi, instruction_word
            const result_val = row.rd_val;
            columns[0][row_idx] = u32ToM31(row.clk);
            columns[1][row_idx] = u32ToM31(row.pc);
            columns[2][row_idx] = M31.fromCanonical(@as(u32, row.rd));
            columns[3][row_idx] = u32ToM31(row.rd_val);
            columns[4][row_idx] = M31.fromCanonical(result_val >> 12); // imm_u fits in 20 bits
            columns[5][row_idx] = u32ToM31(result_val); // result
            columns[6][row_idx] = M31.one(); // enabler
            columns[7][row_idx] = M31.fromCanonical(result_val & 0xFFFF); // result_lo
            columns[8][row_idx] = M31.fromCanonical(result_val >> 16); // result_hi (max 16 bits)
            columns[9][row_idx] = M31.zero(); // instruction_word (placeholder)
        },
        .auipc => {
            // AuipcColumns: same layout as LUI
            const result_val = row.rd_val;
            columns[0][row_idx] = u32ToM31(row.clk);
            columns[1][row_idx] = u32ToM31(row.pc);
            columns[2][row_idx] = M31.fromCanonical(@as(u32, row.rd));
            columns[3][row_idx] = u32ToM31(row.rd_val);
            // imm_u for AUIPC: (result - pc) >> 12 may be large, use fromU64
            const imm_bits: u32 = @bitCast(@as(i32, @bitCast(result_val)) -% @as(i32, @bitCast(row.pc)));
            columns[4][row_idx] = u32ToM31(imm_bits);
            columns[5][row_idx] = u32ToM31(result_val);
            columns[6][row_idx] = M31.one();
            columns[7][row_idx] = M31.fromCanonical(result_val & 0xFFFF);
            columns[8][row_idx] = M31.fromCanonical(result_val >> 16);
            columns[9][row_idx] = M31.zero();
        },
        .jal => {
            // JalColumns: clk, pc, rd, rd_val, imm_j, target, enabler,
            //   target_lo, target_hi, instruction_word
            const target_val = row.next_pc;
            columns[0][row_idx] = u32ToM31(row.clk);
            columns[1][row_idx] = u32ToM31(row.pc);
            columns[2][row_idx] = M31.fromCanonical(@as(u32, row.rd));
            columns[3][row_idx] = u32ToM31(row.rd_val);
            columns[4][row_idx] = immToM31(row.imm);
            columns[5][row_idx] = u32ToM31(target_val);
            columns[6][row_idx] = M31.one();
            columns[7][row_idx] = M31.fromCanonical(target_val & 0xFFFF);
            columns[8][row_idx] = M31.fromCanonical(target_val >> 16);
            columns[9][row_idx] = M31.zero();
        },
        .jalr => {
            // JalrColumns: clk, pc, rd, rs1, imm, rd_val, rs1_val, target,
            //   enabler, target_lo, target_hi, instruction_word
            const target_val = row.next_pc;
            columns[0][row_idx] = u32ToM31(row.clk);
            columns[1][row_idx] = u32ToM31(row.pc);
            columns[2][row_idx] = M31.fromCanonical(@as(u32, row.rd));
            columns[3][row_idx] = M31.fromCanonical(@as(u32, row.rs1));
            columns[4][row_idx] = immToM31(row.imm);
            columns[5][row_idx] = u32ToM31(row.rd_val);
            columns[6][row_idx] = u32ToM31(row.rs1_val);
            columns[7][row_idx] = u32ToM31(target_val);
            columns[8][row_idx] = M31.one();
            columns[9][row_idx] = M31.fromCanonical(target_val & 0xFFFF);
            columns[10][row_idx] = M31.fromCanonical(target_val >> 16);
            columns[11][row_idx] = M31.zero();
        },
        .load_store => {
            // LoadStoreColumns: clk, pc, rd, rs1, rs2, imm, rd_val, rs1_val, rs2_val,
            //   mem_addr, mem_val, is_lb..is_sw, enabler, byte_0..byte_3, instruction_word
            columns[0][row_idx] = u32ToM31(row.clk);
            columns[1][row_idx] = u32ToM31(row.pc);
            columns[2][row_idx] = M31.fromCanonical(@as(u32, row.rd));
            columns[3][row_idx] = M31.fromCanonical(@as(u32, row.rs1));
            columns[4][row_idx] = M31.fromCanonical(@as(u32, row.rs2));
            columns[5][row_idx] = immToM31(row.imm);
            columns[6][row_idx] = u32ToM31(row.rd_val);
            columns[7][row_idx] = u32ToM31(row.rs1_val);
            columns[8][row_idx] = u32ToM31(row.rs2_val);
            columns[9][row_idx] = u32ToM31(row.mem_addr);
            columns[10][row_idx] = u32ToM31(row.mem_val);
            columns[11][row_idx] = if (row.opcode == .LB) M31.one() else M31.zero();
            columns[12][row_idx] = if (row.opcode == .LBU) M31.one() else M31.zero();
            columns[13][row_idx] = if (row.opcode == .LH) M31.one() else M31.zero();
            columns[14][row_idx] = if (row.opcode == .LHU) M31.one() else M31.zero();
            columns[15][row_idx] = if (row.opcode == .LW) M31.one() else M31.zero();
            columns[16][row_idx] = if (row.opcode == .SB) M31.one() else M31.zero();
            columns[17][row_idx] = if (row.opcode == .SH) M31.one() else M31.zero();
            columns[18][row_idx] = if (row.opcode == .SW) M31.one() else M31.zero();
            columns[19][row_idx] = M31.one(); // enabler
            columns[20][row_idx] = M31.fromCanonical(row.mem_val & 0xFF);
            columns[21][row_idx] = M31.fromCanonical((row.mem_val >> 8) & 0xFF);
            columns[22][row_idx] = M31.fromCanonical((row.mem_val >> 16) & 0xFF);
            columns[23][row_idx] = M31.fromCanonical((row.mem_val >> 24) & 0xFF);
            columns[24][row_idx] = M31.zero(); // instruction_word (placeholder)
        },
        .shifts_reg => {
            const shamt: u5 = @truncate(row.rs2_val);
            columns[0][row_idx] = u32ToM31(row.clk);
            columns[1][row_idx] = u32ToM31(row.pc);
            columns[2][row_idx] = M31.fromCanonical(@as(u32, row.rd));
            columns[3][row_idx] = M31.fromCanonical(@as(u32, row.rs1));
            columns[4][row_idx] = M31.fromCanonical(@as(u32, row.rs2));
            columns[5][row_idx] = u32ToM31(row.rd_val);
            columns[6][row_idx] = u32ToM31(row.rs1_val);
            columns[7][row_idx] = u32ToM31(row.rs2_val);
            columns[8][row_idx] = u32ToM31(row.rd_val); // result
            columns[9][row_idx] = if (row.opcode == .SLL) M31.one() else M31.zero();
            columns[10][row_idx] = if (row.opcode == .SRL) M31.one() else M31.zero();
            columns[11][row_idx] = if (row.opcode == .SRA) M31.one() else M31.zero();
            columns[12][row_idx] = M31.one();
            columns[13][row_idx] = M31.fromCanonical(@as(u32, shamt));
            columns[14][row_idx] = M31.fromCanonical(32 - @as(u32, shamt));
            columns[15][row_idx] = M31.fromCanonical(row.rd_val & 0xFFFF);
            columns[16][row_idx] = M31.fromCanonical(row.rd_val >> 16);
            columns[17][row_idx] = M31.zero();
        },
        .shifts_imm => {
            const shamt: u5 = @truncate(@as(u32, @bitCast(row.imm)));
            columns[0][row_idx] = u32ToM31(row.clk);
            columns[1][row_idx] = u32ToM31(row.pc);
            columns[2][row_idx] = M31.fromCanonical(@as(u32, row.rd));
            columns[3][row_idx] = M31.fromCanonical(@as(u32, row.rs1));
            columns[4][row_idx] = immToM31(row.imm);
            columns[5][row_idx] = u32ToM31(row.rd_val);
            columns[6][row_idx] = u32ToM31(row.rs1_val);
            columns[7][row_idx] = u32ToM31(row.rd_val);
            columns[8][row_idx] = if (row.opcode == .SLLI) M31.one() else M31.zero();
            columns[9][row_idx] = if (row.opcode == .SRLI) M31.one() else M31.zero();
            columns[10][row_idx] = if (row.opcode == .SRAI) M31.one() else M31.zero();
            columns[11][row_idx] = M31.one();
            columns[12][row_idx] = M31.fromCanonical(@as(u32, shamt));
            columns[13][row_idx] = M31.fromCanonical(32 - @as(u32, shamt));
            columns[14][row_idx] = M31.fromCanonical(row.rd_val & 0xFFFF);
            columns[15][row_idx] = M31.fromCanonical(row.rd_val >> 16);
            columns[16][row_idx] = M31.fromCanonical(row.rs1_val >> 31);
            columns[17][row_idx] = M31.zero();
        },
        .lt_reg => {
            columns[0][row_idx] = u32ToM31(row.clk);
            columns[1][row_idx] = u32ToM31(row.pc);
            columns[2][row_idx] = M31.fromCanonical(@as(u32, row.rd));
            columns[3][row_idx] = M31.fromCanonical(@as(u32, row.rs1));
            columns[4][row_idx] = M31.fromCanonical(@as(u32, row.rs2));
            columns[5][row_idx] = u32ToM31(row.rd_val);
            columns[6][row_idx] = u32ToM31(row.rs1_val);
            columns[7][row_idx] = u32ToM31(row.rs2_val);
            columns[8][row_idx] = u32ToM31(row.rd_val);
            columns[9][row_idx] = if (row.opcode == .SLT) M31.one() else M31.zero();
            columns[10][row_idx] = if (row.opcode == .SLTU) M31.one() else M31.zero();
            columns[11][row_idx] = M31.one();
            const diff = row.rs1_val -% row.rs2_val;
            columns[12][row_idx] = M31.fromCanonical(diff & 0xFFFF);
            columns[13][row_idx] = M31.fromCanonical(diff >> 16);
            columns[14][row_idx] = M31.zero();
        },
        .lt_imm => {
            const imm_u32: u32 = @bitCast(row.imm);
            const diff = row.rs1_val -% imm_u32;
            columns[0][row_idx] = u32ToM31(row.clk);
            columns[1][row_idx] = u32ToM31(row.pc);
            columns[2][row_idx] = M31.fromCanonical(@as(u32, row.rd));
            columns[3][row_idx] = M31.fromCanonical(@as(u32, row.rs1));
            columns[4][row_idx] = immToM31(row.imm);
            columns[5][row_idx] = u32ToM31(row.rd_val);
            columns[6][row_idx] = u32ToM31(row.rs1_val);
            columns[7][row_idx] = u32ToM31(row.rd_val);
            columns[8][row_idx] = if (row.opcode == .SLTI) M31.one() else M31.zero();
            columns[9][row_idx] = if (row.opcode == .SLTIU) M31.one() else M31.zero();
            columns[10][row_idx] = M31.one();
            columns[11][row_idx] = M31.fromCanonical(diff & 0xFFFF);
            columns[12][row_idx] = M31.fromCanonical(diff >> 16);
            columns[13][row_idx] = if (row.imm < 0) M31.one() else M31.zero();
            columns[14][row_idx] = M31.zero();
        },
        .branch_lt => {
            const diff = row.rs1_val -% row.rs2_val;
            const target_val: u32 = @bitCast(@as(i32, @bitCast(row.pc)) +% row.imm);
            const is_lt: bool = switch (row.opcode) {
                .BLT => @as(i32, @bitCast(row.rs1_val)) < @as(i32, @bitCast(row.rs2_val)),
                .BLTU => row.rs1_val < row.rs2_val,
                .BGE => @as(i32, @bitCast(row.rs1_val)) < @as(i32, @bitCast(row.rs2_val)),
                .BGEU => row.rs1_val < row.rs2_val,
                else => false,
            };
            columns[0][row_idx] = u32ToM31(row.clk);
            columns[1][row_idx] = u32ToM31(row.pc);
            columns[2][row_idx] = M31.fromCanonical(@as(u32, row.rs1));
            columns[3][row_idx] = M31.fromCanonical(@as(u32, row.rs2));
            columns[4][row_idx] = u32ToM31(row.rs1_val);
            columns[5][row_idx] = u32ToM31(row.rs2_val);
            columns[6][row_idx] = if (row.opcode == .BLT) M31.one() else M31.zero();
            columns[7][row_idx] = if (row.opcode == .BLTU) M31.one() else M31.zero();
            columns[8][row_idx] = if (row.opcode == .BGE) M31.one() else M31.zero();
            columns[9][row_idx] = if (row.opcode == .BGEU) M31.one() else M31.zero();
            columns[10][row_idx] = M31.one();
            columns[11][row_idx] = u32ToM31(target_val);
            columns[12][row_idx] = M31.fromCanonical(diff & 0xFFFF);
            columns[13][row_idx] = M31.fromCanonical(diff >> 16);
            columns[14][row_idx] = if (is_lt) M31.one() else M31.zero();
            columns[15][row_idx] = M31.zero();
        },
        .mul => {
            const prod: u64 = @as(u64, row.rs1_val) *% @as(u64, row.rs2_val);
            columns[0][row_idx] = u32ToM31(row.clk);
            columns[1][row_idx] = u32ToM31(row.pc);
            columns[2][row_idx] = M31.fromCanonical(@as(u32, row.rd));
            columns[3][row_idx] = M31.fromCanonical(@as(u32, row.rs1));
            columns[4][row_idx] = M31.fromCanonical(@as(u32, row.rs2));
            columns[5][row_idx] = u32ToM31(row.rd_val);
            columns[6][row_idx] = u32ToM31(row.rs1_val);
            columns[7][row_idx] = u32ToM31(row.rs2_val);
            columns[8][row_idx] = u32ToM31(row.rd_val);
            columns[9][row_idx] = M31.one();
            columns[10][row_idx] = M31.fromCanonical(@truncate(prod & 0xFFFF));
            columns[11][row_idx] = M31.fromCanonical(@truncate((prod >> 16) & 0xFFFF));
            columns[12][row_idx] = M31.fromCanonical(@truncate(prod >> 32));
            columns[13][row_idx] = M31.zero();
        },
        .mulh => {
            const prod: u64 = @as(u64, row.rs1_val) *% @as(u64, row.rs2_val);
            columns[0][row_idx] = u32ToM31(row.clk);
            columns[1][row_idx] = u32ToM31(row.pc);
            columns[2][row_idx] = M31.fromCanonical(@as(u32, row.rd));
            columns[3][row_idx] = M31.fromCanonical(@as(u32, row.rs1));
            columns[4][row_idx] = M31.fromCanonical(@as(u32, row.rs2));
            columns[5][row_idx] = u32ToM31(row.rd_val);
            columns[6][row_idx] = u32ToM31(row.rs1_val);
            columns[7][row_idx] = u32ToM31(row.rs2_val);
            columns[8][row_idx] = u32ToM31(row.rd_val);
            columns[9][row_idx] = if (row.opcode == .MULH) M31.one() else M31.zero();
            columns[10][row_idx] = if (row.opcode == .MULHSU) M31.one() else M31.zero();
            columns[11][row_idx] = if (row.opcode == .MULHU) M31.one() else M31.zero();
            columns[12][row_idx] = M31.one();
            columns[13][row_idx] = M31.fromCanonical(@truncate(prod & 0xFFFF));
            columns[14][row_idx] = M31.fromCanonical(@truncate(prod >> 16));
            columns[15][row_idx] = M31.fromCanonical(row.rs1_val >> 31);
            columns[16][row_idx] = M31.fromCanonical(row.rs2_val >> 31);
            columns[17][row_idx] = M31.zero();
        },
        .div => {
            const q_and_r = computeDivResult(row);
            columns[0][row_idx] = u32ToM31(row.clk);
            columns[1][row_idx] = u32ToM31(row.pc);
            columns[2][row_idx] = M31.fromCanonical(@as(u32, row.rd));
            columns[3][row_idx] = M31.fromCanonical(@as(u32, row.rs1));
            columns[4][row_idx] = M31.fromCanonical(@as(u32, row.rs2));
            columns[5][row_idx] = u32ToM31(row.rd_val);
            columns[6][row_idx] = u32ToM31(row.rs1_val);
            columns[7][row_idx] = u32ToM31(row.rs2_val);
            columns[8][row_idx] = u32ToM31(row.rd_val);
            columns[9][row_idx] = if (row.opcode == .DIV) M31.one() else M31.zero();
            columns[10][row_idx] = if (row.opcode == .DIVU) M31.one() else M31.zero();
            columns[11][row_idx] = if (row.opcode == .REM) M31.one() else M31.zero();
            columns[12][row_idx] = if (row.opcode == .REMU) M31.one() else M31.zero();
            columns[13][row_idx] = M31.one();
            columns[14][row_idx] = u32ToM31(q_and_r.quotient);
            columns[15][row_idx] = u32ToM31(q_and_r.remainder);
            columns[16][row_idx] = if (row.rs2_val == 0) M31.one() else M31.zero();
            columns[17][row_idx] = M31.fromCanonical(row.rs1_val >> 31);
            columns[18][row_idx] = M31.fromCanonical(row.rs2_val >> 31);
            columns[19][row_idx] = M31.zero();
        },
    }
}

/// Compute quotient and remainder for div family.
fn computeDivResult(row: TraceRow) struct { quotient: u32, remainder: u32 } {
    if (row.rs2_val == 0) {
        return .{ .quotient = 0, .remainder = row.rs1_val };
    }
    return switch (row.opcode) {
        .DIV => blk: {
            const a: i32 = @bitCast(row.rs1_val);
            const b: i32 = @bitCast(row.rs2_val);
            if (a == std.math.minInt(i32) and b == -1) {
                break :blk .{ .quotient = @bitCast(a), .remainder = 0 };
            }
            break :blk .{ .quotient = @bitCast(@divTrunc(a, b)), .remainder = @bitCast(@rem(a, b)) };
        },
        .DIVU => .{
            .quotient = row.rs1_val / row.rs2_val,
            .remainder = row.rs1_val % row.rs2_val,
        },
        .REM => blk: {
            const a: i32 = @bitCast(row.rs1_val);
            const b: i32 = @bitCast(row.rs2_val);
            if (a == std.math.minInt(i32) and b == -1) {
                break :blk .{ .quotient = @bitCast(a), .remainder = 0 };
            }
            break :blk .{ .quotient = @bitCast(@divTrunc(a, b)), .remainder = @bitCast(@rem(a, b)) };
        },
        .REMU => .{
            .quotient = row.rs1_val / row.rs2_val,
            .remainder = row.rs1_val % row.rs2_val,
        },
        else => .{ .quotient = 0, .remainder = 0 },
    };
}

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
