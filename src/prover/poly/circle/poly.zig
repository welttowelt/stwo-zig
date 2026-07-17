const std = @import("std");
const circle = @import("../../../core/circle.zig");
const fft = @import("../../../core/fft.zig");
const m31 = @import("../../../core/fields/m31.zig");
const qm31 = @import("../../../core/fields/qm31.zig");
const canonic = @import("../../../core/poly/circle/canonic.zig");
const domain_mod = @import("../../../core/poly/circle/domain.zig");
const line_mod = @import("../../../core/poly/line.zig");
const poly_utils = @import("../../../core/poly/utils.zig");
const eval_mod = @import("evaluation.zig");
const fft_kernels = @import("fft_kernels.zig");
const point_evaluation = @import("point_evaluation.zig");
const twiddles_mod = @import("../twiddles.zig");

const M31 = m31.M31;
const QM31 = qm31.QM31;
const CirclePointQM31 = circle.CirclePointQM31;
const CircleDomain = domain_mod.CircleDomain;
const M31TwiddleTree = twiddles_mod.TwiddleTree([]const M31);

pub const PolyError = error{
    InvalidLength,
    InvalidLogSize,
    NonBaseEvaluation,
    SingularSystem,
};

/// Host polynomial coefficients in the circle-FFT basis.
///
/// Invariants:
/// - `coeffs.len` is a non-zero power of two.
pub const CircleCoefficients = struct {
    coeffs: []const M31,
    log_size: u32,
    owns_coeffs: bool,

    pub fn initBorrowed(coeffs: []const M31) PolyError!CircleCoefficients {
        if (coeffs.len == 0 or !std.math.isPowerOfTwo(coeffs.len)) {
            return PolyError.InvalidLength;
        }
        return .{
            .coeffs = coeffs,
            .log_size = @intCast(std.math.log2_int(usize, coeffs.len)),
            .owns_coeffs = false,
        };
    }

    pub fn initOwned(coeffs: []M31) PolyError!CircleCoefficients {
        var out = try initBorrowed(coeffs);
        out.owns_coeffs = true;
        return out;
    }

    pub fn deinit(self: *CircleCoefficients, allocator: std.mem.Allocator) void {
        if (self.owns_coeffs) allocator.free(@constCast(self.coeffs));
        self.* = undefined;
    }

    pub fn logSize(self: CircleCoefficients) u32 {
        return self.log_size;
    }

    pub fn coefficients(self: CircleCoefficients) []const M31 {
        return self.coeffs;
    }

    /// Evaluates the polynomial at one secure-field point.
    pub fn evalAtPoint(self: CircleCoefficients, point: CirclePointQM31) QM31 {
        if (self.log_size == 0) return QM31.fromBase(self.coeffs[0]);

        var factors: [circle.M31_CIRCLE_LOG_ORDER]QM31 = undefined;
        return self.evalAtPointWithFactors(
            fillEvalFactorsForPoint(point, self.log_size, &factors),
        );
    }

    pub fn evalAtPointWithFactors(
        self: CircleCoefficients,
        factors: []const QM31,
    ) QM31 {
        std.debug.assert(factors.len == self.log_size);
        if (self.log_size == 0) return QM31.fromBase(self.coeffs[0]);
        return point_evaluation.evalAtPointIterative(
            self.coeffs,
            factors,
            self.log_size,
        );
    }

    pub fn evalAtPointsFolded(
        self: CircleCoefficients,
        points: []const CirclePointQM31,
        fold_count: u32,
        out: []QM31,
    ) void {
        std.debug.assert(points.len == out.len);
        var flat_factors: [32 * circle.M31_CIRCLE_LOG_ORDER]QM31 = undefined;
        if (points.len <= 32) {
            fillEvalFactorsForPointsFolded(
                points,
                fold_count,
                self.log_size,
                flat_factors[0 .. points.len * self.log_size],
            );
            self.evalAtPointsWithFlatFactors(
                flat_factors[0 .. points.len * self.log_size],
                out,
            );
            return;
        }

        const chunk_points: usize = 32;
        var at: usize = 0;
        while (at < points.len) {
            const chunk_len = @min(chunk_points, points.len - at);
            fillEvalFactorsForPointsFolded(
                points[at .. at + chunk_len],
                fold_count,
                self.log_size,
                flat_factors[0 .. chunk_len * self.log_size],
            );
            self.evalAtPointsWithFlatFactors(
                flat_factors[0 .. chunk_len * self.log_size],
                out[at .. at + chunk_len],
            );
            at += chunk_len;
        }
    }

    pub fn evalAtPointsWithFlatFactors(
        self: CircleCoefficients,
        flat_factors: []const QM31,
        out: []QM31,
    ) void {
        std.debug.assert(self.log_size == 0 or flat_factors.len == out.len * self.log_size);
        if (self.log_size == 0) {
            const constant = QM31.fromBase(self.coeffs[0]);
            @memset(out, constant);
            return;
        }

        var factor_at: usize = 0;
        for (out) |*value| {
            value.* = point_evaluation.evalAtPointIterative(
                self.coeffs,
                flat_factors[factor_at .. factor_at + self.log_size],
                self.log_size,
            );
            factor_at += self.log_size;
        }
    }

    pub fn evalManyAtPointsWithFlatFactors(
        polys: []const CircleCoefficients,
        flat_factors: []const QM31,
        out_batch: []const []QM31,
    ) void {
        std.debug.assert(polys.len == out_batch.len);
        if (polys.len == 0) return;

        const log_size = polys[0].log_size;
        if (log_size == 0) {
            for (polys, out_batch) |poly, out| {
                const constant = QM31.fromBase(poly.coeffs[0]);
                @memset(out, constant);
            }
            return;
        }

        const point_count = out_batch[0].len;
        std.debug.assert(flat_factors.len == point_count * log_size);
        for (polys, out_batch) |poly, out| {
            std.debug.assert(poly.log_size == log_size);
            std.debug.assert(out.len == point_count);
        }

        var factor_at: usize = 0;
        for (0..point_count) |point_idx| {
            const point_factors = flat_factors[factor_at .. factor_at + log_size];
            for (polys, out_batch) |poly, out| {
                out[point_idx] = point_evaluation.evalAtPointIterative(
                    poly.coeffs,
                    point_factors,
                    log_size,
                );
            }
            factor_at += log_size;
        }
    }

    pub fn extend(
        self: CircleCoefficients,
        allocator: std.mem.Allocator,
        log_size: u32,
    ) (std.mem.Allocator.Error || PolyError)!CircleCoefficients {
        if (log_size < self.log_size) return PolyError.InvalidLogSize;
        const new_len = checkedPow2(log_size) catch return PolyError.InvalidLogSize;
        const out = try allocator.alloc(M31, new_len);
        @memset(out, M31.zero());
        @memcpy(out[0..self.coeffs.len], self.coeffs);
        return CircleCoefficients.initOwned(out);
    }

    pub fn evaluate(
        self: CircleCoefficients,
        allocator: std.mem.Allocator,
        domain: CircleDomain,
    ) (std.mem.Allocator.Error || PolyError || eval_mod.EvaluationError)!eval_mod.CircleEvaluation {
        var twiddle_tree_owned = twiddles_mod.precomputeM31(allocator, domain.half_coset) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SingularTwiddle => return PolyError.SingularSystem,
        };
        defer twiddles_mod.deinitM31(allocator, &twiddle_tree_owned);
        return self.evaluateWithTwiddles(
            allocator,
            domain,
            .{
                .root_coset = twiddle_tree_owned.root_coset,
                .twiddles = twiddle_tree_owned.twiddles,
                .itwiddles = twiddle_tree_owned.itwiddles,
            },
        );
    }

    pub fn evaluateWithTwiddles(
        self: CircleCoefficients,
        allocator: std.mem.Allocator,
        domain: CircleDomain,
        twiddle_tree: M31TwiddleTree,
    ) (std.mem.Allocator.Error || PolyError || eval_mod.EvaluationError)!eval_mod.CircleEvaluation {
        if (domain.logSize() < self.log_size) return PolyError.InvalidLogSize;
        if (!domain.half_coset.isDoublingOf(twiddle_tree.root_coset)) return PolyError.InvalidLogSize;
        const values = try allocator.alloc(M31, domain.size());
        errdefer allocator.free(values);
        @memcpy(values[0..self.coeffs.len], self.coeffs);
        if (self.coeffs.len < values.len) @memset(values[self.coeffs.len..], M31.zero());

        const log_size = domain.logSize();
        if (log_size == 1) {
            var v0 = values[0];
            var v1 = values[1];
            fft.butterfly(M31, &v0, &v1, domain.half_coset.initial.y);
            values[0] = v0;
            values[1] = v1;
            return eval_mod.CircleEvaluation.init(domain, values);
        }
        if (log_size == 2) {
            var v0 = values[0];
            var v1 = values[1];
            var v2 = values[2];
            var v3 = values[3];
            const x = domain.half_coset.initial.x;
            const y = domain.half_coset.initial.y;
            fft.butterfly(M31, &v0, &v2, x);
            fft.butterfly(M31, &v1, &v3, x);
            fft.butterfly(M31, &v0, &v1, y);
            fft.butterfly(M31, &v2, &v3, y.neg());
            values[0] = v0;
            values[1] = v1;
            values[2] = v2;
            values[3] = v3;
            return eval_mod.CircleEvaluation.init(domain, values);
        }

        const line_log_size = domain.half_coset.logSize();
        const twiddle_len = twiddle_tree.twiddles.len;
        var layer_idx: u32 = line_log_size;
        while (layer_idx > 0) {
            layer_idx -= 1;
            const depth = line_log_size - 1 - layer_idx;
            const len = @as(usize, 1) << @intCast(depth);
            const start = twiddle_len - (len * 2);
            const layer_twiddles = twiddle_tree.twiddles[start .. twiddle_len - len];
            for (layer_twiddles, 0..) |twid, h| {
                fft_kernels.fftLayerLoopForwardM31(values, @intCast(layer_idx + 1), h, twid);
            }
        }

        const first_line_len = @as(usize, 1) << @intCast(line_log_size - 1);
        const first_line_twiddles = twiddle_tree.twiddles[twiddle_len - (first_line_len * 2) .. twiddle_len - first_line_len];
        var tw_idx: usize = 0;
        var first_h: usize = 0;
        const first_half = values.len / 2;
        while (first_h < first_half) : (first_h += 4) {
            const x = first_line_twiddles[tw_idx];
            const y = first_line_twiddles[tw_idx + 1];
            tw_idx += 2;
            fft_kernels.fftPairForwardM31(values, first_h, y);
            fft_kernels.fftPairForwardM31(values, first_h + 1, y.neg());
            fft_kernels.fftPairForwardM31(values, first_h + 2, x.neg());
            fft_kernels.fftPairForwardM31(values, first_h + 3, x);
        }
        return eval_mod.CircleEvaluation.init(domain, values);
    }

    pub const SplitPair = struct {
        left: CircleCoefficients,
        right: CircleCoefficients,

        pub fn deinit(self: *SplitPair, allocator: std.mem.Allocator) void {
            self.left.deinit(allocator);
            self.right.deinit(allocator);
            self.* = undefined;
        }
    };

    /// Splits the coefficient vector in the middle.
    ///
    /// Returns `(left, right)` such that:
    /// `p(z) = left(z) + pi^{L-2}(z.x) * right(z)`, where `L = log2(coeffs.len)`.
    pub fn splitAtMid(
        self: CircleCoefficients,
        allocator: std.mem.Allocator,
    ) (std.mem.Allocator.Error || PolyError)!SplitPair {
        if (self.log_size == 0) return PolyError.InvalidLogSize;
        const mid = self.coeffs.len / 2;
        const left = try allocator.dupe(M31, self.coeffs[0..mid]);
        errdefer allocator.free(left);
        const right = try allocator.dupe(M31, self.coeffs[mid..]);
        errdefer allocator.free(right);

        return .{
            .left = try CircleCoefficients.initOwned(left),
            .right = try CircleCoefficients.initOwned(right),
        };
    }
};

