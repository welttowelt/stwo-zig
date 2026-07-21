//! Bounded CPU row execution for FRI quotient construction.

const std = @import("std");
const circle = @import("stwo_core").circle;
const cm31 = @import("stwo_core").fields.cm31;
const m31 = @import("stwo_core").fields.m31;
const qm31 = @import("stwo_core").fields.qm31;
const quotients = @import("stwo_core").pcs.quotients;
const canonic = @import("stwo_core").poly.circle.canonic;
const constraints = @import("stwo_core").constraints;
const core_utils = @import("stwo_core").utils;
const tile_sink = @import("quotient_tile_sink.zig");
const domain_walk = @import("quotient_domain_walk.zig");

const CircleDomain = @import("stwo_core").poly.circle.domain.CircleDomain;
const CirclePointM31 = circle.CirclePointM31;
const CM31 = cm31.CM31;
const M31 = m31.M31;
const QM31 = qm31.QM31;

pub const MAX_ROWS: usize = 1024;
pub const MAX_BYTES_PER_WORKER: usize = 8 * 1024 * 1024;
pub const MIN_BATCHED_DOMAIN_ROWS: usize = 8192;

pub const LiftingColumnView = struct {
    values: []const M31,
    shift_amt: std.math.Log2Int(usize),
    is_direct: bool,
};

pub const CombinedContributionView = struct {
    coordinates: [qm31.SECURE_EXTENSION_DEGREE][]M31,
    batch_index: usize,
    shift_amt: std.math.Log2Int(usize),
    is_direct: bool,
};

pub const ColumnContribution = struct {
    batch_index: usize,
    value_coeff: QM31,
};

pub const ColumnContributionRange = struct {
    start: usize,
    len: usize,
};

pub inline fn shouldBatchDomain(total_rows: usize) bool {
    return total_rows >= MIN_BATCHED_DOMAIN_ROWS;
}

pub const Scratch = struct {
    domain_points: []CirclePointM31,
    denominators: []CM31,
    denominator_inverses: []CM31,
    batch_count: usize,
    prepared_rows: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        batch_count: usize,
        requested_rows: usize,
    ) !Scratch {
        const row_capacity = try rowCapacityForBatchCount(batch_count, requested_rows);
        const cell_count = std.math.mul(usize, row_capacity, batch_count) catch
            return error.ScratchSizeOverflow;

        const domain_points = try allocator.alloc(CirclePointM31, row_capacity);
        errdefer allocator.free(domain_points);
        const denominators = try allocator.alloc(CM31, cell_count);
        errdefer allocator.free(denominators);
        const denominator_inverses = try allocator.alloc(CM31, cell_count);
        errdefer allocator.free(denominator_inverses);

        return .{
            .domain_points = domain_points,
            .denominators = denominators,
            .denominator_inverses = denominator_inverses,
            .batch_count = batch_count,
            .prepared_rows = 0,
        };
    }

    pub fn deinit(self: *Scratch, allocator: std.mem.Allocator) void {
        allocator.free(self.domain_points);
        allocator.free(self.denominators);
        allocator.free(self.denominator_inverses);
        self.* = undefined;
    }

    pub inline fn rowCapacity(self: Scratch) usize {
        return self.domain_points.len;
    }

    pub fn prepare(
        self: *Scratch,
        workspace: *const quotients.RowQuotientWorkspace,
        row_count: usize,
    ) !void {
        if (row_count == 0 or row_count > self.rowCapacity()) return error.InvalidChunkSize;
        if (workspace.batch_numerators.len != self.batch_count) return error.ShapeMismatch;
        self.prepared_rows = 0;
        const cell_count = std.math.mul(usize, row_count, self.batch_count) catch
            return error.ScratchSizeOverflow;
        try workspace.prepareDenominatorInversesForRows(
            self.domain_points[0..row_count],
            self.denominators[0..cell_count],
            self.denominator_inverses[0..cell_count],
        );
        self.prepared_rows = row_count;
    }

    pub fn inversesForRow(self: Scratch, row: usize) ![]const CM31 {
        if (row >= self.prepared_rows) return error.InvalidChunkSize;
        const start = std.math.mul(usize, row, self.batch_count) catch
            return error.ScratchSizeOverflow;
        return self.denominator_inverses[start..][0..self.batch_count];
    }

    pub fn retainedBytes(self: Scratch) usize {
        return self.domain_points.len * @sizeOf(CirclePointM31) +
            self.denominators.len * @sizeOf(CM31) +
            self.denominator_inverses.len * @sizeOf(CM31);
    }
};

