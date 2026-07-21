//! Bounded CPU execution for direct contribution-to-quotient row tiles.

const std = @import("std");
const circle = @import("stwo_core").circle;
const cm31 = @import("stwo_core").fields.cm31;
const m31 = @import("stwo_core").fields.m31;
const qm31 = @import("stwo_core").fields.qm31;
const quotients = @import("stwo_core").pcs.quotients;
const core_utils = @import("stwo_core").utils;
const row_executor = @import("quotient_row_executor.zig");
const tile_sink = @import("quotient_tile_sink.zig");
const work_pool_mod = @import("../work_pool.zig");

const CircleDomain = @import("stwo_core").poly.circle.domain.CircleDomain;
const CirclePointM31 = circle.CirclePointM31;
const CM31 = cm31.CM31;
const M31 = m31.M31;
const QM31 = qm31.QM31;

pub const MAX_SCRATCH_BYTES_PER_WORKER: usize = 8 * 1024 * 1024;
const MIN_POSITIONS_PER_WORKER: usize = 256;

pub inline fn shouldUseBoundedInput(lifting_log_size: u32) bool {
    return lifting_log_size >= 13;
}

pub const DirectContributionPlan = struct {
    views: []row_executor.LiftingColumnView,
    ranges: []row_executor.ColumnContributionRange,

    pub fn deinit(self: *DirectContributionPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.views);
        allocator.free(self.ranges);
        self.* = undefined;
    }
};

pub fn buildDirectContributionPlan(
    allocator: std.mem.Allocator,
    flat_columns: anytype,
    active_column_indices: []const usize,
    contribution_ranges: []const row_executor.ColumnContributionRange,
    nonzero_columns: []const bool,
    lifting_log_size: u32,
) !DirectContributionPlan {
    if (active_column_indices.len != contribution_ranges.len or
        flat_columns.len != nonzero_columns.len)
    {
        return error.ShapeMismatch;
    }

    var nonzero_count: usize = 0;
    for (active_column_indices) |column_index| {
        if (column_index >= flat_columns.len) return error.ShapeMismatch;
        if (nonzero_columns[column_index]) nonzero_count += 1;
    }
    const views = try allocator.alloc(row_executor.LiftingColumnView, nonzero_count);
    errdefer allocator.free(views);
    const ranges = try allocator.alloc(row_executor.ColumnContributionRange, nonzero_count);
    errdefer allocator.free(ranges);

    var write_index: usize = 0;
    for (active_column_indices, contribution_ranges) |column_index, contribution_range| {
        if (!nonzero_columns[column_index]) continue;
        const column = flat_columns[column_index];
        if (column.log_size > lifting_log_size) return error.InvalidColumnLogSize;
        const log_shift = lifting_log_size - column.log_size;
        if (log_shift >= @bitSizeOf(usize)) return error.InvalidColumnLogSize;
        views[write_index] = .{
            .values = column.values,
            .shift_amt = @intCast(log_shift + 1),
            .is_direct = column.log_size == lifting_log_size,
        };
        ranges[write_index] = contribution_range;
        write_index += 1;
    }
    std.debug.assert(write_index == nonzero_count);
    return .{ .views = views, .ranges = ranges };
}

