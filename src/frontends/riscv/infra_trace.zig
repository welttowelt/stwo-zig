//! Infrastructure trace generation for the RISC-V STARK.
//!
//! Provides column generators for infrastructure (non-opcode) components:
//! Program ROM, Memory check, Clock updates (mem + reg), Merkle tree,
//! Poseidon2 permutation, and preprocessed multiplicity tables.
//!
//! Each generator produces padded, bit-reversed column arrays suitable
//! for commitment via the stwo STARK backend.

const std = @import("std");
const m31 = @import("../../core/fields/m31.zig");
const utils = @import("../../core/utils.zig");
const poseidon2 = @import("common/poseidon2.zig");
const program_table = @import("air/program/table.zig");
const trace_mod = @import("runner/trace.zig");
const state_chain = @import("runner/state_chain.zig");
const trace_columns = @import("air/trace_columns.zig");

const M31 = m31.M31;
const StateChainTracker = state_chain.StateChainTracker;

/// Number of trace columns for the Program ROM component.
/// The trailing root column is protocol-known zero until the program lookup
/// is wired, so only the seven populated columns are committed.
pub const PROGRAM_TRACE_COLS: usize = trace_columns.ProgramColumns.N_COLUMNS - 1;

/// Number of trace columns for the Memory check component.
/// Multiplicity and root are protocol-known zero until LogUp/state-root
/// constraints are wired, so only the seven populated columns are committed.
pub const MEMORY_TRACE_COLS: usize = trace_columns.MemoryCheckColumns.N_COLUMNS - 2;

/// Number of trace columns for the memory clock update component.
pub const MEM_CLOCK_UPDATE_COLS: usize = trace_columns.MemClockUpdateColumns.N_COLUMNS; // 7

/// Number of trace columns for the register clock update component.
pub const REG_CLOCK_UPDATE_COLS: usize = trace_columns.RegClockUpdateColumns.N_COLUMNS; // 7

/// Unified clock-gap table used by the current stark-v AIR.
pub const CLOCK_UPDATE_COLS: usize = 8;

/// Number of trace columns for a single Poseidon2 permutation.
pub const POSEIDON2_TRACE_COLS: usize = 443;

/// Number of trace columns for a Merkle tree node row.
pub const MERKLE_TRACE_COLS: usize = 10;

/// Number of preprocessed multiplicity tables.
pub const N_MULTIPLICITY_TABLES: usize = 6;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Pre-computed permutation table mapping coset row indices to
/// bit-reversed circle-domain positions.  Building this once per log_size
/// replaces per-cell `cosetIndexToCircleDomainIndex` + `bitReverseIndex`
/// calls with a single table lookup.
pub const BitReversalTable = struct {
    mapping: []const usize,

    /// Allocate and populate the permutation table for `log_size`.
    pub fn init(allocator: std.mem.Allocator, log_size: u32) !BitReversalTable {
        const n = @as(usize, 1) << @intCast(log_size);
        const buf = try allocator.alloc(usize, n);
        for (0..n) |i| {
            buf[i] = utils.bitReverseIndex(
                utils.cosetIndexToCircleDomainIndex(i, log_size),
                log_size,
            );
        }
        return .{ .mapping = buf };
    }

    pub fn deinit(self: BitReversalTable, allocator: std.mem.Allocator) void {
        allocator.free(self.mapping);
    }

    /// Look up the destination index for `row_idx`.
    pub inline fn map(self: BitReversalTable, row_idx: usize) usize {
        return self.mapping[row_idx];
    }
};

/// Place `value` at the pre-computed bit-reversed circle-domain position.
inline fn placeValue(col: []M31, row_idx: usize, table: BitReversalTable, value: M31) void {
    col[table.map(row_idx)] = value;
}

/// Allocate `n` zero-filled columns of `domain_size` elements each.
fn allocZeroColumns(
    allocator: std.mem.Allocator,
    comptime n: usize,
    domain_size: usize,
) ![n][]M31 {
    var columns: [n][]M31 = undefined;
    var allocated: usize = 0;
    errdefer {
        for (0..allocated) |i| allocator.free(columns[i]);
    }
    for (0..n) |i| {
        columns[i] = try allocator.alloc(M31, domain_size);
        allocated = i + 1;
        @memset(columns[i], M31.zero());
    }
    return columns;
}

// ---------------------------------------------------------------------------
// Program ROM (8 columns)
// ---------------------------------------------------------------------------

