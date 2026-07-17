const std = @import("std");
const builtin = @import("builtin");
const m31 = @import("../../core/fields/m31.zig");
const qm31 = @import("../../core/fields/qm31.zig");
const quotients = @import("../../core/pcs/quotients.zig");
const pcs_utils = @import("../../core/pcs/utils.zig");
const canonic = @import("../../core/poly/circle/canonic.zig");
const column_geometry = @import("quotient_column_geometry.zig");
const execution = @import("quotients/execution.zig");
const planning = @import("quotients/planning.zig");
const row_executor = @import("quotient_row_executor.zig");
const tile_executor = @import("quotient_tile_executor.zig");
const tile_sink = @import("quotient_tile_sink.zig");
const secure_column = @import("../secure_column.zig");
const work_pool_mod = @import("../work_pool.zig");

const circle_mod = @import("../../core/circle.zig");
const circle_domain = @import("../../core/poly/circle/domain.zig");
const CirclePointQM31 = circle_mod.CirclePointQM31;
const M31 = m31.M31;
const QM31 = qm31.QM31;
const TreeVec = pcs_utils.TreeVec;
const PointSample = quotients.PointSample;
const SecureColumnByCoords = secure_column.SecureColumnByCoords;
/// Minimum number of domain positions per worker thread to amortize overhead.
const MIN_POSITIONS_PER_WORKER = execution.min_positions_per_worker;
/// Number of rows processed per chunk in lazy quotient evaluation.
/// Chosen to amortize function-call overhead while keeping chunk memory bounded.
pub const LAZY_QUOTIENT_CHUNK_SIZE: usize = 1024;

pub const QuotientOpsError = column_geometry.QuotientOpsError;

/// One committed trace/evaluation column.
///
/// Invariants:
/// - `values.len == 2^log_size`.
/// - `values` are in bit-reversed order, matching Stwo prover conventions.
pub const ColumnEvaluation = column_geometry.ColumnEvaluation;

const CombinedContributionView = row_executor.CombinedContributionView;

