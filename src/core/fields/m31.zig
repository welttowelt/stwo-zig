const std = @import("std");

/// The prime modulus p = 2^31 - 1.
pub const Modulus: u32 = 0x7fffffff;

/// An element of F_p where p = 2^31 - 1.
///
/// Representation invariant: `v` is always canonical in `[0, p-1]`.
pub const M31 = struct {
    v: u32,

    pub const Error = error{
        DivisionByZero,
        NonCanonical,
    };

    pub inline fn zero() M31 {
        return .{ .v = 0 };
    }

    pub inline fn one() M31 {
        return .{ .v = 1 };
    }

    /// Construct from a canonical representative in `[0, p-1]`.
    pub inline fn fromCanonical(x: u32) M31 {
        std.debug.assert(x < Modulus);
        return .{ .v = x };
    }

    /// Reduce an unsigned integer into F_p.
    pub inline fn fromU64(x: u64) M31 {
        return .{ .v = reduce64(x) };
    }

    pub inline fn isZero(self: M31) bool {
        return self.v == 0;
    }

    pub inline fn isOne(self: M31) bool {
        return self.v == 1;
    }

    pub inline fn eql(a: M31, b: M31) bool {
        return a.v == b.v;
    }

    pub inline fn add(a: M31, b: M31) M31 {
        var s: u32 = a.v + b.v;
        if (s >= Modulus) s -= Modulus;
        return .{ .v = s };
    }

    pub inline fn sub(a: M31, b: M31) M31 {
        if (a.v >= b.v) {
            return .{ .v = a.v - b.v };
        }
        return .{ .v = (a.v + Modulus) - b.v };
    }

    pub inline fn neg(a: M31) M31 {
        if (a.v == 0) return a;
        return .{ .v = Modulus - a.v };
    }

    pub inline fn complexConjugate(self: M31) M31 {
        return self;
    }

    pub inline fn mul(a: M31, b: M31) M31 {
        const prod: u64 = @as(u64, a.v) * @as(u64, b.v);
        return .{ .v = reduce64(prod) };
    }

    pub inline fn square(a: M31) M31 {
        return mul(a, a);
    }

    pub fn pow(a: M31, exponent: u64) M31 {
        var base = a;
        var e = exponent;
        var acc = M31.one();
        while (e != 0) : (e >>= 1) {
            if ((e & 1) != 0) acc = acc.mul(base);
            base = base.square();
        }
        return acc;
    }

    /// Multiplicative inverse.
    ///
    /// Errors if `self == 0`.
    pub fn inv(self: M31) Error!M31 {
        if (self.isZero()) return Error.DivisionByZero;
        return self.invUncheckedNonZero();
    }

    /// Multiplicative inverse for known non-zero elements.
    ///
    /// Preconditions:
    /// - `self != 0`.
    pub inline fn invUncheckedNonZero(self: M31) M31 {
        std.debug.assert(!self.isZero());
        return powPMinus2(self);
    }

    pub fn div(a: M31, b: M31) Error!M31 {
        const inv_b = try b.inv();
        return a.mul(inv_b);
    }

    pub inline fn toU32(self: M31) u32 {
        return self.v;
    }

    pub fn toBytesLe(self: M31) [4]u8 {
        const x = self.v;
        return .{
            @intCast(x & 0xff),
            @intCast((x >> 8) & 0xff),
            @intCast((x >> 16) & 0xff),
            @intCast((x >> 24) & 0xff),
        };
    }

    pub fn fromBytesLe(bytes: [4]u8) Error!M31 {
        const x: u32 = (@as(u32, bytes[0])) |
            (@as(u32, bytes[1]) << 8) |
            (@as(u32, bytes[2]) << 16) |
            (@as(u32, bytes[3]) << 24);
        if (x >= Modulus) return Error.NonCanonical;
        return M31.fromCanonical(x);
    }

    /// Display helper for debugging.
    pub fn format(
        self: M31,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{}", .{self.v});
    }
};

/// Reduce a 64-bit integer modulo p = 2^31 - 1.
///
/// For x <= (p-1)^2 < 2^62, two Mersenne folds suffice.
fn reduce64(x: u64) u32 {
    const p: u64 = Modulus;
    var t: u64 = (x & p) + (x >> 31);
    t = (t & p) + (t >> 31);

    const r: u32 = @intCast(t);
    // t is in [0, p+1].
    if (r == Modulus) return 0;
    if (r > Modulus) return r - Modulus;
    return r;
}

// ---------------------------------------------------------------
// SIMD vectorized M31 operations (4-lane)
// ---------------------------------------------------------------

pub const VEC_WIDTH: usize = 4;
pub const Vec4u32 = @Vector(VEC_WIDTH, u32);
pub const Vec4u64 = @Vector(VEC_WIDTH, u64);
const P_VEC: Vec4u32 = @splat(Modulus);

/// Load 4 M31 values from a pointer.
pub inline fn loadVec4(ptr: [*]const M31) Vec4u32 {
    const raw: *const [VEC_WIDTH]u32 = @ptrCast(ptr);
    return raw.*;
}