/// Generate the seven populated columns for the Program ROM component.
///
/// Iterates over execution trace rows, collecting unique PCs and their exact
/// pinned Stark-V decoded program tuples. Each unique PC becomes one row.
///
/// Columns: enabler, pc, opcode_id, value_1, value_2, value_3, multiplicity.
pub fn genProgramColumns(
    allocator: std.mem.Allocator,
    exec_trace: *const trace_mod.Trace,
    log_size: u32,
) !struct { columns: [PROGRAM_TRACE_COLS][]M31, n_real_rows: usize } {
    const domain_size = @as(usize, 1) << @intCast(log_size);
    var columns = try allocZeroColumns(allocator, PROGRAM_TRACE_COLS, domain_size);
    errdefer for (&columns) |col| allocator.free(col);

    const table = try BitReversalTable.init(allocator, log_size);
    defer table.deinit(allocator);

    const fetches = try allocator.alloc(program_table.Fetch, exec_trace.rows.items.len);
    defer allocator.free(fetches);
    for (exec_trace.rows.items, fetches) |row, *fetch| {
        fetch.* = .{ .pc = row.pc, .word = row.inst_word };
    }
    var decoded = try program_table.generate(allocator, fetches);
    defer decoded.deinit();
    if (decoded.rows.len > domain_size) return error.InvalidTraceShape;

    for (decoded.rows, 0..) |row, row_idx| {
        const values = row.relationValues();
        placeValue(columns[0], row_idx, table, M31.one()); // enabler
        for (values, 0..) |value, column| {
            placeValue(columns[1 + column], row_idx, table, M31.fromU64(value));
        }
        placeValue(columns[6], row_idx, table, M31.fromU64(row.multiplicity));
    }

    return .{ .columns = columns, .n_real_rows = decoded.rows.len };
}

/// Free columns allocated by `genProgramColumns`.
pub fn freeProgramColumns(allocator: std.mem.Allocator, columns: *[PROGRAM_TRACE_COLS][]M31) void {
    for (columns) |col| allocator.free(col);
}

// ---------------------------------------------------------------------------
// Memory check (9 columns)
// ---------------------------------------------------------------------------

/// Generate the seven populated columns for the Memory integrity component.
///
/// Columns: enabler, addr, clk, value_0..3.
pub const MemoryColumnsResult = struct {
    columns: [MEMORY_TRACE_COLS][]M31,
    n_real_rows: usize,
};

pub fn genMemoryColumns(
    allocator: std.mem.Allocator,
    chain: *const StateChainTracker,
    log_size: u32,
) !MemoryColumnsResult {
    return genMemoryColumnsRange(allocator, chain, log_size, 0, chain.accesses.items.len);
}

pub fn genMemoryColumnsRange(
    allocator: std.mem.Allocator,
    chain: *const StateChainTracker,
    log_size: u32,
    access_start: usize,
    access_end: usize,
) !MemoryColumnsResult {
    if (access_start > access_end or access_end > chain.accesses.items.len) return error.InvalidAccessRange;
    const domain_size = @as(usize, 1) << @intCast(log_size);
    var columns = try allocZeroColumns(allocator, MEMORY_TRACE_COLS, domain_size);
    errdefer for (&columns) |col| allocator.free(col);

    const table = try BitReversalTable.init(allocator, log_size);
    defer table.deinit(allocator);

    var row_idx: usize = 0;
    for (chain.accesses.items[access_start..access_end]) |access| {
        // Include BOTH register (addr_space=0) and memory (addr_space=1) accesses,
        // matching stark-v's unified memory component.
        if (row_idx >= domain_size) break;

        placeValue(columns[0], row_idx, table, M31.one()); // enabler
        placeValue(columns[1], row_idx, table, M31.fromCanonical(access.addr & 0x7FFFFFFF)); // addr
        placeValue(columns[2], row_idx, table, M31.fromCanonical(access.clk)); // clk
        placeValue(columns[3], row_idx, table, access.value_limbs[0]); // value_0
        placeValue(columns[4], row_idx, table, access.value_limbs[1]); // value_1
        placeValue(columns[5], row_idx, table, access.value_limbs[2]); // value_2
        placeValue(columns[6], row_idx, table, access.value_limbs[3]); // value_3
        row_idx += 1;
    }

    return .{ .columns = columns, .n_real_rows = row_idx };
}

/// Free columns allocated by `genMemoryColumns`.
pub fn freeMemoryColumns(allocator: std.mem.Allocator, columns: *[MEMORY_TRACE_COLS][]M31) void {
    for (columns) |col| allocator.free(col);
}

// ---------------------------------------------------------------------------
// Memory clock update (7 columns)
// ---------------------------------------------------------------------------

/// Generate 7 columns for the memory clock update (gap-filling) component.
///
/// Columns: enabler, addr, clk, clk_prev, value_0, value_1, value_2.
pub fn genMemClockUpdateColumns(
    allocator: std.mem.Allocator,
    chain: *const StateChainTracker,
    log_size: u32,
) !struct { columns: [MEM_CLOCK_UPDATE_COLS][]M31, n_real_rows: usize } {
    const domain_size = @as(usize, 1) << @intCast(log_size);
    var columns = try allocZeroColumns(allocator, MEM_CLOCK_UPDATE_COLS, domain_size);
    errdefer for (&columns) |col| allocator.free(col);

    const table = try BitReversalTable.init(allocator, log_size);
    defer table.deinit(allocator);

    for (chain.clock_updates_mem.items, 0..) |upd, row_idx| {
        if (row_idx >= domain_size) break;

        placeValue(columns[0], row_idx, table, M31.one()); // enabler
        placeValue(columns[1], row_idx, table, M31.fromCanonical(upd.addr & 0x7FFFFFFF)); // addr
        placeValue(columns[2], row_idx, table, M31.fromCanonical(upd.clk)); // clk
        placeValue(columns[3], row_idx, table, M31.fromCanonical(upd.clk_prev)); // clk_prev
        placeValue(columns[4], row_idx, table, upd.value_limbs[0]); // value_0
        placeValue(columns[5], row_idx, table, upd.value_limbs[1]); // value_1
        placeValue(columns[6], row_idx, table, upd.value_limbs[2]); // value_2
    }

    return .{ .columns = columns, .n_real_rows = chain.clock_updates_mem.items.len };
}

