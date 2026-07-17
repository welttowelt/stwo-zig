const std = @import("std");
const builtin = @import("builtin");

pub const Blake2sHash = [32]u8;

pub const BackendMode = enum {
    auto,
    scalar,
    simd,
};

var backend_mode: BackendMode = .auto;

pub fn setBackendMode(mode: BackendMode) void {
    backend_mode = mode;
}

pub fn getBackendMode() BackendMode {
    return backend_mode;
}

pub fn supportsSimdBackend() bool {
    return switch (builtin.cpu.arch) {
        .x86_64, .aarch64 => true,
        else => false,
    };
}

pub const Blake2sHasher = struct {
    h: [8]u32,
    t0: u32,
    t1: u32,
    buf: [64]u8,
    buf_len: usize,
    finalized: bool,

    const Self = @This();

    pub fn init() Self {
        var h = BLAKE2S_IV;
        h[0] ^= 0x01010020;
        return .{
            .h = h,
            .t0 = 0,
            .t1 = 0,
            .buf = [_]u8{0} ** 64,
            .buf_len = 0,
            .finalized = false,
        };
    }

    pub fn update(self: *Self, data: []const u8) void {
        std.debug.assert(!self.finalized);
        if (data.len == 0) return;

        var at: usize = 0;
        if (self.buf_len > 0 or data.len <= 64) {
            const copy_len = @min(64 - self.buf_len, data.len);
            @memcpy(self.buf[self.buf_len .. self.buf_len + copy_len], data[0..copy_len]);
            self.buf_len += copy_len;
            at += copy_len;

            // Keep a full terminal block buffered so finalize can mark it as last.
            if (self.buf_len < 64 or at == data.len) return;

            self.addCounter(64);
            self.compressBlock(&self.buf, false);
            self.buf_len = 0;
        }

        while (at + 64 < data.len) : (at += 64) {
            self.addCounter(64);
            self.compressBlockBytes(data[at .. at + 64], false);
        }

        if (at <= data.len) {
            const rem = data.len - at;
            std.debug.assert(rem <= 64);
            if (rem > 0) {
                @memcpy(self.buf[0..rem], data[at..]);
            }
            self.buf_len = rem;
        }
    }

    pub fn finalize(self: *Self) Blake2sHash {
        std.debug.assert(!self.finalized);
        self.finalized = true;

        var block: [64]u8 = [_]u8{0} ** 64;
        if (self.buf_len > 0) {
            @memcpy(block[0..self.buf_len], self.buf[0..self.buf_len]);
        }
        self.addCounter(@intCast(self.buf_len));
        self.compressBlock(&block, true);
        return stateToDigest(self.h);
    }

    pub fn hash(data: []const u8) Blake2sHash {
        var hasher = Self.init();
        hasher.update(data);
        return hasher.finalize();
    }

    pub fn hashFixedSingleBlock(comptime byte_len: usize, data: *const [byte_len]u8) Blake2sHash {
        comptime std.debug.assert(byte_len <= 64);

        var hasher = Self.init();
        if (byte_len == 64) {
            hasher.addCounter(64);
            hasher.compressBlockBytes(data[0..], true);
            return stateToDigest(hasher.h);
        }

        var block: [64]u8 = [_]u8{0} ** 64;
        if (byte_len > 0) {
            @memcpy(block[0..byte_len], data[0..]);
        }
        hasher.addCounter(@intCast(byte_len));
        hasher.compressBlock(&block, true);
        return stateToDigest(hasher.h);
    }

    pub fn hashFixed64(data: *const [64]u8) Blake2sHash {
        return hashFixedSingleBlock(64, data);
    }

    pub fn hashFixed128(data: *const [128]u8) Blake2sHash {
        var hasher = Self.init();
        hasher.addCounter(64);
        hasher.compressBlockBytes(data[0..64], false);
        hasher.addCounter(64);
        hasher.compressBlockBytes(data[64..128], true);
        hasher.finalized = true;
        return stateToDigest(hasher.h);
    }

    /// State after hashing one complete, non-terminal 64-byte block.
    pub const Fixed64Seed = [8]u32;

    pub fn seedAfterFixed64(data: *const [64]u8) Fixed64Seed {
        var hasher = Self.init();
        hasher.addCounter(64);
        hasher.compressBlockBytes(data[0..], false);
        return hasher.h;
    }

    /// Finishes a 128-byte message from the state returned by
    /// `seedAfterFixed64`, hashing only its terminal 64-byte block.
    pub fn hashFinal64FromSeed(seed: Fixed64Seed, data: *const [64]u8) Blake2sHash {
        var h = seed;
        var words: [16]u32 = undefined;
        loadBlockWords(data, &words);
        switch (effectiveMode()) {
            .simd => compressSimd(&h, &words, 128, 0, 0xFFFF_FFFF),
            .scalar => compressScalar(&h, &words, 128, 0, 0xFFFF_FFFF),
            .auto => unreachable,
        }
        return stateToDigest(h);
    }

    pub fn hashFinal64FromSeed4(
        seed: Fixed64Seed,
        data: *const [4][64]u8,
    ) [4]Blake2sHash {
        var messages: [16]V4 = undefined;
        loadParallelBlock4(data, &messages);

        var states: [8]V4 = undefined;
        for (0..8) |word_index| states[word_index] = @splat(seed[word_index]);
        compressParallel4(&states, &messages, 128, 0, 0xFFFF_FFFF);
        return parallelStatesToDigests(&states);
    }

    pub fn hashEqualFromSeed4(
        seed: Fixed64Seed,
        data: *const [4][]const u8,
    ) [4]Blake2sHash {
        const len = data[0].len;
        for (data[1..]) |message| std.debug.assert(message.len == len);
        std.debug.assert(len > 0);

        var states: [8]V4 = undefined;
        for (0..8) |word_index| states[word_index] = @splat(seed[word_index]);

        var at: usize = 0;
        var counter: u32 = 64;
        while (at + 64 < len) : (at += 64) {
            var blocks: [4][64]u8 = undefined;
            for (0..4) |lane| @memcpy(blocks[lane][0..], data[lane][at .. at + 64]);
            var messages: [16]V4 = undefined;
            loadParallelBlock4(&blocks, &messages);
            counter +%= 64;
            compressParallel4(&states, &messages, counter, 0, 0);
        }

        const remaining = len - at;
        var final_blocks = [_][64]u8{[_]u8{0} ** 64} ** 4;
        for (0..4) |lane| @memcpy(final_blocks[lane][0..remaining], data[lane][at..]);
        var final_messages: [16]V4 = undefined;
        loadParallelBlock4(&final_blocks, &final_messages);
        counter +%= @intCast(remaining);
        compressParallel4(&states, &final_messages, counter, 0, 0xFFFF_FFFF);

        return parallelStatesToDigests(&states);
    }

    fn addCounter(self: *Self, inc: u32) void {
        const sum: u64 = @as(u64, self.t0) + @as(u64, inc);
        self.t0 = @truncate(sum);
        self.t1 +%= @intCast(sum >> 32);
    }

    fn compressBlock(self: *Self, block: *const [64]u8, is_last: bool) void {
        var m: [16]u32 = undefined;
        loadBlockWords(block, &m);
        self.compressWords(&m, is_last);
    }

    fn compressBlockBytes(self: *Self, block: []const u8, is_last: bool) void {
        std.debug.assert(block.len == 64);
        var m: [16]u32 = undefined;
        loadBlockWordsFromSlice(block, &m);
        self.compressWords(&m, is_last);
    }

    fn compressWords(self: *Self, m: *const [16]u32, is_last: bool) void {
        const f0: u32 = if (is_last) 0xFFFF_FFFF else 0;
        switch (effectiveMode()) {
            .simd => compressSimd(&self.h, m, self.t0, self.t1, f0),
            .scalar => compressScalar(&self.h, m, self.t0, self.t1, f0),
            .auto => unreachable,
        }
    }
};

