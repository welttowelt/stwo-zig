const std = @import("std");
const m31 = @import("../../../core/fields/m31.zig");

const M31 = m31.M31;

/// Applies one forward FFT layer block with hardware-native packed lanes.
pub inline fn fftLayerLoopForwardM31(
    values: []M31,
    i: u32,
    h: usize,
    twid: M31,
) void {
    const half_block: usize = @as(usize, 1) << @intCast(i);
    const block_start = h << @intCast(i + 1);
    var lhs = values.ptr + block_start;
    var rhs = lhs + half_block;
    var remaining = half_block;

    // Hardware-native SIMD path with interleaved pipeline execution.
    // By loading and multiplying multiple pairs before storing results,
    // the CPU's out-of-order execution can pipeline independent multiplies.
    const PW = m31.PACK_WIDTH;
    const twid_packed: m31.PackedM31 = @splat(twid.v);

    // 4-way interleaved: process 4 butterfly pairs simultaneously.
    const PW4 = PW * 4;
    while (remaining >= PW4) : (remaining -= PW4) {
        // Load all 4 pairs.
        const v0a = m31.loadPacked(lhs);
        const v1a = m31.loadPacked(rhs);
        const v0b = m31.loadPacked(lhs + PW);
        const v1b = m31.loadPacked(rhs + PW);
        const v0c = m31.loadPacked(lhs + PW * 2);
        const v1c = m31.loadPacked(rhs + PW * 2);
        const v0d = m31.loadPacked(lhs + PW * 3);
        const v1d = m31.loadPacked(rhs + PW * 3);

        // Issue all 4 multiplications (pipeline-friendly: independent operations).
        const ma = m31.mulPacked(v1a, twid_packed);
        const mb = m31.mulPacked(v1b, twid_packed);
        const mc = m31.mulPacked(v1c, twid_packed);
        const md = m31.mulPacked(v1d, twid_packed);

        // Store results (by now the multiplies have completed).
        m31.storePacked(lhs, m31.addPacked(v0a, ma));
        m31.storePacked(rhs, m31.subPacked(v0a, ma));
        m31.storePacked(lhs + PW, m31.addPacked(v0b, mb));
        m31.storePacked(rhs + PW, m31.subPacked(v0b, mb));
        m31.storePacked(lhs + PW * 2, m31.addPacked(v0c, mc));
        m31.storePacked(rhs + PW * 2, m31.subPacked(v0c, mc));
        m31.storePacked(lhs + PW * 3, m31.addPacked(v0d, md));
        m31.storePacked(rhs + PW * 3, m31.subPacked(v0d, md));

        lhs += PW4;
        rhs += PW4;
    }
    // 2-way interleaved fallback for remaining >= 2 packed widths.
    const PW2 = PW * 2;
    while (remaining >= PW2) : (remaining -= PW2) {
        const v0a = m31.loadPacked(lhs);
        const v1a = m31.loadPacked(rhs);
        const v0b = m31.loadPacked(lhs + PW);
        const v1b = m31.loadPacked(rhs + PW);

        const ma = m31.mulPacked(v1a, twid_packed);
        const mb = m31.mulPacked(v1b, twid_packed);

        m31.storePacked(lhs, m31.addPacked(v0a, ma));
        m31.storePacked(rhs, m31.subPacked(v0a, ma));
        m31.storePacked(lhs + PW, m31.addPacked(v0b, mb));
        m31.storePacked(rhs + PW, m31.subPacked(v0b, mb));

        lhs += PW2;
        rhs += PW2;
    }
    // Single packed-width fallback.
    while (remaining >= PW) : (remaining -= PW) {
        m31.butterflyPacked(lhs, rhs, twid_packed);
        lhs += PW;
        rhs += PW;
    }
    // 4-lane SIMD for remainder.
    const VW = m31.VEC_WIDTH;
    const twid_vec: m31.Vec4u32 = @splat(twid.v);
    while (remaining >= VW) : (remaining -= VW) {
        m31.butterflyVec4(lhs, rhs, twid_vec);
        lhs += VW;
        rhs += VW;
    }
    // Scalar tail.
    while (remaining != 0) : (remaining -= 1) {
        const v0 = lhs[0];
        const v1 = rhs[0];
        const mul = v1.mul(twid);
        lhs[0] = v0.add(mul);
        rhs[0] = v0.sub(mul);
        lhs += 1;
        rhs += 1;
    }
}