/// Compatibility type function for callers parameterized by a prover backend.
/// Coefficients currently borrow host slices, so their representation is
/// backend-independent.
pub fn CircleCoefficientsGeneric(comptime B: type) type {
    _ = B;
    return CircleCoefficients;
}

test "prover poly circle poly: generic type preserves host representation" {
    try std.testing.expect(CircleCoefficientsGeneric(struct {}) == CircleCoefficients);
}

/// Interpolates circle coefficients from bit-reversed domain evaluations.
///
/// This is a deterministic reference implementation (Gaussian elimination).
pub fn interpolateFromEvaluation(
    allocator: std.mem.Allocator,
    evaluation: eval_mod.CircleEvaluation,
) (std.mem.Allocator.Error || PolyError)!CircleCoefficients {
    var twiddle_tree_owned = twiddles_mod.precomputeM31(allocator, evaluation.domain.half_coset) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SingularTwiddle => return PolyError.SingularSystem,
    };
    defer twiddles_mod.deinitM31(allocator, &twiddle_tree_owned);
    return interpolateFromEvaluationWithTwiddles(
        allocator,
        evaluation,
        .{
            .root_coset = twiddle_tree_owned.root_coset,
            .twiddles = twiddle_tree_owned.twiddles,
            .itwiddles = twiddle_tree_owned.itwiddles,
        },
    );
}