pub fn rowCapacityForBatchCount(batch_count: usize, requested_rows: usize) !usize {
    if (requested_rows == 0) return error.InvalidChunkSize;
    const denominator_bytes = std.math.mul(usize, batch_count, 2 * @sizeOf(CM31)) catch
        return error.ScratchSizeOverflow;
    const bytes_per_row = std.math.add(
        usize,
        @sizeOf(CirclePointM31),
        denominator_bytes,
    ) catch return error.ScratchSizeOverflow;
    if (bytes_per_row > MAX_BYTES_PER_WORKER) return error.ScratchMemoryLimitExceeded;

    const bounded_request = @min(requested_rows, MAX_ROWS);
    return @min(bounded_request, MAX_BYTES_PER_WORKER / bytes_per_row);
}

pub fn initScratchOrScalarFallback(
    allocator: std.mem.Allocator,
    batch_count: usize,
    requested_rows: usize,
    total_rows: usize,
) !?Scratch {
    if (!shouldBatchDomain(total_rows)) return null;
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
    if (!shouldBatchDomain(total_rows)) return error.ParallelUnavailable;
    return Scratch.init(allocator, batch_count, requested_rows) catch |err| switch (err) {
        error.ScratchMemoryLimitExceeded => return error.ParallelUnavailable,
        else => return err,
    };
}

pub fn prepareParallelScratchPolicy(
    batch_count: usize,
    requested_rows: usize,
    total_rows: usize,
) !bool {
    if (!shouldBatchDomain(total_rows)) return false;
    _ = rowCapacityForBatchCount(batch_count, requested_rows) catch |err| switch (err) {
        error.ScratchMemoryLimitExceeded => return error.ParallelUnavailable,
        else => return err,
    };
    return true;
}

pub fn workerSpan(domain_size: usize, n_workers: usize) !usize {
    if (n_workers == 0) return error.ParallelUnavailable;
    const rounded = std.math.add(usize, domain_size, n_workers - 1) catch
        return error.ScratchSizeOverflow;
    return rounded / n_workers;
}

pub const WorkerRange = struct {
    start: usize,
    end: usize,
};

pub fn workerRange(domain_size: usize, worker_span: usize, worker: usize) !WorkerRange {
    const start = std.math.mul(usize, worker, worker_span) catch
        return error.ScratchSizeOverflow;
    const unbounded_end = std.math.mul(usize, worker + 1, worker_span) catch
        return error.ScratchSizeOverflow;
    return .{
        .start = @min(domain_size, start),
        .end = @min(domain_size, unbounded_end),
    };
}

pub const MaterializedWork = struct {
    out_columns: [qm31.SECURE_EXTENSION_DEGREE][]M31,
    start: usize,
    end: usize,
    workspace: *quotients.RowQuotientWorkspace,
    scratch: ?*Scratch,
    domain: CircleDomain,
    lifted_columns: []const []M31,
    contribution_plan_ranges: []const ColumnContributionRange,
    contributions: []const ColumnContribution,
    quotient_constants: *const quotients.QuotientConstants,
    lifting_log_size: u32,
    failure: ?anyerror = null,
};

pub fn executeMaterialized(item: *const MaterializedWork) !void {
    const scratch = item.scratch orelse return executeMaterializedScalar(item);
    const workspace = item.workspace;
    var chunk_start = item.start;
    var walk = domain_walk.BitReversedCosetWalk.init(
        item.domain,
        item.lifting_log_size,
        item.start,
    );
    while (chunk_start < item.end) {
        const row_count = @min(scratch.rowCapacity(), item.end - chunk_start);
        for (scratch.domain_points[0..row_count]) |*domain_point| {
            domain_point.* = walk.next();
        }
        try scratch.prepare(workspace, row_count);

        for (0..row_count) |row| {
            const position = chunk_start + row;
            const domain_point = scratch.domain_points[row];
            workspace.resetNumerators();
            for (item.lifted_columns, item.contribution_plan_ranges) |lifted_column, contribution_range| {
                const base_value = lifted_column[position];
                for (item.contributions[contribution_range.start..][0..contribution_range.len]) |contribution| {
                    workspace.batch_numerators[contribution.batch_index] =
                        workspace.batch_numerators[contribution.batch_index].add(
                            contribution.value_coeff.mulM31(base_value),
                        );
                }
            }
            try writeQuotientRow(
                item.out_columns,
                position,
                item.quotient_constants,
                domain_point.y,
                workspace.batch_numerators,
                try scratch.inversesForRow(row),
            );
        }
        chunk_start += row_count;
    }
}

/// Rows per stack-resident inversion chunk in the scalar row paths.
/// 32 rows amortize one Montgomery batch inversion across the chunk
/// (~3 CM31 multiplies per row plus one inversion) instead of one full
/// inversion per row, without any heap allocation: the buffers live on the
/// stack, so peak RSS matches the old per-row path.
const SCALAR_INVERSION_CHUNK_ROWS: usize = 32;
const SCALAR_INVERSION_MAX_BATCHES: usize = 16;

const ScalarInversionChunk = struct {
    points: [SCALAR_INVERSION_CHUNK_ROWS]CirclePointM31,
    denominators: [SCALAR_INVERSION_CHUNK_ROWS * SCALAR_INVERSION_MAX_BATCHES]CM31,
    inverses: [SCALAR_INVERSION_CHUNK_ROWS * SCALAR_INVERSION_MAX_BATCHES]CM31,
};

