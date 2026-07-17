//! Low-overhead evidence that a generic proof used the intended Metal paths.

const std = @import("std");
const runtime = @import("runtime.zig");

pub const Event = enum {
    host_merkle_commit,
    resident_merkle_commit,
    metal_quotient_dispatch,
    metal_sampled_value_dispatch,
    metal_circle_transform_dispatch,
    metal_circle_lde_dispatch,
    metal_fri_circle_fold_dispatch,
    metal_fri_line_fold_dispatch,
    metal_fri_fold_commit_epoch,
    metal_qm31_coordinate_dispatch,
    cpu_small_merkle_commit,
    cpu_streaming_merkle_commit,
    cpu_sampled_value_evaluation,
    cpu_small_circle_interpolation,
    cpu_small_circle_evaluation,
    cpu_small_circle_lde,
};

pub const CounterValues = struct {
    host_merkle_commits: u64 = 0,
    resident_merkle_commits: u64 = 0,
    metal_quotient_dispatches: u64 = 0,
    metal_sampled_value_dispatches: u64 = 0,
    metal_circle_transform_dispatches: u64 = 0,
    metal_circle_lde_dispatches: u64 = 0,
    metal_fri_circle_fold_dispatches: u64 = 0,
    metal_fri_line_fold_dispatches: u64 = 0,
    metal_fri_fold_commit_epochs: u64 = 0,
    metal_qm31_coordinate_dispatches: u64 = 0,
    cpu_small_merkle_commits: u64 = 0,
    cpu_streaming_merkle_commits: u64 = 0,
    cpu_sampled_value_evaluations: u64 = 0,
    cpu_small_circle_interpolations: u64 = 0,
    cpu_small_circle_evaluations: u64 = 0,
    cpu_small_circle_ldes: u64 = 0,

    pub fn delta(after: CounterValues, before: CounterValues) CounterValues {
        var result: CounterValues = .{};
        inline for (std.meta.fields(CounterValues)) |field| {
            @field(result, field.name) = @field(after, field.name) -| @field(before, field.name);
        }
        return result;
    }

    pub fn metalDispatchTotal(self: CounterValues) u64 {
        var total: u64 = 0;
        inline for (.{
            self.resident_merkle_commits,
            self.metal_quotient_dispatches,
            self.metal_sampled_value_dispatches,
            self.metal_circle_transform_dispatches,
            self.metal_circle_lde_dispatches,
            self.metal_fri_circle_fold_dispatches,
            self.metal_fri_line_fold_dispatches,
            self.metal_fri_fold_commit_epochs,
            self.metal_qm31_coordinate_dispatches,
        }) |value| total +|= value;
        return total;
    }

    pub fn cpuFallbackTotal(self: CounterValues) u64 {
        const named_merkle = self.cpu_small_merkle_commits +| self.cpu_streaming_merkle_commits;
        var total = @max(self.host_merkle_commits, named_merkle);
        inline for (.{
            self.cpu_sampled_value_evaluations,
            self.cpu_small_circle_interpolations,
            self.cpu_small_circle_evaluations,
            self.cpu_small_circle_ldes,
        }) |value| total +|= value;
        return total;
    }
};

pub const PipelineCacheDelta = struct {
    library_cache_hits: u64 = 0,
    library_cache_misses: u64 = 0,
    pipeline_cache_hits: u64 = 0,
    binary_archive_hits: u64 = 0,
    binary_archive_misses: u64 = 0,
    direct_compiles: u64 = 0,
    archive_populations: u64 = 0,
    archive_serializations: u64 = 0,
    pipeline_preparation_seconds: f64 = 0,

    pub fn between(
        after: runtime.PipelineCacheStats,
        before: runtime.PipelineCacheStats,
    ) PipelineCacheDelta {
        return .{
            .library_cache_hits = after.library_cache_hits -| before.library_cache_hits,
            .library_cache_misses = after.library_cache_misses -| before.library_cache_misses,
            .pipeline_cache_hits = after.pipeline_cache_hits -| before.pipeline_cache_hits,
            .binary_archive_hits = after.binary_archive_hits -| before.binary_archive_hits,
            .binary_archive_misses = after.binary_archive_misses -| before.binary_archive_misses,
            .direct_compiles = after.direct_compiles -| before.direct_compiles,
            .archive_populations = after.archive_populations -| before.archive_populations,
            .archive_serializations = after.archive_serializations -| before.archive_serializations,
            .pipeline_preparation_seconds = @max(
                @as(f64, 0),
                after.pipeline_preparation_seconds - before.pipeline_preparation_seconds,
            ),
        };
    }
};

