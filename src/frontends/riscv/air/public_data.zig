//! Public statement data for RV32IM proofs.
//!
//! The field model and transcript order mirror Stark-V's `PublicData` at the
//! pinned RISC-V oracle revision. This module only binds the values into the
//! Fiat-Shamir transcript. The corresponding public MemoryAccess LogUp terms
//! must be added when that bus is wired; transcript binding alone does not
//! prove that these values belong to the committed execution trace.

const std = @import("std");

/// A final public output word and the clock of its last memory access.
pub const OutputWord = struct {
    addr: u32,
    value: u32,
    clock: u32,
};

/// Public input and output memory entries.
pub const IoEntries = struct {
    /// Input region start address.
    input_start: u32,
    /// Input length in bytes.
    input_len: u32,
    /// Little-endian input words, contiguous from `input_start`.
    input_words: []const u32,
    /// Output length in bytes.
    output_len: u32,
    /// Address of the output length word.
    output_len_addr: u32,
    /// Address of the first output data byte.
    output_data_addr: u32,
    /// Output length word followed by the output data words.
    output_words: []const OutputWord,
};

/// Public execution state carried by an RV32IM proof.
pub const PublicData = struct {
    initial_pc: u32,
    final_pc: u32,
    /// Total executed cycles in the Stark-V public-data clock model.
    clock: u32,
    initial_regs: [32]u32,
    final_regs: [32]u32,
    /// Last access clock for every register, or zero if never accessed.
    reg_last_clock: [32]u32,
    program_root: ?u32,
    initial_rw_root: ?u32,
    final_rw_root: ?u32,
    io_entries: IoEntries,

    /// Mix fields in the exact order used by pinned Stark-V `PublicData`.
    pub fn mixInto(self: *const PublicData, channel: anytype) void {
        channel.mixU32s(&.{ self.initial_pc, self.final_pc, self.clock });
        channel.mixU32s(&self.initial_regs);
        channel.mixU32s(&self.final_regs);
        channel.mixU32s(&self.reg_last_clock);

        channel.mixU32s(&.{
            @intFromBool(self.program_root != null),
            @intFromBool(self.initial_rw_root != null),
            @intFromBool(self.final_rw_root != null),
        });
        channel.mixU32s(&.{
            self.program_root orelse 0,
            self.initial_rw_root orelse 0,
            self.final_rw_root orelse 0,
        });

        channel.mixU32s(&.{
            self.io_entries.input_start,
            self.io_entries.input_len,
            self.io_entries.output_len_addr,
            self.io_entries.output_data_addr,
            self.io_entries.output_len,
            @intCast(self.io_entries.output_words.len),
        });
        channel.mixU32s(self.io_entries.input_words);
        for (self.io_entries.output_words) |word| {
            channel.mixU32s(&.{ word.addr, word.value, word.clock });
        }
    }
};

/// Pack public input bytes into Stark-V's contiguous little-endian words.
/// The unused high bytes of the final word are zero.
pub fn packInputWords(allocator: std.mem.Allocator, bytes: []const u8) ![]u32 {
    const words = try allocator.alloc(u32, std.math.divCeil(usize, bytes.len, 4) catch unreachable);
    errdefer allocator.free(words);
    for (words, 0..) |*word, word_index| {
        var buf = [_]u8{0} ** 4;
        const start = word_index * 4;
        const end = @min(start + 4, bytes.len);
        @memcpy(buf[0 .. end - start], bytes[start..end]);
        word.* = std.mem.readInt(u32, &buf, .little);
    }
    return words;
}

const RecordingChannel = struct {
    words: [256]u32 = undefined,
    words_len: usize = 0,
    call_lengths: [32]usize = undefined,
    calls_len: usize = 0,

    fn mixU32s(self: *RecordingChannel, values: []const u32) void {
        std.debug.assert(self.calls_len < self.call_lengths.len);
        std.debug.assert(self.words_len + values.len <= self.words.len);
        self.call_lengths[self.calls_len] = values.len;
        self.calls_len += 1;
        @memcpy(self.words[self.words_len..][0..values.len], values);
        self.words_len += values.len;
    }
};

