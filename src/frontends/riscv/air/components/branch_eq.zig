//! AIR component for the branch-equal family.
//!
//! Instructions: BEQ, BNE (2 ops).
//!
//! Trace layout (30 columns):
//!   clk, pc, is_beq, is_bne, enabler, branch_target, diff, diff_inv,
//!   is_equal, branch_target_aux, rs1_access(10), rs2_access(10).
//!
//! Constraints:
//!   - Flags boolean, enabler = sum, enabler in {0,1}.
//!   - is_equal is boolean.
//!   - is_equal * diff = 0.
//!   - (1 - is_equal) * (1 - diff * diff_inv) = 0.

const std = @import("std");
const cf = @import("stwo_core").constraint_framework;
const claims_mod = @import("../claims.zig");
const trace = @import("../trace_columns.zig");
const M31 = @import("stwo_core").fields.m31.M31;

const ExprEvaluator = cf.ExprEvaluator;
const ExprArena = cf.ExprArena;
const BaseExpr = cf.BaseExpr;
const ExtExpr = cf.ExtExpr;

pub const Columns = trace.BranchEqColumns;
pub const N_TRACE_COLUMNS: usize = Columns.N_COLUMNS;
pub const Claim = claims_mod.ComponentClaim;
pub const InteractionClaim = claims_mod.ComponentInteractionClaim;

/// Evaluate the branch_eq AIR constraints.
pub fn evaluate(eval: *ExprEvaluator) !void {
    const arena = eval.arena;

    // Common (10)
    const _clk = try eval.nextTraceMask();
    const _pc = try eval.nextTraceMask();
    const is_beq = try eval.nextTraceMask();
    const is_bne = try eval.nextTraceMask();
    const enabler = try eval.nextTraceMask();
    const _branch_target = try eval.nextTraceMask();
    const diff = try eval.nextTraceMask();
    const diff_inv = try eval.nextTraceMask();
    const is_equal = try eval.nextTraceMask();
    const _branch_target_aux = try eval.nextTraceMask();

    // rs1 access (10)
    var rs1_cols: [10]BaseExpr = undefined;
    for (&rs1_cols) |*col| col.* = try eval.nextTraceMask();

    // rs2 access (10)
    var rs2_cols: [10]BaseExpr = undefined;
    for (&rs2_cols) |*col| col.* = try eval.nextTraceMask();

    _ = _clk;
    _ = _pc;
    _ = _branch_target;
    _ = _branch_target_aux;

    const one = try arena.baseOne();

    // ---- Flag boolean constraints ----
    const flags = [_]BaseExpr{ is_beq, is_bne, is_equal };
    for (flags) |flag| {
        try eval.addConstraint(try arena.extBase(
            try arena.baseSub(try arena.baseMul(flag, flag), flag),
        ));
    }

    // enabler = is_beq + is_bne
    const flag_sum = try arena.baseAdd(is_beq, is_bne);
    try eval.addConstraint(try arena.extBase(try arena.baseSub(enabler, flag_sum)));

    // enabler * (enabler - 1) = 0
    try eval.addConstraint(try arena.extBase(try arena.baseMul(enabler, try arena.baseSub(enabler, one))));

    // ---- Equality check constraints ----
    // is_equal * diff = 0
    try eval.addConstraint(try arena.extBase(try arena.baseMul(is_equal, diff)));

    // (1 - is_equal) * (1 - diff * diff_inv) = 0
    const one_minus_eq = try arena.baseSub(one, is_equal);
    const one_minus_inv = try arena.baseSub(one, try arena.baseMul(diff, diff_inv));
    try eval.addConstraint(try arena.extBase(try arena.baseMul(one_minus_eq, one_minus_inv)));

    try eval.finalizeLogupInPairs();
}

test "branch_eq: constraint count" {
    var arena = cf.ExprArena.init(std.testing.allocator);
    defer arena.deinit();
    var eval = try ExprEvaluator.init(&arena, std.testing.allocator);
    defer eval.deinit();

    try evaluate(&eval);
    try std.testing.expect(eval.constraints.items.len > 0);
}
