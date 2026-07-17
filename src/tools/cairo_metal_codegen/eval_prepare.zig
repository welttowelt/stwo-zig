const std = @import("std");
const stwo = @import("stwo");
const metal = stwo.backends.metal.runtime;
const codegen = stwo.integrations.cairo_metal.eval_codegen;
const composition = stwo.frontends.cairo.witness.composition_bundle;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    const path = if (args.len == 1) "vectors/cairo/sn_pie_2_composition.bin" else if (args.len <= 3) args[1] else return error.InvalidArguments;
    var bundle = try composition.Bundle.readFile(allocator, path);
    defer bundle.deinit();
    var runtime = try metal.Runtime.init();
    defer runtime.deinit();
    var library: ?metal.EvalLibrary = if (args.len == 3) try runtime.loadEvalLibrary(args[2]) else null;
    defer if (library) |*loaded| loaded.deinit();
    var timer = try std.time.Timer.start();
    var codegen_ns: u64 = 0;
    var compile_ns: u64 = 0;
    var source_bytes: u64 = 0;
    var program_count: u32 = 0;
    var instruction_count: u64 = 0;
    var largest_source: usize = 0;
    for (bundle.components) |component| for (component.parts) |part| {
        const name = try codegen.kernelName(allocator, part.semantic_hash);
        defer allocator.free(name);
        instruction_count += part.program.base_insts.len + part.program.ext_insts.len;
        timer.reset();
        const layout: metal.EvalLayout = .{
            .trace_offsets = 0,
            .interaction_offsets = 0,
            .base_params = 0,
            .ext_params = 0,
            .random_coeffs = 0,
            .denom_inv = 0,
            .coordinates = .{ 0, 0, 0, 0 },
            .row_count = @as(u32, 1) << @intCast(component.evaluation_log_size),
            .trace_log_size = component.trace_log_size,
            .domain_log_size = part.program.header.domain_log_size,
            .rc_base = part.rc_base,
        };
        var plan = if (library) |loaded|
            try runtime.prepareEvalFromLibrary(loaded, name, layout)
        else blk: {
            timer.reset();
            const source = try codegen.generate(allocator, part.program);
            codegen_ns += timer.read();
            defer allocator.free(source);
            source_bytes += source.len;
            largest_source = @max(largest_source, source.len);
            timer.reset();
            break :blk try runtime.prepareEval(source, name, layout);
        };
        compile_ns += timer.read();
        plan.deinit();
        program_count += 1;
    };
    if (library) |loaded| try loaded.serialize();
    const result = .{
        .components = bundle.components.len,
        .programs = program_count,
        .constraints = bundle.total_constraints,
        .instructions = instruction_count,
        .source_bytes = source_bytes,
        .largest_source_bytes = largest_source,
        .codegen_ms = @as(f64, @floatFromInt(codegen_ns)) / std.time.ns_per_ms,
        .metal_compile_ms = @as(f64, @floatFromInt(compile_ns)) / std.time.ns_per_ms,
        .all_programs_compiled = true,
    };
    var buffer: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buffer);
    try std.json.Stringify.value(result, .{ .whitespace = .indent_2 }, &writer.interface);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}
