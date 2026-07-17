const std = @import("std");
const metal = @import("../../../backends/metal/runtime.zig");

const library_count = 9;
const pipeline_count = 65;
const function_name = "stwo_zig_cache_probe";

const layout: metal.EvalLayout = .{
    .trace_offsets = 0,
    .interaction_offsets = 0,
    .base_params = 0,
    .ext_params = 0,
    .random_coeffs = 0,
    .denom_inv = 0,
    .coordinates = .{ 0, 0, 0, 0 },
    .row_count = 2,
    .trace_log_size = 0,
    .domain_log_size = 0,
    .rc_base = 0,
};

fn sourceFor(allocator: std.mem.Allocator, value: usize) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        \\#include <metal_stdlib>
        \\using namespace metal;
        \\kernel void stwo_zig_cache_probe(
        \\    device uint *output [[buffer(0)]],
        \\    uint index [[thread_position_in_grid]]) {{
        \\    if (index == 0) output[0] = {d};
        \\}}
    ,
        .{value},
    );
}

fn pipelineSource(allocator: std.mem.Allocator) ![]u8 {
    var source = std.ArrayList(u8).empty;
    errdefer source.deinit(allocator);
    const writer = source.writer(allocator);
    try writer.writeAll("#include <metal_stdlib>\nusing namespace metal;\n");
    for (0..pipeline_count) |index| {
        try writer.print(
            "kernel void stwo_zig_cache_pipeline_{d}(device uint *output [[buffer(0)]], uint i [[thread_position_in_grid]]) {{ if (i == 0) output[0] = {d}; }}\n",
            .{ index, index },
        );
    }
    return source.toOwnedSlice(allocator);
}

test "metal: dynamic library and pipeline caches are bounded across teardown" {
    const allocator = std.testing.allocator;
    {
        var runtime = try metal.Runtime.init();
        defer runtime.deinit();

        var libraries: [library_count]metal.EvalLibrary = undefined;
        var initialized: usize = 0;
        defer for (libraries[0..initialized]) |*library| library.deinit();

        const first_source = try sourceFor(allocator, 0);
        defer allocator.free(first_source);
        libraries[0] = try runtime.compileEvalLibrary(first_source);
        initialized = 1;

        var retained_plan = try runtime.prepareEvalFromLibrary(libraries[0], function_name, layout);
        defer retained_plan.deinit();

        for (1..library_count) |index| {
            const source = try sourceFor(allocator, index);
            defer allocator.free(source);
            libraries[index] = try runtime.compileEvalLibrary(source);
            initialized += 1;
        }

        const after_eviction = runtime.pipelineCacheStats();
        try std.testing.expectEqual(after_eviction.library_cache_entry_limit, after_eviction.library_cache_entries);
        try std.testing.expectEqual(@as(u64, 1), after_eviction.library_cache_evictions);
        try std.testing.expectEqual(@as(u64, 1), after_eviction.pipeline_cache_invalidations);
        try std.testing.expectEqual(@as(u64, 0), after_eviction.pipeline_cache_entries);
        try std.testing.expect(after_eviction.library_cache_bytes <= after_eviction.library_cache_byte_limit);
        try std.testing.expect(after_eviction.library_cache_peak_bytes <= after_eviction.library_cache_byte_limit);
        try std.testing.expect(after_eviction.pipeline_cache_peak_bytes <= after_eviction.pipeline_cache_byte_limit);

        const newest_source = try sourceFor(allocator, library_count - 1);
        defer allocator.free(newest_source);
        var cache_hit = try runtime.compileEvalLibrary(newest_source);
        defer cache_hit.deinit();
        const after_hit = runtime.pipelineCacheStats();
        try std.testing.expectEqual(after_eviction.library_cache_entries, after_hit.library_cache_entries);
        try std.testing.expectEqual(after_eviction.library_cache_hits + 1, after_hit.library_cache_hits);

        var restored_plan = try runtime.prepareEvalFromLibrary(libraries[0], function_name, layout);
        defer restored_plan.deinit();
        var pipeline_hit = try runtime.prepareEvalFromLibrary(libraries[0], function_name, layout);
        defer pipeline_hit.deinit();
        const after_restore = runtime.pipelineCacheStats();
        try std.testing.expectEqual(@as(u64, 1), after_restore.pipeline_cache_entries);
        try std.testing.expectEqual(after_hit.pipeline_cache_hits + 1, after_restore.pipeline_cache_hits);

        const pipeline_source = try pipelineSource(allocator);
        defer allocator.free(pipeline_source);
        var pipeline_library = try runtime.compileEvalLibrary(pipeline_source);
        defer pipeline_library.deinit();
        var plans: [pipeline_count]metal.EvalPlan = undefined;
        var plan_count: usize = 0;
        defer for (plans[0..plan_count]) |*plan| plan.deinit();
        for (0..pipeline_count) |index| {
            const name = try std.fmt.allocPrint(allocator, "stwo_zig_cache_pipeline_{d}", .{index});
            defer allocator.free(name);
            plans[index] = try runtime.prepareEvalFromLibrary(pipeline_library, name, layout);
            plan_count += 1;
        }
        const after_pipeline_eviction = runtime.pipelineCacheStats();
        try std.testing.expectEqual(
            after_pipeline_eviction.pipeline_cache_entry_limit,
            after_pipeline_eviction.pipeline_cache_entries,
        );
        try std.testing.expect(after_pipeline_eviction.pipeline_cache_evictions > after_restore.pipeline_cache_evictions);
        try std.testing.expect(after_pipeline_eviction.pipeline_cache_bytes <= after_pipeline_eviction.pipeline_cache_byte_limit);
        try std.testing.expect(after_pipeline_eviction.pipeline_cache_peak_bytes <= after_pipeline_eviction.pipeline_cache_byte_limit);
    }

    var fresh_runtime = try metal.Runtime.init();
    defer fresh_runtime.deinit();
    const fresh = fresh_runtime.pipelineCacheStats();
    try std.testing.expectEqual(@as(u64, 0), fresh.library_cache_entries);
    try std.testing.expectEqual(@as(u64, 0), fresh.pipeline_cache_entries);
    try std.testing.expectEqual(@as(u64, 0), fresh.library_cache_peak_entries);
    try std.testing.expectEqual(@as(u64, 0), fresh.pipeline_cache_peak_entries);
    try std.testing.expect(fresh.library_cache_entry_limit > 0);
    try std.testing.expect(fresh.pipeline_cache_entry_limit > 0);
}
