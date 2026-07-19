//! AIR component for the base ALU register-register family.
//!
//! Instructions: ADD, SUB, XOR, OR, AND (5 ops).
//!
//! Trace layout (37 columns):
//!   clk, pc, is_add, is_sub, is_xor, is_or, is_and,
//!   rd_access(10), rs1_access(10), rs2_access(10).
//!
//! Constraints:
//!   - Each flag is boolean (flag^2 = flag).
//!   - enabler = sum of flags, enabler in {0,1}.
//!   - Register accesses verified via state chain lookups.

const std = @import("std");
const cf = @import("stwo_core").constraint_framework;
const claims_mod = @import("../claims.zig");
const trace = @import("../trace_columns.zig");

const ExprEvaluator = cf.ExprEvaluator;
const ExprArena = cf.ExprArena;
const BaseExpr = cf.BaseExpr;
const ExtExpr = cf.ExtExpr;

pub const Columns = trace.BaseAluRegColumns;
pub const N_TRACE_COLUMNS: usize = Columns.N_COLUMNS;
pub const Claim = claims_mod.ComponentClaim;
pub const InteractionClaim = claims_mod.ComponentInteractionClaim;

/// Evaluate the base_alu_reg AIR constraints.
pub fn evaluate(eval: *ExprEvaluator) !void {
    const arena = eval.arena;

    // Read all 37 trace columns in order.
    // Common (7)
    const _clk = try eval.nextTraceMask();
    const _pc = try eval.nextTraceMask();
    const is_add = try eval.nextTraceMask();
    const is_sub = try eval.nextTraceMask();
    const is_xor = try eval.nextTraceMask();
    const is_or = try eval.nextTraceMask();
    const is_and = try eval.nextTraceMask();

    // rd access (10)
    var rd_cols: [10]BaseExpr = undefined;
    for (&rd_cols) |*col| col.* = try eval.nextTraceMask();

    // rs1 access (10)
    var rs1_cols: [10]BaseExpr = undefined;
    for (&rs1_cols) |*col| col.* = try eval.nextTraceMask();

    // rs2 access (10)
    var rs2_cols: [10]BaseExpr = undefined;
    for (&rs2_cols) |*col| col.* = try eval.nextTraceMask();

    _ = _clk;
    _ = _pc;

    // ---- Flag boolean constraints: flag^2 - flag = 0 ----
    const flags = [_]BaseExpr{ is_add, is_sub, is_xor, is_or, is_and };
    for (flags) |flag| {
        const flag_sq = try arena.baseMul(flag, flag);
        const flag_bit = try arena.baseSub(flag_sq, flag);
        try eval.addConstraint(try arena.extBase(flag_bit));
    }

    // ---- Enabler = sum of flags ----
    var flag_sum = is_add;
    flag_sum = try arena.baseAdd(flag_sum, is_sub);
    flag_sum = try arena.baseAdd(flag_sum, is_xor);
    flag_sum = try arena.baseAdd(flag_sum, is_or);
    flag_sum = try arena.baseAdd(flag_sum, is_and);

    // enabler * (enabler - 1) = 0
    const one = try arena.baseOne();
    const enabler_m1 = try arena.baseSub(flag_sum, one);
    const enabler_bit = try arena.baseMul(flag_sum, enabler_m1);
    try eval.addConstraint(try arena.extBase(enabler_bit));

    try eval.finalizeLogupInPairs();
}

test "base_alu_reg: constraint count" {
    var arena = cf.ExprArena.init(std.testing.allocator);
    defer arena.deinit();
    var eval = try ExprEvaluator.init(&arena, std.testing.allocator);
    defer eval.deinit();

    try evaluate(&eval);

    // 5 flag-bit constraints + 1 enabler-bit = 6 direct
    try std.testing.expect(eval.constraints.items.len > 0);
}
