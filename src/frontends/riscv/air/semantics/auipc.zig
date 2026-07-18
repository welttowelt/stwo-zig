//! Exact pinned Stark-V AIR semantics and lookup requests for AUIPC.

const std = @import("std");
const QM31 = @import("../../../../core/fields/qm31.zig").QM31;
const common = @import("common.zig");
const control = @import("control_common.zig");
const Opcode = @import("../program/opcode.zig").Opcode;

pub const N_MAIN_COLUMNS: usize = 14;
pub const N_CONSTRAINTS: usize = 2;

pub const Row = struct {
    enabler: QM31,
    clock: QM31,
    pc: QM31,
    rd: common.Access,
    imm_felt: QM31,

    pub fn fromMainColumns(columns: []const QM31) !Row {
        if (columns.len != N_MAIN_COLUMNS) return error.InvalidMainTraceShape;
        return .{
            .enabler = columns[0],
            .clock = columns[1],
            .pc = columns[2],
            .rd = control.accessFromColumns(columns, 3),
            .imm_felt = columns[13],
        };
    }
};

pub const Constraints = common.ConstraintSet(N_CONSTRAINTS);

pub fn evaluate(row: Row) Constraints {
    return .{ .values = .{
        common.bit(row.enabler),
        common.composeU32(row.rd.next).sub(row.pc.add(row.imm_felt)),
    } };
}

pub fn placementConstraint(row: Row, is_active: QM31) QM31 {
    return row.enabler.sub(is_active);
}

pub fn programLookup(row: Row) common.ProgramTuple {
    return .{
        .pc = row.pc,
        .opcode_id = common.q(Opcode.auipc.protocolId()),
        .rd = row.rd.addr,
        .rs1 = row.imm_felt,
        .operand = QM31.zero(),
    };
}

pub const RangeLookups = struct {
    middle_bytes: control.Request(control.RangePairTuple),
    m31_split: control.Request(control.RangePairTuple),
};

pub const Lookups = struct {
    /// Fields retain `schema.rs` declaration order for interaction batching.
    program: control.Request(common.ProgramTuple),
    state: control.StateLookups,
    ranges: RangeLookups,
    rd: control.RegisterAccessLookups,
};

pub fn lookups(row: Row) Lookups {
    return .{
        .program = control.programRequest(row.enabler, programLookup(row)),
        .state = control.stateLookups(
            row.pc,
            row.clock,
            row.pc.add(common.q(4)),
            row.enabler,
        ),
        .ranges = .{
            .middle_bytes = control.rangePairRequest(
                row.enabler,
                row.rd.next[1],
                row.rd.next[2],
            ),
            .m31_split = control.rangePairRequest(
                row.enabler,
                row.rd.next[0],
                row.rd.next[3],
            ),
        },
        .rd = control.registerAccessLookups(row.rd, row.clock, row.enabler),
    };
}

fn zeroRow() Row {
    return .{
        .enabler = QM31.zero(),
        .clock = QM31.zero(),
        .pc = QM31.zero(),
        .rd = .{
            .addr = QM31.zero(),
            .previous = .{QM31.zero()} ** 4,
            .previous_clock = QM31.zero(),
            .next = .{QM31.zero()} ** 4,
        },
        .imm_felt = QM31.zero(),
    };
}

test "auipc: honest result satisfies direct equation and exact ranges" {
    var row = zeroRow();
    row.enabler = QM31.one();
    row.clock = common.q(4);
    row.pc = common.q(0x1000);
    row.imm_felt = common.q(0x2000);
    row.rd.addr = common.q(8);
    row.rd.next = .{ common.q(0), common.q(0x30), common.q(0), common.q(0) };
    try std.testing.expect(evaluate(row).allZero());

    const requests = lookups(row);
    try std.testing.expect(requests.program.tuple.opcode_id.eql(common.q(36)));
    try std.testing.expect(requests.program.tuple.rs1.eql(common.q(0x2000)));
    try std.testing.expect(requests.state.emit.tuple.pc.eql(common.q(0x1004)));
    try std.testing.expect(requests.ranges.middle_bytes.tuple.limb_0.eql(common.q(0x30)));
}

test "auipc: forged destination is rejected" {
    var row = zeroRow();
    row.enabler = QM31.one();
    row.pc = common.q(100);
    row.imm_felt = common.q(20);
    row.rd.next[0] = common.q(121);
    try std.testing.expect(!evaluate(row).allZero());
}

test "auipc: exact adapter has upstream enabler first" {
    var columns = [_]QM31{QM31.zero()} ** N_MAIN_COLUMNS;
    columns[0] = common.q(1);
    columns[3] = common.q(2);
    columns[8] = common.q(3);
    columns[9] = common.q(4);
    columns[13] = common.q(5);
    const row = try Row.fromMainColumns(&columns);
    try std.testing.expect(row.enabler.eql(common.q(1)));
    try std.testing.expect(row.rd.addr.eql(common.q(2)));
    try std.testing.expect(row.rd.previous_clock.eql(common.q(3)));
    try std.testing.expect(row.rd.next[0].eql(common.q(4)));
    try std.testing.expect(row.imm_felt.eql(common.q(5)));
}