fn effectiveMode() BackendMode {
    return switch (backend_mode) {
        .auto => if (supportsSimdBackend()) .simd else .scalar,
        .scalar => .scalar,
        .simd => if (supportsSimdBackend()) .simd else .scalar,
    };
}

const BLAKE2S_IV = [_]u32{
    0x6A09E667,
    0xBB67AE85,
    0x3C6EF372,
    0xA54FF53A,
    0x510E527F,
    0x9B05688C,
    0x1F83D9AB,
    0x5BE0CD19,
};

const BLAKE2S_SIGMA = [10][16]u8{
    .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
    .{ 14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3 },
    .{ 11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4 },
    .{ 7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8 },
    .{ 9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13 },
    .{ 2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9 },
    .{ 12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11 },
    .{ 13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10 },
    .{ 6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5 },
    .{ 10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0 },
};

fn loadBlockWords(block: *const [64]u8, out: *[16]u32) void {
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        out[i] = readU32LeFromFixed(block, i * 4);
    }
}

fn loadBlockWordsFromSlice(block: []const u8, out: *[16]u32) void {
    std.debug.assert(block.len == 64);
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const start = i * 4;
        out[i] = (@as(u32, block[start + 0])) |
            (@as(u32, block[start + 1]) << 8) |
            (@as(u32, block[start + 2]) << 16) |
            (@as(u32, block[start + 3]) << 24);
    }
}

