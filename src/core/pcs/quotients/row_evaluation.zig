//! Backend-independent quotient evaluation for one queried domain row.
//!
//! The allocating and reusable-workspace entry points implement the same law.
//! Optimized backends may replace mechanics, but not line construction,
//! denominator semantics, or accumulation order without oracle evidence.

const std = @import("std");
const circle = @import("../../circle.zig");
const constraints = @import("../../constraints.zig");
const cm31_mod = @import("../../fields/cm31.zig");
const m31_mod = @import("../../fields/m31.zig");
const qm31_mod = @import("../../fields/qm31.zig");
const samples = @import("samples.zig");

const CirclePointM31 = circle.CirclePointM31;
const CirclePointQM31 = circle.CirclePointQM31;
const CM31 = cm31_mod.CM31;
const M31 = m31_mod.M31;
const QM31 = qm31_mod.QM31;
const ColumnSampleBatch = samples.ColumnSampleBatch;

/// Constants shared by every row evaluated for one sample-batch set.
pub const QuotientConstants = struct {
    line_coeffs: [][]constraints.LineCoeffs,
    batch_linear_terms: []BatchLinearTerm,

    pub fn deinit(self: *QuotientConstants, allocator: std.mem.Allocator) void {
        for (self.line_coeffs) |batch_coeffs| allocator.free(batch_coeffs);
        allocator.free(self.line_coeffs);
        allocator.free(self.batch_linear_terms);
        self.* = undefined;
    }
};

const BatchLinearTerm = struct {
    sum_a: QM31,
    sum_b: QM31,

    inline fn evalAt(self: BatchLinearTerm, domain_y: M31) QM31 {
        return self.sum_a.mulM31(domain_y).add(self.sum_b);
    }
};

/// Precomputes line coefficients for every sampled column in each batch.
pub fn columnLineCoeffs(
    allocator: std.mem.Allocator,
    sample_batches: []const ColumnSampleBatch,
) ![][]constraints.LineCoeffs {
    var outer = std.ArrayList([]constraints.LineCoeffs).empty;
    defer outer.deinit(allocator);
    errdefer {
        for (outer.items) |batch_coeffs| allocator.free(batch_coeffs);
    }

    for (sample_batches) |batch| {
        const batch_coeffs = try allocator.alloc(constraints.LineCoeffs, batch.cols_vals_randpows.len);
        errdefer allocator.free(batch_coeffs);

        for (batch.cols_vals_randpows, 0..) |sample_data, i| {
            batch_coeffs[i] = constraints.complexConjugateLineCoeffs(
                batch.point,
                sample_data.sample_value,
                sample_data.random_coeff,
            ) catch return error.DegenerateLine;
        }
        try outer.append(allocator, batch_coeffs);
    }

    return outer.toOwnedSlice(allocator);
}

pub fn quotientConstants(
    allocator: std.mem.Allocator,
    sample_batches: []const ColumnSampleBatch,
) !QuotientConstants {
    const line_coeffs = try columnLineCoeffs(allocator, sample_batches);
    errdefer {
        for (line_coeffs) |batch_coeffs| allocator.free(batch_coeffs);
        allocator.free(line_coeffs);
    }

    const batch_linear_terms = try allocator.alloc(BatchLinearTerm, sample_batches.len);
    errdefer allocator.free(batch_linear_terms);
    for (sample_batches, line_coeffs, 0..) |batch, coeffs, batch_idx| {
        if (batch.cols_vals_randpows.len != coeffs.len) return error.ShapeMismatch;
        var sum_a = QM31.zero();
        var sum_b = QM31.zero();
        for (coeffs) |coeff| {
            sum_a = sum_a.add(coeff.a);
            sum_b = sum_b.add(coeff.b);
        }
        batch_linear_terms[batch_idx] = .{
            .sum_a = sum_a,
            .sum_b = sum_b,
        };
    }

    return .{
        .line_coeffs = line_coeffs,
        .batch_linear_terms = batch_linear_terms,
    };
}

