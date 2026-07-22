//! C-ABI shim exposing the native proof bench to mobile app shells.
//!
//! Compiled as a static library (root module = this file), it pulls
//! `runner.zig` and its `config.zig` into one module instantiation, so no
//! upstream file changes are needed. The app passes a bench arg string
//! (same grammar as the CLI, without the program name); the shim returns
//! the machine-readable report JSON produced by `runner.run`.
//!
//! Contract:
//! - `stwo_mobile_bench("--example plonk --log-n-rows 12 --protocol functional --warmups 1 --samples 3")`
//!   returns a NUL-terminated JSON report on success, or a NUL-terminated
//!   string beginning with `error:` on failure. Never null.
//! - The caller MUST release the returned pointer with
//!   `stwo_mobile_bench_free`.
//! - Arguments are split on single spaces; paths with spaces are not
//!   supported (none are needed for the native examples).

const std = @import("std");
const stwo = @import("stwo");
const runner = @import("runner.zig");
const config = @import("config.zig");

const allocator = std.heap.smp_allocator;

/// Static fallback for the pathological case where even the error message
/// cannot be heap-allocated. `stwo_mobile_bench_free` recognizes and skips
/// it, so the caller-side contract ("always free the result") stays safe.
var oom_sentinel: [19:0]u8 = "error: OutOfMemory\x00".*;

export fn stwo_mobile_bench(arg_line: [*:0]const u8) [*:0]u8 {
    return benchImpl(std.mem.span(arg_line)) catch |err| dupeError(err);
}

export fn stwo_mobile_bench_free(ptr: [*:0]u8) void {
    if (@intFromPtr(ptr) == @intFromPtr(&oom_sentinel)) return;
    allocator.free(std.mem.span(ptr));
}

fn benchImpl(line: []const u8) ![*:0]u8 {
    var argz = std.ArrayList([:0]const u8).empty;
    defer {
        for (argz.items) |a| allocator.free(a);
        argz.deinit(allocator);
    }
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    while (it.next()) |tok| {
        try argz.append(allocator, try allocator.dupeZ(u8, tok));
    }

    const parsed = try config.parseArgs(.cpu_native, argz.items);
    switch (parsed) {
        .help => return try allocator.dupeZ(u8, "error: help requested"),
        .run => |parsed_args| {
            const encoded = try runner.run(
                stwo.examples.wide_fibonacci.CpuProverEngine,
                .cpu_native,
                allocator,
                parsed_args,
            );
            defer allocator.free(encoded);
            return try allocator.dupeZ(u8, encoded);
        },
    }
}

fn dupeError(err: anyerror) [*:0]u8 {
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "error: {s}", .{@errorName(err)}) catch "error: OutOfMemory";
    return allocator.dupeZ(u8, msg) catch &oom_sentinel;
}
