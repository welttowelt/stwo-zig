//! AIR component for the Load/Store family.
//!
//! Instructions: LB, LBU, LH, LHU, LW, SB, SH, SW (8 ops).
//!
//! Trace layout (50 columns):
//!   clk, pc, imm, is_lb, is_lbu, is_lh, is_lhu, is_lw, is_sb, is_sh, is_sw,
//!   enabler, byte_0, byte_1, byte_2, byte_3, mem_addr, mem_val, rs2_val,
//!   sign_extend, rd_access(10), rs1_access(10), mem_access(10).
//!
//! Constraints:
//!   - Each flag is boolean, enabler = sum, enabler in {0,1}.

const std = @import("std");
const cf = @import("../../../../core/constraint_framework/mod.zig");
const claims_mod = @import("../claims.zig");
const trace = @import("../trace_columns.zig");
const M31 = @import("../../../../core/fields/m31.zig").M31;

const ExprEvaluator = cf.ExprEvaluator;
const ExprArena = cf.ExprArena;
const BaseExpr = cf.BaseExpr;
const ExtExpr = cf.ExtExpr;

pub const Columns = trace.LoadStoreColumns;
pub const N_TRACE_COLUMNS: usize = Columns.N_COLUMNS;
pub const Claim = claims_mod.ComponentClaim;
pub const InteractionClaim = claims_mod.ComponentInteractionClaim;

/// Evaluate the load_store AIR constraints.
pub fn evaluate(eval: *ExprEvaluator) !void {
    const arena = eval.arena;

    // Common/flags (20)
    const _clk = try eval.nextTraceMask();
    const _pc = try eval.nextTraceMask();
    const _imm = try eval.nextTraceMask();
    const is_lb = try eval.nextTraceMask();
    const is_lbu = try eval.nextTraceMask();
    const is_lh = try eval.nextTraceMask();
    const is_lhu = try eval.nextTraceMask();
    const is_lw = try eval.nextTraceMask();
    const is_sb = try eval.nextTraceMask();
    const is_sh = try eval.nextTraceMask();
    const is_sw = try eval.nextTraceMask();
    const enabler = try eval.nextTraceMask();
    const _byte_0 = try eval.nextTraceMask();
    const _byte_1 = try eval.nextTraceMask();
    const _byte_2 = try eval.nextTraceMask();
    const _byte_3 = try eval.nextTraceMask();
    const _mem_addr = try eval.nextTraceMask();
    const _mem_val = try eval.nextTraceMask();
    const _rs2_val = try eval.nextTraceMask();
    const _sign_extend = try eval.nextTraceMask();

    // rd access (10)
    var rd_cols: [10]BaseExpr = undefined;
    for (&rd_cols) |*col| col.* = try eval.nextTraceMask();

    // rs1 access (10)
    var rs1_cols: [10]BaseExpr = undefined;
    for (&rs1_cols) |*col| col.* = try eval.nextTraceMask();

    // memory access (10)
    var mem_cols: [10]BaseExpr = undefined;
    for (&mem_cols) |*col| col.* = try eval.nextTraceMask();

    _ = _clk;
    _ = _pc;
    _ = _imm;
    _ = _byte_0;
    _ = _byte_1;
    _ = _byte_2;
    _ = _byte_3;
    _ = _mem_addr;
    _ = _mem_val;
    _ = _rs2_val;
    _ = _sign_extend;

    const one = try arena.baseOne();

    // ---- Flag boolean constraints ----
    const flags = [_]BaseExpr{ is_lb, is_lbu, is_lh, is_lhu, is_lw, is_sb, is_sh, is_sw };
    for (flags) |flag| {
        try eval.addConstraint(try arena.extBase(
            try arena.baseSub(try arena.baseMul(flag, flag), flag),
        ));
    }

    // enabler = sum of all flags
    var flag_sum = is_lb;
    flag_sum = try arena.baseAdd(flag_sum, is_lbu);
    flag_sum = try arena.baseAdd(flag_sum, is_lh);
    flag_sum = try arena.baseAdd(flag_sum, is_lhu);
    flag_sum = try arena.baseAdd(flag_sum, is_lw);
    flag_sum = try arena.baseAdd(flag_sum, is_sb);
    flag_sum = try arena.baseAdd(flag_sum, is_sh);
    flag_sum = try arena.baseAdd(flag_sum, is_sw);
    try eval.addConstraint(try arena.extBase(try arena.baseSub(enabler, flag_sum)));

    // enabler * (enabler - 1) = 0
    try eval.addConstraint(try arena.extBase(try arena.baseMul(enabler, try arena.baseSub(enabler, one))));

    try eval.finalizeLogupInPairs();
}

test "load_store: constraint count" {
    var arena = cf.ExprArena.init(std.testing.allocator);
    defer arena.deinit();
    var eval = try ExprEvaluator.init(&arena, std.testing.allocator);
    defer eval.deinit();

    try evaluate(&eval);
    try std.testing.expect(eval.constraints.items.len > 0);
}