/// Applies one adjacent forward butterfly.
pub inline fn fftPairForwardM31(values: []M31, h: usize, twid: M31) void {
    const idx0 = h << 1;
    const idx1 = idx0 + 1;
    const v0 = values[idx0];
    const v1 = values[idx1];
    const mul = v1.mul(twid);
    values[idx0] = v0.add(mul);
    values[idx1] = v0.sub(mul);
}

/// Applies one inverse FFT layer block with hardware-native packed lanes.
pub inline fn fftLayerLoopInverseM31(
    values: []M31,
    i: u32,
    h: usize,
    itwid: M31,
) void {
    const half_block: usize = @as(usize, 1) << @intCast(i);
    const block_start = h << @intCast(i + 1);
    var lhs = values.ptr + block_start;
    var rhs = lhs + half_block;
    var remaining = half_block;

    // Hardware-native SIMD path with interleaved pipeline execution.
    // By loading and computing multiple pairs before storing results,
    // the CPU's out-of-order execution can pipeline independent multiplies.
    const PW = m31.PACK_WIDTH;
    const itwid_packed: m31.PackedM31 = @splat(itwid.v);

    // 4-way interleaved: process 4 inverse butterfly pairs simultaneously.
    const PW4 = PW * 4;
    while (remaining >= PW4) : (remaining -= PW4) {
        // Load all 4 pairs.
        const v0a = m31.loadPacked(lhs);
        const v1a = m31.loadPacked(rhs);
        const v0b = m31.loadPacked(lhs + PW);
        const v1b = m31.loadPacked(rhs + PW);
        const v0c = m31.loadPacked(lhs + PW * 2);
        const v1c = m31.loadPacked(rhs + PW * 2);
        const v0d = m31.loadPacked(lhs + PW * 3);
        const v1d = m31.loadPacked(rhs + PW * 3);

        // Compute sums and diffs for all 4 pairs.
        const sum_a = m31.addPacked(v0a, v1a);
        const sum_b = m31.addPacked(v0b, v1b);
        const sum_c = m31.addPacked(v0c, v1c);
        const sum_d = m31.addPacked(v0d, v1d);
        const diff_a = m31.subPacked(v0a, v1a);
        const diff_b = m31.subPacked(v0b, v1b);
        const diff_c = m31.subPacked(v0c, v1c);
        const diff_d = m31.subPacked(v0d, v1d);

        // Issue all 4 multiplications (pipeline-friendly: independent operations).
        const ma = m31.mulPacked(diff_a, itwid_packed);
        const mb = m31.mulPacked(diff_b, itwid_packed);
        const mc = m31.mulPacked(diff_c, itwid_packed);
        const md = m31.mulPacked(diff_d, itwid_packed);

        // Store results (by now the multiplies have completed).
        m31.storePacked(lhs, sum_a);
        m31.storePacked(rhs, ma);
        m31.storePacked(lhs + PW, sum_b);
        m31.storePacked(rhs + PW, mb);
        m31.storePacked(lhs + PW * 2, sum_c);
        m31.storePacked(rhs + PW * 2, mc);
        m31.storePacked(lhs + PW * 3, sum_d);
        m31.storePacked(rhs + PW * 3, md);

        lhs += PW4;
        rhs += PW4;
    }
    // 2-way interleaved fallback for remaining >= 2 packed widths.
    const PW2 = PW * 2;
    while (remaining >= PW2) : (remaining -= PW2) {
        const v0a = m31.loadPacked(lhs);
        const v1a = m31.loadPacked(rhs);
        const v0b = m31.loadPacked(lhs + PW);
        const v1b = m31.loadPacked(rhs + PW);

        const sum_a = m31.addPacked(v0a, v1a);
        const sum_b = m31.addPacked(v0b, v1b);
        const diff_a = m31.subPacked(v0a, v1a);
        const diff_b = m31.subPacked(v0b, v1b);

        const ma = m31.mulPacked(diff_a, itwid_packed);
        const mb = m31.mulPacked(diff_b, itwid_packed);

        m31.storePacked(lhs, sum_a);
        m31.storePacked(rhs, ma);
        m31.storePacked(lhs + PW, sum_b);
        m31.storePacked(rhs + PW, mb);

        lhs += PW2;
        rhs += PW2;
    }
    // Single packed-width fallback.
    while (remaining >= PW) : (remaining -= PW) {
        m31.ibutterflyPacked(lhs, rhs, itwid_packed);
        lhs += PW;
        rhs += PW;
    }
    // 4-lane SIMD for remainder.
    const VW = m31.VEC_WIDTH;
    const itwid_vec: m31.Vec4u32 = @splat(itwid.v);
    while (remaining >= VW) : (remaining -= VW) {
        m31.ibutterflyVec4(lhs, rhs, itwid_vec);
        lhs += VW;
        rhs += VW;
    }
    // Scalar tail.
    while (remaining != 0) : (remaining -= 1) {
        const v0 = lhs[0];
        const v1 = rhs[0];
        lhs[0] = v0.add(v1);
        rhs[0] = v0.sub(v1).mul(itwid);
        lhs += 1;
        rhs += 1;
    }
}

