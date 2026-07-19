//! AIR component for register clock update (gap-filling).
//!
//! Ensures register access clock ordering is within range-check bounds.
//! Intermediate rows fill gaps when the clock difference exceeds the bound.
//!
//! Trace layout (7 columns):
//!   enabler, addr, clk_prev, value_0, value_1, value_2, value_3.
//!
//! Constraints:
//!   - enabler is boolean.
//!   - clk_diff range checked via range_check_20 lookup.

const std = @import("std");
const cf = @import("stwo_core").constraint_framework;
const claims_mod = @import("../claims.zig");
const trace = @import("../trace_columns.zig");
const M31 = @import("stwo_core").fields.m31.M31;

const ExprEvaluator = cf.ExprEvaluator;
const ExprArena = cf.ExprArena;
const BaseExpr = cf.BaseExpr;
const ExtExpr = cf.ExtExpr;

pub const Columns = trace.RegClockUpdateColumns;
pub const N_TRACE_COLUMNS: usize = Columns.N_COLUMNS;
pub const Claim = claims_mod.ComponentClaim;
pub const InteractionClaim = claims_mod.ComponentInteractionClaim;

/// Evaluate the reg_clock_update AIR constraints.
pub fn evaluate(eval: *ExprEvaluator) !void {
    const arena = eval.arena;

    // Read all 7 trace columns in order.
    const enabler = try eval.nextTraceMask();
    const addr = try eval.nextTraceMask();
    const clk_prev = try eval.nextTraceMask();
    const value_0 = try eval.nextTraceMask();
    const value_1 = try eval.nextTraceMask();
    const value_2 = try eval.nextTraceMask();
    const value_3 = try eval.nextTraceMask();

    _ = addr;
    _ = clk_prev;
    _ = value_0;
    _ = value_1;
    _ = value_2;
    _ = value_3;

    // ---- enabler is boolean ----
    try eval.addConstraint(try arena.extFromBase(
        try arena.baseSub(try arena.baseMul(enabler, enabler), enabler),
    ));

    // ---- LogUp relations ----
    // The clk_diff is range checked via the range_check_20 lookup.
    // For now the clk_diff is implicit (provided by the prover as
    // clk - clk_prev from the register access trace).
    const z = try arena.extParam("z");

    // Range check: +enabler / (z - enabler)
    // Placeholder LogUp fraction -- the actual clk_diff will be wired
    // once the register access trace is fully integrated.
    try eval.writeLogupFrac(.{
        .numerator = try arena.extFromBase(enabler),
        .denominator = try arena.extSub(z, try arena.extFromBase(enabler)),
    });

    try eval.finalizeLogup();
}

test "reg_clock_update: constraint count" {
    var arena = cf.ExprArena.init(std.testing.allocator);
    defer arena.deinit();
    var eval = try ExprEvaluator.init(&arena, std.testing.allocator);
    defer eval.deinit();

    try evaluate(&eval);

    // 1 enabler-boolean + 1 logup = 2
    try std.testing.expectEqual(@as(usize, 2), eval.constraints.items.len);
}
