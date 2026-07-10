const std = @import("std");
const builtin = @import("builtin");
const m31 = @import("../../core/fields/m31.zig");
const qm31 = @import("../../core/fields/qm31.zig");
const quotients = @import("../../core/pcs/quotients.zig");
const pcs_utils = @import("../../core/pcs/utils.zig");
const canonic = @import("../../core/poly/circle/canonic.zig");
const core_utils = @import("../../core/utils.zig");
const secure_column = @import("../secure_column.zig");
const work_pool_mod = @import("../work_pool.zig");
const CircleDomain = @import("../../core/poly/circle/domain.zig").CircleDomain;

const circle_mod = @import("../../core/circle.zig");
const circle_domain = @import("../../core/poly/circle/domain.zig");
const CirclePointQM31 = circle_mod.CirclePointQM31;
const M31 = m31.M31;
const QM31 = qm31.QM31;
const TreeVec = pcs_utils.TreeVec;
const PointSample = quotients.PointSample;
const SecureColumnByCoords = secure_column.SecureColumnByCoords;
const MATERIALIZE_LIFTED_THRESHOLD_BYTES: usize = 48 * 1024 * 1024;
const STREAMING_DOMAIN_THRESHOLD: usize = 1 << 12;
const STREAMING_ACTIVE_COLUMN_THRESHOLD: usize = 1024;
/// Minimum number of domain positions per worker thread to amortize overhead.
const MIN_POSITIONS_PER_WORKER: usize = 256;
/// Number of rows processed per chunk in lazy quotient evaluation.
/// Chosen to amortize function-call overhead while keeping chunk memory bounded.
pub const LAZY_QUOTIENT_CHUNK_SIZE: usize = 1024;

pub const QuotientOpsError = error{
    ShapeMismatch,
    InvalidColumnLogSize,
    InvalidColumnLength,
};

const LiftingColumnView = struct {
    values: []const M31,
    shift_amt: std.math.Log2Int(usize),
    is_direct: bool,
};

const CombinedContributionView = struct {
    coordinates: [qm31.SECURE_EXTENSION_DEGREE][]M31,
    batch_index: usize,
    shift_amt: std.math.Log2Int(usize),
    is_direct: bool,
};

const CombinedContributionPlan = struct {
    views: []CombinedContributionView,

    fn deinit(self: *CombinedContributionPlan, allocator: std.mem.Allocator) void {
        for (self.views) |view| {
            for (view.coordinates) |coordinate| allocator.free(coordinate);
        }
        allocator.free(self.views);
        self.* = undefined;
    }
};

const ColumnContribution = struct {
    batch_index: usize,
    value_coeff: QM31,
};

const ColumnContributionRange = struct {
    start: usize,
    len: usize,
};

const ColumnContributionPlan = struct {
    active_column_indices: []usize,
    ranges: []ColumnContributionRange,
    contributions: []ColumnContribution,

    fn deinit(self: *ColumnContributionPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.active_column_indices);
        allocator.free(self.ranges);
        allocator.free(self.contributions);
        self.* = undefined;
    }

    fn activeColumnCount(self: ColumnContributionPlan) usize {
        return self.active_column_indices.len;
    }

    fn totalContributions(self: ColumnContributionPlan) usize {
        return self.contributions.len;
    }
};

const QuotientConstructionStrategy = enum {
    materialized,
    streaming,
};

const PreparedQuotientContext = struct {
    sample_batches: []quotients.ColumnSampleBatch,
    quotient_constants: quotients.QuotientConstants,
    contribution_plan: ColumnContributionPlan,

    fn deinit(self: *PreparedQuotientContext, allocator: std.mem.Allocator) void {
        self.contribution_plan.deinit(allocator);
        self.quotient_constants.deinit(allocator);
        quotients.ColumnSampleBatch.deinitSlice(allocator, self.sample_batches);
        self.* = undefined;
    }
};

const MaterializedLiftedColumns = struct {
    storage: []M31,
    columns: [][]M31,

    fn deinit(self: *MaterializedLiftedColumns, allocator: std.mem.Allocator) void {
        allocator.free(self.columns);
        allocator.free(self.storage);
        self.* = undefined;
    }
};

