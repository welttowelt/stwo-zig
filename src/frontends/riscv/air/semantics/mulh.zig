//! Exact pinned Stark-V `MULH`, `MULHSU`, and `MULHU` semantics.
//!
//! The witness carries both halves of the 64-bit product. Eight singleton
//! `range_check_8_11` requests enforce the signed schoolbook carry chain while
//! keeping every lookup denominator within the oracle's degree bound.
//! Oracle: pinned `crates/air/src/schema.rs` and `runner/src/ops/muldiv.rs`.

const std = @import("std");
const QM31 = @import("stwo_core").fields.qm31.QM31;
const common = @import("common.zig");
const control = @import("control_common.zig");
const Opcode = @import("../program/opcode.zig").Opcode;

pub const N_ORACLE_COLUMNS: usize = 41;
pub const N_CONSTRAINTS: usize = 8;
pub const LOOKUP_BATCH_SIZE: usize = 1;
pub const BITWISE_LOOKUP_COUNT: usize = 0;
// FIX(stark-v-signed-mulh): The pinned oracle adds `sign * 128` to the raw top
// byte while also using a `255 * sign` extension byte. For signed operands this
// makes the carry numerator non-divisible by 256 (for example, MULH(-1, -1)
// yields carry_4 = 2_139_096_569), outside the 11-bit lookup table. Of the eight
// invalid range requests, four index past the table and four wrap to an existing
// u32 index whose generated tuple does not match. The sign witnesses are also
// not tied to the operand top bits, so clearing them can admit unsigned-high
// behavior for a signed opcode. Preserve the formula below for d478f783 parity,
// keep this family fail closed in production, and remove this marker only after
// the pinned Rust oracle changes with signed prove/verify vectors.
pub const CURRENT_TRACE_COMPATIBLE = false;
pub const MISSING_CURRENT_WITNESS_COLUMNS = [_][]const u8{
    "pinned signed carry relation rejects the exact runner witness",
};

pub const Row = struct {
    clock: QM31,
    pc: QM31,
    rd: common.Access,
    rs1: common.Access,
    rs2: common.Access,
    rd_high: [4]QM31,
    rs1_sign: QM31,
    rs2_sign: QM31,
    is_mulh: QM31,
    is_mulhsu: QM31,
    is_mulhu: QM31,

    pub fn fromOracleColumns(columns: []const QM31) !Row {
        if (columns.len != N_ORACLE_COLUMNS) return error.InvalidOracleTraceShape;
        return .{
            .clock = columns[0],
            .pc = columns[1],
            .rd = common.accessFromColumns(columns[2..12]),
            .rs1 = common.accessFromColumns(columns[12..22]),
            .rs2 = common.accessFromColumns(columns[22..32]),
            .rd_high = columns[32..36].*,
            .rs1_sign = columns[36],
            .rs2_sign = columns[37],
            .is_mulh = columns[38],
            .is_mulhsu = columns[39],
            .is_mulhu = columns[40],
        };
    }

    pub fn active(self: Row) QM31 {
        return self.is_mulh.add(self.is_mulhsu).add(self.is_mulhu);
    }
};

pub const Derived = struct {
    carries: [8]QM31,
};

