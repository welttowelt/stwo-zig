//! Public LogUp compensation terms for a Stark-V RV32IM statement.
//!
//! This is an exact port of pinned Stark-V `PublicData::logup_sum`. It must be
//! added to the committed components' aggregate interaction claim only after
//! the same relation challenges, clock model, memory-access bus, and Merkle
//! bus are wired. Until then, callers must remain fail-closed.

const std = @import("std");
const M31 = @import("../../../core/fields/m31.zig").M31;
const QM31 = @import("../../../core/fields/qm31.zig").QM31;
const public_data = @import("public_data.zig");
const relation_challenges = @import("relation_challenges.zig");

pub const Error = error{ ZeroDenominator, ClockOverflow };

/// Public compensation split by independent LogUp relation. These domains
/// must cancel independently; offsetting a forged memory claim with a Merkle
/// or CPU-state claim is not valid.
pub const Sums = struct {
    registers_state: QM31,
    merkle: QM31,
    memory_access: QM31,

    pub fn total(self: Sums) QM31 {
        return self.registers_state.add(self.merkle).add(self.memory_access);
    }
};

/// Exact verifier-side compensation for public CPU, root, register, input,
/// and output boundary values.
pub fn sum(
    data: *const public_data.PublicData,
    relations: *const relation_challenges.Relations,
) Error!QM31 {
    return (try relationSums(data, relations)).total();
}

pub fn relationSums(
    data: *const public_data.PublicData,
    relations: *const relation_challenges.Relations,
) Error!Sums {
    var result = Sums{
        .registers_state = QM31.zero(),
        .merkle = QM31.zero(),
        .memory_access = QM31.zero(),
    };

    // Registers-state bus: public initial emit and final consume. Stark-V
    // instruction clocks start at one, hence the `clock + 1` final boundary.
    const final_clock = std.math.add(u32, data.clock, 1) catch return error.ClockOverflow;
    try addInverse(&result.registers_state, relations.registers_state.combineBase(.{
        base(data.initial_pc),
        base(1),
    }), .emit);
    try addInverse(&result.registers_state, relations.registers_state.combineBase(.{
        base(data.final_pc),
        base(final_clock),
    }), .consume);

    // Every present root is emitted once on Merkle(index, depth, value, root).
    for ([_]?u32{ data.program_root, data.initial_rw_root, data.final_rw_root }) |maybe_root| {
        if (maybe_root) |root| {
            try addInverse(&result.merkle, relations.merkle.combineBase(.{
                M31.zero(), M31.zero(), base(root), base(root),
            }), .emit);
        }
    }

    // Register address space: emit the clock-zero initial word and consume
    // the word at its final access clock, including never-accessed registers.
    for (0..32) |index| {
        const addr = base(@intCast(index));
        try addInverse(&result.memory_access, relations.memory_access.combineBase(memoryTuple(
            0,
            addr,
            M31.zero(),
            data.initial_regs[index],
        )), .emit);
        try addInverse(&result.memory_access, relations.memory_access.combineBase(memoryTuple(
            0,
            addr,
            base(data.reg_last_clock[index]),
            data.final_regs[index],
        )), .consume);
    }

    // Public input words are initial RW-memory values at clock zero. Address
    // arithmetic deliberately mirrors Rust wrapping-add and saturating-mul.
    for (data.io_entries.input_words, 0..) |word, index| {
        const word_offset: u32 = @truncate(index);
        const addr = data.io_entries.input_start +% (word_offset *| 4);
        try addInverse(&result.memory_access, relations.memory_access.combineBase(memoryTuple(
            1,
            base(addr),
            M31.zero(),
            word,
        )), .emit);
    }

    // Public output words are consumed at their last committed access clock.
    for (data.io_entries.output_words) |word| {
        try addInverse(&result.memory_access, relations.memory_access.combineBase(memoryTuple(
            1,
            base(word.addr),
            base(word.clock),
            word.value,
        )), .consume);
    }
    return result;
}

