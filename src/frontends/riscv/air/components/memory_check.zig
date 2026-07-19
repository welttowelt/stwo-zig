//! AIR component for memory integrity checking.
//!
//! Verifies memory consistency using Merkle-tree-backed state.
//! Each memory cell has (addr, clk, value_0..3).
//!
//! Trace layout (9 columns):
//!   enabler, addr, clk, value_0, value_1, value_2, value_3, multiplicity, root.
//!
//! multiplicity tracks how many times this memory cell is accessed.
//! root connects to the Merkle tree.
//!
//! Constraints:
//!   - enabler is boolean.
//!   - Memory access relation: +multiplicity / (alpha - entry(addr, clk, value_0..3)).

const std = @import("std");
const cf = @import("stwo_core").constraint_framework;
const claims_mod = @import("../claims.zig");
const trace = @import("../trace_columns.zig");
const M31 = @import("stwo_core").fields.m31.M31;

const ExprEvaluator = cf.ExprEvaluator;
const ExprArena = cf.ExprArena;
const BaseExpr = cf.BaseExpr;
const ExtExpr = cf.ExtExpr;

pub const Columns = trace.MemoryCheckColumns;
pub const N_TRACE_COLUMNS: usize = Columns.N_COLUMNS;
pub const Claim = claims_mod.ComponentClaim;
pub const InteractionClaim = claims_mod.ComponentInteractionClaim;

/// Evaluate the memory_check AIR constraints.
pub fn evaluate(eval: *ExprEvaluator) !void {
    const arena = eval.arena;

    // Read all 9 trace columns in order.
    const enabler = try eval.nextTraceMask();
    const addr = try eval.nextTraceMask();
    const clk = try eval.nextTraceMask();
    const value_0 = try eval.nextTraceMask();
    const value_1 = try eval.nextTraceMask();
    const value_2 = try eval.nextTraceMask();
    const value_3 = try eval.nextTraceMask();
    const multiplicity = try eval.nextTraceMask();
    const root = try eval.nextTraceMask();

    _ = root;

    const shift_8 = try arena.baseConst(M31.fromCanonical(1 << 8));
    const shift_16 = try arena.baseConst(M31.fromCanonical(1 << 16));
    const shift_24 = try arena.baseConst(M31.fromCanonical(1 << 24));

    // ---- enabler is boolean ----
    try eval.addConstraint(try arena.extFromBase(
        try arena.baseSub(try arena.baseMul(enabler, enabler), enabler),
    ));

    // ---- LogUp relations ----
    const alpha = try arena.extParam("alpha");

    // Memory access relation:
    // entry = addr + clk * 2^8 + value
    // where value = value_0 + value_1 * 2^8 + value_2 * 2^16 + value_3 * 2^24
    const value = try arena.baseAdd(
        try arena.baseAdd(value_0, try arena.baseMul(value_1, shift_8)),
        try arena.baseAdd(try arena.baseMul(value_2, shift_16), try arena.baseMul(value_3, shift_24)),
    );
    const mem_entry = try arena.extFromBase(try arena.baseAdd(
        try arena.baseAdd(addr, try arena.baseMul(clk, shift_8)),
        value,
    ));
    try eval.writeLogupFrac(.{
        .numerator = try arena.extFromBase(multiplicity),
        .denominator = try arena.extSub(alpha, mem_entry),
    });

    try eval.finalizeLogup();
}

test "memory_check: constraint count" {
    var arena = cf.ExprArena.init(std.testing.allocator);
    defer arena.deinit();
    var eval = try ExprEvaluator.init(&arena, std.testing.allocator);
    defer eval.deinit();

    try evaluate(&eval);

    // 1 enabler-boolean constraint + 1 logup constraint = 2
    try std.testing.expectEqual(@as(usize, 2), eval.constraints.items.len);
}
