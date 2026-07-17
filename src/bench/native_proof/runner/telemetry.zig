//! Metal request telemetry normalization and headline-validity gates.

const std = @import("std");
const config = @import("../config.zig");
const report = @import("../report.zig");

pub const Totals = struct {
    metal_dispatches: u64 = 0,
    cpu_fallbacks: u64 = 0,
};

pub fn request(delta: anytype) report.BackendTelemetryDelta {
    const counters = delta.counters;
    return .{
        .classification = @tagName(delta.classification()),
        .metal_dispatches = counters.metalDispatchTotal(),
        .cpu_fallbacks = counters.cpuFallbackTotal(),
        .counters = .{
            .host_merkle_commits = counters.host_merkle_commits,
            .resident_merkle_commits = counters.resident_merkle_commits,
            .metal_quotient_dispatches = counters.metal_quotient_dispatches,
            .metal_sampled_value_dispatches = counters.metal_sampled_value_dispatches,
            .metal_circle_transform_dispatches = counters.metal_circle_transform_dispatches,
            .metal_circle_lde_dispatches = counters.metal_circle_lde_dispatches,
            .metal_fri_circle_fold_dispatches = counters.metal_fri_circle_fold_dispatches,
            .metal_fri_line_fold_dispatches = counters.metal_fri_line_fold_dispatches,
            .metal_fri_fold_commit_epochs = counters.metal_fri_fold_commit_epochs,
            .metal_qm31_coordinate_dispatches = counters.metal_qm31_coordinate_dispatches,
            .cpu_small_merkle_commits = counters.cpu_small_merkle_commits,
            .cpu_streaming_merkle_commits = counters.cpu_streaming_merkle_commits,
            .cpu_sampled_value_evaluations = counters.cpu_sampled_value_evaluations,
            .cpu_small_circle_interpolations = counters.cpu_small_circle_interpolations,
            .cpu_small_circle_evaluations = counters.cpu_small_circle_evaluations,
            .cpu_small_circle_ldes = counters.cpu_small_circle_ldes,
        },
        .pipeline_cache = pipelineCache(delta.pipeline_cache),
    };
}

pub fn pipelineCache(stats: anytype) report.PipelineCacheDelta {
    return .{
        .library_cache_hits = stats.library_cache_hits,
        .library_cache_misses = stats.library_cache_misses,
        .pipeline_cache_hits = stats.pipeline_cache_hits,
        .binary_archive_hits = stats.binary_archive_hits,
        .binary_archive_misses = stats.binary_archive_misses,
        .direct_compiles = stats.direct_compiles,
        .archive_populations = stats.archive_populations,
        .archive_serializations = stats.archive_serializations,
        .pipeline_preparation_seconds = stats.pipeline_preparation_seconds,
        .library_preparation_seconds = stats.library_preparation_seconds,
        .library_cache_entries = stats.library_cache_entries,
        .library_cache_bytes = stats.library_cache_bytes,
        .library_cache_peak_entries = stats.library_cache_peak_entries,
        .library_cache_peak_bytes = stats.library_cache_peak_bytes,
        .library_cache_evictions = stats.library_cache_evictions,
        .library_cache_rejections = stats.library_cache_rejections,
        .pipeline_cache_entries = stats.pipeline_cache_entries,
        .pipeline_cache_bytes = stats.pipeline_cache_bytes,
        .pipeline_cache_peak_entries = stats.pipeline_cache_peak_entries,
        .pipeline_cache_peak_bytes = stats.pipeline_cache_peak_bytes,
        .pipeline_cache_evictions = stats.pipeline_cache_evictions,
        .pipeline_cache_invalidations = stats.pipeline_cache_invalidations,
        .pipeline_cache_rejections = stats.pipeline_cache_rejections,
        .library_cache_entry_limit = stats.library_cache_entry_limit,
        .library_cache_byte_limit = stats.library_cache_byte_limit,
        .pipeline_cache_entry_limit = stats.pipeline_cache_entry_limit,
        .pipeline_cache_byte_limit = stats.pipeline_cache_byte_limit,
    };
}

pub fn valid(
    comptime backend: config.Backend,
    warmups: []const report.BackendTelemetryDelta,
    samples: []const report.BackendTelemetryDelta,
) bool {
    if (comptime backend == .cpu_native) return warmups.len == 0 and samples.len == 0;
    for (warmups) |delta| if (delta.metal_dispatches == 0) return false;
    for (samples) |delta| {
        if (delta.metal_dispatches == 0 or pipelinePreparationOccurred(delta.pipeline_cache))
            return false;
    }
    return true;
}

pub fn sum(
    warmups: []const report.BackendTelemetryDelta,
    samples: []const report.BackendTelemetryDelta,
) Totals {
    var result: Totals = .{};
    for (warmups) |delta| {
        result.metal_dispatches +|= delta.metal_dispatches;
        result.cpu_fallbacks +|= delta.cpu_fallbacks;
    }
    for (samples) |delta| {
        result.metal_dispatches +|= delta.metal_dispatches;
        result.cpu_fallbacks +|= delta.cpu_fallbacks;
    }
    return result;
}

fn pipelinePreparationOccurred(cache: report.PipelineCacheDelta) bool {
    // Cache-hit lookup time is still accumulated; counters identify samples
    // that actually create or load library or pipeline state after warmup.
    return cache.library_cache_misses > 0 or
        cache.binary_archive_hits > 0 or
        cache.binary_archive_misses > 0 or
        cache.direct_compiles > 0 or
        cache.archive_populations > 0 or
        cache.archive_serializations > 0;
}

test "every Metal request needs a dispatch" {
    const accelerated = report.BackendTelemetryDelta{
        .classification = "accelerated_without_fallbacks",
        .metal_dispatches = 1,
        .cpu_fallbacks = 0,
        .counters = .{},
        .pipeline_cache = .{},
    };
    var host_only = accelerated;
    host_only.metal_dispatches = 0;
    try std.testing.expect(valid(.metal_hybrid, &.{accelerated}, &.{accelerated}));
    try std.testing.expect(!valid(.metal_hybrid, &.{accelerated}, &.{host_only}));
    var cold = accelerated;
    cold.pipeline_cache.direct_compiles = 1;
    try std.testing.expect(!valid(.metal_hybrid, &.{accelerated}, &.{cold}));
    try std.testing.expect(valid(.cpu_native, &.{}, &.{}));
}

test "library misses are cold but hit timing is warm" {
    var cache = report.PipelineCacheDelta{};
    cache.library_cache_misses = 1;
    try std.testing.expect(pipelinePreparationOccurred(cache));

    cache = .{};
    cache.library_cache_hits = 1;
    cache.pipeline_preparation_seconds = 0.125;
    cache.library_preparation_seconds = 0.25;
    try std.testing.expect(!pipelinePreparationOccurred(cache));
}
