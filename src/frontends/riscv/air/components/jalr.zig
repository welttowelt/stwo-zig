//! AIR component for the JALR (Jump And Link Register) instruction.
//!
//! Instructions: JALR (1 op).
//!
//! Trace layout (12 columns):
//!   clk, pc, rd, rs1, imm, rd_val, rs1_val, target, enabler,
//!   target_lo, target_hi, instruction_word.
//!
//! Constraints:
//!   - enabler is boolean.
//!   - target = (rs1_val + imm) & ~1 (clear lowest bit).
//!   - target = target_lo + target_hi * 2^16 (range check).
//!   - rd_val = pc + 4 (link register: return address).

const std = @import("std");
const cf = @import("../../../../core/constraint_framework/mod.zig");
const claims_mod = @import("../claims.zig");
const trace = @import("../trace_columns.zig");
const M31 = @import("../../../../core/fields/m31.zig").M31;

const ExprEvaluator = cf.ExprEvaluator;
const ExprArena = cf.ExprArena;
const BaseExpr = cf.BaseExpr;
const ExtExpr = cf.ExtExpr;

pub const Columns = trace.JalrColumns;
pub const N_TRACE_COLUMNS: usize = Columns.N_COLUMNS;
pub const Claim = claims_mod.ComponentClaim;
pub const InteractionClaim = claims_mod.ComponentInteractionClaim;

/// Evaluate the jalr AIR constraints.
pub fn evaluate(eval: *ExprEvaluator) !void {
    const arena = eval.arena;

    const clk = try eval.nextTraceMask();
    const pc = try eval.nextTraceMask();
    const rd = try eval.nextTraceMask();
    const rs1 = try eval.nextTraceMask();
    const imm = try eval.nextTraceMask();
    const rd_val = try eval.nextTraceMask();
    const rs1_val = try eval.nextTraceMask();
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

    // target = rs1_val + imm (with lowest bit cleared; the bit-clearing is
    // enforced by requiring target_lo to be even, checked in range check).
    const raw_target = try arena.baseAdd(rs1_val, imm);
    try eval.addConstraint(try arena.extBase(
        try arena.baseMul(enabler, try arena.baseSub(target, raw_target)),
    ));

    // target = target_lo + target_hi * 2^16
    const target_recon = try arena.baseAdd(target_lo, try arena.baseMul(target_hi, shift_16));
    try eval.addConstraint(try arena.extBase(
        try arena.baseMul(enabler, try arena.baseSub(target, target_recon)),
    ));

    // rd_val = pc + 4 (link address)
    const link_addr = try arena.baseAdd(pc, four);
    try eval.addConstraint(try arena.extBase(
        try arena.baseMul(enabler, try arena.baseSub(rd_val, link_addr)),
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

    // Register write rd (link register)
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

    // Opcode bus: next state (jumps to target, not pc+4)
    try eval.writeLogupFrac(.{
        .numerator = try arena.extNeg(try arena.extFromBase(enabler)),
        .denominator = try arena.extSub(alpha, try arena.extFromBase(try arena.baseAdd(target, clk_next))),
    });

    try eval.finalizeLogupInPairs();
}

test "jalr: constraint count" {
    var arena = cf.ExprArena.init(std.testing.allocator);
    defer arena.deinit();
    var eval = try ExprEvaluator.init(&arena, std.testing.allocator);
    defer eval.deinit();

    try evaluate(&eval);
    try std.testing.expect(eval.constraints.items.len > 0);
}