fn sequence(comptime n: usize, start: u32) [n]u32 {
    var result: [n]u32 = undefined;
    for (&result, 0..) |*value, i| value.* = start + @as(u32, @intCast(i));
    return result;
}

test "public data: transcript mix order matches pinned Stark-V" {
    const initial_regs = sequence(32, 100);
    const final_regs = sequence(32, 200);
    const reg_last_clock = sequence(32, 300);
    const input_words = [_]u32{ 0x0403_0201, 0x0000_0605 };
    const output_words = [_]OutputWord{
        .{ .addr = 0x0010_0004, .value = 5, .clock = 40 },
        .{ .addr = 0x0010_0008, .value = 0x4443_4241, .clock = 41 },
    };
    const public_data = PublicData{
        .initial_pc = 11,
        .final_pc = 22,
        .clock = 33,
        .initial_regs = initial_regs,
        .final_regs = final_regs,
        .reg_last_clock = reg_last_clock,
        .program_root = 44,
        .initial_rw_root = null,
        .final_rw_root = 66,
        .io_entries = .{
            .input_start = 0x0018_0000,
            .input_len = 6,
            .input_words = &input_words,
            .output_len = 5,
            .output_len_addr = 0x0010_0004,
            .output_data_addr = 0x0010_0008,
            .output_words = &output_words,
        },
    };

    var channel = RecordingChannel{};
    public_data.mixInto(&channel);

    const expected_call_lengths = [_]usize{ 3, 32, 32, 32, 3, 3, 6, 2, 3, 3 };
    try std.testing.expectEqualSlices(
        usize,
        &expected_call_lengths,
        channel.call_lengths[0..channel.calls_len],
    );

    var expected: [119]u32 = undefined;
    var cursor: usize = 0;
    const append = struct {
        fn values(dst: []u32, at: *usize, src: []const u32) void {
            @memcpy(dst[at.*..][0..src.len], src);
            at.* += src.len;
        }
    }.values;
    append(&expected, &cursor, &.{ 11, 22, 33 });
    append(&expected, &cursor, &initial_regs);
    append(&expected, &cursor, &final_regs);
    append(&expected, &cursor, &reg_last_clock);
    append(&expected, &cursor, &.{ 1, 0, 1 });
    append(&expected, &cursor, &.{ 44, 0, 66 });
    append(&expected, &cursor, &.{ 0x0018_0000, 6, 0x0010_0004, 0x0010_0008, 5, 2 });
    append(&expected, &cursor, &input_words);
    append(&expected, &cursor, &.{ 0x0010_0004, 5, 40 });
    append(&expected, &cursor, &.{ 0x0010_0008, 0x4443_4241, 41 });
    try std.testing.expectEqual(expected.len, cursor);
    try std.testing.expectEqualSlices(u32, &expected, channel.words[0..channel.words_len]);
}

test "public data: absent roots and empty input preserve upstream mix calls" {
    const public_data = PublicData{
        .initial_pc = 1,
        .final_pc = 2,
        .clock = 3,
        .initial_regs = .{0} ** 32,
        .final_regs = .{0} ** 32,
        .reg_last_clock = .{0} ** 32,
        .program_root = null,
        .initial_rw_root = null,
        .final_rw_root = null,
        .io_entries = .{
            .input_start = 4,
            .input_len = 0,
            .input_words = &.{},
            .output_len = 0,
            .output_len_addr = 5,
            .output_data_addr = 6,
            .output_words = &.{},
        },
    };

    var channel = RecordingChannel{};
    public_data.mixInto(&channel);
    try std.testing.expectEqualSlices(
        usize,
        &.{ 3, 32, 32, 32, 3, 3, 6, 0 },
        channel.call_lengths[0..channel.calls_len],
    );
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 0, 0, 0, 0 }, channel.words[99..105]);
}

test "public data: pack input words is little endian with zero padding" {
    const bytes = [_]u8{ 1, 2, 3, 4, 5, 6 };
    const words = try packInputWords(std.testing.allocator, &bytes);
    defer std.testing.allocator.free(words);
    try std.testing.expectEqualSlices(u32, &.{ 0x0403_0201, 0x0000_0605 }, words);

    const empty = try packInputWords(std.testing.allocator, &.{});
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}