/// Free columns allocated by `genMemClockUpdateColumns`.
pub fn freeMemClockUpdateColumns(allocator: std.mem.Allocator, columns: *[MEM_CLOCK_UPDATE_COLS][]M31) void {
    for (columns) |col| allocator.free(col);
}

// ---------------------------------------------------------------------------
// Register clock update (7 columns)
// ---------------------------------------------------------------------------

/// Generate 7 columns for the register clock update (gap-filling) component.
///
/// Columns: enabler, addr, clk_prev, value_0, value_1, value_2, value_3.
pub fn genRegClockUpdateColumns(
    allocator: std.mem.Allocator,
    chain: *const StateChainTracker,
    log_size: u32,
) !struct { columns: [REG_CLOCK_UPDATE_COLS][]M31, n_real_rows: usize } {
    const domain_size = @as(usize, 1) << @intCast(log_size);
    var columns = try allocZeroColumns(allocator, REG_CLOCK_UPDATE_COLS, domain_size);
    errdefer for (&columns) |col| allocator.free(col);

    const table = try BitReversalTable.init(allocator, log_size);
    defer table.deinit(allocator);

    for (chain.clock_updates_reg.items, 0..) |upd, row_idx| {
        if (row_idx >= domain_size) break;

        placeValue(columns[0], row_idx, table, M31.one()); // enabler
        placeValue(columns[1], row_idx, table, M31.fromCanonical(upd.addr & 0x7FFFFFFF)); // addr
        placeValue(columns[2], row_idx, table, M31.fromCanonical(upd.clk_prev)); // clk_prev
        placeValue(columns[3], row_idx, table, upd.value_limbs[0]); // value_0
        placeValue(columns[4], row_idx, table, upd.value_limbs[1]); // value_1
        placeValue(columns[5], row_idx, table, upd.value_limbs[2]); // value_2
        placeValue(columns[6], row_idx, table, upd.value_limbs[3]); // value_3
    }

    return .{ .columns = columns, .n_real_rows = chain.clock_updates_reg.items.len };
}

/// Free columns allocated by `genRegClockUpdateColumns`.
pub fn freeRegClockUpdateColumns(allocator: std.mem.Allocator, columns: *[REG_CLOCK_UPDATE_COLS][]M31) void {
    for (columns) |col| allocator.free(col);
}

/// Generate the unified stark-v clock-gap layout.
/// Columns: enabler, addr_space, addr, clk_prev, value_0..value_3.
pub fn genClockUpdateColumns(
    allocator: std.mem.Allocator,
    chain: *const StateChainTracker,
    log_size: u32,
) !struct { columns: [CLOCK_UPDATE_COLS][]M31, n_real_rows: usize } {
    const domain_size = @as(usize, 1) << @intCast(log_size);
    var columns = try allocZeroColumns(allocator, CLOCK_UPDATE_COLS, domain_size);
    errdefer for (&columns) |col| allocator.free(col);

    const table = try BitReversalTable.init(allocator, log_size);
    defer table.deinit(allocator);

    var row_idx: usize = 0;
    for (chain.clock_updates_reg.items) |upd| {
        if (row_idx >= domain_size) break;
        placeClockUpdateRow(&columns, row_idx, table, 0, upd);
        row_idx += 1;
    }
    for (chain.clock_updates_mem.items) |upd| {
        if (row_idx >= domain_size) break;
        placeClockUpdateRow(&columns, row_idx, table, 1, upd);
        row_idx += 1;
    }

    return .{
        .columns = columns,
        .n_real_rows = chain.clock_updates_reg.items.len + chain.clock_updates_mem.items.len,
    };
}

pub fn freeClockUpdateColumns(allocator: std.mem.Allocator, columns: *[CLOCK_UPDATE_COLS][]M31) void {
    for (columns) |column| allocator.free(column);
}

fn placeClockUpdateRow(
    columns: *[CLOCK_UPDATE_COLS][]M31,
    row_idx: usize,
    table: BitReversalTable,
    addr_space: u32,
    upd: state_chain.ClockUpdate,
) void {
    placeValue(columns[0], row_idx, table, M31.one());
    placeValue(columns[1], row_idx, table, M31.fromCanonical(addr_space));
    placeValue(columns[2], row_idx, table, M31.fromCanonical(upd.addr & 0x7FFFFFFF));
    placeValue(columns[3], row_idx, table, M31.fromCanonical(upd.clk_prev));
    for (0..4) |i| placeValue(columns[4 + i], row_idx, table, upd.value_limbs[i]);
}

// ---------------------------------------------------------------------------
// Preprocessed multiplicity tables (6 x 1 column)
// ---------------------------------------------------------------------------

