//! PCS sample representation, periodicity expansion, and stable point grouping.
//!
//! Random coefficient powers are assigned in upstream tree/column/sample order.
//! That ordering is part of the transcript law and must not be parallelized or
//! reordered without Rust-oracle evidence.

const std = @import("std");
const circle = @import("../../circle.zig");
const qm31_mod = @import("../../fields/qm31.zig");
const canonic = @import("../../poly/circle/canonic.zig");
const pcs_utils = @import("../utils.zig");

const CirclePointM31 = circle.CirclePointM31;
const CirclePointQM31 = circle.CirclePointQM31;
const QM31 = qm31_mod.QM31;
const TreeVec = pcs_utils.TreeVec;

/// A sample of one column at one secure-field circle point.
pub const PointSample = struct {
    point: CirclePointQM31,
    value: QM31,
};

/// A sample together with its transcript-derived random coefficient power.
pub const SampleWithRandomness = struct {
    point: CirclePointQM31,
    value: QM31,
    random_coeff: QM31,
};

/// One column's contribution to a batch sharing the same sample point.
pub const NumeratorData = struct {
    column_index: usize,
    sample_value: QM31,
    random_coeff: QM31,
};

const MutableColumnSampleBatch = struct {
    point: CirclePointQM31,
    vals: std.ArrayList(NumeratorData),
};

/// Column samples grouped by point in stable first-occurrence order.
pub const ColumnSampleBatch = struct {
    point: CirclePointQM31,
    cols_vals_randpows: []NumeratorData,

    pub fn deinit(self: *ColumnSampleBatch, allocator: std.mem.Allocator) void {
        allocator.free(self.cols_vals_randpows);
        self.* = undefined;
    }

    pub fn deinitSlice(allocator: std.mem.Allocator, batches: []ColumnSampleBatch) void {
        for (batches) |*batch| batch.deinit(allocator);
        allocator.free(batches);
    }

    pub fn newVec(
        allocator: std.mem.Allocator,
        samples_with_rand: []const []const SampleWithRandomness,
    ) ![]ColumnSampleBatch {
        var grouped = std.ArrayList(MutableColumnSampleBatch).empty;
        defer deinitMutableColumnSampleBatches(allocator, &grouped);
        var batch_indices = std.AutoHashMap(CirclePointQM31, usize).init(allocator);
        defer batch_indices.deinit();

        for (samples_with_rand, 0..) |column_samples, column_index| {
            for (column_samples) |sample_with_rand| {
                const batch_idx = try ensureMutableBatchForPoint(
                    allocator,
                    &grouped,
                    &batch_indices,
                    sample_with_rand.point,
                );
                try grouped.items[batch_idx].vals.append(allocator, .{
                    .column_index = column_index,
                    .sample_value = sample_with_rand.value,
                    .random_coeff = sample_with_rand.random_coeff,
                });
            }
        }

        return mutableColumnSampleBatchesToOwned(allocator, &grouped);
    }
};

fn deinitMutableColumnSampleBatches(
    allocator: std.mem.Allocator,
    grouped: *std.ArrayList(MutableColumnSampleBatch),
) void {
    for (grouped.items) |*batch| batch.vals.deinit(allocator);
    grouped.deinit(allocator);
}

fn ensureMutableBatchForPoint(
    allocator: std.mem.Allocator,
    grouped: *std.ArrayList(MutableColumnSampleBatch),
    batch_indices: *std.AutoHashMap(CirclePointQM31, usize),
    point: CirclePointQM31,
) !usize {
    const gop = try batch_indices.getOrPut(point);
    if (gop.found_existing) return gop.value_ptr.*;

    try grouped.append(allocator, .{
        .point = point,
        .vals = std.ArrayList(NumeratorData).empty,
    });
    gop.value_ptr.* = grouped.items.len - 1;
    return gop.value_ptr.*;
}

fn mutableColumnSampleBatchesToOwned(
    allocator: std.mem.Allocator,
    grouped: *std.ArrayList(MutableColumnSampleBatch),
) ![]ColumnSampleBatch {
    const out = try allocator.alloc(ColumnSampleBatch, grouped.items.len);
    errdefer allocator.free(out);

    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |batch| allocator.free(batch.cols_vals_randpows);
    }

    for (grouped.items, 0..) |*batch, i| {
        out[i] = .{
            .point = batch.point,
            .cols_vals_randpows = try batch.vals.toOwnedSlice(allocator),
        };
        initialized += 1;
    }
    return out;
}

