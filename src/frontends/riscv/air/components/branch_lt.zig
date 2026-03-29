//! AIR component for the branch-less-than family.
//!
//! Instructions: BLT, BLTU, BGE, BGEU (4 ops).
//!
//! Trace layout (16 columns):
//!   clk, pc, rs1, rs2, rs1_val, rs2_val, is_blt, is_bltu, is_bge, is_bgeu,
//!   enabler, branch_target, diff_lo, diff_hi, is_less_than, instruction_word.
//!
//! Constraints:
//!   - Flags boolean, enabler = sum, enabler in {0,1}.
//!   - is_less_than is boolean.
//!   - Difference decomposition proves the comparison.
//!   - PC update: taken depends on instruction and comparison result.
//!       BLT taken iff is_less_than; BGE taken iff !is_less_than.

const std = @import("std");
const cf = @import("../../../../core/constraint_framework/mod.zig");
const claims_mod = @import("../claims.zig");
const trace = @import("../trace_columns.zig");
const M31 = @import("../../../../core/fields/m31.zig").M31;

const ExprEvaluator = cf.ExprEvaluator;
const ExprArena = cf.ExprArena;
const BaseExpr = cf.BaseExpr;
const ExtExpr = cf.ExtExpr;

pub const Columns = trace.BranchLtColumns;
pub const N_TRACE_COLUMNS: usize = Columns.N_COLUMNS;
pub const Claim = claims_mod.ComponentClaim;
pub const InteractionClaim = claims_mod.ComponentInteractionClaim;

/// Evaluate the branch_lt AIR constraints.
pub fn evaluate(eval: *ExprEvaluator) !void {
    const arena = eval.arena;

    const clk = try eval.nextTraceMask();
    const pc = try eval.nextTraceMask();
    const rs1 = try eval.nextTraceMask();
    const rs2 = try eval.nextTraceMask();
    const rs1_val = try eval.nextTraceMask();
    const rs2_val = try eval.nextTraceMask();
    const is_blt = try eval.nextTraceMask();
    const is_bltu = try eval.nextTraceMask();
    const is_bge = try eval.nextTraceMask();
    const is_bgeu = try eval.nextTraceMask();
    const enabler = try eval.nextTraceMask();
    const branch_target = try eval.nextTraceMask();
    const diff_lo = try eval.nextTraceMask();
    const diff_hi = try eval.nextTraceMask();
    const is_less_than = try eval.nextTraceMask();
    const instruction_word = try eval.nextTraceMask();

    const one = try arena.baseOne();
    const shift_16 = try arena.baseConst(M31.fromCanonical(1 << 16));
    const four = try arena.baseConst(M31.fromCanonical(4));

    // ---- Flag boolean constraints ----
    const flags = [_]BaseExpr{ is_blt, is_bltu, is_bge, is_bgeu, is_less_than };
    for (flags) |flag| {
        try eval.addConstraint(try arena.extBase(
            try arena.baseSub(try arena.baseMul(flag, flag), flag),
        ));
    }

    // enabler = sum of instruction flags
    var flag_sum = is_blt;
    flag_sum = try arena.baseAdd(flag_sum, is_bltu);
    flag_sum = try arena.baseAdd(flag_sum, is_bge);
    flag_sum = try arena.baseAdd(flag_sum, is_bgeu);
    try eval.addConstraint(try arena.extBase(try arena.baseSub(enabler, flag_sum)));

    // enabler * (enabler - 1) = 0
    try eval.addConstraint(try arena.extBase(try arena.baseMul(enabler, try arena.baseSub(enabler, one))));

    // ---- Difference decomposition ----
    // If is_less_than = 1: diff = rs2_val - rs1_val - 1  (non-negative)
    // If is_less_than = 0: diff = rs1_val - rs2_val      (non-negative)
    const rs1_minus_rs2 = try arena.baseSub(rs1_val, rs2_val);
    const rs2_minus_rs1_m1 = try arena.baseSub(try arena.baseSub(rs2_val, rs1_val), one);
    const one_minus_lt = try arena.baseSub(one, is_less_than);
    const expected_diff = try arena.baseAdd(
        try arena.baseMul(one_minus_lt, rs1_minus_rs2),
        try arena.baseMul(is_less_than, rs2_minus_rs1_m1),
    );
    const actual_diff = try arena.baseAdd(diff_lo, try arena.baseMul(diff_hi, shift_16));
    try eval.addConstraint(try arena.extBase(
        try arena.baseMul(enabler, try arena.baseSub(actual_diff, expected_diff)),
    ));

    // ---- PC update ----
    // taken = (is_blt + is_bltu) * is_less_than + (is_bge + is_bgeu) * (1 - is_less_than)
    const lt_group = try arena.baseAdd(is_blt, is_bltu);
    const ge_group = try arena.baseAdd(is_bge, is_bgeu);
    const taken = try arena.baseAdd(
        try arena.baseMul(lt_group, is_less_than),
        try arena.baseMul(ge_group, one_minus_lt),
    );
    const pc_plus_4 = try arena.baseAdd(pc, four);
    const one_minus_taken = try arena.baseSub(one, taken);
    const expected_next_pc = try arena.baseAdd(
        try arena.baseMul(taken, branch_target),
        try arena.baseMul(one_minus_taken, pc_plus_4),
    );

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

    // Register read rs2
    try eval.writeLogupFrac(.{
        .numerator = try arena.extFromBase(enabler),
        .denominator = try arena.extSub(alpha, try arena.extFromBase(
            try arena.baseAdd(try arena.baseAdd(rs2, try arena.baseMul(clk, shift_16)), rs2_val),
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
        .denominator = try arena.extSub(z, try arena.extFromBase(actual_diff)),
    });

    // Opcode bus: current state
    try eval.writeLogupFrac(.{
        .numerator = try arena.extFromBase(enabler),
        .denominator = try arena.extSub(alpha, try arena.extFromBase(try arena.baseAdd(pc, clk))),
    });

    // Opcode bus: next state
    try eval.writeLogupFrac(.{
        .numerator = try arena.extNeg(try arena.extFromBase(enabler)),
        .denominator = try arena.extSub(alpha, try arena.extFromBase(try arena.baseAdd(expected_next_pc, clk_next))),
    });

    try eval.finalizeLogupInPairs();
}

test "branch_lt: constraint count" {
    var arena = cf.ExprArena.init(std.testing.allocator);
    defer arena.deinit();
    var eval = try ExprEvaluator.init(&arena, std.testing.allocator);
    defer eval.deinit();

    try evaluate(&eval);
    try std.testing.expect(eval.constraints.items.len > 0);
}
