//! Cairo proving flow benchmark harness.
//!
//! Measures each stage of the pipeline:
//! 1. Execution: cairo1-run subprocess (Cairo VM)
//! 2. Loading: read binary trace + memory files
//! 3. Parsing: convert raw entries to CasmState + Memory
//! 4. Adapter: opcode classification into 20 categories
//!
//! Usage:
//!   zig run src/frontends/cairo/bench.zig -- <cairo-file> [--cairo1-run <path>]

const std = @import("std");
const trace_reader = @import("adapter/trace_reader.zig");
const opcodes = @import("adapter/opcodes.zig");
const decode_mod = @import("adapter/decode.zig");
const cpu = @import("common/cpu.zig");
const memory_mod = @import("common/memory.zig");
const felt252_mod = @import("common/felt252.zig");

const CasmState = cpu.CasmState;
const M31 = @import("../../core/fields/m31.zig").M31;

const Timer = struct {
    start: i128,

    fn begin() Timer {
        return .{ .start = std.time.nanoTimestamp() };
    }

    fn elapsedMs(self: Timer) f64 {
        const elapsed = std.time.nanoTimestamp() - self.start;
        return @as(f64, @floatFromInt(elapsed)) / 1_000_000.0;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Parse arguments.
    var cairo_file: ?[]const u8 = null;
    var cairo1_run_path: []const u8 = "cairo1-run";
    var cairo_cwd: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--cairo1-run") and i + 1 < args.len) {
            i += 1;
            cairo1_run_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--cairo-cwd") and i + 1 < args.len) {
            i += 1;
            cairo_cwd = args[i];
        } else {
            cairo_file = args[i];
        }
    }

    if (cairo_file == null) {
        std.debug.print("Usage: cairo-bench <cairo-file> [--cairo1-run <path>] [--cairo-cwd <dir>]\n", .{});
        std.debug.print("\nOptions:\n", .{});
        std.debug.print("  --cairo1-run <path>   Path to cairo1-run binary\n", .{});
        std.debug.print("  --cairo-cwd <dir>     Working directory for cairo1-run (must contain corelib)\n", .{});
        return;
    }

    const trace_path = "/tmp/stwo_zig_bench.trace";
    const memory_path = "/tmp/stwo_zig_bench.memory";

    std.debug.print("Cairo proving flow benchmark\n", .{});
    std.debug.print("============================\n", .{});
    std.debug.print("Program: {s}\n\n", .{cairo_file.?});

    // Stage 1: Execution via cairo1-run subprocess.
    {
        std.debug.print("Stage 1: Cairo VM execution...\n", .{});
        const t = Timer.begin();

        const argv = &[_][]const u8{
            cairo1_run_path,
            cairo_file.?,
            "--layout",
            "all_cairo",
            "--proof_mode",
            "--trace_file",
            trace_path,
            "--memory_file",
            memory_path,
        };

        var child = std.process.Child.init(argv, allocator);
        if (cairo_cwd) |cwd| child.cwd = cwd;
        child.stderr_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        try child.spawn();
        const result = try child.wait();

        if (result.Exited != 0) {
            std.debug.print("  ERROR: cairo1-run exited with code {d}\n", .{result.Exited});
            return;
        }

        std.debug.print("  Execution: {d:.2}ms\n", .{t.elapsedMs()});
    }

    // Stage 2: Load binary files.
    var raw_trace: []trace_reader.RawTraceEntry = undefined;
    var raw_memory: []trace_reader.RawMemoryEntry = undefined;
    {
        std.debug.print("\nStage 2: Load binary trace + memory...\n", .{});
        const t = Timer.begin();

        raw_trace = try trace_reader.readTraceFile(allocator, trace_path);
        raw_memory = try trace_reader.readMemoryFile(allocator, memory_path);

        std.debug.print("  Load: {d:.2}ms\n", .{t.elapsedMs()});
        std.debug.print("  Trace entries: {d}\n", .{raw_trace.len});
        std.debug.print("  Memory entries: {d}\n", .{raw_memory.len});
    }
    defer allocator.free(raw_trace);
    defer allocator.free(raw_memory);

    // Stage 3: Parse into typed structures.
    {
        std.debug.print("\nStage 3: Parse raw entries...\n", .{});
        const t = Timer.begin();

        const stats = trace_reader.memoryStats(raw_memory);
        std.debug.print("  Parse: {d:.2}ms\n", .{t.elapsedMs()});
        std.debug.print("  Max address: {d}\n", .{stats.max_address});
        std.debug.print("  Small values: {d}, Large values: {d}\n", .{ stats.small_values, stats.large_values });
    }

    // Stage 4: Opcode classification.
    {
        std.debug.print("\nStage 4: Opcode classification...\n", .{});
        const t = Timer.begin();

        var states = opcodes.CasmStatesByOpcode.init(allocator);
        defer states.deinit(allocator);

        // Convert trace entries to CasmState and classify.
        // Note: real classification needs the decoded instruction from memory.
        // For now, we measure the conversion + accumulation cost.
        for (raw_trace) |entry| {
            const state = entry.toCasmState();
            try states.get(.generic_opcode).append(allocator, state);
        }

        std.debug.print("  Classification: {d:.2}ms\n", .{t.elapsedMs()});
        std.debug.print("  Total states: {d}\n", .{states.totalCount()});

        // Show per-opcode breakdown.
        std.debug.print("  Breakdown:\n", .{});
        inline for (@typeInfo(opcodes.OpcodeTag).@"enum".fields) |field| {
            const tag: opcodes.OpcodeTag = @enumFromInt(field.value);
            const count = states.getConst(tag).len;
            if (count > 0) {
                std.debug.print("    {s}: {d}\n", .{ field.name, count });
            }
        }
    }

    std.debug.print("\n============================\n", .{});
    std.debug.print("Pipeline complete.\n", .{});
    std.debug.print("Note: Proving stage requires full AIR component implementation.\n", .{});
}
