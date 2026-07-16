const std = @import("std");
const builtin = @import("builtin");
const channel_blake2s = @import("../channel/blake2s.zig");
const m31 = @import("../fields/m31.zig");
const blake2_hash = @import("../vcs/blake2_hash.zig");

const M31 = m31.M31;

pub const LEAF_PREFIX = makePrefix("leaf");
pub const NODE_PREFIX = makePrefix("node");

pub const Blake2sMerkleHasher = Blake2sMerkleHasherGeneric(false);
pub const Blake2sM31MerkleHasher = Blake2sMerkleHasherGeneric(true);

pub fn Blake2sMerkleHasherGeneric(comptime is_m31_output: bool) type {
    const InnerHasher = blake2_hash.Blake2sHasherGeneric(is_m31_output);
    const pack_chunk_elems = 32;
    return struct {
        inner: InnerHasher,
        pub const Hash = blake2_hash.Blake2sHash;
        pub const NodeSeed = InnerHasher.Fixed64Seed;

        const Self = @This();

        pub fn init() Self {
            return .{ .inner = InnerHasher.init() };
        }

        pub fn defaultWithInitialState() Self {
            return Self.init();
        }

        pub fn hashChildren(children: struct { left: Hash, right: Hash }) Hash {
            return InnerHasher.concatAndHash(children.left, children.right);
        }

        /// Pre-hashed node-domain separator state used to avoid reprocessing
        /// `NODE_PREFIX` for every parent hash on one Merkle layer.
        pub fn nodeSeed() NodeSeed {
            return InnerHasher.seedAfterFixed64(&NODE_PREFIX);
        }

        pub fn leafSeed() NodeSeed {
            return InnerHasher.seedAfterFixed64(&LEAF_PREFIX);
        }

        pub fn hashChildrenWithSeed(seed: NodeSeed, children: struct { left: Hash, right: Hash }) Hash {
            _ = seed;
            return InnerHasher.concatAndHash(children.left, children.right);
        }

        pub fn hashChildrenWithSeed4(seed: NodeSeed, children: *const [8]Hash) [4]Hash {
            _ = seed;
            var out: [4]Hash = undefined;
            for (&out, 0..) |*digest, lane| digest.* = InnerHasher.concatAndHash(
                children[2 * lane],
                children[2 * lane + 1],
            );
            return out;
        }

        pub fn hashPackedLeavesWithSeed4(seed: NodeSeed, messages: *const [4][]const u8) [4]Hash {
            _ = seed;
            var out: [4]Hash = undefined;
            for (&out, messages) |*digest, message| digest.* = InnerHasher.hash(message);
            return out;
        }


        pub fn updateLeaf(self: *Self, column_values: []const M31) void {
            if (column_values.len == 0) return;

            if (builtin.cpu.arch.endian() == .little) {
                // M31 is represented as canonical u32 words, so little-endian
                // hosts can stream the bytes directly without repacking.
                self.inner.update(std.mem.sliceAsBytes(column_values));
                return;
            } else {
                var at: usize = 0;
                var bytes: [pack_chunk_elems * 4]u8 = undefined;
                while (at < column_values.len) {
                    const chunk = @min(pack_chunk_elems, column_values.len - at);
                    for (0..chunk) |i| {
                        const value_bytes = column_values[at + i].toBytesLe();
                        const start = i * 4;
                        @memcpy(bytes[start .. start + 4], value_bytes[0..]);
                    }
                    self.inner.update(bytes[0 .. chunk * 4]);
                    at += chunk;
                }
            }
        }

        /// Updates a leaf hasher from pre-packed canonical little-endian M31 bytes.
        ///
        /// Preconditions:
        /// - `packed_bytes.len` is a multiple of 4.
        pub fn updateLeafPackedBytes(self: *Self, packed_bytes: []const u8) void {
            std.debug.assert((packed_bytes.len & 3) == 0);
            if (packed_bytes.len == 0) return;
            self.inner.update(packed_bytes);
        }

        pub fn finalize(self: *Self) Hash {
            return self.inner.finalize();
        }
    };
}

