const fft = @import("stwo_core").fft;
const m31 = @import("stwo_core").fields.m31;
const domain_mod = @import("stwo_core").poly.circle.domain;
const fft_kernels = @import("fft_kernels.zig");
const twiddles_mod = @import("../twiddles.zig");

const M31 = m31.M31;
const CircleDomain = domain_mod.CircleDomain;
const M31TwiddleTree = twiddles_mod.TwiddleTree([]const M31);

pub const PolyError = error{
    InvalidLength,
    InvalidLogSize,
    NonBaseEvaluation,
    SingularSystem,
};

/// Evaluates one prepared coefficient buffer in place.
///
/// Preconditions:
/// - `values.len == domain.size()`.
/// - `twiddle_tree.root_coset` matches `domain`.
/// Evaluates a coefficient buffer whose upper half is known to be zero —
/// the 2x-blowup extension case. The first FFT layer pairs each lower-half
/// element with a zero (`v ± 0·t = v`), so it degenerates to duplicating the
/// lower half; the remaining layers are unchanged. Callers skip both the
/// upper-half zero fill and the first layer's butterflies. Bit-identical to
/// zero-padding `values` and calling `evaluateBufferWithTwiddles`.
pub fn evaluateExtensionBufferWithTwiddles(
    values: []M31,
    domain: CircleDomain,
    twiddle_tree: M31TwiddleTree,
) void {
    const log_size = domain.logSize();
    if (log_size <= 2) {
        const half = values.len / 2;
        @memset(values[half..], M31.zero());
        evaluateBufferWithTwiddles(values, domain, twiddle_tree);
        return;
    }
    const half = values.len / 2;
    @memcpy(values[half..], values[0..half]);
    evaluateBufferTailLayers(values, domain, twiddle_tree, 1);
}

pub fn evaluateBufferWithTwiddles(
    values: []M31,
    domain: CircleDomain,
    twiddle_tree: M31TwiddleTree,
) void {
    const log_size = domain.logSize();
    if (log_size == 1) {
        var v0 = values[0];
        var v1 = values[1];
        fft.butterfly(M31, &v0, &v1, domain.half_coset.initial.y);
        values[0] = v0;
        values[1] = v1;
        return;
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
        return;
    }

    evaluateBufferTailLayers(values, domain, twiddle_tree, 0);
}

