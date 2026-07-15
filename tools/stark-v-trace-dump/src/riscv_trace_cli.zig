//! RISC-V trace dumper CLI for cross-verification.
const std = @import("std");
const runner = @import("frontends/riscv/runner/mod.zig");
const trace_dump = @import("frontends/riscv/runner/trace_dump.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    var elf_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var max_steps: usize = 1_000_000;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--elf") and i + 1 < args.len) {
            i += 1; elf_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--output") and i + 1 < args.len) {
            i += 1; output_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--max-steps") and i + 1 < args.len) {
            i += 1; max_steps = try std.fmt.parseInt(usize, args[i], 10);
        }
    }
    if (elf_path == null) {
        std.debug.print("Usage: riscv-trace-dump --elf <path> --output <trace.json> [--max-steps N]\n", .{});
        return;
    }
    const elf_bytes = try std.fs.cwd().readFileAlloc(allocator, elf_path.?, 64 * 1024 * 1024);
    defer allocator.free(elf_bytes);
    var result = try runner.run(allocator, elf_bytes, max_steps);
    defer result.deinit();
    if (output_path) |path| {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try trace_dump.writeTraceJson(file.writer(), &result.execution_trace, result.cpu_final);
    } else {
        try trace_dump.writeTraceJson(std.io.getStdOut().writer(), &result.execution_trace, result.cpu_final);
    }
}