/// Generate 6 multiplicity columns (1 each) for the preprocessed lookup tables:
///   bitwise, range_check_20, range_check_8_8, range_check_8_11,
///   range_check_8_8_4, range_check_m31.
///
/// Returns 6 columns, each of size 2^log_size, zero-filled (placeholder).
pub fn genPreprocessedMultiplicityColumns(
    allocator: std.mem.Allocator,
    exec_trace: *const trace_mod.Trace,
) !struct { columns: [N_MULTIPLICITY_TABLES][]M31, log_size: u32 } {
    const count = @max(exec_trace.step_count, 16);
    const log_size: u32 = @intCast(std.math.log2_int_ceil(usize, count));
    const domain_size = @as(usize, 1) << @intCast(log_size);
    var columns = try allocZeroColumns(allocator, N_MULTIPLICITY_TABLES, domain_size);
    errdefer for (&columns) |col| allocator.free(col);
    // Placeholder: all zeros.  Real multiplicity tallying will be done
    // once the LogUp relation accounting is fully wired.
    return .{ .columns = columns, .log_size = log_size };
}

/// Free columns allocated by `genPreprocessedMultiplicityColumns`.
pub fn freeMultiplicityColumns(allocator: std.mem.Allocator, columns: *[N_MULTIPLICITY_TABLES][]M31) void {
    for (columns) |col| allocator.free(col);
}

/// The log_size used by genPreprocessedMultiplicityColumns.
/// Exposed so the prover/verifier can compute the same value.
pub fn multiplicityLogSize(exec_trace: *const trace_mod.Trace) u32 {
    const count = @max(exec_trace.step_count, 16);
    return @intCast(std.math.log2_int_ceil(usize, count));
}

// ---------------------------------------------------------------------------
// Poseidon2 (443 columns)
// ---------------------------------------------------------------------------

/// Generate Poseidon2 trace columns (443 columns per row).
/// Each row records one full Poseidon2 permutation with all intermediate states.
pub fn genPoseidon2Columns(
    allocator: std.mem.Allocator,
    hash_traces: []const poseidon2.PermuteTrace,
    log_size: u32,
) !struct { columns: [POSEIDON2_TRACE_COLS][]M31, n_real_rows: usize } {
    const domain_size = @as(usize, 1) << @intCast(log_size);
    var columns = try allocZeroColumns(allocator, POSEIDON2_TRACE_COLS, domain_size);
    errdefer for (&columns) |col| allocator.free(col);

    const table = try BitReversalTable.init(allocator, log_size);
    defer table.deinit(allocator);

    for (hash_traces, 0..) |trace, row| {
        if (row >= domain_size) break;
        const flat = trace.flatten();
        for (0..POSEIDON2_TRACE_COLS) |col| {
            placeValue(columns[col], row, table, flat[col]);
        }
    }

    return .{ .columns = columns, .n_real_rows = hash_traces.len };
}

/// Free columns allocated by `genPoseidon2Columns`.
pub fn freePoseidon2Columns(allocator: std.mem.Allocator, columns: *[POSEIDON2_TRACE_COLS][]M31) void {
    for (columns) |col| allocator.free(col);
}

/// Generate Merkle tree trace columns (10 columns per row).
/// Each row records one Merkle node: hash(lhs, rhs) = cur.
pub fn genMerkleColumns(
    allocator: std.mem.Allocator,
    n_nodes: usize,
    log_size: u32,
) !struct { columns: [MERKLE_TRACE_COLS][]M31, n_real_rows: usize } {
    const domain_size = @as(usize, 1) << @intCast(log_size);
    var columns = try allocZeroColumns(allocator, MERKLE_TRACE_COLS, domain_size);
    errdefer for (&columns) |col| allocator.free(col);

    const table = try BitReversalTable.init(allocator, log_size);
    defer table.deinit(allocator);

    // Generate n_nodes rows with enabler=1 and index
    for (0..@min(n_nodes, domain_size)) |row| {
        placeValue(columns[0], row, table, M31.one()); // enabler
        placeValue(columns[1], row, table, M31.fromU64(@as(u64, row))); // index
    }

    return .{ .columns = columns, .n_real_rows = n_nodes };
}

/// Free columns allocated by `genMerkleColumns`.
pub fn freeMerkleColumns(allocator: std.mem.Allocator, columns: *[MERKLE_TRACE_COLS][]M31) void {
    for (columns) |col| allocator.free(col);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "infra_trace: genPoseidon2Columns basic" {
    const allocator = std.testing.allocator;

    // Create two traced permutations
    var state1: poseidon2.State = [_]M31{M31.zero()} ** poseidon2.STATE_WIDTH;
    state1[0] = M31.fromCanonical(1);
    const trace1 = poseidon2.permuteTraced(&state1);

    var state2: poseidon2.State = [_]M31{M31.zero()} ** poseidon2.STATE_WIDTH;
    state2[0] = M31.fromCanonical(2);
    const trace2 = poseidon2.permuteTraced(&state2);

    const traces = [_]poseidon2.PermuteTrace{ trace1, trace2 };
    const log_size: u32 = 2; // domain_size = 4

    var result = try genPoseidon2Columns(allocator, &traces, log_size);
    defer freePoseidon2Columns(allocator, &result.columns);

    try std.testing.expectEqual(@as(usize, 2), result.n_real_rows);

    // Enabler column (col 0): exactly 2 rows should be M31.one()
    var ones_count: usize = 0;
    for (result.columns[0]) |v| {
        if (v.eql(M31.one())) ones_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), ones_count);
}

