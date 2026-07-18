//! Exact direct semantics for ADD/SUB and lookup requests for bitwise R-type
//! instructions, expressed over the full committed family-column layout.
//!
//! Oracle: `stark-v` `crates/air/src/schema.rs`, `base_alu_reg`, pinned by
//! `conformance/upstream.md`.

const std = @import("std");
const QM31 = @import("../../../../core/fields/qm31.zig").QM31;
const common = @import("common.zig");

/// Full 37-column family trace followed by the exact decoded-program bus
/// columns `(next_pc, opcode_id, value_1, value_2, value_3)`.
pub const N_MAIN_COLUMNS: usize = 42;
pub const N_CONSTRAINTS: usize = 19;

pub const Row = struct {
    clk: QM31,
    pc: QM31,
    is_add: QM31,
    is_sub: QM31,
    is_xor: QM31,
    is_or: QM31,
    is_and: QM31,
    rd: common.Access,
    rs1: common.Access,
    rs2: common.Access,
    next_pc: QM31,
    program_opcode: QM31,
    program_value_1: QM31,
    program_value_2: QM31,
    program_value_3: QM31,

    pub fn fromMainColumns(columns: []const QM31) !Row {
        if (columns.len != N_MAIN_COLUMNS) return error.InvalidMainTraceShape;
        return .{
            .clk = columns[0],
            .pc = columns[1],
            .is_add = columns[2],
            .is_sub = columns[3],
            .is_xor = columns[4],
            .is_or = columns[5],
            .is_and = columns[6],
            .rd = .{
                .addr = columns[7],
                .previous = columns[8..12].*,
                .previous_clock = columns[12],
                .next = columns[13..17].*,
            },
            .rs1 = .{
                .addr = columns[17],
                .previous = columns[18..22].*,
                .previous_clock = columns[22],
                .next = columns[23..27].*,
            },
            .rs2 = .{
                .addr = columns[27],
                .previous = columns[28..32].*,
                .previous_clock = columns[32],
                .next = columns[33..37].*,
            },
            .next_pc = columns[37],
            .program_opcode = columns[38],
            .program_value_1 = columns[39],
            .program_value_2 = columns[40],
            .program_value_3 = columns[41],
        };
    }

    pub fn active(self: Row) QM31 {
        return self.is_add.add(self.is_sub).add(self.is_xor).add(self.is_or).add(self.is_and);
    }
};

pub const Constraints = common.ConstraintSet(N_CONSTRAINTS);

/// Direct AIR constraints. The byte-range lookups documented in
/// `rangeCheckPairs` and the decoded program lookup returned by
/// `programLookup` must be wired alongside these constraints.
pub fn evaluate(row: Row, is_active: QM31) Constraints {
    var out: [N_CONSTRAINTS]QM31 = undefined;
    var i: usize = 0;

    const flags = [_]QM31{ row.is_add, row.is_sub, row.is_xor, row.is_or, row.is_and };
    for (flags) |flag| {
        out[i] = common.bit(flag);
        i += 1;
    }
    out[i] = row.active().sub(is_active);
    i += 1;
    out[i] = common.selected(is_active, row.next_pc.sub(row.pc).sub(common.q(4)));
    i += 1;

    const program = programLookup(row);
    for ([_]QM31{
        row.program_opcode.sub(program.opcode_id),
        row.program_value_1.sub(program.rd),
        row.program_value_2.sub(program.rs1),
        row.program_value_3.sub(program.operand),
    }) |constraint| {
        out[i] = common.selected(is_active, constraint);
        i += 1;
    }

    var carry = QM31.zero();
    for (0..4) |limb| {
        const numerator = row.rs1.next[limb].add(row.rs2.next[limb]).add(carry).sub(row.rd.next[limb]);
        carry = numerator.mul(common.INV_BYTE_RADIX);
        out[i] = common.selected(row.is_add, common.bit(carry));
        i += 1;
    }

    carry = QM31.zero();
    for (0..4) |limb| {
        const numerator = row.rd.next[limb].add(row.rs2.next[limb]).add(carry).sub(row.rs1.next[limb]);
        carry = numerator.mul(common.INV_BYTE_RADIX);
        out[i] = common.selected(row.is_sub, common.bit(carry));
        i += 1;
    }
    std.debug.assert(i == out.len);
    return .{ .values = out };
}

