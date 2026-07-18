//! AIR component for the less-than immediate family.
//!
//! Instructions: SLTI, SLTIU (2 ops).
//!
//! Trace layout (34 columns):
//!   clk, pc, is_slti, is_sltiu, enabler, imm, imm_sign,
//!   comparison decomposition (7), rd_access(10), rs1_access(10).
//!
//! Constraints:
//!   - Flags boolean, enabler = sum, enabler in {0,1}.
//!   - imm_sign is boolean.

const std = @import("std");
const cf = @import("../../../../core/constraint_framework/mod.zig");
const claims_mod = @import("../claims.zig");
const trace = @import("../trace_columns.zig");
const M31 = @import("../../../../core/fields/m31.zig").M31;

const ExprEvaluator = cf.ExprEvaluator;
const ExprArena = cf.ExprArena;
const BaseExpr = cf.BaseExpr;
const ExtExpr = cf.ExtExpr;

pub const Columns = trace.LtImmColumns;
pub const N_TRACE_COLUMNS: usize = Columns.N_COLUMNS;
pub const Claim = claims_mod.ComponentClaim;
pub const InteractionClaim = claims_mod.ComponentInteractionClaim;

/// Evaluate the lt_imm AIR constraints.
pub fn evaluate(eval: *ExprEvaluator) !void {
    const arena = eval.arena;

    // Common (7)
    const _clk = try eval.nextTraceMask();
    const _pc = try eval.nextTraceMask();
    const is_slti = try eval.nextTraceMask();
    const is_sltiu = try eval.nextTraceMask();
    const enabler = try eval.nextTraceMask();
    const _imm = try eval.nextTraceMask();
    const imm_sign = try eval.nextTraceMask();

    // Comparison decomposition (7)
    var cmp_cols: [7]BaseExpr = undefined;
    for (&cmp_cols) |*col| col.* = try eval.nextTraceMask();

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
    const flags = [_]BaseExpr{ is_slti, is_sltiu };
    for (flags) |flag| {
        try eval.addConstraint(try arena.extBase(
            try arena.baseSub(try arena.baseMul(flag, flag), flag),
        ));
    }

    // imm_sign is boolean
    try eval.addConstraint(try arena.extBase(
        try arena.baseSub(try arena.baseMul(imm_sign, imm_sign), imm_sign),
    ));

    // enabler = sum of flags
    const flag_sum = try arena.baseAdd(is_slti, is_sltiu);
    try eval.addConstraint(try arena.extBase(try arena.baseSub(enabler, flag_sum)));

    // enabler * (enabler - 1) = 0
    try eval.addConstraint(try arena.extBase(try arena.baseMul(enabler, try arena.baseSub(enabler, one))));

    try eval.finalizeLogupInPairs();
}

test "lt_imm: constraint count" {
    var arena = cf.ExprArena.init(std.testing.allocator);
    defer arena.deinit();
    var eval = try ExprEvaluator.init(&arena, std.testing.allocator);
    defer eval.deinit();

    try evaluate(&eval);
    try std.testing.expect(eval.constraints.items.len > 0);
}
