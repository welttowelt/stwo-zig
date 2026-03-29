//! AIR component for the LUI (Load Upper Immediate) instruction.
//!
//! Instructions: LUI (1 op).
//!
//! Trace layout (10 columns):
//!   clk, pc, rd, rd_val, imm_u, result, enabler,
//!   result_lo, result_hi, instruction_word.
//!
//! Constraints:
//!   - enabler is boolean (single instruction, no flags needed).
//!   - result = imm_u << 12 (upper 20 bits set, lower 12 zero).
//!   - result = result_lo + result_hi * 2^16 (range check decomposition).
//!   - rd_val = result.

const std = @import("std");
const cf = @import("../../../../core/constraint_framework/mod.zig");
const claims_mod = @import("../claims.zig");
const trace = @import("../trace_columns.zig");
const M31 = @import("../../../../core/fields/m31.zig").M31;

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

    const clk = try eval.nextTraceMask();
    const pc = try eval.nextTraceMask();
    const rd = try eval.nextTraceMask();
    const rd_val = try eval.nextTraceMask();
    const imm_u = try eval.nextTraceMask();
    const result = try eval.nextTraceMask();
    const enabler = try eval.nextTraceMask();
    const result_lo = try eval.nextTraceMask();
    const result_hi = try eval.nextTraceMask();
    const instruction_word = try eval.nextTraceMask();

    const one = try arena.baseOne();
    const shift_12 = try arena.baseConst(M31.fromCanonical(1 << 12));
    const shift_16 = try arena.baseConst(M31.fromCanonical(1 << 16));
    const four = try arena.baseConst(M31.fromCanonical(4));

    // enabler is boolean
    try eval.addConstraint(try arena.extBase(
        try arena.baseSub(try arena.baseMul(enabler, enabler), enabler),
    ));

    // result = imm_u << 12
    const expected_result = try arena.baseMul(imm_u, shift_12);
    try eval.addConstraint(try arena.extBase(
        try arena.baseMul(enabler, try arena.baseSub(result, expected_result)),
    ));

    // result = result_lo + result_hi * 2^16
    const result_recon = try arena.baseAdd(result_lo, try arena.baseMul(result_hi, shift_16));
    try eval.addConstraint(try arena.extBase(
        try arena.baseMul(enabler, try arena.baseSub(result, result_recon)),
    ));

    // rd_val = result
    try eval.addConstraint(try arena.extBase(
        try arena.baseMul(enabler, try arena.baseSub(rd_val, result)),
    ));

    // ---- LogUp relations ----
    const alpha = try arena.extParam("alpha");
    const z = try arena.extParam("z");
    const clk_next = try arena.baseAdd(clk, one);

    // Register write rd
    try eval.writeLogupFrac(.{
        .numerator = try arena.extNeg(try arena.extFromBase(enabler)),
        .denominator = try arena.extSub(alpha, try arena.extFromBase(
            try arena.baseAdd(try arena.baseAdd(rd, try arena.baseMul(clk_next, shift_16)), result),
        )),
    });

    // Program lookup
    try eval.writeLogupFrac(.{
        .numerator = try arena.extFromBase(enabler),
        .denominator = try arena.extSub(z, try arena.extFromBase(
            try arena.baseAdd(pc, try arena.baseMul(instruction_word, shift_16)),
        )),
    });

    // Range check 8_8 for result decomposition
    try eval.writeLogupFrac(.{
        .numerator = try arena.extFromBase(enabler),
        .denominator = try arena.extSub(z, try arena.extFromBase(
            try arena.baseAdd(result_lo, try arena.baseMul(result_hi, shift_16)),
        )),
    });

    // Opcode bus
    const pc_next = try arena.baseAdd(pc, four);
    try eval.writeLogupFrac(.{
        .numerator = try arena.extFromBase(enabler),
        .denominator = try arena.extSub(alpha, try arena.extFromBase(try arena.baseAdd(pc, clk))),
    });
    try eval.writeLogupFrac(.{
        .numerator = try arena.extNeg(try arena.extFromBase(enabler)),
        .denominator = try arena.extSub(alpha, try arena.extFromBase(try arena.baseAdd(pc_next, clk_next))),
    });

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
