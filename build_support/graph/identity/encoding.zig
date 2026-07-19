//! Length-delimited canonical encoding for product identity digests.

const std = @import("std");

pub const Digest = [32]u8;
pub const Hasher = std.crypto.hash.sha2.Sha256;

pub fn digestBytes(value: []const u8) Digest {
    var result: Digest = undefined;
    Hasher.hash(value, &result, .{});
    return result;
}

pub fn hashField(hasher: *Hasher, value: []const u8) void {
    hashInt(hasher, value.len);
    hasher.update(value);
}

pub fn hashOptionalField(hasher: *Hasher, value: ?[]const u8) void {
    hashBool(hasher, value != null);
    if (value) |present| hashField(hasher, present);
}

pub fn hashDigest(hasher: *Hasher, value: Digest) void {
    hasher.update(&value);
}

pub fn hashOptionalDigest(hasher: *Hasher, value: ?Digest) void {
    hashBool(hasher, value != null);
    if (value) |present| hashDigest(hasher, present);
}

pub fn hashBool(hasher: *Hasher, value: bool) void {
    hasher.update(if (value) "\x01" else "\x00");
}

pub fn hashInt(hasher: *Hasher, value: anytype) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, @intCast(value), .big);
    hasher.update(&encoded);
}