/// Karatsuba CM31 multiply over four packed rows. Identical field
/// operations to the scalar CM31.mul, one row per lane.
inline fn mulCM31Vec4(
    lhs_re: m31.Vec4u32,
    lhs_im: m31.Vec4u32,
    rhs_re: m31.Vec4u32,
    rhs_im: m31.Vec4u32,
) struct { re: m31.Vec4u32, im: m31.Vec4u32 } {
    const ac = m31.mulVec4(lhs_re, rhs_re);
    const bd = m31.mulVec4(lhs_im, rhs_im);
    const cross = m31.mulVec4(
        m31.addVec4(lhs_re, lhs_im),
        m31.addVec4(rhs_re, rhs_im),
    );
    return .{
        .re = m31.subVec4(ac, bd),
        .im = m31.subVec4(m31.subVec4(cross, ac), bd),
    };
}

/// Finalizes quotients for four rows in packed lanes, reading staged
/// per-row QM31 numerators. Same exact field operations as
/// `quotients.finalizeRowQuotients` per row, so outputs are byte-identical
/// to the scalar writeQuotientRow calls it replaces.
fn finalizeQuadVec4(
    out_columns: [qm31.SECURE_EXTENSION_DEGREE][]M31,
    output_position: usize,
    quotient_constants: *const quotients.QuotientConstants,
    ys: m31.Vec4u32,
    staged_numerators: []const [m31.VEC_WIDTH]QM31,
    staged_inverses: []const [m31.VEC_WIDTH]CM31,
) void {
    var acc: [qm31.SECURE_EXTENSION_DEGREE]m31.Vec4u32 = @splat(@splat(0));
    for (quotient_constants.batch_linear_terms, 0..) |linear_term, batch| {
        const a_coords = linear_term.sum_a.toM31Array();
        const b_coords = linear_term.sum_b.toM31Array();
        var diff: [qm31.SECURE_EXTENSION_DEGREE]m31.Vec4u32 = undefined;
        inline for (0..qm31.SECURE_EXTENSION_DEGREE) |coordinate| {
            const lt = m31.addVec4(
                m31.mulVec4(@as(m31.Vec4u32, @splat(a_coords[coordinate].v)), ys),
                @as(m31.Vec4u32, @splat(b_coords[coordinate].v)),
            );
            var nums: [m31.VEC_WIDTH]u32 = undefined;
            inline for (0..m31.VEC_WIDTH) |lane| {
                nums[lane] = staged_numerators[batch][lane].toM31Array()[coordinate].v;
            }
            diff[coordinate] = m31.subVec4(nums, lt);
        }
        var inv_re: [m31.VEC_WIDTH]u32 = undefined;
        var inv_im: [m31.VEC_WIDTH]u32 = undefined;
        inline for (0..m31.VEC_WIDTH) |lane| {
            inv_re[lane] = staged_inverses[batch][lane].a.v;
            inv_im[lane] = staged_inverses[batch][lane].b.v;
        }
        const q0 = mulCM31Vec4(diff[0], diff[1], inv_re, inv_im);
        const q1 = mulCM31Vec4(diff[2], diff[3], inv_re, inv_im);
        acc[0] = m31.addVec4(acc[0], q0.re);
        acc[1] = m31.addVec4(acc[1], q0.im);
        acc[2] = m31.addVec4(acc[2], q1.re);
        acc[3] = m31.addVec4(acc[3], q1.im);
    }
    inline for (0..qm31.SECURE_EXTENSION_DEGREE) |coordinate| {
        m31.storeVec4(out_columns[coordinate][output_position..].ptr, acc[coordinate]);
    }
}

