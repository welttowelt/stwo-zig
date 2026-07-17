const std = @import("std");
const stwo = @import("stwo");
const codegen = stwo.integrations.cairo_metal.eval_codegen;
const composition = stwo.frontends.cairo.witness.composition_bundle;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 3) return error.InvalidArguments;
    var fusion_cap = codegen.default_fused_instruction_cap;
    var selected_only = false;
    var component_limit_override: ?usize = null;
    var argument_index: usize = 3;
    if (argument_index < args.len and !std.mem.startsWith(u8, args[argument_index], "--")) {
        fusion_cap = try std.fmt.parseUnsigned(usize, args[argument_index], 10);
        argument_index += 1;
    }
    if (fusion_cap == 0 or fusion_cap > codegen.max_fused_instruction_cap)
        return error.InvalidFusionInstructionCap;
    while (argument_index < args.len) : (argument_index += 1) {
        const argument = args[argument_index];
        if (std.mem.eql(u8, argument, "--selected-only")) {
            if (selected_only) return error.InvalidArguments;
            selected_only = true;
        } else if (std.mem.eql(u8, argument, "--component-limit")) {
            if (component_limit_override != null or argument_index + 1 >= args.len)
                return error.InvalidArguments;
            argument_index += 1;
            component_limit_override = try std.fmt.parseUnsigned(usize, args[argument_index], 10);
            if (component_limit_override.? == 0) return error.InvalidComponentLimit;
        } else {
            return error.InvalidArguments;
        }
    }
    var bundle = try composition.Bundle.readFile(allocator, args[1]);
    defer bundle.deinit();
    const component_limit = component_limit_override orelse bundle.components.len;
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
    if (!selected_only) {
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
        var start: usize = 0;
        while (start < component.parts.len) {
            const end = try codegen.fusionGroupEnd(fused_parts, start, fusion_cap);
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
            } else if (selected_only) {
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
    }
    try writer.flush();
    std.debug.print(
        "emitted {} unique Metal programs and {} fused programs for plan {x:0>16}; components={}/{} fusion_cap={} dispatches={}->{} selected_only={}\n",
        .{
            programs,
            fused_programs,
            bundle.plan_hash,
            component_limit,
            bundle.components.len,
            fusion_cap,
            baseline_dispatches,
            fused_dispatches,
            selected_only,
        },
    );
}
