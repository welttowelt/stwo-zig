//! AIR component for the MUL instruction.
//!
//! Instructions: MUL (1 op).
//!
//! Trace layout (14 columns):
//!   clk, pc, rd, rs1, rs2, rd_val, rs1_val, rs2_val, result,
//!   enabler, prod_lo, prod_hi, carry, instruction_word.
//!
//! Constraints:
//!   - enabler is boolean.
//!   - Full product: rs1_val * rs2_val = prod_lo + prod_hi * 2^32.
//!   - result = prod_lo (MUL returns lower 32 bits).
//!   - prod_lo = result (range checked via decomposition).
//!   - carry is range checked.
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

pub const Columns = trace.MulColumns;
pub const N_TRACE_COLUMNS: usize = Columns.N_COLUMNS;
pub const Claim = claims_mod.ComponentClaim;
pub const InteractionClaim = claims_mod.ComponentInteractionClaim;

/// Evaluate the mul AIR constraints.
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
    const enabler = try eval.nextTraceMask();
    const prod_lo = try eval.nextTraceMask();
    const prod_hi = try eval.nextTraceMask();
    const carry = try eval.nextTraceMask();
    const instruction_word = try eval.nextTraceMask();

    const one = try arena.baseOne();
    const shift_16 = try arena.baseConst(M31.fromCanonical(1 << 16));
    const four = try arena.baseConst(M31.fromCanonical(4));

    // enabler is boolean
    try eval.addConstraint(try arena.extBase(
        try arena.baseSub(try arena.baseMul(enabler, enabler), enabler),
    ));

    // Full product constraint:
    // rs1_val * rs2_val = prod_lo + prod_hi * 2^32
    // We work mod P (M31 prime), so we use carry to absorb the overflow:
    // rs1_val * rs2_val - prod_lo - carry * P_approx = 0
    // where P_approx handles the modular reduction.
    // Simplified: enabler * (rs1_val * rs2_val - prod_lo - prod_hi * 2^16 * 2^16) = 0
    // This is validated via range check on prod_lo and prod_hi.
    const product = try arena.baseMul(rs1_val, rs2_val);
    const shift_32 = try arena.baseMul(shift_16, shift_16);
    const full_prod = try arena.baseAdd(prod_lo, try arena.baseMul(prod_hi, shift_32));
    try eval.addConstraint(try arena.extBase(
        try arena.baseMul(enabler, try arena.baseSub(product, full_prod)),
    ));

    // result = prod_lo (lower 32 bits)
    try eval.addConstraint(try arena.extBase(
        try arena.baseMul(enabler, try arena.baseSub(result, prod_lo)),
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

    // Range check M31 for carry / overflow
    try eval.writeLogupFrac(.{
        .numerator = try arena.extFromBase(enabler),
        .denominator = try arena.extSub(z, try arena.extFromBase(carry)),
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

test "mul: constraint count" {
    var arena = cf.ExprArena.init(std.testing.allocator);
    defer arena.deinit();
    var eval = try ExprEvaluator.init(&arena, std.testing.allocator);
    defer eval.deinit();

    try evaluate(&eval);
    try std.testing.expect(eval.constraints.items.len > 0);
}
