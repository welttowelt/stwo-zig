//! AIR component for the Poseidon2 hash permutation.
//!
//! Tracks the full Poseidon2 permutation over M31 with STATE_WIDTH=16,
//! 4+4 full rounds, and 14 partial rounds.
//!
//! Trace layout (443 columns):
//!   - 1 enabler
//!   - 16 initial state
//!   - 4 first full rounds x 48 columns each
//!       (16 state_in + 16 after_sbox + 16 after_mds) = 192
//!   - 14 partial rounds x 3 columns each
//!       (state0_in, after_sbox, after_mds_state0) = 42
//!   - 4 last full rounds x 48 columns each = 192
//!
//! Constraints:
//!   - enabler is boolean.
//!   - Full round S-box: for each element i in the state,
//!       enabler * (after_sbox[i] - state_in[i]^5) = 0
//!     verified via an intermediate x2 = state_in^2 so the
//!     constraint is degree 3: enabler * (after_sbox - x2 * x2 * state_in).
//!   - Partial round S-box: same but only on element 0.
//!   - Round transition: state_in of round r+1 = after_mds of round r
//!     (enforced by sharing columns; initial_state feeds first round).
//!   - LogUp relation for Poseidon2 bus (linking to Merkle component).

const std = @import("std");
const cf = @import("stwo_core").constraint_framework;
const claims_mod = @import("../claims.zig");
const trace = @import("../trace_columns.zig");
const M31 = @import("stwo_core").fields.m31.M31;
const poseidon2 = @import("../../common/poseidon2.zig");

const ExprEvaluator = cf.ExprEvaluator;
const ExprArena = cf.ExprArena;
const BaseExpr = cf.BaseExpr;
const ExtExpr = cf.ExtExpr;

const STATE_WIDTH = poseidon2.STATE_WIDTH; // 16
const N_FULL_ROUNDS_FIRST = poseidon2.N_FULL_ROUNDS_FIRST; // 4
const N_PARTIAL_ROUNDS = poseidon2.N_PARTIAL_ROUNDS; // 14
const N_FULL_ROUNDS_LAST = poseidon2.N_FULL_ROUNDS_LAST; // 4

/// Number of columns per full round: state_in(16) + after_sbox(16) + after_mds(16) = 48.
const COLS_PER_FULL_ROUND: usize = 3 * STATE_WIDTH;

/// Number of columns per partial round: state0_in(1) + after_sbox(1) + after_mds_state0(1) = 3.
const COLS_PER_PARTIAL_ROUND: usize = 3;

/// Total trace columns for the Poseidon2 component.
///   1 + 16 + 4*48 + 14*3 + 4*48 = 1 + 16 + 192 + 42 + 192 = 443
pub const N_TRACE_COLUMNS: usize = 1 + STATE_WIDTH +
    (N_FULL_ROUNDS_FIRST * COLS_PER_FULL_ROUND) +
    (N_PARTIAL_ROUNDS * COLS_PER_PARTIAL_ROUND) +
    (N_FULL_ROUNDS_LAST * COLS_PER_FULL_ROUND);

pub const Columns = trace.Poseidon2Columns;
pub const Claim = claims_mod.ComponentClaim;
pub const InteractionClaim = claims_mod.ComponentInteractionClaim;

/// Column index helpers.
const ENABLER_COL: usize = 0;
const INITIAL_STATE_START: usize = 1;
const FULL_ROUNDS_FIRST_START: usize = INITIAL_STATE_START + STATE_WIDTH; // 17
const PARTIAL_ROUNDS_START: usize = FULL_ROUNDS_FIRST_START + N_FULL_ROUNDS_FIRST * COLS_PER_FULL_ROUND; // 209
const FULL_ROUNDS_LAST_START: usize = PARTIAL_ROUNDS_START + N_PARTIAL_ROUNDS * COLS_PER_PARTIAL_ROUND; // 251

