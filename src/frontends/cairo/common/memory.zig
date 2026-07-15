//! Cairo memory model.
//!
//! Memory maps addresses to values, split into two representations for efficiency:
//! - Small values: fit in 72 bits (N_M31_IN_SMALL * BITS_PER_WORD = 8 * 9 = 72)
//! - F252 values: full 252-bit field elements stored as 8 x u32
//!
//! The `EncodedMemoryValueId` packs a table selector (bit 30) and an index
//! into a single u32.

const std = @import("std");
const felt252_mod = @import("felt252.zig");

const Felt252 = felt252_mod.Felt252;

/// Number of M31 elements in a small Felt252 (72 bits / 9 bits per word).
pub const N_M31_IN_SMALL_FELT252: usize = 8;

/// Bit 30 is set for F252 (large) value IDs.
pub const LARGE_MEMORY_VALUE_ID_BASE: u32 = 0x4000_0000;

/// Sentinel for empty/unused memory addresses.
pub const DEFAULT_ID: u32 = LARGE_MEMORY_VALUE_ID_BASE - 1;

/// F252 raw representation: 8 x u32 limbs (little-endian).
pub const F252 = [8]u32;

/// Packed memory value identifier.
///
/// Bit 30 is the tag:
///   - 0 => Small value (index into `small_values` table)
///   - 1 => F252 value (index into `f252_values` table)
///   - `DEFAULT_ID` (0x3FFFFFFF) => Empty slot
pub const EncodedMemoryValueId = struct {
    raw: u32,

    pub const EMPTY: EncodedMemoryValueId = .{ .raw = DEFAULT_ID };

    pub fn small(idx: u32) EncodedMemoryValueId {
        std.debug.assert(idx < LARGE_MEMORY_VALUE_ID_BASE);
        return .{ .raw = idx };
    }

    pub fn f252(idx: u32) EncodedMemoryValueId {
        return .{ .raw = idx | LARGE_MEMORY_VALUE_ID_BASE };
    }

    pub fn isSmall(self: EncodedMemoryValueId) bool {
        return self.raw < LARGE_MEMORY_VALUE_ID_BASE and self.raw != DEFAULT_ID;
    }

    pub fn isLarge(self: EncodedMemoryValueId) bool {
        return (self.raw & LARGE_MEMORY_VALUE_ID_BASE) != 0;
    }

    pub fn isEmpty(self: EncodedMemoryValueId) bool {
        return self.raw == DEFAULT_ID;
    }

    pub fn index(self: EncodedMemoryValueId) u32 {
        return self.raw & (LARGE_MEMORY_VALUE_ID_BASE - 1);
    }
};

/// Memory configuration.
pub const MemoryConfig = struct {
    /// Maximum value that qualifies as "small" (default: 2^72 - 1).
    small_max: u128 = (1 << 72) - 1,
    /// Log2 capacity of the small value table (default: 24 => 16M entries).
    log_small_value_capacity: u32 = 24,
};

/// Cairo memory: maps addresses to deduplicated values.
pub const Memory = struct {
    config: MemoryConfig,
    /// Address → encoded value ID. Indexed by flat address.
    address_to_id: []EncodedMemoryValueId,
    /// Table of large (252-bit) values.
    f252_values: []F252,
    /// Table of small values (fit in 72 bits).
    small_values: []u128,

    pub fn deinit(self: *Memory, allocator: std.mem.Allocator) void {
        allocator.free(self.address_to_id);
        allocator.free(self.f252_values);
        allocator.free(self.small_values);
        self.* = undefined;
    }

    /// Look up a memory value by address.
    pub fn get(self: Memory, address: u32) ?MemoryValue {
        if (address >= self.address_to_id.len) return null;
        const id = self.address_to_id[address];
        if (id.isEmpty()) return null;
        if (id.isSmall()) {
            return .{ .small = self.small_values[id.index()] };
        }
        return .{ .f252 = self.f252_values[id.index()] };
    }
};

/// A resolved memory value.
pub const MemoryValue = union(enum) {
    small: u128,
    f252: F252,

    /// Convert to Felt252.
    pub fn toFelt252(self: MemoryValue) Felt252 {
        return switch (self) {
            .small => |v| Felt252{ .limbs = .{
                @truncate(v),
                @truncate(v >> 64),
                0,
                0,
            } },
            .f252 => |v| Felt252.fromU32x8(v),
        };
    }
};

// ---------------------------------------------------------------
// Tests
// ---------------------------------------------------------------

test "memory: encoded value id tagging" {
    const small_id = EncodedMemoryValueId.small(42);
    try std.testing.expect(small_id.isSmall());
    try std.testing.expect(!small_id.isLarge());
    try std.testing.expect(!small_id.isEmpty());
    try std.testing.expectEqual(@as(u32, 42), small_id.index());

    const large_id = EncodedMemoryValueId.f252(7);
    try std.testing.expect(!large_id.isSmall());
    try std.testing.expect(large_id.isLarge());
    try std.testing.expectEqual(@as(u32, 7), large_id.index());

    try std.testing.expect(EncodedMemoryValueId.EMPTY.isEmpty());
}
