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
const core_poly = @import("stwo_core").poly;
const prover_impl = @import("stwo_prover_impl");
const lifted_merkle = @import("stwo_prover_impl").vcs_lifted.prover;
const secure_composition = @import("secure_composition.zig");

const M31 = m31_mod.M31;
const CM31 = cm31_mod.CM31;
const QM31 = qm31_mod.QM31;

/// CPU scalar backend. Zero-sized marker type.
///
/// Satisfies the full `backend.assertBackend` contract by delegating
/// to the existing scalar implementations in `core/` and `prover/`.
pub const CpuBackend = struct {
    pub const combined_commit_min_columns: usize = 65;
    pub const combined_commit_max_columns: usize = 256;
    pub const combined_base_in_place = true;

    pub fn warmup() !void {}

    pub fn computeCompositionEvaluation(
        allocator: std.mem.Allocator,
        components: []const @import("stwo_prover_impl").air.component_prover.ComponentProver,
        random_coeff: QM31,
        trace: *const @import("stwo_prover_impl").air.component_prover.Trace,
        residency_handles: []const ?*anyopaque,
        composition_twiddles: ?@import("stwo_prover_impl").poly.twiddles.TwiddleTree([]const M31),
    ) !?@import("stwo_prover_impl").secure_column.SecureColumnByCoords {
        _ = residency_handles;
        _ = composition_twiddles;
        return secure_composition.evaluateLargeRecurrenceComposition(
            allocator,
            components,
            random_coeff,
            trace,
        );
    }

    /// Interpolates the four independent secure-field coordinates in place
    /// on the existing prover pool. The generic path duplicates and transforms
    /// them serially; owned composition evaluations need neither cost.
    pub fn interpolateSecureComposition(
        allocator: std.mem.Allocator,
        values: *prover_impl.secure_column.SecureColumnByCoords,
        domain: core_poly.circle.domain.CircleDomain,
        twiddle_tree: prover_impl.poly.twiddles.TwiddleTree([]const M31),
    ) !bool {
        _ = allocator;
        for (values.columns) |coordinate| {
            if (coordinate.len != domain.size()) return false;
        }

        const Job = struct {
            values: []M31,
            domain: core_poly.circle.domain.CircleDomain,
            twiddle_tree: prover_impl.poly.twiddles.TwiddleTree([]const M31),
            failure: ?anyerror = null,

            fn run(job: *@This()) void {
                var batch = [_][]M31{job.values};
                prover_impl.poly.circle.poly.interpolateBuffersWithTwiddles(
                    &batch,
                    job.domain,
                    job.twiddle_tree,
                ) catch |err| {
                    job.failure = err;
                };
            }
        };

        var jobs: [qm31_mod.SECURE_EXTENSION_DEGREE]Job = undefined;
        for (values.columns, &jobs) |coordinate, *job| {
            job.* = .{
                .values = coordinate,
                .domain = domain,
                .twiddle_tree = twiddle_tree,
            };
        }

        if (prover_impl.work_pool.getGlobalPool()) |pool| {
            var wait_group: std.Thread.WaitGroup = .{};
            for (jobs[1..]) |*job| pool.spawnWg(&wait_group, Job.run, .{job});
            Job.run(&jobs[0]);
            wait_group.wait();
        } else {
            for (&jobs) |*job| Job.run(job);
        }
        for (jobs) |job| if (job.failure) |err| return err;
        return true;
    }

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

    /// Retains large CPU commitment columns in the same cache-skewed backing
    /// layout used by the shared-memory Metal path while preserving one FFT
    /// task per column on the global worker pool.
    pub fn interpolateAndEvaluateCircleBuffers(
        allocator: std.mem.Allocator,
        source_values: []const []const M31,
        base_values: []const []M31,
        extended_values: []const []M31,
        transform_buffer: []M31,
        extended_start: usize,
        extended_stride: usize,
        base_domain: anytype,
        base_twiddles: anytype,
        extended_domain: anytype,
        extended_twiddles: anytype,
    ) !void {
        _ = transform_buffer;
        _ = extended_start;
        _ = extended_stride;
        if (source_values.len == 0 or source_values.len != base_values.len or
            base_values.len != extended_values.len)
        {
            return error.InvalidColumns;
        }

        const prover = @import("stwo_prover_impl");
        const BaseDomain = @TypeOf(base_domain);
        const BaseTwiddles = @TypeOf(base_twiddles);
        const ExtendedDomain = @TypeOf(extended_domain);
        const ExtendedTwiddles = @TypeOf(extended_twiddles);
        const Job = struct {
            base: []M31,
            extended: []M31,
            base_domain: BaseDomain,
            base_twiddles: BaseTwiddles,
            extended_domain: ExtendedDomain,
            extended_twiddles: ExtendedTwiddles,
            err: ?anyerror = null,

            fn run(job: *@This()) void {
                var base_batch = [_][]M31{job.base};
                prover.poly.circle.poly.interpolateBuffersWithTwiddles(
                    &base_batch,
                    job.base_domain,
                    job.base_twiddles,
                ) catch |err| {
                    job.err = err;
                    return;
                };
                @memcpy(job.extended[0..job.base.len], job.base);
                var extended_batch = [_][]M31{job.extended};
                prover.poly.circle.poly.evaluateExtensionBuffersWithTwiddles(
                    &extended_batch,
                    job.extended_domain,
                    job.extended_twiddles,
                ) catch |err| {
                    job.err = err;
                };
            }
        };

        const jobs = try allocator.alloc(Job, source_values.len);
        defer allocator.free(jobs);
        for (source_values, base_values, extended_values, jobs) |source, base, extended, *job| {
            if (source.ptr != base.ptr) @memcpy(base, source);
            job.* = .{
                .base = base,
                .extended = extended,
                .base_domain = base_domain,
                .base_twiddles = base_twiddles,
                .extended_domain = extended_domain,
                .extended_twiddles = extended_twiddles,
            };
        }

        if (prover.work_pool.getGlobalPool()) |pool| {
            var wait_group: std.Thread.WaitGroup = .{};
            for (jobs[1..]) |*job| pool.spawnWg(&wait_group, Job.run, .{job});
            Job.run(&jobs[0]);
            wait_group.wait();
        } else {
            for (jobs) |*job| Job.run(job);
        }
        for (jobs) |job| if (job.err) |err| return err;
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