/// The upstream opcode ids are protocol constants, not Zig enum ordinals.
pub fn programLookup(row: Row) common.ProgramTuple {
    const opcode_id = row.is_add.mul(common.q(0))
        .add(row.is_sub.mul(common.q(1)))
        .add(row.is_xor.mul(common.q(5)))
        .add(row.is_or.mul(common.q(8)))
        .add(row.is_and.mul(common.q(9)));
    return .{
        .pc = row.pc,
        .opcode_id = opcode_id,
        .rd = row.rd.addr,
        .rs1 = row.rs1.addr,
        .operand = row.rs2.addr,
    };
}

/// Bitwise table requests. The caller multiplies their LogUp numerators by
/// `is_xor + is_or + is_and`; ADD/SUB rows therefore emit no bitwise entries.
pub fn bitwiseLookups(row: Row) [4]common.BitwiseTuple {
    const operation_id = row.is_xor.mul(common.q(2)).add(row.is_or);
    var tuples: [4]common.BitwiseTuple = undefined;
    for (&tuples, 0..) |*tuple, i| {
        tuple.* = .{
            .lhs = row.rs1.next[i],
            .rhs = row.rs2.next[i],
            .result = row.rd.next[i],
            .operation_id = operation_id,
        };
    }
    return tuples;
}

/// Each pair is one `range_check_8_8` request.
pub fn rangeCheckPairs(row: Row) [6][2]QM31 {
    return .{
        .{ row.rd.next[0], row.rd.next[1] },
        .{ row.rd.next[2], row.rd.next[3] },
        .{ row.rs1.next[0], row.rs1.next[1] },
        .{ row.rs1.next[2], row.rs1.next[3] },
        .{ row.rs2.next[0], row.rs2.next[1] },
        .{ row.rs2.next[2], row.rs2.next[3] },
    };
}

pub const AccessLookups = struct {
    rd: common.AccessChain,
    rs1: common.AccessChain,
    rs2: common.AccessChain,
};

/// Register-file state-chain entries. All three accesses emit at this AIR
/// row's clock, matching the pinned Stark-V schema.
pub fn accessLookups(row: Row) AccessLookups {
    return .{
        .rd = common.registerAccessChain(row.rd, row.clk),
        .rs1 = common.registerAccessChain(row.rs1, row.clk),
        .rs2 = common.registerAccessChain(row.rs2, row.clk),
    };
}

fn zeroRow() Row {
    const zero_access = common.Access{
        .addr = QM31.zero(),
        .previous = .{QM31.zero()} ** 4,
        .previous_clock = QM31.zero(),
        .next = .{QM31.zero()} ** 4,
    };
    return .{
        .clk = QM31.zero(),
        .pc = QM31.zero(),
        .is_add = QM31.zero(),
        .is_sub = QM31.zero(),
        .is_xor = QM31.zero(),
        .is_or = QM31.zero(),
        .is_and = QM31.zero(),
        .rd = zero_access,
        .rs1 = zero_access,
        .rs2 = zero_access,
        .next_pc = QM31.zero(),
        .program_opcode = QM31.zero(),
        .program_value_1 = QM31.zero(),
        .program_value_2 = QM31.zero(),
        .program_value_3 = QM31.zero(),
    };
}

fn bindProgram(row: *Row) void {
    const program = programLookup(row.*);
    row.program_opcode = program.opcode_id;
    row.program_value_1 = program.rd;
    row.program_value_2 = program.rs1;
    row.program_value_3 = program.operand;
}

test "base alu reg semantics: ADD accepts byte carry chain" {
    var row = zeroRow();
    row.pc = common.q(0x1000);
    row.next_pc = common.q(0x1004);
    row.is_add = QM31.one();
    row.rs1.next = .{ common.q(255), common.q(255), common.q(0), common.q(0) };
    row.rs2.next = .{ common.q(1), common.q(0), common.q(0), common.q(0) };
    row.rd.next = .{ common.q(0), common.q(0), common.q(1), common.q(0) };
    bindProgram(&row);
    try std.testing.expect(evaluate(row, QM31.one()).allZero());
}

