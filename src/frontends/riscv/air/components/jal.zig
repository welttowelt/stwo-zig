//! AIR component for the JAL (Jump And Link) instruction.
//!
//! Instructions: JAL (1 op).
//!
//! Trace layout (10 columns):
//!   clk, pc, rd, rd_val, imm_j, target, enabler,
//!   target_lo, target_hi, instruction_word.
//!
//! Constraints:
//!   - enabler is boolean.
//!   - target = pc + imm_j (J-type immediate, already sign-extended).
//!   - target = target_lo + target_hi * 2^16 (range check).
//!   - rd_val = pc + 4 (link register).

const std = @import("std");
const cf = @import("../../../../core/constraint_framework/mod.zig");
const claims_mod = @import("../claims.zig");
const trace = @import("../trace_columns.zig");
const M31 = @import("../../../../core/fields/m31.zig").M31;

const ExprEvaluator = cf.ExprEvaluator;
const ExprArena = cf.ExprArena;
const BaseExpr = cf.BaseExpr;
const ExtExpr = cf.ExtExpr;

pub const Columns = trace.JalColumns;
pub const N_TRACE_COLUMNS: usize = Columns.N_COLUMNS;
pub const Claim = claims_mod.ComponentClaim;
pub const InteractionClaim = claims_mod.ComponentInteractionClaim;

/// Evaluate the jal AIR constraints.
pub fn evaluate(eval: *ExprEvaluator) !void {
    const arena = eval.arena;

    const clk = try eval.nextTraceMask();
    const pc = try eval.nextTraceMask();
    const rd = try eval.nextTraceMask();
    const rd_val = try eval.nextTraceMask();
    const imm_j = try eval.nextTraceMask();
    const target = try eval.nextTraceMask();
    const enabler = try eval.nextTraceMask();
    const target_lo = try eval.nextTraceMask();
    const target_hi = try eval.nextTraceMask();
    const instruction_word = try eval.nextTraceMask();

    const one = try arena.baseOne();
    const shift_16 = try arena.baseConst(M31.fromCanonical(1 << 16));
    const four = try arena.baseConst(M31.fromCanonical(4));

    // enabler is boolean
    try eval.addConstraint(try arena.extBase(
        try arena.baseSub(try arena.baseMul(enabler, enabler), enabler),
    ));

    // target = pc + imm_j
    const expected_target = try arena.baseAdd(pc, imm_j);
    try eval.addConstraint(try arena.extBase(
        try arena.baseMul(enabler, try arena.baseSub(target, expected_target)),
    ));

    // target = target_lo + target_hi * 2^16
    const target_recon = try arena.baseAdd(target_lo, try arena.baseMul(target_hi, shift_16));
    try eval.addConstraint(try arena.extBase(
        try arena.baseMul(enabler, try arena.baseSub(target, target_recon)),
    ));

    // rd_val = pc + 4 (link)
    const link_addr = try arena.baseAdd(pc, four);
    try eval.addConstraint(try arena.extBase(
        try arena.baseMul(enabler, try arena.baseSub(rd_val, link_addr)),
    ));

    // ---- LogUp relations ----
    const alpha = try arena.extParam("alpha");
    const z = try arena.extParam("z");
    const clk_next = try arena.baseAdd(clk, one);

    // Register write rd (link)
    try eval.writeLogupFrac(.{
        .numerator = try arena.extNeg(try arena.extFromBase(enabler)),
        .denominator = try arena.extSub(alpha, try arena.extFromBase(
            try arena.baseAdd(try arena.baseAdd(rd, try arena.baseMul(clk_next, shift_16)), link_addr),
        )),
    });

    // Program lookup
    try eval.writeLogupFrac(.{
        .numerator = try arena.extFromBase(enabler),
        .denominator = try arena.extSub(z, try arena.extFromBase(
            try arena.baseAdd(pc, try arena.baseMul(instruction_word, shift_16)),
        )),
    });

    // Range check 8_8 for target
    try eval.writeLogupFrac(.{
        .numerator = try arena.extFromBase(enabler),
        .denominator = try arena.extSub(z, try arena.extFromBase(target_recon)),
    });

    // Opcode bus: current state
    try eval.writeLogupFrac(.{
        .numerator = try arena.extFromBase(enabler),
        .denominator = try arena.extSub(alpha, try arena.extFromBase(try arena.baseAdd(pc, clk))),
    });

    // Opcode bus: next state (jumps to target)
    try eval.writeLogupFrac(.{
        .numerator = try arena.extNeg(try arena.extFromBase(enabler)),
        .denominator = try arena.extSub(alpha, try arena.extFromBase(try arena.baseAdd(target, clk_next))),
    });

    try eval.finalizeLogupInPairs();
}

test "jal: constraint count" {
    var arena = cf.ExprArena.init(std.testing.allocator);
    defer arena.deinit();
    var eval = try ExprEvaluator.init(&arena, std.testing.allocator);
    defer eval.deinit();

    try evaluate(&eval);
    try std.testing.expect(eval.constraints.items.len > 0);
}
