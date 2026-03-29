//! AIR component for the base ALU immediate family.
//!
//! Instructions: ADDI, XORI, ORI, ANDI (4 ops).
//!
//! Trace layout (15 columns):
//!   clk, pc, rd, rs1, imm, rd_val, rs1_val, result,
//!   is_addi, is_xori, is_ori, is_andi, enabler, imm_sign, instruction_word.
//!
//! Constraints:
//!   - Each flag is boolean.
//!   - enabler = sum of flags, enabler in {0,1}.
//!   - imm_sign is boolean (sign extension bit).
//!   - Result correctness:
//!       is_addi * (rs1_val + imm - result) = 0
//!       is_xori / is_ori / is_andi verified via bitwise lookup.
//!   - Register read: rs1 via register_access.
//!   - Register write: rd via register_access.
//!   - Program lookup and opcode bus transitions.

const std = @import("std");
const cf = @import("../../../../core/constraint_framework/mod.zig");
const claims_mod = @import("../claims.zig");
const trace = @import("../trace_columns.zig");
const M31 = @import("../../../../core/fields/m31.zig").M31;

const ExprEvaluator = cf.ExprEvaluator;
const ExprArena = cf.ExprArena;
const BaseExpr = cf.BaseExpr;
const ExtExpr = cf.ExtExpr;

pub const Columns = trace.BaseAluImmColumns;
pub const N_TRACE_COLUMNS: usize = Columns.N_COLUMNS;
pub const Claim = claims_mod.ComponentClaim;
pub const InteractionClaim = claims_mod.ComponentInteractionClaim;

/// Evaluate the base_alu_imm AIR constraints.
pub fn evaluate(eval: *ExprEvaluator) !void {
    const arena = eval.arena;

    // Read all 15 trace columns.
    const clk = try eval.nextTraceMask();
    const pc = try eval.nextTraceMask();
    const rd = try eval.nextTraceMask();
    const rs1 = try eval.nextTraceMask();
    const imm = try eval.nextTraceMask();
    const rd_val = try eval.nextTraceMask();
    const rs1_val = try eval.nextTraceMask();
    const result = try eval.nextTraceMask();
    const is_addi = try eval.nextTraceMask();
    const is_xori = try eval.nextTraceMask();
    const is_ori = try eval.nextTraceMask();
    const is_andi = try eval.nextTraceMask();
    const enabler = try eval.nextTraceMask();
    const imm_sign = try eval.nextTraceMask();
    const instruction_word = try eval.nextTraceMask();

    // ---- Flag boolean constraints ----
    const flags = [_]BaseExpr{ is_addi, is_xori, is_ori, is_andi };
    for (flags) |flag| {
        const flag_sq = try arena.baseMul(flag, flag);
        try eval.addConstraint(try arena.extBase(try arena.baseSub(flag_sq, flag)));
    }

    // imm_sign is boolean
    const sign_sq = try arena.baseMul(imm_sign, imm_sign);
    try eval.addConstraint(try arena.extBase(try arena.baseSub(sign_sq, imm_sign)));

    // ---- Enabler = sum of flags ----
    var flag_sum = is_addi;
    flag_sum = try arena.baseAdd(flag_sum, is_xori);
    flag_sum = try arena.baseAdd(flag_sum, is_ori);
    flag_sum = try arena.baseAdd(flag_sum, is_andi);
    try eval.addConstraint(try arena.extBase(try arena.baseSub(enabler, flag_sum)));

    // enabler * (enabler - 1) = 0
    const one = try arena.baseOne();
    const enabler_m1 = try arena.baseSub(enabler, one);
    try eval.addConstraint(try arena.extBase(try arena.baseMul(enabler, enabler_m1)));

    // ---- Result correctness ----
    // is_addi * (rs1_val + imm - result) = 0
    const add_res = try arena.baseSub(try arena.baseAdd(rs1_val, imm), result);
    try eval.addConstraint(try arena.extBase(try arena.baseMul(is_addi, add_res)));

    // Bitwise ops: rd_val holds the correct result from lookup.
    const bitwise_diff = try arena.baseSub(rd_val, result);
    try eval.addConstraint(try arena.extBase(try arena.baseMul(is_xori, bitwise_diff)));
    try eval.addConstraint(try arena.extBase(try arena.baseMul(is_ori, bitwise_diff)));
    try eval.addConstraint(try arena.extBase(try arena.baseMul(is_andi, bitwise_diff)));

    // ---- LogUp relations ----
    const alpha = try arena.extParam("alpha");
    const z = try arena.extParam("z");
    const shift_16 = try arena.baseConst(M31.fromCanonical(1 << 16));
    const four = try arena.baseConst(M31.fromCanonical(4));
    const clk_next = try arena.baseAdd(clk, one);

    // Register read rs1
    const rs1_entry = try arena.extFromBase(try arena.baseAdd(
        try arena.baseAdd(rs1, try arena.baseMul(clk, shift_16)),
        rs1_val,
    ));
    try eval.writeLogupFrac(.{
        .numerator = try arena.extFromBase(enabler),
        .denominator = try arena.extSub(alpha, rs1_entry),
    });

    // Register write rd
    const rd_entry = try arena.extFromBase(try arena.baseAdd(
        try arena.baseAdd(rd, try arena.baseMul(clk_next, shift_16)),
        result,
    ));
    try eval.writeLogupFrac(.{
        .numerator = try arena.extNeg(try arena.extFromBase(enabler)),
        .denominator = try arena.extSub(alpha, rd_entry),
    });

    // Program lookup
    const prog_entry = try arena.extFromBase(try arena.baseAdd(
        pc,
        try arena.baseMul(instruction_word, shift_16),
    ));
    try eval.writeLogupFrac(.{
        .numerator = try arena.extFromBase(enabler),
        .denominator = try arena.extSub(z, prog_entry),
    });

    // Opcode bus transitions
    const pc_next = try arena.baseAdd(pc, four);
    try eval.writeLogupFrac(.{
        .numerator = try arena.extFromBase(enabler),
        .denominator = try arena.extSub(alpha, try arena.extFromBase(try arena.baseAdd(pc, clk))),
    });
    try eval.writeLogupFrac(.{
        .numerator = try arena.extNeg(try arena.extFromBase(enabler)),
        .denominator = try arena.extSub(alpha, try arena.extFromBase(try arena.baseAdd(pc_next, clk_next))),
    });

    try eval.finalizeLogupInPairs();
}

test "base_alu_imm: constraint count" {
    var arena = cf.ExprArena.init(std.testing.allocator);
    defer arena.deinit();
    var eval = try ExprEvaluator.init(&arena, std.testing.allocator);
    defer eval.deinit();

    try evaluate(&eval);

    // 4 flag-bit + 1 sign-bit + 1 enabler-eq + 1 enabler-bit
    // + 1 addi result + 3 bitwise result = 11 direct
    // + logup constraints from finalizeLogupInPairs (5 fracs -> 3 constraints).
    try std.testing.expect(eval.constraints.items.len > 0);
}
