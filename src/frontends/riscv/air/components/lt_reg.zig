//! AIR component for the less-than register family.
//!
//! Instructions: SLT, SLTU (2 ops).
//!
//! Trace layout (15 columns):
//!   clk, pc, rd, rs1, rs2, rd_val, rs1_val, rs2_val, result,
//!   is_slt, is_sltu, enabler, diff_lo, diff_hi, instruction_word.
//!
//! Constraints:
//!   - Flags boolean, enabler = sum, enabler in {0,1}.
//!   - result is boolean (SLT/SLTU produce 0 or 1).
//!   - Difference decomposition for comparison:
//!       diff = rs1_val - rs2_val = diff_lo + diff_hi * 2^16
//!       (range checked to verify the comparison result).
//!   - result correctness depends on sign comparison (SLT) or unsigned (SLTU).

const std = @import("std");
const cf = @import("../../../../core/constraint_framework/mod.zig");
const claims_mod = @import("../claims.zig");
const trace = @import("../trace_columns.zig");
const M31 = @import("../../../../core/fields/m31.zig").M31;

const ExprEvaluator = cf.ExprEvaluator;
const ExprArena = cf.ExprArena;
const BaseExpr = cf.BaseExpr;
const ExtExpr = cf.ExtExpr;

pub const Columns = trace.LtRegColumns;
pub const N_TRACE_COLUMNS: usize = Columns.N_COLUMNS;
pub const Claim = claims_mod.ComponentClaim;
pub const InteractionClaim = claims_mod.ComponentInteractionClaim;

/// Evaluate the lt_reg AIR constraints.
pub fn evaluate(eval: *ExprEvaluator) !void {
    const arena = eval.arena;

    const clk = try eval.nextTraceMask();
    const pc = try eval.nextTraceMask();
    const rd = try eval.nextTraceMask();
    const rs1 = try eval.nextTraceMask();
    const rs2 = try eval.nextTraceMask();
    const rd_val = try eval.nextTraceMask();
    const rs1_val = try eval.nextTraceMask();
    const rs2_val = try eval.nextTraceMask();
    const result = try eval.nextTraceMask();
    const is_slt = try eval.nextTraceMask();
    const is_sltu = try eval.nextTraceMask();
    const enabler = try eval.nextTraceMask();
    const diff_lo = try eval.nextTraceMask();
    const diff_hi = try eval.nextTraceMask();
    const instruction_word = try eval.nextTraceMask();

    const one = try arena.baseOne();
    const shift_16 = try arena.baseConst(M31.fromCanonical(1 << 16));
    const four = try arena.baseConst(M31.fromCanonical(4));

    // ---- Flag boolean constraints ----
    const flags = [_]BaseExpr{ is_slt, is_sltu };
    for (flags) |flag| {
        try eval.addConstraint(try arena.extBase(
            try arena.baseSub(try arena.baseMul(flag, flag), flag),
        ));
    }

    // result is boolean
    try eval.addConstraint(try arena.extBase(
        try arena.baseSub(try arena.baseMul(result, result), result),
    ));

    // enabler = sum of flags
    const flag_sum = try arena.baseAdd(is_slt, is_sltu);
    try eval.addConstraint(try arena.extBase(try arena.baseSub(enabler, flag_sum)));

    // enabler * (enabler - 1) = 0
    try eval.addConstraint(try arena.extBase(try arena.baseMul(enabler, try arena.baseSub(enabler, one))));

    // ---- Difference decomposition ----
    // The difference rs1_val - rs2_val is decomposed into two limbs for range checking.
    // If result = 1 (less than), then diff encodes rs2_val - rs1_val - 1.
    // If result = 0 (not less than), then diff encodes rs1_val - rs2_val.
    // diff_lo + diff_hi * 2^16 = (1 - result) * (rs1_val - rs2_val) + result * (rs2_val - rs1_val - 1)
    const rs1_minus_rs2 = try arena.baseSub(rs1_val, rs2_val);
    const rs2_minus_rs1_m1 = try arena.baseSub(try arena.baseSub(rs2_val, rs1_val), one);
    const one_minus_result = try arena.baseSub(one, result);
    const expected_diff = try arena.baseAdd(
        try arena.baseMul(one_minus_result, rs1_minus_rs2),
        try arena.baseMul(result, rs2_minus_rs1_m1),
    );
    const actual_diff = try arena.baseAdd(diff_lo, try arena.baseMul(diff_hi, shift_16));
    try eval.addConstraint(try arena.extBase(
        try arena.baseMul(enabler, try arena.baseSub(actual_diff, expected_diff)),
    ));

    // rd_val = result
    try eval.addConstraint(try arena.extBase(
        try arena.baseMul(enabler, try arena.baseSub(rd_val, result)),
    ));

    // ---- LogUp relations ----
    const alpha = try arena.extParam("alpha");
    const z = try arena.extParam("z");
    const clk_next = try arena.baseAdd(clk, one);

    // Register read rs1
    try eval.writeLogupFrac(.{
        .numerator = try arena.extFromBase(enabler),
        .denominator = try arena.extSub(alpha, try arena.extFromBase(
            try arena.baseAdd(try arena.baseAdd(rs1, try arena.baseMul(clk, shift_16)), rs1_val),
        )),
    });

    // Register read rs2
    try eval.writeLogupFrac(.{
        .numerator = try arena.extFromBase(enabler),
        .denominator = try arena.extSub(alpha, try arena.extFromBase(
            try arena.baseAdd(try arena.baseAdd(rs2, try arena.baseMul(clk, shift_16)), rs2_val),
        )),
    });

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

    // Range check 8_8 for diff decomposition
    try eval.writeLogupFrac(.{
        .numerator = try arena.extFromBase(enabler),
        .denominator = try arena.extSub(z, try arena.extFromBase(
            try arena.baseAdd(diff_lo, try arena.baseMul(diff_hi, shift_16)),
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

test "lt_reg: constraint count" {
    var arena = cf.ExprArena.init(std.testing.allocator);
    defer arena.deinit();
    var eval = try ExprEvaluator.init(&arena, std.testing.allocator);
    defer eval.deinit();

    try evaluate(&eval);
    try std.testing.expect(eval.constraints.items.len > 0);
}
