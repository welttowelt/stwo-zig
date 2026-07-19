//! Quotient input planning and lifted-column construction.
//!
//! This module owns the allocation-backed plans shared by eager and lazy FRI
//! quotient evaluation. Execution remains in the row and tile executors.

const std = @import("std");
const circle = @import("stwo_core").circle;
const m31 = @import("stwo_core").fields.m31;
const qm31 = @import("stwo_core").fields.qm31;
const quotients = @import("stwo_core").pcs.quotients;
const pcs_utils = @import("stwo_core").pcs.utils;
const column_geometry = @import("../quotient_column_geometry.zig");
const row_executor = @import("../quotient_row_executor.zig");

const CirclePointQM31 = circle.CirclePointQM31;
const M31 = m31.M31;
const QM31 = qm31.QM31;
const TreeVec = pcs_utils.TreeVec;
const ColumnEvaluation = column_geometry.ColumnEvaluation;
const ColumnContribution = row_executor.ColumnContribution;
const ColumnContributionRange = row_executor.ColumnContributionRange;
const CombinedContributionView = row_executor.CombinedContributionView;
const LiftingColumnView = row_executor.LiftingColumnView;
const QuotientOpsError = column_geometry.QuotientOpsError;

const materialize_lifted_threshold_bytes: usize = 48 * 1024 * 1024;
const streaming_domain_threshold: usize = 1 << 12;
const streaming_active_column_threshold: usize = 1024;

pub const CombinedContributionPlan = struct {
    views: []CombinedContributionView,

    pub fn deinit(self: *CombinedContributionPlan, allocator: std.mem.Allocator) void {
        for (self.views) |view| {
            for (view.coordinates) |coordinate| allocator.free(coordinate);
        }
        allocator.free(self.views);
        self.* = undefined;
    }
};

pub const ColumnContributionPlan = struct {
    active_column_indices: []usize,
    ranges: []ColumnContributionRange,
    contributions: []ColumnContribution,

    pub fn deinit(self: *ColumnContributionPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.active_column_indices);
        allocator.free(self.ranges);
        allocator.free(self.contributions);
        self.* = undefined;
    }

    pub fn activeColumnCount(self: ColumnContributionPlan) usize {
        return self.active_column_indices.len;
    }

    pub fn totalContributions(self: ColumnContributionPlan) usize {
        return self.contributions.len;
    }
};

pub const ConstructionStrategy = enum {
    materialized,
    streaming,
};

pub const PreparedContext = struct {
    sample_batches: []quotients.ColumnSampleBatch,
    quotient_constants: quotients.QuotientConstants,
    contribution_plan: ColumnContributionPlan,

    pub fn deinit(self: *PreparedContext, allocator: std.mem.Allocator) void {
        self.contribution_plan.deinit(allocator);
        self.quotient_constants.deinit(allocator);
        quotients.ColumnSampleBatch.deinitSlice(allocator, self.sample_batches);
        self.* = undefined;
    }
};

pub const MaterializedLiftedColumns = struct {
    storage: []M31,
    columns: [][]M31,

    pub fn deinit(self: *MaterializedLiftedColumns, allocator: std.mem.Allocator) void {
        allocator.free(self.columns);
        allocator.free(self.storage);
        self.* = undefined;
    }
};

pub fn prepareContext(
    allocator: std.mem.Allocator,
    column_log_sizes: TreeVec([]u32),
    sampled_points: TreeVec([][]CirclePointQM31),
    sampled_values: TreeVec([][]QM31),
    random_coeff: QM31,
    lifting_log_size: u32,
    flat_column_count: usize,
) !PreparedContext {
    const sample_batches = try quotients.buildColumnSampleBatchesFromParallelInputs(
        allocator,
        sampled_points,
        sampled_values,
        column_log_sizes,
        lifting_log_size,
        random_coeff,
    );
    errdefer quotients.ColumnSampleBatch.deinitSlice(allocator, sample_batches);

    var quotient_constants = try quotients.quotientConstants(allocator, sample_batches);
    errdefer quotient_constants.deinit(allocator);

    try validateSampleBatchColumnIndices(sample_batches, flat_column_count);
    var contribution_plan = try buildColumnContributionPlan(
        allocator,
        sample_batches,
        &quotient_constants,
        flat_column_count,
    );
    errdefer contribution_plan.deinit(allocator);

    return .{
        .sample_batches = sample_batches,
        .quotient_constants = quotient_constants,
        .contribution_plan = contribution_plan,
    };
}

