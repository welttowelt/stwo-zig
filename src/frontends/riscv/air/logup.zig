//! Real LogUp interaction machinery for the RISC-V AIR.
//!
//! This module owns the batched-fraction cumulative columns, the generic
//! pairs-batched transition constraint, and the public boundary terms of the
//! cross-shard buses:
//!
//!  - CPU state chain (`OpcodeRelation`): every executed row consumes its
//!    in-state `(pc, clk)` and emits its out-state `(next_pc, clk + 1)`.
//!    Sharding is irrelevant to the bus — the multiset telescopes globally,
//!    with the initial and final CPU states supplied publicly by the verifier.
//!  - Program lookup (`ProgramLookupRelation`): every executed row consumes
//!    `(pc, inst_lo, inst_hi)`; the program ROM component emits each unique
//!    tuple weighted by its execution multiplicity.
//!
//! The cumulative-sum column S obeys, over the trace domain,
//!   [S(x) - S(x·g⁻¹) + is_first(x)·claimed] · d1(x) · d2(x)
//!       - [n1(x)·d2(x) + n2(x)·d1(x)] = 0
//! where g is the canonic-coset step. The identity between "trace-order row
//! shift" and "evaluation at x·g⁻¹" is proven by a test in this file against
//! the exact interpolation pipeline the prover uses.

const std = @import("std");
const m31 = @import("../../../core/fields/m31.zig");
const qm31 = @import("../../../core/fields/qm31.zig");
const circle = @import("../../../core/circle.zig");
const canonic = @import("../../../core/poly/circle/canonic.zig");
const interaction = @import("interaction.zig");
const relations = @import("relations.zig");

const M31 = m31.M31;
const QM31 = qm31.QM31;
pub const SECURE_EXTENSION_DEGREE = qm31.SECURE_EXTENSION_DEGREE;
const CirclePointM31 = circle.CirclePointM31;
const CirclePointQM31 = circle.CirclePointQM31;

pub const LogupError = error{ ZeroDenominator, OutOfMemory };

/// Lift a base-field circle point into the secure field.
pub fn liftPoint(p: CirclePointM31) CirclePointQM31 {
    return .{ .x = QM31.fromBase(p.x), .y = QM31.fromBase(p.y) };
}

/// The trace-order predecessor mask point: `point - g` for the canonic coset
/// step g of the component's domain. Sampling a committed column at this
/// point reads the previous trace row.
pub fn prevRowPoint(log_size: u32, point: CirclePointQM31) CirclePointQM31 {
    const step = canonic.CanonicCoset.new(log_size).coset_value.step;
    return point.sub(liftPoint(step));
}

/// One pairs-batched row: the fraction n1/d1 + n2/d2. Single-fraction rows
/// set `n2 = 0, d2 = 1`.
pub const RowPair = struct {
    n1: QM31,
    d1: QM31,
    n2: QM31,
    d2: QM31,

    pub fn single(n: QM31, d: QM31) RowPair {
        return .{ .n1 = n, .d1 = d, .n2 = QM31.zero(), .d2 = QM31.one() };
    }
};

/// Cumulative sums in TRACE ORDER plus the component's claimed sum.
pub const CumulativeColumn = struct {
    sums: []QM31,
    claimed: QM31,

    pub fn deinit(self: *CumulativeColumn, allocator: std.mem.Allocator) void {
        allocator.free(self.sums);
        self.* = undefined;
    }
};

/// Accumulate batched fractions row by row. `pairs.len` must be the full
/// domain size; padding rows must carry zero numerators.
pub fn cumulativeColumn(
    allocator: std.mem.Allocator,
    pairs: []const RowPair,
) LogupError!CumulativeColumn {
    const sums = try allocator.alloc(QM31, pairs.len);
    errdefer allocator.free(sums);
    var acc = QM31.zero();
    for (pairs, 0..) |pair, i| {
        const denom = pair.d1.mul(pair.d2);
        const numer = pair.n1.mul(pair.d2).add(pair.n2.mul(pair.d1));
        const denom_inv = denom.inv() catch return error.ZeroDenominator;
        acc = acc.add(numer.mul(denom_inv));
        sums[i] = acc;
    }
    return .{ .sums = sums, .claimed = acc };
}