pub fn Blake2sMerkleChannelGeneric(comptime is_m31_output: bool) type {
    return struct {
        pub fn mixRoot(
            channel: *channel_blake2s.Blake2sChannelGeneric(is_m31_output),
            root: blake2_hash.Blake2sHash,
        ) void {
            const digest = channel.digestBytes();
            channel.updateDigest(
                blake2_hash.Blake2sHasherGeneric(is_m31_output).concatAndHash(digest, root),
            );
        }
    };
}

pub const Blake2sMerkleChannel = Blake2sMerkleChannelGeneric(false);
pub const Blake2sM31MerkleChannel = Blake2sMerkleChannelGeneric(true);

fn makePrefix(comptime tag: []const u8) [64]u8 {
    var out: [64]u8 = [_]u8{0} ** 64;
    inline for (tag, 0..) |c, i| out[i] = c;
    return out;
}

test "vcs_lifted blake2: hash children deterministic" {
    const left = [_]u8{1} ** 32;
    const right = [_]u8{2} ** 32;
    const h1 = Blake2sMerkleHasher.hashChildren(.{ .left = left, .right = right });
    const h2 = Blake2sMerkleHasher.hashChildren(.{ .left = left, .right = right });
    try std.testing.expect(std.mem.eql(u8, h1[0..], h2[0..]));
}

test "vcs_lifted blake2: mix root changes channel digest" {
    var channel = channel_blake2s.Blake2sChannel{};
    const before = channel.digestBytes();
    Blake2sMerkleChannel.mixRoot(&channel, [_]u8{3} ** 32);
    try std.testing.expect(!std.mem.eql(u8, before[0..], channel.digestBytes()[0..]));
}

test "vcs_lifted blake2: updateLeaf matches plain explicit byte packing" {
    var prng = std.Random.DefaultPrng.init(0x5ca1_ab1e_1234_5678);
    const rng = prng.random();
    var values: [65]M31 = undefined;
    for (values[0..]) |*value| {
        value.* = M31.fromU64(rng.int(u32));
    }

    var lifted = Blake2sMerkleHasher.defaultWithInitialState();
    lifted.updateLeaf(values[0..]);
    const digest = lifted.finalize();

    var manual = blake2_hash.Blake2sHasher.init();
    for (values[0..]) |value| {
        const encoded = value.toBytesLe();
        manual.update(encoded[0..]);
    }
    const expected = manual.finalize();
    try std.testing.expect(std.mem.eql(u8, digest[0..], expected[0..]));
}

test "vcs_lifted blake2: updateLeafPackedBytes matches updateLeaf" {
    var prng = std.Random.DefaultPrng.init(0x1234_5678_9abc_def0);
    const rng = prng.random();
    var values: [96]M31 = undefined;
    for (values[0..]) |*value| {
        value.* = M31.fromU64(rng.int(u32));
    }

    var packed_bytes: [96 * 4]u8 = undefined;
    if (builtin.cpu.arch.endian() == .little) {
        @memcpy(packed_bytes[0..], std.mem.sliceAsBytes(values[0..]));
    } else {
        for (values[0..], 0..) |value, i| {
            const encoded = value.toBytesLe();
            const start = i * 4;
            @memcpy(packed_bytes[start .. start + 4], encoded[0..]);
        }
    }

    var from_values = Blake2sMerkleHasher.defaultWithInitialState();
    from_values.updateLeaf(values[0..]);
    const digest_values = from_values.finalize();

    var from_packed = Blake2sMerkleHasher.defaultWithInitialState();
    from_packed.updateLeafPackedBytes(packed_bytes[0..]);
    const digest_packed = from_packed.finalize();

    try std.testing.expect(std.mem.eql(u8, digest_values[0..], digest_packed[0..]));
}

test "vcs_lifted blake2: hashChildrenWithSeed matches fixed parent hash" {
    const left = [_]u8{7} ** 32;
    const right = [_]u8{11} ** 32;
    const seeded = Blake2sMerkleHasher.hashChildrenWithSeed(
        Blake2sMerkleHasher.nodeSeed(),
        .{ .left = left, .right = right },
    );
    const direct = Blake2sMerkleHasher.hashChildren(.{ .left = left, .right = right });
    try std.testing.expect(std.mem.eql(u8, seeded[0..], direct[0..]));
}