/// Store 4 M31 values to a pointer.
pub inline fn storeVec4(ptr: [*]M31, v: Vec4u32) void {
    const raw: *[VEC_WIDTH]u32 = @ptrCast(ptr);
    raw.* = v;
}

/// Vectorized M31 addition: (a + b) mod p, 4 lanes.
pub inline fn addVec4(a: Vec4u32, b: Vec4u32) Vec4u32 {
    const sum = a +% b;
    const geq_p = sum >= P_VEC;
    return @select(u32, geq_p, sum -% P_VEC, sum);
}

/// Vectorized M31 subtraction: (a - b) mod p, 4 lanes.
pub inline fn subVec4(a: Vec4u32, b: Vec4u32) Vec4u32 {
    const lt = a < b;
    // If a < b, result = a + p - b; else result = a - b.
    return @select(u32, lt, (a +% P_VEC) -% b, a -% b);
}

/// Vectorized M31 multiplication: (a * b) mod p, 4 lanes.
/// Uses 64-bit intermediate products with Mersenne reduction.
pub inline fn mulVec4(a: Vec4u32, b: Vec4u32) Vec4u32 {
    const a64: Vec4u64 = a;
    const b64: Vec4u64 = b;
    const prod = a64 * b64;
    return reduceVec4(prod);
}

/// Vectorized Mersenne reduction: x mod (2^31 - 1), 4 lanes.
/// Two rounds of: t = (x & p) + (x >> 31).
inline fn reduceVec4(x: Vec4u64) Vec4u32 {
    const p64: Vec4u64 = @splat(@as(u64, Modulus));

    // Round 1
    var t = (x & p64) + (x >> @splat(@as(u6, 31)));
    // Round 2
    t = (t & p64) + (t >> @splat(@as(u6, 31)));

    const r: Vec4u32 = @truncate(t);
    // Conditional: if r == p -> 0, if r > p -> r - p, else r.
    const is_p = r == P_VEC;
    const gt_p = r > P_VEC;
    const adjusted = @select(u32, gt_p, r -% P_VEC, r);
    return @select(u32, is_p, @as(Vec4u32, @splat(0)), adjusted);
}

/// Vectorized butterfly: forward FFT.
/// lhs[i] = lhs[i] + rhs[i]*twid, rhs[i] = lhs[i] - rhs[i]*twid.
pub inline fn butterflyVec4(lhs: [*]M31, rhs: [*]M31, twid: Vec4u32) void {
    const v0 = loadVec4(lhs);
    const v1 = loadVec4(rhs);
    const m = mulVec4(v1, twid);
    storeVec4(lhs, addVec4(v0, m));
    storeVec4(rhs, subVec4(v0, m));
}

/// Vectorized inverse butterfly: inverse FFT.
/// lhs[i] = lhs[i] + rhs[i], rhs[i] = (lhs[i] - rhs[i]) * itwid.
pub inline fn ibutterflyVec4(lhs: [*]M31, rhs: [*]M31, itwid: Vec4u32) void {
    const v0 = loadVec4(lhs);
    const v1 = loadVec4(rhs);
    storeVec4(lhs, addVec4(v0, v1));
    storeVec4(rhs, mulVec4(subVec4(v0, v1), itwid));
}

// ---------------------------------------------------------------
// SIMD vectorized M31 operations (16-lane / PackedM31)
// ---------------------------------------------------------------

/// 16-lane packed width — maps to 4x NEON uint32x4 or 2x AVX2 __m256i.
pub const PACK_WIDTH: usize = 16;
pub const PackedM31 = @Vector(PACK_WIDTH, u32);
pub const PackedU64 = @Vector(PACK_WIDTH, u64);
const P_PACKED: PackedM31 = @splat(Modulus);

/// Load 16 M31 values from a pointer.
pub inline fn loadPacked(ptr: [*]const M31) PackedM31 {
    const raw: *const [PACK_WIDTH]u32 = @ptrCast(ptr);
    return raw.*;
}

/// Store 16 M31 values to a pointer.
pub inline fn storePacked(ptr: [*]M31, v: PackedM31) void {
    const raw: *[PACK_WIDTH]u32 = @ptrCast(ptr);
    raw.* = v;
}

/// 16-lane M31 addition.
pub inline fn addPacked(a: PackedM31, b: PackedM31) PackedM31 {
    const sum = a +% b;
    return @select(u32, sum >= P_PACKED, sum -% P_PACKED, sum);
}

/// 16-lane M31 subtraction.
pub inline fn subPacked(a: PackedM31, b: PackedM31) PackedM31 {
    return @select(u32, a < b, (a +% P_PACKED) -% b, a -% b);
}

/// 16-lane M31 multiplication with Mersenne reduction.
pub inline fn mulPacked(a: PackedM31, b: PackedM31) PackedM31 {
    const a64: PackedU64 = a;
    const b64: PackedU64 = b;
    const prod = a64 * b64;
    return reducePacked(prod);
}

/// 16-lane M31 negation.
pub inline fn negPacked(a: PackedM31) PackedM31 {
    const zero_vec: PackedM31 = @splat(0);
    const is_zero = a == zero_vec;
    return @select(u32, is_zero, zero_vec, P_PACKED -% a);
}

