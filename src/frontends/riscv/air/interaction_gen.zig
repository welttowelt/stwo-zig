//! Interaction-tree (tree 2) column generation for the RISC-V LogUp buses.
//!
//! Operates on primitives (slices of trace rows, log sizes, drawn lookup
//! elements) so it never depends on the prover orchestration module.
//!
//! Layouts (M31 columns, committed bit-reversed circle-domain order):
//!  - Opcode component (8): [0..4) S_state, [4..8) S_program.
//!  - Program component (4): [0..4) S_rom.
//!
//! Every relation tuple input lives in the main tree, which is committed
//! before the lookup challenge is drawn. Tree 2 contains cumulative secure
//! columns only; putting tuple inputs here would let the prover adapt them to
//! the Fiat-Shamir challenge.
//! Each generator also produces the trace-order-shifted S coordinate columns
//! (`prev_*`), which are consumed by the on-domain constraint evaluator and
//! are NOT committed.

const std = @import("std");
const m31 = @import("../../../core/fields/m31.zig");
const qm31 = @import("../../../core/fields/qm31.zig");
const infra = @import("../infra_trace.zig");
const logup = @import("logup.zig");
const program_decode = @import("program/decode.zig");
const program_table = @import("program/table.zig");
const relation_challenges = @import("relation_challenges.zig");
const trace_mod = @import("../runner/trace.zig");

const M31 = m31.M31;
const QM31 = qm31.QM31;

/// M31 interaction columns committed per opcode component.
pub const OPCODE_INTERACTION_COLS: usize = 8;
/// M31 interaction columns committed for the program ROM component.
pub const PROGRAM_INTERACTION_COLS: usize = 4;

fn qFromU32(v: u32) QM31 {
    return QM31.fromBase(M31.fromU64(v & 0x7FFFFFFF));
}

fn allocColumns(
    allocator: std.mem.Allocator,
    comptime n: usize,
    domain_size: usize,
) ![n][]M31 {
    var columns: [n][]M31 = undefined;
    var allocated: usize = 0;
    errdefer for (0..allocated) |i| allocator.free(columns[i]);
    for (0..n) |i| {
        columns[i] = try allocator.alloc(M31, domain_size);
        allocated = i + 1;
        @memset(columns[i], M31.zero());
    }
    return columns;
}

pub fn freeColumns(allocator: std.mem.Allocator, columns: []const []M31) void {
    for (columns) |col| allocator.free(col);
}

/// Relation inputs committed in tree 1 before lookup challenges are drawn.
pub fn genOpcodeBusColumns(
    allocator: std.mem.Allocator,
    rows: []const trace_mod.TraceRow,
    log_size: u32,
) ![5][]M31 {
    const n = @as(usize, 1) << @intCast(log_size);
    if (rows.len > n) return error.InvalidTraceShape;
    var columns = try allocColumns(allocator, 5, n);
    errdefer freeColumns(allocator, &columns);
    const table = try infra.BitReversalTable.init(allocator, log_size);
    defer table.deinit(allocator);
    for (rows, 0..) |row, i| {
        const dst = table.map(i);
        const values = try program_decode.decodeProgramWord(row.inst_word);
        columns[0][dst] = M31.fromU64(row.next_pc & 0x7FFFFFFF);
        for (values, 0..) |value, column| columns[1 + column][dst] = M31.fromU64(value);
    }
    return columns;
}

/// Interaction columns for one opcode-family component shard.
pub const OpcodeInteraction = struct {
    columns: [OPCODE_INTERACTION_COLS][]M31,
    /// Trace-order shift of the S_state coordinates, committed order.
    prev_state: [4][]M31,
    /// Trace-order shift of the S_prog coordinates, committed order.
    prev_prog: [4][]M31,
    state_claim: QM31,
    prog_claim: QM31,

    pub fn deinit(self: *OpcodeInteraction, allocator: std.mem.Allocator) void {
        freeColumns(allocator, &self.columns);
        freeColumns(allocator, &self.prev_state);
        freeColumns(allocator, &self.prev_prog);
        self.* = undefined;
    }
};