pub const Classification = enum {
    no_backend_work,
    host_only,
    accelerated_with_fallbacks,
    accelerated_without_fallbacks,
};

pub const ClassificationError = error{
    NoMetalDispatch,
    CpuFallbackObserved,
};

pub const Snapshot = struct {
    counters: CounterValues,
    pipeline_cache: runtime.PipelineCacheStats,

    pub fn delta(after: Snapshot, before: Snapshot) Delta {
        return .{
            .counters = CounterValues.delta(after.counters, before.counters),
            .pipeline_cache = PipelineCacheDelta.between(after.pipeline_cache, before.pipeline_cache),
        };
    }
};

pub const Delta = struct {
    counters: CounterValues,
    pipeline_cache: PipelineCacheDelta,

    pub fn classification(self: Delta) Classification {
        const metal_dispatches = self.counters.metalDispatchTotal();
        const cpu_fallbacks = self.counters.cpuFallbackTotal();
        if (metal_dispatches == 0) {
            return if (cpu_fallbacks == 0) .no_backend_work else .host_only;
        }
        return if (cpu_fallbacks == 0)
            .accelerated_without_fallbacks
        else
            .accelerated_with_fallbacks;
    }

    /// Hybrid Metal benchmarks may report CPU fallback work, but cannot claim
    /// a Metal result unless at least one device operation was dispatched.
    pub fn requireMetalDispatch(self: Delta) error{NoMetalDispatch}!void {
        if (self.counters.metalDispatchTotal() == 0) return error.NoMetalDispatch;
    }

    /// A benchmark may claim an accelerated Metal result only after this
    /// succeeds. Missing dispatches and every known CPU fallback fail closed.
    pub fn requireAcceleratedWithoutFallbacks(self: Delta) ClassificationError!void {
        if (self.counters.metalDispatchTotal() == 0) return error.NoMetalDispatch;
        if (self.counters.cpuFallbackTotal() != 0) return error.CpuFallbackObserved;
    }
};

const AtomicCounter = std.atomic.Value(u64);

const CounterBank = struct {
    host_merkle_commits: AtomicCounter = AtomicCounter.init(0),
    resident_merkle_commits: AtomicCounter = AtomicCounter.init(0),
    metal_quotient_dispatches: AtomicCounter = AtomicCounter.init(0),
    metal_sampled_value_dispatches: AtomicCounter = AtomicCounter.init(0),
    metal_circle_transform_dispatches: AtomicCounter = AtomicCounter.init(0),
    metal_circle_lde_dispatches: AtomicCounter = AtomicCounter.init(0),
    metal_fri_circle_fold_dispatches: AtomicCounter = AtomicCounter.init(0),
    metal_fri_line_fold_dispatches: AtomicCounter = AtomicCounter.init(0),
    metal_fri_fold_commit_epochs: AtomicCounter = AtomicCounter.init(0),
    metal_qm31_coordinate_dispatches: AtomicCounter = AtomicCounter.init(0),
    cpu_small_merkle_commits: AtomicCounter = AtomicCounter.init(0),
    cpu_streaming_merkle_commits: AtomicCounter = AtomicCounter.init(0),
    cpu_sampled_value_evaluations: AtomicCounter = AtomicCounter.init(0),
    cpu_small_circle_interpolations: AtomicCounter = AtomicCounter.init(0),
    cpu_small_circle_evaluations: AtomicCounter = AtomicCounter.init(0),
    cpu_small_circle_ldes: AtomicCounter = AtomicCounter.init(0),
};

var counter_bank: CounterBank = .{};

