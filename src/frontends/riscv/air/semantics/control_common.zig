//! Shared lookup request types for control-flow and upper-immediate families.
//!
//! Numerators preserve the signs and gates from the pinned Stark-V schema so
//! interaction-column integration does not have to reconstruct policy.

const QM31 = @import("stwo_core").fields.qm31.QM31;
const common = @import("common.zig");

pub fn Request(comptime Tuple: type) type {
    return struct {
        numerator: QM31,
        tuple: Tuple,
    };
}

pub const RegisterStateTuple = struct {
    pc: QM31,
    clock: QM31,

    pub fn values(self: @This()) [2]QM31 {
        return .{ self.pc, self.clock };
    }
};

pub const Range20Tuple = struct {
    value: QM31,

    pub fn values(self: @This()) [1]QM31 {
        return .{self.value};
    }
};

pub const RangePairTuple = struct {
    limb_0: QM31,
    limb_1: QM31,

    pub fn values(self: @This()) [2]QM31 {
        return .{ self.limb_0, self.limb_1 };
    }
};

pub const RangeTripleTuple = struct {
    limb_0: QM31,
    limb_1: QM31,
    limb_2: QM31,

    pub fn values(self: @This()) [3]QM31 {
        return .{ self.limb_0, self.limb_1, self.limb_2 };
    }
};

pub const StateLookups = struct {
    consume: Request(RegisterStateTuple),
    emit: Request(RegisterStateTuple),
};

pub fn stateLookups(
    pc: QM31,
    clock: QM31,
    next_pc: QM31,
    enabler: QM31,
) StateLookups {
    return .{
        .consume = .{
            .numerator = enabler.neg(),
            .tuple = .{ .pc = pc, .clock = clock },
        },
        .emit = .{
            .numerator = enabler,
            .tuple = .{ .pc = next_pc, .clock = clock.add(QM31.one()) },
        },
    };
}

pub const RegisterAccessLookups = struct {
    consume: Request(common.MemoryAccessTuple),
    emit: Request(common.MemoryAccessTuple),
    clock_gap: Request(Range20Tuple),
};

pub fn registerAccessLookups(
    access: common.Access,
    row_clock: QM31,
    enabler: QM31,
) RegisterAccessLookups {
    const chain = common.registerAccessChain(access, row_clock);
    return .{
        .consume = .{ .numerator = enabler.neg(), .tuple = chain.previous },
        .emit = .{ .numerator = enabler, .tuple = chain.next },
        .clock_gap = .{
            .numerator = enabler.neg(),
            .tuple = .{ .value = chain.clock_gap },
        },
    };
}

pub fn accessFromColumns(columns: []const QM31, start: usize) common.Access {
    return .{
        .addr = columns[start],
        .previous = .{
            columns[start + 1],
            columns[start + 2],
            columns[start + 3],
            columns[start + 4],
        },
        .previous_clock = columns[start + 5],
        .next = .{
            columns[start + 6],
            columns[start + 7],
            columns[start + 8],
            columns[start + 9],
        },
    };
}

pub fn programRequest(
    enabler: QM31,
    tuple: common.ProgramTuple,
) Request(common.ProgramTuple) {
    return .{ .numerator = enabler.neg(), .tuple = tuple };
}

pub fn range20Request(enabler: QM31, value: QM31) Request(Range20Tuple) {
    return .{ .numerator = enabler.neg(), .tuple = .{ .value = value } };
}

pub fn rangePairRequest(
    enabler: QM31,
    limb_0: QM31,
    limb_1: QM31,
) Request(RangePairTuple) {
    return .{
        .numerator = enabler.neg(),
        .tuple = .{ .limb_0 = limb_0, .limb_1 = limb_1 },
    };
}

test "control common: register access preserves signed relation requests" {
    const std = @import("std");
    const access = common.Access{
        .addr = common.q(7),
        .previous = .{ common.q(1), common.q(2), common.q(3), common.q(4) },
        .previous_clock = common.q(11),
        .next = .{ common.q(5), common.q(6), common.q(7), common.q(8) },
    };
    const requests = registerAccessLookups(access, common.q(19), QM31.one());
    try std.testing.expect(requests.consume.numerator.eql(QM31.one().neg()));
    try std.testing.expect(requests.consume.tuple.clock.eql(common.q(11)));
    try std.testing.expect(requests.emit.numerator.eql(QM31.one()));
    try std.testing.expect(requests.emit.tuple.clock.eql(common.q(19)));
    try std.testing.expect(requests.clock_gap.tuple.value.eql(common.q(8)));
}