pub fn interpolateFromEvaluationWithTwiddles(
    allocator: std.mem.Allocator,
    evaluation: eval_mod.CircleEvaluation,
    twiddle_tree: M31TwiddleTree,
) (std.mem.Allocator.Error || PolyError)!CircleCoefficients {
    const n = evaluation.values.len;
    if (n == 0 or !std.math.isPowerOfTwo(n)) return PolyError.InvalidLength;
    if (evaluation.domain.size() != n) return PolyError.InvalidLength;
    if (!evaluation.domain.half_coset.isDoublingOf(twiddle_tree.root_coset)) return PolyError.InvalidLogSize;
    const coeffs = try allocator.dupe(M31, evaluation.values);
    errdefer allocator.free(coeffs);
    try interpolateIntoBufferWithTwiddles(
        coeffs,
        evaluation.domain,
        twiddle_tree,
    );
    return CircleCoefficients.initOwned(coeffs);
}

/// Consumes owned bit-reversed evaluation values and turns them into owned coefficients in place.
///
/// Ownership:
/// - `owned_values` is consumed on success and becomes the returned coefficient storage.
/// - On error, the caller retains ownership of `owned_values`.
pub fn interpolateOwnedValuesWithTwiddles(
    domain: CircleDomain,
    owned_values: []M31,
    twiddle_tree: M31TwiddleTree,
) PolyError!CircleCoefficients {
    const n = owned_values.len;
    if (n == 0 or !std.math.isPowerOfTwo(n)) return PolyError.InvalidLength;
    if (domain.size() != n) return PolyError.InvalidLength;
    if (!domain.half_coset.isDoublingOf(twiddle_tree.root_coset)) return PolyError.InvalidLogSize;
    try interpolateIntoBufferWithTwiddles(
        owned_values,
        domain,
        twiddle_tree,
    );
    return CircleCoefficients.initOwned(owned_values);
}

pub fn interpolateOwnedValuesBatchWithTwiddles(
    domain: CircleDomain,
    owned_values_batch: []const []M31,
    twiddle_tree: M31TwiddleTree,
) PolyError!void {
    if (owned_values_batch.len == 0) return;
    for (owned_values_batch) |owned_values| {
        const n = owned_values.len;
        if (n == 0 or !std.math.isPowerOfTwo(n)) return PolyError.InvalidLength;
        if (domain.size() != n) return PolyError.InvalidLength;
    }
    if (!domain.half_coset.isDoublingOf(twiddle_tree.root_coset)) return PolyError.InvalidLogSize;
    try interpolateBuffersWithTwiddles(
        owned_values_batch,
        domain,
        twiddle_tree,
    );
}

pub fn evaluateManyWithTwiddles(
    allocator: std.mem.Allocator,
    polys: []const CircleCoefficients,
    domain: CircleDomain,
    twiddle_tree: M31TwiddleTree,
) (std.mem.Allocator.Error || PolyError || eval_mod.EvaluationError)![][]M31 {
    const out = try allocator.alloc([]M31, polys.len);
    errdefer allocator.free(out);

    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |values| allocator.free(values);
    }

    for (polys, 0..) |poly, i| {
        if (domain.logSize() < poly.log_size) return PolyError.InvalidLogSize;
        const values = try allocator.alloc(M31, domain.size());
        @memcpy(values[0..poly.coeffs.len], poly.coeffs);
        if (poly.coeffs.len < values.len) @memset(values[poly.coeffs.len..], M31.zero());
        out[i] = values;
        initialized += 1;
    }

    try evaluateBuffersWithTwiddles(out, domain, twiddle_tree);
    return out;
}

