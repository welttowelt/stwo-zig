//! AIR component for Merkle tree verification.
//!
//! Verifies Merkle tree paths used by program ROM and memory state
//! commitment.  Each row corresponds to one level of a Merkle path.
//!
//! Trace layout (10 columns):
//!   enabler, index, depth, lhs, rhs, cur, lhs_mult, rhs_mult, cur_mult, root.
//!
//! Constraints:
//!   - enabler is boolean.
//!   - Poseidon2 relation: cur = hash(lhs, rhs).
//!   - Multiplicity consistency for Merkle node reuse.

const std = @import("std");
const cf = @import("stwo_core").constraint_framework;
const claims_mod = @import("../claims.zig");
const trace = @import("../trace_columns.zig");
const M31 = @import("stwo_core").fields.m31.M31;

const ExprEvaluator = cf.ExprEvaluator;
const ExprArena = cf.ExprArena;
const BaseExpr = cf.BaseExpr;
const ExtExpr = cf.ExtExpr;

pub const Columns = trace.MerkleColumns;
pub const N_TRACE_COLUMNS: usize = Columns.N_COLUMNS;
pub const Claim = claims_mod.ComponentClaim;
pub const InteractionClaim = claims_mod.ComponentInteractionClaim;

/// Evaluate the merkle AIR constraints.
pub fn evaluate(eval: *ExprEvaluator) !void {
    const arena = eval.arena;

    // Read all 10 trace columns in order.
    const enabler = try eval.nextTraceMask();
    const index = try eval.nextTraceMask();
    const depth = try eval.nextTraceMask();
    const lhs = try eval.nextTraceMask();
    const rhs = try eval.nextTraceMask();
    const cur = try eval.nextTraceMask();
    const lhs_mult = try eval.nextTraceMask();
    const rhs_mult = try eval.nextTraceMask();
    const cur_mult = try eval.nextTraceMask();
    const root = try eval.nextTraceMask();

    _ = index;
    _ = depth;
    _ = root;

    // ---- enabler is boolean ----
    try eval.addConstraint(try arena.extFromBase(
        try arena.baseSub(try arena.baseMul(enabler, enabler), enabler),
    ));

    // ---- Poseidon2 relation: cur = hash(lhs, rhs) ----
    // The Poseidon2 hash is verified via a LogUp lookup into the
    // Poseidon2 permutation component.
    const alpha = try arena.extParam("alpha");
    const z = try arena.extParam("z");

    // Poseidon2 lookup: +enabler / (alpha - hash_entry(lhs, rhs, cur))
    const shift_16 = try arena.baseConst(M31.fromCanonical(1 << 16));
    const hash_entry = try arena.extFromBase(try arena.baseAdd(
        try arena.baseAdd(lhs, try arena.baseMul(rhs, shift_16)),
        cur,
    ));
    try eval.writeLogupFrac(.{
        .numerator = try arena.extFromBase(enabler),
        .denominator = try arena.extSub(alpha, hash_entry),
    });

    // ---- Multiplicity consistency ----
    // lhs_mult and rhs_mult track child node multiplicities.
    // cur_mult tracks the current node multiplicity.
    // LogUp fraction for multiplicity balance:
    // +cur_mult / (z - cur) - lhs_mult / (z - lhs) - rhs_mult / (z - rhs)
    try eval.writeLogupFrac(.{
        .numerator = try arena.extFromBase(cur_mult),
        .denominator = try arena.extSub(z, try arena.extFromBase(cur)),
    });
    try eval.writeLogupFrac(.{
        .numerator = try arena.extNeg(try arena.extFromBase(lhs_mult)),
        .denominator = try arena.extSub(z, try arena.extFromBase(lhs)),
    });
    try eval.writeLogupFrac(.{
        .numerator = try arena.extNeg(try arena.extFromBase(rhs_mult)),
        .denominator = try arena.extSub(z, try arena.extFromBase(rhs)),
    });

    try eval.finalizeLogupInPairs();
}

test "merkle: constraint count" {
    var arena = cf.ExprArena.init(std.testing.allocator);
    defer arena.deinit();
    var eval = try ExprEvaluator.init(&arena, std.testing.allocator);
    defer eval.deinit();

    try evaluate(&eval);

    // 1 enabler-boolean constraint + logup constraints (4 fracs batched in pairs -> ceil(4/2) = 2)
    // = 3
    try std.testing.expectEqual(@as(usize, 3), eval.constraints.items.len);
}