fn buildColumnContributionPlan(
    allocator: std.mem.Allocator,
    sample_batches: []const quotients.ColumnSampleBatch,
    quotient_constants: *const quotients.QuotientConstants,
    column_count: usize,
) !ColumnContributionPlan {
    const counts = try allocator.alloc(usize, column_count);
    defer allocator.free(counts);
    @memset(counts, 0);

    var total_contributions: usize = 0;
    var active_column_count: usize = 0;
    for (sample_batches) |batch| {
        for (batch.cols_vals_randpows) |sample_data| {
            if (sample_data.column_index >= column_count) return QuotientOpsError.ShapeMismatch;
            if (counts[sample_data.column_index] == 0) active_column_count += 1;
            counts[sample_data.column_index] += 1;
            total_contributions += 1;
        }
    }

    const active_column_indices = try allocator.alloc(usize, active_column_count);
    errdefer allocator.free(active_column_indices);
    const ranges = try allocator.alloc(ColumnContributionRange, active_column_count);
    errdefer allocator.free(ranges);

    const invalid_active_index = std.math.maxInt(usize);
    const column_to_active = try allocator.alloc(usize, column_count);
    defer allocator.free(column_to_active);
    @memset(column_to_active, invalid_active_index);

    var at: usize = 0;
    var active_idx: usize = 0;
    for (counts, 0..) |count, col_idx| {
        if (count == 0) continue;
        active_column_indices[active_idx] = col_idx;
        column_to_active[col_idx] = active_idx;
        ranges[active_idx] = .{ .start = at, .len = count };
        at += count;
        active_idx += 1;
    }
    std.debug.assert(at == total_contributions);
    std.debug.assert(active_idx == active_column_count);

    const next_offsets = try allocator.alloc(usize, active_column_count);
    defer allocator.free(next_offsets);
    for (ranges, 0..) |range, idx| next_offsets[idx] = range.start;

    const contributions = try allocator.alloc(ColumnContribution, total_contributions);
    errdefer allocator.free(contributions);
    for (sample_batches, 0..) |batch, batch_idx| {
        const line_coeffs = quotient_constants.line_coeffs[batch_idx];
        if (line_coeffs.len != batch.cols_vals_randpows.len) return QuotientOpsError.ShapeMismatch;
        for (batch.cols_vals_randpows, 0..) |sample_data, coeff_idx| {
            const mapped_active_idx = column_to_active[sample_data.column_index];
            if (mapped_active_idx == invalid_active_index) return QuotientOpsError.ShapeMismatch;
            const write_idx = next_offsets[mapped_active_idx];
            contributions[write_idx] = .{
                .batch_index = batch_idx,
                .value_coeff = line_coeffs[coeff_idx].c,
            };
            next_offsets[mapped_active_idx] = write_idx + 1;
        }
    }

    return .{
        .active_column_indices = active_column_indices,
        .ranges = ranges,
        .contributions = contributions,
    };
}

pub fn chooseConstructionStrategy(
    active_column_count: usize,
    domain_size: usize,
) ConstructionStrategy {
    if (domain_size >= streaming_domain_threshold and
        active_column_count > streaming_active_column_threshold)
    {
        return .streaming;
    }

    const lifted_cells = std.math.mul(usize, active_column_count, domain_size) catch return .streaming;
    const lifted_bytes = std.math.mul(usize, lifted_cells, @sizeOf(M31)) catch return .streaming;
    return if (lifted_bytes > materialize_lifted_threshold_bytes)
        .streaming
    else
        .materialized;
}

fn buildActiveLiftingColumnViews(
    allocator: std.mem.Allocator,
    flat_columns: []const ColumnEvaluation,
    active_column_indices: []const usize,
    lifting_log_size: u32,
) ![]LiftingColumnView {
    const views = try allocator.alloc(LiftingColumnView, active_column_indices.len);
    errdefer allocator.free(views);

    for (active_column_indices, 0..) |column_idx, active_idx| {
        if (column_idx >= flat_columns.len) return QuotientOpsError.ShapeMismatch;
        const column = flat_columns[column_idx];
        if (column.log_size > lifting_log_size) return QuotientOpsError.InvalidColumnLogSize;
        const log_shift = lifting_log_size - column.log_size;
        if (log_shift >= @bitSizeOf(usize)) return QuotientOpsError.InvalidColumnLogSize;
        views[active_idx] = .{
            .values = column.values,
            .shift_amt = @intCast(log_shift + 1),
            .is_direct = column.log_size == lifting_log_size,
        };
    }

    return views;
}

pub fn markNonzeroColumnsAndSamples(
    allocator: std.mem.Allocator,
    columns: TreeVec([]const ColumnEvaluation),
    sampled_values: TreeVec([][]QM31),
) ![]bool {
    const nonzero = try allocator.alloc(bool, column_geometry.countColumns(columns));
    errdefer allocator.free(nonzero);

    var flat_idx: usize = 0;
    for (columns.items, sampled_values.items) |tree_columns, tree_samples| {
        if (tree_columns.len != tree_samples.len) return QuotientOpsError.ShapeMismatch;
        for (tree_columns, tree_samples) |column, samples| {
            var has_nonzero = false;
            for (column.values) |value| {
                if (!value.isZero()) {
                    has_nonzero = true;
                    break;
                }
            }
            if (!has_nonzero) {
                for (samples) |value| {
                    if (!value.eql(QM31.zero())) {
                        has_nonzero = true;
                        break;
                    }
                }
            }
            nonzero[flat_idx] = has_nonzero;
            flat_idx += 1;
        }
    }
    std.debug.assert(flat_idx == nonzero.len);
    return nonzero;
}