test "infra_trace: genPoseidon2Columns empty traces" {
    const allocator = std.testing.allocator;
    const traces = [_]poseidon2.PermuteTrace{};
    const log_size: u32 = 1; // domain_size = 2

    var result = try genPoseidon2Columns(allocator, &traces, log_size);
    defer freePoseidon2Columns(allocator, &result.columns);

    try std.testing.expectEqual(@as(usize, 0), result.n_real_rows);

    // All values should be zero
    for (result.columns[0]) |v| {
        try std.testing.expect(v.isZero());
    }
}

test "infra_trace: genMerkleColumns basic" {
    const allocator = std.testing.allocator;
    const log_size: u32 = 3; // domain_size = 8
    const n_nodes: usize = 5;

    var result = try genMerkleColumns(allocator, n_nodes, log_size);
    defer freeMerkleColumns(allocator, &result.columns);

    try std.testing.expectEqual(@as(usize, 5), result.n_real_rows);

    // Enabler column: exactly 5 rows should be M31.one()
    var ones_count: usize = 0;
    for (result.columns[0]) |v| {
        if (v.eql(M31.one())) ones_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), ones_count);
}

test "infra_trace: genMerkleColumns empty" {
    const allocator = std.testing.allocator;
    const log_size: u32 = 2; // domain_size = 4
    const n_nodes: usize = 0;

    var result = try genMerkleColumns(allocator, n_nodes, log_size);
    defer freeMerkleColumns(allocator, &result.columns);

    try std.testing.expectEqual(@as(usize, 0), result.n_real_rows);

    // All values should be zero
    for (0..MERKLE_TRACE_COLS) |col| {
        for (result.columns[col]) |v| {
            try std.testing.expect(v.isZero());
        }
    }
}

test "infra_trace: genMerkleColumns clamps to domain_size" {
    const allocator = std.testing.allocator;
    const log_size: u32 = 2; // domain_size = 4
    const n_nodes: usize = 100; // more than domain_size

    var result = try genMerkleColumns(allocator, n_nodes, log_size);
    defer freeMerkleColumns(allocator, &result.columns);

    // n_real_rows reports the requested count, not the clamped count
    try std.testing.expectEqual(@as(usize, 100), result.n_real_rows);

    // But only 4 rows should actually have enabler=1
    var ones_count: usize = 0;
    for (result.columns[0]) |v| {
        if (v.eql(M31.one())) ones_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), ones_count);
}

test "infra_trace: genProgramColumns basic" {
    const allocator = std.testing.allocator;
    var exec_trace = trace_mod.Trace.init(allocator);
    defer exec_trace.deinit();

    try exec_trace.append(.{
        .clk = 0,
        .pc = 0x1000,
        .opcode = .ADDI,
        .rd = 1,
        .rs1 = 0,
        .rs2 = 0,
        .imm = 1,
        .rs1_val = 0,
        .rs2_val = 0,
        .rd_val = 1,
        .mem_addr = 0,
        .mem_val = 0,
        .is_load = false,
        .is_store = false,
        .branch_taken = false,
        .next_pc = 0x1004,
        .inst_word = 0x00100093,
    });
    try exec_trace.append(.{
        .clk = 1,
        .pc = 0x1004,
        .opcode = .ADD,
        .rd = 2,
        .rs1 = 1,
        .rs2 = 0,
        .imm = 0,
        .rs1_val = 1,
        .rs2_val = 0,
        .rd_val = 1,
        .mem_addr = 0,
        .mem_val = 0,
        .is_load = false,
        .is_store = false,
        .branch_taken = false,
        .next_pc = 0x1008,
        .inst_word = 0x00008133,
    });

    var result = try genProgramColumns(allocator, &exec_trace, 4);
    defer freeProgramColumns(allocator, &result.columns);

    try std.testing.expectEqual(@as(usize, PROGRAM_TRACE_COLS), result.columns.len);
    try std.testing.expectEqual(@as(usize, 2), result.n_real_rows);
    try std.testing.expectEqual(@as(usize, 16), result.columns[0].len);
}

test "infra_trace: genPreprocessedMultiplicityColumns basic" {
    const allocator = std.testing.allocator;
    var exec_trace = trace_mod.Trace.init(allocator);
    defer exec_trace.deinit();

    for (0..32) |i| {
        try exec_trace.append(.{
            .clk = @intCast(i),
            .pc = @intCast(0x1000 + i * 4),
            .opcode = .ADDI,
            .rd = 1,
            .rs1 = 0,
            .rs2 = 0,
            .imm = 1,
            .rs1_val = 0,
            .rs2_val = 0,
            .rd_val = 1,
            .mem_addr = 0,
            .mem_val = 0,
            .is_load = false,
            .is_store = false,
            .branch_taken = false,
            .next_pc = @intCast(0x1004 + i * 4),
        });
    }

    var result = try genPreprocessedMultiplicityColumns(allocator, &exec_trace);
    defer freeMultiplicityColumns(allocator, &result.columns);

    try std.testing.expectEqual(@as(usize, N_MULTIPLICITY_TABLES), result.columns.len);
    try std.testing.expectEqual(@as(u32, 5), result.log_size); // log2(32) = 5
}

