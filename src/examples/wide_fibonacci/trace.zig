//! Wide Fibonacci statement validation and trace preparation.

const std = @import("std");
const core_air_utils = @import("../../core/air/utils.zig");
const m31 = @import("../../core/fields/m31.zig");
const prover_pcs = @import("../../prover/pcs/mod.zig");

const M31 = m31.M31;

pub const Statement = struct {
    log_n_rows: u32,
    sequence_len: u32,
};

pub const PreparedInput = struct {
    statement: Statement,
    columns: []prover_pcs.ColumnEvaluation,

    pub fn deinit(self: *PreparedInput, allocator: std.mem.Allocator) void {
        for (self.columns) |column| allocator.free(column.values);
        allocator.free(self.columns);
        self.* = undefined;
    }
};

pub const Error = error{
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
    return .{
        .statement = statement,
        .columns = try intoOwnedColumns(allocator, statement.log_n_rows, columns),
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
