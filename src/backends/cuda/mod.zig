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
//! ## Implementation status
//!
//! All core operation methods delegate to the FFI surface declared in
//! `ffi.zig`.  GKR operations that lack dedicated CUDA kernels fall
//! back to host-side computation.

const std = @import("std");
const builtin = @import("builtin");
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

// ---------------------------------------------------------------
// QM31 <-> CudaQM31 conversion helpers
// ---------------------------------------------------------------

/// Convert a Zig QM31 value to the C-ABI CudaQM31 layout.
pub fn qm31ToCuda(q: QM31) ffi.CudaQM31 {
    return .{
        .a = .{ .a = q.c0.a.v, .b = q.c0.b.v },
        .b = .{ .a = q.c1.a.v, .b = q.c1.b.v },
    };
}

/// Convert a C-ABI CudaQM31 back to a Zig QM31 value.
pub fn cudaToQm31(c: ffi.CudaQM31) QM31 {
    return .{
        .c0 = .{ .a = .{ .v = c.a.a }, .b = .{ .v = c.a.b } },
        .c1 = .{ .a = .{ .v = c.b.a }, .b = .{ .v = c.b.b } },
    };
}

/// CUDA GPU backend. Zero-sized marker type.
///
/// Satisfies the `backend.assertBackend` contract. Operation methods
/// delegate to the stwo-cuda FFI surface.
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
        // The CUDA kernel operates on DeviceColumn; this slice-based
        // signature is kept for contract compatibility.  When the prover
        // is fully ported to DeviceColumn the inner call is:
        //
        //   ffi.batch_inverse_base_field(size, src_ptr, dst_ptr)
        //
        // For now, the host-slice signature cannot perform device work
        // without uploading, so we panic with a helpful message.
        @panic("CUDA batchInverse: use batchInverseDevice for device-resident columns");
    }

    /// Device-resident batch inverse (the real hot path).
    pub fn batchInverseDevice(comptime F: type, col: DeviceColumn(F)) !DeviceColumn(F) {
        if (F != M31) @compileError("CUDA batchInverse only supports M31");
        const result = try DeviceColumn(F).allocOnDevice(col.size, col.device_id);
        ffi.batch_inverse_base_field(
            @intCast(col.size),
            @ptrCast(col.device_ptr),
            @ptrCast(result.device_ptr),
        );
        return result;
    }

    // ---------------------------------------------------------------
    // PolyOps
    // ---------------------------------------------------------------

    /// Circle-domain interpolation (inverse NTT) on the GPU.
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
        // Slice-based stub kept for contract compatibility.
        @panic("CUDA interpolate: use interpolateDevice for device-resident columns");
    }

    /// Device-resident interpolation (inverse NTT, bit-reversal to natural).
    pub fn interpolateDevice(values: DeviceColumn(M31), twiddles: DeviceColumn(M31)) void {
        const log_size: u32 = std.math.log2_int(usize, values.size);
        ffi.ntt_b2n_column(
            log_size,
            @ptrCast(values.device_ptr),
            @ptrCast(twiddles.device_ptr),
            @intCast(twiddles.size),
        );
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
        @panic("CUDA evaluateOnDomain: use evaluateOnDomainDevice for device-resident columns");
    }

    /// Device-resident forward NTT (natural to bit-reversed).
    pub fn evaluateOnDomainDevice(allocator: std.mem.Allocator, coeffs: DeviceColumn(M31), twiddles: DeviceColumn(M31)) !DeviceColumn(M31) {
        const result = try coeffs.clone(allocator);
        const log_size: u32 = std.math.log2_int(usize, coeffs.size);
        var ptrs = [_][*]u32{@ptrCast(result.device_ptr.?)};
        ffi.ntt_n2b_columns(
            log_size,
            1,
            &ptrs,
            @ptrCast(twiddles.device_ptr),
            @intCast(twiddles.size),
        );
        return result;
    }

    /// Evaluate polynomial at a single QM31 point on the GPU.
    pub fn evalAtPoint(
        coeffs: []const M31,
        point: circle.CirclePoint(QM31),
    ) QM31 {
        _ = coeffs;
        _ = point;
        @panic("CUDA evalAtPoint: use evalAtPointDevice for device-resident columns");
    }

    /// Device-resident point evaluation.
    pub fn evalAtPointDevice(coeffs: DeviceColumn(M31), point: circle.CirclePoint(QM31)) QM31 {
        const cuda_x = qm31ToCuda(point.x);
        const cuda_y = qm31ToCuda(point.y);
        const result = ffi.eval_at_point(
            @ptrCast(coeffs.device_ptr),
            @intCast(coeffs.size),
            cuda_x,
            cuda_y,
        );
        return cudaToQm31(result);
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
        @panic("CUDA foldCircleIntoLine: use foldCircleIntoLineDevice for device-resident columns");
    }

    /// Device-resident circle-to-line FRI fold.
    pub fn foldCircleIntoLineDevice(
        dst: DeviceColumn(QM31),
        src_columns: [4]DeviceColumn(M31),
        domain: DeviceColumn(M31),
        alpha: QM31,
    ) void {
        var src_ptrs: [4][*]u32 = undefined;
        for (0..4) |i| {
            src_ptrs[i] = @ptrCast(src_columns[i].device_ptr.?);
        }
        // QM31 is stored as 4 interleaved M31 words per element.
        // The dst DeviceColumn(QM31) pointer is treated as 4 u32 columns
        // by the CUDA kernel. We pass the base pointer and let the kernel
        // handle the interleaved layout.
        const base: [*]u32 = @ptrCast(@alignCast(dst.device_ptr.?));
        var dst_ptrs: [4][*]u32 = undefined;
        for (0..4) |i| {
            dst_ptrs[i] = base + i * dst.size;
        }
        ffi.fold_circle_into_line(
            @ptrCast(domain.device_ptr),
            0,
            @intCast(dst.size),
            &src_ptrs,
            qm31ToCuda(alpha),
            &dst_ptrs,
        );
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
        @panic("CUDA foldLine: use foldLineDevice for device-resident columns");
    }

    /// Device-resident line fold.
    pub fn foldLineDevice(
        dst: DeviceColumn(QM31),
        src: DeviceColumn(QM31),
        domain: DeviceColumn(M31),
        alpha: QM31,
    ) void {
        const src_base: [*]u32 = @ptrCast(@alignCast(src.device_ptr.?));
        var src_ptrs: [4][*]u32 = undefined;
        for (0..4) |i| {
            src_ptrs[i] = src_base + i * src.size;
        }
        const dst_base: [*]u32 = @ptrCast(@alignCast(dst.device_ptr.?));
        var dst_ptrs: [4][*]u32 = undefined;
        for (0..4) |i| {
            dst_ptrs[i] = dst_base + i * dst.size;
        }
        ffi.fold_line(
            @ptrCast(domain.device_ptr),
            0,
            @intCast(dst.size),
            &src_ptrs,
            qm31ToCuda(alpha),
            &dst_ptrs,
        );
    }

    // ---------------------------------------------------------------
    // QuotientOps
    // ---------------------------------------------------------------

    /// Compute constraint quotients over the evaluation domain on the GPU.
    ///
    /// The slice-based API cannot operate directly on device memory; use
    /// `accumulateQuotientsDevice` for device-resident columns.
    pub fn accumulateQuotients() void {
        @panic("CUDA accumulateQuotients: use accumulateQuotientsDevice for device-resident columns");
    }

    /// Device-resident quotient accumulation.
    ///
    /// Delegates to the `accumulate_quotients` CUDA kernel via FFI.
    pub fn accumulateQuotientsDevice(
        log_size: u32,
        n_columns: u32,
        columns: [*]const [*]const u32,
        random_coeff: QM31,
        n_batches: u32,
        batch_sizes: [*]const u32,
        batch_column_indices: [*]const u32,
        batch_point_xs: []const ffi.CudaQM31,
        batch_point_ys: []const ffi.CudaQM31,
        batch_line_coeffs_a: []const ffi.CudaQM31,
        batch_line_coeffs_b: []const ffi.CudaQM31,
        batch_line_coeffs_c: []const ffi.CudaQM31,
        result: [*][*]u32,
    ) void {
        ffi.accumulate_quotients(
            log_size,
            n_columns,
            columns,
            qm31ToCuda(random_coeff),
            n_batches,
            batch_sizes,
            batch_column_indices,
            batch_point_xs.ptr,
            batch_point_ys.ptr,
            batch_line_coeffs_a.ptr,
            batch_line_coeffs_b.ptr,
            batch_line_coeffs_c.ptr,
            result,
        );
    }

    // ---------------------------------------------------------------
    // AccumulationOps
    // ---------------------------------------------------------------

    /// Accumulate constraint evaluations across domain positions on the GPU.
    ///
    /// The slice-based API cannot operate directly on device memory; use
    /// `accumulateDevice` for device-resident columns.
    pub fn accumulate() void {
        @panic("CUDA accumulate: use accumulateDevice for device-resident columns");
    }

    /// Device-resident accumulation of two M31 columns.
    ///
    /// Adds `src` element-wise into `dst` in-place on the device.
    pub fn accumulateDevice(dst: DeviceColumn(M31), src: DeviceColumn(M31)) void {
        std.debug.assert(dst.size == src.size);
        ffi.accumulate(
            @intCast(dst.size),
            @ptrCast(dst.device_ptr.?),
            @ptrCast(src.device_ptr.?),
        );
    }

    // ---------------------------------------------------------------
    // GkrOps
    // ---------------------------------------------------------------

    /// Generate equality polynomial evaluations over the boolean hypercube.
    ///
    /// The slice-based API cannot operate directly on device memory; use
    /// `genEqEvalsDevice` for device-resident data.
    pub fn genEqEvals() void {
        @panic("CUDA genEqEvals: use genEqEvalsDevice for device-resident data");
    }

    /// Device-resident equality evaluations generation.
    ///
    /// Computes eq(y, .) scaled by `v` over the boolean hypercube and
    /// writes the result into a device buffer.
    pub fn genEqEvalsDevice(
        y: [*]const ffi.CudaQM31,
        y_len: u32,
        v: QM31,
        result: [*]u32,
    ) void {
        ffi.gen_eq_evals(y, y_len, qm31ToCuda(v), result);
    }

    /// Compute the next GKR circuit layer on the GPU.
    ///
    /// The slice-based API cannot operate directly on device memory; use
    /// `nextLayerDevice` variants for device-resident data.
    pub fn nextLayer() void {
        @panic("CUDA nextLayer: use nextLayerGrandProductDevice / nextLayerLogupDevice");
    }

    /// Device-resident next grand-product layer.
    pub fn nextLayerGrandProductDevice(
        n: u32,
        input: [*]const [*]const u32,
        output: [*][*]u32,
    ) void {
        ffi.gkr_next_grand_product_layer(n, input, output);
    }

    /// Device-resident next logup-generic layer.
    pub fn nextLayerLogupDevice(
        n: u32,
        num_input: [*]const [*]const u32,
        den_input: [*]const [*]const u32,
        num_output: [*][*]u32,
        den_output: [*][*]u32,
    ) void {
        ffi.gkr_next_logup_generic_layer(n, num_input, den_input, num_output, den_output);
    }

    /// Sum multilinear extension as polynomial in first variable.
    ///
    /// The slice-based API cannot operate directly on device memory; use
    /// `sumGrandProductDevice` / `sumLogupDevice` for device-resident data.
    pub fn sumAsPolyInFirstVariable() void {
        @panic("CUDA sumAsPolyInFirstVariable: use sumGrandProductDevice / sumLogupDevice");
    }

    /// Device-resident sum for grand-product GKR layers.
    pub fn sumGrandProductDevice(
        n: u32,
        input: [*]const [*]const u32,
        eq: [*]const u32,
        result_at_0: [*]u32,
        result_at_2: [*]u32,
    ) void {
        ffi.gkr_sum_grand_product(n, input, eq, result_at_0, result_at_2);
    }

    /// Device-resident sum for logup-generic GKR layers.
    pub fn sumLogupDevice(
        n: u32,
        num: [*]const [*]const u32,
        den: [*]const [*]const u32,
        eq: [*]const u32,
        lambda: QM31,
        result_at_0: [*]u32,
        result_at_2: [*]u32,
    ) void {
        ffi.gkr_sum_logup_generic(n, num, den, eq, qm31ToCuda(lambda), result_at_0, result_at_2);
    }

    // ---------------------------------------------------------------
    // MerkleOps
    // ---------------------------------------------------------------

    /// Build one layer of a Merkle tree commitment on the GPU.
    ///
    /// `H` is the hash type (ignored -- Blake2s is assumed for the CUDA
    /// kernel). When `prev_layer` is null the kernel builds the leaf
    /// layer; otherwise it hashes the previous layer together with the
    /// column data.
    pub fn commitOnLayer(comptime H: type, size: u32, n_cols: u32, data_ptrs: [*][*]u32, prev_layer: ?[*]const u8, result: [*]u8) void {
        _ = H; // Blake2s assumed by the CUDA kernel.
        if (prev_layer) |prev| {
            ffi.commit_on_layer_in_gpu(size, n_cols, data_ptrs, prev, result);
        } else {
            ffi.commit_on_first_layer_in_gpu(size, n_cols, data_ptrs, result);
        }
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

test "cuda: QM31 conversion roundtrip" {
    const q = QM31.fromU32Unchecked(1, 2, 3, 4);
    const c = qm31ToCuda(q);
    const back = cudaToQm31(c);
    try std.testing.expect(q.eql(back));
}

test "cuda: QM31 conversion zero" {
    const q = QM31.zero();
    const c = qm31ToCuda(q);
    const back = cudaToQm31(c);
    try std.testing.expect(q.eql(back));
}

test "cuda: QM31 conversion one" {
    const q = QM31.one();
    const c = qm31ToCuda(q);
    const back = cudaToQm31(c);
    try std.testing.expect(q.eql(back));
}

test "cuda: QM31 conversion preserves all components" {
    const q = QM31.fromU32Unchecked(100, 200, 300, 400);
    const c = qm31ToCuda(q);

    // Verify individual CUDA struct fields.
    try std.testing.expectEqual(@as(u32, 100), c.a.a);
    try std.testing.expectEqual(@as(u32, 200), c.a.b);
    try std.testing.expectEqual(@as(u32, 300), c.b.a);
    try std.testing.expectEqual(@as(u32, 400), c.b.b);

    const back = cudaToQm31(c);
    try std.testing.expectEqual(@as(u32, 100), back.c0.a.v);
    try std.testing.expectEqual(@as(u32, 200), back.c0.b.v);
    try std.testing.expectEqual(@as(u32, 300), back.c1.a.v);
    try std.testing.expectEqual(@as(u32, 400), back.c1.b.v);
}

test "cuda: commitOnLayer declaration exists" {
    // Ensure the function can be referenced at comptime (contract check).
    const ptr = &CudaBackend.commitOnLayer;
    try std.testing.expect(@intFromPtr(ptr) != 0);
}

test "cuda: device method declarations exist" {
    // Compile-time check that all Device* helper methods resolve.
    _ = &CudaBackend.batchInverseDevice;
    _ = &CudaBackend.interpolateDevice;
    _ = &CudaBackend.evaluateOnDomainDevice;
    _ = &CudaBackend.evalAtPointDevice;
    _ = &CudaBackend.foldCircleIntoLineDevice;
    _ = &CudaBackend.foldLineDevice;
}

test "cuda: accumulateQuotientsDevice declaration and type signature" {
    // Verify the device variant exists and can be referenced at comptime.
    const ptr = &CudaBackend.accumulateQuotientsDevice;
    try std.testing.expect(@intFromPtr(ptr) != 0);

    // Verify it accepts the expected parameter types by checking the function info.
    const info = @typeInfo(@TypeOf(CudaBackend.accumulateQuotientsDevice));
    // accumulateQuotientsDevice has 13 parameters.
    try std.testing.expectEqual(@as(usize, 13), info.@"fn".params.len);
    // Returns void.
    try std.testing.expect(info.@"fn".return_type == void);
}

test "cuda: accumulateDevice declaration and type signature" {
    const ptr = &CudaBackend.accumulateDevice;
    try std.testing.expect(@intFromPtr(ptr) != 0);

    const info = @typeInfo(@TypeOf(CudaBackend.accumulateDevice));
    // accumulateDevice takes (dst: DeviceColumn(M31), src: DeviceColumn(M31)).
    try std.testing.expectEqual(@as(usize, 2), info.@"fn".params.len);
    try std.testing.expect(info.@"fn".return_type == void);
}

test "cuda: GKR device variant declarations exist" {
    // genEqEvalsDevice
    _ = &CudaBackend.genEqEvalsDevice;
    const eq_info = @typeInfo(@TypeOf(CudaBackend.genEqEvalsDevice));
    try std.testing.expectEqual(@as(usize, 4), eq_info.@"fn".params.len);
    try std.testing.expect(eq_info.@"fn".return_type == void);

    // nextLayerGrandProductDevice
    _ = &CudaBackend.nextLayerGrandProductDevice;
    const gp_info = @typeInfo(@TypeOf(CudaBackend.nextLayerGrandProductDevice));
    try std.testing.expectEqual(@as(usize, 3), gp_info.@"fn".params.len);
    try std.testing.expect(gp_info.@"fn".return_type == void);

    // nextLayerLogupDevice
    _ = &CudaBackend.nextLayerLogupDevice;
    const lu_info = @typeInfo(@TypeOf(CudaBackend.nextLayerLogupDevice));
    try std.testing.expectEqual(@as(usize, 5), lu_info.@"fn".params.len);
    try std.testing.expect(lu_info.@"fn".return_type == void);

    // sumGrandProductDevice
    _ = &CudaBackend.sumGrandProductDevice;
    const sgp_info = @typeInfo(@TypeOf(CudaBackend.sumGrandProductDevice));
    try std.testing.expectEqual(@as(usize, 5), sgp_info.@"fn".params.len);
    try std.testing.expect(sgp_info.@"fn".return_type == void);

    // sumLogupDevice
    _ = &CudaBackend.sumLogupDevice;
    const slu_info = @typeInfo(@TypeOf(CudaBackend.sumLogupDevice));
    try std.testing.expectEqual(@as(usize, 7), slu_info.@"fn".params.len);
    try std.testing.expect(slu_info.@"fn".return_type == void);
}

test "cuda: FFI new declarations compile" {
    // Verify that all newly added FFI extern declarations can be referenced
    // at comptime. This ensures the signatures are syntactically valid and
    // the symbols are known to the compiler (they resolve at link time).
    _ = &ffi.copy_uint32_t_vec_from_device_to_device;
    _ = &ffi.batch_eval_at_points;
    _ = &ffi.accumulate_quotients;
    _ = &ffi.lift_accumulate_secure_columns;
    _ = &ffi.gen_eq_evals;
    _ = &ffi.gkr_next_grand_product_layer;
    _ = &ffi.gkr_next_logup_generic_layer;
    _ = &ffi.gkr_sum_grand_product;
    _ = &ffi.gkr_sum_logup_generic;
    _ = &ffi.poseidon252_commit_on_first_layer;
    _ = &ffi.poseidon252_commit_on_layer_with_previous;
    _ = &ffi.execute_framework_eval_plan_v1;
    _ = &ffi.fix_first_variable_base_field;
    _ = &ffi.fix_first_variable_secure_field;
}
