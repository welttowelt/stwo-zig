const std = @import("std");
const builtin = @import("builtin");

pub const m31 = @import("m31.zig");
pub const cm31 = @import("cm31.zig");
pub const qm31 = @import("qm31.zig");

/// Inverts all elements in `column` using Montgomery's trick.
///
/// Preconditions:
/// - `dst.len >= column.len`
/// - all elements in `column` are non-zero.
///
/// Failure modes:
/// - Returns an error if any element inversion fails.
pub fn batchInverseInPlace(comptime F: type, column: []const F, dst: []F) !void {
    std.debug.assert(dst.len >= column.len);
    const n = column.len;

    if (comptime F == cm31.CM31 and builtin.cpu.arch == .aarch64 and builtin.zig_backend != .stage2_c) {
        if (n >= 32 and (n & 31) == 0) return batchInverseCM31Packed(column, dst, 32);
        if (n >= 16 and (n & 15) == 0) return batchInverseCM31Packed(column, dst, 16);
        if (n >= 8 and (n & 7) == 0) return batchInverseCM31Packed(column, dst, 8);
    }
    if (n > 8 and (n & 7) == 0) return batchInverseStriped(F, column, dst, 8);
    if (n > 4 and (n & 3) == 0) return batchInverseStriped(F, column, dst, 4);
    return batchInverseClassic(F, column, dst);
}

fn batchInverseStriped(
    comptime F: type,
    column: []const F,
    dst: []F,
    comptime width: usize,
) !void {
    const n = column.len;
    std.debug.assert(n > width and (n & (width - 1)) == 0);
    var cum_prod: [width]F = undefined;
    for (&cum_prod) |*v| v.* = F.one();

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const lane = i & (width - 1);
        cum_prod[lane] = cum_prod[lane].mul(column[i]);
        dst[i] = cum_prod[lane];
    }

    var tail_inverses: [width]F = undefined;
    try batchInverseClassic(F, dst[n - width .. n], tail_inverses[0..]);

    i = n;
    while (i > width) {
        i -= 1;
        const lane = i & (width - 1);
        dst[i] = dst[i - width].mul(tail_inverses[lane]);
        tail_inverses[lane] = tail_inverses[lane].mul(column[i]);
    }

    @memcpy(dst[0..width], tail_inverses[0..]);
}

const PackedCM31x4 = struct {
    a: m31.Vec4u32,
    b: m31.Vec4u32,
};

inline fn loadPackedCM31x4(ptr: [*]const cm31.CM31) PackedCM31x4 {
    comptime {
        std.debug.assert(@sizeOf(cm31.CM31) == 2 * @sizeOf(u32));
        std.debug.assert(@offsetOf(cm31.CM31, "a") == 0);
        std.debug.assert(@offsetOf(cm31.CM31, "b") == @sizeOf(u32));
    }
    const raw: *const [8]u32 = @ptrCast(ptr);
    const lo: m31.Vec4u32 = raw[0..4].*;
    const hi: m31.Vec4u32 = raw[4..8].*;
    return .{
        .a = @shuffle(u32, lo, hi, @Vector(4, i32){ 0, 2, -1, -3 }),
        .b = @shuffle(u32, lo, hi, @Vector(4, i32){ 1, 3, -2, -4 }),
    };
}

inline fn storePackedCM31x4(ptr: [*]cm31.CM31, value: PackedCM31x4) void {
    const lo = @shuffle(u32, value.a, value.b, @Vector(4, i32){ 0, -1, 1, -2 });
    const hi = @shuffle(u32, value.a, value.b, @Vector(4, i32){ 2, -3, 3, -4 });
    const raw: *[8]u32 = @ptrCast(ptr);
    raw[0..4].* = lo;
    raw[4..8].* = hi;
}

inline fn mulPackedCM31x4(lhs: PackedCM31x4, rhs: PackedCM31x4) PackedCM31x4 {
    const ac = m31.mulVec4(lhs.a, rhs.a);
    const bd = m31.mulVec4(lhs.b, rhs.b);
    const cross = m31.mulVec4(
        m31.addVec4(lhs.a, lhs.b),
        m31.addVec4(rhs.a, rhs.b),
    );
    return .{
        .a = m31.subVec4(ac, bd),
        .b = m31.subVec4(m31.subVec4(cross, ac), bd),
    };
}

