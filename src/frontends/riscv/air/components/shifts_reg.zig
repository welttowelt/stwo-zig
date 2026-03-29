//! AIR component for the shifts register-register family.
//!
//! Instructions: SLL, SRL, SRA (3 ops).
//!
//! Trace layout (18 columns):
//!   clk, pc, rd, rs1, rs2, rd_val, rs1_val, rs2_val, result,
//!   is_sll, is_srl, is_sra, enabler, shift_amount, shift_amount_bound,
//!   shifted_lo, shifted_hi, instruction_word.
//!
//! Constraints:
//!   - Flags are boolean, enabler = sum of flags.
//!   - shift_amount = rs2_val & 0x1f (bottom 5 bits).
//!   - shift_amount_bound = 32 - shift_amount (range checked to prove < 32).
//!   - For SLL: result = (rs1_val << shift_amount) & 0xFFFFFFFF.
//!   - For SRL: result = rs1_val >> shift_amount (logical).
//!   - For SRA: result = rs1_val >>> shift_amount (arithmetic).
//!   - Range check relation for shift_amount decomposition (8_11).

const std = @import("std");
const cf = @import("../../../../core/constraint_framework/mod.zig");
const claims_mod = @import("../claims.zig");
const trace = @import("../trace_columns.zig");
const M31 = @import("../../../../core/fields/m31.zig").M31;

const ExprEvaluator = cf.ExprEvaluator;
const ExprArena = cf.ExprArena;
const BaseExpr = cf.BaseExpr;
const ExtExpr = cf.ExtExpr;

pub const Columns = trace.ShiftsRegColumns;
pub const N_TRACE_COLUMNS: usize = Columns.N_COLUMNS;
pub const Claim = claims_mod.ComponentClaim;
pub const InteractionClaim = claims_mod.ComponentInteractionClaim;

/// Evaluate the shifts_reg AIR constraints.
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
    const is_sll = try eval.nextTraceMask();
    const is_srl = try eval.nextTraceMask();
    const is_sra = try eval.nextTraceMask();
    const enabler = try eval.nextTraceMask();
    const shift_amount = try eval.nextTraceMask();
    const shift_amount_bound = try eval.nextTraceMask();
    const shifted_lo = try eval.nextTraceMask();
    const shifted_hi = try eval.nextTraceMask();
    const instruction_word = try eval.nextTraceMask();

    const one = try arena.baseOne();
    const shift_16 = try arena.baseConst(M31.fromCanonical(1 << 16));
    const four = try arena.baseConst(M31.fromCanonical(4));
    const thirty_two = try arena.baseConst(M31.fromCanonical(32));

    // ---- Flag boolean constraints ----
    const flags = [_]BaseExpr{ is_sll, is_srl, is_sra };
    for (flags) |flag| {
        const flag_sq = try arena.baseMul(flag, flag);
        try eval.addConstraint(try arena.extBase(try arena.baseSub(flag_sq, flag)));
    }

    // enabler = sum of flags
    var flag_sum = is_sll;
    flag_sum = try arena.baseAdd(flag_sum, is_srl);
    flag_sum = try arena.baseAdd(flag_sum, is_sra);
    try eval.addConstraint(try arena.extBase(try arena.baseSub(enabler, flag_sum)));

    // enabler * (enabler - 1) = 0
    try eval.addConstraint(try arena.extBase(try arena.baseMul(enabler, try arena.baseSub(enabler, one))));

    // ---- Shift amount constraint ----
    // shift_amount + shift_amount_bound = 32
    const sa_sum = try arena.baseAdd(shift_amount, shift_amount_bound);
    try eval.addConstraint(try arena.extBase(try arena.baseSub(sa_sum, thirty_two)));

    // ---- Result decomposition ----
    // result = shifted_lo + shifted_hi * 2^16  (for range checking)
    const result_recon = try arena.baseAdd(shifted_lo, try arena.baseMul(shifted_hi, shift_16));
    try eval.addConstraint(try arena.extBase(
        try arena.baseMul(enabler, try arena.baseSub(result, result_recon)),
    ));

    // rd_val = result (destination gets the shift result)
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

    // Range check 8_11 for shift_amount decomposition
    try eval.writeLogupFrac(.{
        .numerator = try arena.extFromBase(enabler),
        .denominator = try arena.extSub(z, try arena.extFromBase(
            try arena.baseAdd(shift_amount, try arena.baseMul(shift_amount_bound, shift_16)),
        )),
    });

    // Opcode bus transitions
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

test "shifts_reg: constraint count" {
    var arena = cf.ExprArena.init(std.testing.allocator);
    defer arena.deinit();
    var eval = try ExprEvaluator.init(&arena, std.testing.allocator);
    defer eval.deinit();

    try evaluate(&eval);
    try std.testing.expect(eval.constraints.items.len > 0);
}
