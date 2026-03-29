//! AIR component for the less-than immediate family.
//!
//! Instructions: SLTI, SLTIU (2 ops).
//!
//! Trace layout (15 columns):
//!   clk, pc, rd, rs1, imm, rd_val, rs1_val, result,
//!   is_slti, is_sltiu, enabler, diff_lo, diff_hi, imm_sign, instruction_word.
//!
//! Similar to lt_reg but compares against a sign-extended immediate.

const std = @import("std");
const cf = @import("../../../../core/constraint_framework/mod.zig");
const claims_mod = @import("../claims.zig");
const trace = @import("../trace_columns.zig");
const M31 = @import("../../../../core/fields/m31.zig").M31;

const ExprEvaluator = cf.ExprEvaluator;
const ExprArena = cf.ExprArena;
const BaseExpr = cf.BaseExpr;
const ExtExpr = cf.ExtExpr;

pub const Columns = trace.LtImmColumns;
pub const N_TRACE_COLUMNS: usize = Columns.N_COLUMNS;
pub const Claim = claims_mod.ComponentClaim;
pub const InteractionClaim = claims_mod.ComponentInteractionClaim;

/// Evaluate the lt_imm AIR constraints.
pub fn evaluate(eval: *ExprEvaluator) !void {
    const arena = eval.arena;

    const clk = try eval.nextTraceMask();
    const pc = try eval.nextTraceMask();
    const rd = try eval.nextTraceMask();
    const rs1 = try eval.nextTraceMask();
    const imm = try eval.nextTraceMask();
    const rd_val = try eval.nextTraceMask();
    const rs1_val = try eval.nextTraceMask();
    const result = try eval.nextTraceMask();
    const is_slti = try eval.nextTraceMask();
    const is_sltiu = try eval.nextTraceMask();
    const enabler = try eval.nextTraceMask();
    const diff_lo = try eval.nextTraceMask();
    const diff_hi = try eval.nextTraceMask();
    const imm_sign = try eval.nextTraceMask();
    const instruction_word = try eval.nextTraceMask();

    const one = try arena.baseOne();
    const shift_16 = try arena.baseConst(M31.fromCanonical(1 << 16));
    const four = try arena.baseConst(M31.fromCanonical(4));

    // ---- Flag boolean constraints ----
    const flags = [_]BaseExpr{ is_slti, is_sltiu };
    for (flags) |flag| {
        try eval.addConstraint(try arena.extBase(
            try arena.baseSub(try arena.baseMul(flag, flag), flag),
        ));
    }

    // result and imm_sign are boolean
    try eval.addConstraint(try arena.extBase(
        try arena.baseSub(try arena.baseMul(result, result), result),
    ));
    try eval.addConstraint(try arena.extBase(
        try arena.baseSub(try arena.baseMul(imm_sign, imm_sign), imm_sign),
    ));

    // enabler = sum of flags
    const flag_sum = try arena.baseAdd(is_slti, is_sltiu);
    try eval.addConstraint(try arena.extBase(try arena.baseSub(enabler, flag_sum)));

    // enabler * (enabler - 1) = 0
    try eval.addConstraint(try arena.extBase(try arena.baseMul(enabler, try arena.baseSub(enabler, one))));

    // ---- Difference decomposition ----
    // Compare rs1_val against imm.
    const rs1_minus_imm = try arena.baseSub(rs1_val, imm);
    const imm_minus_rs1_m1 = try arena.baseSub(try arena.baseSub(imm, rs1_val), one);
    const one_minus_result = try arena.baseSub(one, result);
    const expected_diff = try arena.baseAdd(
        try arena.baseMul(one_minus_result, rs1_minus_imm),
        try arena.baseMul(result, imm_minus_rs1_m1),
    );
    const actual_diff = try arena.baseAdd(diff_lo, try arena.baseMul(diff_hi, shift_16));
    try eval.addConstraint(try arena.extBase(
        try arena.baseMul(enabler, try arena.baseSub(actual_diff, expected_diff)),
    ));

    // rd_val = result
    try eval.addConstraint(try arena.extBase(
        try arena.baseMul(enabler, try arena.baseSub(rd_val, result)),
    ));

    // ---- LogUp relations ----
    const alpha = try arena.extParam("alpha");
    const z = try arena.extParam("z");
    const clk_next = try arena.baseAdd(clk, one);

    // Register read rs1
    try eval.writeLogupFrac(.{
        .numerator = try arena.extFromBase(enabler),
        .denominator = try arena.extSub(alpha, try arena.extFromBase(
            try arena.baseAdd(try arena.baseAdd(rs1, try arena.baseMul(clk, shift_16)), rs1_val),
        )),
    });

    // Register write rd
    try eval.writeLogupFrac(.{
        .numerator = try arena.extNeg(try arena.extFromBase(enabler)),
        .denominator = try arena.extSub(alpha, try arena.extFromBase(
            try arena.baseAdd(try arena.baseAdd(rd, try arena.baseMul(clk_next, shift_16)), result),
        )),
    });

    // Program lookup
    try eval.writeLogupFrac(.{
        .numerator = try arena.extFromBase(enabler),
        .denominator = try arena.extSub(z, try arena.extFromBase(
            try arena.baseAdd(pc, try arena.baseMul(instruction_word, shift_16)),
        )),
    });

    // Range check 8_8 for diff
    try eval.writeLogupFrac(.{
        .numerator = try arena.extFromBase(enabler),
        .denominator = try arena.extSub(z, try arena.extFromBase(
            try arena.baseAdd(diff_lo, try arena.baseMul(diff_hi, shift_16)),
        )),
    });

    // Opcode bus
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

test "lt_imm: constraint count" {
    var arena = cf.ExprArena.init(std.testing.allocator);
    defer arena.deinit();
    var eval = try ExprEvaluator.init(&arena, std.testing.allocator);
    defer eval.deinit();

    try evaluate(&eval);
    try std.testing.expect(eval.constraints.items.len > 0);
}