/// The pairs-batched LogUp transition constraint. Works identically on OODS
/// mask samples and on lifted domain values; degree 3 in the trace columns.
pub fn pairConstraint(
    s: QM31,
    s_prev: QM31,
    is_first: QM31,
    claimed: QM31,
    pair: RowPair,
) QM31 {
    const delta = s.sub(s_prev).add(is_first.mul(claimed));
    return delta.mul(pair.d1).mul(pair.d2)
        .sub(pair.n1.mul(pair.d2)).sub(pair.n2.mul(pair.d1));
}

// ---------------------------------------------------------------------------
// Bus tuples
// ---------------------------------------------------------------------------

/// CPU state-chain pair for one executed row: consume (pc, clk), emit
/// (next_pc, clk + 1), both gated by the row enabler.
pub fn stateChainPair(
    lookup: *const interaction.LookupElements,
    pc: QM31,
    clk: QM31,
    next_pc: QM31,
    enabler: QM31,
) RowPair {
    return .{
        .n1 = enabler,
        .d1 = stateDenominator(lookup, next_pc, clk.add(QM31.one())),
        .n2 = enabler.neg(),
        .d2 = stateDenominator(lookup, pc, clk),
    };
}

fn stateDenominator(
    lookup: *const interaction.LookupElements,
    pc: QM31,
    clk: QM31,
) QM31 {
    var acc = QM31.fromBase(relations.OpcodeRelation.ID);
    acc = acc.add(lookup.elements[0].mul(pc));
    acc = acc.add(lookup.elements[1].mul(clk));
    return lookup.z.sub(acc);
}

/// Program-lookup denominator over the tuple (pc, inst_lo, inst_hi).
pub fn programDenominator(
    lookup: *const interaction.LookupElements,
    pc: QM31,
    inst_lo: QM31,
    inst_hi: QM31,
) QM31 {
    var acc = QM31.fromBase(relations.ProgramLookupRelation.ID);
    acc = acc.add(lookup.elements[0].mul(pc));
    acc = acc.add(lookup.elements[1].mul(inst_lo));
    acc = acc.add(lookup.elements[2].mul(inst_hi));
    return lookup.z.sub(acc);
}

/// Executed-row side of the program bus: consume the fetched instruction.
pub fn programConsume(
    lookup: *const interaction.LookupElements,
    pc: QM31,
    inst_lo: QM31,
    inst_hi: QM31,
    enabler: QM31,
) RowPair {
    return RowPair.single(enabler.neg(), programDenominator(lookup, pc, inst_lo, inst_hi));
}

/// ROM side of the program bus: emit the tuple with its multiplicity.
pub fn programEmit(
    lookup: *const interaction.LookupElements,
    pc: QM31,
    inst_lo: QM31,
    inst_hi: QM31,
    multiplicity: QM31,
) RowPair {
    return RowPair.single(multiplicity, programDenominator(lookup, pc, inst_lo, inst_hi));
}

/// Public boundary of the CPU state chain: the verifier emits the initial
/// state and consumes the final one, closing the global telescope.
pub fn stateBoundary(
    lookup: *const interaction.LookupElements,
    initial_pc: u32,
    final_pc: u32,
    total_steps: u32,
) LogupError!QM31 {
    const d_init = stateDenominator(
        lookup,
        QM31.fromBase(M31.fromU64(initial_pc)),
        QM31.one(),
    );
    const d_final = stateDenominator(
        lookup,
        QM31.fromBase(M31.fromU64(final_pc)),
        QM31.fromBase(M31.fromU64(total_steps)).add(QM31.one()),
    );
    const init_term = QM31.one().mul((d_init.inv() catch return error.ZeroDenominator));
    const final_term = QM31.one().mul((d_final.inv() catch return error.ZeroDenominator));
    return init_term.sub(final_term);
}

