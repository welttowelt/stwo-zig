//! Wide Fibonacci statement validation and trace preparation.

const std = @import("std");
const core_air_utils = @import("stwo_core").air.utils;
const m31 = @import("stwo_core").fields.m31;
const prover_pcs = @import("stwo_prover_impl").pcs;
const prover_transaction = @import("../common/prover_transaction.zig");

const M31 = m31.M31;

pub const Statement = struct {
    log_n_rows: u32,
    sequence_len: u32,
};

pub const PreparedInput = prover_transaction.PreparedInput(Statement);

pub const Error = prover_transaction.Error || error{
    InvalidLogSize,
    InvalidSequenceLength,
};

/// Generates a wide-fibonacci trace in bit-reversed circle-domain order.
///
/// For each row `i`, the sequence starts at `(a, b) = (1, i)` and evolves via
/// `c = a^2 + b^2`.
pub fn generate(
    allocator: std.mem.Allocator,
    statement: Statement,
) (std.mem.Allocator.Error || Error)![][]M31 {
    if (statement.log_n_rows == 0 or statement.log_n_rows >= 31) return error.InvalidLogSize;
    if (statement.sequence_len < 2) return error.InvalidSequenceLength;

    const n = checkedPow2(statement.log_n_rows) catch return error.InvalidLogSize;
    const n_cols: usize = @intCast(statement.sequence_len);

    const columns = try allocator.alloc([]M31, n_cols);
    errdefer allocator.free(columns);

    var initialized: usize = 0;
    errdefer for (columns[0..initialized]) |column| allocator.free(column);

    for (columns) |*column| {
        column.* = try allocator.alloc(M31, n);
        initialized += 1;
    }

    const bit_reversed_rows = try allocator.alloc(usize, n);
    defer allocator.free(bit_reversed_rows);
    for (0..n) |row| {
        bit_reversed_rows[row] = core_air_utils.circleBitReversedIndex(
            statement.log_n_rows,
            row,
        ) catch return error.InvalidLogSize;
    }

    const previous = try allocator.alloc(M31, n);
    defer allocator.free(previous);
    const current = try allocator.alloc(M31, n);
    defer allocator.free(current);

    for (0..n) |row| {
        const bit_reversed = bit_reversed_rows[row];
        previous[row] = M31.one();
        current[row] = M31.fromCanonical(@intCast(row));
        columns[0][bit_reversed] = previous[row];
        columns[1][bit_reversed] = current[row];
    }

    for (columns[2..]) |column| {
        for (0..n) |row| {
            const next = previous[row].square().add(current[row].square());
            column[bit_reversed_rows[row]] = next;
            previous[row] = current[row];
            current[row] = next;
        }
    }

    return columns;
}

pub fn deinit(allocator: std.mem.Allocator, columns: [][]M31) void {
    for (columns) |column| allocator.free(column);
    allocator.free(columns);
}

pub fn prepare(
    allocator: std.mem.Allocator,
    statement: Statement,
) (std.mem.Allocator.Error || Error)!PreparedInput {
    const columns = try generate(allocator, statement);
    var main = prover_transaction.OwnedColumns.init(
        try intoOwnedColumns(allocator, statement.log_n_rows, columns),
    );
    errdefer main.deinit(allocator);

    var preprocessed = prover_transaction.OwnedColumns.init(
        try allocator.alloc(prover_pcs.ColumnEvaluation, 0),
    );
    errdefer preprocessed.deinit(allocator);

    return .{
        .request = statement,
        .trace = try prover_transaction.PreparedTrace.initOwned(
            allocator,
            preprocessed.take(),
            main.take(),
        ),
    };
}

fn checkedPow2(log_size: u32) Error!usize {
    if (log_size >= @bitSizeOf(usize)) return error.InvalidLogSize;
    return @as(usize, 1) << @intCast(log_size);
}

fn intoOwnedColumns(
    allocator: std.mem.Allocator,
    log_n_rows: u32,
    trace: [][]M31,
) ![]prover_pcs.ColumnEvaluation {
    const columns = allocator.alloc(prover_pcs.ColumnEvaluation, trace.len) catch |err| {
        deinit(allocator, trace);
        return err;
    };

    for (trace, 0..) |column, index| {
        columns[index] = .{ .log_size = log_n_rows, .values = column };
    }
    allocator.free(trace);
    return columns;
}
