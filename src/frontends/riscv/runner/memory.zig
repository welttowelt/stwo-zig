//! Byte-addressable sparse memory for RISC-V execution.
//!
//! Backed by a hash map so that only touched addresses consume memory,
//! which is important for the large 32-bit address space of RISC-V.

const std = @import("std");

pub const Memory = struct {
    data: std.AutoHashMap(u32, u8),

    pub fn init(allocator: std.mem.Allocator) Memory {
        return .{
            .data = std.AutoHashMap(u32, u8).init(allocator),
        };
    }

    pub fn deinit(self: *Memory) void {
        self.data.deinit();
    }

    /// Add every initialized aligned word address without exposing byte-map
    /// iteration to commitment consumers.
    pub fn addAlignedWordAddresses(
        self: *const Memory,
        addresses: *std.AutoHashMap(u32, void),
    ) !void {
        var iterator = self.data.keyIterator();
        while (iterator.next()) |addr| {
            try addresses.put(addr.* & ~@as(u32, 3), {});
        }
    }

    // ----- Byte access -----

    pub fn readByte(self: *const Memory, addr: u32) u8 {
        return self.data.get(addr) orelse 0;
    }

    pub fn writeByte(self: *Memory, addr: u32, val: u8) void {
        self.data.put(addr, val) catch @panic("Memory.writeByte: allocation failed");
    }

    // ----- 16-bit little-endian access -----

    pub fn readU16(self: *const Memory, addr: u32) u16 {
        const lo: u16 = self.readByte(addr);
        const hi: u16 = self.readByte(addr +% 1);
        return (hi << 8) | lo;
    }

    pub fn writeU16(self: *Memory, addr: u32, val: u16) void {
        self.writeByte(addr, @truncate(val));
        self.writeByte(addr +% 1, @truncate(val >> 8));
    }

    // ----- 32-bit little-endian access -----

    pub fn readU32(self: *const Memory, addr: u32) u32 {
        const b0: u32 = self.readByte(addr);
        const b1: u32 = self.readByte(addr +% 1);
        const b2: u32 = self.readByte(addr +% 2);
        const b3: u32 = self.readByte(addr +% 3);
        return (b3 << 24) | (b2 << 16) | (b1 << 8) | b0;
    }

    pub fn writeU32(self: *Memory, addr: u32, val: u32) void {
        self.writeByte(addr, @truncate(val));
        self.writeByte(addr +% 1, @truncate(val >> 8));
        self.writeByte(addr +% 2, @truncate(val >> 16));
        self.writeByte(addr +% 3, @truncate(val >> 24));
    }

    // ----- Bulk access -----

    /// Copy a contiguous slice of bytes into memory starting at `base_addr`.
    pub fn loadSegment(self: *Memory, base_addr: u32, segment: []const u8) void {
        for (segment, 0..) |byte, i| {
            self.writeByte(base_addr +% @as(u32, @intCast(i)), byte);
        }
    }

    /// Materialize a zero-initialized ELF range. Presence matters to the
    /// memory commitment even when the guest never accesses the bytes.
    pub fn loadZeroes(self: *Memory, base_addr: u32, len: u32) void {
        for (0..len) |i| {
            self.writeByte(base_addr +% @as(u32, @intCast(i)), 0);
        }
    }

    /// Read `buf.len` bytes from guest memory starting at `addr` into `buf`.
    pub fn readSlice(self: *const Memory, addr: u32, buf: []u8) void {
        for (buf, 0..) |*b, i| {
            b.* = self.readByte(addr +% @as(u32, @intCast(i)));
        }
    }

    /// Write `data` bytes into guest memory starting at `addr`.
    pub fn writeSlice(self: *Memory, addr: u32, data: []const u8) void {
        for (data, 0..) |byte, i| {
            self.writeByte(addr +% @as(u32, @intCast(i)), byte);
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Memory readU32/writeU32 roundtrip" {
    var mem = Memory.init(std.testing.allocator);
    defer mem.deinit();

    mem.writeU32(0x1000, 0xDEAD_BEEF);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), mem.readU32(0x1000));
}

test "Memory byte-level access" {
    var mem = Memory.init(std.testing.allocator);
    defer mem.deinit();

    mem.writeByte(0x10, 0xAB);
    try std.testing.expectEqual(@as(u8, 0xAB), mem.readByte(0x10));
}

test "Memory readByte returns 0 for untouched addresses" {
    var mem = Memory.init(std.testing.allocator);
    defer mem.deinit();

    try std.testing.expectEqual(@as(u8, 0), mem.readByte(0x42));
}

test "Memory little-endian byte order" {
    var mem = Memory.init(std.testing.allocator);
    defer mem.deinit();

    mem.writeU32(0x100, 0x04030201);
    try std.testing.expectEqual(@as(u8, 0x01), mem.readByte(0x100));
    try std.testing.expectEqual(@as(u8, 0x02), mem.readByte(0x101));
    try std.testing.expectEqual(@as(u8, 0x03), mem.readByte(0x102));
    try std.testing.expectEqual(@as(u8, 0x04), mem.readByte(0x103));
}

test "Memory readU16/writeU16 roundtrip" {
    var mem = Memory.init(std.testing.allocator);
    defer mem.deinit();

    mem.writeU16(0x200, 0xBEEF);
    try std.testing.expectEqual(@as(u16, 0xBEEF), mem.readU16(0x200));
}

test "Memory loadSegment" {
    var mem = Memory.init(std.testing.allocator);
    defer mem.deinit();

    const data = [_]u8{ 0x10, 0x20, 0x30, 0x40 };
    mem.loadSegment(0x2000, &data);

    try std.testing.expectEqual(@as(u32, 0x40302010), mem.readU32(0x2000));
}

test "Memory readSlice/writeSlice roundtrip" {
    var mem = Memory.init(std.testing.allocator);
    defer mem.deinit();

    const data = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE };
    mem.writeSlice(0x3000, &data);

    var buf: [6]u8 = undefined;
    mem.readSlice(0x3000, &buf);
    try std.testing.expectEqualSlices(u8, &data, &buf);
}

test "Memory readSlice returns zeros for untouched" {
    var mem = Memory.init(std.testing.allocator);
    defer mem.deinit();

    var buf: [4]u8 = undefined;
    mem.readSlice(0x5000, &buf);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, &buf);
}