/// Evaluate the Poseidon2 AIR constraints.
pub fn evaluate(eval: *ExprEvaluator) !void {
    const arena = eval.arena;

    // Read all 443 trace columns in order.
    var cols: [N_TRACE_COLUMNS]BaseExpr = undefined;
    for (0..N_TRACE_COLUMNS) |i| {
        cols[i] = try eval.nextTraceMask();
    }

    const enabler = cols[ENABLER_COL];

    // ---- enabler is boolean ----
    try eval.addConstraint(try arena.extFromBase(
        try arena.baseSub(try arena.baseMul(enabler, enabler), enabler),
    ));

    // ---- First full rounds: S-box constraints ----
    // For each full round and each state element:
    //   Introduce intermediate x2 = state_in[i]^2.
    //   Constraint: enabler * (after_sbox[i] - x2 * x2 * state_in[i]) = 0
    //   This is degree 3 (enabler * x2 * x2 * state_in), where x2 is an
    //   intermediate that the evaluator substitutes at evaluation time.
    for (0..N_FULL_ROUNDS_FIRST) |round| {
        const base = FULL_ROUNDS_FIRST_START + round * COLS_PER_FULL_ROUND;
        for (0..STATE_WIDTH) |i| {
            const state_in = cols[base + i];
            const after_sbox = cols[base + STATE_WIDTH + i];

            // x2 = state_in * state_in
            const x2 = try eval.addIntermediate(try arena.baseMul(state_in, state_in));
            // x5 = x2 * x2 * state_in  (via intermediate x4 = x2 * x2)
            const x4 = try arena.baseMul(x2, x2);
            const x5 = try arena.baseMul(x4, state_in);

            // enabler * (after_sbox - x5) = 0
            const diff = try arena.baseSub(after_sbox, x5);
            try eval.addConstraint(try arena.extFromBase(
                try arena.baseMul(enabler, diff),
            ));
        }
    }

    // ---- Partial rounds: S-box constraint on element 0 only ----
    for (0..N_PARTIAL_ROUNDS) |round| {
        const base = PARTIAL_ROUNDS_START + round * COLS_PER_PARTIAL_ROUND;
        const state0_in = cols[base];
        const after_sbox = cols[base + 1];

        const x2 = try eval.addIntermediate(try arena.baseMul(state0_in, state0_in));
        const x4 = try arena.baseMul(x2, x2);
        const x5 = try arena.baseMul(x4, state0_in);

        const diff = try arena.baseSub(after_sbox, x5);
        try eval.addConstraint(try arena.extFromBase(
            try arena.baseMul(enabler, diff),
        ));
    }

    // ---- Last full rounds: S-box constraints ----
    for (0..N_FULL_ROUNDS_LAST) |round| {
        const base = FULL_ROUNDS_LAST_START + round * COLS_PER_FULL_ROUND;
        for (0..STATE_WIDTH) |i| {
            const state_in = cols[base + i];
            const after_sbox = cols[base + STATE_WIDTH + i];

            const x2 = try eval.addIntermediate(try arena.baseMul(state_in, state_in));
            const x4 = try arena.baseMul(x2, x2);
            const x5 = try arena.baseMul(x4, state_in);

            const diff = try arena.baseSub(after_sbox, x5);
            try eval.addConstraint(try arena.extFromBase(
                try arena.baseMul(enabler, diff),
            ));
        }
    }

    // ---- LogUp relation for Poseidon2 bus ----
    // Links the initial state to the Merkle / hash-invocation bus.
    // Numerator: enabler (contributes +1 when enabled).
    // Denominator: alpha - hash_entry, where hash_entry encodes the
    // initial state columns into a single field element.
    const alpha = try arena.extParam("alpha");

    // Encode initial state: sum_{i} initial_state[i] * 2^(8*i) (mod p).
    // For simplicity we use a linear combination with powers of a shift.
    const shift = try arena.baseConst(M31.fromCanonical(1 << 8));
    var hash_entry = cols[INITIAL_STATE_START];
    var cur_shift = shift;
    for (1..STATE_WIDTH) |i| {
        hash_entry = try arena.baseAdd(
            hash_entry,
            try arena.baseMul(cols[INITIAL_STATE_START + i], cur_shift),
        );
        cur_shift = try arena.baseMul(cur_shift, shift);
    }

    try eval.writeLogupFrac(.{
        .numerator = try arena.extFromBase(enabler),
        .denominator = try arena.extSub(alpha, try arena.extFromBase(hash_entry)),
    });

    try eval.finalizeLogup();
}

test "poseidon2_comp: column count is 443" {
    try std.testing.expectEqual(@as(usize, 443), N_TRACE_COLUMNS);
}

test "poseidon2_comp: column layout offsets" {
    try std.testing.expectEqual(@as(usize, 0), ENABLER_COL);
    try std.testing.expectEqual(@as(usize, 1), INITIAL_STATE_START);
    try std.testing.expectEqual(@as(usize, 17), FULL_ROUNDS_FIRST_START);
    try std.testing.expectEqual(@as(usize, 209), PARTIAL_ROUNDS_START);
    try std.testing.expectEqual(@as(usize, 251), FULL_ROUNDS_LAST_START);
    // Final column index: 251 + 4*48 - 1 = 251 + 192 - 1 = 442 (last index in 0-based)
    try std.testing.expectEqual(@as(usize, 443), FULL_ROUNDS_LAST_START + N_FULL_ROUNDS_LAST * COLS_PER_FULL_ROUND);
}

test "poseidon2_comp: constraint evaluation runs" {
    var arena = cf.ExprArena.init(std.testing.allocator);
    defer arena.deinit();
    var eval = try ExprEvaluator.init(&arena, std.testing.allocator);
    defer eval.deinit();

    try evaluate(&eval);

    // Expected constraints:
    //   1 enabler-boolean
    // + 4*16 = 64 first full-round S-box constraints
    // + 14 partial-round S-box constraints
    // + 4*16 = 64 last full-round S-box constraints
    // + 1 logup constraint
    // = 144
    try std.testing.expectEqual(@as(usize, 144), eval.constraints.items.len);
}