fn readU32LeFromFixed(data: *const [64]u8, at: usize) u32 {
    return (@as(u32, data[at + 0])) |
        (@as(u32, data[at + 1]) << 8) |
        (@as(u32, data[at + 2]) << 16) |
        (@as(u32, data[at + 3]) << 24);
}

fn loadParallelBlock4(data: *const [4][64]u8, out: *[16]V4) void {
    if (comptime builtin.cpu.arch.endian() == .little) {
        const words: [4][4]V4 = @bitCast(data.*);
        inline for (0..4) |group| {
            const transposed = transpose4x4(.{
                words[0][group],
                words[1][group],
                words[2][group],
                words[3][group],
            });
            inline for (0..4) |word| out[group * 4 + word] = transposed[word];
        }
    } else {
        for (0..16) |word_index| {
            const byte_index = word_index * 4;
            out[word_index] = .{
                readU32LeFromFixed(&data[0], byte_index),
                readU32LeFromFixed(&data[1], byte_index),
                readU32LeFromFixed(&data[2], byte_index),
                readU32LeFromFixed(&data[3], byte_index),
            };
        }
    }
}

fn parallelStatesToDigests(states: *const [8]V4) [4]Blake2sHash {
    if (comptime builtin.cpu.arch.endian() == .little) {
        const low = transpose4x4(.{ states[0], states[1], states[2], states[3] });
        const high = transpose4x4(.{ states[4], states[5], states[6], states[7] });
        var words: [4][2]V4 = undefined;
        inline for (0..4) |lane| words[lane] = .{ low[lane], high[lane] };
        return @bitCast(words);
    } else {
        var out: [4]Blake2sHash = undefined;
        for (0..4) |lane| {
            var lane_state: [8]u32 = undefined;
            for (0..8) |word_index| lane_state[word_index] = states[word_index][lane];
            out[lane] = stateToDigest(lane_state);
        }
        return out;
    }
}

fn stateToDigest(h: [8]u32) Blake2sHash {
    var out: Blake2sHash = undefined;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        writeU32Le(out[i * 4 .. i * 4 + 4], h[i]);
    }
    return out;
}

fn writeU32Le(dst: []u8, value: u32) void {
    std.debug.assert(dst.len == 4);
    dst[0] = @truncate(value);
    dst[1] = @truncate(value >> 8);
    dst[2] = @truncate(value >> 16);
    dst[3] = @truncate(value >> 24);
}

fn rotr32(x: u32, bits: u5) u32 {
    const left_bits: u5 = @intCast((@as(u6, 32) - @as(u6, bits)) & 31);
    return (x >> bits) | (x << left_bits);
}

fn gScalar(v: *[16]u32, a: usize, b: usize, c: usize, d: usize, x: u32, y: u32) void {
    v[a] = v[a] +% v[b] +% x;
    v[d] = rotr32(v[d] ^ v[a], 16);
    v[c] = v[c] +% v[d];
    v[b] = rotr32(v[b] ^ v[c], 12);
    v[a] = v[a] +% v[b] +% y;
    v[d] = rotr32(v[d] ^ v[a], 8);
    v[c] = v[c] +% v[d];
    v[b] = rotr32(v[b] ^ v[c], 7);
}