pub const InputMode = enum {
    bounded_cpu,
    combined_compatibility,
    raw_backend,
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
    prepared: planning.PreparedContext,
    input_mode: InputMode,
    combined_views: []CombinedContributionView,
    direct_plan: tile_executor.DirectContributionPlan,
    raw_columns: []ColumnEvaluation,
    workspace: quotients.RowQuotientWorkspace,
    chunk_scratch: ?row_executor.Scratch,
    direct_chunk_scratch: ?tile_executor.Scratch,
    allow_parallel_scalar: bool,
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
        return initWithMode(
            allocator,
            columns,
            sampled_points,
            sampled_values,
            random_coeff,
            lifting_log_size,
            if (tile_executor.shouldUseBoundedInput(lifting_log_size))
                .bounded_cpu
            else
                .combined_compatibility,
        );
    }

    pub fn initWithMode(
        allocator: std.mem.Allocator,
        columns: TreeVec([]const ColumnEvaluation),
        sampled_points: TreeVec([][]CirclePointQM31),
        sampled_values: TreeVec([][]QM31),
        random_coeff: QM31,
        lifting_log_size: u32,
        input_mode: InputMode,
    ) !LazyQuotientProvider {
        return initForBackendWithMode(
            void,
            allocator,
            columns,
            sampled_points,
            sampled_values,
            random_coeff,
            lifting_log_size,
            input_mode,
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
        const backend_raw = comptime B != void and @hasDecl(B, "rawQuotientInputs") and B.rawQuotientInputs;
        return initForBackendWithMode(
            B,
            allocator,
            columns,
            sampled_points,
            sampled_values,
            random_coeff,
            lifting_log_size,
            if (backend_raw)
                .raw_backend
            else if (tile_executor.shouldUseBoundedInput(lifting_log_size))
                .bounded_cpu
            else
                .combined_compatibility,
        );
    }

    pub fn initForBackendWithMode(
        comptime B: type,
        allocator: std.mem.Allocator,
        columns: TreeVec([]const ColumnEvaluation),
        sampled_points: TreeVec([][]CirclePointQM31),
        sampled_values: TreeVec([][]QM31),
        random_coeff: QM31,
        lifting_log_size: u32,
        input_mode: InputMode,
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

        var column_log_sizes = try column_geometry.buildColumnLogSizes(allocator, columns);
        defer column_log_sizes.deinitDeep(allocator);

        const domain_size = try column_geometry.checkedPow2(lifting_log_size);
        const flat_columns = try column_geometry.flattenColumnsBorrowed(allocator, columns);
        errdefer allocator.free(flat_columns);

        var prepared = try planning.prepareContext(
            allocator,
            column_log_sizes,
            sampled_points,
            sampled_values,
            random_coeff,
            lifting_log_size,
            flat_columns.len,
        );
        errdefer prepared.deinit(allocator);

        const nonzero_columns = try planning.markNonzeroColumnsAndSamples(
            allocator,
            columns,
            sampled_values,
        );
        defer allocator.free(nonzero_columns);

        const backend_raw = comptime B != void and @hasDecl(B, "rawQuotientInputs") and B.rawQuotientInputs;
        if ((input_mode == .raw_backend) != backend_raw) return error.InvalidQuotientInputMode;
        var combined_views: []CombinedContributionView = &.{};
        var direct_plan = tile_executor.DirectContributionPlan{ .views = &.{}, .ranges = &.{} };
        switch (input_mode) {
            .combined_compatibility => {
                const combined_plan = try planning.buildCombinedContributionPlan(
                    allocator,
                    flat_columns,
                    prepared.contribution_plan.active_column_indices,
                    prepared.contribution_plan.ranges,
                    prepared.contribution_plan.contributions,
                    nonzero_columns,
                    lifting_log_size,
                );
                combined_views = combined_plan.views;
            },
            .bounded_cpu => direct_plan = try tile_executor.buildDirectContributionPlan(
                allocator,
                flat_columns,
                prepared.contribution_plan.active_column_indices,
                prepared.contribution_plan.ranges,
                nonzero_columns,
                lifting_log_size,
            ),
            .raw_backend => {},
        }
        errdefer {
            var combined_plan = planning.CombinedContributionPlan{ .views = combined_views };
            combined_plan.deinit(allocator);
            direct_plan.deinit(allocator);
        }

        var workspace = try quotients.RowQuotientWorkspace.init(allocator, prepared.sample_batches);
        errdefer workspace.deinit(allocator);
        var chunk_scratch: ?row_executor.Scratch = null;
        if (input_mode == .combined_compatibility) {
            chunk_scratch = try row_executor.initScratchOrScalarFallback(
                allocator,
                prepared.sample_batches.len,
                LAZY_QUOTIENT_CHUNK_SIZE,
                domain_size,
            );
        }
        errdefer if (chunk_scratch) |*scratch| scratch.deinit(allocator);
        var direct_chunk_scratch: ?tile_executor.Scratch = null;
        if (input_mode == .bounded_cpu) {
            direct_chunk_scratch = try tile_executor.initScratchOrScalarFallback(
                allocator,
                prepared.sample_batches.len,
                tile_sink.DEFAULT_TILE_ROWS,
                domain_size,
            );
        }
        errdefer if (direct_chunk_scratch) |*scratch| scratch.deinit(allocator);

        const domain = canonic.CanonicCoset.new(lifting_log_size).circleDomain();

        return .{
            .prepared = prepared,
            .input_mode = input_mode,
            .combined_views = combined_views,
            .direct_plan = direct_plan,
            .raw_columns = if (input_mode == .raw_backend) flat_columns else blk: {
                allocator.free(flat_columns);
                break :blk &.{};
            },
            .workspace = workspace,
            .chunk_scratch = chunk_scratch,
            .direct_chunk_scratch = direct_chunk_scratch,
            .allow_parallel_scalar = input_mode != .raw_backend and !row_executor.shouldBatchDomain(domain_size),
            .domain = domain,
            .lifting_log_size = lifting_log_size,
            .domain_size = domain_size,
        };
    }

    pub fn deinit(self: *LazyQuotientProvider, allocator: std.mem.Allocator) void {
        if (self.direct_chunk_scratch) |*scratch| scratch.deinit(allocator);
        if (self.chunk_scratch) |*scratch| scratch.deinit(allocator);
        self.workspace.deinit(allocator);
        var combined_plan = planning.CombinedContributionPlan{ .views = self.combined_views };
        combined_plan.deinit(allocator);
        self.direct_plan.deinit(allocator);
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
        const chunk_end = std.math.add(usize, chunk_start, chunk_len) catch
            return QuotientOpsError.ShapeMismatch;
        if (chunk_end > self.domain_size) return QuotientOpsError.ShapeMismatch;
        for (out_coords) |coord_buf| {
            if (coord_buf.len < chunk_len) return QuotientOpsError.ShapeMismatch;
        }

        switch (self.input_mode) {
            .bounded_cpu => {
                var work = tile_executor.Work{
                    .out_columns = out_coords.*,
                    .start = chunk_start,
                    .end = chunk_end,
                    .output_start = chunk_start,
                    .workspace = &self.workspace,
                    .scratch = if (self.direct_chunk_scratch) |*scratch| scratch else null,
                    .domain = self.domain,
                    .column_views = self.direct_plan.views,
                    .contribution_ranges = self.direct_plan.ranges,
                    .contributions = self.prepared.contribution_plan.contributions,
                    .quotient_constants = &self.prepared.quotient_constants,
                    .lifting_log_size = self.lifting_log_size,
                };
                try tile_executor.execute(&work);
            },
            .combined_compatibility => {
                var work = row_executor.StreamingWork{
                    .out_columns = out_coords.*,
                    .start = chunk_start,
                    .end = chunk_end,
                    .output_start = chunk_start,
                    .workspace = &self.workspace,
                    .scratch = if (self.chunk_scratch) |*scratch| scratch else null,
                    .domain = self.domain,
                    .combined_views = self.combined_views,
                    .quotient_constants = &self.prepared.quotient_constants,
                    .lifting_log_size = self.lifting_log_size,
                };
                try row_executor.executeStreaming(&work);
            },
            .raw_backend => return error.UnsupportedQuotientInputMode,
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
            if (try self.computeAllParallel(allocator, out, null) != null) return;
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

    /// Computes the retained quotient column and emits each completed row tile
    /// to a worker-local sink before its output cache lines are reused.
    pub fn computeAllWithTileSink(
        self: *LazyQuotientProvider,
        allocator: std.mem.Allocator,
        out: *SecureColumnByCoords,
        factory: tile_sink.Factory,
    ) !tile_sink.ExecutionStats {
        if (out.len() != self.domain_size) return QuotientOpsError.ShapeMismatch;

        if (!builtin.single_threaded) {
            if (try self.computeAllParallel(allocator, out, factory)) |stats| return stats;
        }

        const writer = try factory.prepareWriter(0, .{ .start = 0, .end = self.domain_size });
        var tile_count: usize = 0;
        switch (self.input_mode) {
            .bounded_cpu => {
                var work = tile_executor.Work{
                    .out_columns = out.columns,
                    .start = 0,
                    .end = self.domain_size,
                    .workspace = &self.workspace,
                    .scratch = if (self.direct_chunk_scratch) |*scratch| scratch else null,
                    .domain = self.domain,
                    .column_views = self.direct_plan.views,
                    .contribution_ranges = self.direct_plan.ranges,
                    .contributions = self.prepared.contribution_plan.contributions,
                    .quotient_constants = &self.prepared.quotient_constants,
                    .lifting_log_size = self.lifting_log_size,
                    .tile_writer = writer,
                };
                try tile_executor.execute(&work);
                tile_count = work.completed_tiles;
            },
            .combined_compatibility => {
                var work = row_executor.StreamingWork{
                    .out_columns = out.columns,
                    .start = 0,
                    .end = self.domain_size,
                    .workspace = &self.workspace,
                    .scratch = if (self.chunk_scratch) |*scratch| scratch else null,
                    .domain = self.domain,
                    .combined_views = self.combined_views,
                    .quotient_constants = &self.prepared.quotient_constants,
                    .lifting_log_size = self.lifting_log_size,
                    .tile_writer = writer,
                };
                try row_executor.executeStreaming(&work);
                tile_count = work.completed_tiles;
            },
            .raw_backend => return error.UnsupportedQuotientInputMode,
        }
        try factory.finishWriters(1);
        const scratch_bytes = switch (self.input_mode) {
            .bounded_cpu => if (self.direct_chunk_scratch) |scratch| scratch.retainedBytes() else 0,
            .combined_compatibility => if (self.chunk_scratch) |scratch| scratch.retainedBytes() else 0,
            .raw_backend => 0,
        };
        return .{
            .tile_pipeline_selected = true,
            .worker_count = 1,
            .tile_row_limit = tile_sink.DEFAULT_TILE_ROWS,
            .tile_count = tile_count,
            .peak_scratch_bytes_per_worker = scratch_bytes,
            .total_scratch_bytes = scratch_bytes,
            .bounded_numerator_tile_bytes_per_worker = if (self.direct_chunk_scratch) |scratch|
                scratch.numeratorBytes()
            else
                0,
            .complete_column_combined_intermediate_bytes = try self.combinedIntermediateBytes(),
            .post_compute_leaf_pass_count = 0,
        };
    }

    pub fn combinedIntermediateBytes(self: *const LazyQuotientProvider) !usize {
        var bytes: usize = 0;
        for (self.combined_views) |view| {
            for (view.coordinates) |coordinate| {
                const coordinate_bytes = std.math.mul(usize, coordinate.len, @sizeOf(M31)) catch
                    return error.ScratchSizeOverflow;
                bytes = std.math.add(usize, bytes, coordinate_bytes) catch
                    return error.ScratchSizeOverflow;
            }
        }
        return bytes;
    }

    fn computeAllParallel(
        self: *const LazyQuotientProvider,
        allocator: std.mem.Allocator,
        out: *SecureColumnByCoords,
        factory: ?tile_sink.Factory,
    ) !?tile_sink.ExecutionStats {
        switch (self.input_mode) {
            .bounded_cpu => return self.computeAllParallelDirect(allocator, out, factory),
            .combined_compatibility => {},
            .raw_backend => return null,
        }
        const use_batched_inversion = self.chunk_scratch != null;
        if (!use_batched_inversion and !self.allow_parallel_scalar) return null;
        const pool = work_pool_mod.getGlobalPool() orelse return null;
        const n_workers = @min(pool.workerCount(), self.domain_size / MIN_POSITIONS_PER_WORKER);
        if (n_workers <= 1) return null;

        const workspaces = try allocator.alloc(quotients.RowQuotientWorkspace, n_workers);
        defer allocator.free(workspaces);
        var initialized: usize = 0;
        defer for (workspaces[0..initialized]) |*workspace| workspace.deinit(allocator);
        for (workspaces) |*workspace| {
            workspace.* = try quotients.RowQuotientWorkspace.init(allocator, self.prepared.sample_batches);
            initialized += 1;
        }

        const worker_span = try row_executor.workerSpan(self.domain_size, n_workers);
        var scratches: ?[]row_executor.Scratch = null;
        var scratch_initialized: usize = 0;
        defer if (scratches) |values| {
            for (values[0..scratch_initialized]) |*scratch| scratch.deinit(allocator);
            allocator.free(values);
        };
        if (use_batched_inversion) {
            scratches = try allocator.alloc(row_executor.Scratch, n_workers);
            for (scratches.?) |*scratch| {
                scratch.* = row_executor.initParallelScratch(
                    allocator,
                    self.prepared.sample_batches.len,
                    @min(worker_span, row_executor.MAX_ROWS),
                    self.domain_size,
                ) catch |err| switch (err) {
                    error.ParallelUnavailable => return null,
                    else => return err,
                };
                scratch_initialized += 1;
            }
        }

        var work_items: [work_pool_mod.MAX_WORKERS]row_executor.StreamingWork = undefined;
        for (0..n_workers) |worker| {
            const worker_range = try row_executor.workerRange(self.domain_size, worker_span, worker);
            const writer = if (factory) |active|
                try active.prepareWriter(worker, .{
                    .start = worker_range.start,
                    .end = worker_range.end,
                })
            else
                null;
            work_items[worker] = .{
                .out_columns = out.columns,
                .start = worker_range.start,
                .end = worker_range.end,
                .workspace = &workspaces[worker],
                .scratch = if (scratches) |values| &values[worker] else null,
                .domain = self.domain,
                .combined_views = self.combined_views,
                .quotient_constants = &self.prepared.quotient_constants,
                .lifting_log_size = self.lifting_log_size,
                .tile_writer = writer,
            };
        }

        var wait_group: std.Thread.WaitGroup = .{};
        for (work_items[1..n_workers]) |*item| {
            pool.spawnWg(&wait_group, row_executor.streamingWorker, .{item});
        }
        row_executor.streamingWorker(&work_items[0]);
        wait_group.wait();
        for (work_items[0..n_workers]) |item| {
            if (item.failure) |err| return err;
        }
        if (factory) |active| try active.finishWriters(n_workers);

        var tile_count: usize = 0;
        for (work_items[0..n_workers]) |item| tile_count += item.completed_tiles;
        var total_scratch_bytes: usize = 0;
        var peak_scratch_bytes: usize = 0;
        if (scratches) |values| {
            for (values) |scratch| {
                const retained = scratch.retainedBytes();
                total_scratch_bytes = std.math.add(usize, total_scratch_bytes, retained) catch
                    return error.ScratchSizeOverflow;
                peak_scratch_bytes = @max(peak_scratch_bytes, retained);
            }
        }
        return .{
            .tile_pipeline_selected = factory != null,
            .worker_count = n_workers,
            .tile_row_limit = tile_sink.DEFAULT_TILE_ROWS,
            .tile_count = tile_count,
            .peak_scratch_bytes_per_worker = peak_scratch_bytes,
            .total_scratch_bytes = total_scratch_bytes,
            .bounded_numerator_tile_bytes_per_worker = 0,
            .complete_column_combined_intermediate_bytes = if (factory != null)
                try self.combinedIntermediateBytes()
            else
                0,
            .post_compute_leaf_pass_count = if (factory == null) 1 else 0,
        };
    }

    fn computeAllParallelDirect(
        self: *const LazyQuotientProvider,
        allocator: std.mem.Allocator,
        out: *SecureColumnByCoords,
        factory: ?tile_sink.Factory,
    ) !?tile_sink.ExecutionStats {
        return tile_executor.executeParallel(allocator, .{
            .out_columns = out.columns,
            .domain_size = self.domain_size,
            .sample_batches = self.prepared.sample_batches,
            .use_batched_inversion = self.direct_chunk_scratch != null,
            .allow_parallel_scalar = self.allow_parallel_scalar,
            .domain = self.domain,
            .column_views = self.direct_plan.views,
            .contribution_ranges = self.direct_plan.ranges,
            .contributions = self.prepared.contribution_plan.contributions,
            .quotient_constants = &self.prepared.quotient_constants,
            .lifting_log_size = self.lifting_log_size,
            .factory = factory,
        });
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
    forced_strategy: ?planning.ConstructionStrategy,
) !SecureColumnByCoords {
    return execution.compute(
        allocator,
        columns,
        sampled_points,
        sampled_values,
        random_coeff,
        lifting_log_size,
        forced_strategy,
    );
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

fn checkLazyProviderAllocationFailureCleanup(
    allocator: std.mem.Allocator,
    columns: TreeVec([]const ColumnEvaluation),
    sampled_points: TreeVec([][]CirclePointQM31),
    sampled_values: TreeVec([][]QM31),
) !void {
    var provider = try LazyQuotientProvider.initWithMode(
        allocator,
        columns,
        sampled_points,
        sampled_values,
        QM31.fromU32Unchecked(3, 0, 1, 0),
        13,
        .bounded_cpu,
    );
    defer provider.deinit(allocator);
}

test "prover pcs bounded quotient provider releases partial state on allocation failure" {
    const column_values = [_]M31{M31.one()} ** (1 << 13);
    var tree_columns = [_]ColumnEvaluation{.{
        .log_size = 13,
        .values = column_values[0..],
    }};
    var column_trees = [_][]const ColumnEvaluation{tree_columns[0..]};
    const columns = TreeVec([]const ColumnEvaluation).initOwned(column_trees[0..]);

    var column_points = [_]CirclePointQM31{circle_mod.SECURE_FIELD_CIRCLE_GEN.mul(7)};
    var tree_points = [_][]CirclePointQM31{column_points[0..]};
    var point_trees = [_][][]CirclePointQM31{tree_points[0..]};
    const sampled_points = TreeVec([][]CirclePointQM31).initOwned(point_trees[0..]);

    var column_samples = [_]QM31{QM31.fromU32Unchecked(9, 10, 11, 12)};
    var tree_samples = [_][]QM31{column_samples[0..]};
    var sample_trees = [_][][]QM31{tree_samples[0..]};
    const sampled_values = TreeVec([][]QM31).initOwned(sample_trees[0..]);

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkLazyProviderAllocationFailureCleanup,
        .{ columns, sampled_points, sampled_values },
    );
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
        planning.ConstructionStrategy.materialized,
        planning.chooseConstructionStrategy(256, 2048),
    );
    try std.testing.expectEqual(
        planning.ConstructionStrategy.streaming,
        planning.chooseConstructionStrategy(1500, 4096),
    );
    try std.testing.expectEqual(
        planning.ConstructionStrategy.streaming,
        planning.chooseConstructionStrategy(1400, 8192),
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
