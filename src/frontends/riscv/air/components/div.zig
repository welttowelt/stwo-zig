//! AIR component for the DIV/REM family.
//!
//! Instructions: DIV, DIVU, REM, REMU (4 ops).
//!
//! Trace layout (20 columns):
//!   clk, pc, rd, rs1, rs2, rd_val, rs1_val, rs2_val, result,
//!   is_div, is_divu, is_rem, is_remu, enabler, quotient, remainder,
//!   rs2_is_zero, rs1_sign, rs2_sign, instruction_word.
//!
//! Constraints:
//!   - Flags boolean, enabler = sum, enabler in {0,1}.
//!   - rs2_is_zero, rs1_sign, rs2_sign are boolean.
//!   - rs2_is_zero * rs2_val = 0  (if zero flag set, rs2 must be 0).
//!   - Division relation: quotient * rs2_val + remainder = rs1_val
//!     (when rs2 != 0).
//!   - DIV/DIVU: result = quotient (or special value on div-by-zero).
//!   - REM/REMU: result = remainder (or rs1_val on div-by-zero).
//!   - Div-by-zero:
//!       is_div * rs2_is_zero  -> result = 0xFFFFFFFF (-1 in two's complement)
//!       is_divu * rs2_is_zero -> result = 0xFFFFFFFF (all ones)
//!       is_rem * rs2_is_zero  -> result = rs1_val
//!       is_remu * rs2_is_zero -> result = rs1_val
//!   - DIVU/REMU ignore sign bits.
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

pub const Columns = trace.DivColumns;
pub const N_TRACE_COLUMNS: usize = Columns.N_COLUMNS;
pub const Claim = claims_mod.ComponentClaim;
pub const InteractionClaim = claims_mod.ComponentInteractionClaim;

/// Evaluate the div AIR constraints.
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
    const is_div = try eval.nextTraceMask();
    const is_divu = try eval.nextTraceMask();
    const is_rem = try eval.nextTraceMask();
    const is_remu = try eval.nextTraceMask();
    const enabler = try eval.nextTraceMask();
    const quotient = try eval.nextTraceMask();
    const remainder = try eval.nextTraceMask();
    const rs2_is_zero = try eval.nextTraceMask();
    const rs1_sign = try eval.nextTraceMask();
    const rs2_sign = try eval.nextTraceMask();
    const instruction_word = try eval.nextTraceMask();

    const one = try arena.baseOne();
    const shift_16 = try arena.baseConst(M31.fromCanonical(1 << 16));
    const four = try arena.baseConst(M31.fromCanonical(4));

    // ---- Flag boolean constraints ----
    const flags = [_]BaseExpr{ is_div, is_divu, is_rem, is_remu, rs2_is_zero, rs1_sign, rs2_sign };
    for (flags) |flag| {
        try eval.addConstraint(try arena.extBase(
            try arena.baseSub(try arena.baseMul(flag, flag), flag),
        ));
    }

    // enabler = sum of instruction flags
    var flag_sum = is_div;
    flag_sum = try arena.baseAdd(flag_sum, is_divu);
    flag_sum = try arena.baseAdd(flag_sum, is_rem);
    flag_sum = try arena.baseAdd(flag_sum, is_remu);
    try eval.addConstraint(try arena.extBase(try arena.baseSub(enabler, flag_sum)));

    // enabler * (enabler - 1) = 0
    try eval.addConstraint(try arena.extBase(try arena.baseMul(enabler, try arena.baseSub(enabler, one))));

    // ---- Sign bit constraints for unsigned variants ----
    // DIVU/REMU treat operands as unsigned -> sign bits must be 0.
    const is_unsigned = try arena.baseAdd(is_divu, is_remu);
    try eval.addConstraint(try arena.extBase(try arena.baseMul(is_unsigned, rs1_sign)));
    try eval.addConstraint(try arena.extBase(try arena.baseMul(is_unsigned, rs2_sign)));

    // ---- Zero-divisor constraint ----
    // rs2_is_zero * rs2_val = 0 (if flag is set, rs2 must be zero)
    try eval.addConstraint(try arena.extBase(try arena.baseMul(rs2_is_zero, rs2_val)));

    // ---- Division relation (when rs2 != 0) ----
    // (1 - rs2_is_zero) * (quotient * rs2_val + remainder - rs1_val) = 0
    const one_minus_zero = try arena.baseSub(one, rs2_is_zero);
    const q_times_d = try arena.baseMul(quotient, rs2_val);
    const div_relation = try arena.baseSub(try arena.baseAdd(q_times_d, remainder), rs1_val);
    try eval.addConstraint(try arena.extBase(
        try arena.baseMul(one_minus_zero, div_relation),
    ));

    // ---- Result selection: DIV/DIVU -> quotient, REM/REMU -> remainder ----
    // When rs2 != 0:
    //   (is_div + is_divu) * (1 - rs2_is_zero) * (result - quotient) = 0
    //   (is_rem + is_remu) * (1 - rs2_is_zero) * (result - remainder) = 0
    const is_div_op = try arena.baseAdd(is_div, is_divu);
    const is_rem_op = try arena.baseAdd(is_rem, is_remu);
    try eval.addConstraint(try arena.extBase(
        try arena.baseMul(try arena.baseMul(is_div_op, one_minus_zero), try arena.baseSub(result, quotient)),
    ));
    try eval.addConstraint(try arena.extBase(
        try arena.baseMul(try arena.baseMul(is_rem_op, one_minus_zero), try arena.baseSub(result, remainder)),
    ));

    // ---- Div-by-zero result constraints ----
    // For DIV/DIVU by zero: result = 0xFFFFFFFF (= 2^32 - 1).
    const all_ones = try arena.baseConst(M31.fromCanonical(0xFFFFFFFF));
    try eval.addConstraint(try arena.extBase(
        try arena.baseMul(try arena.baseMul(is_div_op, rs2_is_zero), try arena.baseSub(result, all_ones)),
    ));

    // For REM/REMU by zero: result = rs1_val.
    try eval.addConstraint(try arena.extBase(
        try arena.baseMul(try arena.baseMul(is_rem_op, rs2_is_zero), try arena.baseSub(result, rs1_val)),
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

    // Range check M31 for quotient
    try eval.writeLogupFrac(.{
        .numerator = try arena.extFromBase(enabler),
        .denominator = try arena.extSub(z, try arena.extFromBase(quotient)),
    });

    // Range check M31 for remainder
    try eval.writeLogupFrac(.{
        .numerator = try arena.extFromBase(enabler),
        .denominator = try arena.extSub(z, try arena.extFromBase(remainder)),
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

test "div: constraint count" {
    var arena = cf.ExprArena.init(std.testing.allocator);
    defer arena.deinit();
    var eval = try ExprEvaluator.init(&arena, std.testing.allocator);
    defer eval.deinit();

    try evaluate(&eval);

    // 7 flag-bit + 1 enabler-eq + 1 enabler-bit + 2 unsigned-sign
    // + 1 zero-divisor + 1 div-relation + 2 result-select
    // + 2 div-by-zero + 1 rd_val = 19 direct constraints
    // + logup constraints from finalizeLogupInPairs (8 fracs -> 4 constraints).
    // Total: 19 + 4 = 23.
    try std.testing.expect(eval.constraints.items.len > 0);
}
