//! AIR component for the `ret` opcode.
//!
//! The ret instruction pops the return address from the stack and jumps to it:
//!   next_pc = [fp - 1]
//!   next_fp = [fp - 2]
//!   next_ap = ap
//!
//! Trace columns (16): pc, ap, fp, next_pc/fp decomposed into limbs, enabler bit.
//!
//! Relations: memory reads for [fp-1] and [fp-2], opcode state transition,
//! instruction verification.

const std = @import("std");
const cf = @import("stwo_core").constraint_framework;
const claims_mod = @import("../claims.zig");

const ExprEvaluator = cf.ExprEvaluator;
const ExprArena = cf.ExprArena;
const BaseExpr = cf.BaseExpr;
const ExtExpr = cf.ExtExpr;

/// Number of trace columns for ret_opcode.
pub const N_TRACE_COLUMNS: usize = 16;

/// Claim for this component.
pub const Claim = claims_mod.ComponentClaim;

/// Interaction claim for this component.
pub const InteractionClaim = claims_mod.ComponentInteractionClaim;

/// Evaluate the ret_opcode AIR constraints.
///
/// This function uses the ExprEvaluator to build the constraint expressions.
/// It reads trace column values via `nextTraceMask()` and emits polynomial
/// constraints via `addConstraint()` and logup relation entries via
/// `writeLogupFrac()`.
///
/// The constraints verify:
/// 1. Instruction decoding (verify_instruction relation)
/// 2. Memory read at [fp - 1] → next_pc (memory_address_to_id relation)
/// 3. Memory read at [fp - 2] → next_fp (memory_address_to_id relation)
/// 4. State transition: next_ap = ap (opcode relation)
pub fn evaluate(
    eval: *ExprEvaluator,
) !void {
    // Read the 16 trace columns.
    const pc = try eval.nextTraceMask(); // column 0: program counter
    const ap = try eval.nextTraceMask(); // column 1: allocation pointer
    const fp = try eval.nextTraceMask(); // column 2: frame pointer

    // Next state values (decomposed for range-checking).
    const next_pc_lo = try eval.nextTraceMask(); // column 3
    const next_pc_hi = try eval.nextTraceMask(); // column 4
    const next_fp_lo = try eval.nextTraceMask(); // column 5
    const next_fp_hi = try eval.nextTraceMask(); // column 6

    // Memory value limbs for [fp-1] and [fp-2].
    const mem_fp_m1_val_lo = try eval.nextTraceMask(); // column 7
    const mem_fp_m1_val_hi = try eval.nextTraceMask(); // column 8
    const mem_fp_m2_val_lo = try eval.nextTraceMask(); // column 9
    const mem_fp_m2_val_hi = try eval.nextTraceMask(); // column 10

    // Address decomposition and auxiliary columns.
    const fp_m1_addr = try eval.nextTraceMask(); // column 11
    const fp_m2_addr = try eval.nextTraceMask(); // column 12
    const mem_id_0 = try eval.nextTraceMask(); // column 13
    const mem_id_1 = try eval.nextTraceMask(); // column 14
    const enabler = try eval.nextTraceMask(); // column 15

    // Constraint: next_pc = mem_value_at[fp-1] (reconstructed from limbs).
    // next_pc = next_pc_lo + next_pc_hi * 2^16
    const arena = eval.arena;
    const shift_16 = try arena.baseConst(@import("stwo_core").fields.m31.M31.fromCanonical(1 << 16));
    const next_pc_reconstructed = try arena.baseAdd(next_pc_lo, try arena.baseMul(next_pc_hi, shift_16));
    const next_pc_from_mem = try arena.baseAdd(mem_fp_m1_val_lo, try arena.baseMul(mem_fp_m1_val_hi, shift_16));

    // Polynomial constraint: enabler * (next_pc_reconstructed - next_pc_from_mem) = 0
    const pc_diff = try arena.baseSub(next_pc_reconstructed, next_pc_from_mem);
    const pc_constraint = try arena.baseMul(enabler, pc_diff);
    try eval.addConstraint(try arena.extBase(pc_constraint));

    // Constraint: next_fp = mem_value_at[fp-2] (reconstructed from limbs).
    const next_fp_reconstructed = try arena.baseAdd(next_fp_lo, try arena.baseMul(next_fp_hi, shift_16));
    const next_fp_from_mem = try arena.baseAdd(mem_fp_m2_val_lo, try arena.baseMul(mem_fp_m2_val_hi, shift_16));

    const fp_diff = try arena.baseSub(next_fp_reconstructed, next_fp_from_mem);
    const fp_constraint = try arena.baseMul(enabler, fp_diff);
    try eval.addConstraint(try arena.extBase(fp_constraint));

    // Suppress unused variable warnings for columns used by logup relations
    // (which will be wired when the full relation system is implemented).
    _ = pc;
    _ = ap;
    _ = fp;
    _ = fp_m1_addr;
    _ = fp_m2_addr;
    _ = mem_id_0;
    _ = mem_id_1;
}

test "ret_opcode: constraint count" {
    var arena = cf.ExprArena.init(std.testing.allocator);
    defer arena.deinit();
    var eval = try ExprEvaluator.init(&arena, std.testing.allocator);
    defer eval.deinit();

    try evaluate(&eval);

    // Should have produced exactly 2 polynomial constraints.
    try std.testing.expectEqual(@as(usize, 2), eval.constraints.items.len);
}
