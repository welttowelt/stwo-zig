//! RISC-V trace dumper CLI for cross-verification.
//!
//! Runs a RISC-V RV32IM ELF binary through the Zig execution engine and
//! writes a JSON trace suitable for equivalence comparison with the Rust
//! stark-v trace dumper.
//!
//! Usage:
//!   riscv-trace-dump --elf <path> [--output <trace.json>] [--max-steps N]
//!
//! When --output is omitted the JSON is written to stdout.

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
    var decode_file: ?[]const u8 = null;
    var max_steps: usize = 1_000_000;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--elf") and i + 1 < args.len) {
            i += 1;
            elf_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--output") and i + 1 < args.len) {
            i += 1;
            output_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--decode-file") and i + 1 < args.len) {
            i += 1;
            decode_file = args[i];
        } else if (std.mem.eql(u8, args[i], "--max-steps") and i + 1 < args.len) {
            i += 1;
            max_steps = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            printUsage();
            return;
        }
    }

    if (decode_file) |path| {
        try dumpDecodeMatrix(allocator, path);
        return;
    }

    if (elf_path == null) {
        printUsage();
        std.process.exit(1);
    }

    // Read ELF binary.
    const elf_bytes = std.fs.cwd().readFileAlloc(allocator, elf_path.?, 64 * 1024 * 1024) catch |err| {
        std.debug.print("error: cannot read ELF file '{s}': {}\n", .{ elf_path.?, err });
        std.process.exit(1);
    };
    defer allocator.free(elf_bytes);

    // Execute.
    var result = runner.run(allocator, elf_bytes, max_steps) catch |err| {
        std.debug.print("error: execution failed: {}\n", .{err});
        std.process.exit(1);
    };
    defer result.deinit();

    // Serialize trace to an in-memory buffer, then write it out.
    var json_buf: std.ArrayList(u8) = .{};
    defer json_buf.deinit(allocator);
    try trace_dump.writeTraceJson(json_buf.writer(allocator), &result.execution_trace, result.cpu_final);

    if (output_path) |path| {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(json_buf.items);
    } else {
        // Write to stdout.
        try json_buf.append(allocator, '\n');
        const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
        try stdout.writeAll(json_buf.items);
    }
}

fn printUsage() void {
    std.debug.print(
        \\Usage: riscv-trace-dump --elf <path> [--output <trace.json>] [--max-steps N]
        \\
        \\Options:
        \\  --elf <path>         Path to a RISC-V RV32IM ELF binary (required)
        \\  --output <path>      Write JSON trace to file (default: stdout)
        \\  --max-steps <N>      Maximum execution steps (default: 1000000)
        \\  --help, -h           Show this message
        \\
    , .{});
}

/// Decode-matrix mode for oracle parity: canonical one-line-per-word output
/// byte-compared against the pinned Stark-V decoder over the same corpus.
fn dumpDecodeMatrix(allocator: std.mem.Allocator, path: []const u8) !void {
    const raw = try std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024);
    defer allocator.free(raw);
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(allocator);
    const writer = out.writer(allocator);
    var offset: usize = 0;
    while (offset + 4 <= raw.len) : (offset += 4) {
        const word = std.mem.readInt(u32, raw[offset..][0..4], .little);
        if (runner.DecodedInst.decode(word)) |inst| {
            try writer.print("{x:0>8} {s} {d} {d} {d} {d}\n", .{
                word,
                @tagName(inst.opcode),
                inst.rd,
                inst.rs1,
                inst.rs2,
                inst.imm,
            });
        } else |_| {
            try writer.print("{x:0>8} -\n", .{word});
        }
    }
    const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    try stdout.writeAll(out.items);
}
