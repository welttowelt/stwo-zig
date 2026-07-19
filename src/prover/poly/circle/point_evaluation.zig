const std = @import("std");
const circle = @import("stwo_core").circle;
const m31 = @import("stwo_core").fields.m31;
const qm31 = @import("stwo_core").fields.qm31;

const M31 = m31.M31;
const QM31 = qm31.QM31;
const CirclePointQM31 = circle.CirclePointQM31;

/// Evaluates circle-basis coefficients using precomputed point factors.
///
/// The carry-style reduction preserves the recursive evaluator's left/right
/// merge order while using bounded stack storage and no recursion.
pub inline fn evalAtPointIterative(
    coeffs: []const M31,
    factors: []const QM31,
    log_size: u32,
) QM31 {
    std.debug.assert(coeffs.len == (@as(usize, 1) << @intCast(log_size)));
    std.debug.assert(factors.len == log_size);

    if (log_size == 0) return QM31.fromBase(coeffs[0]);

    var pending: [circle.M31_CIRCLE_LOG_ORDER + 1]QM31 = undefined;

    for (coeffs, 0..) |coeff, coeff_idx| {
        var value = QM31.fromBase(coeff);
        var level: usize = @as(usize, @intCast(@ctz(~coeff_idx)));
        if (level > @as(usize, @intCast(log_size))) level = @as(usize, @intCast(log_size));
        var merge_level: usize = 0;
        while (merge_level < level) : (merge_level += 1) {
            value = pending[merge_level].add(value.mul(factors[merge_level]));
        }
        pending[level] = value;
    }

    return pending[log_size];
}

/// Fills the circle-basis factors for one secure-field point.
pub fn fillEvalFactorsForPoint(
    point: CirclePointQM31,
    log_size: u32,
    out: *[circle.M31_CIRCLE_LOG_ORDER]QM31,
) []const QM31 {
    fillEvalFactors(point, log_size, out);
    return out[0..log_size];
}

/// Fills point-major factors after applying the requested circle folds.
pub fn fillEvalFactorsForPointsFolded(
    points: []const CirclePointQM31,
    fold_count: u32,
    log_size: u32,
    out: []QM31,
) void {
    std.debug.assert(log_size == 0 or out.len == points.len * log_size);
    if (log_size == 0) return;

    var at: usize = 0;
    var factors: [circle.M31_CIRCLE_LOG_ORDER]QM31 = undefined;
    for (points) |point| {
        const folded_point = if (fold_count == 0) point else repeatedDoubleOnCircleQM31(point, fold_count);
        fillEvalFactors(folded_point, log_size, &factors);
        @memcpy(out[at .. at + log_size], factors[0..log_size]);
        at += log_size;
    }
}

/// Applies the circle doubling map exactly `n` times in the secure field.
pub inline fn repeatedDoubleOnCircleQM31(point: CirclePointQM31, n: u32) CirclePointQM31 {
    var x = point.x;
    var y = point.y;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const xx = x.square();
        const xy = x.mul(y);
        x = xx.add(xx).sub(QM31.one());
        y = xy.add(xy);
    }
    return .{ .x = x, .y = y };
}

inline fn fillEvalFactors(
    point: CirclePointQM31,
    log_size: u32,
    out: *[circle.M31_CIRCLE_LOG_ORDER]QM31,
) void {
    const max_log_size = circle.M31_CIRCLE_LOG_ORDER;
    std.debug.assert(log_size <= max_log_size);
    if (log_size == 0) return;

    out[0] = point.y;
    if (log_size > 1) {
        var x = point.x;
        out[1] = x;
        var bit: u32 = 2;
        while (bit < log_size) : (bit += 1) {
            x = circle.CirclePoint(QM31).doubleX(x);
            out[bit] = x;
        }
    }
}