pub const Scratch = struct {
    row_scratch: row_executor.Scratch,
    numerators: []M31,
    batch_count: usize,
    row_capacity: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        batch_count: usize,
        requested_rows: usize,
    ) !Scratch {
        const capacity = try rowCapacity(batch_count, requested_rows);
        var row_scratch = try row_executor.Scratch.init(allocator, batch_count, capacity);
        errdefer row_scratch.deinit(allocator);
        const plane_count = std.math.mul(
            usize,
            batch_count,
            qm31.SECURE_EXTENSION_DEGREE,
        ) catch return error.ScratchSizeOverflow;
        const numerator_count = std.math.mul(usize, plane_count, capacity) catch
            return error.ScratchSizeOverflow;
        const numerators = try allocator.alloc(M31, numerator_count);
        return .{
            .row_scratch = row_scratch,
            .numerators = numerators,
            .batch_count = batch_count,
            .row_capacity = capacity,
        };
    }

    pub fn deinit(self: *Scratch, allocator: std.mem.Allocator) void {
        self.row_scratch.deinit(allocator);
        allocator.free(self.numerators);
        self.* = undefined;
    }

    pub fn retainedBytes(self: Scratch) usize {
        return self.row_scratch.retainedBytes() + self.numerators.len * @sizeOf(M31);
    }

    pub fn numeratorBytes(self: Scratch) usize {
        return self.numerators.len * @sizeOf(M31);
    }

    fn clearNumerators(self: *Scratch, row_count: usize) !void {
        if (row_count == 0 or row_count > self.row_capacity) return error.InvalidChunkSize;
        if (row_count == self.row_capacity) {
            @memset(self.numerators, M31.zero());
            return;
        }
        for (0..self.batch_count * qm31.SECURE_EXTENSION_DEGREE) |plane| {
            const start = plane * self.row_capacity;
            @memset(self.numerators[start..][0..row_count], M31.zero());
        }
    }

    fn numerator(self: *Scratch, batch: usize, coordinate: usize, row: usize) *M31 {
        std.debug.assert(batch < self.batch_count);
        std.debug.assert(coordinate < qm31.SECURE_EXTENSION_DEGREE);
        std.debug.assert(row < self.row_capacity);
        const plane = batch * qm31.SECURE_EXTENSION_DEGREE + coordinate;
        return &self.numerators[plane * self.row_capacity + row];
    }
};

pub fn initScratchOrScalarFallback(
    allocator: std.mem.Allocator,
    batch_count: usize,
    requested_rows: usize,
    total_rows: usize,
) !?Scratch {
    if (!row_executor.shouldBatchDomain(total_rows)) return null;
    return Scratch.init(allocator, batch_count, requested_rows) catch |err| switch (err) {
        error.ScratchMemoryLimitExceeded => null,
        else => return err,
    };
}

pub fn initParallelScratch(
    allocator: std.mem.Allocator,
    batch_count: usize,
    requested_rows: usize,
    total_rows: usize,
) !Scratch {
    if (!row_executor.shouldBatchDomain(total_rows)) return error.ParallelUnavailable;
    return Scratch.init(allocator, batch_count, requested_rows) catch |err| switch (err) {
        error.ScratchMemoryLimitExceeded => return error.ParallelUnavailable,
        else => return err,
    };
}

fn rowCapacity(batch_count: usize, requested_rows: usize) !usize {
    if (batch_count == 0 or requested_rows == 0) return error.InvalidChunkSize;
    const denominator_bytes = std.math.mul(usize, batch_count, 2 * @sizeOf(CM31)) catch
        return error.ScratchSizeOverflow;
    const numerator_bytes = std.math.mul(
        usize,
        batch_count,
        qm31.SECURE_EXTENSION_DEGREE * @sizeOf(M31),
    ) catch return error.ScratchSizeOverflow;
    const bytes_per_row = std.math.add(
        usize,
        @sizeOf(CirclePointM31),
        std.math.add(usize, denominator_bytes, numerator_bytes) catch
            return error.ScratchSizeOverflow,
    ) catch return error.ScratchSizeOverflow;
    if (bytes_per_row > MAX_SCRATCH_BYTES_PER_WORKER) {
        return error.ScratchMemoryLimitExceeded;
    }
    return @min(
        @min(requested_rows, tile_sink.DEFAULT_TILE_ROWS),
        MAX_SCRATCH_BYTES_PER_WORKER / bytes_per_row,
    );
}

pub const Work = struct {
    out_columns: [qm31.SECURE_EXTENSION_DEGREE][]M31,
    start: usize,
    end: usize,
    output_start: usize = 0,
    workspace: *quotients.RowQuotientWorkspace,
    scratch: ?*Scratch,
    domain: CircleDomain,
    column_views: []const row_executor.LiftingColumnView,
    contribution_ranges: []const row_executor.ColumnContributionRange,
    contributions: []const row_executor.ColumnContribution,
    quotient_constants: *const quotients.QuotientConstants,
    lifting_log_size: u32,
    tile_writer: ?tile_sink.Writer = null,
    completed_tiles: usize = 0,
    failure: ?anyerror = null,
};

pub fn execute(work: *Work) !void {
    if (work.column_views.len != work.contribution_ranges.len or
        work.output_start > work.start)
    {
        return error.ShapeMismatch;
    }
    const output_end = work.end - work.output_start;
    for (work.out_columns) |column| {
        if (output_end > column.len) return error.ShapeMismatch;
    }
    if (work.scratch) |scratch| return executeBatched(work, scratch);
    return executeScalar(work);
}