/// Lazy quotient provider for fused quotient-computation + Merkle commitment.
///
/// Encapsulates all state needed to compute FRI quotient values on demand,
/// one chunk at a time, without materializing the full quotient column
/// or the lifted column matrix before Merkle hashing begins.
///
/// Usage:
///   1. `init()` — prepare the provider from the same inputs as `computeFriQuotients`.
///   2. Call `computeChunk()` repeatedly with ascending, non-overlapping position ranges.
///      Each call fills the 4 coordinate buffers for a chunk of the output column.
///   3. `deinit()` — release internal scratch memory.
pub const LazyQuotientProvider = struct {
    prepared: PreparedQuotientContext,
    combined_views: []CombinedContributionView,
    raw_columns: []ColumnEvaluation,
    workspace: quotients.RowQuotientWorkspace,
    domain: circle_domain.CircleDomain,
    lifting_log_size: u32,
    domain_size: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        columns: TreeVec([]const ColumnEvaluation),
        sampled_points: TreeVec([][]CirclePointQM31),
        sampled_values: TreeVec([][]QM31),
        random_coeff: QM31,
        lifting_log_size: u32,
    ) !LazyQuotientProvider {
        return initForBackend(
            void,
            allocator,
            columns,
            sampled_points,
            sampled_values,
            random_coeff,
            lifting_log_size,
        );
    }

    pub fn initForBackend(
        comptime B: type,
        allocator: std.mem.Allocator,
        columns: TreeVec([]const ColumnEvaluation),
        sampled_points: TreeVec([][]CirclePointQM31),
        sampled_values: TreeVec([][]QM31),
        random_coeff: QM31,
        lifting_log_size: u32,
    ) !LazyQuotientProvider {
        if (columns.items.len != sampled_points.items.len) return QuotientOpsError.ShapeMismatch;
        if (columns.items.len != sampled_values.items.len) return QuotientOpsError.ShapeMismatch;

        for (columns.items, sampled_points.items, sampled_values.items) |tree_columns, tree_points, tree_values| {
            if (tree_columns.len != tree_points.len) return QuotientOpsError.ShapeMismatch;
            if (tree_columns.len != tree_values.len) return QuotientOpsError.ShapeMismatch;
            for (tree_columns) |column| {
                try column.validate();
                if (column.log_size > lifting_log_size) return QuotientOpsError.InvalidColumnLogSize;
            }
        }

        var column_log_sizes = try buildColumnLogSizes(allocator, columns);
        defer column_log_sizes.deinitDeep(allocator);

        const domain_size = try checkedPow2(lifting_log_size);
        const flat_columns = try flattenColumnsBorrowed(allocator, columns);
        errdefer allocator.free(flat_columns);

        var prepared = try prepareQuotientContext(
            allocator,
            column_log_sizes,
            sampled_points,
            sampled_values,
            random_coeff,
            lifting_log_size,
            flat_columns.len,
        );
        errdefer prepared.deinit(allocator);

        const nonzero_columns = try markNonzeroColumnsAndSamples(
            allocator,
            columns,
            sampled_values,
        );
        defer allocator.free(nonzero_columns);

        const use_raw_columns = comptime B != void and @hasDecl(B, "rawQuotientInputs") and B.rawQuotientInputs;
        var combined_views: []CombinedContributionView = &.{};
        if (!use_raw_columns) {
            const combined_plan = try buildCombinedContributionPlan(
                allocator,
                flat_columns,
                prepared.contribution_plan.active_column_indices,
                prepared.contribution_plan.ranges,
                prepared.contribution_plan.contributions,
                nonzero_columns,
                lifting_log_size,
            );
            combined_views = combined_plan.views;
        }

        var workspace = try quotients.RowQuotientWorkspace.init(allocator, prepared.sample_batches);
        errdefer workspace.deinit(allocator);

        const domain = canonic.CanonicCoset.new(lifting_log_size).circleDomain();

        return .{
            .prepared = prepared,
            .combined_views = combined_views,
            .raw_columns = if (use_raw_columns) flat_columns else blk: {
                allocator.free(flat_columns);
                break :blk &.{};
            },
            .workspace = workspace,
            .domain = domain,
            .lifting_log_size = lifting_log_size,
            .domain_size = domain_size,
        };
    }

    pub fn deinit(self: *LazyQuotientProvider, allocator: std.mem.Allocator) void {
        self.workspace.deinit(allocator);
        var combined_plan = CombinedContributionPlan{ .views = self.combined_views };
        combined_plan.deinit(allocator);
        if (self.raw_columns.len != 0) allocator.free(self.raw_columns);
        self.prepared.deinit(allocator);
        self.* = undefined;
    }

    /// Compute quotient values for positions `[chunk_start .. chunk_start + chunk_len)`.
    ///
    /// The 4 output coordinate buffers must each have length >= `chunk_len`.
    /// Positions must be in range `[0, domain_size)`.
    pub fn computeChunk(
        self: *LazyQuotientProvider,
        chunk_start: usize,
        chunk_len: usize,
        out_coords: *[qm31.SECURE_EXTENSION_DEGREE][]M31,
    ) !void {
        std.debug.assert(chunk_start + chunk_len <= self.domain_size);
        for (out_coords) |coord_buf| {
            std.debug.assert(coord_buf.len >= chunk_len);
        }

        for (0..chunk_len) |local_idx| {
            const position = chunk_start + local_idx;
            const domain_point = self.domain.at(core_utils.bitReverseIndex(position, self.lifting_log_size));
            try self.workspace.beginRow(domain_point);

            for (self.combined_views) |view| {
                const idx = if (view.is_direct)
                    position
                else blk: {
                    break :blk ((position >> view.shift_amt) << 1) + (position & 1);
                };
                const value = QM31.fromM31(
                    view.coordinates[0][idx],
                    view.coordinates[1][idx],
                    view.coordinates[2][idx],
                    view.coordinates[3][idx],
                );
                self.workspace.batch_numerators[view.batch_index] =
                    self.workspace.batch_numerators[view.batch_index].add(value);
            }

            const quotient_value = try quotients.finalizeRowQuotients(
                &self.prepared.quotient_constants,
                domain_point.y,
                self.workspace.batch_numerators,
                self.workspace.denominator_inverses,
            );
            const coords = quotient_value.toM31Array();
            inline for (0..qm31.SECURE_EXTENSION_DEGREE) |coord| {
                out_coords[coord][local_idx] = coords[coord];
            }
        }
    }

    /// Materialize the full quotient column, splitting disjoint domain ranges
    /// across the global prover pool when enough work is available.
    pub fn computeAll(
        self: *LazyQuotientProvider,
        allocator: std.mem.Allocator,
        out: *SecureColumnByCoords,
    ) !void {
        if (out.len() != self.domain_size) return QuotientOpsError.ShapeMismatch;

        if (!builtin.single_threaded) {
            if (try self.computeAllParallel(allocator, out)) return;
        }

        var chunk_start: usize = 0;
        while (chunk_start < self.domain_size) {
            const chunk_len = @min(LAZY_QUOTIENT_CHUNK_SIZE, self.domain_size - chunk_start);
            var chunk_coords: [qm31.SECURE_EXTENSION_DEGREE][]M31 = undefined;
            inline for (0..qm31.SECURE_EXTENSION_DEGREE) |coord| {
                chunk_coords[coord] = out.columns[coord][chunk_start..][0..chunk_len];
            }
            try self.computeChunk(chunk_start, chunk_len, &chunk_coords);
            chunk_start += chunk_len;
        }
    }

    fn computeAllParallel(
        self: *const LazyQuotientProvider,
        allocator: std.mem.Allocator,
        out: *SecureColumnByCoords,
    ) !bool {
        const pool = work_pool_mod.getGlobalPool() orelse return false;
        const n_workers = @min(pool.workerCount(), self.domain_size / MIN_POSITIONS_PER_WORKER);
        if (n_workers <= 1) return false;

        const workspaces = try allocator.alloc(quotients.RowQuotientWorkspace, n_workers);
        defer allocator.free(workspaces);
        var initialized: usize = 0;
        defer for (workspaces[0..initialized]) |*workspace| workspace.deinit(allocator);
        for (workspaces) |*workspace| {
            workspace.* = try quotients.RowQuotientWorkspace.init(allocator, self.prepared.sample_batches);
            initialized += 1;
        }

        var work_items: [work_pool_mod.MAX_WORKERS]StreamingChunkWork = undefined;
        const chunk_len = (self.domain_size + n_workers - 1) / n_workers;
        for (0..n_workers) |worker| {
            const start = worker * chunk_len;
            work_items[worker] = .{
                .out_columns = out.columns,
                .start = start,
                .end = @min(self.domain_size, start + chunk_len),
                .workspace = &workspaces[worker],
                .domain = self.domain,
                .combined_views = self.combined_views,
                .quotient_constants = &self.prepared.quotient_constants,
                .lifting_log_size = self.lifting_log_size,
            };
        }

        var wait_group: std.Thread.WaitGroup = .{};
        for (work_items[1..n_workers]) |*item| {
            pool.spawnWg(&wait_group, streamingChunkWorker, .{@as(*const StreamingChunkWork, item)});
        }
        streamingChunkWorker(&work_items[0]);
        wait_group.wait();
        return true;
    }
};

/// One committed trace/evaluation column.
///
/// Invariants:
/// - `values.len == 2^log_size`.
/// - `values` are in bit-reversed order, matching Stwo prover conventions.
pub const ColumnEvaluation = struct {
    log_size: u32,
    values: []const M31,

    pub fn validate(self: ColumnEvaluation) QuotientOpsError!void {
        const expected_len = try checkedPow2(self.log_size);
        if (self.values.len != expected_len) return QuotientOpsError.InvalidColumnLength;
    }

    /// Returns the value at lifted-domain position `position` where the maximal
    /// domain has log size `lifting_log_size`.
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

        const idx = ((position >> shift_amt) << 1) + (position & 1);
        if (idx >= self.values.len) return QuotientOpsError.InvalidColumnLength;
        return self.values[idx];
    }
};

