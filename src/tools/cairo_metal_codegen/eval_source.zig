const std = @import("std");
const stwo = @import("stwo");
const options_parser = @import("eval_source_options.zig");
const codegen = stwo.integrations.cairo_metal.eval_codegen;
const composition = stwo.frontends.cairo.witness.composition_bundle;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 3) return error.InvalidArguments;
    const options = try options_parser.parse(
        args[3..],
        codegen.default_fused_instruction_cap,
        codegen.max_fused_instruction_cap,
    );
    var bundle = try composition.Bundle.readFile(allocator, args[1]);
    defer bundle.deinit();
    const component_limit = options.component_limit orelse bundle.components.len;
    if (component_limit > bundle.components.len) return error.InvalidComponentLimit;
    const components = bundle.components[0..component_limit];
    var output = try std.fs.cwd().createFile(args[2], .{});
    defer output.close();
    var buffer: [64 * 1024]u8 = undefined;
    var file_writer = output.writer(&buffer);
    const writer = &file_writer.interface;
    try writer.writeAll(codegen.preambleSource());
    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();
    var seen_fused = std.AutoHashMap(u64, void).init(allocator);
    defer seen_fused.deinit();
    var programs: u32 = 0;
    var fused_programs: u32 = 0;
    var baseline_dispatches: u32 = 0;
    var fused_dispatches: u32 = 0;
    if (!options.selected_only) {
        for (components) |component| for (component.parts) |part| {
            const entry = try seen.getOrPut(part.semantic_hash);
            if (entry.found_existing) continue;
            const source = try codegen.generateKernel(allocator, part.program, false);
            defer allocator.free(source);
            try writer.writeAll(source);
            programs += 1;
        };
    }
    for (components) |component| {
        baseline_dispatches += @intCast(component.parts.len);
        const fused_parts = try allocator.alloc(codegen.FusedPart, component.parts.len);
        defer allocator.free(fused_parts);
        for (component.parts, fused_parts) |part, *fused| fused.* = .{
            .program = part.program,
            .rc_base = part.rc_base,
        };
        var hybrid_partition: ?codegen.FusionPartition = null;
        defer if (hybrid_partition) |*partition| partition.deinit();
        if (options.fusion_mode == .experimental_hybrid_source_diagnostic)
            hybrid_partition = try codegen.hybridFusionPartition(allocator, fused_parts, .{});
        var start: usize = 0;
        var hybrid_slice_index: usize = 0;
        while (start < component.parts.len) {
            const end = switch (options.fusion_mode) {
                .capped => try codegen.fusionGroupEnd(fused_parts, start, options.fusion_cap),
                .experimental_hybrid_source_diagnostic => end: {
                    const slice = hybrid_partition.?.slices[hybrid_slice_index];
                    if (slice.start != start) return error.InvalidFusionPartition;
                    hybrid_slice_index += 1;
                    break :end slice.end;
                },
            };
            fused_dispatches += 1;
            if (end - start > 1) {
                const group = fused_parts[start..end];
                const entry = try seen_fused.getOrPut(try codegen.fusedKernelHash(group));
                if (!entry.found_existing) {
                    const source = try codegen.generateFusedKernel(allocator, group, false);
                    defer allocator.free(source);
                    try writer.writeAll(source);
                    fused_programs += 1;
                }
            } else if (options.selected_only) {
                const part = component.parts[start];
                const entry = try seen.getOrPut(part.semantic_hash);
                if (!entry.found_existing) {
                    const source = try codegen.generateKernel(allocator, part.program, false);
                    defer allocator.free(source);
                    try writer.writeAll(source);
                    programs += 1;
                }
            }
            start = end;
        }
        if (hybrid_partition) |partition|
            if (hybrid_slice_index != partition.slices.len)
                return error.InvalidFusionPartition;
    }
    try writer.flush();
    std.debug.print(
        "emitted {} unique Metal programs and {} fused programs for plan {x:0>16}; components={}/{} fusion_mode={s} fusion_cap={} dispatches={}->{} selected_only={}\n",
        .{
            programs,
            fused_programs,
            bundle.plan_hash,
            component_limit,
            bundle.components.len,
            @tagName(options.fusion_mode),
            options.fusion_cap,
            baseline_dispatches,
            fused_dispatches,
            options.selected_only,
        },
    );
}
