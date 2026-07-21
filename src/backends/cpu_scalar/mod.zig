//! CPU scalar backend for stwo-zig.
//!
//! This is the default backend. All operations work on plain `[]F` slices
//! with scalar field arithmetic. The type itself is zero-sized — it exists
//! purely to select implementations at compile time.
//!
//! ## Column type
//!
//! `CpuBackend.ColumnType(M31) = []M31` — plain heap-allocated slices.
//!
//! ## Threading
//!
//! Merkle commitment supports optional multi-threaded hashing via
//! `std.Thread.Pool`, configured by environment variables.

const std = @import("std");
const m31_mod = @import("stwo_core").fields.m31;
const cm31_mod = @import("stwo_core").fields.cm31;
const qm31_mod = @import("stwo_core").fields.qm31;
const fields_mod = @import("stwo_core").fields;
const core_fri = @import("stwo_core").fri;
const circle = @import("stwo_core").circle;
const lifted_merkle = @import("stwo_prover_impl").vcs_lifted.prover;

const M31 = m31_mod.M31;
const CM31 = cm31_mod.CM31;
const QM31 = qm31_mod.QM31;

/// CPU scalar backend. Zero-sized marker type.
///
/// Satisfies the full `backend.assertBackend` contract by delegating
/// to the existing scalar implementations in `core/` and `prover/`.
pub const CpuBackend = struct {
    // ---------------------------------------------------------------
    // ColumnOps
    // ---------------------------------------------------------------

    /// Column storage is a plain slice of field elements.
    pub fn ColumnType(comptime F: type) type {
        return []F;
    }

    // ---------------------------------------------------------------
    // FieldOps
    // ---------------------------------------------------------------

    /// Montgomery batch inverse on a slice of field elements.
    pub fn batchInverse(
        comptime F: type,
        allocator: std.mem.Allocator,
        column: []const F,
    ) ![]F {
        return fields_mod.batchInverse(F, allocator, column);
    }

    // ---------------------------------------------------------------
    // PolyOps — delegates to prover/poly/circle/poly.zig
    // ---------------------------------------------------------------

    // These are thin markers that will be wired into the prover in Phase 3.
    // For now they exist to satisfy the assertPolyOps contract.

    /// Circle-domain interpolation (FFT-based).
    pub fn interpolate(
        allocator: std.mem.Allocator,
        values: []M31,
        domain: anytype,
        twiddle_tree: anytype,
    ) !void {
        // Delegates to poly.zig's interpolateIntoBufferWithTwiddles.
        // Full wiring happens in Phase 3 when CircleCoefficients gains B.
        _ = allocator;
        _ = values;
        _ = domain;
        _ = twiddle_tree;
    }

    /// Evaluate polynomial on extended domain.
    pub fn evaluateOnDomain(
        allocator: std.mem.Allocator,
        coeffs: []const M31,
        domain: anytype,
        twiddle_tree: anytype,
    ) ![]M31 {
        _ = allocator;
        _ = coeffs;
        _ = domain;
        _ = twiddle_tree;
        return error.OutOfMemory; // Placeholder — full impl in Phase 3
    }

    /// Evaluate polynomial at a single point.
    pub fn evalAtPoint(
        coeffs: []const M31,
        point: circle.CirclePoint(QM31),
    ) QM31 {
        _ = coeffs;
        _ = point;
        return QM31.zero(); // Placeholder — full impl in Phase 3
    }

    // ---------------------------------------------------------------
    // FriOps — delegates to core/fri.zig fold functions
    // ---------------------------------------------------------------

    /// Fold a circle evaluation into a line evaluation.
    pub fn foldCircleIntoLine(
        allocator: std.mem.Allocator,
        dst: []QM31,
        src_columns: [qm31_mod.SECURE_EXTENSION_DEGREE][]const M31,
        src_domain: anytype,
        alpha: QM31,
        workspace: *core_fri.FoldCircleWorkspace,
    ) !void {
        return core_fri.foldCircleColumnsIntoLineWithWorkspace(
            allocator,
            dst,
            src_columns,
            src_domain,
            alpha,
            workspace,
        );
    }

    /// Fold a line evaluation to half its size.
    pub fn foldLine(
        allocator: std.mem.Allocator,
        eval: []QM31,
        domain: anytype,
        alpha: QM31,
        workspace: *core_fri.FoldLineWorkspace,
    ) !core_fri.FoldLineResult {
        return core_fri.foldLineInPlaceWithWorkspace(
            allocator,
            eval,
            domain,
            alpha,
            workspace,
        );
    }

    pub fn foldLineN(
        allocator: std.mem.Allocator,
        eval: []QM31,
        domain: anytype,
        alpha: QM31,
        workspace: *core_fri.FoldLineWorkspace,
        n_folds: u32,
    ) !core_fri.FoldLineResult {
        return core_fri.foldLineInPlaceNWithWorkspace(
            allocator,
            eval,
            domain,
            alpha,
            workspace,
            n_folds,
        );
    }

    // ---------------------------------------------------------------
    // QuotientOps
    // ---------------------------------------------------------------

    /// Compute constraint quotients over the evaluation domain.
    /// Delegates to prover/pcs/quotient_ops.zig.
    pub fn accumulateQuotients() void {
        // Placeholder — full wiring in Phase 3 when quotient_ops gains B.
    }

    // ---------------------------------------------------------------
    // AccumulationOps
    // ---------------------------------------------------------------

    /// Accumulate constraint evaluations across domain positions.
    pub fn accumulate() void {
        // Placeholder — full wiring in Phase 3.
    }

    // ---------------------------------------------------------------
    // GkrOps
    // ---------------------------------------------------------------

    /// Generate equality polynomial evaluations over the boolean hypercube.
    pub fn genEqEvals() void {
        // Placeholder — delegates to gkr_prover.genEqEvals in Phase 3.
    }

    /// Compute the next GKR circuit layer.
    pub fn nextLayer() void {
        // Placeholder — delegates to gkr_prover layer logic in Phase 3.
    }

    /// Sum multilinear extension as polynomial in first variable.
    pub fn sumAsPolyInFirstVariable() void {
        // Placeholder — delegates to mle.sumAsPolyInFirstVariable in Phase 3.
    }

    // ---------------------------------------------------------------
    // MerkleOps
    // ---------------------------------------------------------------

    pub fn MerkleTree(comptime H: type) type {
        return lifted_merkle.MerkleProverLifted(H);
    }

    pub fn commitMerkle(
        comptime H: type,
        allocator: std.mem.Allocator,
        columns: []const []const M31,
    ) !MerkleTree(H) {
        return MerkleTree(H).commit(allocator, columns);
    }

    pub fn commitLazyMerkle(
        comptime H: type,
        allocator: std.mem.Allocator,
        provider: anytype,
        out_column: anytype,
    ) !MerkleTree(H) {
        return MerkleTree(H).commitWithLazyQuotients(allocator, provider, out_column);
    }

    pub fn commitSecureValuesMerkle(
        comptime H: type,
        allocator: std.mem.Allocator,
        values: []const QM31,
    ) !MerkleTree(H).SecureColumnCommitResult {
        return MerkleTree(H).commitSecureValues(allocator, values);
    }
};

