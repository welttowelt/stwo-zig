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
pub const MAX_FAMILY_COLUMNS: usize = 65; // DivColumns has the most

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

/// Decompose a u32 value into 4 byte limbs and write to columns[start..start+4].
inline fn writeU32Limbs(columns: *[MAX_FAMILY_COLUMNS][]M31, row_idx: usize, start: usize, val: u32) void {
    columns[start][row_idx] = u32ToM31(val & 0xFF);
    columns[start + 1][row_idx] = u32ToM31((val >> 8) & 0xFF);
    columns[start + 2][row_idx] = u32ToM31((val >> 16) & 0xFF);
    columns[start + 3][row_idx] = u32ToM31((val >> 24) & 0xFF);
}

/// Write a 10-column register access block at columns[start..start+10].
/// Layout: addr, prev_0..3, clk_prev, next_0..3
/// State chain data (prev values, clk_prev) is placeholder (zero) for now.
inline fn writeRegAccess(
    columns: *[MAX_FAMILY_COLUMNS][]M31,
    row_idx: usize,
    start: usize,
    addr: u32,
    next_val: u32,
) void {
    columns[start][row_idx] = u32ToM31(addr); // addr (may be register index or memory address)
    // prev_0..3: placeholder zeros (state chain data TBD)
    columns[start + 1][row_idx] = M31.zero();
    columns[start + 2][row_idx] = M31.zero();
    columns[start + 3][row_idx] = M31.zero();
    columns[start + 4][row_idx] = M31.zero();
    // clk_prev: placeholder zero
    columns[start + 5][row_idx] = M31.zero();
    // next_0..3: decompose next_val into byte limbs
    writeU32Limbs(columns, row_idx, start + 6, next_val);
}

