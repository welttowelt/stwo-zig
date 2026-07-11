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
    pub const foldCircleIntoLine = cpu.foldCircleIntoLine;
    pub const foldLine = cpu.foldLine;
    pub const accumulateQuotients = cpu.accumulateQuotients;
    pub const accumulate = cpu.accumulate;
    pub const genEqEvals = cpu.genEqEvals;
    pub const nextLayer = cpu.nextLayer;
    pub const sumAsPolyInFirstVariable = cpu.sumAsPolyInFirstVariable;
};