fn compressScalar(h: *[8]u32, m: *const [16]u32, t0: u32, t1: u32, f0: u32) void {
    var v: [16]u32 = undefined;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        v[i] = h[i];
        v[i + 8] = BLAKE2S_IV[i];
    }
    v[12] ^= t0;
    v[13] ^= t1;
    v[14] ^= f0;

    var round: usize = 0;
    while (round < 10) : (round += 1) {
        const s = BLAKE2S_SIGMA[round];
        gScalar(&v, 0, 4, 8, 12, m[s[0]], m[s[1]]);
        gScalar(&v, 1, 5, 9, 13, m[s[2]], m[s[3]]);
        gScalar(&v, 2, 6, 10, 14, m[s[4]], m[s[5]]);
        gScalar(&v, 3, 7, 11, 15, m[s[6]], m[s[7]]);
        gScalar(&v, 0, 5, 10, 15, m[s[8]], m[s[9]]);
        gScalar(&v, 1, 6, 11, 12, m[s[10]], m[s[11]]);
        gScalar(&v, 2, 7, 8, 13, m[s[12]], m[s[13]]);
        gScalar(&v, 3, 4, 9, 14, m[s[14]], m[s[15]]);
    }

    i = 0;
    while (i < 8) : (i += 1) {
        h[i] ^= v[i] ^ v[i + 8];
    }
}

const V4 = @Vector(4, u32);
const Shift4 = @Vector(4, u5);

fn transpose4x4(rows: [4]V4) [4]V4 {
    const ab_low = @shuffle(u32, rows[0], rows[1], @Vector(4, i32){ 0, -1, 1, -2 });
    const ab_high = @shuffle(u32, rows[0], rows[1], @Vector(4, i32){ 2, -3, 3, -4 });
    const cd_low = @shuffle(u32, rows[2], rows[3], @Vector(4, i32){ 0, -1, 1, -2 });
    const cd_high = @shuffle(u32, rows[2], rows[3], @Vector(4, i32){ 2, -3, 3, -4 });
    return .{
        @shuffle(u32, ab_low, cd_low, @Vector(4, i32){ 0, 1, -1, -2 }),
        @shuffle(u32, ab_low, cd_low, @Vector(4, i32){ 2, 3, -3, -4 }),
        @shuffle(u32, ab_high, cd_high, @Vector(4, i32){ 0, 1, -1, -2 }),
        @shuffle(u32, ab_high, cd_high, @Vector(4, i32){ 2, 3, -3, -4 }),
    };
}

fn rotr32x4(x: V4, bits: u5) V4 {
    const left_bits: u5 = @intCast((@as(u6, 32) - @as(u6, bits)) & 31);
    const r: Shift4 = @splat(bits);
    const l: Shift4 = @splat(left_bits);
    return (x >> r) | (x << l);
}

fn gather4(values: *const [16]u32, idx: [4]u8) V4 {
    return .{
        values[idx[0]],
        values[idx[1]],
        values[idx[2]],
        values[idx[3]],
    };
}

fn scatter4(values: *[16]u32, idx: [4]u8, vec: V4) void {
    values[idx[0]] = vec[0];
    values[idx[1]] = vec[1];
    values[idx[2]] = vec[2];
    values[idx[3]] = vec[3];
}

fn g4(a: *V4, b: *V4, c: *V4, d: *V4, x: V4, y: V4) void {
    a.* = a.* +% b.* +% x;
    d.* = rotr32x4(d.* ^ a.*, 16);
    c.* = c.* +% d.*;
    b.* = rotr32x4(b.* ^ c.*, 12);
    a.* = a.* +% b.* +% y;
    d.* = rotr32x4(d.* ^ a.*, 8);
    c.* = c.* +% d.*;
    b.* = rotr32x4(b.* ^ c.*, 7);
}