/// 16-lane Mersenne reduction: x mod (2^31 - 1).
/// Two rounds of: t = (x & p) + (x >> 31).
inline fn reducePacked(x: PackedU64) PackedM31 {
    const p64: PackedU64 = @splat(@as(u64, Modulus));
    var t = (x & p64) + (x >> @splat(@as(u6, 31)));
    t = (t & p64) + (t >> @splat(@as(u6, 31)));
    const r: PackedM31 = @truncate(t);
    return @select(u32, r >= P_PACKED, r -% P_PACKED, r);
}

/// 16-lane forward butterfly: lhs[i] = lhs[i] + rhs[i]*twid, rhs[i] = lhs[i] - rhs[i]*twid.
pub inline fn butterflyPacked(lhs: [*]M31, rhs: [*]M31, twid: PackedM31) void {
    const v0 = loadPacked(lhs);
    const v1 = loadPacked(rhs);
    const m = mulPacked(v1, twid);
    storePacked(lhs, addPacked(v0, m));
    storePacked(rhs, subPacked(v0, m));
}

/// 16-lane inverse butterfly.
pub inline fn ibutterflyPacked(lhs: [*]M31, rhs: [*]M31, itwid: PackedM31) void {
    const v0 = loadPacked(lhs);
    const v1 = loadPacked(rhs);
    storePacked(lhs, addPacked(v0, v1));
    storePacked(rhs, mulPacked(subPacked(v0, v1), itwid));
}

/// Create a PackedM31 by splatting a single scalar M31 value across all 16 lanes.
pub inline fn splatPacked(x: M31) PackedM31 {
    return @splat(x.v);
}

/// Fixed-exponent inversion for `p = 2^31 - 1`, computing `a^(p-2)`.
/// Exponent bits: `111...1101` (31 bits).
fn powPMinus2(a: M31) M31 {
    var acc = a;
    inline for (0..30) |step| {
        acc = acc.square();
        const bit = 29 - step;
        if (bit >= 2 or bit == 0) {
            acc = acc.mul(a);
        }
    }
    return acc;
}

fn randElem(rng: std.Random) M31 {
    while (true) {
        const x = rng.int(u32) & Modulus;
        if (x != Modulus) return M31.fromCanonical(x);
    }
}

test "m31: canonical reduction" {
    const p = Modulus;
    try std.testing.expect(M31.fromU64(p).isZero());
    try std.testing.expectEqual(@as(u32, 1), M31.fromU64(p + 1).toU32());
    try std.testing.expect(M31.fromU64(@as(u64, 2) * p).isZero());
    try std.testing.expectEqual(@as(u32, 1), M31.fromU64(@as(u64, 2) * p + 1).toU32());
}

test "m31: basic identities" {
    const a = M31.fromCanonical(123456789);
    const b = M31.fromCanonical(987654321);

    try std.testing.expect(a.add(M31.zero()).eql(a));
    try std.testing.expect(a.mul(M31.one()).eql(a));
    try std.testing.expect(a.sub(a).isZero());
    try std.testing.expect(a.add(b).sub(b).eql(a));

    const minus_one = M31.fromCanonical(Modulus - 1);
    try std.testing.expect(minus_one.mul(minus_one).eql(M31.one()));
}

test "m31: inversion" {
    const a = M31.fromCanonical(7);
    const inv_a = try a.inv();
    try std.testing.expect(a.mul(inv_a).eql(M31.one()));

    try std.testing.expectError(M31.Error.DivisionByZero, M31.zero().inv());
}

test "m31: randomized ring laws" {
    var prng = std.Random.DefaultPrng.init(0x1234_5678_9abc_def0);
    const rng = prng.random();

    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        const a = randElem(rng);
        const b = randElem(rng);
        const c = randElem(rng);

        // Commutativity.
        try std.testing.expect(a.add(b).eql(b.add(a)));
        try std.testing.expect(a.mul(b).eql(b.mul(a)));

        // Associativity.
        try std.testing.expect(a.add(b).add(c).eql(a.add(b.add(c))));
        try std.testing.expect(a.mul(b).mul(c).eql(a.mul(b.mul(c))));

        // Distributivity.
        try std.testing.expect(a.mul(b.add(c)).eql(a.mul(b).add(a.mul(c))));

        // Inversion property for non-zero.
        if (!a.isZero()) {
            const inv_a = try a.inv();
            try std.testing.expect(a.mul(inv_a).eql(M31.one()));
        }
    }
}

test "m31: packed 16-lane add matches scalar" {
    var a_arr: [PACK_WIDTH]M31 = undefined;
    var b_arr: [PACK_WIDTH]M31 = undefined;
    for (0..PACK_WIDTH) |i| {
        a_arr[i] = M31.fromCanonical(@intCast(i * 100 + 1));
        b_arr[i] = M31.fromCanonical(@intCast(i * 200 + 3));
    }
    const a_packed = loadPacked(&a_arr);
    const b_packed = loadPacked(&b_arr);
    const sum_packed = addPacked(a_packed, b_packed);
    var result: [PACK_WIDTH]M31 = undefined;
    storePacked(&result, sum_packed);
    for (0..PACK_WIDTH) |i| {
        try std.testing.expect(result[i].eql(a_arr[i].add(b_arr[i])));
    }
}