fn executeBatched(work: *Work, scratch: *Scratch) !void {
    const point_materializer = try row_executor.BitReversedDomainPointMaterializer.init(
        work.domain,
        work.lifting_log_size,
    );
    var tile_start = work.start;
    while (tile_start < work.end) {
        const row_count = @min(scratch.row_capacity, work.end - tile_start);
        try point_materializer.fill(
            scratch.row_scratch.domain_points[0..row_count],
            tile_start,
        );
        try scratch.row_scratch.prepare(work.workspace, row_count);
        try scratch.clearNumerators(row_count);
        accumulateTile(work, scratch, tile_start, row_count);

        for (0..row_count) |row| {
            for (0..scratch.batch_count) |batch| {
                work.workspace.batch_numerators[batch] = QM31.fromM31(
                    scratch.numerator(batch, 0, row).*,
                    scratch.numerator(batch, 1, row).*,
                    scratch.numerator(batch, 2, row).*,
                    scratch.numerator(batch, 3, row).*,
                );
            }
            try writeRow(
                work,
                tile_start + row,
                scratch.row_scratch.domain_points[row].y,
                try scratch.row_scratch.inversesForRow(row),
            );
        }
        try emitTile(work, tile_start, tile_start + row_count);
        tile_start += row_count;
    }
}

fn accumulateTile(work: *const Work, scratch: *Scratch, start: usize, row_count: usize) void {
    for (work.column_views, work.contribution_ranges) |view, contribution_range| {
        const column_contributions = work.contributions[contribution_range.start..][0..contribution_range.len];
        for (column_contributions) |contribution| {
            const coefficients = contribution.value_coeff.toM31Array();
            if (view.is_direct and m31.PACK_WIDTH > 1) {
                accumulateDirectPacked(
                    scratch,
                    view.values[start..][0..row_count],
                    contribution.batch_index,
                    coefficients,
                );
                continue;
            }
            for (0..row_count) |row| {
                const position = start + row;
                const source_index = ((position >> view.shift_amt) << 1) + (position & 1);
                const base = view.values[source_index];
                inline for (0..qm31.SECURE_EXTENSION_DEGREE) |coordinate| {
                    const numerator = scratch.numerator(contribution.batch_index, coordinate, row);
                    numerator.* = numerator.add(base.mul(coefficients[coordinate]));
                }
            }
        }
    }
}

/// Accumulates one direct-column contribution across a tile in native packed
/// row lanes. Contribution order is unchanged for every output cell; only the
/// four independent coordinate planes are traversed separately.
fn accumulateDirectPacked(
    scratch: *Scratch,
    values: []const M31,
    batch: usize,
    coefficients: [qm31.SECURE_EXTENSION_DEGREE]M31,
) void {
    std.debug.assert(values.len <= scratch.row_capacity);
    var coefficient_vectors: [qm31.SECURE_EXTENSION_DEGREE]m31.PackedM31 = undefined;
    var numerator_planes: [qm31.SECURE_EXTENSION_DEGREE][*]M31 = undefined;
    inline for (0..qm31.SECURE_EXTENSION_DEGREE) |coordinate| {
        coefficient_vectors[coordinate] = m31.splatPacked(coefficients[coordinate]);
        const plane = batch * qm31.SECURE_EXTENSION_DEGREE + coordinate;
        numerator_planes[coordinate] = scratch.numerators.ptr + plane * scratch.row_capacity;
    }

    var row: usize = 0;
    while (row + m31.PACK_WIDTH <= values.len) : (row += m31.PACK_WIDTH) {
        const base = m31.loadPacked(values.ptr + row);
        inline for (0..qm31.SECURE_EXTENSION_DEGREE) |coordinate| {
            const numerators = numerator_planes[coordinate] + row;
            const accumulated = m31.loadPacked(numerators);
            m31.storePacked(
                numerators,
                m31.addPacked(accumulated, m31.mulPacked(base, coefficient_vectors[coordinate])),
            );
        }
    }
    while (row < values.len) : (row += 1) {
        const base = values[row];
        inline for (0..qm31.SECURE_EXTENSION_DEGREE) |coordinate| {
            const numerator = numerator_planes[coordinate] + row;
            numerator[0] = numerator[0].add(base.mul(coefficients[coordinate]));
        }
    }
}