/// Generate the interaction columns for one opcode component.
///
/// `rows` is the component's shard of its family's rows in execution order;
/// `rows.len` must not exceed the domain size. Padding rows carry zero
/// numerators (enabler 0) over the all-zero tuple.
pub fn genOpcodeInteraction(
    allocator: std.mem.Allocator,
    rows: []const trace_mod.TraceRow,
    log_size: u32,
    relations: *const relation_challenges.Relations,
) !OpcodeInteraction {
    const n = @as(usize, 1) << @intCast(log_size);
    std.debug.assert(rows.len <= n);

    const pairs_state = try allocator.alloc(logup.RowPair, n);
    defer allocator.free(pairs_state);
    const pairs_prog = try allocator.alloc(logup.RowPair, n);
    defer allocator.free(pairs_prog);
    for (0..n) |i| {
        if (i < rows.len) {
            const row = rows[i];
            const pc = qFromU32(row.pc);
            const program = try program_decode.decodeProgramWord(row.inst_word);
            pairs_state[i] = logup.stateChainPair(
                relations,
                pc,
                qFromU32(row.clk),
                qFromU32(row.next_pc),
                QM31.one(),
            );
            pairs_prog[i] = logup.programConsume(
                relations,
                pc,
                qFromU32(program[0]),
                qFromU32(program[1]),
                qFromU32(program[2]),
                qFromU32(program[3]),
                QM31.one(),
            );
        } else {
            const zero = QM31.zero();
            pairs_state[i] = logup.stateChainPair(relations, zero, zero, zero, zero);
            pairs_prog[i] = logup.programConsume(relations, zero, zero, zero, zero, zero, zero);
        }
    }

    var col_state = try logup.cumulativeColumn(allocator, pairs_state);
    defer col_state.deinit(allocator);
    var col_prog = try logup.cumulativeColumn(allocator, pairs_prog);
    defer col_prog.deinit(allocator);

    const table = try infra.BitReversalTable.init(allocator, log_size);
    defer table.deinit(allocator);

    var columns = try allocColumns(allocator, OPCODE_INTERACTION_COLS, n);
    errdefer freeColumns(allocator, &columns);
    var prev_state = try allocColumns(allocator, 4, n);
    errdefer freeColumns(allocator, &prev_state);
    var prev_prog = try allocColumns(allocator, 4, n);
    errdefer freeColumns(allocator, &prev_prog);

    for (0..n) |i| {
        const dst = table.map(i);
        const s = col_state.sums[i].toM31Array();
        const p = col_prog.sums[i].toM31Array();
        const s_prev = col_state.sums[(i + n - 1) % n].toM31Array();
        const p_prev = col_prog.sums[(i + n - 1) % n].toM31Array();
        for (0..4) |c| {
            columns[c][dst] = s[c];
            columns[4 + c][dst] = p[c];
            prev_state[c][dst] = s_prev[c];
            prev_prog[c][dst] = p_prev[c];
        }
    }

    return .{
        .columns = columns,
        .prev_state = prev_state,
        .prev_prog = prev_prog,
        .state_claim = col_state.claimed,
        .prog_claim = col_prog.claimed,
    };
}

/// Interaction columns for the program ROM component.
pub const ProgramInteraction = struct {
    columns: [PROGRAM_INTERACTION_COLS][]M31,
    /// Trace-order shift of the S_rom coordinates, committed order.
    prev_rom: [4][]M31,
    rom_claim: QM31,

    pub fn deinit(self: *ProgramInteraction, allocator: std.mem.Allocator) void {
        freeColumns(allocator, &self.columns);
        freeColumns(allocator, &self.prev_rom);
        self.* = undefined;
    }
};