/// Global cross-shard acceptance: all component claims plus the public
/// boundary must cancel exactly.
pub fn verifyGlobalCancellation(claims: []const QM31, boundary: QM31) !void {
    var total = boundary;
    for (claims) |claim| total = total.add(claim);
    if (!total.eql(QM31.zero())) return error.LogupSumNonZero;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const eval_mod = @import("../../../prover/poly/circle/evaluation.zig");
const poly_mod = @import("../../../prover/poly/circle/poly.zig");
const infra = @import("../infra_trace.zig");

test "geometry: trace-order shift equals evaluation at point minus coset step" {
    const allocator = std.testing.allocator;
    const log_size: u32 = 3;
    const n: usize = 1 << log_size;

    var values: [8]M31 = undefined;
    for (&values, 0..) |*v, i| v.* = M31.fromU64(@as(u64, i) * 37 + 11);
    var shifted: [8]M31 = undefined;
    for (0..n) |i| shifted[i] = values[(i + n - 1) % n];

    const table = try infra.BitReversalTable.init(allocator, log_size);
    defer table.deinit(allocator);

    var col_a = [_]M31{M31.zero()} ** 8;
    var col_s = [_]M31{M31.zero()} ** 8;
    for (0..n) |i| {
        col_a[table.map(i)] = values[i];
        col_s[table.map(i)] = shifted[i];
    }

    const coset = canonic.CanonicCoset.new(log_size);
    const domain = coset.circleDomain();
    const eval_a = try eval_mod.CircleEvaluation.init(domain, &col_a);
    const eval_s = try eval_mod.CircleEvaluation.init(domain, &col_s);
    var coeffs_a = try poly_mod.interpolateFromEvaluation(allocator, eval_a);
    defer coeffs_a.deinit(allocator);
    var coeffs_s = try poly_mod.interpolateFromEvaluation(allocator, eval_s);
    defer coeffs_s.deinit(allocator);

    const step = coset.coset_value.step;
    const probe = circle.SECURE_FIELD_CIRCLE_GEN.mul(987654321);
    const at_probe = coeffs_s.evalAtPoint(probe);
    const at_shifted_probe = coeffs_a.evalAtPoint(probe.sub(liftPoint(step)));
    try std.testing.expect(at_probe.eql(at_shifted_probe));

    // Second independent probe point.
    const probe2 = circle.SECURE_FIELD_CIRCLE_GEN.mul(1234567);
    try std.testing.expect(
        coeffs_s.evalAtPoint(probe2).eql(coeffs_a.evalAtPoint(probe2.sub(liftPoint(step)))),
    );
}

test "cumulativeColumn accumulates batched fractions and reports the claim" {
    const allocator = std.testing.allocator;
    const one = QM31.one();
    const two = QM31.fromU32Unchecked(2, 0, 0, 0);
    const three = QM31.fromU32Unchecked(3, 0, 0, 0);
    const pairs = [_]RowPair{
        .{ .n1 = one, .d1 = two, .n2 = one.neg(), .d2 = three },
        RowPair.single(one, two),
    };
    var col = try cumulativeColumn(allocator, &pairs);
    defer col.deinit(allocator);

    const half = two.inv() catch unreachable;
    const third = three.inv() catch unreachable;
    const row0 = half.sub(third);
    try std.testing.expect(col.sums[0].eql(row0));
    try std.testing.expect(col.sums[1].eql(row0.add(half)));
    try std.testing.expect(col.claimed.eql(col.sums[1]));
}

test "pairConstraint vanishes exactly on honest cumulative columns" {
    const allocator = std.testing.allocator;
    var pairs: [4]RowPair = undefined;
    for (&pairs, 0..) |*pair, i| {
        pair.* = .{
            .n1 = QM31.fromU32Unchecked(@intCast(i + 1), 0, 3, 0),
            .d1 = QM31.fromU32Unchecked(@intCast(7 + i), 1, 0, 2),
            .n2 = QM31.fromU32Unchecked(5, @intCast(i), 0, 0).neg(),
            .d2 = QM31.fromU32Unchecked(11, 0, @intCast(2 * i + 1), 0),
        };
    }
    var col = try cumulativeColumn(allocator, &pairs);
    defer col.deinit(allocator);

    for (0..pairs.len) |i| {
        const s = col.sums[i];
        // Trace-order wraparound: row 0's predecessor is the last row.
        const s_prev = if (i == 0) col.sums[pairs.len - 1] else col.sums[i - 1];
        const is_first = if (i == 0) QM31.one() else QM31.zero();
        const c = pairConstraint(s, s_prev, is_first, col.claimed, pairs[i]);
        try std.testing.expect(c.eql(QM31.zero()));
    }

    // A forged claim breaks the first row.
    const forged = pairConstraint(
        col.sums[0],
        col.sums[pairs.len - 1],
        QM31.one(),
        col.claimed.add(QM31.one()),
        pairs[0],
    );
    try std.testing.expect(!forged.eql(QM31.zero()));
}

test "state chain telescopes across shards with the public boundary" {
    // Two shards proving a four-step execution: pc 0x1000 -> 0x1010.
    var lookup = interaction.LookupElements.initZero();
    lookup.z = QM31.fromU32Unchecked(7919, 104729, 1299709, 15485863);
    lookup.elements[0] = QM31.fromU32Unchecked(3, 1, 4, 1);
    lookup.elements[1] = QM31.fromU32Unchecked(2, 7, 1, 8);

    const allocator = std.testing.allocator;
    const one = QM31.one();

    // Shard A holds steps 1 and 3; shard B holds steps 2 and 4 — deliberately
    // interleaved to show placement is order-independent.
    const mkRow = struct {
        fn f(lk: *const interaction.LookupElements, pc: u32, clk: u32, next: u32) RowPair {
            return stateChainPair(
                lk,
                QM31.fromBase(M31.fromU64(pc)),
                QM31.fromBase(M31.fromU64(clk)),
                QM31.fromBase(M31.fromU64(next)),
                QM31.one(),
            );
        }
    }.f;
    _ = one;

    const shard_a = [_]RowPair{ mkRow(&lookup, 0x1000, 1, 0x1004), mkRow(&lookup, 0x1008, 3, 0x100C) };
    const shard_b = [_]RowPair{ mkRow(&lookup, 0x1004, 2, 0x1008), mkRow(&lookup, 0x100C, 4, 0x1010) };

    var col_a = try cumulativeColumn(allocator, &shard_a);
    defer col_a.deinit(allocator);
    var col_b = try cumulativeColumn(allocator, &shard_b);
    defer col_b.deinit(allocator);

    const boundary = try stateBoundary(&lookup, 0x1000, 0x1010, 4);
    try verifyGlobalCancellation(&.{ col_a.claimed, col_b.claimed }, boundary);

    // Drop one row's emission (forge the chain) and the cancellation fails.
    const bad_b = [_]RowPair{ mkRow(&lookup, 0x1004, 2, 0x1008), mkRow(&lookup, 0x100C, 4, 0x1014) };
    var col_bad = try cumulativeColumn(allocator, &bad_b);
    defer col_bad.deinit(allocator);
    try std.testing.expectError(
        error.LogupSumNonZero,
        verifyGlobalCancellation(&.{ col_a.claimed, col_bad.claimed }, boundary),
    );
}

test "program bus balances executed rows against ROM multiplicities" {
    var lookup = interaction.LookupElements.initZero();
    lookup.z = QM31.fromU32Unchecked(104651, 2, 3, 5);
    lookup.elements[0] = QM31.fromU32Unchecked(1, 1, 2, 3);
    lookup.elements[1] = QM31.fromU32Unchecked(5, 8, 13, 21);
    lookup.elements[2] = QM31.fromU32Unchecked(34, 55, 89, 144);

    const allocator = std.testing.allocator;
    const pc0 = QM31.fromBase(M31.fromU64(0x1000));
    const pc1 = QM31.fromBase(M31.fromU64(0x1004));
    const lo = QM31.fromBase(M31.fromU64(0x0093));
    const hi = QM31.fromBase(M31.fromU64(0x00A0));

    // pc0 executed twice (a loop), pc1 once.
    const executed = [_]RowPair{
        programConsume(&lookup, pc0, lo, hi, QM31.one()),
        programConsume(&lookup, pc0, lo, hi, QM31.one()),
        programConsume(&lookup, pc1, hi, lo, QM31.one()),
    };
    const rom = [_]RowPair{
        programEmit(&lookup, pc0, lo, hi, QM31.fromU32Unchecked(2, 0, 0, 0)),
        programEmit(&lookup, pc1, hi, lo, QM31.one()),
    };

    var exec_col = try cumulativeColumn(allocator, &executed);
    defer exec_col.deinit(allocator);
    var rom_col = try cumulativeColumn(allocator, &rom);
    defer rom_col.deinit(allocator);

    try verifyGlobalCancellation(&.{ exec_col.claimed, rom_col.claimed }, QM31.zero());

    // Wrong multiplicity is caught.
    const rom_bad = [_]RowPair{
        programEmit(&lookup, pc0, lo, hi, QM31.one()),
        programEmit(&lookup, pc1, hi, lo, QM31.one()),
    };
    var rom_bad_col = try cumulativeColumn(allocator, &rom_bad);
    defer rom_bad_col.deinit(allocator);
    try std.testing.expectError(
        error.LogupSumNonZero,
        verifyGlobalCancellation(&.{ exec_col.claimed, rom_bad_col.claimed }, QM31.zero()),
    );
}