fn executeScalar(work: *Work) !void {
    var tile_start = work.start;
    while (tile_start < work.end) {
        const tile_end = @min(work.end, tile_start + tile_sink.DEFAULT_TILE_ROWS);
        for (tile_start..tile_end) |position| {
            const domain_point = work.domain.at(core_utils.bitReverseIndex(
                position,
                work.lifting_log_size,
            ));
            try work.workspace.beginRow(domain_point);
            for (work.column_views, work.contribution_ranges) |view, contribution_range| {
                const source_index = if (view.is_direct)
                    position
                else
                    ((position >> view.shift_amt) << 1) + (position & 1);
                const base = view.values[source_index];
                for (work.contributions[contribution_range.start..][0..contribution_range.len]) |contribution| {
                    work.workspace.batch_numerators[contribution.batch_index] =
                        work.workspace.batch_numerators[contribution.batch_index].add(
                            contribution.value_coeff.mulM31(base),
                        );
                }
            }
            try writeRow(work, position, domain_point.y, work.workspace.denominator_inverses);
        }
        try emitTile(work, tile_start, tile_end);
        tile_start = tile_end;
    }
}

fn writeRow(work: *Work, position: usize, domain_y: M31, inverses: []const CM31) !void {
    const quotient = try quotients.finalizeRowQuotients(
        work.quotient_constants,
        domain_y,
        work.workspace.batch_numerators,
        inverses,
    );
    const coordinates = quotient.toM31Array();
    inline for (0..qm31.SECURE_EXTENSION_DEGREE) |coordinate| {
        work.out_columns[coordinate][position - work.output_start] = coordinates[coordinate];
    }
}

fn emitTile(work: *Work, start: usize, end: usize) !void {
    const writer = work.tile_writer orelse return;
    const local_start = start - work.output_start;
    const local_end = end - work.output_start;
    var coordinates: [qm31.SECURE_EXTENSION_DEGREE][]const M31 = undefined;
    inline for (0..qm31.SECURE_EXTENSION_DEGREE) |coordinate| {
        coordinates[coordinate] = work.out_columns[coordinate][local_start..local_end];
    }
    try writer.absorb(.{ .start = start, .coordinates = coordinates });
    work.completed_tiles += 1;
}

pub fn worker(work: *Work) void {
    execute(work) catch |err| {
        work.failure = err;
    };
}

pub const ParallelRequest = struct {
    out_columns: [qm31.SECURE_EXTENSION_DEGREE][]M31,
    domain_size: usize,
    sample_batches: []const quotients.ColumnSampleBatch,
    use_batched_inversion: bool,
    allow_parallel_scalar: bool,
    domain: CircleDomain,
    column_views: []const row_executor.LiftingColumnView,
    contribution_ranges: []const row_executor.ColumnContributionRange,
    contributions: []const row_executor.ColumnContribution,
    quotient_constants: *const quotients.QuotientConstants,
    lifting_log_size: u32,
    factory: ?tile_sink.Factory,
};