fn evalAtPointRecursive(
    coeffs: []const M31,
    factors: []const QM31,
    bits_left: u32,
) QM31 {
    std.debug.assert(coeffs.len == (@as(usize, 1) << @intCast(bits_left)));
    if (bits_left == 0) return QM31.fromBase(coeffs[0]);

    const mid = coeffs.len / 2;
    const left = evalAtPointRecursive(coeffs[0..mid], factors, bits_left - 1);
    const right = evalAtPointRecursive(coeffs[mid..], factors, bits_left - 1);
    return left.add(right.mul(factors[bits_left - 1]));
}

fn evalAtPointReference(
    coeffs: []const M31,
    log_size: u32,
    point: CirclePointQM31,
) QM31 {
    if (log_size == 0) return QM31.fromBase(coeffs[0]);

    var mappings: [circle.M31_CIRCLE_LOG_ORDER]QM31 = undefined;
    mappings[log_size - 1] = point.y;
    if (log_size > 1) {
        var x = point.x;
        var i: usize = log_size - 1;
        while (i > 0) {
            i -= 1;
            mappings[i] = x;
            x = circle.CirclePoint(QM31).doubleX(x);
        }
    }

    var acc = QM31.zero();
    for (coeffs, 0..) |coeff, index| {
        var twiddle = QM31.one();
        var bit_index: usize = 0;
        var bit_words = index;
        while (bit_index < log_size and bit_words != 0) : (bit_index += 1) {
            if ((bit_words & 1) == 1) {
                const mapping_index = log_size - 1 - bit_index;
                twiddle = twiddle.mul(mappings[mapping_index]);
            }
            bit_words >>= 1;
        }
        acc = acc.add(QM31.fromBase(coeff).mul(twiddle));
    }
    return acc;
}

test "circle point evaluation matches the monomial reference" {
    const allocator = std.testing.allocator;
    const log_sizes = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8 };

    var prng = std.Random.DefaultPrng.init(0x97d8_114a_3f61_55cc);
    const random = prng.random();

    for (log_sizes) |log_size| {
        const coefficient_count = @as(usize, 1) << @intCast(log_size);
        const coeffs = try allocator.alloc(M31, coefficient_count);
        defer allocator.free(coeffs);
        for (coeffs) |*coeff| {
            coeff.* = M31.fromCanonical(random.intRangeLessThan(u32, 0, m31.Modulus));
        }

        var sample_index: usize = 0;
        while (sample_index < 24) : (sample_index += 1) {
            const point = circle.SECURE_FIELD_CIRCLE_GEN.mul(@as(u64, random.int(u32)) + 11);
            var factor_storage: [circle.M31_CIRCLE_LOG_ORDER]QM31 = undefined;
            const factors = fillEvalFactorsForPoint(point, log_size, &factor_storage);
            const iterative = evalAtPointIterative(coeffs, factors, log_size);
            const reference = evalAtPointReference(coeffs, log_size, point);
            try std.testing.expect(iterative.eql(reference));
        }
    }
}

test "circle point evaluation iterative reduction matches recursive oracle" {
    const allocator = std.testing.allocator;
    const log_sizes = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8 };

    var prng = std.Random.DefaultPrng.init(0x8a3f_77de_13cc_59e1);
    const random = prng.random();

    for (log_sizes) |log_size| {
        const coefficient_count = @as(usize, 1) << @intCast(log_size);
        const coeffs = try allocator.alloc(M31, coefficient_count);
        defer allocator.free(coeffs);
        for (coeffs) |*coeff| {
            coeff.* = M31.fromCanonical(random.intRangeLessThan(u32, 0, m31.Modulus));
        }

        var sample_index: usize = 0;
        while (sample_index < 24) : (sample_index += 1) {
            const point = circle.SECURE_FIELD_CIRCLE_GEN.mul(@as(u64, random.int(u32)) + 29);
            var factor_storage: [circle.M31_CIRCLE_LOG_ORDER]QM31 = undefined;
            const factors = fillEvalFactorsForPoint(point, log_size, &factor_storage);

            const iterative = evalAtPointIterative(coeffs, factors, log_size);
            const recursive = evalAtPointRecursive(coeffs, factors, log_size);
            try std.testing.expect(iterative.eql(recursive));
        }
    }
}
