//! AIR component for the JALR (Jump And Link Register) instruction.
//!
//! Instructions: JALR (1 op).
//!
//! Trace layout (26 columns):
//!   clk, pc, imm, enabler, target_lo, target_hi,
//!   rd_access(10), rs1_access(10).
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

pub const Columns = trace.JalrColumns;
pub const N_TRACE_COLUMNS: usize = Columns.N_COLUMNS;
pub const Claim = claims_mod.ComponentClaim;
pub const InteractionClaim = claims_mod.ComponentInteractionClaim;

/// Evaluate the jalr AIR constraints.
pub fn evaluate(eval: *ExprEvaluator) !void {
    const arena = eval.arena;

    // Common (6)
    const _clk = try eval.nextTraceMask();
    const _pc = try eval.nextTraceMask();
    const _imm = try eval.nextTraceMask();
    const enabler = try eval.nextTraceMask();
    const _target_lo = try eval.nextTraceMask();
    const _target_hi = try eval.nextTraceMask();

    // rd access (10)
    var rd_cols: [10]BaseExpr = undefined;
    for (&rd_cols) |*col| col.* = try eval.nextTraceMask();

    // rs1 access (10)
    var rs1_cols: [10]BaseExpr = undefined;
    for (&rs1_cols) |*col| col.* = try eval.nextTraceMask();

    _ = _clk;
    _ = _pc;
    _ = _imm;
    _ = _target_lo;
    _ = _target_hi;

    // enabler is boolean
    try eval.addConstraint(try arena.extBase(
        try arena.baseSub(try arena.baseMul(enabler, enabler), enabler),
    ));

    try eval.finalizeLogupInPairs();
}

test "jalr: constraint count" {
    var arena = cf.ExprArena.init(std.testing.allocator);
    defer arena.deinit();
    var eval = try ExprEvaluator.init(&arena, std.testing.allocator);
    defer eval.deinit();

    try evaluate(&eval);
    try std.testing.expect(eval.constraints.items.len > 0);
}