fn executeMaterializedScalar(item: *const MaterializedWork) !void {
    const workspace = item.workspace;
    const batch_count = workspace.sample_point_components.len;
    if (batch_count > SCALAR_INVERSION_MAX_BATCHES) {
        return executeMaterializedScalarPerRow(item);
    }
    var walk = domain_walk.BitReversedCosetWalk.init(
        item.domain,
        item.lifting_log_size,
        item.start,
    );
    var chunk: ScalarInversionChunk = undefined;
    var position = item.start;
    while (position < item.end) {
        const row_count = @min(SCALAR_INVERSION_CHUNK_ROWS, item.end - position);
        for (0..row_count) |row| {
            chunk.points[row] = walk.next();
        }
        try workspace.prepareDenominatorInversesForRows(
            chunk.points[0..row_count],
            chunk.denominators[0 .. row_count * batch_count],
            chunk.inverses[0 .. row_count * batch_count],
        );
        var row: usize = 0;
        while (row + m31.VEC_WIDTH <= row_count) : (row += m31.VEC_WIDTH) {
            var staged_num: [SCALAR_INVERSION_MAX_BATCHES][m31.VEC_WIDTH]QM31 = undefined;
            var staged_inv: [SCALAR_INVERSION_MAX_BATCHES][m31.VEC_WIDTH]CM31 = undefined;
            var ys: [m31.VEC_WIDTH]M31 = undefined;
            inline for (0..m31.VEC_WIDTH) |lane| {
                const r = row + lane;
                ys[lane] = chunk.points[r].y;
                workspace.resetNumerators();
                for (item.lifted_columns, item.contribution_plan_ranges) |lifted_column, contribution_range| {
                    const base_value = lifted_column[position + r];
                    for (item.contributions[contribution_range.start..][0..contribution_range.len]) |contribution| {
                        workspace.batch_numerators[contribution.batch_index] =
                            workspace.batch_numerators[contribution.batch_index].add(
                                contribution.value_coeff.mulM31(base_value),
                            );
                    }
                }
                for (0..batch_count) |batch| {
                    staged_num[batch][lane] = workspace.batch_numerators[batch];
                    staged_inv[batch][lane] = chunk.inverses[r * batch_count + batch];
                }
            }
            finalizeQuadVec4(
                item.out_columns,
                position + row,
                item.quotient_constants,
                m31.loadVec4(&ys),
                staged_num[0..batch_count],
                staged_inv[0..batch_count],
            );
        }
        while (row < row_count) : (row += 1) {
            const domain_point = chunk.points[row];
            workspace.resetNumerators();
            for (item.lifted_columns, item.contribution_plan_ranges) |lifted_column, contribution_range| {
                const base_value = lifted_column[position + row];
                for (item.contributions[contribution_range.start..][0..contribution_range.len]) |contribution| {
                    workspace.batch_numerators[contribution.batch_index] =
                        workspace.batch_numerators[contribution.batch_index].add(
                            contribution.value_coeff.mulM31(base_value),
                        );
                }
            }
            try writeQuotientRow(
                item.out_columns,
                position + row,
                item.quotient_constants,
                domain_point.y,
                workspace.batch_numerators,
                chunk.inverses[row * batch_count ..][0..batch_count],
            );
        }
        position += row_count;
    }
}

fn executeMaterializedScalarPerRow(item: *const MaterializedWork) !void {
    const workspace = item.workspace;
    var walk = domain_walk.BitReversedCosetWalk.init(
        item.domain,
        item.lifting_log_size,
        item.start,
    );
    for (item.start..item.end) |position| {
        const domain_point = walk.next();
        try workspace.beginRow(domain_point);
        for (item.lifted_columns, item.contribution_plan_ranges) |lifted_column, contribution_range| {
            const base_value = lifted_column[position];
            for (item.contributions[contribution_range.start..][0..contribution_range.len]) |contribution| {
                workspace.batch_numerators[contribution.batch_index] =
                    workspace.batch_numerators[contribution.batch_index].add(
                        contribution.value_coeff.mulM31(base_value),
                    );
            }
        }
        try writeQuotientRow(
            item.out_columns,
            position,
            item.quotient_constants,
            domain_point.y,
            workspace.batch_numerators,
            workspace.denominator_inverses,
        );
    }
}

pub fn materializedWorker(item: *MaterializedWork) void {
    executeMaterialized(item) catch |err| {
        item.failure = err;
    };
}

pub const StreamingWork = struct {
    out_columns: [qm31.SECURE_EXTENSION_DEGREE][]M31,
    start: usize,
    end: usize,
    output_start: usize = 0,
    workspace: *quotients.RowQuotientWorkspace,
    scratch: ?*Scratch,
    domain: CircleDomain,
    combined_views: []const CombinedContributionView,
    quotient_constants: *const quotients.QuotientConstants,
    lifting_log_size: u32,
    tile_writer: ?tile_sink.Writer = null,
    completed_tiles: usize = 0,
    failure: ?anyerror = null,
};

pub fn executeStreaming(item: *StreamingWork) !void {
    if (item.output_start > item.start) return error.ShapeMismatch;
    const output_end = item.end - item.output_start;
    for (item.out_columns) |column| {
        if (output_end > column.len) return error.ShapeMismatch;
    }

    const scratch = item.scratch orelse return executeStreamingScalar(item);
    const workspace = item.workspace;
    var chunk_start = item.start;
    var walk = domain_walk.BitReversedCosetWalk.init(
        item.domain,
        item.lifting_log_size,
        item.start,
    );
    while (chunk_start < item.end) {
        const row_count = @min(scratch.rowCapacity(), item.end - chunk_start);
        for (scratch.domain_points[0..row_count]) |*domain_point| {
            domain_point.* = walk.next();
        }
        try scratch.prepare(workspace, row_count);

        var tile_row_start: usize = 0;
        while (tile_row_start < row_count) {
            const tile_row_end = @min(
                row_count,
                tile_row_start + tile_sink.DEFAULT_TILE_ROWS,
            );
            for (tile_row_start..tile_row_end) |row| {
                const position = chunk_start + row;
                const domain_point = scratch.domain_points[row];
                workspace.resetNumerators();
                accumulateStreamingNumerators(workspace, item.combined_views, position);
                try writeQuotientRow(
                    item.out_columns,
                    position - item.output_start,
                    item.quotient_constants,
                    domain_point.y,
                    workspace.batch_numerators,
                    try scratch.inversesForRow(row),
                );
            }
            try emitCompletedTile(
                item,
                chunk_start + tile_row_start,
                chunk_start + tile_row_end,
            );
            tile_row_start = tile_row_end;
        }
        chunk_start += row_count;
    }
}