fn interpolateIntoBufferWithTwiddles(
    coeffs: []M31,
    domain: CircleDomain,
    twiddle_tree: M31TwiddleTree,
) PolyError!void {
    const n = coeffs.len;
    const log_size = domain.logSize();
    if (log_size == 1) {
        const y = domain.half_coset.initial.y;
        const n_f = M31.fromCanonical(2);
        const yn_inv = y.mul(n_f).inv() catch return PolyError.SingularSystem;
        const y_inv = yn_inv.mul(n_f);
        const n_inv = yn_inv.mul(y);

        var v0 = coeffs[0];
        var v1 = coeffs[1];
        fft.ibutterfly(M31, &v0, &v1, y_inv);
        coeffs[0] = v0.mul(n_inv);
        coeffs[1] = v1.mul(n_inv);
        return;
    }
    if (log_size == 2) {
        const x = domain.half_coset.initial.x;
        const y = domain.half_coset.initial.y;
        const n_f = M31.fromCanonical(4);
        const xyn_inv = x.mul(y).mul(n_f).inv() catch return PolyError.SingularSystem;
        const x_inv = xyn_inv.mul(y).mul(n_f);
        const y_inv = xyn_inv.mul(x).mul(n_f);
        const n_inv = xyn_inv.mul(x).mul(y);

        var v0 = coeffs[0];
        var v1 = coeffs[1];
        var v2 = coeffs[2];
        var v3 = coeffs[3];
        fft.ibutterfly(M31, &v0, &v1, y_inv);
        fft.ibutterfly(M31, &v2, &v3, y_inv.neg());
        fft.ibutterfly(M31, &v0, &v2, x_inv);
        fft.ibutterfly(M31, &v1, &v3, x_inv);
        coeffs[0] = v0.mul(n_inv);
        coeffs[1] = v1.mul(n_inv);
        coeffs[2] = v2.mul(n_inv);
        coeffs[3] = v3.mul(n_inv);
        return;
    }

    const line_log_size = domain.half_coset.logSize();
    const itwiddle_len = twiddle_tree.itwiddles.len;
    const first_line_len = @as(usize, 1) << @intCast(line_log_size - 1);
    const first_line_itwiddles = twiddle_tree.itwiddles[itwiddle_len - (first_line_len * 2) .. itwiddle_len - first_line_len];
    var tw_idx: usize = 0;
    var first_h: usize = 0;
    const first_half = coeffs.len / 2;
    while (first_h < first_half) : (first_h += 4) {
        const x = first_line_itwiddles[tw_idx];
        const y = first_line_itwiddles[tw_idx + 1];
        tw_idx += 2;
        fft_kernels.fftPairInverseM31(coeffs, first_h, y);
        fft_kernels.fftPairInverseM31(coeffs, first_h + 1, y.neg());
        fft_kernels.fftPairInverseM31(coeffs, first_h + 2, x.neg());
        fft_kernels.fftPairInverseM31(coeffs, first_h + 3, x);
    }

    var layer_idx: u32 = 0;
    while (layer_idx < line_log_size) : (layer_idx += 1) {
        const depth = line_log_size - 1 - layer_idx;
        const len = @as(usize, 1) << @intCast(depth);
        const start = itwiddle_len - (len * 2);
        const layer_twiddles = twiddle_tree.itwiddles[start .. itwiddle_len - len];
        for (layer_twiddles, 0..) |twid, h| {
            fft_kernels.fftLayerLoopInverseM31(coeffs, @intCast(layer_idx + 1), h, twid);
        }
    }

    const n_inv = M31.fromCanonical(@intCast(n)).inv() catch return PolyError.SingularSystem;
    for (coeffs) |*coeff| {
        coeff.* = coeff.*.mul(n_inv);
    }
}

pub fn interpolateBuffersWithTwiddles(
    coeffs_batch: []const []M31,
    domain: CircleDomain,
    twiddle_tree: M31TwiddleTree,
) PolyError!void {
    const log_size = domain.logSize();
    if (log_size == 1) {
        const y = domain.half_coset.initial.y;
        const n_f = M31.fromCanonical(2);
        const yn_inv = y.mul(n_f).inv() catch return PolyError.SingularSystem;
        const y_inv = yn_inv.mul(n_f);
        const n_inv = yn_inv.mul(y);

        for (coeffs_batch) |coeffs| {
            var v0 = coeffs[0];
            var v1 = coeffs[1];
            fft.ibutterfly(M31, &v0, &v1, y_inv);
            coeffs[0] = v0.mul(n_inv);
            coeffs[1] = v1.mul(n_inv);
        }
        return;
    }
    if (log_size == 2) {
        const x = domain.half_coset.initial.x;
        const y = domain.half_coset.initial.y;
        const n_f = M31.fromCanonical(4);
        const xyn_inv = x.mul(y).mul(n_f).inv() catch return PolyError.SingularSystem;
        const x_inv = xyn_inv.mul(y).mul(n_f);
        const y_inv = xyn_inv.mul(x).mul(n_f);
        const n_inv = xyn_inv.mul(x).mul(y);

        for (coeffs_batch) |coeffs| {
            var v0 = coeffs[0];
            var v1 = coeffs[1];
            var v2 = coeffs[2];
            var v3 = coeffs[3];
            fft.ibutterfly(M31, &v0, &v1, y_inv);
            fft.ibutterfly(M31, &v2, &v3, y_inv.neg());
            fft.ibutterfly(M31, &v0, &v2, x_inv);
            fft.ibutterfly(M31, &v1, &v3, x_inv);
            coeffs[0] = v0.mul(n_inv);
            coeffs[1] = v1.mul(n_inv);
            coeffs[2] = v2.mul(n_inv);
            coeffs[3] = v3.mul(n_inv);
        }
        return;
    }

    const line_log_size = domain.half_coset.logSize();
    const itwiddle_len = twiddle_tree.itwiddles.len;
    const first_line_len = @as(usize, 1) << @intCast(line_log_size - 1);
    const first_line_itwiddles = twiddle_tree.itwiddles[itwiddle_len - (first_line_len * 2) .. itwiddle_len - first_line_len];
    var tw_idx: usize = 0;
    var first_h: usize = 0;
    const first_half = coeffs_batch[0].len / 2;
    while (first_h < first_half) : (first_h += 4) {
        const x = first_line_itwiddles[tw_idx];
        const y = first_line_itwiddles[tw_idx + 1];
        const y_neg = y.neg();
        const x_neg = x.neg();
        tw_idx += 2;
        for (coeffs_batch) |coeffs| {
            fft_kernels.fftPairInverseM31(coeffs, first_h, y);
            fft_kernels.fftPairInverseM31(coeffs, first_h + 1, y_neg);
            fft_kernels.fftPairInverseM31(coeffs, first_h + 2, x_neg);
            fft_kernels.fftPairInverseM31(coeffs, first_h + 3, x);
        }
    }

    var layer_idx: u32 = 0;
    while (layer_idx < line_log_size) : (layer_idx += 1) {
        const depth = line_log_size - 1 - layer_idx;
        const len = @as(usize, 1) << @intCast(depth);
        const start = itwiddle_len - (len * 2);
        const layer_twiddles = twiddle_tree.itwiddles[start .. itwiddle_len - len];
        for (layer_twiddles, 0..) |twid, h| {
            for (coeffs_batch) |coeffs| {
                fft_kernels.fftLayerLoopInverseM31(coeffs, @intCast(layer_idx + 1), h, twid);
            }
        }
    }

    const n_inv = M31.fromCanonical(@intCast(coeffs_batch[0].len)).inv() catch return PolyError.SingularSystem;
    for (coeffs_batch) |coeffs| {
        for (coeffs) |*coeff| {
            coeff.* = coeff.*.mul(n_inv);
        }
    }
}

