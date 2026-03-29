//! Binary trace and memory file reader for cairo-vm output.
//!
//! ## Trace format (from cairo-vm)
//! Each entry is 24 bytes, little-endian:
//!   [ap: u64] [fp: u64] [pc: u64]
//!
//! ## Memory format (from cairo-vm)
//! Each entry is 40 bytes, little-endian:
//!   [address: u64] [value: 32 bytes Felt252 LE]
//!
//! These formats are written by `cairo-vm`'s `write_encoded_trace` and
//! `write_encoded_memory` functions.

const std = @import("std");
const M31 = @import("../../../core/fields/m31.zig").M31;
const cpu = @import("../common/cpu.zig");
const memory_mod = @import("../common/memory.zig");
const felt252_mod = @import("../common/felt252.zig");

const CasmState = cpu.CasmState;
const Felt252 = felt252_mod.Felt252;

pub const TraceReaderError = error{
    InvalidTraceFileSize,
    InvalidMemoryFileSize,
    AddressOutOfBounds,
    OutOfMemory,
};

/// A raw trace entry as read from the binary file.
pub const RawTraceEntry = struct {
    ap: u64,
    fp: u64,
    pc: u64,

    /// Convert to CasmState (truncates u64 to M31-range u32).
    pub fn toCasmState(self: RawTraceEntry) CasmState {
        return .{
            .pc = M31.fromCanonical(@intCast(self.pc & 0x7FFFFFFF)),
            .ap = M31.fromCanonical(@intCast(self.ap & 0x7FFFFFFF)),
            .fp = M31.fromCanonical(@intCast(self.fp & 0x7FFFFFFF)),
        };
    }
};

/// A raw memory entry as read from the binary file.
pub const RawMemoryEntry = struct {
    address: u64,
    value: [32]u8, // Felt252 in little-endian bytes

    /// Convert the 32-byte LE value to [8]u32 (F252 representation).
    pub fn toF252(self: RawMemoryEntry) memory_mod.F252 {
        var result: [8]u32 = undefined;
        for (0..8) |i| {
            result[i] = std.mem.readInt(u32, self.value[i * 4 ..][0..4], .little);
        }
        return result;
    }

    /// Convert to Felt252.
    pub fn toFelt252(self: RawMemoryEntry) Felt252 {
        return Felt252.fromU32x8(self.toF252());
    }
};

/// Read a binary trace file produced by cairo-vm.
///
/// Returns an array of raw trace entries. Caller owns the returned slice.
pub fn readTraceFile(
    allocator: std.mem.Allocator,
    path: []const u8,
) ![]RawTraceEntry {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    const file_size = stat.size;

    if (file_size % 24 != 0) return TraceReaderError.InvalidTraceFileSize;
    const n_entries = file_size / 24;

    const entries = try allocator.alloc(RawTraceEntry, n_entries);
    errdefer allocator.free(entries);

    const bytes = try file.readAll(std.mem.sliceAsBytes(entries));
    if (bytes != file_size) return TraceReaderError.InvalidTraceFileSize;

    // Convert from LE if needed (on big-endian platforms).
    if (comptime @import("builtin").target.cpu.arch.endian() != .little) {
        for (entries) |*entry| {
            entry.ap = std.mem.littleToNative(u64, @bitCast(entry.ap));
            entry.fp = std.mem.littleToNative(u64, @bitCast(entry.fp));
            entry.pc = std.mem.littleToNative(u64, @bitCast(entry.pc));
        }
    }

    return entries;
}

/// Read a binary memory file produced by cairo-vm.
///
/// Returns an array of raw memory entries. Caller owns the returned slice.
pub fn readMemoryFile(
    allocator: std.mem.Allocator,
    path: []const u8,
) ![]RawMemoryEntry {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    const file_size = stat.size;

    if (file_size % 40 != 0) return TraceReaderError.InvalidMemoryFileSize;
    const n_entries = file_size / 40;

    const buffer = try allocator.alloc(u8, file_size);
    defer allocator.free(buffer);

    const bytes_read = try file.readAll(buffer);
    if (bytes_read != file_size) return TraceReaderError.InvalidMemoryFileSize;

    const entries = try allocator.alloc(RawMemoryEntry, n_entries);
    errdefer allocator.free(entries);

    for (0..n_entries) |i| {
        const offset = i * 40;
        entries[i] = .{
            .address = std.mem.readInt(u64, buffer[offset..][0..8], .little),
            .value = buffer[offset + 8 ..][0..32].*,
        };
    }

    return entries;
}

/// Summary statistics from reading trace + memory files.
pub const TraceStats = struct {
    trace_entries: usize,
    memory_entries: usize,
    max_address: u64,
    small_values: usize,
    large_values: usize,

    pub fn format(
        self: TraceStats,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print(
            "trace_entries={d} memory_entries={d} max_addr={d} small={d} large={d}",
            .{ self.trace_entries, self.memory_entries, self.max_address, self.small_values, self.large_values },
        );
    }
};

/// Compute summary statistics from raw memory entries.
pub fn memoryStats(entries: []const RawMemoryEntry) TraceStats {
    var max_addr: u64 = 0;
    var small: usize = 0;
    var large: usize = 0;

    for (entries) |entry| {
        if (entry.address > max_addr) max_addr = entry.address;
        const f = entry.toFelt252();
        if (f.isSmall()) small += 1 else large += 1;
    }

    return .{
        .trace_entries = 0,
        .memory_entries = entries.len,
        .max_address = max_addr,
        .small_values = small,
        .large_values = large,
    };
}

// ---------------------------------------------------------------
// Tests
// ---------------------------------------------------------------

test "trace_reader: raw trace entry to CasmState" {
    const entry = RawTraceEntry{ .ap = 100, .fp = 200, .pc = 42 };
    const state = entry.toCasmState();
    try std.testing.expectEqual(@as(u32, 42), state.pc.v);
    try std.testing.expectEqual(@as(u32, 100), state.ap.v);
    try std.testing.expectEqual(@as(u32, 200), state.fp.v);
}

test "trace_reader: raw memory entry to F252" {
    var entry: RawMemoryEntry = .{ .address = 0, .value = .{0} ** 32 };
    // Set first 4 bytes to 0x01000000 (LE) = 1
    entry.value[0] = 1;
    const f252 = entry.toF252();
    try std.testing.expectEqual(@as(u32, 1), f252[0]);
    try std.testing.expectEqual(@as(u32, 0), f252[1]);
}

test "trace_reader: raw memory entry to felt252" {
    var entry: RawMemoryEntry = .{ .address = 0, .value = .{0} ** 32 };
    entry.value[0] = 42;
    const felt = entry.toFelt252();
    try std.testing.expect(felt.eql(Felt252.fromU64(42)));
}
