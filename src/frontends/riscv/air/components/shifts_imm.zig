//! AIR component for the shifts immediate family.
//!
//! Instructions: SLLI, SRLI, SRAI (3 ops).
//!
//! Trace layout (45 columns):
//!   clk, pc, is_slli, is_srli, is_srai, enabler, imm,
//!   shift decomposition (18), rd_access(10), rs1_access(10).
//!
//! Constraints:
//!   - Flags are boolean, enabler = sum of flags.

const std = @import("std");
const cf = @import("stwo_core").constraint_framework;
const claims_mod = @import("../claims.zig");
const trace = @import("../trace_columns.zig");
const M31 = @import("stwo_core").fields.m31.M31;

const ExprEvaluator = cf.ExprEvaluator;
const ExprArena = cf.ExprArena;
const BaseExpr = cf.BaseExpr;
const ExtExpr = cf.ExtExpr;

pub const Columns = trace.ShiftsImmColumns;
pub const N_TRACE_COLUMNS: usize = Columns.N_COLUMNS;
pub const Claim = claims_mod.ComponentClaim;
pub const InteractionClaim = claims_mod.ComponentInteractionClaim;

/// Evaluate the shifts_imm AIR constraints.
pub fn evaluate(eval: *ExprEvaluator) !void {
    const arena = eval.arena;

    // Common (7)
    const _clk = try eval.nextTraceMask();
    const _pc = try eval.nextTraceMask();
    const is_slli = try eval.nextTraceMask();
    const is_srli = try eval.nextTraceMask();
    const is_srai = try eval.nextTraceMask();
    const enabler = try eval.nextTraceMask();
    const _imm = try eval.nextTraceMask();

    // Shift decomposition (18)
    var shift_cols: [18]BaseExpr = undefined;
    for (&shift_cols) |*col| col.* = try eval.nextTraceMask();

    // rd access (10)
    var rd_cols: [10]BaseExpr = undefined;
    for (&rd_cols) |*col| col.* = try eval.nextTraceMask();

    // rs1 access (10)
    var rs1_cols: [10]BaseExpr = undefined;
    for (&rs1_cols) |*col| col.* = try eval.nextTraceMask();

    _ = _clk;
    _ = _pc;
    _ = _imm;

    const one = try arena.baseOne();

    // ---- Flag boolean constraints ----
    const flags = [_]BaseExpr{ is_slli, is_srli, is_srai };
    for (flags) |flag| {
        const flag_sq = try arena.baseMul(flag, flag);
        try eval.addConstraint(try arena.extBase(try arena.baseSub(flag_sq, flag)));
    }

    // enabler = sum of flags
    var flag_sum = is_slli;
    flag_sum = try arena.baseAdd(flag_sum, is_srli);
    flag_sum = try arena.baseAdd(flag_sum, is_srai);
    try eval.addConstraint(try arena.extBase(try arena.baseSub(enabler, flag_sum)));

    // enabler * (enabler - 1) = 0
    try eval.addConstraint(try arena.extBase(try arena.baseMul(enabler, try arena.baseSub(enabler, one))));

    try eval.finalizeLogupInPairs();
}

test "shifts_imm: constraint count" {
    var arena = cf.ExprArena.init(std.testing.allocator);
    defer arena.deinit();
    var eval = try ExprEvaluator.init(&arena, std.testing.allocator);
    defer eval.deinit();

    try evaluate(&eval);
    try std.testing.expect(eval.constraints.items.len > 0);
}
