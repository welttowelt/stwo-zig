//! Structural quadratic-recurrence trace dispatch and telemetry.

const std = @import("std");
const M31 = @import("stwo_core").fields.m31.M31;
const shared_runtime = @import("../shared_runtime.zig");
const telemetry = @import("../telemetry.zig");

pub const min_cells: usize = 1 << 20;

pub fn admits(row_count: usize, column_count: usize) bool {
    const cells = std.math.mul(usize, row_count, column_count) catch return false;
    return column_count >= 2 and column_count <= 256 and cells >= min_cells;
}

pub fn fill(columns: [][]M31, log_n_rows: u32, recipe: [7]u32) !void {
    if (columns.len < 2 or columns.len > 256 or log_n_rows == 0 or log_n_rows >= 31)
        return error.InvalidColumns;
    const row_count: usize = @as(usize, 1) << @intCast(log_n_rows);
    var pointers: [256][*]u32 = undefined;
    for (columns, 0..) |column, index| {
        if (column.len != row_count) return error.InvalidColumns;
        pointers[index] = @ptrCast(column.ptr);
    }

    var lease = try shared_runtime.acquireExisting();
    defer lease.deinit();
    const stats = try lease.runtime.quadraticRecurrenceTrace(
        pointers[0..columns.len],
        @intCast(row_count),
        log_n_rows,
        recipe,
    );
    telemetry.record(.metal_trace_generation_dispatch);
    telemetry.record(.metal_trace_generation_synchronization);
    if (stats.copyback_columns != 0) telemetry.record(.metal_trace_generation_copyback);
    std.log.debug(
        "Metal quadratic recurrence trace: {d:.3}ms, copyback columns={}",
        .{ stats.gpu_ms, stats.copyback_columns },
    );
}