/// Montgomery inversion with independent prefix chains packed across CM31
/// values. Each four-element group maps the real and imaginary coordinates to
/// AdvSIMD lanes, so one Karatsuba product advances four chains. Wider batches
/// interleave several vector chains to cover multiply latency; the measured
/// AArch64 optimum is capped at 32 elements to avoid register-spill growth.
fn batchInverseCM31Packed(
    column: []const cm31.CM31,
    dst: []cm31.CM31,
    comptime width: usize,
) !void {
    comptime std.debug.assert(width == 8 or width == 16 or width == 32);
    std.debug.assert(dst.len >= column.len and column.len >= width and (column.len & (width - 1)) == 0);
    const groups = width / 4;
    const one = PackedCM31x4{
        .a = @splat(1),
        .b = @splat(0),
    };
    var cumulative = [_]PackedCM31x4{one} ** groups;
    var base: usize = 0;
    while (base < column.len) : (base += width) {
        inline for (0..groups) |group| {
            cumulative[group] = mulPackedCM31x4(
                cumulative[group],
                loadPackedCM31x4(column.ptr + base + 4 * group),
            );
            storePackedCM31x4(dst.ptr + base + 4 * group, cumulative[group]);
        }
    }

    const tail_products: [width]cm31.CM31 = dst[column.len - width ..][0..width].*;
    var tail_inverses: [width]cm31.CM31 = undefined;
    try batchInverseClassic(cm31.CM31, &tail_products, &tail_inverses);
    var inverse: [groups]PackedCM31x4 = undefined;
    inline for (0..groups) |group| {
        inverse[group] = loadPackedCM31x4((&tail_inverses).ptr + 4 * group);
    }

    var block = column.len;
    while (block > width) {
        block -= width;
        inline for (0..groups) |group| {
            storePackedCM31x4(
                dst.ptr + block + 4 * group,
                mulPackedCM31x4(
                    loadPackedCM31x4(dst.ptr + block - width + 4 * group),
                    inverse[group],
                ),
            );
        }
        inline for (0..groups) |group| {
            inverse[group] = mulPackedCM31x4(
                inverse[group],
                loadPackedCM31x4(column.ptr + block + 4 * group),
            );
        }
    }
    inline for (0..groups) |group| {
        storePackedCM31x4(dst.ptr + 4 * group, inverse[group]);
    }
}

pub fn batchInverse(comptime F: type, allocator: std.mem.Allocator, column: []const F) ![]F {
    const out = try allocator.alloc(F, column.len);
    errdefer allocator.free(out);
    try batchInverseInPlace(F, column, out);
    return out;
}

pub fn batchInverseChunked(
    comptime F: type,
    column: []const F,
    dst: []F,
    chunk_size: usize,
) !void {
    std.debug.assert(chunk_size > 0);
    std.debug.assert(dst.len >= column.len);

    var start: usize = 0;
    while (start < column.len) : (start += chunk_size) {
        const end = @min(start + chunk_size, column.len);
        try batchInverseInPlace(F, column[start..end], dst[start..end]);
    }
}

fn batchInverseClassic(comptime F: type, column: []const F, dst: []F) !void {
    std.debug.assert(dst.len >= column.len);
    const n = column.len;
    if (n == 0) return;

    dst[0] = column[0];
    var i: usize = 1;
    while (i < n) : (i += 1) {
        dst[i] = dst[i - 1].mul(column[i]);
    }

    var curr_inverse = try dst[n - 1].inv();
    i = n;
    while (i > 1) {
        i -= 1;
        dst[i] = dst[i - 1].mul(curr_inverse);
        curr_inverse = curr_inverse.mul(column[i]);
    }
    dst[0] = curr_inverse;
}

fn randNonZeroM31(rng: std.Random) m31.M31 {
    while (true) {
        const x = rng.int(u32) & m31.Modulus;
        if (x != m31.Modulus and x != 0) return m31.M31.fromCanonical(x);
    }
}

test "fields: batch inverse matches scalar inverse (m31)" {
    var prng = std.Random.DefaultPrng.init(0x91f1_7244_6800_5c3a);
    const rng = prng.random();

    var elements: [16]m31.M31 = undefined;
    for (&elements) |*e| e.* = randNonZeroM31(rng);

    const actual = try batchInverse(m31.M31, std.testing.allocator, elements[0..]);
    defer std.testing.allocator.free(actual);

    for (elements, 0..) |e, i| {
        try std.testing.expect(actual[i].eql(try e.inv()));
    }
}

test "fields: batch inverse chunked matches batch inverse (m31)" {
    var prng = std.Random.DefaultPrng.init(0x32c8_4457_f1ab_9920);
    const rng = prng.random();

    var elements: [16]m31.M31 = undefined;
    for (&elements) |*e| e.* = randNonZeroM31(rng);

    const expected = try batchInverse(m31.M31, std.testing.allocator, elements[0..]);
    defer std.testing.allocator.free(expected);

    var actual: [16]m31.M31 = undefined;
    try batchInverseChunked(m31.M31, elements[0..], actual[0..], 4);

    for (expected, 0..) |e, i| {
        try std.testing.expect(actual[i].eql(e));
    }
}