/// Runs the forward FFT layer cascade, skipping the first `skip_layers`
/// (largest-block) layers. `skip_layers = 0` is the full evaluation.
fn evaluateBufferTailLayers(
    values: []M31,
    domain: CircleDomain,
    twiddle_tree: M31TwiddleTree,
    skip_layers: u32,
) void {
    const line_log_size = domain.half_coset.logSize();
    const twiddle_len = twiddle_tree.twiddles.len;
    const fuse_bottom = line_log_size >= 3;
    var skipped: u32 = 0;
    var layer_idx: u32 = line_log_size;
    const stop: u32 = if (fuse_bottom) 2 else 0;
    while (layer_idx > stop) {
        layer_idx -= 1;
        const depth = line_log_size - 1 - layer_idx;
        if (skipped < skip_layers) {
            skipped += 1;
            continue;
        }
        const len = @as(usize, 1) << @intCast(depth);
        const start = twiddle_len - (len * 2);
        const layer_twiddles = twiddle_tree.twiddles[start .. twiddle_len - len];
        for (layer_twiddles, 0..) |twid, h| {
            fft_kernels.fftLayerLoopForwardM31(values, @intCast(layer_idx + 1), h, twid);
        }
    }

    if (fuse_bottom) {
        const len2 = @as(usize, 1) << @intCast(line_log_size - 2);
        const t2s = twiddle_tree.twiddles[twiddle_len - (len2 * 2) .. twiddle_len - len2];
        const len1 = @as(usize, 1) << @intCast(line_log_size - 1);
        const t01s = twiddle_tree.twiddles[twiddle_len - (len1 * 2) .. twiddle_len - len1];
        fft_kernels.fftBottomThreeLayersForwardM31(values, t2s, t01s);
        return;
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
}

/// Interpolates one evaluation buffer into coefficients in place.
pub fn interpolateIntoBufferWithTwiddles(
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
    const fuse_bottom = line_log_size >= 3;
    var layer_idx: u32 = 0;
    if (fuse_bottom) {
        const len2 = @as(usize, 1) << @intCast(line_log_size - 2);
        const it2s = twiddle_tree.itwiddles[itwiddle_len - (len2 * 2) .. itwiddle_len - len2];
        const len1 = @as(usize, 1) << @intCast(line_log_size - 1);
        const it01s = twiddle_tree.itwiddles[itwiddle_len - (len1 * 2) .. itwiddle_len - len1];
        fft_kernels.fftBottomThreeLayersInverseM31(coeffs, it2s, it01s);
        layer_idx = 2;
    } else {
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
    }

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

/// Interpolates a batch in place while sharing twiddle traversal.
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
    const fuse_bottom = line_log_size >= 3;
    var layer_idx: u32 = 0;
    if (fuse_bottom) {
        const len2 = @as(usize, 1) << @intCast(line_log_size - 2);
        const it2s = twiddle_tree.itwiddles[itwiddle_len - (len2 * 2) .. itwiddle_len - len2];
        const len1 = @as(usize, 1) << @intCast(line_log_size - 1);
        const it01s = twiddle_tree.itwiddles[itwiddle_len - (len1 * 2) .. itwiddle_len - len1];
        for (coeffs_batch) |coeffs| {
            fft_kernels.fftBottomThreeLayersInverseM31(coeffs, it2s, it01s);
        }
        layer_idx = 2;
    } else {
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
    }

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

/// Evaluates a batch in place while sharing twiddle traversal.
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

    try evaluateBuffersTailLayers(values_batch, domain, twiddle_tree, 0);
}

/// Batched forward evaluation for buffers whose upper halves are known to be
/// zero (2x-blowup extension). Duplicates each lower half in place of the
/// first (degenerate) layer, then runs the remaining cascade. Bit-identical
/// to zero-filling the upper halves and calling
/// `evaluateBuffersWithTwiddles`.
pub fn evaluateExtensionBuffersWithTwiddles(
    values_batch: []const []M31,
    domain: CircleDomain,
    twiddle_tree: M31TwiddleTree,
) PolyError!void {
    if (!domain.half_coset.isDoublingOf(twiddle_tree.root_coset)) return PolyError.InvalidLogSize;
    if (domain.logSize() <= 2) {
        for (values_batch) |values| {
            const half = values.len / 2;
            @memset(values[half..], M31.zero());
        }
        return evaluateBuffersWithTwiddles(values_batch, domain, twiddle_tree);
    }
    for (values_batch) |values| {
        const half = values.len / 2;
        @memcpy(values[half..], values[0..half]);
    }
    try evaluateBuffersTailLayers(values_batch, domain, twiddle_tree, 1);
}

fn evaluateBuffersTailLayers(
    values_batch: []const []M31,
    domain: CircleDomain,
    twiddle_tree: M31TwiddleTree,
    skip_layers: u32,
) PolyError!void {
    const line_log_size = domain.half_coset.logSize();
    const twiddle_len = twiddle_tree.twiddles.len;
    const fuse_bottom = line_log_size >= 3;
    var skipped: u32 = 0;
    var layer_idx: u32 = line_log_size;
    const stop: u32 = if (fuse_bottom) 2 else 0;
    while (layer_idx > stop) {
        layer_idx -= 1;
        const depth = line_log_size - 1 - layer_idx;
        if (skipped < skip_layers) {
            skipped += 1;
            continue;
        }
        const len = @as(usize, 1) << @intCast(depth);
        const start = twiddle_len - (len * 2);
        const layer_twiddles = twiddle_tree.twiddles[start .. twiddle_len - len];
        for (layer_twiddles, 0..) |twid, h| {
            for (values_batch) |values| {
                fft_kernels.fftLayerLoopForwardM31(values, @intCast(layer_idx + 1), h, twid);
            }
        }
    }

    if (fuse_bottom) {
        const len2 = @as(usize, 1) << @intCast(line_log_size - 2);
        const t2s = twiddle_tree.twiddles[twiddle_len - (len2 * 2) .. twiddle_len - len2];
        const len1 = @as(usize, 1) << @intCast(line_log_size - 1);
        const t01s = twiddle_tree.twiddles[twiddle_len - (len1 * 2) .. twiddle_len - len1];
        for (values_batch) |values| {
            fft_kernels.fftBottomThreeLayersForwardM31(values, t2s, t01s);
        }
        return;
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
