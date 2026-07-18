//! Stark-V RV32IM ELF adapter seam behind the production proof CLI.
//!
//! The adapter is deliberately fail-closed: `proveElf` is the one call site
//! the CLI routes `--elf` runs through, and it returns
//! `error.AdapterNotReleaseGated` until the RV32IM AIR and public I/O binding
//! pass the release gate. Wiring the real prover is a one-function change
//! here; the registry entry in `registry.zig` flips only at that moment.

const std = @import("std");
const stwo = @import("stwo");
const cli = @import("cli.zig");

pub const AdapterError = error{AdapterNotReleaseGated};

pub const PENDING_DIAGNOSTIC =
    "stark-v adapter: pending release gate (opcode, memory, and public I/O AIR constraints are incomplete)";

pub const Benchmark = struct {
    warmups: usize,
    samples: usize,
    profiled: bool,
};

pub const Mode = union(enum) {
    prove,
    bench: Benchmark,
};

pub const Options = struct {
    backend: cli.Backend,
    protocol: cli.Protocol,
    blake2_backend: cli.Blake2Backend,
    metal_runtime: cli.MetalRuntime,
    mode: Mode,
    /// Sibling temporary path owned and published by the CLI transaction.
    proof_temporary: ?[]const u8,
    /// Final path recorded in the report; the adapter never publishes it.
    proof_report_path: ?[]const u8,
};

/// Runs the staged ELF adapter and returns an owned machine-readable report.
///
/// Keeping publication outside the adapter gives Native and RISC-V workloads
/// identical exclusive-output and rollback behavior when the release gate is
/// eventually opened.
pub fn run(
    allocator: std.mem.Allocator,
    elf_path: []const u8,
    input_path: ?[]const u8,
    options: Options,
) ![]u8 {
    _ = allocator;
    _ = elf_path;
    _ = input_path;
    _ = options;
    return error.AdapterNotReleaseGated;
}

/// Recognizes and structurally validates the staged artifact before refusing
/// cryptographic acceptance. This prevents malformed or provenance-drifted
/// envelopes from being mislabeled as merely pending the release gate.
pub fn verifyArtifact(allocator: std.mem.Allocator, path: []const u8) !void {
    try stwo.interop.riscv_artifact.validatePath(allocator, path);
    return error.AdapterNotReleaseGated;
}

test "adapter preserves the complete sampled benchmark contract while gated" {
    const options = Options{
        .backend = .cpu,
        .protocol = .functional,
        .blake2_backend = .simd,
        .metal_runtime = .{},
        .mode = .{ .bench = .{ .warmups = 3, .samples = 7, .profiled = true } },
        .proof_temporary = "proof.tmp",
        .proof_report_path = "proof.json",
    };
    try std.testing.expectEqual(@as(usize, 3), options.mode.bench.warmups);
    try std.testing.expectEqual(@as(usize, 7), options.mode.bench.samples);
    try std.testing.expect(options.mode.bench.profiled);
    try std.testing.expectError(
        error.AdapterNotReleaseGated,
        run(std.testing.allocator, "guest.elf", "input.bin", options),
    );
}
