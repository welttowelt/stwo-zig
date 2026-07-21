//! FRI layer decommitment position and witness collection.

const std = @import("std");
const qm31 = @import("stwo_core").fields.qm31;
const secure_column = @import("../secure_column.zig");

const QM31 = qm31.QM31;

pub const Error = error{
    QueryOutOfRange,
    FoldStepTooLarge,
};

pub const ValueEntry = struct {
    position: usize,
    value: QM31,
};

pub const Result = struct {
    decommitment_positions: []usize,
    witness_evals: []QM31,
    value_map: []ValueEntry,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.decommitment_positions);
        allocator.free(self.witness_evals);
        allocator.free(self.value_map);
        self.* = undefined;
    }
};

/// Returns Merkle decommitment positions and witness evaluations for a secure
/// field slice. `query_positions` must be sorted in ascending order.
pub fn fromSecureSlice(
    allocator: std.mem.Allocator,
    column: []const QM31,
    query_positions: []const usize,
    fold_step: u32,
) (std.mem.Allocator.Error || Error)!Result {
    if (fold_step >= @bitSizeOf(usize)) return Error.FoldStepTooLarge;

    var decommitment_positions = std.ArrayList(usize).empty;
    defer decommitment_positions.deinit(allocator);
    var witness_evals = std.ArrayList(QM31).empty;
    defer witness_evals.deinit(allocator);
    var value_map = std.ArrayList(ValueEntry).empty;
    defer value_map.deinit(allocator);

    const subset_len = @as(usize, 1) << @intCast(fold_step);
    var subset_start_idx: usize = 0;
    while (subset_start_idx < query_positions.len) {
        const subset_key = query_positions[subset_start_idx] >> @intCast(fold_step);
        var subset_end_idx = subset_start_idx + 1;
        while (subset_end_idx < query_positions.len and
            (query_positions[subset_end_idx] >> @intCast(fold_step)) == subset_key)
        {
            subset_end_idx += 1;
        }

        const subset_queries = query_positions[subset_start_idx..subset_end_idx];
        const subset_start = subset_key << @intCast(fold_step);
        var subset_query_at: usize = 0;

        var position = subset_start;
        while (position < subset_start + subset_len) : (position += 1) {
            if (position >= column.len) return Error.QueryOutOfRange;

            try decommitment_positions.append(allocator, position);
            const eval = column[position];
            try value_map.append(allocator, .{
                .position = position,
                .value = eval,
            });

            if (subset_query_at < subset_queries.len and
                subset_queries[subset_query_at] == position)
            {
                subset_query_at += 1;
            } else {
                try witness_evals.append(allocator, eval);
            }
        }

        subset_start_idx = subset_end_idx;
    }

    return .{
        .decommitment_positions = try decommitment_positions.toOwnedSlice(allocator),
        .witness_evals = try witness_evals.toOwnedSlice(allocator),
        .value_map = try value_map.toOwnedSlice(allocator),
    };
}

/// Coordinate-column equivalent of `fromSecureSlice`, avoiding temporary
/// secure-field materialization.
pub fn fromCoords(
    allocator: std.mem.Allocator,
    column: secure_column.SecureColumnByCoords,
    query_positions: []const usize,
    fold_step: u32,
) (std.mem.Allocator.Error || Error)!Result {
    if (fold_step >= @bitSizeOf(usize)) return Error.FoldStepTooLarge;

    var decommitment_positions = std.ArrayList(usize).empty;
    defer decommitment_positions.deinit(allocator);
    var witness_evals = std.ArrayList(QM31).empty;
    defer witness_evals.deinit(allocator);
    var value_map = std.ArrayList(ValueEntry).empty;
    defer value_map.deinit(allocator);

    const subset_len = @as(usize, 1) << @intCast(fold_step);
    var subset_start_idx: usize = 0;
    while (subset_start_idx < query_positions.len) {
        const subset_key = query_positions[subset_start_idx] >> @intCast(fold_step);
        var subset_end_idx = subset_start_idx + 1;
        while (subset_end_idx < query_positions.len and
            (query_positions[subset_end_idx] >> @intCast(fold_step)) == subset_key)
        {
            subset_end_idx += 1;
        }

        const subset_queries = query_positions[subset_start_idx..subset_end_idx];
        const subset_start = subset_key << @intCast(fold_step);
        var subset_query_at: usize = 0;
        for (subset_start..subset_start + subset_len) |position| {
            if (position >= column.len()) return Error.QueryOutOfRange;
            const eval = column.at(position);
            try decommitment_positions.append(allocator, position);
            try value_map.append(allocator, .{ .position = position, .value = eval });
            if (subset_query_at < subset_queries.len and
                subset_queries[subset_query_at] == position)
            {
                subset_query_at += 1;
            } else {
                try witness_evals.append(allocator, eval);
            }
        }
        subset_start_idx = subset_end_idx;
    }

    return .{
        .decommitment_positions = try decommitment_positions.toOwnedSlice(allocator),
        .witness_evals = try witness_evals.toOwnedSlice(allocator),
        .value_map = try value_map.toOwnedSlice(allocator),
    };
}
