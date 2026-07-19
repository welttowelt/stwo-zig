//! AIR component for the branch-less-than family.
//!
//! Instructions: BLT, BLTU, BGE, BGEU (4 ops).
//!
//! Trace layout (37 columns):
//!   clk, pc, is_blt, is_bltu, is_bge, is_bgeu, enabler, branch_target,
//!   comparison/branch decomposition (9), rs1_access(10), rs2_access(10).
//!
//! Constraints:
//!   - Flags boolean, enabler = sum, enabler in {0,1}.

const std = @import("std");
const cf = @import("stwo_core").constraint_framework;
const claims_mod = @import("../claims.zig");
const trace = @import("../trace_columns.zig");
const M31 = @import("stwo_core").fields.m31.M31;

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

    // Common (8)
    const _clk = try eval.nextTraceMask();
    const _pc = try eval.nextTraceMask();
    const is_blt = try eval.nextTraceMask();
    const is_bltu = try eval.nextTraceMask();
    const is_bge = try eval.nextTraceMask();
    const is_bgeu = try eval.nextTraceMask();
    const enabler = try eval.nextTraceMask();
    const _branch_target = try eval.nextTraceMask();

    // Comparison/branch decomposition (9)
    var cmp_cols: [9]BaseExpr = undefined;
    for (&cmp_cols) |*col| col.* = try eval.nextTraceMask();

    // rs1 access (10)
    var rs1_cols: [10]BaseExpr = undefined;
    for (&rs1_cols) |*col| col.* = try eval.nextTraceMask();

    // rs2 access (10)
    var rs2_cols: [10]BaseExpr = undefined;
    for (&rs2_cols) |*col| col.* = try eval.nextTraceMask();

    _ = _clk;
    _ = _pc;
    _ = _branch_target;

    const one = try arena.baseOne();

    // ---- Flag boolean constraints ----
    const flags = [_]BaseExpr{ is_blt, is_bltu, is_bge, is_bgeu };
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
