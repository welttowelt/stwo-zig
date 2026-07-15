const std = @import("std");
const codegen = @import("backends/metal/eval_codegen.zig");
const composition = @import("frontends/cairo/witness/composition_bundle.zig");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 3) return error.InvalidArguments;
    var bundle = try composition.Bundle.readFile(allocator, args[1]);
    defer bundle.deinit();
    var output = try std.fs.cwd().createFile(args[2], .{});
    defer output.close();
    var buffer: [64 * 1024]u8 = undefined;
    var file_writer = output.writer(&buffer);
    const writer = &file_writer.interface;
    try writer.writeAll(codegen.preambleSource());
    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();
    var programs: u32 = 0;
    for (bundle.components) |component| for (component.parts) |part| {
        const entry = try seen.getOrPut(part.semantic_hash);
        if (entry.found_existing) continue;
        const source = try codegen.generateKernel(allocator, part.program, false);
        defer allocator.free(source);
        try writer.writeAll(source);
        programs += 1;
    };
    try writer.flush();
    std.debug.print("emitted {} unique Metal programs for plan {x:0>16}\n", .{ programs, bundle.plan_hash });
}