/// Computes denominator inverses for one domain point and all sample points.
pub fn denominatorInverses(
    allocator: std.mem.Allocator,
    sample_points: []const CirclePointQM31,
    domain_point: CirclePointM31,
) ![]CM31 {
    const denominators = try allocator.alloc(CM31, sample_points.len);
    defer allocator.free(denominators);
    const inverses = try allocator.alloc(CM31, sample_points.len);
    errdefer allocator.free(inverses);

    try denominatorInversesInto(sample_points, domain_point, denominators, inverses);
    return inverses;
}

fn denominatorInversesInto(
    sample_points: []const CirclePointQM31,
    domain_point: CirclePointM31,
    denominators: []CM31,
    denominator_inverses: []CM31,
) !void {
    if (denominators.len != sample_points.len) return error.ShapeMismatch;
    if (denominator_inverses.len != sample_points.len) return error.ShapeMismatch;

    const domain_x = CM31.fromBase(domain_point.x);
    const domain_y = CM31.fromBase(domain_point.y);

    for (sample_points, 0..) |sample_point, i| {
        const prx = sample_point.x.c0;
        const pry = sample_point.y.c0;
        const pix = sample_point.x.c1;
        const piy = sample_point.y.c1;
        denominators[i] = prx.sub(domain_x).mul(piy).sub(pry.sub(domain_y).mul(pix));
    }

    try batchInverseIntoCM31(denominators, denominator_inverses);
}

const SamplePointComponents = struct {
    prx: CM31,
    pry: CM31,
    pix: CM31,
    piy: CM31,
};

/// Reusable scratch for row-by-row quotient accumulation.
pub const RowQuotientWorkspace = struct {
    sample_point_components: []SamplePointComponents,
    denominator_scratch: []CM31,
    denominator_inverses: []CM31,
    batch_numerators: []QM31,

    pub fn init(
        allocator: std.mem.Allocator,
        sample_batches: []const ColumnSampleBatch,
    ) !RowQuotientWorkspace {
        const sample_point_components = try allocator.alloc(SamplePointComponents, sample_batches.len);
        errdefer allocator.free(sample_point_components);
        const denominator_scratch = try allocator.alloc(CM31, sample_batches.len);
        errdefer allocator.free(denominator_scratch);
        const denominator_inverses = try allocator.alloc(CM31, sample_batches.len);
        errdefer allocator.free(denominator_inverses);
        const batch_numerators = try allocator.alloc(QM31, sample_batches.len);
        errdefer allocator.free(batch_numerators);

        for (sample_batches, 0..) |batch, i| {
            sample_point_components[i] = .{
                .prx = batch.point.x.c0,
                .pry = batch.point.y.c0,
                .pix = batch.point.x.c1,
                .piy = batch.point.y.c1,
            };
        }

        return .{
            .sample_point_components = sample_point_components,
            .denominator_scratch = denominator_scratch,
            .denominator_inverses = denominator_inverses,
            .batch_numerators = batch_numerators,
        };
    }

    pub fn deinit(self: *RowQuotientWorkspace, allocator: std.mem.Allocator) void {
        allocator.free(self.sample_point_components);
        allocator.free(self.denominator_scratch);
        allocator.free(self.denominator_inverses);
        allocator.free(self.batch_numerators);
        self.* = undefined;
    }

    pub fn beginRow(self: *RowQuotientWorkspace, domain_point: CirclePointM31) !void {
        try denominatorInversesIntoFromComponents(
            self.sample_point_components,
            domain_point,
            self.denominator_scratch,
            self.denominator_inverses,
        );
        @memset(self.batch_numerators, QM31.zero());
    }

    /// Computes row-major denominator inverses for several domain points with
    /// one batch inversion. The caller owns the bounded chunk storage.
    pub fn prepareDenominatorInversesForRows(
        self: *const RowQuotientWorkspace,
        domain_points: []const CirclePointM31,
        denominators: []CM31,
        denominator_inverses: []CM31,
    ) !void {
        const cell_count = std.math.mul(
            usize,
            domain_points.len,
            self.sample_point_components.len,
        ) catch return error.ScratchSizeOverflow;
        if (denominators.len != cell_count) return error.ShapeMismatch;
        if (denominator_inverses.len != cell_count) return error.ShapeMismatch;

        for (domain_points, 0..) |domain_point, row| {
            const start = row * self.sample_point_components.len;
            denominatorValuesIntoFromComponents(
                self.sample_point_components,
                domain_point,
                denominators[start..][0..self.sample_point_components.len],
            );
        }
        try batchInverseIntoCM31(denominators, denominator_inverses);
    }

    pub inline fn resetNumerators(self: *RowQuotientWorkspace) void {
        @memset(self.batch_numerators, QM31.zero());
    }
};

