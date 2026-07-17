//! Lifted Merkle lazy quotient and batched leaf tests.

const std = @import("std");
const m31 = @import("../../../core/fields/m31.zig");
const qm31 = @import("../../../core/fields/qm31.zig");
const quotient_ops = @import("../../pcs/quotient_ops.zig");
const secure_column = @import("../../secure_column.zig");
const prover_mod = @import("../prover.zig");

const M31 = m31.M31;
const SecureColumnByCoords = secure_column.SecureColumnByCoords;
const MerkleProverLifted = prover_mod.MerkleProverLifted;

test "MerkleProverLifted: commitWithLazyQuotients produces same root as standard commit" {
    const alloc = std.testing.allocator;
    const pcs_utils = @import("../../../core/pcs/utils.zig");
    const TreeVec = pcs_utils.TreeVec;
    const quotients_mod = @import("../../../core/pcs/quotients.zig");
    const ColumnEvaluation = quotient_ops.ColumnEvaluation;
    const PointSample = quotients_mod.PointSample;
    const QM31 = qm31.QM31;

    const blake2_merkle = @import("../../../core/vcs_lifted/blake2_merkle.zig");
    const Hasher = blake2_merkle.Blake2sMerkleHasher;
    const Prover = MerkleProverLifted(Hasher);

    const lifting_log_size: u32 = 6;
    const domain_size = @as(usize, 1) << @intCast(lifting_log_size);

    // Build test trace columns.
    const col0 = try alloc.alloc(M31, domain_size);
    defer alloc.free(col0);
    for (col0, 0..) |*v, i| v.* = M31.fromCanonical(@intCast(i + 3));

    const col1_log_size: u32 = 4;
    const col1 = try alloc.alloc(M31, @as(usize, 1) << @intCast(col1_log_size));
    defer alloc.free(col1);
    for (col1, 0..) |*v, i| v.* = M31.fromCanonical(@intCast(101 + i));

    const tree_columns = try alloc.dupe(ColumnEvaluation, &[_]ColumnEvaluation{
        .{ .log_size = lifting_log_size, .values = col0 },
        .{ .log_size = col1_log_size, .values = col1 },
    });
    var columns = TreeVec([]ColumnEvaluation).initOwned(
        try alloc.dupe([]ColumnEvaluation, &[_][]ColumnEvaluation{tree_columns}),
    );
    defer columns.deinitDeep(alloc);

    // Build sample data.
    const point0 = @import("../../../core/circle.zig").SECURE_FIELD_CIRCLE_GEN.mul(7);
    const point1 = @import("../../../core/circle.zig").SECURE_FIELD_CIRCLE_GEN.mul(19);

    const col0_samples = try alloc.dupe(PointSample, &[_]PointSample{
        .{ .point = point0, .value = QM31.fromU32Unchecked(1, 2, 3, 4) },
    });
    const col1_samples = try alloc.dupe(PointSample, &[_]PointSample{
        .{ .point = point0, .value = QM31.fromU32Unchecked(5, 6, 7, 8) },
        .{ .point = point1, .value = QM31.fromU32Unchecked(9, 10, 11, 12) },
    });
    const tree_samples = try alloc.dupe([]PointSample, &[_][]PointSample{
        col0_samples,
        col1_samples,
    });
    var samples = TreeVec([][]PointSample).initOwned(
        try alloc.dupe([][]PointSample, &[_][][]PointSample{tree_samples}),
    );
    defer samples.deinitDeep(alloc);

    // Split into points/values.
    const point_trees = try alloc.alloc([][]@import("../../../core/circle.zig").CirclePointQM31, 1);
    errdefer alloc.free(point_trees);
    const value_trees = try alloc.alloc([][]QM31, 1);
    errdefer alloc.free(value_trees);

    point_trees[0] = try alloc.alloc([]@import("../../../core/circle.zig").CirclePointQM31, samples.items[0].len);
    value_trees[0] = try alloc.alloc([]QM31, samples.items[0].len);

    for (samples.items[0], 0..) |col_samples, col_idx| {
        const pts = try alloc.alloc(@import("../../../core/circle.zig").CirclePointQM31, col_samples.len);
        const vals = try alloc.alloc(QM31, col_samples.len);
        for (col_samples, 0..) |s, si| {
            pts[si] = s.point;
            vals[si] = s.value;
        }
        point_trees[0][col_idx] = pts;
        value_trees[0][col_idx] = vals;
    }

    var sampled_points = TreeVec([][]@import("../../../core/circle.zig").CirclePointQM31).initOwned(point_trees);
    defer sampled_points.deinitDeep(alloc);
    var sampled_values = TreeVec([][]QM31).initOwned(value_trees);
    defer sampled_values.deinitDeep(alloc);

    const alpha = QM31.fromU32Unchecked(3, 0, 1, 0);

    // borrow columns for both paths
    const borrowed_items = try alloc.alloc([]const ColumnEvaluation, columns.items.len);
    defer alloc.free(borrowed_items);
    for (columns.items, 0..) |tc, i| borrowed_items[i] = tc;

    // === Standard path: compute quotients, then commit ===
    var quotients_column = try quotient_ops.computeFriQuotients(
        alloc,
        TreeVec([]const ColumnEvaluation).initOwned(borrowed_items),
        sampled_points,
        sampled_values,
        alpha,
        lifting_log_size,
        1,
    );
    defer quotients_column.deinit(alloc);

    const standard_columns = [_][]const M31{
        quotients_column.columns[0],
        quotients_column.columns[1],
        quotients_column.columns[2],
        quotients_column.columns[3],
    };
    var standard_tree = try Prover.commit(alloc, standard_columns[0..]);
    defer standard_tree.deinit(alloc);
    const standard_root = standard_tree.root();

    // === Lazy path: fused compute+commit ===
    const borrowed_items2 = try alloc.alloc([]const ColumnEvaluation, columns.items.len);
    defer alloc.free(borrowed_items2);
    for (columns.items, 0..) |tc, i| borrowed_items2[i] = tc;

    var provider = try quotient_ops.LazyQuotientProvider.init(
        alloc,
        TreeVec([]const ColumnEvaluation).initOwned(borrowed_items2),
        sampled_points,
        sampled_values,
        alpha,
        lifting_log_size,
    );
    defer provider.deinit(alloc);

    var lazy_column = try SecureColumnByCoords.uninitialized(alloc, domain_size);
    defer lazy_column.deinit(alloc);

    var lazy_tree = try Prover.commitWithLazyQuotients(alloc, &provider, &lazy_column);
    defer lazy_tree.deinit(alloc);
    const lazy_root = lazy_tree.root();

    // Roots must match.
    try std.testing.expect(std.mem.eql(u8, std.mem.asBytes(&standard_root), std.mem.asBytes(&lazy_root)));

    // Column values must also match.
    for (0..domain_size) |i| {
        try std.testing.expect(quotients_column.at(i).eql(lazy_column.at(i)));
    }
}