/// Attaches random coefficient powers and periodicity checks to all samples.
pub fn buildSamplesWithRandomnessAndPeriodicity(
    allocator: std.mem.Allocator,
    sampled_points: TreeVec([][]CirclePointQM31),
    sampled_values: TreeVec([][]QM31),
    column_log_sizes: TreeVec([]u32),
    lifting_log_size: u32,
    random_coeff: QM31,
) !TreeVec([][]SampleWithRandomness) {
    if (sampled_points.items.len != column_log_sizes.items.len) return error.ShapeMismatch;
    if (sampled_points.items.len != sampled_values.items.len) return error.ShapeMismatch;

    var random_pow = QM31.one();
    const lifting_domain_generator = canonic.CanonicCoset.new(lifting_log_size).step();

    var trees_builder = std.ArrayList([][]SampleWithRandomness).empty;
    defer trees_builder.deinit(allocator);
    errdefer {
        for (trees_builder.items) |tree_samples| {
            freeTreeSamplesWithRandomness(allocator, tree_samples);
        }
    }

    for (sampled_points.items, sampled_values.items, 0..) |points_per_tree, values_per_tree, tree_idx| {
        const sizes_per_tree = column_log_sizes.items[tree_idx];
        if (points_per_tree.len != sizes_per_tree.len) return error.ShapeMismatch;
        if (points_per_tree.len != values_per_tree.len) return error.ShapeMismatch;

        var cols_builder = std.ArrayList([]SampleWithRandomness).empty;
        defer cols_builder.deinit(allocator);
        errdefer {
            for (cols_builder.items) |col_samples| allocator.free(col_samples);
        }

        for (points_per_tree, values_per_tree, 0..) |points_per_col, values_per_col, col_idx| {
            if (points_per_col.len != values_per_col.len) return error.ShapeMismatch;
            const log_size = sizes_per_tree[col_idx];
            if (points_per_col.len == 0) {
                try cols_builder.append(
                    allocator,
                    try allocator.alloc(SampleWithRandomness, 0),
                );
                continue;
            }

            const has_periodicity = points_per_col.len == 2;
            const out_samples = try allocator.alloc(
                SampleWithRandomness,
                points_per_col.len + @intFromBool(has_periodicity),
            );
            errdefer allocator.free(out_samples);

            var out_i: usize = 0;
            if (has_periodicity) {
                const point = points_per_col[1];
                const value = values_per_col[1];
                const period_generator = lifting_domain_generator.repeatedDouble(log_size);
                out_samples[out_i] = .{
                    .point = point.add(pointM31IntoQM31(period_generator)),
                    .value = value,
                    .random_coeff = nextRandomPow(&random_pow, random_coeff),
                };
                out_i += 1;
            }

            for (points_per_col, values_per_col) |point, value| {
                out_samples[out_i] = .{
                    .point = point,
                    .value = value,
                    .random_coeff = nextRandomPow(&random_pow, random_coeff),
                };
                out_i += 1;
            }
            try cols_builder.append(allocator, out_samples);
        }

        try trees_builder.append(allocator, try cols_builder.toOwnedSlice(allocator));
    }

    return TreeVec([][]SampleWithRandomness).initOwned(try trees_builder.toOwnedSlice(allocator));
}

/// Builds point-grouped batches directly from parallel point/value inputs.
pub fn buildColumnSampleBatchesFromParallelInputs(
    allocator: std.mem.Allocator,
    sampled_points: TreeVec([][]CirclePointQM31),
    sampled_values: TreeVec([][]QM31),
    column_log_sizes: TreeVec([]u32),
    lifting_log_size: u32,
    random_coeff: QM31,
) ![]ColumnSampleBatch {
    if (sampled_points.items.len != column_log_sizes.items.len) return error.ShapeMismatch;
    if (sampled_points.items.len != sampled_values.items.len) return error.ShapeMismatch;

    var grouped = std.ArrayList(MutableColumnSampleBatch).empty;
    defer deinitMutableColumnSampleBatches(allocator, &grouped);
    var batch_indices = std.AutoHashMap(CirclePointQM31, usize).init(allocator);
    defer batch_indices.deinit();

    var random_pow = QM31.one();
    const lifting_domain_generator = canonic.CanonicCoset.new(lifting_log_size).step();
    var flat_column_index: usize = 0;

    for (sampled_points.items, sampled_values.items, 0..) |points_per_tree, values_per_tree, tree_idx| {
        const sizes_per_tree = column_log_sizes.items[tree_idx];
        if (points_per_tree.len != sizes_per_tree.len) return error.ShapeMismatch;
        if (points_per_tree.len != values_per_tree.len) return error.ShapeMismatch;

        for (points_per_tree, values_per_tree, 0..) |points_per_col, values_per_col, col_idx| {
            defer flat_column_index += 1;
            if (points_per_col.len != values_per_col.len) return error.ShapeMismatch;
            if (points_per_col.len == 0) continue;

            const log_size = sizes_per_tree[col_idx];
            if (points_per_col.len == 2) {
                const periodic_point = points_per_col[1].add(
                    pointM31IntoQM31(lifting_domain_generator.repeatedDouble(log_size)),
                );
                const batch_idx = try ensureMutableBatchForPoint(
                    allocator,
                    &grouped,
                    &batch_indices,
                    periodic_point,
                );
                try grouped.items[batch_idx].vals.append(allocator, .{
                    .column_index = flat_column_index,
                    .sample_value = values_per_col[1],
                    .random_coeff = nextRandomPow(&random_pow, random_coeff),
                });
            }

            for (points_per_col, values_per_col) |point, value| {
                const batch_idx = try ensureMutableBatchForPoint(
                    allocator,
                    &grouped,
                    &batch_indices,
                    point,
                );
                try grouped.items[batch_idx].vals.append(allocator, .{
                    .column_index = flat_column_index,
                    .sample_value = value,
                    .random_coeff = nextRandomPow(&random_pow, random_coeff),
                });
            }
        }
    }

    return mutableColumnSampleBatchesToOwned(allocator, &grouped);
}

fn pointM31IntoQM31(point: CirclePointM31) CirclePointQM31 {
    return .{
        .x = QM31.fromBase(point.x),
        .y = QM31.fromBase(point.y),
    };
}

fn nextRandomPow(current: *QM31, random_coeff: QM31) QM31 {
    const out = current.*;
    current.* = current.*.mul(random_coeff);
    return out;
}

fn freeTreeSamplesWithRandomness(
    allocator: std.mem.Allocator,
    tree_samples: [][]SampleWithRandomness,
) void {
    for (tree_samples) |column_samples| allocator.free(column_samples);
    allocator.free(tree_samples);
}
