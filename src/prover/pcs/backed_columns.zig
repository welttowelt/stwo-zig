//! Ownership helpers for column descriptors borrowing shared arenas.

const std = @import("std");
const M31 = @import("stwo_core").fields.m31.M31;
const ColumnEvaluation = @import("commitment_tree.zig").ColumnEvaluation;

pub fn detach(
    allocator: std.mem.Allocator,
    columns: []const ColumnEvaluation,
) ![]ColumnEvaluation {
    const detached = try allocator.alloc(ColumnEvaluation, columns.len);
    var initialized: usize = 0;
    errdefer {
        for (detached[0..initialized]) |column| allocator.free(column.values);
        allocator.free(detached);
    }
    for (columns, 0..) |column, index| {
        detached[index] = .{
            .log_size = column.log_size,
            .values = try allocator.dupe(M31, column.values),
        };
        initialized += 1;
    }
    return detached;
}

pub fn free(
    allocator: std.mem.Allocator,
    columns: []ColumnEvaluation,
    backing_buffers: [][]M31,
) void {
    allocator.free(columns);
    for (backing_buffers) |buffer| allocator.free(buffer);
    allocator.free(backing_buffers);
}
