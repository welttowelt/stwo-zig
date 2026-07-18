//! Runtime backend dispatch into the shared Native proving transaction.

const std = @import("std");
const builtin = @import("builtin");
const stwo = @import("stwo");
const runner = @import("native_proof_runner");
const cli = @import("cli.zig");

pub const Execution = struct {
    warmups: usize,
    samples: usize,
    profiled: bool,
    proof_temporary: ?[]const u8,
    proof_report_path: ?[]const u8,
};

pub fn run(
    allocator: std.mem.Allocator,
    request: cli.Run,
    execution: Execution,
) ![]u8 {
    const args = nativeArgs(request, execution);
    return switch (request.backend) {
        .cpu => runner.run(
            stwo.examples.wide_fibonacci.CpuProverEngine,
            .cpu_native,
            allocator,
            args,
        ),
        .metal_hybrid => {
            if (comptime builtin.os.tag != .macos) return error.MetalBackendUnavailable;
            return runner.run(
                stwo.backends.metal.MetalProverEngine,
                .metal_hybrid,
                allocator,
                args,
            );
        },
    };
}

fn nativeArgs(request: cli.Run, execution: Execution) runner.config.Args {
    var result = runner.config.Args{
        .example = @enumFromInt(@intFromEnum(std.meta.activeTag(request.workload))),
        .protocol = @enumFromInt(@intFromEnum(request.protocol)),
        .warmups = execution.warmups,
        .samples = execution.samples,
        .profiled = execution.profiled,
        .proof_artifact_out = execution.proof_temporary,
        .proof_artifact_report_path = execution.proof_report_path,
        .blake2_backend = @enumFromInt(@intFromEnum(request.blake2_backend)),
        .metal_runtime = .{
            .mode = @enumFromInt(@intFromEnum(request.metal_runtime.mode)),
            .aot_bundle = request.metal_runtime.aot_bundle,
            .manifest_sha256 = request.metal_runtime.manifest_sha256,
        },
    };
    switch (request.workload) {
        .wide_fibonacci => |value| result.wide_fibonacci = .{
            .log_n_rows = value.log_n_rows,
            .sequence_len = value.sequence_len,
        },
        .xor => |value| result.xor = .{
            .log_size = value.log_size,
            .log_step = value.log_step,
            .offset = value.offset,
        },
        .plonk => |value| result.plonk = .{ .log_n_rows = value.log_n_rows },
        .state_machine => |value| result.state_machine = .{
            .log_n_rows = value.log_n_rows,
            .initial_x = value.initial_x,
            .initial_y = value.initial_y,
        },
        .blake => |value| result.blake = .{
            .log_n_rows = value.log_n_rows,
            .n_rounds = value.n_rounds,
        },
        .poseidon => |value| result.poseidon = .{
            .log_n_instances = value.log_n_instances,
        },
    }
    return result;
}

test "native dispatch: CLI workload mapping preserves parameters" {
    const args = nativeArgs(.{
        .backend = .cpu,
        .protocol = .secure,
        .workload = .{ .wide_fibonacci = .{ .log_n_rows = 17, .sequence_len = 31 } },
        .blake2_backend = .simd,
        .metal_runtime = .{},
    }, .{
        .warmups = 2,
        .samples = 7,
        .profiled = true,
        .proof_temporary = "/tmp/proof.tmp",
        .proof_report_path = "proof.json",
    });
    try std.testing.expectEqual(runner.config.Example.wide_fibonacci, args.example);
    try std.testing.expectEqual(runner.config.Protocol.secure, args.protocol);
    try std.testing.expectEqual(@as(u32, 17), args.wide_fibonacci.log_n_rows);
    try std.testing.expectEqual(@as(u32, 31), args.wide_fibonacci.sequence_len);
    try std.testing.expectEqualStrings("proof.json", args.proof_artifact_report_path.?);
}
