//! AIR component for clock gap-filling.
//!
//! When the clock difference between consecutive memory accesses exceeds
//! 2^20, intermediate "dummy" accesses are generated to keep the clock
//! difference within range-check bounds.
//!
//! Trace layout (6 columns):
//!   addr_space, addr, clk, prev_clk, clk_diff, enabler.
//!
//! Constraints:
//!   - enabler is boolean.
//!   - clk_diff = clk - prev_clk  (when enabled).
//!   - clk_diff range checked via range_check_20 lookup.

const std = @import("std");
const cf = @import("../../../../core/constraint_framework/mod.zig");
const claims_mod = @import("../claims.zig");
const trace = @import("../trace_columns.zig");
const M31 = @import("../../../../core/fields/m31.zig").M31;

const ExprEvaluator = cf.ExprEvaluator;
const ExprArena = cf.ExprArena;
const BaseExpr = cf.BaseExpr;
const ExtExpr = cf.ExtExpr;

pub const Columns = trace.ClockUpdateColumns;
pub const N_TRACE_COLUMNS: usize = Columns.N_COLUMNS;
pub const Claim = claims_mod.ComponentClaim;
pub const InteractionClaim = claims_mod.ComponentInteractionClaim;

/// Evaluate the clock_update AIR constraints.
pub fn evaluate(eval: *ExprEvaluator) !void {
    const arena = eval.arena;

    // Read all 6 trace columns in order.
    const addr_space = try eval.nextTraceMask();
    const addr = try eval.nextTraceMask();
    const clk = try eval.nextTraceMask();
    const prev_clk = try eval.nextTraceMask();
    const clk_diff = try eval.nextTraceMask();
    const enabler = try eval.nextTraceMask();

    _ = addr_space;
    _ = addr;

    // ---- enabler is boolean ----
    try eval.addConstraint(try arena.extFromBase(
        try arena.baseSub(try arena.baseMul(enabler, enabler), enabler),
    ));

    // ---- clk_diff = clk - prev_clk (when enabled) ----
    // enabler * (clk_diff - (clk - prev_clk)) = 0
    const expected_diff = try arena.baseSub(clk, prev_clk);
    const diff_err = try arena.baseSub(clk_diff, expected_diff);
    try eval.addConstraint(try arena.extFromBase(
        try arena.baseMul(enabler, diff_err),
    ));

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

    // 1 enabler-boolean + 1 clk_diff correctness + 1 logup = 3
    try std.testing.expectEqual(@as(usize, 3), eval.constraints.items.len);
}
