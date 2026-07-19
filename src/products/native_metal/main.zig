//! Focused Native Metal proof and benchmark entry point.

const std = @import("std");
const stwo = @import("stwo_native_metal");
const runner = @import("native_proof_runner");
const identity = @import("identity.zig");
const registry = @import("registry.zig");

const Parsed = union(enum) {
    help,
    applications,
    run: runner.config.Args,
};

pub fn main() !void {
    const allocator = std.heap.smp_allocator;
    const process_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, process_args);
    switch (try parse(process_args[1..])) {
        .help => try writeUsage(std.fs.File.stdout().deprecatedWriter()),
        .applications => try writeApplications(),
        .run => |parsed_args| {
            var args = parsed_args;
            args.product_identity = identity.value();
            const encoded = try runner.run(
                stwo.backends.metal.MetalProverEngine,
                .metal_hybrid,
                allocator,
                args,
            );
            defer allocator.free(encoded);
            const stdout = std.fs.File.stdout().deprecatedWriter();
            try stdout.writeAll(encoded);
            try stdout.writeByte('\n');
        },
    }
}

fn parse(argv: []const []const u8) !Parsed {
    if (argv.len == 1 and (std.mem.eql(u8, argv[0], "--help") or
        std.mem.eql(u8, argv[0], "-h"))) return .help;
    if (argv.len != 0 and std.mem.eql(u8, argv[0], "applications")) {
        if (argv.len != 1) return error.IrrelevantArgument;
        return .applications;
    }
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--backend") or
            std.mem.startsWith(u8, arg, "--cuda-") or
            std.mem.eql(u8, arg, "--elf") or
            std.mem.eql(u8, arg, "--input")) return error.UnsupportedCapability;
    }
    return switch (try runner.config.parseArgs(.metal_hybrid, argv)) {
        .help => .help,
        .run => |args| .{ .run = args },
    };
}

fn writeUsage(writer: anytype) !void {
    try writer.writeAll(
        \\Usage: stwo-zig-native-metal [applications|options]
        \\
        \\  applications          Print the compiled application registry
        \\  --example NAME        wide_fibonacci, xor, plonk, state_machine, blake, poseidon
        \\  --protocol NAME       smoke, functional, or secure
        \\  --warmups N           Verified untimed warmups
        \\  --samples N           Verified timed samples
        \\  --proof-artifact-out PATH
        \\  --metal-runtime MODE  source-jit or authenticated-aot
        \\  --metal-aot-bundle PATH
        \\  --metal-aot-manifest-sha256 HEX
        \\  --profiled            Diagnostic instrumentation
        \\  -h, --help            Show this help
        \\
        \\Backend: Apple Metal only. Device-labelled runs do not fall back to CPU.
        \\
    );
}

fn writeApplications() !void {
    var buffer: [4096]u8 = undefined;
    var output = std.fs.File.stdout().writer(&buffer);
    try registry.write(&output.interface);
    try output.interface.writeByte('\n');
    try output.interface.flush();
}

test "parser accepts Metal runtime policy and rejects foreign selectors" {
    const request = (try parse(&.{
        "--example",       "wide_fibonacci",
        "--log-n-rows",    "5",
        "--sequence-len",  "8",
        "--protocol",      "smoke",
        "--warmups",       "0",
        "--samples",       "1",
        "--metal-runtime", "source-jit",
    })).run;
    try std.testing.expectEqual(runner.config.MetalRuntimeMode.source_jit, request.metal_runtime.mode);
    try std.testing.expectError(error.UnsupportedCapability, parse(&.{ "--backend", "cpu" }));
    try std.testing.expectError(error.UnsupportedCapability, parse(&.{ "--cuda-library", "/tmp/lib" }));
    try std.testing.expectError(error.UnsupportedCapability, parse(&.{ "--elf", "program.elf" }));
}

test "help and generated identity expose one product and backend" {
    var storage: [4096]u8 = undefined;
    var output = std.Io.Writer.fixed(&storage);
    try writeUsage(&output);
    try std.testing.expect(std.mem.indexOf(u8, output.buffered(), "stwo-zig-native-metal") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.buffered(), "CUDA") == null);
    try std.testing.expectEqualStrings("stwo-native-metal", identity.value().name);
    try std.testing.expectEqualStrings("metal", identity.value().backend);
}
