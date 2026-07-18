//! Exact direct semantics for the base ALU immediate family.
//!
//! The current main trace commits one signed `imm` field. That is not
//! enough for a sound byte-carry ADDI constraint in M31: word-level equations
//! admit aliases separated by the field modulus. The pinned Stark-V AIR uses
//! `imm_0` and `imm_1` alongside the sign bit. This module makes those missing
//! witnesses explicit so integration cannot silently accept the incomplete
//! current layout.

const std = @import("std");
const QM31 = @import("../../../../core/fields/qm31.zig").QM31;
const common = @import("common.zig");

/// Full 29-column family trace followed by the three current instruction-bus
/// columns `(next_pc, inst_lo, inst_hi)`.
pub const N_MAIN_COLUMNS: usize = 32;
pub const N_CONSTRAINTS: usize = 14;

/// Required additions to the committed base-ALU-immediate trace. `imm_0`
/// must be range checked to 8 bits and `imm_1` to 3 bits. Carries remain
/// derived expressions and do not require committed columns.
pub const ImmediateWitness = struct {
    imm_0: QM31,
    imm_1: QM31,
};

pub const missing_current_main_columns = [_][]const u8{ "imm_0", "imm_1" };

pub const Row = struct {
    clk: QM31,
    pc: QM31,
    is_addi: QM31,
    is_xori: QM31,
    is_ori: QM31,
    is_andi: QM31,
    signed_imm: QM31,
    imm_sign: QM31,
    enabler: QM31,
    rd: common.Access,
    rs1: common.Access,
    next_pc: QM31,
    inst_lo: QM31,
    inst_hi: QM31,

    pub fn fromMainColumns(columns: []const QM31) !Row {
        if (columns.len != N_MAIN_COLUMNS) return error.InvalidMainTraceShape;
        return .{
            .clk = columns[0],
            .pc = columns[1],
            .is_addi = columns[2],
            .is_xori = columns[3],
            .is_ori = columns[4],
            .is_andi = columns[5],
            .signed_imm = columns[6],
            .imm_sign = columns[7],
            .enabler = columns[8],
            .rd = .{
                .addr = columns[9],
                .previous = columns[10..14].*,
                .previous_clock = columns[14],
                .next = columns[15..19].*,
            },
            .rs1 = .{
                .addr = columns[19],
                .previous = columns[20..24].*,
                .previous_clock = columns[24],
                .next = columns[25..29].*,
            },
            .next_pc = columns[29],
            .inst_lo = columns[30],
            .inst_hi = columns[31],
        };
    }

    pub fn active(self: Row) QM31 {
        return self.is_addi.add(self.is_xori).add(self.is_ori).add(self.is_andi);
    }
};

pub const Constraints = common.ConstraintSet(N_CONSTRAINTS);

fn immediateLimbs(witness: ImmediateWitness, sign: QM31) [4]QM31 {
    // Sign extension of `[imm_0:8, imm_1:3, sign:1]` to four bytes.
    const limb_1 = witness.imm_1.add(sign.mul(common.q(248)));
    const fill = sign.mul(common.q(255));
    return .{ witness.imm_0, limb_1, fill, fill };
}

pub fn unsignedImmediate(witness: ImmediateWitness, sign: QM31) QM31 {
    return witness.imm_0
        .add(witness.imm_1.mul(common.q(1 << 8)))
        .add(sign.mul(common.q(1 << 11)));
}

pub fn signedImmediate(witness: ImmediateWitness, sign: QM31) QM31 {
    return witness.imm_0
        .add(witness.imm_1.mul(common.q(1 << 8)))
        .sub(sign.mul(common.q(1 << 11)));
}