pub fn record(event: Event) void {
    const counter = switch (event) {
        .host_merkle_commit => &counter_bank.host_merkle_commits,
        .resident_merkle_commit => &counter_bank.resident_merkle_commits,
        .metal_quotient_dispatch => &counter_bank.metal_quotient_dispatches,
        .metal_sampled_value_dispatch => &counter_bank.metal_sampled_value_dispatches,
        .metal_circle_transform_dispatch => &counter_bank.metal_circle_transform_dispatches,
        .metal_circle_lde_dispatch => &counter_bank.metal_circle_lde_dispatches,
        .metal_fri_circle_fold_dispatch => &counter_bank.metal_fri_circle_fold_dispatches,
        .metal_fri_line_fold_dispatch => &counter_bank.metal_fri_line_fold_dispatches,
        .metal_fri_fold_commit_epoch => &counter_bank.metal_fri_fold_commit_epochs,
        .metal_qm31_coordinate_dispatch => &counter_bank.metal_qm31_coordinate_dispatches,
        .cpu_small_merkle_commit => &counter_bank.cpu_small_merkle_commits,
        .cpu_streaming_merkle_commit => &counter_bank.cpu_streaming_merkle_commits,
        .cpu_sampled_value_evaluation => &counter_bank.cpu_sampled_value_evaluations,
        .cpu_small_circle_interpolation => &counter_bank.cpu_small_circle_interpolations,
        .cpu_small_circle_evaluation => &counter_bank.cpu_small_circle_evaluations,
        .cpu_small_circle_lde => &counter_bank.cpu_small_circle_ldes,
    };
    _ = counter.fetchAdd(1, .monotonic);
}

pub fn capture(pipeline_cache: runtime.PipelineCacheStats) Snapshot {
    var values: CounterValues = .{};
    inline for (std.meta.fields(CounterValues)) |field| {
        @field(values, field.name) = @field(counter_bank, field.name).load(.monotonic);
    }
    return .{ .counters = values, .pipeline_cache = pipeline_cache };
}

fn snapshot(counters: CounterValues, cache_hits: u64) Snapshot {
    var cache = runtime.PipelineCacheStats.zero();
    cache.pipeline_cache_hits = cache_hits;
    return .{ .counters = counters, .pipeline_cache = cache };
}

test "Metal telemetry delta is monotonic and includes pipeline cache evidence" {
    const before = snapshot(.{
        .host_merkle_commits = 4,
        .resident_merkle_commits = 8,
        .metal_quotient_dispatches = 2,
    }, 11);
    var after_cache = runtime.PipelineCacheStats.zero();
    after_cache.pipeline_cache_hits = 17;
    after_cache.direct_compiles = 3;
    after_cache.pipeline_preparation_seconds = 0.75;
    const after = Snapshot{
        .counters = .{
            .host_merkle_commits = 3,
            .resident_merkle_commits = 10,
            .metal_quotient_dispatches = 5,
        },
        .pipeline_cache = after_cache,
    };
    const result = after.delta(before);
    try std.testing.expectEqual(@as(u64, 0), result.counters.host_merkle_commits);
    try std.testing.expectEqual(@as(u64, 2), result.counters.resident_merkle_commits);
    try std.testing.expectEqual(@as(u64, 3), result.counters.metal_quotient_dispatches);
    try std.testing.expectEqual(@as(u64, 6), result.pipeline_cache.pipeline_cache_hits);
    try std.testing.expectEqual(@as(u64, 3), result.pipeline_cache.direct_compiles);
    try std.testing.expectEqual(@as(f64, 0.75), result.pipeline_cache.pipeline_preparation_seconds);
}

test "Metal telemetry classification fails closed" {
    const empty = Delta{ .counters = .{}, .pipeline_cache = .{} };
    try std.testing.expectEqual(Classification.no_backend_work, empty.classification());
    try std.testing.expectError(error.NoMetalDispatch, empty.requireMetalDispatch());
    try std.testing.expectError(error.NoMetalDispatch, empty.requireAcceleratedWithoutFallbacks());

    const metal = Delta{
        .counters = .{ .metal_quotient_dispatches = 1 },
        .pipeline_cache = .{},
    };
    try std.testing.expectEqual(Classification.accelerated_without_fallbacks, metal.classification());
    try metal.requireMetalDispatch();
    try metal.requireAcceleratedWithoutFallbacks();

    const mixed = Delta{
        .counters = .{
            .resident_merkle_commits = 1,
            .host_merkle_commits = 1,
            .cpu_small_merkle_commits = 1,
        },
        .pipeline_cache = .{},
    };
    try std.testing.expectEqual(Classification.accelerated_with_fallbacks, mixed.classification());
    try mixed.requireMetalDispatch();
    try std.testing.expectError(error.CpuFallbackObserved, mixed.requireAcceleratedWithoutFallbacks());

    const host = Delta{
        .counters = .{ .cpu_sampled_value_evaluations = 1 },
        .pipeline_cache = .{},
    };
    try std.testing.expectEqual(Classification.host_only, host.classification());
    try std.testing.expectError(error.NoMetalDispatch, host.requireMetalDispatch());
    try std.testing.expectError(error.NoMetalDispatch, host.requireAcceleratedWithoutFallbacks());
}