test "m31: packed 16-lane sub matches scalar" {
    var a_arr: [PACK_WIDTH]M31 = undefined;
    var b_arr: [PACK_WIDTH]M31 = undefined;
    for (0..PACK_WIDTH) |i| {
        // Mix values so some lanes have a < b and some a >= b.
        a_arr[i] = M31.fromCanonical(@intCast(i * 37 + 5));
        b_arr[i] = M31.fromCanonical(@intCast(i * 53 + 1000));
    }
    const a_packed = loadPacked(&a_arr);
    const b_packed = loadPacked(&b_arr);
    const diff_packed = subPacked(a_packed, b_packed);
    var result: [PACK_WIDTH]M31 = undefined;
    storePacked(&result, diff_packed);
    for (0..PACK_WIDTH) |i| {
        try std.testing.expect(result[i].eql(a_arr[i].sub(b_arr[i])));
    }
}

test "m31: packed 16-lane mul matches scalar" {
    var a_arr: [PACK_WIDTH]M31 = undefined;
    var b_arr: [PACK_WIDTH]M31 = undefined;
    for (0..PACK_WIDTH) |i| {
        a_arr[i] = M31.fromCanonical(@intCast(i * 12345 + 7));
        b_arr[i] = M31.fromCanonical(@intCast(i * 67890 + 11));
    }
    const a_packed = loadPacked(&a_arr);
    const b_packed = loadPacked(&b_arr);
    const prod_packed = mulPacked(a_packed, b_packed);
    var result: [PACK_WIDTH]M31 = undefined;
    storePacked(&result, prod_packed);
    for (0..PACK_WIDTH) |i| {
        try std.testing.expect(result[i].eql(a_arr[i].mul(b_arr[i])));
    }
}

test "m31: packed 16-lane mul with large values" {
    // Test with values close to the modulus to stress the reduction.
    var a_arr: [PACK_WIDTH]M31 = undefined;
    var b_arr: [PACK_WIDTH]M31 = undefined;
    for (0..PACK_WIDTH) |i| {
        a_arr[i] = M31.fromCanonical(Modulus - 1 - @as(u32, @intCast(i)));
        b_arr[i] = M31.fromCanonical(Modulus - 2 - @as(u32, @intCast(i)));
    }
    const a_packed = loadPacked(&a_arr);
    const b_packed = loadPacked(&b_arr);
    const prod_packed = mulPacked(a_packed, b_packed);
    var result: [PACK_WIDTH]M31 = undefined;
    storePacked(&result, prod_packed);
    for (0..PACK_WIDTH) |i| {
        try std.testing.expect(result[i].eql(a_arr[i].mul(b_arr[i])));
    }
}

test "m31: packed 16-lane neg matches scalar" {
    var a_arr: [PACK_WIDTH]M31 = undefined;
    for (0..PACK_WIDTH) |i| {
        a_arr[i] = M31.fromCanonical(@intCast(i * 500));
    }
    const a_packed = loadPacked(&a_arr);
    const neg_packed = negPacked(a_packed);
    var result: [PACK_WIDTH]M31 = undefined;
    storePacked(&result, neg_packed);
    for (0..PACK_WIDTH) |i| {
        try std.testing.expect(result[i].eql(a_arr[i].neg()));
    }
}

test "m31: packed butterfly matches scalar" {
    var lhs_packed_arr: [PACK_WIDTH]M31 = undefined;
    var rhs_packed_arr: [PACK_WIDTH]M31 = undefined;
    var lhs_scalar: [PACK_WIDTH]M31 = undefined;
    var rhs_scalar: [PACK_WIDTH]M31 = undefined;
    var twid_arr: [PACK_WIDTH]M31 = undefined;
    for (0..PACK_WIDTH) |i| {
        lhs_packed_arr[i] = M31.fromCanonical(@intCast(i * 1000 + 42));
        rhs_packed_arr[i] = M31.fromCanonical(@intCast(i * 777 + 99));
        lhs_scalar[i] = lhs_packed_arr[i];
        rhs_scalar[i] = rhs_packed_arr[i];
        twid_arr[i] = M31.fromCanonical(@intCast(i * 333 + 17));
    }
    // Apply packed butterfly.
    butterflyPacked(&lhs_packed_arr, &rhs_packed_arr, loadPacked(&twid_arr));
    // Apply scalar butterfly.
    for (0..PACK_WIDTH) |i| {
        const m = rhs_scalar[i].mul(twid_arr[i]);
        const new_lhs = lhs_scalar[i].add(m);
        const new_rhs = lhs_scalar[i].sub(m);
        lhs_scalar[i] = new_lhs;
        rhs_scalar[i] = new_rhs;
    }
    // Compare.
    for (0..PACK_WIDTH) |i| {
        try std.testing.expect(lhs_packed_arr[i].eql(lhs_scalar[i]));
        try std.testing.expect(rhs_packed_arr[i].eql(rhs_scalar[i]));
    }
}