fn compressSimd(h: *[8]u32, m: *const [16]u32, t0: u32, t1: u32, f0: u32) void {
    var v: [16]u32 = undefined;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        v[i] = h[i];
        v[i + 8] = BLAKE2S_IV[i];
    }
    v[12] ^= t0;
    v[13] ^= t1;
    v[14] ^= f0;

    const col_a = [_]u8{ 0, 1, 2, 3 };
    const col_b = [_]u8{ 4, 5, 6, 7 };
    const col_c = [_]u8{ 8, 9, 10, 11 };
    const col_d = [_]u8{ 12, 13, 14, 15 };

    const diag_a = [_]u8{ 0, 1, 2, 3 };
    const diag_b = [_]u8{ 5, 6, 7, 4 };
    const diag_c = [_]u8{ 10, 11, 8, 9 };
    const diag_d = [_]u8{ 15, 12, 13, 14 };

    var round: usize = 0;
    while (round < 10) : (round += 1) {
        const s = BLAKE2S_SIGMA[round];

        var a = gather4(&v, col_a);
        var b = gather4(&v, col_b);
        var c = gather4(&v, col_c);
        var d = gather4(&v, col_d);
        const x_col: V4 = .{ m[s[0]], m[s[2]], m[s[4]], m[s[6]] };
        const y_col: V4 = .{ m[s[1]], m[s[3]], m[s[5]], m[s[7]] };
        g4(&a, &b, &c, &d, x_col, y_col);
        scatter4(&v, col_a, a);
        scatter4(&v, col_b, b);
        scatter4(&v, col_c, c);
        scatter4(&v, col_d, d);

        a = gather4(&v, diag_a);
        b = gather4(&v, diag_b);
        c = gather4(&v, diag_c);
        d = gather4(&v, diag_d);
        const x_diag: V4 = .{ m[s[8]], m[s[10]], m[s[12]], m[s[14]] };
        const y_diag: V4 = .{ m[s[9]], m[s[11]], m[s[13]], m[s[15]] };
        g4(&a, &b, &c, &d, x_diag, y_diag);
        scatter4(&v, diag_a, a);
        scatter4(&v, diag_b, b);
        scatter4(&v, diag_c, c);
        scatter4(&v, diag_d, d);
    }

    i = 0;
    while (i < 8) : (i += 1) {
        h[i] ^= v[i] ^ v[i + 8];
    }
}

fn compressParallel4(h: *[8]V4, m: *const [16]V4, t0: u32, t1: u32, f0: u32) void {
    var v: [16]V4 = undefined;
    for (0..8) |i| {
        v[i] = h[i];
        v[i + 8] = @splat(BLAKE2S_IV[i]);
    }
    v[12] ^= @as(V4, @splat(t0));
    v[13] ^= @as(V4, @splat(t1));
    v[14] ^= @as(V4, @splat(f0));

    inline for (BLAKE2S_SIGMA) |s| {
        g4(&v[0], &v[4], &v[8], &v[12], m[s[0]], m[s[1]]);
        g4(&v[1], &v[5], &v[9], &v[13], m[s[2]], m[s[3]]);
        g4(&v[2], &v[6], &v[10], &v[14], m[s[4]], m[s[5]]);
        g4(&v[3], &v[7], &v[11], &v[15], m[s[6]], m[s[7]]);
        g4(&v[0], &v[5], &v[10], &v[15], m[s[8]], m[s[9]]);
        g4(&v[1], &v[6], &v[11], &v[12], m[s[10]], m[s[11]]);
        g4(&v[2], &v[7], &v[8], &v[13], m[s[12]], m[s[13]]);
        g4(&v[3], &v[4], &v[9], &v[14], m[s[14]], m[s[15]]);
    }

    for (0..8) |i| h[i] ^= v[i] ^ v[i + 8];
}

fn digestToHex(digest: Blake2sHash) [64]u8 {
    return std.fmt.bytesToHex(digest, .lower);
}

test "blake2s backend: one-shot known vector" {
    const hash_a = Blake2sHasher.hash("a");
    const hex = digestToHex(hash_a);
    try std.testing.expectEqualStrings(
        "4a0d129873403037c2cd9b9048203687f6233fb6738956e0349bd4320fec3e90",
        &hex,
    );
}

test "blake2s backend: incremental equals one-shot" {
    var state = Blake2sHasher.init();
    state.update("a");
    state.update("b");
    const hash_ab = state.finalize();
    const one_shot = Blake2sHasher.hash("ab");
    try std.testing.expect(std.mem.eql(u8, hash_ab[0..], one_shot[0..]));
}

