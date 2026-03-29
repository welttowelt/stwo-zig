//! CUDA GPU backend for stwo-zig.
//!
//! This backend accelerates the prover by offloading field arithmetic,
//! polynomial evaluation, FRI folding, and Merkle commitment to one or
//! more NVIDIA GPUs via the stwo-cuda native library.
//!
//! ## Column type
//!
//! `CudaBackend.ColumnType(M31) = DeviceColumn(M31)` -- an opaque
//! handle to device-resident memory.
//!
//! ## Current status
//!
//! **Skeleton** -- all operation methods panic at runtime with a
//! "link libstwo_cuda" message. The types compile on any host so that
//! CI and non-GPU contributors can build and test the rest of the tree.

const std = @import("std");
const m31_mod = @import("../../core/fields/m31.zig");
const cm31_mod = @import("../../core/fields/cm31.zig");
const qm31_mod = @import("../../core/fields/qm31.zig");
const circle = @import("../../core/circle.zig");
const core_fri = @import("../../core/fri.zig");

const M31 = m31_mod.M31;
const CM31 = cm31_mod.CM31;
const QM31 = qm31_mod.QM31;

pub const device_column = @import("device_column.zig");
pub const ffi = @import("ffi.zig");
pub const device_context = @import("device_context.zig");

pub const DeviceColumn = device_column.DeviceColumn;
pub const DeviceContext = device_context.DeviceContext;

/// CUDA GPU backend. Zero-sized marker type.
///
/// Satisfies the `backend.assertBackend` contract. All operation
/// methods are stubs that will be wired to FFI calls once
/// `libstwo_cuda.a` is available at link time.
pub const CudaBackend = struct {
    // ---------------------------------------------------------------
    // ColumnOps
    // ---------------------------------------------------------------

    /// Column storage is a device-resident buffer of field elements.
    pub fn ColumnType(comptime F: type) type {
        return DeviceColumn(F);
    }

    // ---------------------------------------------------------------
    // FieldOps
    // ---------------------------------------------------------------

    /// Montgomery batch inverse on a device column.
    pub fn batchInverse(
        comptime F: type,
        allocator: std.mem.Allocator,
        column: []const F,
    ) ![]F {
        _ = allocator;
        _ = column;
        @panic("CUDA backend: link libstwo_cuda to use batchInverse");
    }

    // ---------------------------------------------------------------
    // PolyOps
    // ---------------------------------------------------------------

    /// Circle-domain interpolation (FFT-based) on the GPU.
    pub fn interpolate(
        allocator: std.mem.Allocator,
        values: []M31,
        domain: anytype,
        twiddle_tree: anytype,
    ) !void {
        _ = allocator;
        _ = values;
        _ = domain;
        _ = twiddle_tree;
        @panic("CUDA backend: link libstwo_cuda to use interpolate");
    }

    /// Evaluate polynomial on extended domain on the GPU.
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
        @panic("CUDA backend: link libstwo_cuda to use evaluateOnDomain");
    }

    /// Evaluate polynomial at a single QM31 point on the GPU.
    pub fn evalAtPoint(
        coeffs: []const M31,
        point: circle.CirclePoint(QM31),
    ) QM31 {
        _ = coeffs;
        _ = point;
        @panic("CUDA backend: link libstwo_cuda to use evalAtPoint");
    }

    // ---------------------------------------------------------------
    // FriOps
    // ---------------------------------------------------------------

    /// Fold a circle evaluation into a line evaluation on the GPU.
    pub fn foldCircleIntoLine(
        allocator: std.mem.Allocator,
        dst: []QM31,
        src_columns: [qm31_mod.SECURE_EXTENSION_DEGREE][]const M31,
        src_domain: anytype,
        alpha: QM31,
        workspace: *core_fri.FoldCircleWorkspace,
    ) !void {
        _ = allocator;
        _ = dst;
        _ = src_columns;
        _ = src_domain;
        _ = alpha;
        _ = workspace;
        @panic("CUDA backend: link libstwo_cuda to use foldCircleIntoLine");
    }

    /// Fold a line evaluation to half its size on the GPU.
    pub fn foldLine(
        allocator: std.mem.Allocator,
        eval: []QM31,
        domain: anytype,
        alpha: QM31,
        workspace: *core_fri.FoldLineWorkspace,
    ) !core_fri.FoldLineResult {
        _ = allocator;
        _ = eval;
        _ = domain;
        _ = alpha;
        _ = workspace;
        @panic("CUDA backend: link libstwo_cuda to use foldLine");
    }

    // ---------------------------------------------------------------
    // QuotientOps
    // ---------------------------------------------------------------

    /// Compute constraint quotients over the evaluation domain on the GPU.
    pub fn accumulateQuotients() void {
        @panic("CUDA backend: link libstwo_cuda to use accumulateQuotients");
    }

    // ---------------------------------------------------------------
    // AccumulationOps
    // ---------------------------------------------------------------

    /// Accumulate constraint evaluations across domain positions on the GPU.
    pub fn accumulate() void {
        @panic("CUDA backend: link libstwo_cuda to use accumulate");
    }

    // ---------------------------------------------------------------
    // GkrOps
    // ---------------------------------------------------------------

    /// Generate equality polynomial evaluations over the boolean hypercube.
    pub fn genEqEvals() void {
        @panic("CUDA backend: link libstwo_cuda to use genEqEvals");
    }

    /// Compute the next GKR circuit layer on the GPU.
    pub fn nextLayer() void {
        @panic("CUDA backend: link libstwo_cuda to use nextLayer");
    }

    /// Sum multilinear extension as polynomial in first variable.
    pub fn sumAsPolyInFirstVariable() void {
        @panic("CUDA backend: link libstwo_cuda to use sumAsPolyInFirstVariable");
    }

    // ---------------------------------------------------------------
    // MerkleOps
    // ---------------------------------------------------------------

    /// Build one layer of a Merkle tree commitment on the GPU.
    pub fn commitOnLayer() void {
        @panic("CUDA backend: link libstwo_cuda to use commitOnLayer");
    }
};

// ---------------------------------------------------------------
// Compile-time contract validation
// ---------------------------------------------------------------

const backend = @import("../../backend/mod.zig");

comptime {
    // Validate that CudaBackend satisfies the full backend contract.
    backend.assertBackend(CudaBackend);
}

// ---------------------------------------------------------------
// Tests
// ---------------------------------------------------------------

test "cuda: CudaBackend satisfies backend contract" {
    comptime backend.assertBackend(CudaBackend);
}

test "cuda: ColumnType resolves to DeviceColumn" {
    const ColM31 = CudaBackend.ColumnType(M31);
    const ColQM31 = CudaBackend.ColumnType(QM31);

    // For CUDA, columns are DeviceColumn wrappers.
    try std.testing.expect(ColM31 == DeviceColumn(M31));
    try std.testing.expect(ColQM31 == DeviceColumn(QM31));
}

test "cuda: DeviceContext stub initialises and deinits" {
    var ctx = try DeviceContext.init(std.testing.allocator);
    defer ctx.deinit();

    try std.testing.expectEqual(@as(u32, 0), ctx.active_device);
    try std.testing.expectEqual(@as(usize, 1), ctx.devices.len);
}

test "cuda: FFI types have expected layout" {
    // CudaQM31 must be 16 bytes (4 x u32) for C ABI compatibility.
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(ffi.CudaQM31));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(ffi.CudaCM31));
}