test "m31: packed ibutterfly matches scalar" {
    var lhs_packed_arr: [PACK_WIDTH]M31 = undefined;
    var rhs_packed_arr: [PACK_WIDTH]M31 = undefined;
    var lhs_scalar: [PACK_WIDTH]M31 = undefined;
    var rhs_scalar: [PACK_WIDTH]M31 = undefined;
    var itwid_arr: [PACK_WIDTH]M31 = undefined;
    for (0..PACK_WIDTH) |i| {
        lhs_packed_arr[i] = M31.fromCanonical(@intCast(i * 500 + 10));
        rhs_packed_arr[i] = M31.fromCanonical(@intCast(i * 300 + 20));
        lhs_scalar[i] = lhs_packed_arr[i];
        rhs_scalar[i] = rhs_packed_arr[i];
        itwid_arr[i] = M31.fromCanonical(@intCast(i * 200 + 5));
    }
    // Apply packed inverse butterfly.
    ibutterflyPacked(&lhs_packed_arr, &rhs_packed_arr, loadPacked(&itwid_arr));
    // Apply scalar inverse butterfly.
    for (0..PACK_WIDTH) |i| {
        const new_lhs = lhs_scalar[i].add(rhs_scalar[i]);
        const new_rhs = lhs_scalar[i].sub(rhs_scalar[i]).mul(itwid_arr[i]);
        lhs_scalar[i] = new_lhs;
        rhs_scalar[i] = new_rhs;
    }
    // Compare.
    for (0..PACK_WIDTH) |i| {
        try std.testing.expect(lhs_packed_arr[i].eql(lhs_scalar[i]));
        try std.testing.expect(rhs_packed_arr[i].eql(rhs_scalar[i]));
    }
}

test "m31: packed 16-lane randomized ring laws" {
    var prng = std.Random.DefaultPrng.init(0xdead_beef_cafe_babe);
    const rng = prng.random();

    for (0..1000) |_| {
        var a_arr: [PACK_WIDTH]M31 = undefined;
        var b_arr: [PACK_WIDTH]M31 = undefined;
        var c_arr: [PACK_WIDTH]M31 = undefined;
        for (0..PACK_WIDTH) |i| {
            a_arr[i] = randElem(rng);
            b_arr[i] = randElem(rng);
            c_arr[i] = randElem(rng);
        }
        const a = loadPacked(&a_arr);
        const b = loadPacked(&b_arr);
        const c = loadPacked(&c_arr);

        // Commutativity of add.
        {
            var r1: [PACK_WIDTH]M31 = undefined;
            var r2: [PACK_WIDTH]M31 = undefined;
            storePacked(&r1, addPacked(a, b));
            storePacked(&r2, addPacked(b, a));
            for (0..PACK_WIDTH) |i| {
                try std.testing.expect(r1[i].eql(r2[i]));
            }
        }
        // Commutativity of mul.
        {
            var r1: [PACK_WIDTH]M31 = undefined;
            var r2: [PACK_WIDTH]M31 = undefined;
            storePacked(&r1, mulPacked(a, b));
            storePacked(&r2, mulPacked(b, a));
            for (0..PACK_WIDTH) |i| {
                try std.testing.expect(r1[i].eql(r2[i]));
            }
        }
        // Associativity of add.
        {
            var r1: [PACK_WIDTH]M31 = undefined;
            var r2: [PACK_WIDTH]M31 = undefined;
            storePacked(&r1, addPacked(addPacked(a, b), c));
            storePacked(&r2, addPacked(a, addPacked(b, c)));
            for (0..PACK_WIDTH) |i| {
                try std.testing.expect(r1[i].eql(r2[i]));
            }
        }
        // Distributivity: a * (b + c) == a*b + a*c.
        {
            var r1: [PACK_WIDTH]M31 = undefined;
            var r2: [PACK_WIDTH]M31 = undefined;
            storePacked(&r1, mulPacked(a, addPacked(b, c)));
            storePacked(&r2, addPacked(mulPacked(a, b), mulPacked(a, c)));
            for (0..PACK_WIDTH) |i| {
                try std.testing.expect(r1[i].eql(r2[i]));
            }
        }
        // a - a == 0.
        {
            var r: [PACK_WIDTH]M31 = undefined;
            storePacked(&r, subPacked(a, a));
            for (0..PACK_WIDTH) |i| {
                try std.testing.expect(r[i].isZero());
            }
        }
    }
}

