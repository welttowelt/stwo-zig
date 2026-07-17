//! Owned Poseidon trace preparation for backend-neutral proving.

const std = @import("std");
const m31 = @import("../../core/fields/m31.zig");
const prover_pcs = @import("../../prover/pcs/mod.zig");
const prover_transaction = @import("../common/prover_transaction.zig");

const M31 = m31.M31;

pub const N_LOG_INSTANCES_PER_ROW: u32 = 3;
pub const N_INSTANCES_PER_ROW: usize = 1 << N_LOG_INSTANCES_PER_ROW;
pub const N_STATE: usize = 16;
pub const N_PARTIAL_ROUNDS: usize = 14;
pub const N_HALF_FULL_ROUNDS: usize = 4;
pub const N_FULL_ROUNDS: usize = N_HALF_FULL_ROUNDS * 2;
pub const N_COLUMNS_PER_REP: usize = N_STATE * (1 + N_FULL_ROUNDS) + N_PARTIAL_ROUNDS;
pub const N_COLUMNS: usize = N_COLUMNS_PER_REP * N_INSTANCES_PER_ROW;

pub const Statement = struct {
    log_n_instances: u32,
};

pub const PreparedInput = prover_transaction.PreparedInput(Statement);

pub const Error = prover_transaction.Error || error{
    InvalidLogNInstances,
};

pub fn validate(statement: Statement) Error!void {
    _ = try logNRows(statement);
}

pub fn logNRows(statement: Statement) Error!u32 {
    if (statement.log_n_instances < N_LOG_INSTANCES_PER_ROW)
        return error.InvalidLogNInstances;
    const log_n_rows = statement.log_n_instances - N_LOG_INSTANCES_PER_ROW;
    if (log_n_rows >= 31) return error.InvalidLogNInstances;
    return log_n_rows;
}

pub fn genTrace(
    allocator: std.mem.Allocator,
    statement: Statement,
) (std.mem.Allocator.Error || Error)![][]M31 {
    const log_n_rows = try logNRows(statement);
    const n = try checkedPow2(log_n_rows);

    const trace = try allocator.alloc([]M31, N_COLUMNS);
    errdefer allocator.free(trace);

    var initialized: usize = 0;
    errdefer for (trace[0..initialized]) |column| allocator.free(column);

    for (trace) |*column| {
        column.* = try allocator.alloc(M31, n);
        @memset(column.*, M31.zero());
        initialized += 1;
    }

    for (0..n) |row| fillRow(trace, row);
    return trace;
}

pub fn deinitTrace(allocator: std.mem.Allocator, trace: [][]M31) void {
    for (trace) |column| allocator.free(column);
    allocator.free(trace);
}

pub fn prepare(
    allocator: std.mem.Allocator,
    statement: Statement,
) (std.mem.Allocator.Error || Error)!PreparedInput {
    const log_n_rows = try logNRows(statement);
    const trace = try genTrace(allocator, statement);
    var trace_moved = false;
    defer if (!trace_moved) deinitTrace(allocator, trace);

    const preprocessed = try allocator.alloc(prover_pcs.ColumnEvaluation, 0);
    var preprocessed_owner = prover_transaction.OwnedColumns.init(preprocessed);
    errdefer preprocessed_owner.deinit(allocator);

    const main = try allocator.alloc(prover_pcs.ColumnEvaluation, trace.len);
    var main_owner = prover_transaction.OwnedColumns.init(main);
    errdefer main_owner.deinit(allocator);
    for (trace, 0..) |values, index| {
        main[index] = .{ .log_size = log_n_rows, .values = values };
    }
    allocator.free(trace);
    trace_moved = true;

    return .{
        .request = statement,
        .trace = try prover_transaction.PreparedTrace.initOwned(
            allocator,
            preprocessed_owner.take(),
            main_owner.take(),
        ),
    };
}