pub fn derive(row: Row) Derived {
    @setEvalBranchQuota(100_000);
    const a = row.rs1.next;
    const b = row.rs2.next;
    const low = row.rd_high;
    const high = row.rd.next;
    const a_top = a[3].add(row.rs1_sign.mul(common.q(128)));
    const b_top = b[3].add(row.rs2_sign.mul(common.q(128)));
    const a_fill = row.rs1_sign.mul(common.q(255));
    const b_fill = row.rs2_sign.mul(common.q(255));
    var carry: [8]QM31 = undefined;

    carry[0] = a[0].mul(b[0]).sub(low[0]).mul(common.INV_BYTE_RADIX);
    carry[1] = carry[0].add(a[0].mul(b[1])).add(a[1].mul(b[0]))
        .sub(low[1]).mul(common.INV_BYTE_RADIX);
    carry[2] = carry[1].add(a[0].mul(b[2])).add(a[1].mul(b[1]))
        .add(a[2].mul(b[0])).sub(low[2]).mul(common.INV_BYTE_RADIX);
    carry[3] = carry[2].add(a[0].mul(b_top)).add(a[1].mul(b[2]))
        .add(a[2].mul(b[1])).add(a_top.mul(b[0]))
        .sub(low[3]).mul(common.INV_BYTE_RADIX);
    carry[4] = carry[3].add(a[0].mul(b_fill)).add(a[1].mul(b_top))
        .add(a[2].mul(b[2])).add(a_top.mul(b[1])).add(a_fill.mul(b[0]))
        .sub(high[0]).mul(common.INV_BYTE_RADIX);
    carry[5] = carry[4].add(a[0].mul(b_fill)).add(a[1].mul(b_fill))
        .add(a[2].mul(b_top)).add(a_top.mul(b[2])).add(a_fill.mul(b[1]))
        .add(a_fill.mul(b[0])).sub(high[1]).mul(common.INV_BYTE_RADIX);
    carry[6] = carry[5].add(a[0].mul(b_fill)).add(a[1].mul(b_fill))
        .add(a[2].mul(b_fill)).add(a_top.mul(b_top)).add(a_fill.mul(b[2]))
        .add(a_fill.mul(b[1])).add(a_fill.mul(b[0]))
        .sub(high[2]).mul(common.INV_BYTE_RADIX);
    carry[7] = carry[6].add(a[0].mul(b_fill)).add(a[1].mul(b_fill))
        .add(a[2].mul(b_fill)).add(a_top.mul(b_fill)).add(a_fill.mul(b_top))
        .add(a_fill.mul(b[2])).add(a_fill.mul(b[1])).add(a_fill.mul(b[0]))
        .sub(high[3]).mul(common.INV_BYTE_RADIX);
    return .{ .carries = carry };
}

pub const Constraints = common.ConstraintSet(N_CONSTRAINTS);

fn booleanConstraint(value: QM31) QM31 {
    return value.mul(QM31.one().sub(value));
}

pub fn evaluate(row: Row) Constraints {
    const active = row.active();
    return .{ .values = .{
        booleanConstraint(active),
        booleanConstraint(row.is_mulh),
        booleanConstraint(row.is_mulhsu),
        booleanConstraint(row.is_mulhu),
        booleanConstraint(row.rs1_sign),
        booleanConstraint(row.rs2_sign),
        row.is_mulhsu.add(row.is_mulhu).mul(row.rs2_sign),
        row.is_mulhu.mul(row.rs1_sign),
    } };
}

pub fn placementConstraint(row: Row, is_active: QM31) QM31 {
    return row.active().sub(is_active);
}

pub fn programLookup(row: Row) common.ProgramTuple {
    const opcode_id = row.is_mulh.mul(common.q(Opcode.mulh.protocolId()))
        .add(row.is_mulhsu.mul(common.q(Opcode.mulhsu.protocolId())))
        .add(row.is_mulhu.mul(common.q(Opcode.mulhu.protocolId())));
    return .{
        .pc = row.pc,
        .opcode_id = opcode_id,
        .rd = row.rd.addr,
        .rs1 = row.rs1.addr,
        .operand = row.rs2.addr,
    };
}

pub const Lookups = struct {
    /// Fields retain the exact `schema.rs` declaration order.
    program: control.Request(common.ProgramTuple),
    state: control.StateLookups,
    rs1: control.RegisterAccessLookups,
    rs2: control.RegisterAccessLookups,
    product_ranges: [8]control.Request(control.RangePairTuple),
    rd: control.RegisterAccessLookups,
};

