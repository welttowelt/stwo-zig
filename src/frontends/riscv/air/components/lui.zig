//! AIR component for the LUI (Load Upper Immediate) instruction.
//!
//! Instructions: LUI (1 op).
//!
//! Trace layout (16 columns):
//!   clk, pc, imm_u, enabler, result_lo, result_hi, rd_access(10).
//!
//! Constraints:
//!   - enabler is boolean.

const std = @import("std");
const cf = @import("stwo_core").constraint_framework;
const claims_mod = @import("../claims.zig");
const trace = @import("../trace_columns.zig");
const M31 = @import("stwo_core").fields.m31.M31;

const ExprEvaluator = cf.ExprEvaluator;
const ExprArena = cf.ExprArena;
const BaseExpr = cf.BaseExpr;
const ExtExpr = cf.ExtExpr;

pub const Columns = trace.LuiColumns;
pub const N_TRACE_COLUMNS: usize = Columns.N_COLUMNS;
pub const Claim = claims_mod.ComponentClaim;
pub const InteractionClaim = claims_mod.ComponentInteractionClaim;

/// Evaluate the lui AIR constraints.
pub fn evaluate(eval: *ExprEvaluator) !void {
    const arena = eval.arena;

    // Common (6)
    const _clk = try eval.nextTraceMask();
    const _pc = try eval.nextTraceMask();
    const _imm_u = try eval.nextTraceMask();
    const enabler = try eval.nextTraceMask();
    const _result_lo = try eval.nextTraceMask();
    const _result_hi = try eval.nextTraceMask();

    // rd access (10)
    var rd_cols: [10]BaseExpr = undefined;
    for (&rd_cols) |*col| col.* = try eval.nextTraceMask();

    _ = _clk;
    _ = _pc;
    _ = _imm_u;
    _ = _result_lo;
    _ = _result_hi;

    // enabler is boolean
    try eval.addConstraint(try arena.extBase(
        try arena.baseSub(try arena.baseMul(enabler, enabler), enabler),
    ));

    try eval.finalizeLogupInPairs();
}

test "lui: constraint count" {
    var arena = cf.ExprArena.init(std.testing.allocator);
    defer arena.deinit();
    var eval = try ExprEvaluator.init(&arena, std.testing.allocator);
    defer eval.deinit();

    try evaluate(&eval);
    try std.testing.expect(eval.constraints.items.len > 0);
}