/// Computes FRI quotient evaluations for all points in the lifted domain.
///
/// Inputs:
/// - `columns`: per-tree, per-column evaluations and original log sizes.
/// - `sampled_points`: per-tree, per-column OODS sample points; shape must match `columns`.
/// - `sampled_values`: per-tree, per-column OODS sample values; shape must match `columns`.
/// - `random_coeff`: random challenge used for linear combination.
/// - `lifting_log_size`: maximal lifted domain size.
/// - `log_blowup_factor`: included for API parity (not used directly here).
///
/// Output:
/// - secure-field quotient evaluation values over all lifted-domain positions.
pub fn computeFriQuotients(
    allocator: std.mem.Allocator,
    columns: TreeVec([]const ColumnEvaluation),
    sampled_points: TreeVec([][]CirclePointQM31),
    sampled_values: TreeVec([][]QM31),
    random_coeff: QM31,
    lifting_log_size: u32,
    log_blowup_factor: u32,
) !SecureColumnByCoords {
    _ = log_blowup_factor;
    return computeFriQuotientsWithStrategy(
        allocator,
        columns,
        sampled_points,
        sampled_values,
        random_coeff,
        lifting_log_size,
        null,
    );
}

fn computeFriQuotientsWithStrategy(
    allocator: std.mem.Allocator,
    columns: TreeVec([]const ColumnEvaluation),
    sampled_points: TreeVec([][]CirclePointQM31),
    sampled_values: TreeVec([][]QM31),
    random_coeff: QM31,
    lifting_log_size: u32,
    forced_strategy: ?QuotientConstructionStrategy,
) !SecureColumnByCoords {
    if (columns.items.len != sampled_points.items.len) return QuotientOpsError.ShapeMismatch;
    if (columns.items.len != sampled_values.items.len) return QuotientOpsError.ShapeMismatch;

    for (columns.items, sampled_points.items, sampled_values.items) |tree_columns, tree_points, tree_values| {
        if (tree_columns.len != tree_points.len) return QuotientOpsError.ShapeMismatch;
        if (tree_columns.len != tree_values.len) return QuotientOpsError.ShapeMismatch;
        for (tree_columns) |column| {
            try column.validate();
            if (column.log_size > lifting_log_size) return QuotientOpsError.InvalidColumnLogSize;
        }
    }

    var column_log_sizes = try buildColumnLogSizes(allocator, columns);
    defer column_log_sizes.deinitDeep(allocator);

    const domain_size = try checkedPow2(lifting_log_size);
    const flat_columns = try flattenColumnsBorrowed(allocator, columns);
    defer allocator.free(flat_columns);

    var prepared = try prepareQuotientContext(
        allocator,
        column_log_sizes,
        sampled_points,
        sampled_values,
        random_coeff,
        lifting_log_size,
        flat_columns.len,
    );
    defer prepared.deinit(allocator);

    const strategy = forced_strategy orelse chooseQuotientConstructionStrategy(
        prepared.contribution_plan.activeColumnCount(),
        domain_size,
    );
    return switch (strategy) {
        .materialized => computeMaterializedFriQuotientsParallel(
            allocator,
            flat_columns,
            &prepared,
            lifting_log_size,
            domain_size,
        ) catch computeMaterializedFriQuotients(
            allocator,
            flat_columns,
            &prepared,
            lifting_log_size,
            domain_size,
        ),
        .streaming => computeStreamingFriQuotientsParallel(
            allocator,
            flat_columns,
            &prepared,
            lifting_log_size,
            domain_size,
        ) catch computeStreamingFriQuotients(
            allocator,
            flat_columns,
            &prepared,
            lifting_log_size,
            domain_size,
        ),
    };
}

fn checkedPow2(log_size: u32) QuotientOpsError!usize {
    if (log_size >= @bitSizeOf(usize)) return QuotientOpsError.InvalidColumnLogSize;
    return @as(usize, 1) << @intCast(log_size);
}

fn flattenColumnsBorrowed(
    allocator: std.mem.Allocator,
    columns: TreeVec([]const ColumnEvaluation),
) ![]ColumnEvaluation {
    const out = try allocator.alloc(ColumnEvaluation, countColumns(columns));
    var at: usize = 0;
    for (columns.items) |tree_columns| {
        for (tree_columns) |column| {
            out[at] = column;
            at += 1;
        }
    }
    return out;
}

fn prepareQuotientContext(
    allocator: std.mem.Allocator,
    column_log_sizes: TreeVec([]u32),
    sampled_points: TreeVec([][]CirclePointQM31),
    sampled_values: TreeVec([][]QM31),
    random_coeff: QM31,
    lifting_log_size: u32,
    flat_column_count: usize,
) !PreparedQuotientContext {
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

fn buildColumnLogSizes(
    allocator: std.mem.Allocator,
    columns: TreeVec([]const ColumnEvaluation),
) !TreeVec([]u32) {
    const out = try allocator.alloc([]u32, columns.items.len);
    errdefer allocator.free(out);

    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |tree_sizes| allocator.free(tree_sizes);
    }

    for (columns.items, 0..) |tree_columns, tree_idx| {
        out[tree_idx] = try allocator.alloc(u32, tree_columns.len);
        initialized += 1;
        for (tree_columns, 0..) |column, col_idx| {
            out[tree_idx][col_idx] = column.log_size;
        }
    }

    return TreeVec([]u32).initOwned(out);
}

fn countColumns(columns: TreeVec([]const ColumnEvaluation)) usize {
    var total: usize = 0;
    for (columns.items) |tree_columns| total += tree_columns.len;
    return total;
}

