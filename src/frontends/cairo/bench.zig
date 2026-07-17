//! Cairo proving flow benchmark harness.
//!
//! Measures each stage of the pipeline:
//! 1. Execution: cairo1-run subprocess (Cairo VM)
//! 2. Loading: read binary trace + memory files
//! 3. Parsing: convert raw entries to CasmState + Memory
//! 4. Adapter: opcode classification into 20 categories
//!
//! Backend selection belongs to the executable integration boundary. The root
//! benchmark CLI invokes `run` with its concrete backend.

const std = @import("std");
const trace_reader = @import("adapter/trace_reader.zig");

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

pub fn run(comptime B: type) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Parse arguments.
    var cairo_file: ?[]const u8 = null;
    var cairo1_run_path: []const u8 = "cairo1-run";
    var cairo_cwd: ?[]const u8 = null;
    var synthetic_log_size: ?u32 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--cairo1-run") and i + 1 < args.len) {
            i += 1;
            cairo1_run_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--cairo-cwd") and i + 1 < args.len) {
            i += 1;
            cairo_cwd = args[i];
        } else if (std.mem.eql(u8, args[i], "--synthetic") and i + 1 < args.len) {
            i += 1;
            synthetic_log_size = std.fmt.parseInt(u32, args[i], 10) catch null;
        } else {
            cairo_file = args[i];
        }
    }

    if (cairo_file == null and synthetic_log_size == null) {
        std.debug.print("Usage: cairo-bench <cairo-file> [--cairo1-run <path>] [--cairo-cwd <dir>]\n", .{});
        std.debug.print("       cairo-bench --synthetic <log_size>\n", .{});
        std.debug.print("\nOptions:\n", .{});
        std.debug.print("  --cairo1-run <path>   Path to cairo1-run binary\n", .{});
        std.debug.print("  --cairo-cwd <dir>     Working directory for cairo1-run (must contain corelib)\n", .{});
        std.debug.print("  --synthetic <log_size> Generate synthetic trace with 2^log_size entries\n", .{});
        return;
    }

    const prove_trace_mod = @import("prove_trace.zig");
    const pcs_core_mod = @import("../../core/pcs/mod.zig");

    std.debug.print("Cairo Proving Benchmark\n", .{});
    std.debug.print("============================\n", .{});

    var raw_trace: []trace_reader.RawTraceEntry = undefined;
    var raw_trace_allocated = false;
    var log_size: u32 = undefined;

    if (synthetic_log_size) |syn_log| {
        // Synthetic mode: generate a fake trace.
        log_size = syn_log;
        const n: usize = @as(usize, 1) << @intCast(syn_log);
        std.debug.print("Mode: synthetic (2^{d} = {d} entries)\n\n", .{ syn_log, n });

        const t = Timer.begin();
        raw_trace = try allocator.alloc(trace_reader.RawTraceEntry, n);
        raw_trace_allocated = true;
        for (raw_trace, 0..) |*entry, idx| {
            // Simulate a simple execution: pc increments, ap grows slowly, fp stays near ap.
            entry.pc = @intCast(idx * 2);
            entry.ap = @intCast(1024 + idx);
            entry.fp = @intCast(1024 + idx - (idx % 16));
        }
        std.debug.print("Trace generation: {d:.2}ms\n", .{t.elapsedMs()});
    } else {
        // File mode: run cairo1-run and load trace.
        std.debug.print("Program: {s}\n\n", .{cairo_file.?});
        const trace_path = "/tmp/stwo_zig_bench.trace";
        const memory_path = "/tmp/stwo_zig_bench.memory";

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
        {
            std.debug.print("\nStage 2: Load binary trace + memory...\n", .{});
            const t = Timer.begin();

            raw_trace = try trace_reader.readTraceFile(allocator, trace_path);
            raw_trace_allocated = true;
            const raw_memory = try trace_reader.readMemoryFile(allocator, memory_path);
            defer allocator.free(raw_memory);

            std.debug.print("  Load: {d:.2}ms\n", .{t.elapsedMs()});
            std.debug.print("  Trace entries: {d}\n", .{raw_trace.len});
            std.debug.print("  Memory entries: {d}\n", .{raw_memory.len});
        }

        const n_trace = raw_trace.len;
        log_size = @intCast(std.math.log2_int_ceil(usize, if (n_trace == 0) 1 else n_trace));
    }
    defer if (raw_trace_allocated) allocator.free(raw_trace);
    const n_entries = raw_trace.len;
    std.debug.print("Trace entries: {d}\n", .{n_entries});
    std.debug.print("Security: pow_bits=0, n_queries=3\n\n", .{});

    const config = pcs_core_mod.PcsConfig{
        .pow_bits = 0,
        .fri_config = .{
            .log_blowup_factor = 1,
            .log_last_layer_degree_bound = 0,
            .n_queries = 3,
        },
    };

    // Prove
    var prove_ms: f64 = undefined;
    var prove_result: prove_trace_mod.ProveOutput = undefined;
    {
        const t = Timer.begin();

        prove_result = try prove_trace_mod.proveCairoTrace(
            B,
            allocator,
            config,
            raw_trace,
            log_size,
        );

        prove_ms = t.elapsedMs();
        std.debug.print("Prove:    {d:.1}ms\n", .{prove_ms});
    }
    defer {
        var p = prove_result;
        p.proof.deinit(allocator);
    }

    // Verify
    var verify_ms: f64 = undefined;
    {
        const t = Timer.begin();

        try prove_trace_mod.verifyCairoTrace(
            allocator,
            config,
            prove_result.statement,
            prove_result.proof,
        );

        verify_ms = t.elapsedMs();
        std.debug.print("Verify:   {d:.1}ms\n", .{verify_ms});
    }

    // Summary
    const total_ms = prove_ms + verify_ms;
    const throughput_khz = @as(f64, @floatFromInt(n_entries)) / prove_ms;
    std.debug.print("\nTotal:    {d:.1}ms\n", .{total_ms});
    std.debug.print("Throughput (entries/prove): {d:.1} kHz\n", .{throughput_khz});
}