/// Fill family-specific column data for a single trace row at the given index.
/// Column ordering must match the struct field order in air/trace_columns.zig.
/// All u32 values from the execution trace are reduced modulo P via u32ToM31.
///
/// Register access columns use placeholder values for state chain data
/// (prev limbs and clk_prev are zero). The next limbs are the byte
/// decomposition of the register value from the trace row.
pub fn fillFamilyColumns(
    columns: *[MAX_FAMILY_COLUMNS][]M31,
    row_idx: usize,
    row: TraceRow,
    family: OpcodeFamily,
) void {
    switch (family) {
        .base_alu_reg => {
            // BaseAluRegColumns: 7 common + rd(10) + rs1(10) + rs2(10) = 37
            var c: usize = 0;
            columns[c][row_idx] = u32ToM31(row.clk);
            c += 1;
            columns[c][row_idx] = u32ToM31(row.pc);
            c += 1;
            columns[c][row_idx] = if (row.opcode == .ADD) M31.one() else M31.zero();
            c += 1;
            columns[c][row_idx] = if (row.opcode == .SUB) M31.one() else M31.zero();
            c += 1;
            columns[c][row_idx] = if (row.opcode == .XOR) M31.one() else M31.zero();
            c += 1;
            columns[c][row_idx] = if (row.opcode == .OR) M31.one() else M31.zero();
            c += 1;
            columns[c][row_idx] = if (row.opcode == .AND) M31.one() else M31.zero();
            c += 1;
            writeRegAccess(columns, row_idx, c, @as(u32, row.rd), row.rd_val);
            c += 10;
            writeRegAccess(columns, row_idx, c, @as(u32, row.rs1), row.rs1_val);
            c += 10;
            writeRegAccess(columns, row_idx, c, @as(u32, row.rs2), row.rs2_val);
        },
        .base_alu_imm => {
            // BaseAluImmColumns: 9 common + rd(10) + rs1(10) = 29
            var c: usize = 0;
            columns[c][row_idx] = u32ToM31(row.clk);
            c += 1;
            columns[c][row_idx] = u32ToM31(row.pc);
            c += 1;
            columns[c][row_idx] = if (row.opcode == .ADDI) M31.one() else M31.zero();
            c += 1;
            columns[c][row_idx] = if (row.opcode == .XORI) M31.one() else M31.zero();
            c += 1;
            columns[c][row_idx] = if (row.opcode == .ORI) M31.one() else M31.zero();
            c += 1;
            columns[c][row_idx] = if (row.opcode == .ANDI) M31.one() else M31.zero();
            c += 1;
            columns[c][row_idx] = immToM31(row.imm);
            c += 1;
            columns[c][row_idx] = if (row.imm < 0) M31.one() else M31.zero();
            c += 1;
            columns[c][row_idx] = M31.one(); // enabler
            c += 1;
            writeRegAccess(columns, row_idx, c, @as(u32, row.rd), row.rd_val);
            c += 10;
            writeRegAccess(columns, row_idx, c, @as(u32, row.rs1), row.rs1_val);
        },
        .shifts_reg => {
            // ShiftsRegColumns: 6 common + 18 shift decomp + rd(10) + rs1(10) + rs2(10) = 54
            const shamt: u5 = @truncate(row.rs2_val);
            var c: usize = 0;
            columns[c][row_idx] = u32ToM31(row.clk);
            c += 1;
            columns[c][row_idx] = u32ToM31(row.pc);
            c += 1;
            columns[c][row_idx] = if (row.opcode == .SLL) M31.one() else M31.zero();
            c += 1;
            columns[c][row_idx] = if (row.opcode == .SRL) M31.one() else M31.zero();
            c += 1;
            columns[c][row_idx] = if (row.opcode == .SRA) M31.one() else M31.zero();
            c += 1;
            columns[c][row_idx] = M31.one(); // enabler
            c += 1;
            // shift decomposition (18 cols)
            columns[c][row_idx] = u32ToM31(@as(u32, shamt)); // shift_amount
            c += 1;
            columns[c][row_idx] = u32ToM31(32 - @as(u32, shamt)); // shift_amount_bound
            c += 1;
            columns[c][row_idx] = u32ToM31(row.rd_val & 0xFFFF); // shifted_lo
            c += 1;
            columns[c][row_idx] = u32ToM31(row.rd_val >> 16); // shifted_hi
            c += 1;
            // shift_bit_0..4: individual bits of shamt
            columns[c][row_idx] = u32ToM31(@as(u32, shamt) & 1);
            c += 1;
            columns[c][row_idx] = u32ToM31((@as(u32, shamt) >> 1) & 1);
            c += 1;
            columns[c][row_idx] = u32ToM31((@as(u32, shamt) >> 2) & 1);
            c += 1;
            columns[c][row_idx] = u32ToM31((@as(u32, shamt) >> 3) & 1);
            c += 1;
            columns[c][row_idx] = u32ToM31((@as(u32, shamt) >> 4) & 1);
            c += 1;
            // shift_mask_lo, shift_mask_hi, sign_bit, sign_extend_lo, sign_extend_hi
            columns[c][row_idx] = M31.zero(); // shift_mask_lo (placeholder)
            c += 1;
            columns[c][row_idx] = M31.zero(); // shift_mask_hi (placeholder)
            c += 1;
            columns[c][row_idx] = u32ToM31(row.rs1_val >> 31); // sign_bit
            c += 1;
            columns[c][row_idx] = M31.zero(); // sign_extend_lo (placeholder)
            c += 1;
            columns[c][row_idx] = M31.zero(); // sign_extend_hi (placeholder)
            c += 1;
            columns[c][row_idx] = u32ToM31(row.rd_val & 0xFFFF); // result_lo
            c += 1;
            columns[c][row_idx] = u32ToM31(row.rd_val >> 16); // result_hi
            c += 1;
            columns[c][row_idx] = M31.zero(); // carry (placeholder)
            c += 1;
            columns[c][row_idx] = M31.zero(); // overflow (placeholder)
            c += 1;
            writeRegAccess(columns, row_idx, c, @as(u32, row.rd), row.rd_val);
            c += 10;
            writeRegAccess(columns, row_idx, c, @as(u32, row.rs1), row.rs1_val);
            c += 10;
            writeRegAccess(columns, row_idx, c, @as(u32, row.rs2), row.rs2_val);
        },
        .shifts_imm => {
            // ShiftsImmColumns: 7 common + 18 shift decomp + rd(10) + rs1(10) = 45
            const shamt: u5 = @truncate(@as(u32, @bitCast(row.imm)));
            var c: usize = 0;
            columns[c][row_idx] = u32ToM31(row.clk);
            c += 1;
            columns[c][row_idx] = u32ToM31(row.pc);
            c += 1;
            columns[c][row_idx] = if (row.opcode == .SLLI) M31.one() else M31.zero();
            c += 1;
            columns[c][row_idx] = if (row.opcode == .SRLI) M31.one() else M31.zero();
            c += 1;
            columns[c][row_idx] = if (row.opcode == .SRAI) M31.one() else M31.zero();
            c += 1;
            columns[c][row_idx] = M31.one(); // enabler
            c += 1;
            columns[c][row_idx] = immToM31(row.imm); // imm
            c += 1;
            // shift decomposition (18 cols)
            columns[c][row_idx] = u32ToM31(@as(u32, shamt));
            c += 1;
            columns[c][row_idx] = u32ToM31(32 - @as(u32, shamt));
            c += 1;
            columns[c][row_idx] = u32ToM31(row.rd_val & 0xFFFF);
            c += 1;
            columns[c][row_idx] = u32ToM31(row.rd_val >> 16);
            c += 1;
            columns[c][row_idx] = u32ToM31(@as(u32, shamt) & 1);
            c += 1;
            columns[c][row_idx] = u32ToM31((@as(u32, shamt) >> 1) & 1);
            c += 1;
            columns[c][row_idx] = u32ToM31((@as(u32, shamt) >> 2) & 1);
            c += 1;
            columns[c][row_idx] = u32ToM31((@as(u32, shamt) >> 3) & 1);
            c += 1;
            columns[c][row_idx] = u32ToM31((@as(u32, shamt) >> 4) & 1);
            c += 1;
            columns[c][row_idx] = M31.zero(); // shift_mask_lo
            c += 1;
            columns[c][row_idx] = M31.zero(); // shift_mask_hi
            c += 1;
            columns[c][row_idx] = u32ToM31(row.rs1_val >> 31); // sign_bit
            c += 1;
            columns[c][row_idx] = M31.zero(); // sign_extend_lo
            c += 1;
            columns[c][row_idx] = M31.zero(); // sign_extend_hi
            c += 1;
            columns[c][row_idx] = u32ToM31(row.rd_val & 0xFFFF); // result_lo
            c += 1;
            columns[c][row_idx] = u32ToM31(row.rd_val >> 16); // result_hi
            c += 1;
            columns[c][row_idx] = M31.zero(); // carry
            c += 1;
            columns[c][row_idx] = M31.zero(); // overflow
            c += 1;
            writeRegAccess(columns, row_idx, c, @as(u32, row.rd), row.rd_val);
            c += 10;
            writeRegAccess(columns, row_idx, c, @as(u32, row.rs1), row.rs1_val);
        },
        .lt_reg => {
            // LtRegColumns: 5 common + 7 comparison + rd(10) + rs1(10) + rs2(10) = 42
            const diff = row.rs1_val -% row.rs2_val;
            const is_lt: bool = switch (row.opcode) {
                .SLT => @as(i32, @bitCast(row.rs1_val)) < @as(i32, @bitCast(row.rs2_val)),
                .SLTU => row.rs1_val < row.rs2_val,
                else => false,
            };
            var c: usize = 0;
            columns[c][row_idx] = u32ToM31(row.clk);
            c += 1;
            columns[c][row_idx] = u32ToM31(row.pc);
            c += 1;
            columns[c][row_idx] = if (row.opcode == .SLT) M31.one() else M31.zero();
            c += 1;
            columns[c][row_idx] = if (row.opcode == .SLTU) M31.one() else M31.zero();
            c += 1;
            columns[c][row_idx] = M31.one(); // enabler
            c += 1;
            // comparison decomposition (7)
            columns[c][row_idx] = u32ToM31(diff & 0xFFFF); // diff_lo
            c += 1;
            columns[c][row_idx] = u32ToM31(diff >> 16); // diff_hi
            c += 1;
            columns[c][row_idx] = u32ToM31(row.rs1_val >> 31); // rs1_sign
            c += 1;
            columns[c][row_idx] = u32ToM31(row.rs2_val >> 31); // rs2_sign
            c += 1;
            columns[c][row_idx] = if (is_lt) M31.one() else M31.zero(); // is_less_than
            c += 1;
            columns[c][row_idx] = M31.zero(); // borrow (placeholder)
            c += 1;
            columns[c][row_idx] = u32ToM31(row.rd_val); // result
            c += 1;
            writeRegAccess(columns, row_idx, c, @as(u32, row.rd), row.rd_val);
            c += 10;
            writeRegAccess(columns, row_idx, c, @as(u32, row.rs1), row.rs1_val);
            c += 10;
            writeRegAccess(columns, row_idx, c, @as(u32, row.rs2), row.rs2_val);
        },
        .lt_imm => {
            // LtImmColumns: 7 common + 7 comparison + rd(10) + rs1(10) = 34
            const imm_u32: u32 = @bitCast(row.imm);
            const diff = row.rs1_val -% imm_u32;
            const is_lt: bool = switch (row.opcode) {
                .SLTI => @as(i32, @bitCast(row.rs1_val)) < row.imm,
                .SLTIU => row.rs1_val < imm_u32,
                else => false,
            };
            var c: usize = 0;
            columns[c][row_idx] = u32ToM31(row.clk);
            c += 1;
            columns[c][row_idx] = u32ToM31(row.pc);
            c += 1;
            columns[c][row_idx] = if (row.opcode == .SLTI) M31.one() else M31.zero();
            c += 1;
            columns[c][row_idx] = if (row.opcode == .SLTIU) M31.one() else M31.zero();
            c += 1;
            columns[c][row_idx] = M31.one(); // enabler
            c += 1;
            columns[c][row_idx] = immToM31(row.imm); // imm
            c += 1;
            columns[c][row_idx] = if (row.imm < 0) M31.one() else M31.zero(); // imm_sign
            c += 1;
            // comparison decomposition (7)
            columns[c][row_idx] = u32ToM31(diff & 0xFFFF); // diff_lo
            c += 1;
            columns[c][row_idx] = u32ToM31(diff >> 16); // diff_hi
            c += 1;
            columns[c][row_idx] = u32ToM31(row.rs1_val >> 31); // rs1_sign
            c += 1;
            columns[c][row_idx] = if (is_lt) M31.one() else M31.zero(); // is_less_than
            c += 1;
            columns[c][row_idx] = M31.zero(); // borrow (placeholder)
            c += 1;
            columns[c][row_idx] = u32ToM31(row.rd_val); // result
            c += 1;
            columns[c][row_idx] = M31.zero(); // imm_ext (placeholder)
            c += 1;
            writeRegAccess(columns, row_idx, c, @as(u32, row.rd), row.rd_val);
            c += 10;
            writeRegAccess(columns, row_idx, c, @as(u32, row.rs1), row.rs1_val);
        },
        .branch_eq => {
            // BranchEqColumns: 10 common + rs1(10) + rs2(10) = 30
            const rs1m = u32ToM31(row.rs1_val);
            const rs2m = u32ToM31(row.rs2_val);
            const diff_m31 = rs1m.sub(rs2m);
            const is_eq: bool = (row.rs1_val == row.rs2_val);
            const target: u32 = @bitCast(@as(i32, @bitCast(row.pc)) +% row.imm);
            var c: usize = 0;
            columns[c][row_idx] = u32ToM31(row.clk);
            c += 1;
            columns[c][row_idx] = u32ToM31(row.pc);
            c += 1;
            columns[c][row_idx] = if (row.opcode == .BEQ) M31.one() else M31.zero();
            c += 1;
            columns[c][row_idx] = if (row.opcode == .BNE) M31.one() else M31.zero();
            c += 1;
            columns[c][row_idx] = M31.one(); // enabler
            c += 1;
            columns[c][row_idx] = u32ToM31(target); // branch_target
            c += 1;
            columns[c][row_idx] = diff_m31; // diff
            c += 1;
            columns[c][row_idx] = if (!diff_m31.isZero()) diff_m31.invUncheckedNonZero() else M31.zero(); // diff_inv
            c += 1;
            columns[c][row_idx] = if (is_eq) M31.one() else M31.zero(); // is_equal
            c += 1;
            columns[c][row_idx] = M31.zero(); // branch_target_aux (placeholder)
            c += 1;
            writeRegAccess(columns, row_idx, c, @as(u32, row.rs1), row.rs1_val);
            c += 10;
            writeRegAccess(columns, row_idx, c, @as(u32, row.rs2), row.rs2_val);
        },
        .branch_lt => {
            // BranchLtColumns: 8 common + 9 decomp + rs1(10) + rs2(10) = 37
            const diff = row.rs1_val -% row.rs2_val;
            const target_val: u32 = @bitCast(@as(i32, @bitCast(row.pc)) +% row.imm);
            const is_lt: bool = switch (row.opcode) {
                .BLT => @as(i32, @bitCast(row.rs1_val)) < @as(i32, @bitCast(row.rs2_val)),
                .BLTU => row.rs1_val < row.rs2_val,
                .BGE => @as(i32, @bitCast(row.rs1_val)) < @as(i32, @bitCast(row.rs2_val)),
                .BGEU => row.rs1_val < row.rs2_val,
                else => false,
            };
            var c: usize = 0;
            columns[c][row_idx] = u32ToM31(row.clk);
            c += 1;
            columns[c][row_idx] = u32ToM31(row.pc);
            c += 1;
            columns[c][row_idx] = if (row.opcode == .BLT) M31.one() else M31.zero();
            c += 1;
            columns[c][row_idx] = if (row.opcode == .BLTU) M31.one() else M31.zero();
            c += 1;
            columns[c][row_idx] = if (row.opcode == .BGE) M31.one() else M31.zero();
            c += 1;
            columns[c][row_idx] = if (row.opcode == .BGEU) M31.one() else M31.zero();
            c += 1;
            columns[c][row_idx] = M31.one(); // enabler
            c += 1;
            columns[c][row_idx] = u32ToM31(target_val); // branch_target
            c += 1;
            // comparison/branch decomposition (9)
            columns[c][row_idx] = u32ToM31(diff & 0xFFFF); // diff_lo
            c += 1;
            columns[c][row_idx] = u32ToM31(diff >> 16); // diff_hi
            c += 1;
            columns[c][row_idx] = u32ToM31(row.rs1_val >> 31); // rs1_sign
            c += 1;
            columns[c][row_idx] = u32ToM31(row.rs2_val >> 31); // rs2_sign
            c += 1;
            columns[c][row_idx] = if (is_lt) M31.one() else M31.zero(); // is_less_than
            c += 1;
            columns[c][row_idx] = M31.zero(); // borrow (placeholder)
            c += 1;
            columns[c][row_idx] = u32ToM31(target_val & 0xFFFF); // branch_target_lo
            c += 1;
            columns[c][row_idx] = u32ToM31(target_val >> 16); // branch_target_hi
            c += 1;
            columns[c][row_idx] = M31.zero(); // branch_target_aux (placeholder)
            c += 1;
            writeRegAccess(columns, row_idx, c, @as(u32, row.rs1), row.rs1_val);
            c += 10;
            writeRegAccess(columns, row_idx, c, @as(u32, row.rs2), row.rs2_val);
        },
        .lui => {
            // LuiColumns: 6 common + rd(10) = 16
            const result_val = row.rd_val;
            var c: usize = 0;
            columns[c][row_idx] = u32ToM31(row.clk);
            c += 1;
            columns[c][row_idx] = u32ToM31(row.pc);
            c += 1;
            columns[c][row_idx] = u32ToM31(result_val >> 12); // imm_u
            c += 1;
            columns[c][row_idx] = M31.one(); // enabler
            c += 1;
            columns[c][row_idx] = u32ToM31(result_val & 0xFFFF); // result_lo
            c += 1;
            columns[c][row_idx] = u32ToM31(result_val >> 16); // result_hi
            c += 1;
            writeRegAccess(columns, row_idx, c, @as(u32, row.rd), row.rd_val);
        },
        .auipc => {
            // AuipcColumns: 4 common + rd(10) = 14
            const result_val = row.rd_val;
            const imm_bits: u32 = @bitCast(@as(i32, @bitCast(result_val)) -% @as(i32, @bitCast(row.pc)));
            var c: usize = 0;
            columns[c][row_idx] = u32ToM31(row.clk);
            c += 1;
            columns[c][row_idx] = u32ToM31(row.pc);
            c += 1;
            columns[c][row_idx] = u32ToM31(imm_bits); // imm_u
            c += 1;
            columns[c][row_idx] = M31.one(); // enabler
            c += 1;
            writeRegAccess(columns, row_idx, c, @as(u32, row.rd), row.rd_val);
        },
        .jalr => {
            // JalrColumns: 6 common + rd(10) + rs1(10) = 26
            const target_val = row.next_pc;
            var c: usize = 0;
            columns[c][row_idx] = u32ToM31(row.clk);
            c += 1;
            columns[c][row_idx] = u32ToM31(row.pc);
            c += 1;
            columns[c][row_idx] = immToM31(row.imm); // imm
            c += 1;
            columns[c][row_idx] = M31.one(); // enabler
            c += 1;
            columns[c][row_idx] = u32ToM31(target_val & 0xFFFF); // target_lo
            c += 1;
            columns[c][row_idx] = u32ToM31(target_val >> 16); // target_hi
            c += 1;
            writeRegAccess(columns, row_idx, c, @as(u32, row.rd), row.rd_val);
            c += 10;
            writeRegAccess(columns, row_idx, c, @as(u32, row.rs1), row.rs1_val);
        },
        .jal => {
            // JalColumns: 4 common + rd(10) = 14
            var c: usize = 0;
            columns[c][row_idx] = u32ToM31(row.clk);
            c += 1;
            columns[c][row_idx] = u32ToM31(row.pc);
            c += 1;
            columns[c][row_idx] = immToM31(row.imm); // imm_j
            c += 1;
            columns[c][row_idx] = M31.one(); // enabler
            c += 1;
            writeRegAccess(columns, row_idx, c, @as(u32, row.rd), row.rd_val);
        },
        .load_store => {
            // LoadStoreColumns: 20 common + rd(10) + rs1(10) + mem(10) = 50
            var c: usize = 0;
            columns[c][row_idx] = u32ToM31(row.clk);
            c += 1;
            columns[c][row_idx] = u32ToM31(row.pc);
            c += 1;
            columns[c][row_idx] = immToM31(row.imm); // imm
            c += 1;
            columns[c][row_idx] = if (row.opcode == .LB) M31.one() else M31.zero();
            c += 1;
            columns[c][row_idx] = if (row.opcode == .LBU) M31.one() else M31.zero();
            c += 1;
            columns[c][row_idx] = if (row.opcode == .LH) M31.one() else M31.zero();
            c += 1;
            columns[c][row_idx] = if (row.opcode == .LHU) M31.one() else M31.zero();
            c += 1;
            columns[c][row_idx] = if (row.opcode == .LW) M31.one() else M31.zero();
            c += 1;
            columns[c][row_idx] = if (row.opcode == .SB) M31.one() else M31.zero();
            c += 1;
            columns[c][row_idx] = if (row.opcode == .SH) M31.one() else M31.zero();
            c += 1;
            columns[c][row_idx] = if (row.opcode == .SW) M31.one() else M31.zero();
            c += 1;
            columns[c][row_idx] = M31.one(); // enabler
            c += 1;
            columns[c][row_idx] = u32ToM31(row.mem_val & 0xFF); // byte_0
            c += 1;
            columns[c][row_idx] = u32ToM31((row.mem_val >> 8) & 0xFF); // byte_1
            c += 1;
            columns[c][row_idx] = u32ToM31((row.mem_val >> 16) & 0xFF); // byte_2
            c += 1;
            columns[c][row_idx] = u32ToM31((row.mem_val >> 24) & 0xFF); // byte_3
            c += 1;
            columns[c][row_idx] = u32ToM31(row.mem_addr); // mem_addr
            c += 1;
            columns[c][row_idx] = u32ToM31(row.mem_val); // mem_val
            c += 1;
            columns[c][row_idx] = u32ToM31(row.rs2_val); // rs2_val
            c += 1;
            columns[c][row_idx] = M31.zero(); // sign_extend (placeholder)
            c += 1;
            // For loads, rd gets the loaded value; for stores, rd is not written
            // but we still fill the access columns.
            writeRegAccess(columns, row_idx, c, @as(u32, row.rd), row.rd_val);
            c += 10;
            writeRegAccess(columns, row_idx, c, @as(u32, row.rs1), row.rs1_val);
            c += 10;
            // memory access (10 cols): addr=mem_addr, next=mem_val decomposed
            writeRegAccess(columns, row_idx, c, row.mem_addr, row.mem_val);
        },
        .mul => {
            // MulColumns: 3 common + rd(10) + rs1(10) + rs2(10) = 33
            var c: usize = 0;
            columns[c][row_idx] = u32ToM31(row.clk);
            c += 1;
            columns[c][row_idx] = u32ToM31(row.pc);
            c += 1;
            columns[c][row_idx] = M31.one(); // enabler
            c += 1;
            writeRegAccess(columns, row_idx, c, @as(u32, row.rd), row.rd_val);
            c += 10;
            writeRegAccess(columns, row_idx, c, @as(u32, row.rs1), row.rs1_val);
            c += 10;
            writeRegAccess(columns, row_idx, c, @as(u32, row.rs2), row.rs2_val);
        },
        .mulh => {
            // MulhColumns: 6 common + 5 decomp + rd(10) + rs1(10) + rs2(10) = 41
            const prod: u64 = @as(u64, row.rs1_val) *% @as(u64, row.rs2_val);
            var c: usize = 0;
            columns[c][row_idx] = u32ToM31(row.clk);
            c += 1;
            columns[c][row_idx] = u32ToM31(row.pc);
            c += 1;
            columns[c][row_idx] = if (row.opcode == .MULH) M31.one() else M31.zero();
            c += 1;
            columns[c][row_idx] = if (row.opcode == .MULHSU) M31.one() else M31.zero();
            c += 1;
            columns[c][row_idx] = if (row.opcode == .MULHU) M31.one() else M31.zero();
            c += 1;
            columns[c][row_idx] = M31.one(); // enabler
            c += 1;
            // product decomposition (5)
            columns[c][row_idx] = u32ToM31(@truncate(prod & 0xFFFF)); // prod_lo
            c += 1;
            columns[c][row_idx] = u32ToM31(@truncate(prod >> 16)); // prod_hi
            c += 1;
            columns[c][row_idx] = u32ToM31(row.rs1_val >> 31); // rs1_sign
            c += 1;
            columns[c][row_idx] = u32ToM31(row.rs2_val >> 31); // rs2_sign
            c += 1;
            columns[c][row_idx] = u32ToM31(@truncate(prod >> 32)); // carry
            c += 1;
            writeRegAccess(columns, row_idx, c, @as(u32, row.rd), row.rd_val);
            c += 10;
            writeRegAccess(columns, row_idx, c, @as(u32, row.rs1), row.rs1_val);
            c += 10;
            writeRegAccess(columns, row_idx, c, @as(u32, row.rs2), row.rs2_val);
        },
        .div => {
            // DivColumns: 7 common + 28 decomp + rd(10) + rs1(10) + rs2(10) = 65
            const q_and_r = computeDivResult(row);
            var c: usize = 0;
            columns[c][row_idx] = u32ToM31(row.clk);
            c += 1;
            columns[c][row_idx] = u32ToM31(row.pc);
            c += 1;
            columns[c][row_idx] = if (row.opcode == .DIV) M31.one() else M31.zero();
            c += 1;
            columns[c][row_idx] = if (row.opcode == .DIVU) M31.one() else M31.zero();
            c += 1;
            columns[c][row_idx] = if (row.opcode == .REM) M31.one() else M31.zero();
            c += 1;
            columns[c][row_idx] = if (row.opcode == .REMU) M31.one() else M31.zero();
            c += 1;
            columns[c][row_idx] = M31.one(); // enabler
            c += 1;
            // quotient byte limbs (4)
            writeU32Limbs(columns, row_idx, c, q_and_r.quotient);
            c += 4;
            // remainder byte limbs (4)
            writeU32Limbs(columns, row_idx, c, q_and_r.remainder);
            c += 4;
            columns[c][row_idx] = if (row.rs2_val == 0) M31.one() else M31.zero(); // rs2_is_zero
            c += 1;
            columns[c][row_idx] = u32ToM31(row.rs1_val >> 31); // rs1_sign
            c += 1;
            columns[c][row_idx] = u32ToM31(row.rs2_val >> 31); // rs2_sign
            c += 1;
            columns[c][row_idx] = M31.zero(); // quotient_sign (placeholder)
            c += 1;
            columns[c][row_idx] = M31.zero(); // remainder_sign (placeholder)
            c += 1;
            // abs_rs1 limbs (4)
            writeU32Limbs(columns, row_idx, c, row.rs1_val);
            c += 4;
            // abs_rs2 limbs (4)
            writeU32Limbs(columns, row_idx, c, row.rs2_val);
            c += 4;
            // prod_lo_0, prod_lo_1, prod_hi_0, prod_hi_1 (placeholders)
            columns[c][row_idx] = M31.zero();
            c += 1;
            columns[c][row_idx] = M31.zero();
            c += 1;
            columns[c][row_idx] = M31.zero();
            c += 1;
            columns[c][row_idx] = M31.zero();
            c += 1;
            // carry_0, carry_1, overflow (placeholders)
            columns[c][row_idx] = M31.zero();
            c += 1;
            columns[c][row_idx] = M31.zero();
            c += 1;
            columns[c][row_idx] = M31.zero();
            c += 1;
            writeRegAccess(columns, row_idx, c, @as(u32, row.rd), row.rd_val);
            c += 10;
            writeRegAccess(columns, row_idx, c, @as(u32, row.rs1), row.rs1_val);
            c += 10;
            writeRegAccess(columns, row_idx, c, @as(u32, row.rs2), row.rs2_val);
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
        .LB, .LBU, .LH, .LHU, .LW, .SB, .SH, .SW,
        .LR_W, .SC_W, .AMOSWAP_W, .AMOADD_W, .AMOAND_W, .AMOOR_W, .AMOXOR_W,
        .AMOMIN_W, .AMOMAX_W, .AMOMINU_W, .AMOMAXU_W,
        => .load_store,
        .MUL => .mul,
        .MULH, .MULHSU, .MULHU => .mulh,
        .DIV, .DIVU, .REM, .REMU => .div,
        .ECALL, .EBREAK, .FENCE => .base_alu_reg, // fallback
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