pub fn executeParallel(
    allocator: std.mem.Allocator,
    request: ParallelRequest,
) !?tile_sink.ExecutionStats {
    if (!request.use_batched_inversion and !request.allow_parallel_scalar) return null;
    const pool = work_pool_mod.getGlobalPool() orelse return null;
    const worker_count = @min(
        pool.workerCount(),
        request.domain_size / MIN_POSITIONS_PER_WORKER,
    );
    if (worker_count <= 1) return null;

    const workspaces = try allocator.alloc(quotients.RowQuotientWorkspace, worker_count);
    defer allocator.free(workspaces);
    var initialized_workspaces: usize = 0;
    defer for (workspaces[0..initialized_workspaces]) |*workspace| workspace.deinit(allocator);
    for (workspaces) |*workspace| {
        workspace.* = try quotients.RowQuotientWorkspace.init(
            allocator,
            request.sample_batches,
        );
        initialized_workspaces += 1;
    }

    const worker_span = try row_executor.workerSpan(request.domain_size, worker_count);
    var scratches: ?[]Scratch = null;
    var initialized_scratches: usize = 0;
    defer if (scratches) |values| {
        for (values[0..initialized_scratches]) |*scratch| scratch.deinit(allocator);
        allocator.free(values);
    };
    if (request.use_batched_inversion) {
        scratches = try allocator.alloc(Scratch, worker_count);
        for (scratches.?) |*scratch| {
            scratch.* = initParallelScratch(
                allocator,
                request.sample_batches.len,
                @min(worker_span, tile_sink.DEFAULT_TILE_ROWS),
                request.domain_size,
            ) catch |err| switch (err) {
                error.ParallelUnavailable => return null,
                else => return err,
            };
            initialized_scratches += 1;
        }
    }

    var work_items: [work_pool_mod.MAX_WORKERS]Work = undefined;
    for (0..worker_count) |worker_index| {
        const range = try row_executor.workerRange(
            request.domain_size,
            worker_span,
            worker_index,
        );
        const writer = if (request.factory) |factory|
            try factory.prepareWriter(worker_index, .{ .start = range.start, .end = range.end })
        else
            null;
        work_items[worker_index] = .{
            .out_columns = request.out_columns,
            .start = range.start,
            .end = range.end,
            .workspace = &workspaces[worker_index],
            .scratch = if (scratches) |values| &values[worker_index] else null,
            .domain = request.domain,
            .column_views = request.column_views,
            .contribution_ranges = request.contribution_ranges,
            .contributions = request.contributions,
            .quotient_constants = request.quotient_constants,
            .lifting_log_size = request.lifting_log_size,
            .tile_writer = writer,
        };
    }

    var wait_group: std.Thread.WaitGroup = .{};
    for (work_items[1..worker_count]) |*work| {
        pool.spawnWg(&wait_group, worker, .{work});
    }
    worker(&work_items[0]);
    wait_group.wait();
    for (work_items[0..worker_count]) |work| {
        if (work.failure) |err| return err;
    }
    if (request.factory) |factory| try factory.finishWriters(worker_count);

    var tile_count: usize = 0;
    for (work_items[0..worker_count]) |work| tile_count += work.completed_tiles;
    var total_scratch_bytes: usize = 0;
    var peak_scratch_bytes: usize = 0;
    var peak_numerator_bytes: usize = 0;
    if (scratches) |values| {
        for (values) |scratch| {
            const retained = scratch.retainedBytes();
            total_scratch_bytes = std.math.add(usize, total_scratch_bytes, retained) catch
                return error.ScratchSizeOverflow;
            peak_scratch_bytes = @max(peak_scratch_bytes, retained);
            peak_numerator_bytes = @max(peak_numerator_bytes, scratch.numeratorBytes());
        }
    }
    return .{
        .tile_pipeline_selected = request.factory != null,
        .worker_count = worker_count,
        .tile_row_limit = tile_sink.DEFAULT_TILE_ROWS,
        .tile_count = tile_count,
        .peak_scratch_bytes_per_worker = peak_scratch_bytes,
        .total_scratch_bytes = total_scratch_bytes,
        .bounded_numerator_tile_bytes_per_worker = peak_numerator_bytes,
        .complete_column_combined_intermediate_bytes = 0,
        .post_compute_leaf_pass_count = if (request.factory == null) 1 else 0,
    };
}

test "quotient tile scratch is bounded and rejects overflowing geometry" {
    var scratch = try Scratch.init(std.testing.allocator, 3, tile_sink.DEFAULT_TILE_ROWS);
    defer scratch.deinit(std.testing.allocator);
    try std.testing.expect(scratch.row_capacity <= tile_sink.DEFAULT_TILE_ROWS);
    try std.testing.expect(scratch.retainedBytes() <= MAX_SCRATCH_BYTES_PER_WORKER);
    try std.testing.expect(scratch.numeratorBytes() > 0);
    try std.testing.expectError(
        error.ScratchMemoryLimitExceeded,
        rowCapacity(MAX_SCRATCH_BYTES_PER_WORKER, 1),
    );
    try std.testing.expectError(
        error.ScratchSizeOverflow,
        rowCapacity(std.math.maxInt(usize), 1),
    );
}

test "quotient tile input policy selects only the measured batched domain" {
    try std.testing.expect(!shouldUseBoundedInput(12));
    try std.testing.expect(shouldUseBoundedInput(13));
    try std.testing.expect(shouldUseBoundedInput(14));
}
