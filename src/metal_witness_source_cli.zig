const std = @import("std");
const codegen = @import("integrations/cairo_metal/witness_codegen.zig");
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
    const source = try codegen.generateSpecializedBatch(allocator, bundle.entries);
    defer allocator.free(source);
    try writer.writeAll(source);
    try writer.flush();
    std.debug.print("emitted {} specialized canonical Metal witness kernels\n", .{bundle.entries.len * 2});
}