/// Applies one adjacent inverse butterfly.
pub inline fn fftPairInverseM31(values: []M31, h: usize, itwid: M31) void {
    const idx0 = h << 1;
    const idx1 = idx0 + 1;
    const v0 = values[idx0];
    const v1 = values[idx1];
    values[idx0] = v0.add(v1);
    values[idx1] = v0.sub(v1).mul(itwid);
}

test "circle FFT layer kernels match scalar butterfly laws across lane regimes" {
    const allocator = std.testing.allocator;
    const twid = M31.fromCanonical(1_234_567);
    const itwid = M31.fromCanonical(7_654_321);

    var log_half_block: u32 = 0;
    while (log_half_block <= 9) : (log_half_block += 1) {
        const half_block = @as(usize, 1) << @intCast(log_half_block);
        const block_start = half_block * 2;
        const values_len = half_block * 4;
        const before = try allocator.alloc(M31, values_len);
        defer allocator.free(before);
        for (before, 0..) |*value, index| {
            value.* = M31.fromCanonical(@intCast((index * 1_048_583 + 97) % m31.Modulus));
        }

        const forward = try allocator.dupe(M31, before);
        defer allocator.free(forward);
        fftLayerLoopForwardM31(forward, log_half_block, 1, twid);
        for (0..values_len) |index| {
            const expected = if (index < block_start or index >= block_start + half_block * 2)
                before[index]
            else if (index < block_start + half_block)
                before[index].add(before[index + half_block].mul(twid))
            else
                before[index - half_block].sub(before[index].mul(twid));
            try std.testing.expect(forward[index].eql(expected));
        }

        const inverse = try allocator.dupe(M31, before);
        defer allocator.free(inverse);
        fftLayerLoopInverseM31(inverse, log_half_block, 1, itwid);
        for (0..values_len) |index| {
            const expected = if (index < block_start or index >= block_start + half_block * 2)
                before[index]
            else if (index < block_start + half_block)
                before[index].add(before[index + half_block])
            else
                before[index - half_block].sub(before[index]).mul(itwid);
            try std.testing.expect(inverse[index].eql(expected));
        }
    }
}

test "circle FFT pair kernels match scalar butterfly laws" {
    const twid = M31.fromCanonical(12_345);
    const itwid = M31.fromCanonical(67_890);
    const before = [_]M31{
        M31.fromCanonical(101),
        M31.fromCanonical(202),
        M31.fromCanonical(303),
        M31.fromCanonical(404),
    };

    var forward = before;
    fftPairForwardM31(&forward, 1, twid);
    try std.testing.expect(forward[0].eql(before[0]));
    try std.testing.expect(forward[1].eql(before[1]));
    try std.testing.expect(forward[2].eql(before[2].add(before[3].mul(twid))));
    try std.testing.expect(forward[3].eql(before[2].sub(before[3].mul(twid))));

    var inverse = before;
    fftPairInverseM31(&inverse, 1, itwid);
    try std.testing.expect(inverse[0].eql(before[0]));
    try std.testing.expect(inverse[1].eql(before[1]));
    try std.testing.expect(inverse[2].eql(before[2].add(before[3])));
    try std.testing.expect(inverse[3].eql(before[2].sub(before[3]).mul(itwid)));
}