pub fn evaluateBuffersWithTwiddles(
    values_batch: []const []M31,
    domain: CircleDomain,
    twiddle_tree: M31TwiddleTree,
) PolyError!void {
    if (!domain.half_coset.isDoublingOf(twiddle_tree.root_coset)) return PolyError.InvalidLogSize;
    const log_size = domain.logSize();
    if (log_size == 1) {
        const y = domain.half_coset.initial.y;
        for (values_batch) |values| {
            var v0 = values[0];
            var v1 = values[1];
            fft.butterfly(M31, &v0, &v1, y);
            values[0] = v0;
            values[1] = v1;
        }
        return;
    }
    if (log_size == 2) {
        const x = domain.half_coset.initial.x;
        const y = domain.half_coset.initial.y;
        for (values_batch) |values| {
            var v0 = values[0];
            var v1 = values[1];
            var v2 = values[2];
            var v3 = values[3];
            fft.butterfly(M31, &v0, &v2, x);
            fft.butterfly(M31, &v1, &v3, x);
            fft.butterfly(M31, &v0, &v1, y);
            fft.butterfly(M31, &v2, &v3, y.neg());
            values[0] = v0;
            values[1] = v1;
            values[2] = v2;
            values[3] = v3;
        }
        return;
    }

    const line_log_size = domain.half_coset.logSize();
    const twiddle_len = twiddle_tree.twiddles.len;
    var layer_idx: u32 = line_log_size;
    while (layer_idx > 0) {
        layer_idx -= 1;
        const depth = line_log_size - 1 - layer_idx;
        const len = @as(usize, 1) << @intCast(depth);
        const start = twiddle_len - (len * 2);
        const layer_twiddles = twiddle_tree.twiddles[start .. twiddle_len - len];
        for (layer_twiddles, 0..) |twid, h| {
            for (values_batch) |values| {
                fft_kernels.fftLayerLoopForwardM31(values, @intCast(layer_idx + 1), h, twid);
            }
        }
    }

    const first_line_len = @as(usize, 1) << @intCast(line_log_size - 1);
    const first_line_twiddles = twiddle_tree.twiddles[twiddle_len - (first_line_len * 2) .. twiddle_len - first_line_len];
    var tw_idx: usize = 0;
    var first_h: usize = 0;
    const first_half = values_batch[0].len / 2;
    while (first_h < first_half) : (first_h += 4) {
        const x = first_line_twiddles[tw_idx];
        const y = first_line_twiddles[tw_idx + 1];
        const y_neg = y.neg();
        const x_neg = x.neg();
        tw_idx += 2;
        for (values_batch) |values| {
            fft_kernels.fftPairForwardM31(values, first_h, y);
            fft_kernels.fftPairForwardM31(values, first_h + 1, y_neg);
            fft_kernels.fftPairForwardM31(values, first_h + 2, x_neg);
            fft_kernels.fftPairForwardM31(values, first_h + 3, x);
        }
    }
}

fn checkedPow2(log_size: u32) PolyError!usize {
    if (log_size >= @bitSizeOf(usize)) return PolyError.InvalidLogSize;
    return @as(usize, 1) << @intCast(log_size);
}

fn pointM31IntoQM31(point: circle.CirclePointM31) CirclePointQM31 {
    return .{
        .x = QM31.fromBase(point.x),
        .y = QM31.fromBase(point.y),
    };
}

const repeatedDoubleOnCircleQM31 = point_evaluation.repeatedDoubleOnCircleQM31;

pub const fillEvalFactorsForPoint = point_evaluation.fillEvalFactorsForPoint;
pub const fillEvalFactorsForPointsFolded = point_evaluation.fillEvalFactorsForPointsFolded;

test "prover poly circle poly: eval at point for constant polynomial" {
    const coeffs = [_]M31{M31.fromCanonical(23)};
    const poly = try CircleCoefficients.initBorrowed(coeffs[0..]);
    const point = circle.SECURE_FIELD_CIRCLE_GEN.mul(11);
    try std.testing.expect(poly.evalAtPoint(point).eql(QM31.fromBase(M31.fromCanonical(23))));
}