fn denominatorInversesIntoFromComponents(
    sample_point_components: []const SamplePointComponents,
    domain_point: CirclePointM31,
    denominators: []CM31,
    denominator_inverses: []CM31,
) !void {
    if (denominators.len != sample_point_components.len) return error.ShapeMismatch;
    if (denominator_inverses.len != sample_point_components.len) return error.ShapeMismatch;

    denominatorValuesIntoFromComponents(sample_point_components, domain_point, denominators);

    try batchInverseIntoCM31(denominators, denominator_inverses);
}

fn denominatorValuesIntoFromComponents(
    sample_point_components: []const SamplePointComponents,
    domain_point: CirclePointM31,
    denominators: []CM31,
) void {
    std.debug.assert(denominators.len == sample_point_components.len);
    const domain_x = CM31.fromBase(domain_point.x);
    const domain_y = CM31.fromBase(domain_point.y);

    for (sample_point_components, 0..) |sample, i| {
        denominators[i] = sample.prx.sub(domain_x).mul(sample.piy).sub(sample.pry.sub(domain_y).mul(sample.pix));
    }
}

fn batchInverseIntoCM31(values: []const CM31, out: []CM31) !void {
    if (values.len != out.len) return error.ShapeMismatch;
    if (values.len == 0) return;

    out[0] = CM31.one();
    var i: usize = 1;
    while (i < values.len) : (i += 1) {
        out[i] = out[i - 1].mul(values[i - 1]);
    }

    var inv_total = out[values.len - 1].mul(values[values.len - 1]).inv() catch {
        return error.DivisionByZero;
    };

    var j: usize = values.len;
    while (j > 0) {
        j -= 1;
        const prefix = if (j == 0) CM31.one() else out[j];
        out[j] = inv_total.mul(prefix);
        inv_total = inv_total.mul(values[j]);
    }
}

/// Computes one quotient row using caller-provided reusable scratch.
pub fn accumulateRowQuotientsWithWorkspace(
    sample_batches: []const ColumnSampleBatch,
    queried_values_at_row: []const M31,
    quotient_constants: *const QuotientConstants,
    domain_point: CirclePointM31,
    workspace: *RowQuotientWorkspace,
) !QM31 {
    if (sample_batches.len != quotient_constants.line_coeffs.len) return error.ShapeMismatch;
    if (sample_batches.len != quotient_constants.batch_linear_terms.len) return error.ShapeMismatch;
    if (workspace.sample_point_components.len != sample_batches.len) return error.ShapeMismatch;
    if (workspace.denominator_scratch.len != sample_batches.len) return error.ShapeMismatch;
    if (workspace.denominator_inverses.len != sample_batches.len) return error.ShapeMismatch;
    if (workspace.batch_numerators.len != sample_batches.len) return error.ShapeMismatch;

    try workspace.beginRow(domain_point);

    for (sample_batches, 0..) |batch, batch_idx| {
        const line_coeffs = quotient_constants.line_coeffs[batch_idx];
        if (batch.cols_vals_randpows.len != line_coeffs.len) return error.ShapeMismatch;

        for (batch.cols_vals_randpows, 0..) |sample_data, i| {
            if (sample_data.column_index >= queried_values_at_row.len) {
                return error.ColumnIndexOutOfBounds;
            }
            const value = line_coeffs[i].c.mulM31(queried_values_at_row[sample_data.column_index]);
            workspace.batch_numerators[batch_idx] = workspace.batch_numerators[batch_idx].add(value);
        }
    }
    return finalizeRowQuotients(
        quotient_constants,
        domain_point.y,
        workspace.batch_numerators,
        workspace.denominator_inverses,
    );
}

