//! XOR statement validation and owned trace preparation.

const std = @import("std");
const core_air_utils = @import("stwo_core").air.utils;
const m31 = @import("stwo_core").fields.m31;
const utils = @import("stwo_core").utils;
const prover_pcs = @import("stwo_prover_impl").pcs;
const prover_transaction = @import("../common/prover_transaction.zig");

const M31 = m31.M31;

pub const Statement = struct {
    log_size: u32,
    log_step: u32,
    offset: usize,
};

pub const PreparedInput = prover_transaction.PreparedInput(Statement);

pub const Error = prover_transaction.Error || error{
    InvalidLogSize,
    InvalidStep,
};

pub fn validate(statement: Statement) Error!void {
    if (statement.log_size == 0) return error.InvalidLogSize;
    if (statement.log_step > statement.log_size) return error.InvalidStep;
}

/// Generates `IsFirst` preprocessed values in bit-reversed order.
pub fn genIsFirstColumn(
    allocator: std.mem.Allocator,
    log_size: u32,
) (std.mem.Allocator.Error || Error)![]M31 {
    return core_air_utils.genIsFirstColumn(allocator, log_size);
}

/// Generates `IsStepWithOffset` preprocessed values in bit-reversed order.
pub fn genIsStepWithOffsetColumn(
    allocator: std.mem.Allocator,
    log_size: u32,
    log_step: u32,
    offset: usize,
) (std.mem.Allocator.Error || Error)![]M31 {
    return core_air_utils.genPeriodicIndicatorColumn(allocator, log_size, log_step, offset);
}

pub fn prepare(
    allocator: std.mem.Allocator,
    statement: Statement,
) (std.mem.Allocator.Error || Error)!PreparedInput {
    try validate(statement);

    const is_first = try genIsFirstColumn(allocator, statement.log_size);
    var is_first_moved = false;
    errdefer if (!is_first_moved) allocator.free(is_first);
    const is_step = try genIsStepWithOffsetColumn(
        allocator,
        statement.log_size,
        statement.log_step,
        statement.offset,
    );
    var is_step_moved = false;
    errdefer if (!is_step_moved) allocator.free(is_step);

    const preprocessed_columns = try allocator.alloc(prover_pcs.ColumnEvaluation, 2);
    preprocessed_columns[0] = .{ .log_size = statement.log_size, .values = is_first };
    preprocessed_columns[1] = .{ .log_size = statement.log_size, .values = is_step };
    is_first_moved = true;
    is_step_moved = true;
    var preprocessed = prover_transaction.OwnedColumns.init(preprocessed_columns);
    errdefer preprocessed.deinit(allocator);

    const main_values = try genMainColumn(allocator, statement.log_size);
    var main_values_moved = false;
    errdefer if (!main_values_moved) allocator.free(main_values);
    const main_columns = try allocator.alloc(prover_pcs.ColumnEvaluation, 1);
    main_columns[0] = .{ .log_size = statement.log_size, .values = main_values };
    main_values_moved = true;
    var main = prover_transaction.OwnedColumns.init(main_columns);
    errdefer main.deinit(allocator);

    return .{
        .request = statement,
        .trace = try prover_transaction.PreparedTrace.initOwned(
            allocator,
            preprocessed.take(),
            main.take(),
        ),
    };
}

fn genMainColumn(
    allocator: std.mem.Allocator,
    log_size: u32,
) (std.mem.Allocator.Error || Error)![]M31 {
    const n = try checkedPow2(log_size);
    const values = try allocator.alloc(M31, n);
    @memset(values, M31.zero());

    for (0..n) |i| {
        const circle_domain_index = utils.cosetIndexToCircleDomainIndex(i, log_size);
        const bit_rev_index = utils.bitReverseIndex(circle_domain_index, log_size);
        values[bit_rev_index] = if ((i & 1) == 0) M31.one() else M31.zero();
    }
    return values;
}

fn checkedPow2(log_size: u32) Error!usize {
    if (log_size >= @bitSizeOf(usize)) return error.InvalidLogSize;
    return @as(usize, 1) << @intCast(log_size);
}
