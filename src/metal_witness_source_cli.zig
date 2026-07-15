const std = @import("std");
const codegen = @import("backends/metal/witness_codegen.zig");
const bundle_mod = @import("frontends/cairo/witness/bundle.zig");

pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 3) return error.InvalidArguments;
    var bundle = try bundle_mod.Bundle.readFile(allocator, args[1]);
    defer bundle.deinit();
    var output = try std.fs.cwd().createFile(args[2], .{});
    defer output.close();
    var buffer: [64 * 1024]u8 = undefined;
    var file_writer = output.writer(&buffer);
    const writer = &file_writer.interface;
    try writer.writeAll(codegen.preambleSource());
    for (bundle.entries) |entry| {
        const source = try codegen.generateKernel(allocator, entry.program, entry.semantic_hash);
        defer allocator.free(source);
        try writer.writeAll(source);
    }
    try writer.flush();
    std.debug.print("emitted {} canonical Metal witness programs\n", .{bundle.entries.len});
}