fn fillRow(trace: [][]M31, row: usize) void {
    var column_index: usize = 0;
    for (0..N_INSTANCES_PER_ROW) |rep_i| {
        var state: [N_STATE]M31 = undefined;
        for (0..N_STATE) |state_i| {
            state[state_i] = M31.fromU64(
                @as(u64, @intCast(row * N_STATE + state_i + rep_i)),
            );
            trace[column_index][row] = state[state_i];
            column_index += 1;
        }

        for (0..N_HALF_FULL_ROUNDS) |round| {
            applyExternalRound(&state, round);
            for (0..N_STATE) |state_i| {
                trace[column_index][row] = state[state_i];
                column_index += 1;
            }
        }

        for (0..N_PARTIAL_ROUNDS) |round| {
            state[0] = state[0].add(internalRoundConst(round));
            applyInternalRoundMatrix(&state);
            state[0] = pow5(state[0]);
            trace[column_index][row] = state[0];
            column_index += 1;
        }

        for (0..N_HALF_FULL_ROUNDS) |half_round| {
            applyExternalRound(&state, half_round + N_HALF_FULL_ROUNDS);
            for (0..N_STATE) |state_i| {
                trace[column_index][row] = state[state_i];
                column_index += 1;
            }
        }
    }
    std.debug.assert(column_index == N_COLUMNS);
}

fn applyExternalRound(state: *[N_STATE]M31, round: usize) void {
    for (0..N_STATE) |state_i| {
        state[state_i] = state[state_i].add(externalRoundConst(round, state_i));
    }
    applyExternalRoundMatrix(state);
    for (0..N_STATE) |state_i| state[state_i] = pow5(state[state_i]);
}

fn checkedPow2(log_size: u32) Error!usize {
    if (log_size >= @bitSizeOf(usize)) return error.InvalidLogNInstances;
    return @as(usize, 1) << @intCast(log_size);
}

fn pow5(x: M31) M31 {
    const x2 = x.mul(x);
    const x4 = x2.mul(x2);
    return x4.mul(x);
}

fn externalRoundConst(round: usize, state_i: usize) M31 {
    return M31.fromU64(
        1234 + (@as(u64, @intCast(round)) * 37) + @as(u64, @intCast(state_i)),
    );
}

fn internalRoundConst(round: usize) M31 {
    return M31.fromU64(9876 + (@as(u64, @intCast(round)) * 17));
}

fn applyM4(x: [4]M31) [4]M31 {
    const t0 = x[0].add(x[1]);
    const t02 = t0.add(t0);
    const t1 = x[2].add(x[3]);
    const t12 = t1.add(t1);
    const t2 = x[1].add(x[1]).add(t1);
    const t3 = x[3].add(x[3]).add(t0);
    const t4 = t12.add(t12).add(t3);
    const t5 = t02.add(t02).add(t2);
    const t6 = t3.add(t5);
    const t7 = t2.add(t4);
    return .{ t6, t5, t7, t4 };
}

fn applyExternalRoundMatrix(state: *[N_STATE]M31) void {
    for (0..4) |i| {
        const offset = i * 4;
        const mixed = applyM4(.{
            state[offset],
            state[offset + 1],
            state[offset + 2],
            state[offset + 3],
        });
        for (0..4) |j| state[offset + j] = mixed[j];
    }

    for (0..4) |j| {
        const sum = state[j].add(state[j + 4]).add(state[j + 8]).add(state[j + 12]);
        for (0..4) |i| {
            const index = i * 4 + j;
            state[index] = state[index].add(sum);
        }
    }
}

fn applyInternalRoundMatrix(state: *[N_STATE]M31) void {
    var sum = state[0];
    for (1..N_STATE) |i| sum = sum.add(state[i]);
    for (0..N_STATE) |i| {
        const coefficient = M31.fromU64(@as(u64, 1) << @intCast(i + 1));
        state[i] = state[i].mul(coefficient).add(sum);
    }
}