test "prover poly circle poly: owned interpolation matches cloned interpolation" {
    const alloc = std.testing.allocator;
    const domain = canonic.CanonicCoset.new(5).circleDomain();
    const values = try alloc.alloc(M31, domain.size());
    defer alloc.free(values);
    for (values, 0..) |*value, i| {
        value.* = M31.fromCanonical(@intCast((i * 13 + 7) % m31.Modulus));
    }

    const twiddle_tree = try twiddles_mod.precomputeM31(alloc, domain.half_coset);
    defer {
        var owned = twiddle_tree;
        twiddles_mod.deinitM31(alloc, &owned);
    }

    const evaluation = try eval_mod.CircleEvaluation.init(domain, values);
    var cloned = try interpolateFromEvaluationWithTwiddles(
        alloc,
        evaluation,
        .{
            .root_coset = twiddle_tree.root_coset,
            .twiddles = twiddle_tree.twiddles,
            .itwiddles = twiddle_tree.itwiddles,
        },
    );
    defer cloned.deinit(alloc);

    const owned_values = try alloc.dupe(M31, values);
    var in_place = try interpolateOwnedValuesWithTwiddles(
        domain,
        owned_values,
        .{
            .root_coset = twiddle_tree.root_coset,
            .twiddles = twiddle_tree.twiddles,
            .itwiddles = twiddle_tree.itwiddles,
        },
    );
    defer in_place.deinit(alloc);

    try std.testing.expectEqual(cloned.logSize(), in_place.logSize());
    try std.testing.expectEqualSlices(M31, cloned.coefficients(), in_place.coefficients());
}

test "prover poly circle poly: batched owned interpolation matches scalar helper" {
    const alloc = std.testing.allocator;
    const domain = canonic.CanonicCoset.new(5).circleDomain();
    const twiddle_tree = try twiddles_mod.precomputeM31(alloc, domain.half_coset);
    defer {
        var owned = twiddle_tree;
        twiddles_mod.deinitM31(alloc, &owned);
    }

    var prng = std.Random.DefaultPrng.init(0x6d41_9b83_7e52_4c11);
    const random = prng.random();

    for ([_]usize{ 1, 2, 3, 4, 5, 6, 7, 8 }) |column_count| {
        const batch_values = try alloc.alloc([]M31, column_count);
        defer alloc.free(batch_values);
        const scalar_values = try alloc.alloc([]M31, column_count);
        defer alloc.free(scalar_values);

        for (0..column_count) |idx| {
            batch_values[idx] = try alloc.alloc(M31, domain.size());
            scalar_values[idx] = try alloc.alloc(M31, domain.size());
            for (batch_values[idx], scalar_values[idx]) |*batch, *scalar| {
                const value = M31.fromCanonical(random.intRangeLessThan(u32, 0, m31.Modulus));
                batch.* = value;
                scalar.* = value;
            }
        }

        defer {
            for (batch_values) |values| alloc.free(values);
            for (scalar_values) |values| if (values.len != 0) alloc.free(values);
        }

        try interpolateOwnedValuesBatchWithTwiddles(
            domain,
            batch_values,
            .{
                .root_coset = twiddle_tree.root_coset,
                .twiddles = twiddle_tree.twiddles,
                .itwiddles = twiddle_tree.itwiddles,
            },
        );
        for (scalar_values, 0..) |values, idx| {
            var scalar = try interpolateOwnedValuesWithTwiddles(
                domain,
                values,
                .{
                    .root_coset = twiddle_tree.root_coset,
                    .twiddles = twiddle_tree.twiddles,
                    .itwiddles = twiddle_tree.itwiddles,
                },
            );
            defer scalar.deinit(alloc);
            scalar_values[idx] = &[_]M31{};
            try std.testing.expectEqualSlices(M31, scalar.coefficients(), batch_values[idx]);
        }
    }
}

test "prover poly circle poly: split-at-mid identity" {
    const alloc = std.testing.allocator;
    const log_size: u32 = 5;

    const coeffs = try alloc.alloc(M31, @as(usize, 1) << @intCast(log_size));
    defer alloc.free(coeffs);
    for (coeffs, 0..) |*coeff, i| {
        const canonical: u32 = @intCast((i * 17 + 5) % m31.Modulus);
        coeff.* = M31.fromCanonical(canonical);
    }

    const poly = try CircleCoefficients.initBorrowed(coeffs);
    var split = try poly.splitAtMid(alloc);
    defer split.deinit(alloc);

    const point = circle.SECURE_FIELD_CIRCLE_GEN.mul(21903);
    const lhs = split.left.evalAtPoint(point).add(
        point.repeatedDouble(log_size - 2).x.mul(split.right.evalAtPoint(point)),
    );
    const rhs = poly.evalAtPoint(point);
    try std.testing.expect(lhs.eql(rhs));
}

test "prover poly circle poly: eval at points folded batch matches scalar oracle" {
    const alloc = std.testing.allocator;
    const log_sizes = [_]u32{ 2, 3, 4, 5, 6, 7 };

    var prng = std.Random.DefaultPrng.init(0x194a_2f73_8cdd_4a61);
    const random = prng.random();

    for (log_sizes) |log_size| {
        const n = @as(usize, 1) << @intCast(log_size);
        const coeffs = try alloc.alloc(M31, n);
        defer alloc.free(coeffs);
        for (coeffs) |*coeff| {
            coeff.* = M31.fromCanonical(random.intRangeLessThan(u32, 0, m31.Modulus));
        }

        const poly = try CircleCoefficients.initBorrowed(coeffs);
        const points_len: usize = 32;
        const points = try alloc.alloc(CirclePointQM31, points_len);
        defer alloc.free(points);
        const out = try alloc.alloc(QM31, points_len);
        defer alloc.free(out);
        for (points) |*point| {
            point.* = circle.SECURE_FIELD_CIRCLE_GEN.mul(@as(u64, random.int(u32)) + 41);
        }

        const max_fold = @min(log_size, @as(u32, 4));
        var fold_count: u32 = 0;
        while (fold_count <= max_fold) : (fold_count += 1) {
            poly.evalAtPointsFolded(points, fold_count, out);
            for (points, out) |point, batch_value| {
                const folded_point = if (fold_count == 0) point else repeatedDoubleOnCircleQM31(point, fold_count);
                const scalar = poly.evalAtPoint(folded_point);
                try std.testing.expect(batch_value.eql(scalar));
            }
        }
    }
}

