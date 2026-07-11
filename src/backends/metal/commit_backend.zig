const std = @import("std");
const cpu = @import("../cpu_scalar/mod.zig").CpuBackend;
const runtime_mod = @import("runtime.zig");
const merkle = @import("../../prover/vcs_lifted/prover.zig");

var runtime_mutex: std.Thread.Mutex = .{};
var shared_runtime: ?runtime_mod.Runtime = null;

fn runtime() !*runtime_mod.Runtime {
    runtime_mutex.lock();
    defer runtime_mutex.unlock();
    if (shared_runtime == null) shared_runtime = try runtime_mod.Runtime.init();
    return &shared_runtime.?;
}

pub fn warmup() !void {
    _ = try runtime();
}

/// CPU-compatible prover backend whose commitment constructor is Metal.
///
/// The remaining operation methods are intentionally delegated to the CPU
/// backend until their transaction-level Metal replacements are resident.
pub const MetalCommitBackend = struct {
    pub const rawQuotientInputs = true;
    /// Streaming commitment currently owns a CPU leaf-hasher state machine.
    /// Materialize the prepared LDE columns once so Metal can consume the
    /// complete tree in a single command buffer.
    pub const preferMonolithicCommit = true;

    pub fn allocateSecureColumn(column_len: usize) !@import("../../prover/secure_column.zig").SecureColumnByCoords {
        const M31 = @import("../../core/fields/m31.zig").M31;
        const DEGREE = @import("../../core/fields/qm31.zig").SECURE_EXTENSION_DEGREE;
        var buffer = try (try runtime()).allocateResidentBuffer(column_len * DEGREE * @sizeOf(M31));
        errdefer buffer.deinit();
        const values: [*]M31 = @ptrCast(@alignCast(buffer.contents));
        var columns: [DEGREE][]M31 = undefined;
        for (0..DEGREE) |coordinate| {
            columns[coordinate] = values[coordinate * column_len .. (coordinate + 1) * column_len];
        }
        return @import("../../prover/secure_column.zig").SecureColumnByCoords.initResident(
            columns,
            .{
                .handle = buffer.handle,
                .destroyFn = runtime_mod.ResidentBuffer.destroyOpaque,
            },
        );
    }

    pub fn allocateLineEvaluation(
        domain: @import("../../core/poly/line.zig").LineDomain,
    ) !@import("../../prover/line.zig").LineEvaluation {
        const QM31 = @import("../../core/fields/qm31.zig").QM31;
        var buffer = try (try runtime()).allocateResidentBuffer(domain.size() * @sizeOf(QM31));
        errdefer buffer.deinit();
        const values: [*]QM31 = @ptrCast(@alignCast(buffer.contents));
        return @import("../../prover/line.zig").LineEvaluation.initResident(
            domain,
            values[0..domain.size()],
            .{
                .handle = buffer.handle,
                .destroyFn = runtime_mod.ResidentBuffer.destroyOpaque,
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
        const gpu_ms = try (try runtime()).qm31ToCoordinates(
            source.ptr,
            @intCast(evaluation.len()),
            destination.ptr,
        );
        std.log.debug("Metal QM31 coordinate conversion: {d:.3}ms", .{gpu_ms});
        return column;
    }

    pub fn commitMerkle(
        comptime H: type,
        allocator: std.mem.Allocator,
        columns: []const []const @import("../../core/fields/m31.zig").M31,
    ) !merkle.MerkleProverLifted(H) {
        var cells: usize = 0;
        for (columns) |column| cells += column.len;
        if (cells < (1 << 24)) return merkle.MerkleProverLifted(H).commit(allocator, columns);
        return merkle.MerkleProverLifted(H).commitMetal(try runtime(), allocator, columns);
    }

    pub fn computeLazyQuotients(
        allocator: std.mem.Allocator,
        provider: anytype,
        out: anytype,
    ) !void {
        const gpu_ms = try (try runtime()).computeQuotients(allocator, provider, out);
        std.log.debug("Metal quotient kernel: {d:.3}ms", .{gpu_ms});
    }

    pub fn evaluateCoefficientPlans(
        allocator: std.mem.Allocator,
        coefficients: anytype,
        tree_values: anytype,
        plans: anytype,
    ) !void {
        if (plans.len == 0) return;
        const gpu_ms = try (try runtime()).evaluateCoefficientPlans(
            allocator,
            coefficients,
            tree_values,
            plans,
        );
        std.log.debug("Metal sampled-value kernel: {d:.3}ms", .{gpu_ms});
    }

    pub fn interpolateCircleBuffers(
        allocator: std.mem.Allocator,
        values: []const []@import("../../core/fields/m31.zig").M31,
        domain: @import("../../core/poly/circle/domain.zig").CircleDomain,
        twiddle_tree: @import("../../prover/poly/twiddles.zig").TwiddleTree([]const @import("../../core/fields/m31.zig").M31),
    ) !void {
        if (domain.logSize() < 3) {
            return @import("../../prover/poly/circle/poly.zig").interpolateBuffersWithTwiddles(values, domain, twiddle_tree);
        }
        _ = try (try runtime()).transformCircle(
            allocator,
            values,
            twiddle_tree.itwiddles,
            domain.logSize(),
            true,
        );
    }

    pub fn evaluateCircleBuffers(
        allocator: std.mem.Allocator,
        values: []const []@import("../../core/fields/m31.zig").M31,
        domain: @import("../../core/poly/circle/domain.zig").CircleDomain,
        twiddle_tree: @import("../../prover/poly/twiddles.zig").TwiddleTree([]const @import("../../core/fields/m31.zig").M31),
    ) !void {
        if (domain.logSize() < 3) {
            return @import("../../prover/poly/circle/poly.zig").evaluateBuffersWithTwiddles(values, domain, twiddle_tree);
        }
        _ = try (try runtime()).transformCircle(
            allocator,
            values,
            twiddle_tree.twiddles,
            domain.logSize(),
            false,
        );
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
            return @import("../../prover/poly/circle/poly.zig").evaluateBuffersWithTwiddles(
                extended_values,
                extended_domain,
                extended_twiddles,
            );
        }
        const gpu_ms = try (try runtime()).transformCircleLde(
            allocator,
            source_values,
            base_values,
            extended_values,
            base_twiddles.itwiddles,
            extended_twiddles.twiddles,
            base_domain.logSize(),
            extended_domain.logSize(),
        );
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
        const gpu_ms = try (try runtime()).foldFriCircle(
            source_words.ptr,
            @intCast(src_columns[0].len),
            inverse_words,
            alpha_words,
            destination_words.ptr,
        );
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
        const alpha_coords = alpha.toM31Array();
        const alpha_words = [4]u32{ alpha_coords[0].v, alpha_coords[1].v, alpha_coords[2].v, alpha_coords[3].v };
        var current = evaluation;
        var owns_current = false;
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
            const gpu_ms = try (try runtime()).foldFriLine(
                source_words.ptr,
                @intCast(current.len()),
                inverse_words,
                alpha_words,
                destination_words.ptr,
            );
            std.log.debug("Metal FRI line fold: {d:.3}ms", .{gpu_ms});
            if (owns_current) current.deinit(allocator);
            current = next;
            owns_current = true;
        }
        return current;
    }
    pub const foldLine = cpu.foldLine;
    pub const foldLineN = cpu.foldLineN;
    pub const accumulateQuotients = cpu.accumulateQuotients;
    pub const accumulate = cpu.accumulate;
    pub const genEqEvals = cpu.genEqEvals;
    pub const nextLayer = cpu.nextLayer;
    pub const sumAsPolyInFirstVariable = cpu.sumAsPolyInFirstVariable;
};
