//! AIR component for the MULH family.
//!
//! Instructions: MULH, MULHSU, MULHU (3 ops).
//!
//! Trace layout (18 columns):
//!   clk, pc, rd, rs1, rs2, rd_val, rs1_val, rs2_val, result,
//!   is_mulh, is_mulhsu, is_mulhu, enabler, prod_lo, prod_hi,
//!   rs1_sign, rs2_sign, instruction_word.
//!
//! Constraints:
//!   - Flags boolean, enabler = sum, enabler in {0,1}.
//!   - rs1_sign, rs2_sign boolean (sign bits of operands).
//!   - MULHU ignores sign bits; MULHSU uses rs1_sign; MULH uses both.
//!   - Full 64-bit product decomposed into prod_lo (low 32) + prod_hi (high 32).
//!   - result = prod_hi (MULH* returns upper 32 bits).

const std = @import("std");
const cf = @import("../../../../core/constraint_framework/mod.zig");
const claims_mod = @import("../claims.zig");
const trace = @import("../trace_columns.zig");
const M31 = @import("../../../../core/fields/m31.zig").M31;

const ExprEvaluator = cf.ExprEvaluator;
const ExprArena = cf.ExprArena;
const BaseExpr = cf.BaseExpr;
const ExtExpr = cf.ExtExpr;

pub const Columns = trace.MulhColumns;
pub const N_TRACE_COLUMNS: usize = Columns.N_COLUMNS;
pub const Claim = claims_mod.ComponentClaim;
pub const InteractionClaim = claims_mod.ComponentInteractionClaim;

/// Evaluate the mulh AIR constraints.
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
    const is_mulh = try eval.nextTraceMask();
    const is_mulhsu = try eval.nextTraceMask();
    const is_mulhu = try eval.nextTraceMask();
    const enabler = try eval.nextTraceMask();
    const prod_lo = try eval.nextTraceMask();
    const prod_hi = try eval.nextTraceMask();
    const rs1_sign = try eval.nextTraceMask();
    const rs2_sign = try eval.nextTraceMask();
    const instruction_word = try eval.nextTraceMask();

    const one = try arena.baseOne();
    const shift_16 = try arena.baseConst(M31.fromCanonical(1 << 16));
    const four = try arena.baseConst(M31.fromCanonical(4));

    // ---- Flag boolean constraints ----
    const flags = [_]BaseExpr{ is_mulh, is_mulhsu, is_mulhu, rs1_sign, rs2_sign };
    for (flags) |flag| {
        try eval.addConstraint(try arena.extBase(
            try arena.baseSub(try arena.baseMul(flag, flag), flag),
        ));
    }

    // enabler = sum of instruction flags
    var flag_sum = is_mulh;
    flag_sum = try arena.baseAdd(flag_sum, is_mulhsu);
    flag_sum = try arena.baseAdd(flag_sum, is_mulhu);
    try eval.addConstraint(try arena.extBase(try arena.baseSub(enabler, flag_sum)));

    // enabler * (enabler - 1) = 0
    try eval.addConstraint(try arena.extBase(try arena.baseMul(enabler, try arena.baseSub(enabler, one))));

    // ---- Sign bit constraints ----
    // MULHU: both operands treated as unsigned -> sign bits must be 0.
    // is_mulhu * rs1_sign = 0
    try eval.addConstraint(try arena.extBase(try arena.baseMul(is_mulhu, rs1_sign)));
    // is_mulhu * rs2_sign = 0
    try eval.addConstraint(try arena.extBase(try arena.baseMul(is_mulhu, rs2_sign)));
    // MULHSU: rs2 treated as unsigned -> rs2_sign must be 0.
    try eval.addConstraint(try arena.extBase(try arena.baseMul(is_mulhsu, rs2_sign)));

    // ---- Product constraint ----
    // Full product: rs1_val * rs2_val = prod_lo + prod_hi * 2^32
    const product = try arena.baseMul(rs1_val, rs2_val);
    const shift_32 = try arena.baseMul(shift_16, shift_16);
    const full_prod = try arena.baseAdd(prod_lo, try arena.baseMul(prod_hi, shift_32));
    try eval.addConstraint(try arena.extBase(
        try arena.baseMul(enabler, try arena.baseSub(product, full_prod)),
    ));

    // result = prod_hi (upper 32 bits)
    try eval.addConstraint(try arena.extBase(
        try arena.baseMul(enabler, try arena.baseSub(result, prod_hi)),
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

    // Range check M31 for overflow
    try eval.writeLogupFrac(.{
        .numerator = try arena.extFromBase(enabler),
        .denominator = try arena.extSub(z, try arena.extFromBase(prod_lo)),
    });
    try eval.writeLogupFrac(.{
        .numerator = try arena.extFromBase(enabler),
        .denominator = try arena.extSub(z, try arena.extFromBase(prod_hi)),
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

test "mulh: constraint count" {
    var arena = cf.ExprArena.init(std.testing.allocator);
    defer arena.deinit();
    var eval = try ExprEvaluator.init(&arena, std.testing.allocator);
    defer eval.deinit();

    try evaluate(&eval);
    try std.testing.expect(eval.constraints.items.len > 0);
}
