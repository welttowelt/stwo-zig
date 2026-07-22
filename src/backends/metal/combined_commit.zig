//! One-submit circle LDE and resident Merkle commitment for large uniform trees.

const std = @import("std");
const m31 = @import("stwo_core").fields.m31;
const prover = @import("stwo_prover_impl");
const metal_merkle = @import("merkle_tree.zig");
const shared_runtime = @import("shared_runtime.zig");
const telemetry = @import("telemetry.zig");

const M31 = m31.M31;
const ColumnEvaluation = prover.pcs.ColumnEvaluation;
const CircleCoefficients = prover.poly.circle.CircleCoefficients;
const min_base_log_size: u32 = 16;
const min_columns: usize = 64;
const max_columns: usize = 256;

fn PreparedCommitment(comptime H: type) type {
    return struct {
        columns: []ColumnEvaluation,
        coefficients: []CircleCoefficients,
        column_backing_buffers: [][]M31,
        coefficient_backing_buffers: [][]M31,
        commitment: metal_merkle.MetalMerkleTree(H),
    };
}

/// Takes ownership only when the combined Metal epoch succeeds. Returning
/// `null` leaves every input column untouched for the generic fallback.
pub fn prepareAndCommitOwned(
    comptime H: type,
    allocator: std.mem.Allocator,
    owned_columns: []ColumnEvaluation,
    log_blowup_factor: u32,
    retention_policy: anytype,
    twiddle_source: anytype,
) !?PreparedCommitment(H) {
    if (retention_policy != .always or log_blowup_factor != 1 or
        owned_columns.len < min_columns or owned_columns.len > max_columns)
        return null;

    const base_log_size = owned_columns[0].log_size;
    if (base_log_size < min_base_log_size or base_log_size >= @bitSizeOf(usize) - 1) return null;
    const base_len = @as(usize, 1) << @intCast(base_log_size);
    for (owned_columns) |column| {
        column.validate() catch return null;
        if (column.log_size != base_log_size or column.values.len != base_len) return null;
    }

    const extended_log_size = base_log_size + 1;
    const extended_len = @as(usize, 1) << @intCast(extended_log_size);
    const page_words = std.heap.pageSize() / @sizeOf(M31);
    const page_rotate = owned_columns.len >= 64 and extended_len >= (1 << 18);
    const extended_stride = extended_len +
        @as(usize, if (page_rotate) page_words + 16 else 16);
    const extended_span = try std.math.add(
        usize,
        try std.math.mul(usize, owned_columns.len - 1, extended_stride),
        extended_len,
    );
    const backing_words = std.mem.alignForward(usize, extended_span, page_words);

    const base_buffer = try allocator.alloc(
        M31,
        try std.math.mul(usize, owned_columns.len, base_len),
    );
    var keep_base = false;
    defer if (!keep_base) allocator.free(base_buffer);
    const transform_buffer = try allocator.alloc(M31, backing_words);
    var keep_transform = false;
    defer if (!keep_transform) allocator.free(transform_buffer);

    const source_values = try allocator.alloc([]const M31, owned_columns.len);
    defer allocator.free(source_values);
    const base_values = try allocator.alloc([]M31, owned_columns.len);
    defer allocator.free(base_values);
    const extended_values = try allocator.alloc([]M31, owned_columns.len);
    defer allocator.free(extended_values);
    for (owned_columns, 0..) |column, index| {
        source_values[index] = column.values;
        base_values[index] = base_buffer[index * base_len ..][0..base_len];
        extended_values[index] = transform_buffer[index * extended_stride ..][0..extended_len];
    }

    const base_twiddles = try twiddle_source.get(allocator, base_log_size);
    const extended_twiddles = try twiddle_source.get(allocator, extended_log_size);
    var lease = shared_runtime.acquireExisting() catch return null;
    defer lease.deinit();
    const result = lease.runtime.transformCircleLdeAndCommit(
        allocator,
        source_values,
        base_values,
        extended_values,
        transform_buffer,
        0,
        extended_stride,
        base_twiddles.itwiddles,
        extended_twiddles.twiddles,
        base_log_size,
        extended_log_size,
        H.leafSeed(),
        H.nodeSeed(),
        H.domainPrefixBytes(),
    ) catch return null;
    const commitment = metal_merkle.MetalMerkleTree(H).fromSharedRuntime(result.tree) catch return null;
    errdefer {
        var owned_commitment = commitment;
        owned_commitment.deinit(allocator);
    }

    const columns = try allocator.alloc(ColumnEvaluation, owned_columns.len);
    errdefer allocator.free(columns);
    const coefficients = try allocator.alloc(CircleCoefficients, owned_columns.len);
    errdefer allocator.free(coefficients);
    for (columns, coefficients, base_values, extended_values) |*column, *coefficient, base, extended| {
        column.* = .{ .log_size = extended_log_size, .values = extended };
        coefficient.* = try CircleCoefficients.initBorrowed(base);
    }

    const column_backings = try allocator.alloc([]M31, 1);
    errdefer allocator.free(column_backings);
    column_backings[0] = transform_buffer;
    const coefficient_backings = try allocator.alloc([]M31, 1);
    errdefer allocator.free(coefficient_backings);
    coefficient_backings[0] = base_buffer;

    // The GPU has completed before the source trace is released. Returned
    // coefficient/evaluation slices borrow only the two retained backings.
    for (owned_columns) |column| allocator.free(column.values);
    allocator.free(owned_columns);
    keep_base = true;
    keep_transform = true;
    telemetry.record(.metal_circle_lde_dispatch);
    telemetry.record(.resident_merkle_commit);
    std.log.debug("Metal circle LDE + Merkle epoch: {d:.3}ms", .{result.gpu_ms});
    return .{
        .columns = columns,
        .coefficients = coefficients,
        .column_backing_buffers = column_backings,
        .coefficient_backing_buffers = coefficient_backings,
        .commitment = commitment,
    };
}

test "combined commit admission constants remain large-shape only" {
    try std.testing.expect(min_base_log_size >= 16);
    try std.testing.expect(min_columns >= 64);
    try std.testing.expect(max_columns <= 256);
}