/// Generate the ROM side of the program bus.
///
/// `exec_rows` is the FULL execution trace. Unique PCs are emitted in
/// first-occurrence order — the exact iteration order `genProgramColumns`
/// uses for the committed main columns — with their execution multiplicity
/// and the instruction word of the first row fetched at that pc.
pub fn genProgramInteraction(
    allocator: std.mem.Allocator,
    exec_rows: []const trace_mod.TraceRow,
    log_size: u32,
    relations: *const relation_challenges.Relations,
) !ProgramInteraction {
    const n = @as(usize, 1) << @intCast(log_size);
    const fetches = try allocator.alloc(program_table.Fetch, exec_rows.len);
    defer allocator.free(fetches);
    for (exec_rows, fetches) |row, *fetch| fetch.* = .{ .pc = row.pc, .word = row.inst_word };
    var decoded_table = try program_table.generate(allocator, fetches);
    defer decoded_table.deinit();
    if (decoded_table.rows.len > n) return error.InvalidTraceShape;

    const pairs = try allocator.alloc(logup.RowPair, n);
    defer allocator.free(pairs);
    for (0..n) |i| {
        if (i < decoded_table.rows.len) {
            const entry = decoded_table.rows[i];
            const values = entry.relationValues();
            pairs[i] = logup.programEmit(
                relations,
                qFromU32(values[0]),
                qFromU32(values[1]),
                qFromU32(values[2]),
                qFromU32(values[3]),
                qFromU32(values[4]),
                QM31.fromBase(M31.fromU64(entry.multiplicity)),
            );
        } else {
            const zero = QM31.zero();
            pairs[i] = logup.programEmit(relations, zero, zero, zero, zero, zero, zero);
        }
    }

    var col_rom = try logup.cumulativeColumn(allocator, pairs);
    defer col_rom.deinit(allocator);

    const placement_table = try infra.BitReversalTable.init(allocator, log_size);
    defer placement_table.deinit(allocator);

    var columns = try allocColumns(allocator, PROGRAM_INTERACTION_COLS, n);
    errdefer freeColumns(allocator, &columns);
    var prev_rom = try allocColumns(allocator, 4, n);
    errdefer freeColumns(allocator, &prev_rom);

    for (0..n) |i| {
        const dst = placement_table.map(i);
        const s = col_rom.sums[i].toM31Array();
        const s_prev = col_rom.sums[(i + n - 1) % n].toM31Array();
        for (0..4) |c| {
            columns[c][dst] = s[c];
            prev_rom[c][dst] = s_prev[c];
        }
    }

    return .{
        .columns = columns,
        .prev_rom = prev_rom,
        .rom_claim = col_rom.claimed,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn testRelations() relation_challenges.Relations {
    return relation_challenges.Relations.dummy();
}

fn testRow(clk: u32, pc: u32, next_pc: u32, inst_word: u32) trace_mod.TraceRow {
    return .{
        .clk = clk,
        .pc = pc,
        .opcode = .ADDI,
        .rd = 1,
        .rs1 = 0,
        .rs2 = 0,
        .imm = 0,
        .rs1_val = 0,
        .rs2_val = 0,
        .rd_val = 0,
        .mem_addr = 0,
        .mem_val = 0,
        .is_load = false,
        .is_store = false,
        .branch_taken = false,
        .next_pc = next_pc,
        .inst_word = inst_word,
    };
}

test "interaction_gen: claims telescope across shards and the program bus balances" {
    const allocator = std.testing.allocator;
    const relations = testRelations();

    // Four-step execution split across two shards; pc 0x1008 repeats.
    const rows = [_]trace_mod.TraceRow{
        testRow(1, 0x1000, 0x1004, 0x00A00093),
        testRow(2, 0x1004, 0x1008, 0x01400113),
        testRow(3, 0x1008, 0x1004, 0x002081B3),
        testRow(4, 0x1004, 0x100C, 0x01400113),
    };

    var shard_a = try genOpcodeInteraction(allocator, rows[0..2], 1, &relations);
    defer shard_a.deinit(allocator);
    var shard_b = try genOpcodeInteraction(allocator, rows[2..4], 1, &relations);
    defer shard_b.deinit(allocator);
    var rom = try genProgramInteraction(allocator, rows[0..], 2, &relations);
    defer rom.deinit(allocator);

    // CPU state chain: shard claims + public boundary cancel exactly.
    const boundary = try logup.stateBoundary(&relations, 0x1000, 0x100C, 4);
    try logup.verifyGlobalCancellation(
        &.{ shard_a.state_claim, shard_b.state_claim },
        boundary,
    );

    // Program bus: consumes + ROM emissions cancel exactly on their own.
    try logup.verifyGlobalCancellation(
        &.{ shard_a.prog_claim, shard_b.prog_claim, rom.rom_claim },
        QM31.zero(),
    );

    // A wrong boundary is rejected.
    const bad_boundary = try logup.stateBoundary(&relations, 0x1000, 0x1010, 4);
    try std.testing.expectError(error.LogupSumNonZero, logup.verifyGlobalCancellation(
        &.{ shard_a.state_claim, shard_b.state_claim },
        bad_boundary,
    ));
}

test "interaction_gen: columns are placed in committed order with wrapped shift" {
    const allocator = std.testing.allocator;
    const relations = testRelations();

    const rows = [_]trace_mod.TraceRow{
        testRow(1, 0x1000, 0x1004, 0x00A00093),
        testRow(2, 0x1004, 0x1008, 0x01400113),
        testRow(3, 0x1008, 0x100C, 0x002081B3),
    };
    const log_size: u32 = 2;
    const n: usize = 1 << log_size;

    var gen = try genOpcodeInteraction(allocator, rows[0..], log_size, &relations);
    defer gen.deinit(allocator);
    const bus = try genOpcodeBusColumns(allocator, rows[0..], log_size);
    defer freeColumns(allocator, &bus);

    const table = try infra.BitReversalTable.init(allocator, log_size);
    defer table.deinit(allocator);

    for (0..n) |i| {
        const dst = table.map(i);
        if (i < rows.len) {
            const values = try program_decode.decodeProgramWord(rows[i].inst_word);
            try std.testing.expect(bus[0][dst].eql(M31.fromU64(rows[i].next_pc)));
            for (values, 0..) |value, column| {
                try std.testing.expect(bus[1 + column][dst].eql(M31.fromU64(value)));
            }
        } else {
            try std.testing.expect(bus[0][dst].eql(M31.zero()));
        }
        // prev columns are the wrapped trace-order shift of the S columns.
        const src = table.map((i + n - 1) % n);
        for (0..4) |c| {
            try std.testing.expect(gen.prev_state[c][dst].eql(gen.columns[c][src]));
            try std.testing.expect(gen.prev_prog[c][dst].eql(gen.columns[4 + c][src]));
        }
    }

    // The committed S column at the last trace row equals the claimed sum.
    const last = table.map(n - 1);
    const s_last = QM31.fromM31(
        gen.columns[0][last],
        gen.columns[1][last],
        gen.columns[2][last],
        gen.columns[3][last],
    );
    try std.testing.expect(s_last.eql(gen.state_claim));
}

test "interaction_gen: program cumulative column closes the ROM claim" {
    const allocator = std.testing.allocator;
    const relations = testRelations();

    const rows = [_]trace_mod.TraceRow{
        testRow(1, 0x2000, 0x2004, 0x00100093),
        testRow(2, 0x2004, 0x2000, 0x00200113),
        testRow(3, 0x2000, 0x2008, 0x00100093),
        testRow(4, 0x2008, 0x200C, 0x00300193),
    };
    var rom = try genProgramInteraction(allocator, rows[0..], 2, &relations);
    defer rom.deinit(allocator);

    const table = try infra.BitReversalTable.init(allocator, 2);
    defer table.deinit(allocator);

    const last = table.map(3);
    const claimed = QM31.fromM31(
        rom.columns[0][last],
        rom.columns[1][last],
        rom.columns[2][last],
        rom.columns[3][last],
    );
    try std.testing.expect(claimed.eql(rom.rom_claim));
}

test "interaction_gen: one program counter cannot name two instruction words" {
    const allocator = std.testing.allocator;
    const relations = testRelations();
    const rows = [_]trace_mod.TraceRow{
        testRow(1, 0x2000, 0x2004, 0x0010_0093),
        testRow(2, 0x2000, 0x2004, 0x0020_0093),
    };
    try std.testing.expectError(
        error.ProgramWordChanged,
        genProgramInteraction(allocator, &rows, 1, &relations),
    );
}