fn chooseQuotientConstructionStrategy(
    active_column_count: usize,
    domain_size: usize,
) QuotientConstructionStrategy {
    if (domain_size >= STREAMING_DOMAIN_THRESHOLD and
        active_column_count > STREAMING_ACTIVE_COLUMN_THRESHOLD)
    {
        return .streaming;
    }

    const lifted_cells = std.math.mul(usize, active_column_count, domain_size) catch return .streaming;
    const lifted_bytes = std.math.mul(usize, lifted_cells, @sizeOf(M31)) catch return .streaming;
    return if (lifted_bytes > MATERIALIZE_LIFTED_THRESHOLD_BYTES)
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

fn markNonzeroColumnsAndSamples(
    allocator: std.mem.Allocator,
    columns: TreeVec([]const ColumnEvaluation),
    sampled_values: TreeVec([][]QM31),
) ![]bool {
    const nonzero = try allocator.alloc(bool, countColumns(columns));
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

fn buildCombinedContributionPlan(
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

fn materializeActiveLiftedColumns(
    allocator: std.mem.Allocator,
    flat_columns: []const ColumnEvaluation,
    active_column_indices: []const usize,
    lifting_log_size: u32,
) !MaterializedLiftedColumns {
    const domain_size = try checkedPow2(lifting_log_size);
    const total_cells = std.math.mul(usize, active_column_indices.len, domain_size) catch return QuotientOpsError.ShapeMismatch;
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

fn computeMaterializedFriQuotients(
    allocator: std.mem.Allocator,
    flat_columns: []const ColumnEvaluation,
    prepared: *const PreparedQuotientContext,
    lifting_log_size: u32,
    domain_size: usize,
) !SecureColumnByCoords {
    const domain = canonic.CanonicCoset.new(lifting_log_size).circleDomain();
    std.debug.assert(domain.size() == domain_size);

    var lifted_columns = try materializeActiveLiftedColumns(
        allocator,
        flat_columns,
        prepared.contribution_plan.active_column_indices,
        lifting_log_size,
    );
    defer lifted_columns.deinit(allocator);

    var workspace = try quotients.RowQuotientWorkspace.init(allocator, prepared.sample_batches);
    defer workspace.deinit(allocator);

    var out = try SecureColumnByCoords.uninitialized(allocator, domain_size);
    errdefer out.deinit(allocator);

    for (0..domain_size) |position| {
        const domain_point = domain.at(core_utils.bitReverseIndex(position, lifting_log_size));
        try workspace.beginRow(domain_point);
        for (lifted_columns.columns, prepared.contribution_plan.ranges) |lifted_column, contribution_range| {
            // Small-big multiplication: use QM31.mulM31(M31) (4 base-field muls)
            // instead of QM31.fromBase(M31).mul(QM31) (9 muls via Karatsuba
            // with wasted zero-operand multiplications).
            const base_value = lifted_column[position];
            for (prepared.contribution_plan.contributions[contribution_range.start .. contribution_range.start + contribution_range.len]) |contribution| {
                workspace.batch_numerators[contribution.batch_index] = workspace.batch_numerators[contribution.batch_index].add(
                    contribution.value_coeff.mulM31(base_value),
                );
            }
        }
        try writeQuotientRow(
            &out,
            position,
            &prepared.quotient_constants,
            domain_point.y,
            &workspace,
        );
    }

    return out;
}

fn computeStreamingFriQuotients(
    allocator: std.mem.Allocator,
    flat_columns: []const ColumnEvaluation,
    prepared: *const PreparedQuotientContext,
    lifting_log_size: u32,
    domain_size: usize,
) !SecureColumnByCoords {
    const domain = canonic.CanonicCoset.new(lifting_log_size).circleDomain();
    std.debug.assert(domain.size() == domain_size);

    const nonzero_columns = try allocator.alloc(bool, flat_columns.len);
    defer allocator.free(nonzero_columns);
    @memset(nonzero_columns, true);
    var combined_plan = try buildCombinedContributionPlan(
        allocator,
        flat_columns,
        prepared.contribution_plan.active_column_indices,
        prepared.contribution_plan.ranges,
        prepared.contribution_plan.contributions,
        nonzero_columns,
        lifting_log_size,
    );
    defer combined_plan.deinit(allocator);

    var workspace = try quotients.RowQuotientWorkspace.init(allocator, prepared.sample_batches);
    defer workspace.deinit(allocator);

    var out = try SecureColumnByCoords.uninitialized(allocator, domain_size);
    errdefer out.deinit(allocator);

    for (0..domain_size) |position| {
        const domain_point = domain.at(core_utils.bitReverseIndex(position, lifting_log_size));
        try workspace.beginRow(domain_point);
        for (combined_plan.views) |view| {
            const idx = if (view.is_direct)
                position
            else blk: {
                break :blk ((position >> view.shift_amt) << 1) + (position & 1);
            };
            const value = QM31.fromM31(
                view.coordinates[0][idx],
                view.coordinates[1][idx],
                view.coordinates[2][idx],
                view.coordinates[3][idx],
            );
            workspace.batch_numerators[view.batch_index] = workspace.batch_numerators[view.batch_index].add(value);
        }
        try writeQuotientRow(
            &out,
            position,
            &prepared.quotient_constants,
            domain_point.y,
            &workspace,
        );
    }

    return out;
}

// ---------------------------------------------------------------------------
// Parallel quotient computation
// ---------------------------------------------------------------------------

/// Work item for a single chunk of domain positions (materialized path).
const MaterializedChunkWork = struct {
    out_columns: [qm31.SECURE_EXTENSION_DEGREE][]M31,
    start: usize,
    end: usize,
    workspace: *quotients.RowQuotientWorkspace,
    domain: CircleDomain,
    lifted_columns: []const []M31,
    contribution_plan_ranges: []const ColumnContributionRange,
    contributions: []const ColumnContribution,
    quotient_constants: *const quotients.QuotientConstants,
    lifting_log_size: u32,
};

fn materializedChunkWorker(item: *const MaterializedChunkWork) void {
    const ws = item.workspace;
    for (item.start..item.end) |position| {
        const domain_point = item.domain.at(core_utils.bitReverseIndex(position, item.lifting_log_size));
        ws.beginRow(domain_point) catch return;
        for (item.lifted_columns, item.contribution_plan_ranges) |lifted_column, contribution_range| {
            const base_value = lifted_column[position];
            for (item.contributions[contribution_range.start .. contribution_range.start + contribution_range.len]) |contribution| {
                ws.batch_numerators[contribution.batch_index] = ws.batch_numerators[contribution.batch_index].add(
                    contribution.value_coeff.mulM31(base_value),
                );
            }
        }
        writeQuotientRowNoError(
            item.out_columns,
            position,
            item.quotient_constants,
            domain_point.y,
            ws,
        );
    }
}

/// Work item for a single chunk of domain positions (streaming path).
const StreamingChunkWork = struct {
    out_columns: [qm31.SECURE_EXTENSION_DEGREE][]M31,
    start: usize,
    end: usize,
    workspace: *quotients.RowQuotientWorkspace,
    domain: CircleDomain,
    combined_views: []const CombinedContributionView,
    quotient_constants: *const quotients.QuotientConstants,
    lifting_log_size: u32,
};

fn streamingChunkWorker(item: *const StreamingChunkWork) void {
    const ws = item.workspace;
    for (item.start..item.end) |position| {
        const domain_point = item.domain.at(core_utils.bitReverseIndex(position, item.lifting_log_size));
        ws.beginRow(domain_point) catch return;
        for (item.combined_views) |view| {
            const idx = if (view.is_direct)
                position
            else blk: {
                break :blk ((position >> view.shift_amt) << 1) + (position & 1);
            };
            const value = QM31.fromM31(
                view.coordinates[0][idx],
                view.coordinates[1][idx],
                view.coordinates[2][idx],
                view.coordinates[3][idx],
            );
            ws.batch_numerators[view.batch_index] = ws.batch_numerators[view.batch_index].add(value);
        }
        writeQuotientRowNoError(
            item.out_columns,
            position,
            item.quotient_constants,
            domain_point.y,
            ws,
        );
    }
}

/// Write a quotient row without returning an error (for use in worker threads).
/// Silently skips if finalizeRowQuotients fails (should not happen with valid data).
fn writeQuotientRowNoError(
    out_columns: [qm31.SECURE_EXTENSION_DEGREE][]M31,
    position: usize,
    quotient_constants: *const quotients.QuotientConstants,
    domain_y: M31,
    workspace: *const quotients.RowQuotientWorkspace,
) void {
    const quotient_value = quotients.finalizeRowQuotients(
        quotient_constants,
        domain_y,
        workspace.batch_numerators,
        workspace.denominator_inverses,
    ) catch return;
    const coords = quotient_value.toM31Array();
    inline for (0..qm31.SECURE_EXTENSION_DEGREE) |coord| {
        out_columns[coord][position] = coords[coord];
    }
}

/// Parallel version of `computeMaterializedFriQuotients`.
/// Falls back to sequential via error return if parallelism is unavailable.
fn computeMaterializedFriQuotientsParallel(
    allocator: std.mem.Allocator,
    flat_columns: []const ColumnEvaluation,
    prepared: *const PreparedQuotientContext,
    lifting_log_size: u32,
    domain_size: usize,
) !SecureColumnByCoords {
    if (comptime builtin.single_threaded) return error.ParallelUnavailable;
    const pool = work_pool_mod.getGlobalPool() orelse return error.ParallelUnavailable;

    const n_workers = @min(pool.workerCount(), domain_size / MIN_POSITIONS_PER_WORKER);
    if (n_workers <= 1) return error.ParallelUnavailable;

    const domain = canonic.CanonicCoset.new(lifting_log_size).circleDomain();

    var lifted_columns = try materializeActiveLiftedColumns(
        allocator,
        flat_columns,
        prepared.contribution_plan.active_column_indices,
        lifting_log_size,
    );
    defer lifted_columns.deinit(allocator);

    // Allocate per-worker workspaces.
    const workspaces = try allocator.alloc(quotients.RowQuotientWorkspace, n_workers);
    defer allocator.free(workspaces);
    var ws_initialized: usize = 0;
    defer for (workspaces[0..ws_initialized]) |*ws| ws.deinit(allocator);
    for (workspaces) |*ws| {
        ws.* = try quotients.RowQuotientWorkspace.init(allocator, prepared.sample_batches);
        ws_initialized += 1;
    }

    var out = try SecureColumnByCoords.uninitialized(allocator, domain_size);
    errdefer out.deinit(allocator);

    const chunk_size = domain_size / n_workers;

    // Build work items on the stack (bounded by MAX_WORKERS).
    var work_items: [work_pool_mod.MAX_WORKERS]MaterializedChunkWork = undefined;
    for (0..n_workers) |w| {
        const start = w * chunk_size;
        const end = if (w == n_workers - 1) domain_size else start + chunk_size;
        work_items[w] = .{
            .out_columns = out.columns,
            .start = start,
            .end = end,
            .workspace = &workspaces[w],
            .domain = domain,
            .lifted_columns = lifted_columns.columns,
            .contribution_plan_ranges = prepared.contribution_plan.ranges,
            .contributions = prepared.contribution_plan.contributions,
            .quotient_constants = &prepared.quotient_constants,
            .lifting_log_size = lifting_log_size,
        };
    }

    // Dispatch workers: all but the first to the pool, first on this thread.
    var wait_group: std.Thread.WaitGroup = .{};
    for (work_items[1..n_workers]) |*item| {
        pool.spawnWg(&wait_group, materializedChunkWorker, .{@as(*const MaterializedChunkWork, item)});
    }
    materializedChunkWorker(&work_items[0]);
    wait_group.wait();

    return out;
}

/// Parallel version of `computeStreamingFriQuotients`.
/// Falls back to sequential via error return if parallelism is unavailable.
fn computeStreamingFriQuotientsParallel(
    allocator: std.mem.Allocator,
    flat_columns: []const ColumnEvaluation,
    prepared: *const PreparedQuotientContext,
    lifting_log_size: u32,
    domain_size: usize,
) !SecureColumnByCoords {
    if (comptime builtin.single_threaded) return error.ParallelUnavailable;
    const pool = work_pool_mod.getGlobalPool() orelse return error.ParallelUnavailable;

    const n_workers = @min(pool.workerCount(), domain_size / MIN_POSITIONS_PER_WORKER);
    if (n_workers <= 1) return error.ParallelUnavailable;

    const domain = canonic.CanonicCoset.new(lifting_log_size).circleDomain();

    const nonzero_columns = try allocator.alloc(bool, flat_columns.len);
    defer allocator.free(nonzero_columns);
    @memset(nonzero_columns, true);
    var combined_plan = try buildCombinedContributionPlan(
        allocator,
        flat_columns,
        prepared.contribution_plan.active_column_indices,
        prepared.contribution_plan.ranges,
        prepared.contribution_plan.contributions,
        nonzero_columns,
        lifting_log_size,
    );
    defer combined_plan.deinit(allocator);

    // Allocate per-worker workspaces.
    const workspaces = try allocator.alloc(quotients.RowQuotientWorkspace, n_workers);
    defer allocator.free(workspaces);
    var ws_initialized: usize = 0;
    defer for (workspaces[0..ws_initialized]) |*ws| ws.deinit(allocator);
    for (workspaces) |*ws| {
        ws.* = try quotients.RowQuotientWorkspace.init(allocator, prepared.sample_batches);
        ws_initialized += 1;
    }

    var out = try SecureColumnByCoords.uninitialized(allocator, domain_size);
    errdefer out.deinit(allocator);

    const chunk_size = domain_size / n_workers;

    // Build work items on the stack (bounded by MAX_WORKERS).
    var work_items: [work_pool_mod.MAX_WORKERS]StreamingChunkWork = undefined;
    for (0..n_workers) |w| {
        const start = w * chunk_size;
        const end = if (w == n_workers - 1) domain_size else start + chunk_size;
        work_items[w] = .{
            .out_columns = out.columns,
            .start = start,
            .end = end,
            .workspace = &workspaces[w],
            .domain = domain,
            .combined_views = combined_plan.views,
            .quotient_constants = &prepared.quotient_constants,
            .lifting_log_size = lifting_log_size,
        };
    }

    // Dispatch workers: all but the first to the pool, first on this thread.
    var wait_group: std.Thread.WaitGroup = .{};
    for (work_items[1..n_workers]) |*item| {
        pool.spawnWg(&wait_group, streamingChunkWorker, .{@as(*const StreamingChunkWork, item)});
    }
    streamingChunkWorker(&work_items[0]);
    wait_group.wait();

    return out;
}

fn writeQuotientRow(
    out: *SecureColumnByCoords,
    position: usize,
    quotient_constants: *const quotients.QuotientConstants,
    domain_y: M31,
    workspace: *const quotients.RowQuotientWorkspace,
) !void {
    const quotient_value = try quotients.finalizeRowQuotients(
        quotient_constants,
        domain_y,
        workspace.batch_numerators,
        workspace.denominator_inverses,
    );
    const coords = quotient_value.toM31Array();
    inline for (0..qm31.SECURE_EXTENSION_DEGREE) |coord| {
        out.columns[coord][position] = coords[coord];
    }
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

const SplitPointSamples = struct {
    points: TreeVec([][]CirclePointQM31),
    values: TreeVec([][]QM31),

    fn deinit(self: *SplitPointSamples, allocator: std.mem.Allocator) void {
        self.points.deinitDeep(allocator);
        self.values.deinitDeep(allocator);
        self.* = undefined;
    }
};

fn splitPointSamplesForTest(
    allocator: std.mem.Allocator,
    samples: TreeVec([][]PointSample),
) !SplitPointSamples {
    const point_trees = try allocator.alloc([][]CirclePointQM31, samples.items.len);
    errdefer allocator.free(point_trees);
    const value_trees = try allocator.alloc([][]QM31, samples.items.len);
    errdefer allocator.free(value_trees);

    var initialized_trees: usize = 0;
    errdefer {
        for (point_trees[0..initialized_trees]) |tree| {
            for (tree) |column| allocator.free(column);
            allocator.free(tree);
        }
        for (value_trees[0..initialized_trees]) |tree| {
            for (tree) |column| allocator.free(column);
            allocator.free(tree);
        }
    }

    for (samples.items, 0..) |tree, tree_idx| {
        point_trees[tree_idx] = try allocator.alloc([]CirclePointQM31, tree.len);
        value_trees[tree_idx] = try allocator.alloc([]QM31, tree.len);
        initialized_trees += 1;

        var initialized_cols: usize = 0;
        errdefer {
            for (point_trees[tree_idx][0..initialized_cols]) |column| allocator.free(column);
            allocator.free(point_trees[tree_idx]);
            for (value_trees[tree_idx][0..initialized_cols]) |column| allocator.free(column);
            allocator.free(value_trees[tree_idx]);
        }

        for (tree, 0..) |column, col_idx| {
            const points = try allocator.alloc(CirclePointQM31, column.len);
            const values = try allocator.alloc(QM31, column.len);
            point_trees[tree_idx][col_idx] = points;
            value_trees[tree_idx][col_idx] = values;
            initialized_cols += 1;

            for (column, 0..) |sample, sample_idx| {
                points[sample_idx] = sample.point;
                values[sample_idx] = sample.value;
            }
        }
    }

    return .{
        .points = TreeVec([][]CirclePointQM31).initOwned(point_trees),
        .values = TreeVec([][]QM31).initOwned(value_trees),
    };
}

fn borrowColumnsForTest(
    allocator: std.mem.Allocator,
    columns: TreeVec([]ColumnEvaluation),
) !TreeVec([]const ColumnEvaluation) {
    const out = try allocator.alloc([]const ColumnEvaluation, columns.items.len);
    errdefer allocator.free(out);
    for (columns.items, 0..) |tree_columns, i| out[i] = tree_columns;
    return TreeVec([]const ColumnEvaluation).initOwned(out);
}

test "prover pcs quotient ops: compute fri quotients matches direct fri answers for legacy point-sample fixtures" {
    const alloc = std.testing.allocator;
    const lifting_log_size: u32 = 5;
    const domain_size = @as(usize, 1) << @intCast(lifting_log_size);

    const col0 = try alloc.alloc(M31, domain_size);
    defer alloc.free(col0);
    for (col0, 0..) |*value, i| value.* = M31.fromCanonical(@intCast(i + 1));

    const col1_log_size: u32 = 3;
    const col1 = try alloc.alloc(M31, @as(usize, 1) << @intCast(col1_log_size));
    defer alloc.free(col1);
    for (col1, 0..) |*value, i| value.* = M31.fromCanonical(@intCast(101 + i));

    const tree_columns = try alloc.dupe(ColumnEvaluation, &[_]ColumnEvaluation{
        .{ .log_size = lifting_log_size, .values = col0 },
        .{ .log_size = col1_log_size, .values = col1 },
    });
    var columns = TreeVec([]ColumnEvaluation).initOwned(
        try alloc.dupe([]ColumnEvaluation, &[_][]ColumnEvaluation{tree_columns}),
    );
    defer columns.deinitDeep(alloc);

    const point0 = @import("../../core/circle.zig").SECURE_FIELD_CIRCLE_GEN.mul(7);
    const point1 = @import("../../core/circle.zig").SECURE_FIELD_CIRCLE_GEN.mul(19);

    const col0_samples = try alloc.dupe(PointSample, &[_]PointSample{
        .{ .point = point0, .value = QM31.fromU32Unchecked(1, 2, 3, 4) },
    });
    const col1_samples = try alloc.dupe(PointSample, &[_]PointSample{
        .{ .point = point0, .value = QM31.fromU32Unchecked(5, 6, 7, 8) },
        .{ .point = point1, .value = QM31.fromU32Unchecked(9, 10, 11, 12) },
    });
    const tree_samples = try alloc.dupe([]PointSample, &[_][]PointSample{ col0_samples, col1_samples });
    var samples = TreeVec([][]PointSample).initOwned(
        try alloc.dupe([][]PointSample, &[_][][]PointSample{tree_samples}),
    );
    defer samples.deinitDeep(alloc);
    var split_samples = try splitPointSamplesForTest(alloc, samples);
    defer split_samples.deinit(alloc);
    var columns_borrowed = try borrowColumnsForTest(alloc, columns);
    defer columns_borrowed.deinit(alloc);

    const alpha = QM31.fromU32Unchecked(3, 0, 1, 0);
    var quot_col = try computeFriQuotients(
        alloc,
        columns_borrowed,
        split_samples.points,
        split_samples.values,
        alpha,
        lifting_log_size,
        1,
    );
    defer quot_col.deinit(alloc);

    var col_sizes = TreeVec([]u32).initOwned(
        try alloc.dupe([]u32, &[_][]u32{try alloc.dupe(u32, &[_]u32{ lifting_log_size, col1_log_size })}),
    );
    defer col_sizes.deinitDeep(alloc);

    const q0 = try alloc.dupe(M31, col0);

    const q1 = try alloc.alloc(M31, domain_size);
    const shift: u32 = lifting_log_size - col1_log_size;
    const shift_amt: std.math.Log2Int(usize) = @intCast(shift + 1);
    for (0..domain_size) |position| {
        const idx = ((position >> shift_amt) << 1) + (position & 1);
        q1[position] = col1[idx];
    }

    var queried_values = TreeVec([][]M31).initOwned(
        try alloc.dupe([][]M31, &[_][][]M31{try alloc.dupe([]M31, &[_][]M31{ q0, q1 })}),
    );
    defer queried_values.deinitDeep(alloc);

    const query_positions = try alloc.alloc(usize, domain_size);
    defer alloc.free(query_positions);
    for (query_positions, 0..) |*position, i| position.* = i;

    const expected = try quotients.friAnswers(
        alloc,
        col_sizes,
        split_samples.points,
        split_samples.values,
        alpha,
        query_positions,
        queried_values,
        lifting_log_size,
    );
    defer alloc.free(expected);

    const got = try quot_col.toVec(alloc);
    defer alloc.free(got);

    try std.testing.expectEqual(expected.len, got.len);
    for (expected, got) |lhs, rhs| {
        try std.testing.expect(lhs.eql(rhs));
    }
}

test "prover pcs quotient ops: strategy switches to streaming for medium-wide lifted workloads" {
    try std.testing.expectEqual(
        QuotientConstructionStrategy.materialized,
        chooseQuotientConstructionStrategy(256, 2048),
    );
    try std.testing.expectEqual(
        QuotientConstructionStrategy.streaming,
        chooseQuotientConstructionStrategy(1500, 4096),
    );
    try std.testing.expectEqual(
        QuotientConstructionStrategy.streaming,
        chooseQuotientConstructionStrategy(1400, 8192),
    );
}

test "prover pcs quotient ops: forced materialized and streaming strategies match with sparse active columns" {
    const alloc = std.testing.allocator;
    const lifting_log_size: u32 = 6;
    const domain_size = @as(usize, 1) << @intCast(lifting_log_size);

    const col0 = try alloc.alloc(M31, domain_size);
    defer alloc.free(col0);
    for (col0, 0..) |*value, i| value.* = M31.fromCanonical(@intCast(i + 3));

    const col1_log_size: u32 = 4;
    const col1 = try alloc.alloc(M31, @as(usize, 1) << @intCast(col1_log_size));
    defer alloc.free(col1);
    for (col1, 0..) |*value, i| value.* = M31.fromCanonical(@intCast(101 + i));

    const col2 = try alloc.alloc(M31, domain_size);
    defer alloc.free(col2);
    for (col2, 0..) |*value, i| value.* = M31.fromCanonical(@intCast(205 + i));

    const tree_columns = try alloc.dupe(ColumnEvaluation, &[_]ColumnEvaluation{
        .{ .log_size = lifting_log_size, .values = col0 },
        .{ .log_size = col1_log_size, .values = col1 },
        .{ .log_size = lifting_log_size, .values = col2 },
    });
    var columns = TreeVec([]ColumnEvaluation).initOwned(
        try alloc.dupe([]ColumnEvaluation, &[_][]ColumnEvaluation{tree_columns}),
    );
    defer columns.deinitDeep(alloc);
    var columns_borrowed = try borrowColumnsForTest(alloc, columns);
    defer columns_borrowed.deinit(alloc);

    const point0 = @import("../../core/circle.zig").SECURE_FIELD_CIRCLE_GEN.mul(7);
    const point1 = @import("../../core/circle.zig").SECURE_FIELD_CIRCLE_GEN.mul(13);

    const col0_samples = try alloc.dupe(PointSample, &[_]PointSample{
        .{ .point = point0, .value = QM31.fromU32Unchecked(1, 2, 3, 4) },
    });
    const col1_samples = try alloc.dupe(PointSample, &[_]PointSample{
        .{ .point = point0, .value = QM31.fromU32Unchecked(5, 6, 7, 8) },
        .{ .point = point1, .value = QM31.fromU32Unchecked(9, 10, 11, 12) },
    });
    const col2_samples = try alloc.alloc(PointSample, 0);
    const tree_samples = try alloc.dupe([]PointSample, &[_][]PointSample{
        col0_samples,
        col1_samples,
        col2_samples,
    });
    var samples = TreeVec([][]PointSample).initOwned(
        try alloc.dupe([][]PointSample, &[_][][]PointSample{tree_samples}),
    );
    defer samples.deinitDeep(alloc);
    var split_samples = try splitPointSamplesForTest(alloc, samples);
    defer split_samples.deinit(alloc);

    const alpha = QM31.fromU32Unchecked(3, 0, 1, 0);
    var materialized = try computeFriQuotientsWithStrategy(
        alloc,
        columns_borrowed,
        split_samples.points,
        split_samples.values,
        alpha,
        lifting_log_size,
        .materialized,
    );
    defer materialized.deinit(alloc);
    var streaming = try computeFriQuotientsWithStrategy(
        alloc,
        columns_borrowed,
        split_samples.points,
        split_samples.values,
        alpha,
        lifting_log_size,
        .streaming,
    );
    defer streaming.deinit(alloc);

    const materialized_values = try materialized.toVec(alloc);
    defer alloc.free(materialized_values);
    const streaming_values = try streaming.toVec(alloc);
    defer alloc.free(streaming_values);

    try std.testing.expectEqual(materialized_values.len, streaming_values.len);
    for (materialized_values, streaming_values) |lhs, rhs| {
        try std.testing.expect(lhs.eql(rhs));
    }
}

test "prover pcs quotient ops: rejects invalid column length" {
    const alloc = std.testing.allocator;

    const bad_column = [_]M31{ M31.one(), M31.one(), M31.one() };
    const tree_columns = try alloc.dupe(ColumnEvaluation, &[_]ColumnEvaluation{
        .{ .log_size = 2, .values = bad_column[0..] },
    });
    var columns = TreeVec([]ColumnEvaluation).initOwned(
        try alloc.dupe([]ColumnEvaluation, &[_][]ColumnEvaluation{tree_columns}),
    );
    defer columns.deinitDeep(alloc);

    const sample_col = try alloc.dupe(PointSample, &[_]PointSample{
        .{ .point = @import("../../core/circle.zig").SECURE_FIELD_CIRCLE_GEN, .value = QM31.one() },
    });
    const sample_tree = try alloc.dupe([]PointSample, &[_][]PointSample{sample_col});
    var samples = TreeVec([][]PointSample).initOwned(
        try alloc.dupe([][]PointSample, &[_][][]PointSample{sample_tree}),
    );
    defer samples.deinitDeep(alloc);
    var split_samples = try splitPointSamplesForTest(alloc, samples);
    defer split_samples.deinit(alloc);
    var columns_borrowed = try borrowColumnsForTest(alloc, columns);
    defer columns_borrowed.deinit(alloc);

    try std.testing.expectError(
        QuotientOpsError.InvalidColumnLength,
        computeFriQuotients(
            alloc,
            columns_borrowed,
            split_samples.points,
            split_samples.values,
            QM31.one(),
            2,
            1,
        ),
    );
}

test "prover pcs quotient ops: rejects column log size above lifting" {
    const alloc = std.testing.allocator;

    const column = [_]M31{ M31.one(), M31.one(), M31.one(), M31.one() };
    const tree_columns = try alloc.dupe(ColumnEvaluation, &[_]ColumnEvaluation{
        .{ .log_size = 2, .values = column[0..] },
    });
    var columns = TreeVec([]ColumnEvaluation).initOwned(
        try alloc.dupe([]ColumnEvaluation, &[_][]ColumnEvaluation{tree_columns}),
    );
    defer columns.deinitDeep(alloc);

    const sample_col = try alloc.dupe(PointSample, &[_]PointSample{
        .{ .point = @import("../../core/circle.zig").SECURE_FIELD_CIRCLE_GEN, .value = QM31.one() },
    });
    const sample_tree = try alloc.dupe([]PointSample, &[_][]PointSample{sample_col});
    var samples = TreeVec([][]PointSample).initOwned(
        try alloc.dupe([][]PointSample, &[_][][]PointSample{sample_tree}),
    );
    defer samples.deinitDeep(alloc);
    var split_samples = try splitPointSamplesForTest(alloc, samples);
    defer split_samples.deinit(alloc);
    var columns_borrowed = try borrowColumnsForTest(alloc, columns);
    defer columns_borrowed.deinit(alloc);

    try std.testing.expectError(
        QuotientOpsError.InvalidColumnLogSize,
        computeFriQuotients(
            alloc,
            columns_borrowed,
            split_samples.points,
            split_samples.values,
            QM31.one(),
            1,
            1,
        ),
    );
}

test "prover pcs quotient ops: rejects shape mismatch" {
    const alloc = std.testing.allocator;

    const column = [_]M31{ M31.one(), M31.one() };
    const tree_columns = try alloc.dupe(ColumnEvaluation, &[_]ColumnEvaluation{
        .{ .log_size = 1, .values = column[0..] },
    });
    var columns = TreeVec([]ColumnEvaluation).initOwned(
        try alloc.dupe([]ColumnEvaluation, &[_][]ColumnEvaluation{tree_columns}),
    );
    defer columns.deinitDeep(alloc);
    var columns_borrowed = try borrowColumnsForTest(alloc, columns);
    defer columns_borrowed.deinit(alloc);

    var sampled_points = TreeVec([][]CirclePointQM31).initOwned(try alloc.alloc([][]CirclePointQM31, 0));
    defer sampled_points.deinitDeep(alloc);
    var sampled_values = TreeVec([][]QM31).initOwned(try alloc.alloc([][]QM31, 0));
    defer sampled_values.deinitDeep(alloc);

    try std.testing.expectError(
        QuotientOpsError.ShapeMismatch,
        computeFriQuotients(
            alloc,
            columns_borrowed,
            sampled_points,
            sampled_values,
            QM31.one(),
            1,
            1,
        ),
    );
}

test "prover pcs quotient ops: lazy provider matches materialized output" {
    const alloc = std.testing.allocator;
    const lifting_log_size: u32 = 6;
    const domain_size = @as(usize, 1) << @intCast(lifting_log_size);

    const col0 = try alloc.alloc(M31, domain_size);
    defer alloc.free(col0);
    for (col0, 0..) |*value, i| value.* = M31.fromCanonical(@intCast(i + 3));

    const col1_log_size: u32 = 4;
    const col1 = try alloc.alloc(M31, @as(usize, 1) << @intCast(col1_log_size));
    defer alloc.free(col1);
    for (col1, 0..) |*value, i| value.* = M31.fromCanonical(@intCast(101 + i));

    const col2 = try alloc.alloc(M31, domain_size);
    defer alloc.free(col2);
    for (col2, 0..) |*value, i| value.* = M31.fromCanonical(@intCast(205 + i));

    const tree_columns = try alloc.dupe(ColumnEvaluation, &[_]ColumnEvaluation{
        .{ .log_size = lifting_log_size, .values = col0 },
        .{ .log_size = col1_log_size, .values = col1 },
        .{ .log_size = lifting_log_size, .values = col2 },
    });
    var columns = TreeVec([]ColumnEvaluation).initOwned(
        try alloc.dupe([]ColumnEvaluation, &[_][]ColumnEvaluation{tree_columns}),
    );
    defer columns.deinitDeep(alloc);
    var columns_borrowed = try borrowColumnsForTest(alloc, columns);
    defer columns_borrowed.deinit(alloc);

    const point0 = @import("../../core/circle.zig").SECURE_FIELD_CIRCLE_GEN.mul(7);
    const point1 = @import("../../core/circle.zig").SECURE_FIELD_CIRCLE_GEN.mul(13);

    const col0_samples = try alloc.dupe(PointSample, &[_]PointSample{
        .{ .point = point0, .value = QM31.fromU32Unchecked(1, 2, 3, 4) },
    });
    const col1_samples = try alloc.dupe(PointSample, &[_]PointSample{
        .{ .point = point0, .value = QM31.fromU32Unchecked(5, 6, 7, 8) },
        .{ .point = point1, .value = QM31.fromU32Unchecked(9, 10, 11, 12) },
    });
    const col2_samples = try alloc.alloc(PointSample, 0);
    const tree_samples = try alloc.dupe([]PointSample, &[_][]PointSample{
        col0_samples,
        col1_samples,
        col2_samples,
    });
    var samples = TreeVec([][]PointSample).initOwned(
        try alloc.dupe([][]PointSample, &[_][][]PointSample{tree_samples}),
    );
    defer samples.deinitDeep(alloc);
    var split_samples = try splitPointSamplesForTest(alloc, samples);
    defer split_samples.deinit(alloc);

    const alpha = QM31.fromU32Unchecked(3, 0, 1, 0);

    // Compute via existing materialized path.
    var materialized = try computeFriQuotientsWithStrategy(
        alloc,
        columns_borrowed,
        split_samples.points,
        split_samples.values,
        alpha,
        lifting_log_size,
        .materialized,
    );
    defer materialized.deinit(alloc);

    // Compute via lazy provider, chunk by chunk.
    var provider = try LazyQuotientProvider.init(
        alloc,
        columns_borrowed,
        split_samples.points,
        split_samples.values,
        alpha,
        lifting_log_size,
    );
    defer provider.deinit(alloc);

    var lazy_column = try SecureColumnByCoords.uninitialized(alloc, domain_size);
    defer lazy_column.deinit(alloc);

    var chunk_start: usize = 0;
    const chunk_size: usize = 16; // use small chunks in test to exercise boundary logic
    while (chunk_start < domain_size) {
        const this_chunk = @min(chunk_size, domain_size - chunk_start);
        var chunk_coords: [qm31.SECURE_EXTENSION_DEGREE][]M31 = undefined;
        inline for (0..qm31.SECURE_EXTENSION_DEGREE) |coord| {
            chunk_coords[coord] = lazy_column.columns[coord][chunk_start..][0..this_chunk];
        }
        try provider.computeChunk(chunk_start, this_chunk, &chunk_coords);
        chunk_start += this_chunk;
    }

    // Verify bit-identical output.
    for (0..domain_size) |i| {
        const mat_val = materialized.at(i);
        const lazy_val = lazy_column.at(i);
        try std.testing.expect(mat_val.eql(lazy_val));
    }
}