test "base alu reg semantics: ADD rejects a forged result" {
    var row = zeroRow();
    row.pc = common.q(0x1000);
    row.next_pc = common.q(0x1004);
    row.is_add = QM31.one();
    row.rs1.next[0] = common.q(7);
    row.rs2.next[0] = common.q(9);
    row.rd.next[0] = common.q(17);
    bindProgram(&row);
    try std.testing.expect(!evaluate(row, QM31.one()).allZero());
}

test "base alu reg semantics: SUB accepts unsigned wraparound" {
    var row = zeroRow();
    row.pc = common.q(0x1000);
    row.next_pc = common.q(0x1004);
    row.is_sub = QM31.one();
    row.rs1.next = .{QM31.zero()} ** 4;
    row.rs2.next[0] = common.q(1);
    row.rd.next = .{ common.q(255), common.q(255), common.q(255), common.q(255) };
    bindProgram(&row);
    try std.testing.expect(evaluate(row, QM31.one()).allZero());
}

test "base alu reg semantics: decoded tuple uses pinned Stark-V ids" {
    var row = zeroRow();
    row.is_xor = QM31.one();
    const tuple = programLookup(row);
    try std.testing.expect(tuple.opcode_id.eql(common.q(5)));
}

test "base alu reg semantics: access lookups consume previous and emit at row clock" {
    var row = zeroRow();
    row.clk = common.q(19);
    row.rs1.addr = common.q(7);
    row.rs1.previous_clock = common.q(11);
    row.rs1.previous[0] = common.q(41);
    row.rs1.next[0] = common.q(42);

    const chain = accessLookups(row).rs1;
    try std.testing.expect(chain.previous.addr_space.isZero());
    try std.testing.expect(chain.previous.addr.eql(common.q(7)));
    try std.testing.expect(chain.previous.clock.eql(common.q(11)));
    try std.testing.expect(chain.previous.limbs[0].eql(common.q(41)));
    try std.testing.expect(chain.next.clock.eql(common.q(19)));
    try std.testing.expect(chain.next.limbs[0].eql(common.q(42)));
    try std.testing.expect(chain.clock_gap.eql(common.q(8)));
}

test "base alu reg semantics: full main-column adapter preserves access blocks" {
    var columns = [_]QM31{QM31.zero()} ** N_MAIN_COLUMNS;
    columns[7] = common.q(1);
    columns[8] = common.q(2);
    columns[12] = common.q(3);
    columns[13] = common.q(4);
    columns[17] = common.q(5);
    columns[22] = common.q(6);
    columns[23] = common.q(7);
    columns[27] = common.q(8);
    columns[32] = common.q(9);
    columns[33] = common.q(10);
    columns[37] = common.q(11);
    columns[38] = common.q(12);
    columns[39] = common.q(13);
    columns[40] = common.q(14);
    columns[41] = common.q(15);

    const row = try Row.fromMainColumns(&columns);
    try std.testing.expect(row.rd.addr.eql(common.q(1)));
    try std.testing.expect(row.rd.previous[0].eql(common.q(2)));
    try std.testing.expect(row.rd.previous_clock.eql(common.q(3)));
    try std.testing.expect(row.rd.next[0].eql(common.q(4)));
    try std.testing.expect(row.rs1.addr.eql(common.q(5)));
    try std.testing.expect(row.rs1.previous_clock.eql(common.q(6)));
    try std.testing.expect(row.rs1.next[0].eql(common.q(7)));
    try std.testing.expect(row.rs2.addr.eql(common.q(8)));
    try std.testing.expect(row.rs2.previous_clock.eql(common.q(9)));
    try std.testing.expect(row.rs2.next[0].eql(common.q(10)));
    try std.testing.expect(row.next_pc.eql(common.q(11)));
    try std.testing.expect(row.program_opcode.eql(common.q(12)));
    try std.testing.expect(row.program_value_1.eql(common.q(13)));
    try std.testing.expect(row.program_value_2.eql(common.q(14)));
    try std.testing.expect(row.program_value_3.eql(common.q(15)));
}