// ---------------------------------------------------------------------------
// Program ROM tests
// ---------------------------------------------------------------------------

/// Helper: build a small execution trace for testing infrastructure columns.
fn makeSmallExecTrace(allocator: std.mem.Allocator) !trace_mod.Trace {
    var t = trace_mod.Trace.init(allocator);
    errdefer t.deinit();
    // Row 0: pc=0x100
    try t.append(.{
        .clk = 1,
        .pc = 0x100,
        .opcode = .ADD,
        .rd = 1,
        .rs1 = 2,
        .rs2 = 3,
        .imm = 0,
        .rs1_val = 10,
        .rs2_val = 20,
        .rd_val = 30,
        .mem_addr = 0,
        .mem_val = 0,
        .is_load = false,
        .is_store = false,
        .branch_taken = false,
        .next_pc = 0x104,
        .inst_word = 0x003100b3,
    });
    // Row 1: pc=0x104
    try t.append(.{
        .clk = 2,
        .pc = 0x104,
        .opcode = .SUB,
        .rd = 4,
        .rs1 = 1,
        .rs2 = 5,
        .imm = 0,
        .rs1_val = 30,
        .rs2_val = 5,
        .rd_val = 25,
        .mem_addr = 0,
        .mem_val = 0,
        .is_load = false,
        .is_store = false,
        .branch_taken = false,
        .next_pc = 0x108,
        .inst_word = 0x40508233,
    });
    // Row 2: repeat pc=0x100 (multiplicity test)
    try t.append(.{
        .clk = 3,
        .pc = 0x100,
        .opcode = .ADD,
        .rd = 1,
        .rs1 = 2,
        .rs2 = 3,
        .imm = 0,
        .rs1_val = 10,
        .rs2_val = 20,
        .rd_val = 30,
        .mem_addr = 0,
        .mem_val = 0,
        .is_load = false,
        .is_store = false,
        .branch_taken = false,
        .next_pc = 0x104,
        .inst_word = 0x003100b3,
    });
    return t;
}

test "infra_trace: genProgramColumns row count with duplicates" {
    const allocator = std.testing.allocator;
    var exec_trace = try makeSmallExecTrace(allocator);
    defer exec_trace.deinit();

    const log_size: u32 = 2; // domain_size = 4
    var result = try genProgramColumns(allocator, &exec_trace, log_size);
    defer freeProgramColumns(allocator, &result.columns);

    // 3 rows but only 2 unique PCs (0x100 appears twice).
    try std.testing.expectEqual(@as(usize, 2), result.n_real_rows);
}

test "infra_trace: genProgramColumns enabler count and multiplicity sum" {
    const allocator = std.testing.allocator;
    var exec_trace = try makeSmallExecTrace(allocator);
    defer exec_trace.deinit();

    const log_size: u32 = 2;
    var result = try genProgramColumns(allocator, &exec_trace, log_size);
    defer freeProgramColumns(allocator, &result.columns);

    const domain_size: usize = 1 << log_size;
    var enabler_count: usize = 0;
    var mult_sum: u64 = 0;
    for (0..domain_size) |i| {
        if (result.columns[0][i].eql(M31.one())) {
            enabler_count += 1;
            mult_sum += result.columns[6][i].v;
        }
    }
    // Exactly 2 unique PCs => 2 enablers.
    try std.testing.expectEqual(@as(usize, 2), enabler_count);
    // Total multiplicity = 3 (pc 0x100 x2 + pc 0x104 x1).
    try std.testing.expectEqual(@as(u64, 3), mult_sum);
}

test "infra_trace: genProgramColumns all columns have domain_size length" {
    const allocator = std.testing.allocator;
    var exec_trace = try makeSmallExecTrace(allocator);
    defer exec_trace.deinit();

    const log_size: u32 = 3; // domain_size = 8
    const domain_size: usize = 1 << log_size;
    var result = try genProgramColumns(allocator, &exec_trace, log_size);
    defer freeProgramColumns(allocator, &result.columns);

    for (result.columns) |col| {
        try std.testing.expectEqual(domain_size, col.len);
    }
}

test "infra_trace: genProgramColumns empty trace" {
    const allocator = std.testing.allocator;
    var exec_trace = trace_mod.Trace.init(allocator);
    defer exec_trace.deinit();

    const log_size: u32 = 2;
    var result = try genProgramColumns(allocator, &exec_trace, log_size);
    defer freeProgramColumns(allocator, &result.columns);

    try std.testing.expectEqual(@as(usize, 0), result.n_real_rows);
    // All enabler values should be zero.
    const domain_size: usize = 1 << log_size;
    for (0..domain_size) |i| {
        try std.testing.expect(result.columns[0][i].isZero());
    }
}

// ---------------------------------------------------------------------------
// Memory column tests
// ---------------------------------------------------------------------------

