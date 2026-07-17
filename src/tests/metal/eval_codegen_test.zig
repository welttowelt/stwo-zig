const std = @import("std");
const eval_program = @import("../../frontends/cairo/witness/eval_program.zig");
const eval_codegen = @import("../../integrations/cairo_metal/eval_codegen.zig");
const composition_bundle = @import("../../frontends/cairo/witness/composition_bundle.zig");

test {
    _ = eval_program;
    _ = eval_codegen;
    _ = composition_bundle;
}

test "Metal evaluation codegen: hybrid fusion uses the exact emitted source cap" {
    const allocator = std.testing.allocator;
    var bundle = try composition_bundle.Bundle.readFile(
        allocator,
        "vectors/cairo/sn_pie_2_composition.bin",
    );
    defer bundle.deinit();
    const component = bundle.components[29];
    try std.testing.expectEqualStrings("pedersen_aggregator_window_bits_18", component.label);

    const parts = try allocator.alloc(eval_codegen.FusedPart, component.parts.len);
    defer allocator.free(parts);
    for (component.parts, parts) |part, *fused| fused.* = .{
        .program = part.program,
        .rc_base = part.rc_base,
    };

    var admitted = try eval_codegen.hybridFusionPartition(allocator, parts, .{});
    defer admitted.deinit();
    try std.testing.expectEqual(@as(usize, 1), admitted.slices.len);
    try std.testing.expectEqual(@as(usize, 2097), admitted.slices[0].operations);
    try std.testing.expect(admitted.slices[0].source_bytes <= eval_codegen.hybrid_fusion_source_cap);

    var rejected = try eval_codegen.hybridFusionPartition(allocator, parts, .{
        .maximum_source_bytes = admitted.slices[0].source_bytes - 1,
    });
    defer rejected.deinit();
    try std.testing.expectEqual(@as(usize, 2), rejected.slices.len);
    var expected_start: usize = 0;
    for (rejected.slices) |slice| {
        try std.testing.expectEqual(expected_start, slice.start);
        expected_start = try eval_codegen.fusionGroupEnd(parts, expected_start, 2048);
        try std.testing.expectEqual(expected_start, slice.end);
    }
    try std.testing.expectEqual(parts.len, expected_start);
}

test "Metal evaluation codegen: hybrid fusion minimizes exact maximum source size" {
    const allocator = std.testing.allocator;
    var bundle = try composition_bundle.Bundle.readFile(
        allocator,
        "vectors/cairo/sn_pie_2_composition.bin",
    );
    defer bundle.deinit();
    const component = bundle.components[0];
    try std.testing.expectEqualStrings("add_opcode", component.label);

    const parts = try allocator.alloc(eval_codegen.FusedPart, component.parts.len);
    defer allocator.free(parts);
    for (component.parts, parts) |part, *fused| fused.* = .{
        .program = part.program,
        .rc_base = part.rc_base,
    };
    var partition = try eval_codegen.hybridFusionPartition(allocator, parts, .{
        .baseline_operation_cap = 1,
        .maximum_operation_cap = 815,
    });
    defer partition.deinit();

    try std.testing.expectEqual(@as(usize, 2), partition.slices.len);
    try std.testing.expectEqual(@as(usize, 1), partition.slices[0].end);
    try std.testing.expectEqual(@as(usize, 3), partition.slices[1].end);
    const competing_source = try eval_codegen.generateFusedKernel(allocator, parts[0..2], false);
    defer allocator.free(competing_source);
    try std.testing.expect(partition.slices[1].source_bytes < competing_source.len);

    var oversize_single = try eval_codegen.hybridFusionPartition(allocator, parts[0..1], .{
        .baseline_operation_cap = 1,
        .maximum_operation_cap = 2,
    });
    defer oversize_single.deinit();
    try std.testing.expectEqual(@as(usize, 1), oversize_single.slices.len);
    try std.testing.expectEqual(@as(usize, 0), oversize_single.slices[0].start);
    try std.testing.expectEqual(@as(usize, 1), oversize_single.slices[0].end);
}

test "Metal evaluation codegen: hybrid fusion rejects invalid policy" {
    try std.testing.expectError(
        error.InvalidFusionPolicy,
        eval_codegen.hybridFusionPartition(std.testing.allocator, &.{}, .{
            .baseline_operation_cap = 2049,
            .maximum_operation_cap = 2048,
        }),
    );
}