test "m31: packed16 reduction edge cases" {
    // Test reduce with x = 0: should give 0.
    {
        const zero_vec: PackedU64 = @splat(0);
        const result = reducePacked(zero_vec);
        const expected: PackedM31 = @splat(0);
        try std.testing.expect(@reduce(.And, result == expected));
    }
    // Test reduce with x = P: should give 0.
    {
        const p_vec: PackedU64 = @splat(@as(u64, Modulus));
        const result = reducePacked(p_vec);
        const expected: PackedM31 = @splat(0);
        try std.testing.expect(@reduce(.And, result == expected));
    }
    // Test reduce with x = 1: should give 1.
    {
        const one_vec: PackedU64 = @splat(1);
        const result = reducePacked(one_vec);
        const expected: PackedM31 = @splat(1);
        try std.testing.expect(@reduce(.And, result == expected));
    }
    // Test reduce with x = P-1: should give P-1.
    {
        const pm1_vec: PackedU64 = @splat(@as(u64, Modulus - 1));
        const result = reducePacked(pm1_vec);
        const expected: PackedM31 = @splat(Modulus - 1);
        try std.testing.expect(@reduce(.And, result == expected));
    }
    // Test reduce with x = P+1: should give 1.
    {
        const pp1_vec: PackedU64 = @splat(@as(u64, Modulus + 1));
        const result = reducePacked(pp1_vec);
        const expected: PackedM31 = @splat(1);
        try std.testing.expect(@reduce(.And, result == expected));
    }
    // Test reduce with x = P*P = (2^31-1)^2, the maximum product of two M31 values.
    // (P-1)^2 mod P should equal 1 (since P-1 = -1 mod P, and (-1)*(-1) = 1).
    // But P*P mod P = 0.
    {
        const p_sq: u64 = @as(u64, Modulus) * @as(u64, Modulus);
        const p_sq_vec: PackedU64 = @splat(p_sq);
        const result = reducePacked(p_sq_vec);
        const scalar_result = reduce64(p_sq);
        const expected: PackedM31 = @splat(scalar_result);
        try std.testing.expect(@reduce(.And, result == expected));
    }
    // Test reduce with x = (P-1)^2, the actual max product from mulPacked.
    {
        const pm1_sq: u64 = @as(u64, Modulus - 1) * @as(u64, Modulus - 1);
        const pm1_sq_vec: PackedU64 = @splat(pm1_sq);
        const result = reducePacked(pm1_sq_vec);
        const scalar_result = reduce64(pm1_sq);
        const expected: PackedM31 = @splat(scalar_result);
        try std.testing.expect(@reduce(.And, result == expected));
        // (P-1)^2 mod P = (-1)^2 mod P = 1.
        try std.testing.expectEqual(@as(u32, 1), scalar_result);
    }
    // Test reduce with x = 2^62 - 1 (largest value that fits comfortably in the reduction range).
    {
        const large: u64 = (@as(u64, 1) << 62) - 1;
        const large_vec: PackedU64 = @splat(large);
        const result = reducePacked(large_vec);
        const scalar_result = reduce64(large);
        const expected: PackedM31 = @splat(scalar_result);
        try std.testing.expect(@reduce(.And, result == expected));
    }
    // Test with heterogeneous lanes: each lane has a different edge case.
    {
        var input: [PACK_WIDTH]u64 = undefined;
        input[0] = 0;
        input[1] = 1;
        input[2] = Modulus;
        input[3] = Modulus - 1;
        input[4] = Modulus + 1;
        input[5] = @as(u64, Modulus) * @as(u64, Modulus);
        input[6] = @as(u64, Modulus - 1) * @as(u64, Modulus - 1);
        input[7] = (@as(u64, 1) << 62) - 1;
        input[8] = 2 * @as(u64, Modulus);
        input[9] = 2 * @as(u64, Modulus) + 1;
        input[10] = 3 * @as(u64, Modulus);
        input[11] = @as(u64, 1) << 31;
        input[12] = (@as(u64, 1) << 31) + 1;
        input[13] = 42;
        input[14] = Modulus - 2;
        input[15] = @as(u64, Modulus) * 3 + 7;
        const vec: PackedU64 = input;
        const result = reducePacked(vec);
        const result_arr: [PACK_WIDTH]u32 = result;
        for (0..PACK_WIDTH) |i| {
            try std.testing.expectEqual(reduce64(input[i]), result_arr[i]);
        }
    }
}

test "m31: packed16 add edge cases" {
    // Test adding zero.
    {
        var a_arr: [PACK_WIDTH]M31 = undefined;
        for (0..PACK_WIDTH) |i| {
            a_arr[i] = M31.fromCanonical(@intCast(i * 100_000));
        }
        const a = loadPacked(&a_arr);
        const zero_vec: PackedM31 = @splat(0);
        const result = addPacked(a, zero_vec);
        try std.testing.expect(@reduce(.And, result == a));
    }
    // Test P-1 + 1 = 0 (modular wrap).
    {
        const pm1: PackedM31 = @splat(Modulus - 1);
        const one: PackedM31 = @splat(1);
        const result = addPacked(pm1, one);
        const expected: PackedM31 = @splat(0);
        try std.testing.expect(@reduce(.And, result == expected));
    }
    // Test P-1 + P-1 = P-2 (double wrap).
    {
        const pm1: PackedM31 = @splat(Modulus - 1);
        const result = addPacked(pm1, pm1);
        const expected: PackedM31 = @splat(Modulus - 2);
        try std.testing.expect(@reduce(.And, result == expected));
    }
}

test "m31: packed16 sub edge cases" {
    // Test 0 - 0 = 0.
    {
        const zero_vec: PackedM31 = @splat(0);
        const result = subPacked(zero_vec, zero_vec);
        try std.testing.expect(@reduce(.And, result == zero_vec));
    }
    // Test 0 - 1 = P-1 (wrap around).
    {
        const zero_vec: PackedM31 = @splat(0);
        const one_vec: PackedM31 = @splat(1);
        const result = subPacked(zero_vec, one_vec);
        const expected: PackedM31 = @splat(Modulus - 1);
        try std.testing.expect(@reduce(.And, result == expected));
    }
    // Test 0 - (P-1) = 1.
    {
        const zero_vec: PackedM31 = @splat(0);
        const pm1: PackedM31 = @splat(Modulus - 1);
        const result = subPacked(zero_vec, pm1);
        const expected: PackedM31 = @splat(1);
        try std.testing.expect(@reduce(.And, result == expected));
    }
}