/// Computes `sum(alpha^k * (c * value - b))` for one batch and row.
pub fn accumulateRowPartialNumerators(
    batch: *const ColumnSampleBatch,
    queried_values_at_row: []const M31,
    coeffs: []const constraints.LineCoeffs,
) !QM31 {
    if (batch.cols_vals_randpows.len != coeffs.len) return error.ShapeMismatch;

    var numerator = QM31.zero();
    for (batch.cols_vals_randpows, 0..) |sample_data, i| {
        if (sample_data.column_index >= queried_values_at_row.len) {
            return error.ColumnIndexOutOfBounds;
        }
        const value = coeffs[i].c.mulM31(queried_values_at_row[sample_data.column_index]);
        numerator = numerator.add(value.sub(coeffs[i].b));
    }
    return numerator;
}

/// Computes one quotient row with call-local scratch allocations.
pub fn accumulateRowQuotients(
    allocator: std.mem.Allocator,
    sample_batches: []const ColumnSampleBatch,
    queried_values_at_row: []const M31,
    quotient_constants: *const QuotientConstants,
    domain_point: CirclePointM31,
) !QM31 {
    if (sample_batches.len != quotient_constants.line_coeffs.len) return error.ShapeMismatch;
    if (sample_batches.len != quotient_constants.batch_linear_terms.len) return error.ShapeMismatch;

    const sample_points = try allocator.alloc(CirclePointQM31, sample_batches.len);
    defer allocator.free(sample_points);
    for (sample_batches, 0..) |batch, i| sample_points[i] = batch.point;

    const denominator_scratch = try allocator.alloc(CM31, sample_batches.len);
    defer allocator.free(denominator_scratch);
    const denominator_inverses = try allocator.alloc(CM31, sample_batches.len);
    defer allocator.free(denominator_inverses);
    const batch_numerators = try allocator.alloc(QM31, sample_batches.len);
    defer allocator.free(batch_numerators);
    try denominatorInversesInto(
        sample_points,
        domain_point,
        denominator_scratch,
        denominator_inverses,
    );
    @memset(batch_numerators, QM31.zero());

    for (sample_batches, 0..) |batch, batch_idx| {
        const line_coeffs = quotient_constants.line_coeffs[batch_idx];
        if (batch.cols_vals_randpows.len != line_coeffs.len) return error.ShapeMismatch;

        for (batch.cols_vals_randpows, 0..) |sample_data, i| {
            if (sample_data.column_index >= queried_values_at_row.len) {
                return error.ColumnIndexOutOfBounds;
            }
            const value = line_coeffs[i].c.mulM31(queried_values_at_row[sample_data.column_index]);
            batch_numerators[batch_idx] = batch_numerators[batch_idx].add(value);
        }
    }
    return finalizeRowQuotients(
        quotient_constants,
        domain_point.y,
        batch_numerators,
        denominator_inverses,
    );
}

pub fn finalizeRowQuotients(
    quotient_constants: *const QuotientConstants,
    domain_y: M31,
    batch_numerators: []const QM31,
    denominator_inverses: []const CM31,
) !QM31 {
    if (quotient_constants.batch_linear_terms.len != batch_numerators.len) return error.ShapeMismatch;
    if (denominator_inverses.len != batch_numerators.len) return error.ShapeMismatch;

    var row_accumulator = QM31.zero();
    for (quotient_constants.batch_linear_terms, batch_numerators, denominator_inverses) |linear_term, numerator_sum, denominator_inverse| {
        const numerator = numerator_sum.sub(linear_term.evalAt(domain_y));
        row_accumulator = row_accumulator.add(numerator.mulCM31(denominator_inverse));
    }
    return row_accumulator;
}
