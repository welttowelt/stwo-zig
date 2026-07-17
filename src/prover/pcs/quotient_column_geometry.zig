const std = @import("std");
const m31 = @import("../../core/fields/m31.zig");
const pcs_utils = @import("../../core/pcs/utils.zig");

const M31 = m31.M31;
const TreeVec = pcs_utils.TreeVec;

pub const QuotientOpsError = error{
    ShapeMismatch,
    InvalidColumnLogSize,
    InvalidColumnLength,
};

/// Borrowed evaluations of one circle-domain column.
///
/// Lifting preserves Stwo's circle-domain storage order: each source pair is
/// repeated across the corresponding pair-aligned block in the larger domain.
pub const ColumnEvaluation = struct {
    log_size: u32,
    values: []const M31,

    pub fn validate(self: ColumnEvaluation) QuotientOpsError!void {
        const expected_len = try checkedPow2(self.log_size);
        if (self.values.len != expected_len) return QuotientOpsError.InvalidColumnLength;
    }

    pub fn valueAtLiftingPosition(
        self: ColumnEvaluation,
        lifting_log_size: u32,
        position: usize,
    ) QuotientOpsError!M31 {
        try self.validate();
        if (self.log_size > lifting_log_size) return QuotientOpsError.InvalidColumnLogSize;

        const lifting_domain_size = try checkedPow2(lifting_log_size);
        if (position >= lifting_domain_size) return QuotientOpsError.ShapeMismatch;

        const log_shift = lifting_log_size - self.log_size;
        if (log_shift >= @bitSizeOf(usize)) return QuotientOpsError.InvalidColumnLogSize;
        const shift_amt: std.math.Log2Int(usize) = @intCast(log_shift + 1);

        const index = ((position >> shift_amt) << 1) + (position & 1);
        if (index >= self.values.len) return QuotientOpsError.InvalidColumnLength;
        return self.values[index];
    }
};

/// Returns the exact domain size for a representable binary log size.
pub fn checkedPow2(log_size: u32) QuotientOpsError!usize {
    if (log_size >= @bitSizeOf(usize)) return QuotientOpsError.InvalidColumnLogSize;
    return @as(usize, 1) << @intCast(log_size);
}

/// Flattens tree-major columns without taking ownership of their evaluations.
pub fn flattenColumnsBorrowed(
    allocator: std.mem.Allocator,
    columns: TreeVec([]const ColumnEvaluation),
) ![]ColumnEvaluation {
    const flattened = try allocator.alloc(ColumnEvaluation, countColumns(columns));
    var write_index: usize = 0;
    for (columns.items) |tree_columns| {
        for (tree_columns) |column| {
            flattened[write_index] = column;
            write_index += 1;
        }
    }
    return flattened;
}

/// Projects the tree/column shape into an independently owned log-size tree.
pub fn buildColumnLogSizes(
    allocator: std.mem.Allocator,
    columns: TreeVec([]const ColumnEvaluation),
) !TreeVec([]u32) {
    const log_size_trees = try allocator.alloc([]u32, columns.items.len);
    errdefer allocator.free(log_size_trees);

    var initialized: usize = 0;
    errdefer {
        for (log_size_trees[0..initialized]) |tree_sizes| allocator.free(tree_sizes);
    }

    for (columns.items, 0..) |tree_columns, tree_index| {
        log_size_trees[tree_index] = try allocator.alloc(u32, tree_columns.len);
        initialized += 1;
        for (tree_columns, 0..) |column, column_index| {
            log_size_trees[tree_index][column_index] = column.log_size;
        }
    }

    return TreeVec([]u32).initOwned(log_size_trees);
}

/// Counts columns across all trees without flattening them.
pub fn countColumns(columns: TreeVec([]const ColumnEvaluation)) usize {
    var total: usize = 0;
    for (columns.items) |tree_columns| total += tree_columns.len;
    return total;
}

test "quotient column geometry preserves pair-aligned lifting order" {
    const values = [_]M31{
        M31.fromCanonical(10),
        M31.fromCanonical(11),
        M31.fromCanonical(20),
        M31.fromCanonical(21),
    };
    const column = ColumnEvaluation{ .log_size = 2, .values = &values };
    const expected = [_]u32{ 10, 11, 10, 11, 10, 11, 10, 11, 20, 21, 20, 21, 20, 21, 20, 21 };

    for (expected, 0..) |value, position| {
        try std.testing.expectEqual(value, (try column.valueAtLiftingPosition(4, position)).v);
    }
}

test "quotient column geometry rejects invalid lengths and positions" {
    const values = [_]M31{ M31.one(), M31.one(), M31.one() };
    const column = ColumnEvaluation{ .log_size = 2, .values = &values };

    try std.testing.expectError(QuotientOpsError.InvalidColumnLength, column.validate());
    try std.testing.expectError(
        QuotientOpsError.InvalidColumnLogSize,
        checkedPow2(@bitSizeOf(usize)),
    );

    const valid_values = [_]M31{ M31.one(), M31.zero(), M31.one(), M31.zero() };
    const valid_column = ColumnEvaluation{ .log_size = 2, .values = &valid_values };
    try std.testing.expectError(
        QuotientOpsError.ShapeMismatch,
        valid_column.valueAtLiftingPosition(3, 8),
    );
    try std.testing.expectError(
        QuotientOpsError.InvalidColumnLogSize,
        valid_column.valueAtLiftingPosition(1, 0),
    );
}

test "quotient column tree geometry retains tree and column order" {
    const values_a = [_]M31{M31.one()} ** 2;
    const values_b = [_]M31{M31.one()} ** 4;
    const values_c = [_]M31{M31.one()} ** 8;
    const tree_a = [_]ColumnEvaluation{
        .{ .log_size = 1, .values = &values_a },
        .{ .log_size = 2, .values = &values_b },
    };
    const tree_b = [_]ColumnEvaluation{
        .{ .log_size = 3, .values = &values_c },
    };
    var trees = [_][]const ColumnEvaluation{ &tree_a, &tree_b };
    const columns = TreeVec([]const ColumnEvaluation).initOwned(&trees);

    try std.testing.expectEqual(@as(usize, 3), countColumns(columns));

    const flattened = try flattenColumnsBorrowed(std.testing.allocator, columns);
    defer std.testing.allocator.free(flattened);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, &.{
        flattened[0].log_size,
        flattened[1].log_size,
        flattened[2].log_size,
    });

    var log_sizes = try buildColumnLogSizes(std.testing.allocator, columns);
    defer log_sizes.deinitDeep(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), log_sizes.items.len);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2 }, log_sizes.items[0]);
    try std.testing.expectEqualSlices(u32, &.{3}, log_sizes.items[1]);
}