const Direction = enum { emit, consume };

fn addInverse(result: *QM31, denominator: QM31, direction: Direction) Error!void {
    const inverse = denominator.inv() catch return error.ZeroDenominator;
    result.* = switch (direction) {
        .emit => result.add(inverse),
        .consume => result.sub(inverse),
    };
}

fn memoryTuple(addr_space: u32, addr: M31, clock: M31, word: u32) [7]M31 {
    return .{
        base(addr_space),
        addr,
        clock,
        base(@as(u8, @truncate(word))),
        base(@as(u8, @truncate(word >> 8))),
        base(@as(u8, @truncate(word >> 16))),
        base(@as(u8, @truncate(word >> 24))),
    };
}

fn base(value: anytype) M31 {
    return M31.fromU64(@as(u64, value));
}

fn emptyPublicData() public_data.PublicData {
    return .{
        .initial_pc = 0,
        .final_pc = 0,
        .clock = 0,
        .initial_regs = .{0} ** 32,
        .final_regs = .{0} ** 32,
        .reg_last_clock = .{0} ** 32,
        .program_root = null,
        .initial_rw_root = null,
        .final_rw_root = null,
        .io_entries = .{
            .input_start = 0,
            .input_len = 0,
            .input_words = &.{},
            .output_len = 0,
            .output_len_addr = 0,
            .output_data_addr = 0,
            .output_words = &.{},
        },
    };
}

test "public LogUp: exact pinned Stark-V dummy-relation vector" {
    var data = emptyPublicData();
    data.initial_pc = 0x1000;
    data.final_pc = 0x1040;
    data.clock = 17;
    data.initial_regs[1] = 0x0403_0201;
    data.final_regs[1] = 0x0807_0605;
    data.reg_last_clock[1] = 9;
    data.initial_regs[31] = 11;
    data.final_regs[31] = 12;
    data.program_root = 101;
    data.final_rw_root = 303;
    const input_words = [_]u32{ 0x0403_0201, 0x0000_0605 };
    const output_words = [_]public_data.OutputWord{
        .{ .addr = 0x0010_0004, .value = 4, .clock = 15 },
        .{ .addr = 0x0010_0008, .value = 0x4443_4241, .clock = 16 },
    };
    data.io_entries = .{
        .input_start = 0x0018_0000,
        .input_len = 6,
        .input_words = &input_words,
        .output_len = 4,
        .output_len_addr = 0x0010_0004,
        .output_data_addr = 0x0010_0008,
        .output_words = &output_words,
    };

    const actual = try sum(&data, &relation_challenges.Relations.dummy());
    const expected = [_]u32{ 673401415, 755770749, 1943640833, 2140834143 };
    for (actual.toM31Array(), expected) |limb, expected_limb| {
        try std.testing.expectEqual(expected_limb, limb.toU32());
    }
}

test "public LogUp: clock-zero state and untouched register remain constrained" {
    const relations = relation_challenges.Relations.dummy();
    var data = emptyPublicData();
    data.initial_pc = 7;
    data.final_pc = 8;
    try std.testing.expect(!(try sum(&data, &relations)).eql(QM31.zero()));
    data.final_pc = 7;
    try std.testing.expect((try sum(&data, &relations)).eql(QM31.zero()));

    data.initial_pc = 1;
    data.final_pc = 1;
    data.initial_regs[31] = 11;
    data.final_regs[31] = 12;
    try std.testing.expect(!(try sum(&data, &relations)).eql(QM31.zero()));
    data.final_regs[31] = 11;
    try std.testing.expect((try sum(&data, &relations)).eql(QM31.zero()));
}

test "public LogUp: final clock overflow fails closed" {
    const relations = relation_challenges.Relations.dummy();
    var data = emptyPublicData();
    data.clock = std.math.maxInt(u32);
    try std.testing.expectError(error.ClockOverflow, sum(&data, &relations));
}