// ---------------------------------------------------------------
// Compile-time contract validation
// ---------------------------------------------------------------

const backend = @import("stwo_backend_contracts");

comptime {
    // Validate that CpuBackend satisfies the full backend contract.
    backend.assertBackend(CpuBackend);
}

test "cpu_scalar: CpuBackend satisfies backend contract" {
    comptime backend.assertBackend(CpuBackend);
}

test "cpu_scalar: ColumnType resolves to slices" {
    const ColM31 = CpuBackend.ColumnType(M31);
    const ColQM31 = CpuBackend.ColumnType(QM31);

    // For CPU scalar, columns are plain slices.
    try std.testing.expect(@TypeOf(@as(ColM31, undefined)) == []M31);
    try std.testing.expect(@TypeOf(@as(ColQM31, undefined)) == []QM31);
}

test "cpu_scalar: batchInverse delegates correctly" {
    const allocator = std.testing.allocator;
    const input = try allocator.dupe(M31, &[_]M31{
        M31.fromCanonical(3),
        M31.fromCanonical(7),
        M31.fromCanonical(11),
        M31.fromCanonical(13),
    });
    defer allocator.free(input);

    const result = try CpuBackend.batchInverse(M31, allocator, input);
    defer allocator.free(result);

    // Verify: x * x^-1 == 1
    for (input, result) |x, inv_x| {
        try std.testing.expect(x.mul(inv_x).eql(M31.one()));
    }
}