/// Exact direct constraints, conditional on the documented range lookups for
/// `ImmediateWitness` and all register byte limbs.
pub fn evaluate(row: Row, witness: ImmediateWitness, is_active: QM31) Constraints {
    var out: [N_CONSTRAINTS]QM31 = undefined;
    var i: usize = 0;

    const flags = [_]QM31{ row.is_addi, row.is_xori, row.is_ori, row.is_andi };
    for (flags) |flag| {
        out[i] = common.bit(flag);
        i += 1;
    }
    out[i] = common.bit(row.imm_sign);
    i += 1;
    out[i] = common.bit(row.enabler);
    i += 1;
    out[i] = row.enabler.sub(row.active());
    i += 1;
    out[i] = row.enabler.sub(is_active);
    i += 1;
    out[i] = common.selected(is_active, row.next_pc.sub(row.pc).sub(common.q(4)));
    i += 1;
    out[i] = common.selected(is_active, row.signed_imm.sub(signedImmediate(witness, row.imm_sign)));
    i += 1;

    const imm = immediateLimbs(witness, row.imm_sign);
    var carry = QM31.zero();
    for (0..4) |limb| {
        const numerator = row.rs1.next[limb].add(imm[limb]).add(carry).sub(row.rd.next[limb]);
        carry = numerator.mul(common.INV_BYTE_RADIX);
        out[i] = common.selected(row.is_addi, common.bit(carry));
        i += 1;
    }
    std.debug.assert(i == out.len);
    return .{ .values = out };
}

pub fn programLookup(row: Row, witness: ImmediateWitness) common.ProgramTuple {
    const opcode_id = row.is_addi.mul(common.q(10))
        .add(row.is_xori.mul(common.q(13)))
        .add(row.is_ori.mul(common.q(14)))
        .add(row.is_andi.mul(common.q(15)));
    return .{
        .pc = row.pc,
        .opcode_id = opcode_id,
        .rd = row.rd.addr,
        .rs1 = row.rs1.addr,
        .operand = unsignedImmediate(witness, row.imm_sign),
    };
}

pub fn bitwiseLookups(row: Row, witness: ImmediateWitness) [4]common.BitwiseTuple {
    const operation_id = row.is_xori.mul(common.q(2)).add(row.is_ori);
    const imm = immediateLimbs(witness, row.imm_sign);
    var tuples: [4]common.BitwiseTuple = undefined;
    for (&tuples, 0..) |*tuple, i| {
        tuple.* = .{
            .lhs = row.rs1.next[i],
            .rhs = imm[i],
            .result = row.rd.next[i],
            .operation_id = operation_id,
        };
    }
    return tuples;
}

/// Inputs for the upstream `range_check_8_11` immediate lookup. The second
/// coordinate is shifted by eight bits exactly as in the pinned schema.
pub fn immediateRangeLookup(witness: ImmediateWitness) [2]QM31 {
    return .{ witness.imm_0, witness.imm_1.mul(common.q(1 << 8)) };
}

pub fn registerRangeCheckPairs(row: Row) [4][2]QM31 {
    return .{
        .{ row.rd.next[0], row.rd.next[1] },
        .{ row.rd.next[2], row.rd.next[3] },
        .{ row.rs1.next[0], row.rs1.next[1] },
        .{ row.rs1.next[2], row.rs1.next[3] },
    };
}

pub const AccessLookups = struct {
    rd: common.AccessChain,
    rs1: common.AccessChain,
};

pub fn accessLookups(row: Row) AccessLookups {
    return .{
        .rd = common.registerAccessChain(row.rd, row.clk),
        .rs1 = common.registerAccessChain(row.rs1, row.clk),
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
        .is_addi = QM31.zero(),
        .is_xori = QM31.zero(),
        .is_ori = QM31.zero(),
        .is_andi = QM31.zero(),
        .signed_imm = QM31.zero(),
        .imm_sign = QM31.zero(),
        .enabler = QM31.zero(),
        .rd = zero_access,
        .rs1 = zero_access,
        .next_pc = QM31.zero(),
        .inst_lo = QM31.zero(),
        .inst_hi = QM31.zero(),
    };
}

test "base alu imm semantics: exact ADDI accepts an honest row" {
    var row = zeroRow();
    row.pc = common.q(0x1000);
    row.next_pc = common.q(0x1004);
    row.is_addi = QM31.one();
    row.enabler = QM31.one();
    row.signed_imm = common.q(1);
    row.rd.next[0] = common.q(1);
    const witness = ImmediateWitness{ .imm_0 = common.q(1), .imm_1 = QM31.zero() };
    try std.testing.expect(evaluate(row, witness, QM31.one()).allZero());
}