fn executeStreamingScalar(item: *StreamingWork) !void {
    const workspace = item.workspace;
    const batch_count = workspace.sample_point_components.len;
    if (batch_count > SCALAR_INVERSION_MAX_BATCHES) {
        return executeStreamingScalarPerRow(item);
    }
    var walk = domain_walk.BitReversedCosetWalk.init(
        item.domain,
        item.lifting_log_size,
        item.start,
    );
    var chunk: ScalarInversionChunk = undefined;
    var tile_start = item.start;
    while (tile_start < item.end) {
        const tile_end = @min(item.end, tile_start + tile_sink.DEFAULT_TILE_ROWS);
        var position = tile_start;
        while (position < tile_end) {
            const row_count = @min(SCALAR_INVERSION_CHUNK_ROWS, tile_end - position);
            for (0..row_count) |row| {
                chunk.points[row] = walk.next();
            }
            try workspace.prepareDenominatorInversesForRows(
                chunk.points[0..row_count],
                chunk.denominators[0 .. row_count * batch_count],
                chunk.inverses[0 .. row_count * batch_count],
            );
            var row: usize = 0;
            while (row + m31.VEC_WIDTH <= row_count) : (row += m31.VEC_WIDTH) {
                var staged_num: [SCALAR_INVERSION_MAX_BATCHES][m31.VEC_WIDTH]QM31 = undefined;
                var staged_inv: [SCALAR_INVERSION_MAX_BATCHES][m31.VEC_WIDTH]CM31 = undefined;
                var ys: [m31.VEC_WIDTH]M31 = undefined;
                inline for (0..m31.VEC_WIDTH) |lane| {
                    const r = row + lane;
                    ys[lane] = chunk.points[r].y;
                    workspace.resetNumerators();
                    accumulateStreamingNumerators(workspace, item.combined_views, position + r);
                    for (0..batch_count) |batch| {
                        staged_num[batch][lane] = workspace.batch_numerators[batch];
                        staged_inv[batch][lane] = chunk.inverses[r * batch_count + batch];
                    }
                }
                finalizeQuadVec4(
                    item.out_columns,
                    position + row - item.output_start,
                    item.quotient_constants,
                    m31.loadVec4(&ys),
                    staged_num[0..batch_count],
                    staged_inv[0..batch_count],
                );
            }
            while (row < row_count) : (row += 1) {
                const domain_point = chunk.points[row];
                workspace.resetNumerators();
                accumulateStreamingNumerators(workspace, item.combined_views, position + row);
                try writeQuotientRow(
                    item.out_columns,
                    position + row - item.output_start,
                    item.quotient_constants,
                    domain_point.y,
                    workspace.batch_numerators,
                    chunk.inverses[row * batch_count ..][0..batch_count],
                );
            }
            position += row_count;
        }
        try emitCompletedTile(item, tile_start, tile_end);
        tile_start = tile_end;
    }
}

fn executeStreamingScalarPerRow(item: *StreamingWork) !void {
    const workspace = item.workspace;
    var tile_start = item.start;
    var walk = domain_walk.BitReversedCosetWalk.init(
        item.domain,
        item.lifting_log_size,
        item.start,
    );
    while (tile_start < item.end) {
        const tile_end = @min(item.end, tile_start + tile_sink.DEFAULT_TILE_ROWS);
        for (tile_start..tile_end) |position| {
            const domain_point = walk.next();
            try workspace.beginRow(domain_point);
            accumulateStreamingNumerators(workspace, item.combined_views, position);
            try writeQuotientRow(
                item.out_columns,
                position - item.output_start,
                item.quotient_constants,
                domain_point.y,
                workspace.batch_numerators,
                workspace.denominator_inverses,
            );
        }
        try emitCompletedTile(item, tile_start, tile_end);
        tile_start = tile_end;
    }
}

fn emitCompletedTile(item: *StreamingWork, start: usize, end: usize) !void {
    const writer = item.tile_writer orelse return;
    if (start < item.output_start or end <= start) return error.ShapeMismatch;
    const output_start = start - item.output_start;
    const output_end = end - item.output_start;
    var coordinates: [qm31.SECURE_EXTENSION_DEGREE][]const M31 = undefined;
    inline for (0..qm31.SECURE_EXTENSION_DEGREE) |coordinate| {
        coordinates[coordinate] = item.out_columns[coordinate][output_start..output_end];
    }
    try writer.absorb(.{ .start = start, .coordinates = coordinates });
    item.completed_tiles += 1;
}