/// Helper: build a StateChainTracker with register + memory accesses.
fn makeSmallChain(allocator: std.mem.Allocator) !StateChainTracker {
    var chain = StateChainTracker.init(allocator);
    errdefer chain.deinit();
    try chain.recordRegAccess(1, 0, 42);
    try chain.recordRegAccess(2, 2, 100);
    try chain.recordMemAccess(0x1000, 4, 0xDEADBEEF);
    try chain.recordMemAccess(0x2000, 6, 0xCAFEBABE);
    try chain.recordMemAccess(0x1000, 8, 0x12345678);
    return chain;
}

test "infra_trace: genMemoryColumns row count" {
    const allocator = std.testing.allocator;
    var chain = try makeSmallChain(allocator);
    defer chain.deinit();

    const log_size: u32 = 3; // domain_size = 8
    var result = try genMemoryColumns(allocator, &chain, log_size);
    defer freeMemoryColumns(allocator, &result.columns);

    // Unified memory (stark-v): one row per access — 2 register + 3 memory.
    try std.testing.expectEqual(@as(usize, 5), result.n_real_rows);
}

test "infra_trace: genMemoryColumns value decomposition" {
    const allocator = std.testing.allocator;
    var chain = try makeSmallChain(allocator);
    defer chain.deinit();

    const log_size: u32 = 2;
    var result = try genMemoryColumns(allocator, &chain, log_size);
    defer freeMemoryColumns(allocator, &result.columns);

    // Find the row for addr=0x1000, clk=4 (value=0xDEADBEEF).
    const domain_size: usize = 1 << log_size;
    var found = false;
    for (0..domain_size) |i| {
        if (result.columns[1][i].eql(M31.fromCanonical(0x1000)) and
            result.columns[2][i].eql(M31.fromCanonical(4)))
        {
            // 0xDEADBEEF => limbs: 0xEF, 0xBE, 0xAD, 0xDE
            try std.testing.expectEqual(@as(u32, 0xEF), result.columns[3][i].v);
            try std.testing.expectEqual(@as(u32, 0xBE), result.columns[4][i].v);
            try std.testing.expectEqual(@as(u32, 0xAD), result.columns[5][i].v);
            try std.testing.expectEqual(@as(u32, 0xDE), result.columns[6][i].v);
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "infra_trace: genMemoryColumns all columns have domain_size length" {
    const allocator = std.testing.allocator;
    var chain = try makeSmallChain(allocator);
    defer chain.deinit();

    const log_size: u32 = 3;
    const domain_size: usize = 1 << log_size;
    var result = try genMemoryColumns(allocator, &chain, log_size);
    defer freeMemoryColumns(allocator, &result.columns);

    for (result.columns) |col| {
        try std.testing.expectEqual(domain_size, col.len);
    }
}

test "infra_trace: genMemoryColumns includes register accesses" {
    const allocator = std.testing.allocator;
    var chain = StateChainTracker.init(allocator);
    defer chain.deinit();

    // Register accesses are address space 0 of the unified memory argument.
    try chain.recordRegAccess(1, 0, 42);
    try chain.recordRegAccess(2, 2, 100);

    const log_size: u32 = 2;
    var result = try genMemoryColumns(allocator, &chain, log_size);
    defer freeMemoryColumns(allocator, &result.columns);

    try std.testing.expectEqual(@as(usize, 2), result.n_real_rows);
}

// ---------------------------------------------------------------------------
// Memory clock update tests
// ---------------------------------------------------------------------------

test "infra_trace: genMemClockUpdateColumns empty when no gaps" {
    const allocator = std.testing.allocator;
    var chain = try makeSmallChain(allocator);
    defer chain.deinit();

    const log_size: u32 = 2;
    var result = try genMemClockUpdateColumns(allocator, &chain, log_size);
    defer freeMemClockUpdateColumns(allocator, &result.columns);

    // No clock gaps in makeSmallChain (all clocks are small/close).
    try std.testing.expectEqual(@as(usize, 0), result.n_real_rows);
}

test "infra_trace: genMemClockUpdateColumns with gap filling" {
    const allocator = std.testing.allocator;
    var chain = StateChainTracker.init(allocator);
    defer chain.deinit();

    // Create a large clock gap (> MAX_CLOCK_DIFF) to trigger gap-filling.
    try chain.recordMemAccess(0x3000, 0, 0xFF);
    try chain.recordMemAccess(0x3000, 2_000_000, 0xAB);

    // Gap-filling should produce records.
    try std.testing.expect(chain.clock_updates_mem.items.len > 0);

    const log_size: u32 = 2;
    var result = try genMemClockUpdateColumns(allocator, &chain, log_size);
    defer freeMemClockUpdateColumns(allocator, &result.columns);

    try std.testing.expect(result.n_real_rows > 0);

    // Every filled row should have enabler = 1.
    const domain_size: usize = 1 << log_size;
    var enabler_count: usize = 0;
    for (0..domain_size) |i| {
        if (result.columns[0][i].eql(M31.one())) enabler_count += 1;
    }
    // n_real_rows may be clamped to domain_size.
    try std.testing.expectEqual(@min(result.n_real_rows, domain_size), enabler_count);
}

test "infra_trace: genMemClockUpdateColumns all columns have domain_size length" {
    const allocator = std.testing.allocator;
    var chain = try makeSmallChain(allocator);
    defer chain.deinit();

    const log_size: u32 = 3;
    const domain_size: usize = 1 << log_size;
    var result = try genMemClockUpdateColumns(allocator, &chain, log_size);
    defer freeMemClockUpdateColumns(allocator, &result.columns);

    for (result.columns) |col| {
        try std.testing.expectEqual(domain_size, col.len);
    }
}

// ---------------------------------------------------------------------------
// Register clock update tests
// ---------------------------------------------------------------------------

test "infra_trace: genRegClockUpdateColumns empty when no gaps" {
    const allocator = std.testing.allocator;
    var chain = try makeSmallChain(allocator);
    defer chain.deinit();

    const log_size: u32 = 2;
    var result = try genRegClockUpdateColumns(allocator, &chain, log_size);
    defer freeRegClockUpdateColumns(allocator, &result.columns);

    try std.testing.expectEqual(@as(usize, 0), result.n_real_rows);
}

test "infra_trace: genRegClockUpdateColumns with gap filling" {
    const allocator = std.testing.allocator;
    var chain = StateChainTracker.init(allocator);
    defer chain.deinit();

    // Large register clock gap.
    try chain.recordRegAccess(5, 0, 99);
    try chain.recordRegAccess(5, 2_000_000, 100);

    try std.testing.expect(chain.clock_updates_reg.items.len > 0);

    const log_size: u32 = 2;
    var result = try genRegClockUpdateColumns(allocator, &chain, log_size);
    defer freeRegClockUpdateColumns(allocator, &result.columns);

    try std.testing.expect(result.n_real_rows > 0);
}

test "infra_trace: genRegClockUpdateColumns all columns have domain_size length" {
    const allocator = std.testing.allocator;
    var chain = try makeSmallChain(allocator);
    defer chain.deinit();

    const log_size: u32 = 3;
    const domain_size: usize = 1 << log_size;
    var result = try genRegClockUpdateColumns(allocator, &chain, log_size);
    defer freeRegClockUpdateColumns(allocator, &result.columns);

    for (result.columns) |col| {
        try std.testing.expectEqual(domain_size, col.len);
    }
}

test "infra_trace: unified clock updates preserve address spaces" {
    const allocator = std.testing.allocator;
    var chain = StateChainTracker.init(allocator);
    defer chain.deinit();

    try chain.recordRegAccess(5, 2_000_000, 0x01020304);
    try chain.recordMemAccess(0x3000, 2_000_000, 0xA0B0C0D0);

    var result = try genClockUpdateColumns(allocator, &chain, 2);
    defer freeClockUpdateColumns(allocator, &result.columns);

    try std.testing.expectEqual(@as(usize, 2), result.n_real_rows);
    var register_rows: usize = 0;
    var memory_rows: usize = 0;
    for (result.columns[0], result.columns[1]) |enabled, addr_space| {
        if (!enabled.eql(M31.one())) continue;
        if (addr_space.eql(M31.zero())) register_rows += 1;
        if (addr_space.eql(M31.one())) memory_rows += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), register_rows);
    try std.testing.expectEqual(@as(usize, 1), memory_rows);
}

// ---------------------------------------------------------------------------
// Preprocessed multiplicity additional tests
// ---------------------------------------------------------------------------

test "infra_trace: genPreprocessedMultiplicityColumns empty trace" {
    const allocator = std.testing.allocator;
    var exec_trace = trace_mod.Trace.init(allocator);
    defer exec_trace.deinit();

    var result = try genPreprocessedMultiplicityColumns(allocator, &exec_trace);
    defer freeMultiplicityColumns(allocator, &result.columns);

    // step_count=0 => @max(0,16) = 16 => log_size=4 => domain_size=16
    try std.testing.expectEqual(@as(u32, 4), result.log_size);
    try std.testing.expectEqual(@as(usize, 16), result.columns[0].len);

    // All should be zero (placeholder).
    for (result.columns[0]) |v| try std.testing.expect(v.isZero());
}

test "infra_trace: genPreprocessedMultiplicityColumns all tables same size" {
    const allocator = std.testing.allocator;
    var exec_trace = try makeSmallExecTrace(allocator);
    defer exec_trace.deinit();

    var result = try genPreprocessedMultiplicityColumns(allocator, &exec_trace);
    defer freeMultiplicityColumns(allocator, &result.columns);

    const expected_size = result.columns[0].len;
    for (result.columns) |col| {
        try std.testing.expectEqual(expected_size, col.len);
    }
}

test "infra_trace: multiplicityLogSize consistency" {
    const allocator = std.testing.allocator;
    var exec_trace = try makeSmallExecTrace(allocator);
    defer exec_trace.deinit();
    var result = try genPreprocessedMultiplicityColumns(allocator, &exec_trace);
    defer freeMultiplicityColumns(allocator, &result.columns);
    try std.testing.expectEqual(result.log_size, multiplicityLogSize(&exec_trace));
}