test "base alu imm semantics: exact ADDI rejects known impossible witness" {
    var row = zeroRow();
    row.pc = common.q(0x1000);
    row.next_pc = common.q(0x1004);
    row.is_addi = QM31.one();
    row.enabler = QM31.one();
    row.signed_imm = common.q(1);
    // The pre-existing prover test claimed ADDI x1,x1,1 while rs1 remained 0
    // and rd advanced to 2. The byte carry constraint must reject that row.
    row.rs1.next[0] = common.q(0);
    row.rd.next[0] = common.q(2);
    const witness = ImmediateWitness{ .imm_0 = common.q(1), .imm_1 = QM31.zero() };
    try std.testing.expect(!evaluate(row, witness, QM31.one()).allZero());
}

test "base alu imm semantics: byte carries reject M31 word alias" {
    var row = zeroRow();
    row.pc = common.q(0x1000);
    row.next_pc = common.q(0x1004);
    row.is_addi = QM31.one();
    row.enabler = QM31.one();
    // 0x7fffffff is the M31 modulus, so a single reconstructed word equation
    // would confuse this forged result with zero. Per-byte carries do not.
    row.rd.next = .{ common.q(255), common.q(255), common.q(255), common.q(127) };
    const witness = ImmediateWitness{ .imm_0 = QM31.zero(), .imm_1 = QM31.zero() };
    try std.testing.expect(common.composeU32(row.rd.next).isZero());
    try std.testing.expect(!evaluate(row, witness, QM31.one()).allZero());
}

test "base alu imm semantics: negative immediate sign extends by bytes" {
    var row = zeroRow();
    row.pc = common.q(0x1000);
    row.next_pc = common.q(0x1004);
    row.is_addi = QM31.one();
    row.enabler = QM31.one();
    row.imm_sign = QM31.one();
    row.signed_imm = common.q(1).neg();
    row.rs1.next = .{QM31.zero()} ** 4;
    row.rd.next = .{ common.q(255), common.q(255), common.q(255), common.q(255) };
    const witness = ImmediateWitness{ .imm_0 = common.q(255), .imm_1 = common.q(7) };
    try std.testing.expect(evaluate(row, witness, QM31.one()).allZero());

    const tuple = programLookup(row, witness);
    try std.testing.expect(tuple.opcode_id.eql(common.q(10)));
    try std.testing.expect(tuple.operand.eql(common.q(4095)));
}

test "base alu imm semantics: access lookups preserve register chain values" {
    var row = zeroRow();
    row.clk = common.q(23);
    row.rd.addr = common.q(3);
    row.rd.previous_clock = common.q(17);
    row.rd.previous[2] = common.q(90);
    row.rd.next[2] = common.q(91);

    const chain = accessLookups(row).rd;
    try std.testing.expect(chain.previous.addr.eql(common.q(3)));
    try std.testing.expect(chain.previous.clock.eql(common.q(17)));
    try std.testing.expect(chain.previous.limbs[2].eql(common.q(90)));
    try std.testing.expect(chain.next.clock.eql(common.q(23)));
    try std.testing.expect(chain.next.limbs[2].eql(common.q(91)));
    try std.testing.expect(chain.clock_gap.eql(common.q(6)));
}

test "base alu imm semantics: full main-column adapter preserves access blocks" {
    var columns = [_]QM31{QM31.zero()} ** N_MAIN_COLUMNS;
    columns[9] = common.q(1);
    columns[10] = common.q(2);
    columns[14] = common.q(3);
    columns[15] = common.q(4);
    columns[19] = common.q(5);
    columns[20] = common.q(6);
    columns[24] = common.q(7);
    columns[25] = common.q(8);
    columns[29] = common.q(9);
    columns[30] = common.q(10);
    columns[31] = common.q(11);

    const row = try Row.fromMainColumns(&columns);
    try std.testing.expect(row.rd.addr.eql(common.q(1)));
    try std.testing.expect(row.rd.previous[0].eql(common.q(2)));
    try std.testing.expect(row.rd.previous_clock.eql(common.q(3)));
    try std.testing.expect(row.rd.next[0].eql(common.q(4)));
    try std.testing.expect(row.rs1.addr.eql(common.q(5)));
    try std.testing.expect(row.rs1.previous[0].eql(common.q(6)));
    try std.testing.expect(row.rs1.previous_clock.eql(common.q(7)));
    try std.testing.expect(row.rs1.next[0].eql(common.q(8)));
    try std.testing.expect(row.next_pc.eql(common.q(9)));
    try std.testing.expect(row.inst_lo.eql(common.q(10)));
    try std.testing.expect(row.inst_hi.eql(common.q(11)));
}
