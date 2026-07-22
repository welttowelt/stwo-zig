const std = @import("std");
const backend = @import("../blake2s_backend.zig");

const BackendMode = backend.BackendMode;
const Blake2sHasher = backend.Blake2sHasher;

fn digestToHex(digest: backend.Blake2sHash) [64]u8 {
    return std.fmt.bytesToHex(digest, .lower);
}

fn writeU32Le(dst: []u8, value: u32) void {
    dst[0] = @truncate(value);
    dst[1] = @truncate(value >> 8);
    dst[2] = @truncate(value >> 16);
    dst[3] = @truncate(value >> 24);
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

test "blake2s backend: four-way word reader matches packed messages" {
    var prng = std.Random.DefaultPrng.init(0x776f_7264_345f_6c65);
    var prefix: [64]u8 = undefined;
    prng.random().bytes(prefix[0..]);
    const seed = Blake2sHasher.seedAfterFixed64(&prefix);

    inline for (.{ @as(usize, 1), @as(usize, 16), @as(usize, 17), @as(usize, 33) }) |word_count| {
        var words: [4][word_count]u32 = undefined;
        var storage: [4][word_count * @sizeOf(u32)]u8 = undefined;
        var messages: [4][]const u8 = undefined;
        for (&words, 0..) |*lane_words, lane| {
            for (lane_words, 0..) |*word, word_index| {
                word.* = prng.random().int(u32);
                const byte_start = word_index * @sizeOf(u32);
                writeU32Le(
                    storage[lane][byte_start .. byte_start + @sizeOf(u32)],
                    word.*,
                );
            }
            messages[lane] = storage[lane][0..];
        }

        const Reader = struct {
            words: *const [4][word_count]u32,

            pub inline fn readWord4(reader: @This(), word_index: usize) [4]u32 {
                return .{
                    reader.words[0][word_index],
                    reader.words[1][word_index],
                    reader.words[2][word_index],
                    reader.words[3][word_index],
                };
            }
        };
        const reader = Reader{ .words = &words };

        inline for (.{ BackendMode.scalar, BackendMode.simd }) |mode| {
            const packed_hashes = Blake2sHasher.hashEqualFromSeed4WithMode(mode, seed, &messages);
            const direct = Blake2sHasher.hashEqualWordsFromSeed4WithMode(
                mode,
                seed,
                word_count,
                reader,
            );
            for (0..4) |lane| {
                try std.testing.expectEqualSlices(u8, packed_hashes[lane][0..], direct[lane][0..]);
            }
        }
    }
}

test "blake2s backend: fixed-seed scalar and simd modes cover boundaries and unaligned tails" {
    var prng = std.Random.DefaultPrng.init(0x510e_527f_ade6_82d1);
    const rng = prng.random();

    var storage: [1028]u8 = undefined;
    rng.bytes(storage[0..]);
    const boundary_lengths = [_]usize{
        0,   1,   3,   4,   15,  16,  31,  32,  63,  64,   65, 127, 128, 129,
        191, 192, 193, 255, 256, 257, 511, 512, 513, 1024,
    };
    for (0..4) |offset| {
        for (boundary_lengths) |len| {
            const input = storage[offset .. offset + len];
            const scalar_digest = Blake2sHasher.hashWithMode(.scalar, input);
            const simd_digest = Blake2sHasher.hashWithMode(.simd, input);
            try std.testing.expectEqualSlices(u8, scalar_digest[0..], simd_digest[0..]);
        }
    }
}

test "blake2s backend: four-way incremental updates preserve independent streams" {
    var prng = std.Random.DefaultPrng.init(0x7570_6461_7465_345f);
    var prefixes: [4][93]u8 = undefined;
    var updates: [4][257]u8 = undefined;
    var update_views: [4][]const u8 = undefined;
    var batched: [4]Blake2sHasher = undefined;
    var expected: [4]Blake2sHasher = undefined;
    for (0..4) |lane| {
        prng.random().bytes(prefixes[lane][0..]);
        prng.random().bytes(updates[lane][0..]);
        batched[lane] = Blake2sHasher.initWithMode(.simd);
        batched[lane].update(prefixes[lane][0..]);
        expected[lane] = batched[lane];
        update_views[lane] = updates[lane][0..];
    }

    Blake2sHasher.updateEqual4(&batched, &update_views);
    for (0..4) |lane| {
        expected[lane].update(update_views[lane]);
        try std.testing.expectEqualSlices(
            u8,
            expected[lane].finalize()[0..],
            batched[lane].finalize()[0..],
        );
    }
}

test "blake2s backend: four-way final tails preserve independent states" {
    var prng = std.Random.DefaultPrng.init(0x7461_696c_7334_5f78);
    var prefixes: [4][100]u8 = undefined;
    var tails: [4][20]u8 = undefined;
    var tail_views: [4][]const u8 = undefined;
    var states: [4]Blake2sHasher = undefined;
    var expected: [4]backend.Blake2sHash = undefined;
    for (0..4) |lane| {
        prng.random().bytes(prefixes[lane][0..]);
        prng.random().bytes(tails[lane][0..]);
        states[lane] = Blake2sHasher.initWithMode(.simd);
        states[lane].update(prefixes[lane][0..]);
        var sequential = states[lane];
        sequential.update(tails[lane][0..]);
        expected[lane] = sequential.finalize();
        tail_views[lane] = tails[lane][0..];
    }

    const actual = Blake2sHasher.finalizeEqualTail4(&states, &tail_views);
    for (0..4) |lane| {
        try std.testing.expectEqualSlices(u8, expected[lane][0..], actual[lane][0..]);
    }
}
