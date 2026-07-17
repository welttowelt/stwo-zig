const std = @import("std");
const manifest = @import("manifest.zig");

test "source and AOT core runtimes share one fail-closed pipeline initializer" {
    const runtime_source = @embedFile("../runtime.m");
    const initialization_source = @embedFile("../runtime/initialization.m");
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, runtime_source, "static StwoZigMetalRuntime *create_runtime_from_library("),
    );

    const source_start = std.mem.indexOf(
        u8,
        initialization_source,
        "static void *create_runtime_from_source(",
    ) orelse return error.MissingMetalSourceRuntimeInitializer;
    const aot_start = std.mem.indexOf(
        u8,
        initialization_source,
        "void *stwo_zig_metal_runtime_create_from_metallib(",
    ) orelse return error.MissingMetalAotRuntimeInitializer;
    const data_start = std.mem.indexOf(
        u8,
        initialization_source,
        "void *stwo_zig_metal_runtime_create_from_metallib_data(",
    ) orelse return error.MissingMetalDataRuntimeInitializer;
    const constructors = [_][]const u8{
        initialization_source[source_start..aot_start],
        initialization_source[aot_start..data_start],
        initialization_source[data_start..],
    };
    for (constructors) |constructor| try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, constructor, "StwoZigMetalRuntime *runtime = create_runtime_from_library("),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, runtime_source, "#import \"runtime/initialization.m\""),
    );

    const initializer_start = std.mem.indexOf(
        u8,
        runtime_source,
        "static StwoZigMetalRuntime *create_runtime_from_library(",
    ) orelse return error.MissingMetalRuntimeInitializer;
    const initializer_end = std.mem.indexOfPos(
        u8,
        runtime_source,
        initializer_start,
        "#import \"runtime/initialization.m\"",
    ) orelse return error.MalformedMetalRuntimeInitializer;
    const initializer = runtime_source[initializer_start..initializer_end];

    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, constructors[0], "newLibraryWithSource:source options:options"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, constructors[1], "newLibraryWithURL:[NSURL fileURLWithPath:canonical_path]"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, constructors[2], "newLibraryWithData:data error:&error"),
    );

    var assignments = initializer;
    var assignment_count: usize = 0;
    const assignment_marker = " = make_pipeline(";
    while (std.mem.indexOf(u8, assignments, assignment_marker)) |marker_index| {
        const property_marker = "runtime.";
        const property_start = (std.mem.lastIndexOf(
            u8,
            assignments[0..marker_index],
            property_marker,
        ) orelse return error.MalformedMetalPipelineAssignment) + property_marker.len;
        const property = assignments[property_start..marker_index];
        var validation_buffer: [180]u8 = undefined;
        const validation = try std.fmt.bufPrint(
            &validation_buffer,
            "runtime.{s} == nil",
            .{property},
        );
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, initializer, validation));
        assignment_count += 1;
        assignments = assignments[marker_index + assignment_marker.len ..];
    }
    try std.testing.expectEqual(manifest.exports.len, assignment_count);
}
