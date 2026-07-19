//! AIR component for memory clock update (gap-filling).
//!
//! When the clock difference between consecutive memory accesses exceeds
//! the range-check bound, intermediate rows fill the gap.
//!
//! Trace layout (7 columns):
//!   enabler, addr, clk, clk_prev, value_0, value_1, value_2.
//!
//! Constraints:
//!   - enabler is boolean.
//!   - clk_diff = clk - clk_prev (when enabled).
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

pub const Columns = trace.MemClockUpdateColumns;
pub const N_TRACE_COLUMNS: usize = Columns.N_COLUMNS;
pub const Claim = claims_mod.ComponentClaim;
pub const InteractionClaim = claims_mod.ComponentInteractionClaim;

/// Evaluate the mem_clock_update AIR constraints.
pub fn evaluate(eval: *ExprEvaluator) !void {
    const arena = eval.arena;

    // Read all 7 trace columns in order.
    const enabler = try eval.nextTraceMask();
    const addr = try eval.nextTraceMask();
    const clk = try eval.nextTraceMask();
    const clk_prev = try eval.nextTraceMask();
    const value_0 = try eval.nextTraceMask();
    const value_1 = try eval.nextTraceMask();
    const value_2 = try eval.nextTraceMask();

    _ = addr;
    _ = value_0;
    _ = value_1;
    _ = value_2;

    // ---- enabler is boolean ----
    try eval.addConstraint(try arena.extFromBase(
        try arena.baseSub(try arena.baseMul(enabler, enabler), enabler),
    ));

    // ---- clk_diff = clk - clk_prev (when enabled) ----
    // The clk difference is computed inline rather than stored as a separate column.
    const clk_diff = try arena.baseSub(clk, clk_prev);

    // ---- LogUp relations ----
    const z = try arena.extParam("z");

    // Range check clk_diff via range_check_20 lookup:
    // +enabler / (z - clk_diff)
    try eval.writeLogupFrac(.{
        .numerator = try arena.extFromBase(enabler),
        .denominator = try arena.extSub(z, try arena.extFromBase(clk_diff)),
    });

    try eval.finalizeLogup();
}

test "clock_update: constraint count" {
    var arena = cf.ExprArena.init(std.testing.allocator);
    defer arena.deinit();
    var eval = try ExprEvaluator.init(&arena, std.testing.allocator);
    defer eval.deinit();

    try evaluate(&eval);

    // 1 enabler-boolean + 1 logup = 2
    try std.testing.expectEqual(@as(usize, 2), eval.constraints.items.len);
}