test "blake2s backend: fixed128 equals generic stream hash" {
    var prng = std.Random.DefaultPrng.init(0x6a09_e667_f3bc_c908);
    const rng = prng.random();
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        var payload: [128]u8 = undefined;
        rng.bytes(payload[0..]);
        const generic = Blake2sHasher.hash(payload[0..]);
        const fixed = Blake2sHasher.hashFixed128(&payload);
        try std.testing.expect(std.mem.eql(u8, generic[0..], fixed[0..]));
    }
}

test "blake2s backend: fixed single-block helpers equal generic hash" {
    var prng = std.Random.DefaultPrng.init(0x243f_6a88_85a3_08d3);
    const rng = prng.random();

    inline for (.{
        @as(usize, 0),
        @as(usize, 1),
        @as(usize, 37),
        @as(usize, 40),
        @as(usize, 52),
        @as(usize, 64),
    }) |byte_len| {
        var i: usize = 0;
        while (i < 32) : (i += 1) {
            var payload: [byte_len]u8 = undefined;
            if (byte_len > 0) rng.bytes(payload[0..]);
            const generic = Blake2sHasher.hash(payload[0..]);
            const fixed = Blake2sHasher.hashFixedSingleBlock(byte_len, &payload);
            try std.testing.expect(std.mem.eql(u8, generic[0..], fixed[0..]));
        }
    }
}

test "blake2s backend: four-way terminal compression matches scalar messages" {
    var prng = std.Random.DefaultPrng.init(0x6c62_6174_6368_345f);
    var prefix: [64]u8 = undefined;
    var blocks: [4][64]u8 = undefined;
    prng.random().bytes(prefix[0..]);
    for (&blocks) |*block| prng.random().bytes(block[0..]);

    const seed = Blake2sHasher.seedAfterFixed64(&prefix);
    const batched = Blake2sHasher.hashFinal64FromSeed4(seed, &blocks);
    for (blocks, 0..) |block, lane| {
        const expected = Blake2sHasher.hashFinal64FromSeed(seed, &block);
        try std.testing.expectEqualSlices(u8, expected[0..], batched[lane][0..]);
    }
}

test "blake2s backend: four-way equal messages match seeded scalar stream" {
    var prng = std.Random.DefaultPrng.init(0x6c65_6166_345f_7369);
    var prefix: [64]u8 = undefined;
    prng.random().bytes(prefix[0..]);
    const seed = Blake2sHasher.seedAfterFixed64(&prefix);

    inline for (.{ @as(usize, 4), @as(usize, 64), @as(usize, 68), @as(usize, 3296) }) |len| {
        var storage: [4][len]u8 = undefined;
        var messages: [4][]const u8 = undefined;
        for (&storage, 0..) |*message, lane| {
            prng.random().bytes(message[0..]);
            messages[lane] = message;
        }
        const batched = Blake2sHasher.hashEqualFromSeed4(seed, &messages);
        for (storage, 0..) |message, lane| {
            var payload: [64 + len]u8 = undefined;
            @memcpy(payload[0..64], prefix[0..]);
            @memcpy(payload[64..], message[0..]);
            const expected = Blake2sHasher.hash(payload[0..]);
            try std.testing.expectEqualSlices(u8, expected[0..], batched[lane][0..]);
        }
    }
}

test "blake2s backend: scalar and simd modes are equivalent" {
    const previous_mode = getBackendMode();
    defer setBackendMode(previous_mode);

    var prng = std.Random.DefaultPrng.init(0x510e_527f_ade6_82d1);
    const rng = prng.random();

    var i: usize = 0;
    while (i < 64) : (i += 1) {
        var payload: [128]u8 = undefined;
        rng.bytes(payload[0..]);

        setBackendMode(.scalar);
        const scalar_digest = Blake2sHasher.hashFixed128(&payload);
        setBackendMode(.simd);
        const simd_digest = Blake2sHasher.hashFixed128(&payload);
        try std.testing.expect(std.mem.eql(u8, scalar_digest[0..], simd_digest[0..]));
    }
}