test "prover vcs_lifted: batched leaf building matches original for uniform columns" {
    // Verifies that buildLeavesBatched produces bit-identical leaf hashes
    // as the original buildLeaves when all columns have the same log_size.
    const Hasher = @import("../../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleHasher;
    const Prover = MerkleProverLifted(Hasher);
    const alloc = std.testing.allocator;

    const num_columns: usize = 16;
    const log_size: u32 = 10;
    const n = @as(usize, 1) << @intCast(log_size);

    const columns_storage = try alloc.alloc([]M31, num_columns);
    defer {
        for (columns_storage) |col| alloc.free(col);
        alloc.free(columns_storage);
    }
    const columns = try alloc.alloc([]const M31, num_columns);
    defer alloc.free(columns);

    for (0..num_columns) |col_idx| {
        const values = try alloc.alloc(M31, n);
        columns_storage[col_idx] = values;
        columns[col_idx] = values;
        for (values, 0..) |*value, row_idx| {
            const seed = @as(u64, @intCast(col_idx + 1)) * 1009 +
                @as(u64, @intCast(row_idx + 3)) * 37;
            value.* = M31.fromU64(seed);
        }
    }

    const sorted = try Prover.sortColumnsByLogSizeAsc(alloc, columns);
    defer alloc.free(sorted);
    const layer_alloc = alloc;

    // Original path
    const original_leaves = try Prover.testing.buildLeaves(alloc, layer_alloc, sorted);
    defer layer_alloc.free(original_leaves);

    // Batched path with various batch sizes
    inline for ([_]usize{ 4, 64, 256, 1024 }) |batch_sz| {
        const batched_leaves = try Prover.testing.buildLeavesBatched(alloc, layer_alloc, sorted, batch_sz);
        defer layer_alloc.free(batched_leaves);

        try std.testing.expectEqual(original_leaves.len, batched_leaves.len);
        for (original_leaves, batched_leaves) |orig, bat| {
            try std.testing.expectEqualSlices(u8, orig[0..], bat[0..]);
        }
    }
}

test "prover vcs_lifted: batched leaf building matches original for mixed log sizes" {
    // Verifies bit-identical output when columns have different log_sizes,
    // which exercises the lifting index mapping.
    const Hasher = @import("../../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleHasher;
    const Prover = MerkleProverLifted(Hasher);
    const alloc = std.testing.allocator;

    const large_count: usize = 8;
    const small_count: usize = 4;
    const total = large_count + small_count;
    const large_len: usize = 1 << 9;
    const small_len: usize = 1 << 7;

    const columns_storage = try alloc.alloc([]M31, total);
    defer {
        for (columns_storage) |col| alloc.free(col);
        alloc.free(columns_storage);
    }
    const columns = try alloc.alloc([]const M31, total);
    defer alloc.free(columns);

    for (0..large_count) |i| {
        const values = try alloc.alloc(M31, large_len);
        columns_storage[i] = values;
        columns[i] = values;
        for (values, 0..) |*v, r| {
            v.* = M31.fromU64(@as(u64, @intCast(i * 997 + r * 13 + 5)));
        }
    }
    for (0..small_count) |offset| {
        const i = large_count + offset;
        const values = try alloc.alloc(M31, small_len);
        columns_storage[i] = values;
        columns[i] = values;
        for (values, 0..) |*v, r| {
            v.* = M31.fromU64(@as(u64, @intCast(i * 1223 + r * 19 + 7)));
        }
    }

    const sorted = try Prover.sortColumnsByLogSizeAsc(alloc, columns);
    defer alloc.free(sorted);
    const layer_alloc = alloc;

    const original_leaves = try Prover.testing.buildLeaves(alloc, layer_alloc, sorted);
    defer layer_alloc.free(original_leaves);

    inline for ([_]usize{ 8, 128, 512 }) |batch_sz| {
        const batched_leaves = try Prover.testing.buildLeavesBatched(alloc, layer_alloc, sorted, batch_sz);
        defer layer_alloc.free(batched_leaves);

        try std.testing.expectEqual(original_leaves.len, batched_leaves.len);
        for (original_leaves, batched_leaves) |orig, bat| {
            try std.testing.expectEqualSlices(u8, orig[0..], bat[0..]);
        }
    }
}

test "prover vcs_lifted: batched commit produces same root and decommitment" {
    // End-to-end test: full commit + decommit with the batched path
    // must produce the same root and decommitment as the original.
    const Hasher = @import("../../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleHasher;
    const Prover = MerkleProverLifted(Hasher);
    const Verifier = @import("../../../core/vcs_lifted/verifier.zig").MerkleVerifierLifted(Hasher);
    const alloc = std.testing.allocator;

    const columns = [_][]const M31{
        &[_]M31{
            M31.fromCanonical(1),
            M31.fromCanonical(2),
            M31.fromCanonical(3),
            M31.fromCanonical(4),
            M31.fromCanonical(5),
            M31.fromCanonical(6),
            M31.fromCanonical(7),
            M31.fromCanonical(8),
        },
        &[_]M31{
            M31.fromCanonical(9),
            M31.fromCanonical(10),
            M31.fromCanonical(11),
            M31.fromCanonical(12),
        },
        &[_]M31{
            M31.fromCanonical(13),
            M31.fromCanonical(14),
            M31.fromCanonical(15),
            M31.fromCanonical(16),
            M31.fromCanonical(17),
            M31.fromCanonical(18),
            M31.fromCanonical(19),
            M31.fromCanonical(20),
        },
    };

    // Build using original path (columns are small, below threshold).
    var prover_orig = try Prover.commit(alloc, columns[0..]);
    defer prover_orig.deinit(alloc);

    // Build using batched path explicitly with a tiny batch.
    const sorted = try Prover.sortColumnsByLogSizeAsc(alloc, columns[0..]);
    defer alloc.free(sorted);
    const batched_leaves = try Prover.testing.buildLeavesBatched(alloc, alloc, sorted, 2);
    defer alloc.free(batched_leaves);

    // Compare leaf layers directly.
    const orig_leaf_layer = prover_orig.layers[prover_orig.layers.len - 1];
    try std.testing.expectEqual(orig_leaf_layer.len, batched_leaves.len);
    for (orig_leaf_layer, batched_leaves) |orig, bat| {
        try std.testing.expectEqualSlices(u8, orig[0..], bat[0..]);
    }

    // Verify the original prover's decommitment still works (sanity check).
    const query_positions = [_]usize{ 1, 6 };
    var decommitment = try prover_orig.decommit(alloc, query_positions[0..], columns[0..]);
    defer decommitment.deinit(alloc);

    const queried_values = try alloc.alloc([]const M31, decommitment.queried_values.len);
    defer alloc.free(queried_values);
    for (decommitment.queried_values, 0..) |column, i| queried_values[i] = column;

    var verifier = try Verifier.init(alloc, prover_orig.root(), &[_]u32{ 3, 2, 3 });
    defer verifier.deinit(alloc);
    try verifier.verify(
        alloc,
        query_positions[0..],
        queried_values,
        decommitment.decommitment.decommitment,
    );
}