fn accumulateStreamingNumerators(
    workspace: *quotients.RowQuotientWorkspace,
    views: []const CombinedContributionView,
    position: usize,
) void {
    for (views) |view| {
        const idx = if (view.is_direct)
            position
        else
            ((position >> view.shift_amt) << 1) + (position & 1);
        const value = QM31.fromM31(
            view.coordinates[0][idx],
            view.coordinates[1][idx],
            view.coordinates[2][idx],
            view.coordinates[3][idx],
        );
        workspace.batch_numerators[view.batch_index] =
            workspace.batch_numerators[view.batch_index].add(value);
    }
}

pub fn streamingWorker(item: *StreamingWork) void {
    executeStreaming(item) catch |err| {
        item.failure = err;
    };
}

fn writeQuotientRow(
    out_columns: [qm31.SECURE_EXTENSION_DEGREE][]M31,
    output_position: usize,
    quotient_constants: *const quotients.QuotientConstants,
    domain_y: M31,
    batch_numerators: []const QM31,
    denominator_inverses: []const CM31,
) !void {
    const quotient_value = try quotients.finalizeRowQuotients(
        quotient_constants,
        domain_y,
        batch_numerators,
        denominator_inverses,
    );
    const coordinates = quotient_value.toM31Array();
    inline for (0..qm31.SECURE_EXTENSION_DEGREE) |coordinate| {
        out_columns[coordinate][output_position] = coordinates[coordinate];
    }
}

test "quotient row scratch rejects invalid, overflowing, and over-budget shapes" {
    try std.testing.expectError(error.InvalidChunkSize, rowCapacityForBatchCount(1, 0));
    try std.testing.expectError(
        error.ScratchSizeOverflow,
        rowCapacityForBatchCount(std.math.maxInt(usize), 1),
    );
    try std.testing.expectError(
        error.ScratchMemoryLimitExceeded,
        rowCapacityForBatchCount(MAX_BYTES_PER_WORKER / @sizeOf(CM31), 1),
    );
}

test "quotient row inverses match scalar rows across batch counts and domains" {
    const allocator = std.testing.allocator;
    const batch_counts = [_]usize{ 1, 3, 8 };
    const log_sizes = [_]u32{ 3, 6, 10 };
    var entries: [batch_counts[batch_counts.len - 1]][1]quotients.NumeratorData = undefined;

    for (batch_counts) |batch_count| {
        var batches: [batch_counts[batch_counts.len - 1]]quotients.ColumnSampleBatch = undefined;
        for (batches[0..batch_count], 0..) |*batch, index| {
            entries[index][0] = .{
                .column_index = 0,
                .sample_value = QM31.fromU32Unchecked(@intCast(index + 3), 1, 2, 3),
                .random_coeff = QM31.fromU32Unchecked(@intCast(index + 5), 0, 1, 0),
            };
            batch.* = .{
                .point = circle.SECURE_FIELD_CIRCLE_GEN.mul(17 + index * 12),
                .cols_vals_randpows = entries[index][0..],
            };
        }

        var constants = try quotients.quotientConstants(allocator, batches[0..batch_count]);
        defer constants.deinit(allocator);
        var workspace = try quotients.RowQuotientWorkspace.init(allocator, batches[0..batch_count]);
        defer workspace.deinit(allocator);

        for (log_sizes) |log_size| {
            const domain = canonic.CanonicCoset.new(log_size).circleDomain();
            var scratch = try Scratch.init(allocator, batch_count, domain.size());
            defer scratch.deinit(allocator);

            for (scratch.domain_points, 0..) |*point, row| point.* = domain.at(row);
            try scratch.prepare(&workspace, scratch.rowCapacity());

            for (scratch.domain_points, 0..) |domain_point, row| {
                try workspace.beginRow(domain_point);
                const batched = try scratch.inversesForRow(row);
                for (workspace.denominator_inverses, batched) |scalar, chunked| {
                    try std.testing.expect(scalar.eql(chunked));
                }

                const queried_values = [_]M31{M31.fromCanonical(@intCast(row + 11))};
                const scalar_quotient = try quotients.accumulateRowQuotientsWithWorkspace(
                    batches[0..batch_count],
                    queried_values[0..],
                    &constants,
                    domain_point,
                    &workspace,
                );

                workspace.resetNumerators();
                for (constants.line_coeffs, 0..) |line_coeffs, batch_index| {
                    workspace.batch_numerators[batch_index] =
                        workspace.batch_numerators[batch_index].add(
                            line_coeffs[0].c.mulM31(queried_values[0]),
                        );
                }
                const chunked_quotient = try quotients.finalizeRowQuotients(
                    &constants,
                    domain_point.y,
                    workspace.batch_numerators,
                    batched,
                );
                try std.testing.expect(scalar_quotient.eql(chunked_quotient));
            }
        }
    }
}

