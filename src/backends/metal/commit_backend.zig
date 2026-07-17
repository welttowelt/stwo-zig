const std = @import("std");
const cpu = @import("../cpu_scalar/mod.zig").CpuBackend;
const commit_policy = @import("commit_policy.zig");
const merkle = @import("../../prover/vcs_lifted/prover.zig");
const metal_merkle = @import("merkle_tree.zig");
const shared_runtime = @import("shared_runtime.zig");
const telemetry = @import("telemetry.zig");

pub fn warmup() !void {
    return MetalCommitBackend.warmup();
}

pub fn initializeRuntime(
    allocator: std.mem.Allocator,
    policy: MetalCommitBackend.RuntimeInitializationPolicy,
) !void {
    return MetalCommitBackend.initializeRuntime(allocator, policy);
}

pub fn runtimeLifecycleSnapshot() MetalCommitBackend.RuntimeLifecycleSnapshot {
    return MetalCommitBackend.runtimeLifecycleSnapshot();
}

pub fn shutdown() MetalCommitBackend.ShutdownError!void {
    return MetalCommitBackend.shutdown();
}

/// CPU-compatible prover backend whose commitment constructor is Metal.
///
/// The remaining operation methods are intentionally delegated to the CPU
/// backend until their transaction-level Metal replacements are resident.
pub const MetalCommitBackend = struct {
    pub const rawQuotientInputs = true;
    pub const TelemetrySnapshot = telemetry.Snapshot;
    pub const TelemetryDelta = telemetry.Delta;
    pub const TelemetryError = error{RuntimeNotInitialized};
    pub const ShutdownError = shared_runtime.ShutdownError;
    pub const RuntimeLifecycleSnapshot = shared_runtime.LifecycleSnapshot;
    pub const RuntimeInitializationPolicy = shared_runtime.InitializationPolicy;
    /// Streaming commitment currently owns a CPU leaf-hasher state machine.
    /// Materialize the prepared LDE columns once so Metal can consume the
    /// complete tree in a single command buffer.
    pub const preferMonolithicCommit = true;

    pub fn warmup() !void {
        var lease = try shared_runtime.acquire();
        defer lease.deinit();
    }

    pub fn initializeRuntime(
        allocator: std.mem.Allocator,
        policy: RuntimeInitializationPolicy,
    ) !void {
        return shared_runtime.initialize(allocator, policy);
    }

    /// Reads counters and cache statistics from the one shared backend
    /// runtime. Snapshotting before warmup fails instead of creating a device.
    pub fn telemetrySnapshot() TelemetryError!TelemetrySnapshot {
        var lease = try shared_runtime.acquireExisting();
        defer lease.deinit();
        return telemetry.capture(lease.runtime.pipelineCacheStats());
    }

    /// Reports process-wide runtime ownership without creating a Metal device.
    pub fn runtimeLifecycleSnapshot() RuntimeLifecycleSnapshot {
        return shared_runtime.lifecycleSnapshot();
    }

    /// Releases the process-wide runtime at a quiescent request boundary.
    ///
    /// In-flight calls and live Metal-backed columns, trees, or buffers make
    /// this fail closed rather than invalidating their runtime or device.
    pub fn shutdown() ShutdownError!void {
        return shared_runtime.shutdown();
    }

    pub fn recordSampledValueFallback() void {
        telemetry.record(.cpu_sampled_value_evaluation);
    }

    pub fn MerkleTree(comptime H: type) type {
        return metal_merkle.MetalMerkleTree(H);
    }

    pub fn allocateSecureColumn(column_len: usize) !@import("../../prover/secure_column.zig").SecureColumnByCoords {
        const M31 = @import("../../core/fields/m31.zig").M31;
        const DEGREE = @import("../../core/fields/qm31.zig").SECURE_EXTENSION_DEGREE;
        var lease = try shared_runtime.acquire();
        defer lease.deinit();
        var buffer = try lease.runtime.allocateResidentBuffer(column_len * DEGREE * @sizeOf(M31));
        errdefer buffer.deinit();
        const values: [*]M31 = @ptrCast(@alignCast(buffer.contents));
        var columns: [DEGREE][]M31 = undefined;
        for (0..DEGREE) |coordinate| {
            columns[coordinate] = values[coordinate * column_len .. (coordinate + 1) * column_len];
        }
        shared_runtime.retainResidentResource();
        errdefer shared_runtime.releaseResidentResource();
        return @import("../../prover/secure_column.zig").SecureColumnByCoords.initResident(
            columns,
            .{
                .handle = buffer.handle,
                .destroyFn = shared_runtime.destroyResidentBuffer,
            },
        );
    }

    pub fn allocateLineEvaluation(
        domain: @import("../../core/poly/line.zig").LineDomain,
    ) !@import("../../prover/line.zig").LineEvaluation {
        const QM31 = @import("../../core/fields/qm31.zig").QM31;
        var lease = try shared_runtime.acquire();
        defer lease.deinit();
        var buffer = try lease.runtime.allocateResidentBuffer(domain.size() * @sizeOf(QM31));
        errdefer buffer.deinit();
        const values: [*]QM31 = @ptrCast(@alignCast(buffer.contents));
        shared_runtime.retainResidentResource();
        errdefer shared_runtime.releaseResidentResource();
        return @import("../../prover/line.zig").LineEvaluation.initResident(
            domain,
            values[0..domain.size()],
            .{
                .handle = buffer.handle,
                .destroyFn = shared_runtime.destroyResidentBuffer,
            },
        );
    }

    pub fn secureColumnFromLine(
        evaluation: @import("../../prover/line.zig").LineEvaluation,
    ) !@import("../../prover/secure_column.zig").SecureColumnByCoords {
        var column = try allocateSecureColumn(evaluation.len());
        errdefer column.deinit(std.heap.page_allocator);
        const source = std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(evaluation.values));
        const destination = std.mem.bytesAsSlice(
            u32,
            std.mem.sliceAsBytes(column.columns[0].ptr[0 .. evaluation.len() * 4]),
        );
        var lease = try shared_runtime.acquire();
        defer lease.deinit();
        const gpu_ms = try lease.runtime.qm31ToCoordinates(
            source.ptr,
            @intCast(evaluation.len()),
            destination.ptr,
        );
        telemetry.record(.metal_qm31_coordinate_dispatch);
        std.log.debug("Metal QM31 coordinate conversion: {d:.3}ms", .{gpu_ms});
        return column;
    }

    /// Places coordinate conversion where the immediately following Merkle
    /// commitment will execute. Small host commitments avoid a synchronous GPU
    /// dispatch and allocate their coordinate planes from the proof allocator.
    pub fn secureColumnForMerkle(
        allocator: std.mem.Allocator,
        evaluation: @import("../../prover/line.zig").LineEvaluation,
    ) !@import("../../prover/secure_column.zig").SecureColumnByCoords {
        if (!commit_policy.secureColumnUsesResidentMerkle(evaluation.len())) {
            return @import("../../prover/secure_column.zig").SecureColumnByCoords.fromSecureSlice(
                allocator,
                evaluation.values,
            );
        }
        return secureColumnFromLine(evaluation);
    }

    pub fn commitMerkle(
        comptime H: type,
        allocator: std.mem.Allocator,
        columns: []const []const @import("../../core/fields/m31.zig").M31,
    ) !MerkleTree(H) {
        var cells: usize = 0;
        for (columns) |column| cells = try std.math.add(usize, cells, column.len);
        if (!commit_policy.usesResidentMerkle(cells)) {
            const host_tree = try merkle.MerkleProverLifted(H).commit(allocator, columns);
            telemetry.record(.host_merkle_commit);
            telemetry.record(.cpu_small_merkle_commit);
            return MerkleTree(H).fromHost(host_tree);
        }
        var lease = try shared_runtime.acquire();
        defer lease.deinit();
        const resident_tree = try MerkleTree(H).commitShared(lease.runtime, allocator, columns);
        telemetry.record(.resident_merkle_commit);
        return resident_tree;
    }

    pub fn adoptHostMerkle(
        comptime H: type,
        tree: merkle.MerkleProverLifted(H),
    ) MerkleTree(H) {
        telemetry.record(.host_merkle_commit);
        telemetry.record(.cpu_streaming_merkle_commit);
        return MerkleTree(H).fromHost(tree);
    }

    pub fn computeLazyQuotients(
        allocator: std.mem.Allocator,
        provider: anytype,
        out: anytype,
    ) !void {
        var lease = try shared_runtime.acquire();
        defer lease.deinit();
        const gpu_ms = try lease.runtime.computeQuotients(allocator, provider, out);
        telemetry.record(.metal_quotient_dispatch);
        std.log.debug("Metal quotient kernel: {d:.3}ms", .{gpu_ms});
    }

    /// Produces the first FRI quotient column and its lifted Merkle tree in one
    /// command buffer. The caller retains the resident column independently;
    /// the returned tree owns only its hash layers after the terminal wait.
    pub fn commitLazyMerkle(
        comptime H: type,
        allocator: std.mem.Allocator,
        provider: anytype,
        out: anytype,
    ) !MerkleTree(H) {
        if (!commit_policy.quotientUsesResidentMerkle(provider.lifting_log_size)) {
            try computeLazyQuotients(allocator, provider, out);
            const columns = [_][]const @import("../../core/fields/m31.zig").M31{
                out.columns[0],
                out.columns[1],
                out.columns[2],
                out.columns[3],
            };
            return commitMerkle(H, allocator, columns[0..]);
        }
        var lease = try shared_runtime.acquire();
        defer lease.deinit();
        const result = try lease.runtime.computeQuotientsAndCommit(
            allocator,
            provider,
            out,
            H.leafSeed(),
            H.nodeSeed(),
            H.domainPrefixBytes(),
        );
        telemetry.record(.metal_quotient_dispatch);
        telemetry.record(.resident_merkle_commit);
        std.log.debug("Metal quotient + Merkle epoch: {d:.3}ms", .{result.gpu_ms});
        return MerkleTree(H).fromSharedRuntime(result.tree);
    }

    pub fn evaluateCoefficientPlans(
        allocator: std.mem.Allocator,
        coefficients: anytype,
        tree_values: anytype,
        plans: anytype,
    ) !void {
        if (plans.len == 0) return;
        var lease = try shared_runtime.acquire();
        defer lease.deinit();
        const gpu_ms = try lease.runtime.evaluateCoefficientPlans(
            allocator,
            coefficients,
            tree_values,
            plans,
        );
        telemetry.record(.metal_sampled_value_dispatch);
        std.log.debug("Metal sampled-value kernel: {d:.3}ms", .{gpu_ms});
    }

    pub fn interpolateCircleBuffers(
        allocator: std.mem.Allocator,
        values: []const []@import("../../core/fields/m31.zig").M31,
        domain: @import("../../core/poly/circle/domain.zig").CircleDomain,
        twiddle_tree: @import("../../prover/poly/twiddles.zig").TwiddleTree([]const @import("../../core/fields/m31.zig").M31),
    ) !void {
        if (domain.logSize() < 3) {
            try @import("../../prover/poly/circle/poly.zig").interpolateBuffersWithTwiddles(values, domain, twiddle_tree);
            telemetry.record(.cpu_small_circle_interpolation);
            return;
        }
        var lease = try shared_runtime.acquire();
        defer lease.deinit();
        _ = try lease.runtime.transformCircle(
            allocator,
            values,
            twiddle_tree.itwiddles,
            domain.logSize(),
            true,
        );
        telemetry.record(.metal_circle_transform_dispatch);
    }

    pub fn evaluateCircleBuffers(
        allocator: std.mem.Allocator,
        values: []const []@import("../../core/fields/m31.zig").M31,
        domain: @import("../../core/poly/circle/domain.zig").CircleDomain,
        twiddle_tree: @import("../../prover/poly/twiddles.zig").TwiddleTree([]const @import("../../core/fields/m31.zig").M31),
    ) !void {
        if (domain.logSize() < 3) {
            try @import("../../prover/poly/circle/poly.zig").evaluateBuffersWithTwiddles(values, domain, twiddle_tree);
            telemetry.record(.cpu_small_circle_evaluation);
            return;
        }
        var lease = try shared_runtime.acquire();
        defer lease.deinit();
        _ = try lease.runtime.transformCircle(
            allocator,
            values,
            twiddle_tree.twiddles,
            domain.logSize(),
            false,
        );
        telemetry.record(.metal_circle_transform_dispatch);
    }

    pub fn interpolateAndEvaluateCircleBuffers(
        allocator: std.mem.Allocator,
        source_values: []const []const @import("../../core/fields/m31.zig").M31,
        base_values: []const []@import("../../core/fields/m31.zig").M31,
        extended_values: []const []@import("../../core/fields/m31.zig").M31,
        base_domain: @import("../../core/poly/circle/domain.zig").CircleDomain,
        base_twiddles: @import("../../prover/poly/twiddles.zig").TwiddleTree([]const @import("../../core/fields/m31.zig").M31),
        extended_domain: @import("../../core/poly/circle/domain.zig").CircleDomain,
        extended_twiddles: @import("../../prover/poly/twiddles.zig").TwiddleTree([]const @import("../../core/fields/m31.zig").M31),
    ) !void {
        if (base_domain.logSize() < 3) {
            for (source_values, base_values) |source, base| @memcpy(base, source);
            try @import("../../prover/poly/circle/poly.zig").interpolateBuffersWithTwiddles(
                base_values,
                base_domain,
                base_twiddles,
            );
            for (base_values, extended_values) |base, extended| {
                @memcpy(extended[0..base.len], base);
                @memset(extended[base.len..], @import("../../core/fields/m31.zig").M31.zero());
            }
            try @import("../../prover/poly/circle/poly.zig").evaluateBuffersWithTwiddles(
                extended_values,
                extended_domain,
                extended_twiddles,
            );
            telemetry.record(.cpu_small_circle_lde);
            return;
        }
        var lease = try shared_runtime.acquire();
        defer lease.deinit();
        const gpu_ms = try lease.runtime.transformCircleLde(
            allocator,
            source_values,
            base_values,
            extended_values,
            base_twiddles.itwiddles,
            extended_twiddles.twiddles,
            base_domain.logSize(),
            extended_domain.logSize(),
        );
        telemetry.record(.metal_circle_lde_dispatch);
        std.log.debug("Metal circle IFFT+RFFT: {d:.3}ms", .{gpu_ms});
    }

    pub const ColumnType = cpu.ColumnType;
    pub const batchInverse = cpu.batchInverse;
    pub const interpolate = cpu.interpolate;
    pub const evaluateOnDomain = cpu.evaluateOnDomain;
    pub const evalAtPoint = cpu.evalAtPoint;
    pub fn foldCircleIntoLine(
        allocator: std.mem.Allocator,
        dst: []@import("../../core/fields/qm31.zig").QM31,
        src_columns: [4][]const @import("../../core/fields/m31.zig").M31,
        src_domain: @import("../../core/poly/circle/domain.zig").CircleDomain,
        alpha: @import("../../core/fields/qm31.zig").QM31,
        workspace: *@import("../../core/fri.zig").FoldCircleWorkspace,
    ) !void {
        const M31 = @import("../../core/fields/m31.zig").M31;
        const core_utils = @import("../../core/utils.zig");
        const fields = @import("../../core/fields/mod.zig");
        try workspace.ensureCapacity(allocator, dst.len);
        const py = workspace.py_values[0..dst.len];
        const inverse_y = workspace.inv_py_values[0..dst.len];
        const log_size = src_domain.logSize();
        for (py, 0..) |*value, index| {
            value.* = src_domain.at(core_utils.bitReverseIndex(index << 1, log_size)).y;
        }
        try fields.batchInverseInPlace(M31, py, inverse_y);
        const alpha_coords = alpha.toM31Array();
        const alpha_words = [4]u32{ alpha_coords[0].v, alpha_coords[1].v, alpha_coords[2].v, alpha_coords[3].v };
        const source_words = std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(src_columns[0].ptr[0 .. src_columns[0].len * 4]));
        const destination_words = std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(dst));
        const inverse_words = std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(inverse_y));
        var lease = try shared_runtime.acquire();
        defer lease.deinit();
        const gpu_ms = try lease.runtime.foldFriCircle(
            source_words.ptr,
            @intCast(src_columns[0].len),
            inverse_words,
            alpha_words,
            destination_words.ptr,
        );
        telemetry.record(.metal_fri_circle_fold_dispatch);
        std.log.debug("Metal FRI circle fold: {d:.3}ms", .{gpu_ms});
    }

    pub fn foldLineEvaluationN(
        allocator: std.mem.Allocator,
        evaluation: @import("../../prover/line.zig").LineEvaluation,
        alpha: @import("../../core/fields/qm31.zig").QM31,
        workspace: *@import("../../core/fri.zig").FoldLineWorkspace,
        n_folds: u32,
    ) !@import("../../prover/line.zig").LineEvaluation {
        const M31 = @import("../../core/fields/m31.zig").M31;
        const core_utils = @import("../../core/utils.zig");
        const fields = @import("../../core/fields/mod.zig");
        var current = evaluation;
        var owns_current = false;
        var current_alpha = alpha;
        errdefer if (owns_current) current.deinit(allocator);
        var step: u32 = 0;
        while (step < n_folds) : (step += 1) {
            const destination_domain = current.domain().double();
            var next = try allocateLineEvaluation(destination_domain);
            errdefer next.deinit(allocator);
            const destination_len = next.len();
            try workspace.ensureCapacity(allocator, destination_len);
            const x = workspace.x_values[0..destination_len];
            const inverse_x = workspace.inv_x_values[0..destination_len];
            const log_size = current.domain().logSize();
            for (x, 0..) |*value, index| {
                value.* = current.domain().at(core_utils.bitReverseIndex(index << 1, log_size));
            }
            try fields.batchInverseInPlace(M31, x, inverse_x);
            const source_words = std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(current.values));
            const destination_words = std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(@constCast(next.values)));
            const inverse_words = std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(inverse_x));
            const alpha_coords = current_alpha.toM31Array();
            const alpha_words = [4]u32{ alpha_coords[0].v, alpha_coords[1].v, alpha_coords[2].v, alpha_coords[3].v };
            var lease = try shared_runtime.acquire();
            defer lease.deinit();
            const gpu_ms = try lease.runtime.foldFriLine(
                source_words.ptr,
                @intCast(current.len()),
                inverse_words,
                alpha_words,
                destination_words.ptr,
            );
            telemetry.record(.metal_fri_line_fold_dispatch);
            std.log.debug("Metal FRI line fold: {d:.3}ms", .{gpu_ms});
            if (owns_current) current.deinit(allocator);
            current = next;
            owns_current = true;
            current_alpha = current_alpha.square();
        }
        return current;
    }

    /// Folds a production-size single-fold evaluation and commits the next FRI
    /// layer in one Metal submission. Small, non-resident, and multi-fold
    /// inputs retain the established fallback until the scheduler supplies
    /// explicit next-layer packing metadata.
    pub fn foldLineAndCommitNext(
        comptime H: type,
        allocator: std.mem.Allocator,
        evaluation: @import("../../prover/line.zig").LineEvaluation,
        alpha: @import("../../core/fields/qm31.zig").QM31,
        workspace: *@import("../../core/fri.zig").FoldLineWorkspace,
        n_folds: u32,
    ) !@import("../../backend/fri_ops.zig").FoldLineAndCommitResult(MerkleTree(H)) {
        const M31 = @import("../../core/fields/m31.zig").M31;
        const core_utils = @import("../../core/utils.zig");
        const fields = @import("../../core/fields/mod.zig");
        const secure_column = @import("../../prover/secure_column.zig");
        if (n_folds == 0 or n_folds >= @bitSizeOf(usize) or
            evaluation.len() >> @intCast(n_folds) == 0)
        {
            return error.InvalidColumns;
        }

        const final_count = evaluation.len() >> @intCast(n_folds);
        const source_storage = evaluation.resident_storage;
        if (source_storage == null or !commit_policy.friFoldCommitUsesResidentMerkle(final_count, n_folds)) {
            const folded = try foldLineEvaluationN(allocator, evaluation, alpha, workspace, n_folds);
            errdefer {
                var owned = folded;
                owned.deinit(allocator);
            }
            var coordinates = if (comptime @hasDecl(@This(), "secureColumnForMerkle"))
                try secureColumnForMerkle(allocator, folded)
            else
                try secure_column.SecureColumnByCoords.fromSecureSlice(allocator, folded.values);
            errdefer coordinates.deinit(allocator);
            const columns = [_][]const M31{
                coordinates.columns[0],
                coordinates.columns[1],
                coordinates.columns[2],
                coordinates.columns[3],
            };
            const tree = try commitMerkle(H, allocator, columns[0..]);
            return .{ .evaluation = folded, .column = coordinates, .tree = tree };
        }

        var final_domain = evaluation.domain();
        var inverse_count: usize = 0;
        var stage_count = evaluation.len();
        for (0..n_folds) |_| {
            stage_count >>= 1;
            inverse_count = try std.math.add(usize, inverse_count, stage_count);
            final_domain = final_domain.double();
        }
        const inverse_values = try allocator.alloc(M31, inverse_count);
        defer allocator.free(inverse_values);
        const alphas = try allocator.alloc([4]u32, n_folds);
        defer allocator.free(alphas);

        var inverse_cursor: usize = 0;
        var current_count = evaluation.len();
        var current_domain = evaluation.domain();
        var current_alpha = alpha;
        for (0..n_folds) |step| {
            const destination_count = current_count >> 1;
            try workspace.ensureCapacity(allocator, destination_count);
            const x = workspace.x_values[0..destination_count];
            const inverse_x = workspace.inv_x_values[0..destination_count];
            const log_size = current_domain.logSize();
            for (x, 0..) |*value, index| {
                value.* = current_domain.at(core_utils.bitReverseIndex(index << 1, log_size));
            }
            try fields.batchInverseInPlace(M31, x, inverse_x);
            @memcpy(inverse_values[inverse_cursor .. inverse_cursor + destination_count], inverse_x);
            inverse_cursor += destination_count;
            const alpha_coordinates = current_alpha.toM31Array();
            alphas[step] = .{
                alpha_coordinates[0].v,
                alpha_coordinates[1].v,
                alpha_coordinates[2].v,
                alpha_coordinates[3].v,
            };
            current_count = destination_count;
            current_domain = current_domain.double();
            current_alpha = current_alpha.square();
        }

        var folded = try allocateLineEvaluation(final_domain);
        errdefer folded.deinit(allocator);
        var coordinates = try allocateSecureColumn(final_count);
        errdefer coordinates.deinit(allocator);
        const destination_storage = folded.resident_storage orelse return error.InvalidColumns;
        const coordinate_storage = coordinates.resident_storage orelse return error.InvalidColumns;
        const inverse_words = std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(inverse_values));
        var lease = try shared_runtime.acquire();
        defer lease.deinit();
        const result = try lease.runtime.foldFriLineAndCommit(
            source_storage.?.handle,
            @intCast(evaluation.len()),
            inverse_words,
            alphas,
            destination_storage.handle,
            coordinate_storage.handle,
            H.leafSeed(),
            H.nodeSeed(),
            H.domainPrefixBytes(),
        );
        const tree = try MerkleTree(H).fromSharedRuntime(result.tree);
        telemetry.record(.metal_fri_fold_commit_epoch);
        telemetry.record(.resident_merkle_commit);
        std.log.debug(
            "Metal FRI fold + Merkle epoch: {d:.3}ms, {} dispatches, {} command buffer, {} wait",
            .{
                result.stats.gpu_milliseconds,
                result.stats.dispatches,
                result.stats.command_buffers,
                result.stats.wait_count,
            },
        );
        return .{ .evaluation = folded, .column = coordinates, .tree = tree };
    }
    pub const foldLine = cpu.foldLine;
    pub const foldLineN = cpu.foldLineN;
    pub const accumulateQuotients = cpu.accumulateQuotients;
    pub const accumulate = cpu.accumulate;
    pub const genEqEvals = cpu.genEqEvals;
    pub const nextLayer = cpu.nextLayer;
    pub const sumAsPolyInFirstVariable = cpu.sumAsPolyInFirstVariable;
};

test "Metal commit backend exposes telemetry without constructing a runtime" {
    _ = MetalCommitBackend.TelemetrySnapshot;
    _ = MetalCommitBackend.TelemetryDelta;
    _ = &MetalCommitBackend.telemetrySnapshot;
    _ = &MetalCommitBackend.recordSampledValueFallback;
    _ = MetalCommitBackend.RuntimeLifecycleSnapshot;
    _ = MetalCommitBackend.ShutdownError;
    _ = &MetalCommitBackend.runtimeLifecycleSnapshot;
    _ = &MetalCommitBackend.shutdown;

    const lifecycle = MetalCommitBackend.runtimeLifecycleSnapshot();
    try std.testing.expect(lifecycle.initialization_count >= lifecycle.shutdown_count);
    try std.testing.expectEqual(
        lifecycle.initialized,
        lifecycle.initialization_count > lifecycle.shutdown_count,
    );
}