test "m31: packed16 neg edge cases" {
    // neg(0) = 0.
    {
        const zero_vec: PackedM31 = @splat(0);
        const result = negPacked(zero_vec);
        try std.testing.expect(@reduce(.And, result == zero_vec));
    }
    // neg(1) = P-1.
    {
        const one_vec: PackedM31 = @splat(1);
        const result = negPacked(one_vec);
        const expected: PackedM31 = @splat(Modulus - 1);
        try std.testing.expect(@reduce(.And, result == expected));
    }
    // neg(P-1) = 1.
    {
        const pm1: PackedM31 = @splat(Modulus - 1);
        const result = negPacked(pm1);
        const expected: PackedM31 = @splat(1);
        try std.testing.expect(@reduce(.And, result == expected));
    }
    // a + neg(a) = 0 for random inputs.
    {
        var prng = std.Random.DefaultPrng.init(0xFACE);
        const rng = prng.random();
        var a_arr: [PACK_WIDTH]M31 = undefined;
        for (0..PACK_WIDTH) |i| {
            a_arr[i] = randElem(rng);
        }
        const a = loadPacked(&a_arr);
        const result = addPacked(a, negPacked(a));
        const zero_vec: PackedM31 = @splat(0);
        try std.testing.expect(@reduce(.And, result == zero_vec));
    }
}

test "m31: packed16 mul matches scalar for random inputs" {
    var prng = std.Random.DefaultPrng.init(0xDEADBEEF);
    const rng = prng.random();
    var a_arr: [PACK_WIDTH]M31 = undefined;
    var b_arr: [PACK_WIDTH]M31 = undefined;
    for (0..PACK_WIDTH) |i| {
        a_arr[i] = randElem(rng);
        b_arr[i] = randElem(rng);
    }
    const a_packed = loadPacked(&a_arr);
    const b_packed = loadPacked(&b_arr);
    const prod = mulPacked(a_packed, b_packed);
    var result: [PACK_WIDTH]M31 = undefined;
    storePacked(&result, prod);
    for (0..PACK_WIDTH) |i| {
        try std.testing.expect(result[i].eql(a_arr[i].mul(b_arr[i])));
    }
}

test "m31: packed16 mul with Modulus-1 values" {
    // (P-1) * (P-1) = 1 in M31 because P-1 = -1 mod P.
    {
        const pm1: PackedM31 = @splat(Modulus - 1);
        const result = mulPacked(pm1, pm1);
        const expected: PackedM31 = @splat(1);
        var result_arr: [PACK_WIDTH]M31 = undefined;
        storePacked(&result_arr, result);
        var expected_arr: [PACK_WIDTH]M31 = undefined;
        storePacked(&expected_arr, expected);
        for (0..PACK_WIDTH) |i| {
            try std.testing.expect(result_arr[i].eql(expected_arr[i]));
        }
    }
    // (P-1) * 1 = P-1.
    {
        const pm1: PackedM31 = @splat(Modulus - 1);
        const one: PackedM31 = @splat(1);
        const result = mulPacked(pm1, one);
        try std.testing.expect(@reduce(.And, result == pm1));
    }
    // a * 0 = 0.
    {
        const pm1: PackedM31 = @splat(Modulus - 1);
        const zero_vec: PackedM31 = @splat(0);
        const result = mulPacked(pm1, zero_vec);
        try std.testing.expect(@reduce(.And, result == zero_vec));
    }
}

test "m31: packed16 mul with zero values" {
    // 0 * 0 = 0.
    {
        const zero_vec: PackedM31 = @splat(0);
        const result = mulPacked(zero_vec, zero_vec);
        try std.testing.expect(@reduce(.And, result == zero_vec));
    }
    // 0 * random = 0.
    {
        var prng = std.Random.DefaultPrng.init(0xBAADF00D);
        const rng = prng.random();
        var b_arr: [PACK_WIDTH]M31 = undefined;
        for (0..PACK_WIDTH) |i| {
            b_arr[i] = randElem(rng);
        }
        const zero_vec: PackedM31 = @splat(0);
        const b = loadPacked(&b_arr);
        const result = mulPacked(zero_vec, b);
        try std.testing.expect(@reduce(.And, result == zero_vec));
    }
}

