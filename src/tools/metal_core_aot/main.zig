const std = @import("std");
const artifact = @import("artifact.zig");
const toolchain = @import("toolchain.zig");

const usage =
    \\usage: metal-core-aot <emit|build> --output-dir <path>
    \\
    \\  emit   Write the canonical core MSL and authenticated JSON manifest.
    \\  build  Require full Xcode, emit the inputs, and run metal + metallib.
;

pub fn main() void {
    run() catch |err| {
        if (err == error.FullXcodeRequired)
            std.debug.print("{s}\n", .{toolchain.full_xcode_message})
        else
            std.debug.print("metal-core-aot failed: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };
}

fn run() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 4 or !std.mem.eql(u8, args[2], "--output-dir")) {
        std.debug.print("{s}", .{usage});
        return error.InvalidArguments;
    }
    if (std.mem.eql(u8, args[1], "emit")) {
        try artifact.emit(allocator, args[3]);
    } else if (std.mem.eql(u8, args[1], "build")) {
        try toolchain.build(allocator, args[3]);
    } else {
        std.debug.print("{s}", .{usage});
        return error.InvalidArguments;
    }
}

test {
    _ = artifact;
    _ = toolchain;
}