test "quotient row scratch reports a zero denominator" {
    const allocator = std.testing.allocator;
    const domain_point = canonic.CanonicCoset.new(3).circleDomain().at(2);
    var empty_entries: [0]quotients.NumeratorData = .{};
    const batch = quotients.ColumnSampleBatch{
        .point = .{
            .x = qm31.QM31.fromBase(domain_point.x),
            .y = qm31.QM31.fromBase(domain_point.y),
        },
        .cols_vals_randpows = empty_entries[0..],
    };
    var workspace = try quotients.RowQuotientWorkspace.init(allocator, &.{batch});
    defer workspace.deinit(allocator);
    var scratch = try Scratch.init(allocator, 1, 1);
    defer scratch.deinit(allocator);
    scratch.domain_points[0] = domain_point;

    try std.testing.expectError(error.DivisionByZero, scratch.prepare(&workspace, 1));
}

test "quotient row scratch policy honors cost boundary and memory fallback" {
    const over_budget_batches = MAX_BYTES_PER_WORKER / @sizeOf(CM31);
    var below_boundary = try initScratchOrScalarFallback(
        std.testing.allocator,
        std.math.maxInt(usize),
        1,
        MIN_BATCHED_DOMAIN_ROWS - 1,
    );
    defer if (below_boundary) |*value| value.deinit(std.testing.allocator);
    try std.testing.expectEqual(null, below_boundary);
    try std.testing.expectEqual(
        false,
        try prepareParallelScratchPolicy(
            std.math.maxInt(usize),
            1,
            MIN_BATCHED_DOMAIN_ROWS - 1,
        ),
    );

    var at_boundary = try initScratchOrScalarFallback(
        std.testing.allocator,
        1,
        1,
        MIN_BATCHED_DOMAIN_ROWS,
    );
    defer if (at_boundary) |*value| value.deinit(std.testing.allocator);
    try std.testing.expect(at_boundary != null);

    var over_budget = try initScratchOrScalarFallback(
        std.testing.allocator,
        over_budget_batches,
        1,
        MIN_BATCHED_DOMAIN_ROWS,
    );
    defer if (over_budget) |*value| value.deinit(std.testing.allocator);
    try std.testing.expectEqual(null, over_budget);
    try std.testing.expectError(
        error.ParallelUnavailable,
        initParallelScratch(
            std.testing.allocator,
            over_budget_batches,
            1,
            MIN_BATCHED_DOMAIN_ROWS,
        ),
    );
    try std.testing.expectError(
        error.ScratchSizeOverflow,
        initScratchOrScalarFallback(
            std.testing.allocator,
            std.math.maxInt(usize),
            1,
            MIN_BATCHED_DOMAIN_ROWS,
        ),
    );
}

test "quotient row worker partitions cover each domain exactly once" {
    const cases = [_]struct { domain_size: usize, worker_count: usize }{
        .{ .domain_size = 512, .worker_count = 2 },
        .{ .domain_size = 1024, .worker_count = 3 },
        .{ .domain_size = 4096, .worker_count = 7 },
    };
    for (cases) |case| {
        const span = try workerSpan(case.domain_size, case.worker_count);
        var cursor: usize = 0;
        for (0..case.worker_count) |worker| {
            const range = try workerRange(case.domain_size, span, worker);
            try std.testing.expectEqual(cursor, range.start);
            try std.testing.expect(range.end > range.start);
            cursor = range.end;
        }
        try std.testing.expectEqual(case.domain_size, cursor);
    }
    try std.testing.expectError(error.ParallelUnavailable, workerSpan(1024, 0));
    try std.testing.expectError(
        error.ScratchSizeOverflow,
        workerRange(std.math.maxInt(usize), std.math.maxInt(usize), 1),
    );
}

