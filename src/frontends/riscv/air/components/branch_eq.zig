//! AIR component for the branch-equal family.
//!
//! Instructions: BEQ, BNE (2 ops).
//!
//! Trace layout (14 columns):
//!   clk, pc, rs1, rs2, rs1_val, rs2_val, is_beq, is_bne, enabler,
//!   branch_target, diff, diff_inv, is_equal, instruction_word.
//!
//! Constraints:
//!   - Flags boolean, enabler = sum, enabler in {0,1}.
//!   - diff = rs1_val - rs2_val.
//!   - is_equal is boolean and satisfies: is_equal * diff = 0,
//!     (1 - is_equal) * (1 - diff * diff_inv) = 0.
//!   - PC update:
//!       BEQ taken:  is_beq * is_equal -> next_pc = branch_target
//!       BEQ not taken: is_beq * (1 - is_equal) -> next_pc = pc + 4
//!       BNE taken:  is_bne * (1 - is_equal) -> next_pc = branch_target
//!       BNE not taken: is_bne * is_equal -> next_pc = pc + 4
//!   - No register write (branches don't write to rd).

const std = @import("std");
const cf = @import("../../../../core/constraint_framework/mod.zig");
const claims_mod = @import("../claims.zig");
const trace = @import("../trace_columns.zig");
const M31 = @import("../../../../core/fields/m31.zig").M31;

const ExprEvaluator = cf.ExprEvaluator;
const ExprArena = cf.ExprArena;
const BaseExpr = cf.BaseExpr;
const ExtExpr = cf.ExtExpr;

pub const Columns = trace.BranchEqColumns;
pub const N_TRACE_COLUMNS: usize = Columns.N_COLUMNS;
pub const Claim = claims_mod.ComponentClaim;
pub const InteractionClaim = claims_mod.ComponentInteractionClaim;

/// Evaluate the branch_eq AIR constraints.
pub fn evaluate(eval: *ExprEvaluator) !void {
    const arena = eval.arena;

    const clk = try eval.nextTraceMask();
    const pc = try eval.nextTraceMask();
    const rs1 = try eval.nextTraceMask();
    const rs2 = try eval.nextTraceMask();
    const rs1_val = try eval.nextTraceMask();
    const rs2_val = try eval.nextTraceMask();
    const is_beq = try eval.nextTraceMask();
    const is_bne = try eval.nextTraceMask();
    const enabler = try eval.nextTraceMask();
    const branch_target = try eval.nextTraceMask();
    const diff = try eval.nextTraceMask();
    const diff_inv = try eval.nextTraceMask();
    const is_equal = try eval.nextTraceMask();
    const instruction_word = try eval.nextTraceMask();

    const one = try arena.baseOne();
    const shift_16 = try arena.baseConst(M31.fromCanonical(1 << 16));
    const four = try arena.baseConst(M31.fromCanonical(4));

    // ---- Flag boolean constraints ----
    const flags = [_]BaseExpr{ is_beq, is_bne, is_equal };
    for (flags) |flag| {
        try eval.addConstraint(try arena.extBase(
            try arena.baseSub(try arena.baseMul(flag, flag), flag),
        ));
    }

    // enabler = is_beq + is_bne
    const flag_sum = try arena.baseAdd(is_beq, is_bne);
    try eval.addConstraint(try arena.extBase(try arena.baseSub(enabler, flag_sum)));

    // enabler * (enabler - 1) = 0
    try eval.addConstraint(try arena.extBase(try arena.baseMul(enabler, try arena.baseSub(enabler, one))));

    // ---- Equality check constraints ----
    // diff = rs1_val - rs2_val
    try eval.addConstraint(try arena.extBase(
        try arena.baseMul(enabler, try arena.baseSub(diff, try arena.baseSub(rs1_val, rs2_val))),
    ));

    // is_equal * diff = 0  (if equal, diff must be zero)
    try eval.addConstraint(try arena.extBase(try arena.baseMul(is_equal, diff)));

    // (1 - is_equal) * (1 - diff * diff_inv) = 0
    // If not equal, diff must have an inverse (i.e., diff != 0).
    const one_minus_eq = try arena.baseSub(one, is_equal);
    const one_minus_inv = try arena.baseSub(one, try arena.baseMul(diff, diff_inv));
    try eval.addConstraint(try arena.extBase(try arena.baseMul(one_minus_eq, one_minus_inv)));

    // ---- PC update constraint ----
    // taken = is_beq * is_equal + is_bne * (1 - is_equal)
    // next_pc = taken * branch_target + (1 - taken) * (pc + 4)
    // We constrain via: enabler * (next_pc - expected) = 0
    // where next_pc is what appears on the opcode bus.
    const taken = try arena.baseAdd(
        try arena.baseMul(is_beq, is_equal),
        try arena.baseMul(is_bne, one_minus_eq),
    );
    const pc_plus_4 = try arena.baseAdd(pc, four);
    const one_minus_taken = try arena.baseSub(one, taken);
    const expected_next_pc = try arena.baseAdd(
        try arena.baseMul(taken, branch_target),
        try arena.baseMul(one_minus_taken, pc_plus_4),
    );

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

    // Program lookup
    try eval.writeLogupFrac(.{
        .numerator = try arena.extFromBase(enabler),
        .denominator = try arena.extSub(z, try arena.extFromBase(
            try arena.baseAdd(pc, try arena.baseMul(instruction_word, shift_16)),
        )),
    });

    // Opcode bus: current state
    try eval.writeLogupFrac(.{
        .numerator = try arena.extFromBase(enabler),
        .denominator = try arena.extSub(alpha, try arena.extFromBase(try arena.baseAdd(pc, clk))),
    });

    // Opcode bus: next state (uses expected_next_pc)
    try eval.writeLogupFrac(.{
        .numerator = try arena.extNeg(try arena.extFromBase(enabler)),
        .denominator = try arena.extSub(alpha, try arena.extFromBase(try arena.baseAdd(expected_next_pc, clk_next))),
    });

    try eval.finalizeLogupInPairs();
}

test "branch_eq: constraint count" {
    var arena = cf.ExprArena.init(std.testing.allocator);
    defer arena.deinit();
    var eval = try ExprEvaluator.init(&arena, std.testing.allocator);
    defer eval.deinit();

    try evaluate(&eval);
    try std.testing.expect(eval.constraints.items.len > 0);
}