pub fn lookups(row: Row) Lookups {
    const active = row.active();
    const carries = derive(row).carries;
    var ranges: [8]control.Request(control.RangePairTuple) = undefined;
    for (&ranges, 0..) |*request, limb| {
        const result_limb = if (limb < 4) row.rd.next[limb] else row.rd_high[limb - 4];
        request.* = control.rangePairRequest(active, result_limb, carries[limb]);
    }
    return .{
        .program = control.programRequest(active, programLookup(row)),
        .state = control.stateLookups(row.pc, row.clock, row.pc.add(common.q(4)), active),
        .rs1 = control.registerAccessLookups(row.rs1, row.clock, active),
        .rs2 = control.registerAccessLookups(row.rs2, row.clock, active),
        .product_ranges = ranges,
        .rd = control.registerAccessLookups(row.rd, row.clock, active),
    };
}

fn zeroAccess() common.Access {
    return .{
        .addr = QM31.zero(),
        .previous = .{QM31.zero()} ** 4,
        .previous_clock = QM31.zero(),
        .next = .{QM31.zero()} ** 4,
    };
}

fn honestUnsignedMaxRow() Row {
    var rd = zeroAccess();
    rd.addr = common.q(3);
    rd.next = .{ common.q(254), common.q(255), common.q(255), common.q(255) };
    var rs1 = zeroAccess();
    rs1.addr = common.q(1);
    rs1.next = .{common.q(255)} ** 4;
    var rs2 = zeroAccess();
    rs2.addr = common.q(2);
    rs2.next = .{common.q(255)} ** 4;
    return .{
        .clock = common.q(9),
        .pc = common.q(0x1000),
        .rd = rd,
        .rs1 = rs1,
        .rs2 = rs2,
        .rd_high = .{ QM31.one(), QM31.zero(), QM31.zero(), QM31.zero() },
        .rs1_sign = QM31.zero(),
        .rs2_sign = QM31.zero(),
        .is_mulh = QM31.zero(),
        .is_mulhsu = QM31.zero(),
        .is_mulhu = QM31.one(),
    };
}

test "mulh: unsigned maximal product has eight bounded oracle requests" {
    const row = honestUnsignedMaxRow();
    try std.testing.expect(evaluate(row).allZero());
    const requests = lookups(row);
    try std.testing.expect(requests.program.tuple.opcode_id.eql(common.q(40)));
    for (requests.product_ranges) |request| {
        const limb = try request.tuple.limb_0.tryIntoM31();
        const carry = try request.tuple.limb_1.tryIntoM31();
        try std.testing.expect(limb.toU32() < 256);
        try std.testing.expect(carry.toU32() < 2048);
    }
}

test "mulh: unsigned opcode rejects a forged signed witness" {
    var row = honestUnsignedMaxRow();
    row.rs1_sign = QM31.one();
    try std.testing.expect(!evaluate(row).allZero());
}

test "mulh: forged high product escapes constraints but fails range table" {
    var row = honestUnsignedMaxRow();
    row.rd.next[0] = common.q(255);
    try std.testing.expect(evaluate(row).allZero());
    const forged_carry = try derive(row).carries[4].tryIntoM31();
    try std.testing.expect(forged_carry.toU32() >= 2048);
}

test "mulh: adapter follows access then witness then flag order" {
    var columns = [_]QM31{QM31.zero()} ** N_ORACLE_COLUMNS;
    columns[2] = common.q(1);
    columns[12] = common.q(2);
    columns[22] = common.q(3);
    columns[32] = common.q(4);
    columns[36] = common.q(5);
    columns[40] = common.q(6);
    const row = try Row.fromOracleColumns(&columns);
    try std.testing.expect(row.rd.addr.eql(common.q(1)));
    try std.testing.expect(row.rs1.addr.eql(common.q(2)));
    try std.testing.expect(row.rs2.addr.eql(common.q(3)));
    try std.testing.expect(row.rd_high[0].eql(common.q(4)));
    try std.testing.expect(row.rs1_sign.eql(common.q(5)));
    try std.testing.expect(row.is_mulhu.eql(common.q(6)));
}