test "quotient row workers propagate denominator failures" {
    const allocator = std.testing.allocator;
    const log_size: u32 = 3;
    const domain = canonic.CanonicCoset.new(log_size).circleDomain();
    const domain_point = domain.at(core_utils.bitReverseIndex(0, log_size));
    var empty_entries: [0]quotients.NumeratorData = .{};
    const batch = quotients.ColumnSampleBatch{
        .point = .{
            .x = QM31.fromBase(domain_point.x),
            .y = QM31.fromBase(domain_point.y),
        },
        .cols_vals_randpows = empty_entries[0..],
    };
    const batches = [_]quotients.ColumnSampleBatch{batch};
    var constants = try quotients.quotientConstants(allocator, batches[0..]);
    defer constants.deinit(allocator);
    var workspace = try quotients.RowQuotientWorkspace.init(allocator, batches[0..]);
    defer workspace.deinit(allocator);
    var scratch = try Scratch.init(allocator, batches.len, domain.size());
    defer scratch.deinit(allocator);

    var storage: [qm31.SECURE_EXTENSION_DEGREE][8]M31 = undefined;
    var out_columns: [qm31.SECURE_EXTENSION_DEGREE][]M31 = undefined;
    inline for (0..qm31.SECURE_EXTENSION_DEGREE) |coordinate| {
        out_columns[coordinate] = storage[coordinate][0..];
    }

    var materialized = MaterializedWork{
        .out_columns = out_columns,
        .start = 0,
        .end = domain.size(),
        .workspace = &workspace,
        .scratch = &scratch,
        .domain = domain,
        .lifted_columns = &.{},
        .contribution_plan_ranges = &.{},
        .contributions = &.{},
        .quotient_constants = &constants,
        .lifting_log_size = log_size,
    };
    materializedWorker(&materialized);
    try std.testing.expectEqual(error.DivisionByZero, materialized.failure.?);

    var streaming = StreamingWork{
        .out_columns = out_columns,
        .start = 0,
        .end = domain.size(),
        .workspace = &workspace,
        .scratch = &scratch,
        .domain = domain,
        .combined_views = &.{},
        .quotient_constants = &constants,
        .lifting_log_size = log_size,
    };
    streamingWorker(&streaming);
    try std.testing.expectEqual(error.DivisionByZero, streaming.failure.?);
}

test "quad finalize matches scalar finalizeRowQuotients for all batch counts" {
    const allocator = std.testing.allocator;
    var rng_state: u64 = 0x9e3779b97f4a7c15;
    const nextM31 = struct {
        fn next(state: *u64) M31 {
            state.* ^= state.* << 13;
            state.* ^= state.* >> 7;
            state.* ^= state.* << 17;
            return M31.fromCanonical(@intCast(state.* % 2147483647));
        }
    }.next;

    for ([_]usize{ 1, 2, 3 }) |batch_count| {
        const line_coeffs = try allocator.alloc([]constraints.LineCoeffs, batch_count);
        defer allocator.free(line_coeffs);
        for (line_coeffs) |*lc| lc.* = &[_]constraints.LineCoeffs{};
        var constants: quotients.QuotientConstants = undefined;
        constants.line_coeffs = line_coeffs;
        constants.batch_linear_terms = try allocator.alloc(
            std.meta.Child(@TypeOf(constants.batch_linear_terms)),
            batch_count,
        );
        defer allocator.free(constants.batch_linear_terms);
        for (constants.batch_linear_terms) |*term| {
            term.* = .{
                .sum_a = QM31.fromM31(nextM31(&rng_state), nextM31(&rng_state), nextM31(&rng_state), nextM31(&rng_state)),
                .sum_b = QM31.fromM31(nextM31(&rng_state), nextM31(&rng_state), nextM31(&rng_state), nextM31(&rng_state)),
            };
        }

        var out_columns: [qm31.SECURE_EXTENSION_DEGREE][m31.VEC_WIDTH]M31 = undefined;
        var outs: [qm31.SECURE_EXTENSION_DEGREE][]M31 = undefined;
        inline for (0..qm31.SECURE_EXTENSION_DEGREE) |c| outs[c] = out_columns[c][0..];
        var staged_num: [SCALAR_INVERSION_MAX_BATCHES][m31.VEC_WIDTH]QM31 = undefined;
        var staged_inv: [SCALAR_INVERSION_MAX_BATCHES][m31.VEC_WIDTH]CM31 = undefined;
        var ys: [m31.VEC_WIDTH]M31 = undefined;
        for (0..batch_count) |batch| {
            for (0..m31.VEC_WIDTH) |lane| {
                staged_num[batch][lane] = QM31.fromM31(nextM31(&rng_state), nextM31(&rng_state), nextM31(&rng_state), nextM31(&rng_state));
                staged_inv[batch][lane] = CM31.fromM31(nextM31(&rng_state), nextM31(&rng_state));
            }
        }
        for (0..m31.VEC_WIDTH) |lane| ys[lane] = nextM31(&rng_state);

        finalizeQuadVec4(
            outs,
            0,
            &constants,
            m31.loadVec4(&ys),
            staged_num[0..batch_count],
            staged_inv[0..batch_count],
        );
        for (0..m31.VEC_WIDTH) |lane| {
            var numerators: [3]QM31 = undefined;
            var inverses: [3]CM31 = undefined;
            for (0..batch_count) |batch| {
                numerators[batch] = staged_num[batch][lane];
                inverses[batch] = staged_inv[batch][lane];
            }
            const scalar_q = try quotients.finalizeRowQuotients(
                &constants,
                ys[lane],
                numerators[0..batch_count],
                inverses[0..batch_count],
            );
            const scalar_coords = scalar_q.toM31Array();
            inline for (0..qm31.SECURE_EXTENSION_DEGREE) |coordinate| {
                try std.testing.expectEqual(
                    scalar_coords[coordinate].v,
                    out_columns[coordinate][lane].v,
                );
            }
        }
    }
}