test "prover poly circle poly: precomputed folded factors match scalar oracle" {
    const alloc = std.testing.allocator;
    const log_sizes = [_]u32{ 1, 3, 5, 7 };
    const point_counts = [_]usize{ 1, 5, 9 };

    var prng = std.Random.DefaultPrng.init(0x92a3_197d_4c5b_6ef1);
    const random = prng.random();

    for (log_sizes) |log_size| {
        const coeffs = try alloc.alloc(M31, @as(usize, 1) << @intCast(log_size));
        defer alloc.free(coeffs);
        for (coeffs) |*coeff| {
            coeff.* = M31.fromCanonical(random.intRangeLessThan(u32, 0, m31.Modulus));
        }
        const poly = try CircleCoefficients.initBorrowed(coeffs);

        for (point_counts) |point_count| {
            const points = try alloc.alloc(CirclePointQM31, point_count);
            defer alloc.free(points);
            for (points) |*point| {
                point.* = circle.SECURE_FIELD_CIRCLE_GEN.mul(@as(u64, random.int(u32)) + 73);
            }

            const expected = try alloc.alloc(QM31, point_count);
            defer alloc.free(expected);
            const actual = try alloc.alloc(QM31, point_count);
            defer alloc.free(actual);
            const factors = try alloc.alloc(QM31, point_count * log_size);
            defer alloc.free(factors);

            const max_fold = @min(log_size, @as(u32, 3));
            var fold_count: u32 = 0;
            while (fold_count <= max_fold) : (fold_count += 1) {
                poly.evalAtPointsFolded(points, fold_count, expected);
                fillEvalFactorsForPointsFolded(points, fold_count, log_size, factors);
                poly.evalAtPointsWithFlatFactors(factors, actual);
                for (expected, actual) |lhs, rhs| {
                    try std.testing.expect(lhs.eql(rhs));
                }
            }
        }
    }
}

test "prover poly circle poly: batched point evaluation matches scalar helper" {
    const alloc = std.testing.allocator;
    const log_size: u32 = 6;
    const poly_count: usize = 5;
    const point_count: usize = 7;

    var prng = std.Random.DefaultPrng.init(0xd1a5_4e7b_11c2_39af);
    const random = prng.random();

    const polys = try alloc.alloc(CircleCoefficients, poly_count);
    defer alloc.free(polys);
    const scalar_out = try alloc.alloc([]QM31, poly_count);
    defer alloc.free(scalar_out);
    const batch_out = try alloc.alloc([]QM31, poly_count);
    defer alloc.free(batch_out);

    for (0..poly_count) |poly_idx| {
        const coeffs = try alloc.alloc(M31, @as(usize, 1) << @intCast(log_size));
        for (coeffs) |*coeff| {
            coeff.* = M31.fromCanonical(random.intRangeLessThan(u32, 0, m31.Modulus));
        }
        polys[poly_idx] = try CircleCoefficients.initOwned(coeffs);
        scalar_out[poly_idx] = try alloc.alloc(QM31, point_count);
        batch_out[poly_idx] = try alloc.alloc(QM31, point_count);
    }
    defer {
        for (polys) |*poly| poly.deinit(alloc);
        for (scalar_out) |values| alloc.free(values);
        for (batch_out) |values| alloc.free(values);
    }

    const points = try alloc.alloc(CirclePointQM31, point_count);
    defer alloc.free(points);
    for (points) |*point| {
        point.* = circle.SECURE_FIELD_CIRCLE_GEN.mul(@as(u64, random.int(u32)) + 101);
    }

    const factors = try alloc.alloc(QM31, point_count * log_size);
    defer alloc.free(factors);
    fillEvalFactorsForPointsFolded(points, 0, log_size, factors);

    for (polys, scalar_out) |poly, out| {
        poly.evalAtPointsWithFlatFactors(factors, out);
    }
    CircleCoefficients.evalManyAtPointsWithFlatFactors(polys, factors, batch_out);

    for (scalar_out, batch_out) |expected, actual| {
        for (expected, actual) |lhs, rhs| {
            try std.testing.expect(lhs.eql(rhs));
        }
    }
}

test "prover poly circle poly: batched evaluation matches scalar helper" {
    const alloc = std.testing.allocator;
    const log_size: u32 = 5;
    const extended_log_size: u32 = 7;
    const domain = canonic.CanonicCoset.new(extended_log_size).circleDomain();
    const twiddle_tree = try twiddles_mod.precomputeM31(alloc, domain.half_coset);
    defer {
        var owned = twiddle_tree;
        twiddles_mod.deinitM31(alloc, &owned);
    }

    var prng = std.Random.DefaultPrng.init(0x4f17_5c32_e992_120d);
    const random = prng.random();

    for ([_]usize{ 1, 2, 3, 4, 5, 6, 7, 8 }) |poly_count| {
        const polys = try alloc.alloc(CircleCoefficients, poly_count);
        defer alloc.free(polys);
        var initialized: usize = 0;
        defer {
            for (polys[0..initialized]) |*poly| poly.deinit(alloc);
        }

        for (0..poly_count) |idx| {
            const coeffs = try alloc.alloc(M31, @as(usize, 1) << @intCast(log_size));
            for (coeffs) |*coeff| {
                coeff.* = M31.fromCanonical(random.intRangeLessThan(u32, 0, m31.Modulus));
            }
            polys[idx] = try CircleCoefficients.initOwned(coeffs);
            initialized += 1;
        }

        const batch_values = try evaluateManyWithTwiddles(
            alloc,
            polys,
            domain,
            .{
                .root_coset = twiddle_tree.root_coset,
                .twiddles = twiddle_tree.twiddles,
                .itwiddles = twiddle_tree.itwiddles,
            },
        );
        defer {
            for (batch_values) |values| alloc.free(values);
            alloc.free(batch_values);
        }

        for (polys, 0..) |poly, idx| {
            const scalar = try poly.evaluateWithTwiddles(
                alloc,
                domain,
                .{
                    .root_coset = twiddle_tree.root_coset,
                    .twiddles = twiddle_tree.twiddles,
                    .itwiddles = twiddle_tree.itwiddles,
                },
            );
            defer alloc.free(@constCast(scalar.values));
            try std.testing.expectEqualSlices(M31, scalar.values, batch_values[idx]);
        }
    }
}