pub fn buildCombinedContributionPlan(
    allocator: std.mem.Allocator,
    flat_columns: []const ColumnEvaluation,
    active_column_indices: []const usize,
    contribution_ranges: []const ColumnContributionRange,
    contributions: []const ColumnContribution,
    nonzero_columns: []const bool,
    lifting_log_size: u32,
) !CombinedContributionPlan {
    if (active_column_indices.len != contribution_ranges.len or
        flat_columns.len != nonzero_columns.len)
    {
        return QuotientOpsError.ShapeMismatch;
    }

    var views = std.ArrayList(CombinedContributionView).empty;
    defer views.deinit(allocator);
    errdefer for (views.items) |view| {
        for (view.coordinates) |coordinate| allocator.free(coordinate);
    };

    for (active_column_indices, contribution_ranges) |column_idx, contribution_range| {
        if (column_idx >= nonzero_columns.len or column_idx >= flat_columns.len) {
            return QuotientOpsError.ShapeMismatch;
        }
        if (!nonzero_columns[column_idx]) continue;
        const column = flat_columns[column_idx];
        if (column.log_size > lifting_log_size) return QuotientOpsError.InvalidColumnLogSize;
        const log_shift = lifting_log_size - column.log_size;
        if (log_shift >= @bitSizeOf(usize)) return QuotientOpsError.InvalidColumnLogSize;

        const column_contributions = contributions[contribution_range.start .. contribution_range.start + contribution_range.len];
        for (column_contributions) |contribution| {
            var view_index: ?usize = null;
            for (views.items, 0..) |view, i| {
                if (view.batch_index == contribution.batch_index and
                    view.coordinates[0].len == column.values.len)
                {
                    view_index = i;
                    break;
                }
            }

            if (view_index == null) {
                var coordinates: [qm31.SECURE_EXTENSION_DEGREE][]M31 = undefined;
                var initialized: usize = 0;
                errdefer for (coordinates[0..initialized]) |coordinate| allocator.free(coordinate);
                inline for (0..qm31.SECURE_EXTENSION_DEGREE) |coord| {
                    coordinates[coord] = try allocator.alloc(M31, column.values.len);
                    @memset(coordinates[coord], M31.zero());
                    initialized += 1;
                }
                try views.append(allocator, .{
                    .coordinates = coordinates,
                    .batch_index = contribution.batch_index,
                    .shift_amt = @intCast(log_shift + 1),
                    .is_direct = column.log_size == lifting_log_size,
                });
                view_index = views.items.len - 1;
            }

            const coeffs = contribution.value_coeff.toM31Array();
            const view = &views.items[view_index.?];
            for (column.values, 0..) |base, value_index| {
                inline for (0..qm31.SECURE_EXTENSION_DEGREE) |coord| {
                    view.coordinates[coord][value_index] = view.coordinates[coord][value_index].add(
                        base.mul(coeffs[coord]),
                    );
                }
            }
        }
    }

    return .{ .views = try views.toOwnedSlice(allocator) };
}

pub fn materializeActiveLiftedColumns(
    allocator: std.mem.Allocator,
    flat_columns: []const ColumnEvaluation,
    active_column_indices: []const usize,
    lifting_log_size: u32,
) !MaterializedLiftedColumns {
    const domain_size = try column_geometry.checkedPow2(lifting_log_size);
    const total_cells = std.math.mul(usize, active_column_indices.len, domain_size) catch
        return QuotientOpsError.ShapeMismatch;
    const storage = try allocator.alloc(M31, total_cells);
    errdefer allocator.free(storage);
    const columns = try allocator.alloc([]M31, active_column_indices.len);
    errdefer allocator.free(columns);

    for (active_column_indices, 0..) |column_idx, active_idx| {
        if (column_idx >= flat_columns.len) return QuotientOpsError.ShapeMismatch;
        const column = flat_columns[column_idx];
        if (column.log_size > lifting_log_size) return QuotientOpsError.InvalidColumnLogSize;
        const dest = storage[active_idx * domain_size ..][0..domain_size];
        columns[active_idx] = dest;

        if (column.log_size == lifting_log_size) {
            @memcpy(dest, column.values);
            continue;
        }

        const log_shift = lifting_log_size - column.log_size;
        if (log_shift >= @bitSizeOf(usize)) return QuotientOpsError.InvalidColumnLogSize;
        const shift_amt: std.math.Log2Int(usize) = @intCast(log_shift + 1);
        for (0..domain_size) |position| {
            const idx = ((position >> shift_amt) << 1) + (position & 1);
            std.debug.assert(idx < column.values.len);
            dest[position] = column.values[idx];
        }
    }

    return .{
        .storage = storage,
        .columns = columns,
    };
}

fn validateSampleBatchColumnIndices(
    sample_batches: []const quotients.ColumnSampleBatch,
    queried_values_cols: usize,
) !void {
    for (sample_batches) |batch| {
        for (batch.cols_vals_randpows) |sample_data| {
            if (sample_data.column_index >= queried_values_cols) return error.ColumnIndexOutOfBounds;
        }
    }
}
