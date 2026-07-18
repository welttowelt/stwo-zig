//! Stark-V RV32IM ELF adapter seam behind the production proof CLI.
//!
//! The adapter is deliberately fail-closed: `proveElf` is the one call site
//! the CLI routes `--elf` runs through, and it returns
//! `error.AdapterNotReleaseGated` until the RV32IM AIR and public I/O binding
//! pass the release gate. Wiring the real prover is a one-function change
//! here; the registry entry in `registry.zig` flips only at that moment.

const std = @import("std");
const cli = @import("cli.zig");

pub const AdapterError = error{AdapterNotReleaseGated};

pub const PENDING_DIAGNOSTIC =
    "stark-v adapter: pending release gate (RV32IM AIR completion in progress)";

pub const Options = struct {
    backend: cli.Backend,
    protocol: cli.Protocol,
    blake2_backend: cli.Blake2Backend,
    metal_runtime: cli.MetalRuntime,
};

pub const OutputPaths = struct {
    proof_out: ?[]const u8,
    report_out: ?[]const u8,
};

pub fn proveElf(
    allocator: std.mem.Allocator,
    elf_path: []const u8,
    input_path: ?[]const u8,
    options: Options,
    outputs: OutputPaths,
) AdapterError!void {
    _ = allocator;
    _ = elf_path;
    _ = input_path;
    _ = options;
    _ = outputs;
    return error.AdapterNotReleaseGated;
}