test "prover poly circle poly: evaluate on domain returns base values" {
    const alloc = std.testing.allocator;
    const coeffs = [_]M31{
        M31.fromCanonical(1),
        M31.fromCanonical(0),
        M31.fromCanonical(0),
        M31.fromCanonical(0),
    };
    const poly = try CircleCoefficients.initBorrowed(coeffs[0..]);
    const domain = @import("../../../core/poly/circle/canonic.zig").CanonicCoset.new(3).circleDomain();

    const evaluation = try poly.evaluate(alloc, domain);
    defer alloc.free(@constCast(evaluation.values));

    for (evaluation.values) |value| {
        try std.testing.expect(value.eql(M31.fromCanonical(1)));
    }
}

test "prover poly circle poly: interpolation roundtrip" {
    const alloc = std.testing.allocator;
    const log_size: u32 = 4;
    const n = @as(usize, 1) << @intCast(log_size);

    const coeffs = try alloc.alloc(M31, n);
    defer alloc.free(coeffs);
    for (coeffs, 0..) |*coeff, i| {
        const canonical: u32 = @intCast((i * 19 + 3) % m31.Modulus);
        coeff.* = M31.fromCanonical(canonical);
    }

    const poly = try CircleCoefficients.initBorrowed(coeffs);
    const domain = @import("../../../core/poly/circle/canonic.zig").CanonicCoset.new(log_size).circleDomain();
    const evaluation = try poly.evaluate(alloc, domain);
    defer alloc.free(@constCast(evaluation.values));

    var interpolated = try interpolateFromEvaluation(alloc, evaluation);
    defer interpolated.deinit(alloc);
    try std.testing.expectEqualSlices(M31, poly.coefficients(), interpolated.coefficients());
}

test "prover poly circle poly: evaluate with twiddles matches evaluate" {
    const alloc = std.testing.allocator;
    const log_size: u32 = 5;
    const domain_log_size: u32 = 7;
    const n = @as(usize, 1) << @intCast(log_size);

    const coeffs = try alloc.alloc(M31, n);
    defer alloc.free(coeffs);
    for (coeffs, 0..) |*coeff, i| {
        const canonical: u32 = @intCast((i * 23 + 11) % m31.Modulus);
        coeff.* = M31.fromCanonical(canonical);
    }

    const poly = try CircleCoefficients.initBorrowed(coeffs);
    const domain = @import("../../../core/poly/circle/canonic.zig").CanonicCoset.new(domain_log_size).circleDomain();

    const eval_direct = try poly.evaluate(alloc, domain);
    defer alloc.free(@constCast(eval_direct.values));

    var twiddle_tree = try twiddles_mod.precomputeM31(alloc, domain.half_coset);
    defer twiddles_mod.deinitM31(alloc, &twiddle_tree);
    const eval_with_twiddles = try poly.evaluateWithTwiddles(
        alloc,
        domain,
        .{
            .root_coset = twiddle_tree.root_coset,
            .twiddles = twiddle_tree.twiddles,
            .itwiddles = twiddle_tree.itwiddles,
        },
    );
    defer alloc.free(@constCast(eval_with_twiddles.values));

    try std.testing.expectEqualSlices(M31, eval_direct.values, eval_with_twiddles.values);
}

test "prover poly circle poly: interpolate with twiddles matches interpolate" {
    const alloc = std.testing.allocator;
    const log_size: u32 = 6;
    const n = @as(usize, 1) << @intCast(log_size);

    const values = try alloc.alloc(M31, n);
    defer alloc.free(values);
    for (values, 0..) |*value, i| {
        const canonical: u32 = @intCast((i * 7 + 29) % m31.Modulus);
        value.* = M31.fromCanonical(canonical);
    }

    const domain = @import("../../../core/poly/circle/canonic.zig").CanonicCoset.new(log_size).circleDomain();
    const evaluation = try eval_mod.CircleEvaluation.init(domain, values);

    var interpolated_direct = try interpolateFromEvaluation(alloc, evaluation);
    defer interpolated_direct.deinit(alloc);

    var twiddle_tree = try twiddles_mod.precomputeM31(alloc, domain.half_coset);
    defer twiddles_mod.deinitM31(alloc, &twiddle_tree);
    var interpolated_with_twiddles = try interpolateFromEvaluationWithTwiddles(
        alloc,
        evaluation,
        .{
            .root_coset = twiddle_tree.root_coset,
            .twiddles = twiddle_tree.twiddles,
            .itwiddles = twiddle_tree.itwiddles,
        },
    );
    defer interpolated_with_twiddles.deinit(alloc);

    try std.testing.expectEqualSlices(
        M31,
        interpolated_direct.coefficients(),
        interpolated_with_twiddles.coefficients(),
    );
}
