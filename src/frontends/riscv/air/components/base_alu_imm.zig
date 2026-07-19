//! AIR component for the base ALU immediate family.
//!
//! Instructions: ADDI, XORI, ORI, ANDI (4 ops).
//!
//! Trace layout (29 columns):
//!   clk, pc, is_addi, is_xori, is_ori, is_andi, imm, imm_sign, enabler,
//!   rd_access(10), rs1_access(10).
//!
//! Constraints:
//!   - Each flag is boolean.
//!   - enabler = sum of flags, enabler in {0,1}.
//!   - imm_sign is boolean (sign extension bit).

const std = @import("std");
const cf = @import("stwo_core").constraint_framework;
const claims_mod = @import("../claims.zig");
const trace = @import("../trace_columns.zig");
const M31 = @import("stwo_core").fields.m31.M31;

const ExprEvaluator = cf.ExprEvaluator;
const ExprArena = cf.ExprArena;
const BaseExpr = cf.BaseExpr;
const ExtExpr = cf.ExtExpr;

pub const Columns = trace.BaseAluImmColumns;
pub const N_TRACE_COLUMNS: usize = Columns.N_COLUMNS;
pub const Claim = claims_mod.ComponentClaim;
pub const InteractionClaim = claims_mod.ComponentInteractionClaim;

/// Evaluate the base_alu_imm AIR constraints.
pub fn evaluate(eval: *ExprEvaluator) !void {
    const arena = eval.arena;

    // Read all 29 trace columns.
    // Common (9)
    const _clk = try eval.nextTraceMask();
    const _pc = try eval.nextTraceMask();
    const is_addi = try eval.nextTraceMask();
    const is_xori = try eval.nextTraceMask();
    const is_ori = try eval.nextTraceMask();
    const is_andi = try eval.nextTraceMask();
    const _imm = try eval.nextTraceMask();
    const imm_sign = try eval.nextTraceMask();
    const enabler = try eval.nextTraceMask();

    // rd access (10)
    var rd_cols: [10]BaseExpr = undefined;
    for (&rd_cols) |*col| col.* = try eval.nextTraceMask();

    // rs1 access (10)
    var rs1_cols: [10]BaseExpr = undefined;
    for (&rs1_cols) |*col| col.* = try eval.nextTraceMask();

    _ = _clk;
    _ = _pc;
    _ = _imm;

    // ---- Flag boolean constraints ----
    const flags = [_]BaseExpr{ is_addi, is_xori, is_ori, is_andi };
    for (flags) |flag| {
        const flag_sq = try arena.baseMul(flag, flag);
        try eval.addConstraint(try arena.extBase(try arena.baseSub(flag_sq, flag)));
    }

    // imm_sign is boolean
    const sign_sq = try arena.baseMul(imm_sign, imm_sign);
    try eval.addConstraint(try arena.extBase(try arena.baseSub(sign_sq, imm_sign)));

    // ---- Enabler = sum of flags ----
    var flag_sum = is_addi;
    flag_sum = try arena.baseAdd(flag_sum, is_xori);
    flag_sum = try arena.baseAdd(flag_sum, is_ori);
    flag_sum = try arena.baseAdd(flag_sum, is_andi);
    try eval.addConstraint(try arena.extBase(try arena.baseSub(enabler, flag_sum)));

    // enabler * (enabler - 1) = 0
    const one = try arena.baseOne();
    const enabler_m1 = try arena.baseSub(enabler, one);
    try eval.addConstraint(try arena.extBase(try arena.baseMul(enabler, enabler_m1)));

    try eval.finalizeLogupInPairs();
}

test "base_alu_imm: constraint count" {
    var arena = cf.ExprArena.init(std.testing.allocator);
    defer arena.deinit();
    var eval = try ExprEvaluator.init(&arena, std.testing.allocator);
    defer eval.deinit();

    try evaluate(&eval);

    try std.testing.expect(eval.constraints.items.len > 0);
}
