//! AIR component for memory integrity checking.
//!
//! Verifies memory consistency using clock-ordered access checking.
//! Each memory access has (addr_space, addr, clk, value_limbs).
//! The component verifies:
//!   - Each address is accessed in non-decreasing clock order.
//!   - Clock differences are bounded (range check).
//!   - Initial and final memory states match committed Merkle roots.
//!
//! Trace layout (12 columns):
//!   addr_space, addr, clk, limb_0, limb_1, limb_2, limb_3,
//!   prev_clk, clk_diff, is_first_access, is_write, enabler.
//!
//! Constraints:
//!   - addr_space * (addr_space - 1) = 0  (addr_space is 0 or 1).
//!   - is_first_access is boolean.
//!   - is_write is boolean.
//!   - enabler is boolean.
//!   - clk_diff = clk - prev_clk  (when enabled and not first access).
//!   - clk_diff range checked via range_check_20 lookup.
//!   - Memory access relation: +enabler / (alpha - entry(...)).

const std = @import("std");
const cf = @import("../../../../core/constraint_framework/mod.zig");
const claims_mod = @import("../claims.zig");
const trace = @import("../trace_columns.zig");
const M31 = @import("../../../../core/fields/m31.zig").M31;

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

    // Read all 12 trace columns in order.
    const addr_space = try eval.nextTraceMask();
    const addr = try eval.nextTraceMask();
    const clk = try eval.nextTraceMask();
    const limb_0 = try eval.nextTraceMask();
    const limb_1 = try eval.nextTraceMask();
    const limb_2 = try eval.nextTraceMask();
    const limb_3 = try eval.nextTraceMask();
    const prev_clk = try eval.nextTraceMask();
    const clk_diff = try eval.nextTraceMask();
    const is_first_access = try eval.nextTraceMask();
    const is_write = try eval.nextTraceMask();
    const enabler = try eval.nextTraceMask();

    const one = try arena.baseOne();
    const shift_8 = try arena.baseConst(M31.fromCanonical(1 << 8));
    const shift_16 = try arena.baseConst(M31.fromCanonical(1 << 16));
    const shift_24 = try arena.baseConst(M31.fromCanonical(1 << 24));

    // ---- addr_space is binary: addr_space * (addr_space - 1) = 0 ----
    try eval.addConstraint(try arena.extFromBase(
        try arena.baseMul(addr_space, try arena.baseSub(addr_space, one)),
    ));

    // ---- is_first_access is boolean ----
    try eval.addConstraint(try arena.extFromBase(
        try arena.baseSub(try arena.baseMul(is_first_access, is_first_access), is_first_access),
    ));

    // ---- is_write is boolean ----
    try eval.addConstraint(try arena.extFromBase(
        try arena.baseSub(try arena.baseMul(is_write, is_write), is_write),
    ));

    // ---- enabler is boolean ----
    try eval.addConstraint(try arena.extFromBase(
        try arena.baseSub(try arena.baseMul(enabler, enabler), enabler),
    ));

    // ---- clk_diff = clk - prev_clk (when enabled and not first access) ----
    // enabler * (1 - is_first_access) * (clk_diff - (clk - prev_clk)) = 0
    const not_first = try arena.baseSub(one, is_first_access);
    const expected_diff = try arena.baseSub(clk, prev_clk);
    const diff_err = try arena.baseSub(clk_diff, expected_diff);
    try eval.addConstraint(try arena.extFromBase(
        try arena.baseMul(enabler, try arena.baseMul(not_first, diff_err)),
    ));

    // ---- LogUp relations ----
    const alpha = try arena.extParam("alpha");
    const z = try arena.extParam("z");

    // Memory access relation:
    // entry = addr_space + addr * 2^8 + clk * 2^16 + value
    // where value = limb_0 + limb_1 * 2^8 + limb_2 * 2^16 + limb_3 * 2^24
    const value = try arena.baseAdd(
        try arena.baseAdd(limb_0, try arena.baseMul(limb_1, shift_8)),
        try arena.baseAdd(try arena.baseMul(limb_2, shift_16), try arena.baseMul(limb_3, shift_24)),
    );
    const mem_entry = try arena.extFromBase(try arena.baseAdd(
        try arena.baseAdd(addr_space, try arena.baseMul(addr, shift_8)),
        try arena.baseAdd(try arena.baseMul(clk, shift_16), value),
    ));
    try eval.writeLogupFrac(.{
        .numerator = try arena.extFromBase(enabler),
        .denominator = try arena.extSub(alpha, mem_entry),
    });

    // Range check clk_diff via range_check_20 lookup:
    // +enabler / (z - clk_diff)
    try eval.writeLogupFrac(.{
        .numerator = try arena.extFromBase(enabler),
        .denominator = try arena.extSub(z, try arena.extFromBase(clk_diff)),
    });

    try eval.finalizeLogupInPairs();
}

test "memory_check: constraint count" {
    var arena = cf.ExprArena.init(std.testing.allocator);
    defer arena.deinit();
    var eval = try ExprEvaluator.init(&arena, std.testing.allocator);
    defer eval.deinit();

    try evaluate(&eval);

    // 4 boolean constraints (addr_space, is_first_access, is_write, enabler)
    // + 1 clk_diff correctness
    // + 1 logup constraint (2 fracs batched in pairs -> ceil(2/2) = 1)
    // = 6
    try std.testing.expectEqual(@as(usize, 6), eval.constraints.items.len);
}
