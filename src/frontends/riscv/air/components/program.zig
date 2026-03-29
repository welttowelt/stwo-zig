//! AIR component for the Program ROM.
//!
//! Verifies that each instruction fetched during execution matches the
//! committed program.  In stark-v this is backed by a Merkle tree over
//! program instruction words.
//!
//! Trace layout (3 columns):
//!   pc, instruction_word, enabler.
//!
//! Constraints:
//!   - enabler is boolean (enabler^2 - enabler = 0).
//!   - Program lookup relation: +enabler / (z - entry(pc, instruction_word)).

const std = @import("std");
const cf = @import("../../../../core/constraint_framework/mod.zig");
const claims_mod = @import("../claims.zig");
const trace = @import("../trace_columns.zig");
const M31 = @import("../../../../core/fields/m31.zig").M31;

const ExprEvaluator = cf.ExprEvaluator;
const ExprArena = cf.ExprArena;
const BaseExpr = cf.BaseExpr;
const ExtExpr = cf.ExtExpr;

pub const Columns = trace.ProgramColumns;
pub const N_TRACE_COLUMNS: usize = Columns.N_COLUMNS;
pub const Claim = claims_mod.ComponentClaim;
pub const InteractionClaim = claims_mod.ComponentInteractionClaim;

/// Evaluate the program ROM AIR constraints.
pub fn evaluate(eval: *ExprEvaluator) !void {
    const arena = eval.arena;

    // Read all 3 trace columns in order.
    const pc = try eval.nextTraceMask();
    const instruction_word = try eval.nextTraceMask();
    const enabler = try eval.nextTraceMask();

    const shift_16 = try arena.baseConst(M31.fromCanonical(1 << 16));

    // ---- enabler is boolean ----
    try eval.addConstraint(try arena.extFromBase(
        try arena.baseSub(try arena.baseMul(enabler, enabler), enabler),
    ));

    // ---- Program lookup LogUp ----
    // +enabler / (z - entry(pc, instruction_word))
    // entry = pc + instruction_word * 2^16
    const z = try arena.extParam("z");
    const prog_entry = try arena.extFromBase(try arena.baseAdd(
        pc,
        try arena.baseMul(instruction_word, shift_16),
    ));
    try eval.writeLogupFrac(.{
        .numerator = try arena.extFromBase(enabler),
        .denominator = try arena.extSub(z, prog_entry),
    });

    try eval.finalizeLogup();
}

test "program: constraint count" {
    var arena = cf.ExprArena.init(std.testing.allocator);
    defer arena.deinit();
    var eval = try ExprEvaluator.init(&arena, std.testing.allocator);
    defer eval.deinit();

    try evaluate(&eval);

    // 1 enabler-boolean constraint + 1 logup constraint = 2
    try std.testing.expectEqual(@as(usize, 2), eval.constraints.items.len);
}