test "m31: packed16 all ops match scalar for many random rounds" {
    var prng = std.Random.DefaultPrng.init(0xCAFEBABE_12345678);
    const rng = prng.random();

    for (0..500) |_| {
        var a_arr: [PACK_WIDTH]M31 = undefined;
        var b_arr: [PACK_WIDTH]M31 = undefined;
        for (0..PACK_WIDTH) |i| {
            a_arr[i] = randElem(rng);
            b_arr[i] = randElem(rng);
        }
        const a = loadPacked(&a_arr);
        const b = loadPacked(&b_arr);

        // add
        {
            var result: [PACK_WIDTH]M31 = undefined;
            storePacked(&result, addPacked(a, b));
            for (0..PACK_WIDTH) |i| {
                try std.testing.expect(result[i].eql(a_arr[i].add(b_arr[i])));
            }
        }
        // sub
        {
            var result: [PACK_WIDTH]M31 = undefined;
            storePacked(&result, subPacked(a, b));
            for (0..PACK_WIDTH) |i| {
                try std.testing.expect(result[i].eql(a_arr[i].sub(b_arr[i])));
            }
        }
        // mul
        {
            var result: [PACK_WIDTH]M31 = undefined;
            storePacked(&result, mulPacked(a, b));
            for (0..PACK_WIDTH) |i| {
                try std.testing.expect(result[i].eql(a_arr[i].mul(b_arr[i])));
            }
        }
        // neg
        {
            var result: [PACK_WIDTH]M31 = undefined;
            storePacked(&result, negPacked(a));
            for (0..PACK_WIDTH) |i| {
                try std.testing.expect(result[i].eql(a_arr[i].neg()));
            }
        }
    }
}

test "m31: packed16 butterfly matches scalar fft.butterfly" {
    const fft_mod = @import("../fft.zig");
    var lhs: [PACK_WIDTH]M31 = undefined;
    var rhs: [PACK_WIDTH]M31 = undefined;
    var lhs_scalar: [PACK_WIDTH]M31 = undefined;
    var rhs_scalar: [PACK_WIDTH]M31 = undefined;
    const twid = M31.fromCanonical(12345);
    var prng = std.Random.DefaultPrng.init(0xCAFE);
    const rng = prng.random();
    for (0..PACK_WIDTH) |i| {
        lhs[i] = randElem(rng);
        rhs[i] = randElem(rng);
        lhs_scalar[i] = lhs[i];
        rhs_scalar[i] = rhs[i];
    }
    // Packed butterfly.
    butterflyPacked(&lhs, &rhs, @as(PackedM31, @splat(twid.v)));
    // Scalar butterfly.
    for (0..PACK_WIDTH) |i| {
        fft_mod.butterfly(M31, &lhs_scalar[i], &rhs_scalar[i], twid);
    }
    // Compare.
    for (0..PACK_WIDTH) |i| {
        try std.testing.expect(lhs[i].eql(lhs_scalar[i]));
        try std.testing.expect(rhs[i].eql(rhs_scalar[i]));
    }
}

test "m31: packed16 ibutterfly matches scalar fft.ibutterfly" {
    const fft_mod = @import("../fft.zig");
    var lhs: [PACK_WIDTH]M31 = undefined;
    var rhs: [PACK_WIDTH]M31 = undefined;
    var lhs_scalar: [PACK_WIDTH]M31 = undefined;
    var rhs_scalar: [PACK_WIDTH]M31 = undefined;
    const itwid = M31.fromCanonical(54321);
    var prng = std.Random.DefaultPrng.init(0xBEEF);
    const rng = prng.random();
    for (0..PACK_WIDTH) |i| {
        lhs[i] = randElem(rng);
        rhs[i] = randElem(rng);
        lhs_scalar[i] = lhs[i];
        rhs_scalar[i] = rhs[i];
    }
    // Packed inverse butterfly.
    ibutterflyPacked(&lhs, &rhs, @as(PackedM31, @splat(itwid.v)));
    // Scalar inverse butterfly.
    for (0..PACK_WIDTH) |i| {
        fft_mod.ibutterfly(M31, &lhs_scalar[i], &rhs_scalar[i], itwid);
    }
    // Compare.
    for (0..PACK_WIDTH) |i| {
        try std.testing.expect(lhs[i].eql(lhs_scalar[i]));
        try std.testing.expect(rhs[i].eql(rhs_scalar[i]));
    }
}

test "m31: packed16 butterfly roundtrip (butterfly then ibutterfly)" {
    var lhs: [PACK_WIDTH]M31 = undefined;
    var rhs: [PACK_WIDTH]M31 = undefined;
    const twid = M31.fromCanonical(7);
    const itwid = (M31.fromCanonical(7).inv() catch unreachable);
    var prng = std.Random.DefaultPrng.init(0xF00D);
    const rng = prng.random();
    for (0..PACK_WIDTH) |i| {
        lhs[i] = randElem(rng);
        rhs[i] = randElem(rng);
    }
    const orig_lhs = lhs;
    const orig_rhs = rhs;
    // Forward then inverse butterfly.
    butterflyPacked(&lhs, &rhs, @as(PackedM31, @splat(twid.v)));
    ibutterflyPacked(&lhs, &rhs, @as(PackedM31, @splat(itwid.v)));
    // After roundtrip: lhs = 2*orig_lhs, rhs = 2*orig_rhs.
    for (0..PACK_WIDTH) |i| {
        try std.testing.expect(lhs[i].eql(orig_lhs[i].add(orig_lhs[i])));
        try std.testing.expect(rhs[i].eql(orig_rhs[i].add(orig_rhs[i])));
    }
}
