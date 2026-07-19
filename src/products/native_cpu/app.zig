//! Lifecycle, verification, and publication for the Native CPU/SIMD CLI.

const std = @import("std");
const stwo = @import("stwo_native_cpu");
const runner = @import("native_proof_runner");
const cli = @import("cli.zig");
const identity = @import("identity.zig");
const registry = @import("registry.zig");

const artifacts = stwo.interop.examples_artifact;
const artifact_verifier = stwo.interop.examples_artifact_verifier;
const atomic_file = stwo.interop.atomic_file;

pub fn main() !void {
    const allocator = std.heap.smp_allocator;
    const process_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, process_args);
    const parsed = cli.parse(process_args[1..]) catch |err| {
        try cli.writeUsage(std.fs.File.stderr().deprecatedWriter(), null);
        return err;
    };
    switch (parsed) {
        .help => |command| try cli.writeUsage(std.fs.File.stdout().deprecatedWriter(), command),
        .applications => try writeApplications(),
        .verify => |request| try verifyArtifact(allocator, request),
        .prove => |request| try prove(allocator, request),
        .bench => |request| try bench(allocator, request),
    }
}

fn prove(allocator: std.mem.Allocator, request: cli.Prove) !void {
    try rejectPathCollision(request.output, request.report_out);
    try requireAbsent(request.output);
    if (request.report_out) |path| try requireAbsent(path);
    const temporary = try atomic_file.temporaryPathAlloc(allocator, request.output, "proof");
    defer allocator.free(temporary);
    defer std.fs.cwd().deleteFile(temporary) catch {};
    var args = request.args;
    args.proof_artifact_out = temporary;
    args.proof_artifact_report_path = request.output;
    args.product_identity = identity.value();
    const report = try run(allocator, args);
    defer allocator.free(report);
    try publishResult(allocator, temporary, request.output, report, request.report_out);
}

fn bench(allocator: std.mem.Allocator, request: cli.Bench) !void {
    if (request.proof_out) |proof| try rejectPathCollision(proof, request.report_out);
    if (request.proof_out) |path| try requireAbsent(path);
    if (request.report_out) |path| try requireAbsent(path);
    const temporary = if (request.proof_out) |proof|
        try atomic_file.temporaryPathAlloc(allocator, proof, "proof")
    else
        null;
    defer if (temporary) |path| allocator.free(path);
    defer if (temporary) |path| std.fs.cwd().deleteFile(path) catch {};
    var args = request.args;
    args.proof_artifact_out = temporary;
    args.proof_artifact_report_path = request.proof_out;
    args.product_identity = identity.value();
    const report = try run(allocator, args);
    defer allocator.free(report);
    if (request.proof_out) |proof| {
        try publishResult(allocator, temporary.?, proof, report, request.report_out);
    } else try publishReport(allocator, report, request.report_out);
}

fn run(allocator: std.mem.Allocator, args: runner.config.Args) ![]u8 {
    return runner.run(
        stwo.examples.wide_fibonacci.CpuProverEngine,
        .cpu_native,
        allocator,
        args,
    );
}

fn verifyArtifact(allocator: std.mem.Allocator, request: cli.Verify) !void {
    const verified = try artifact_verifier.verifyPath(
        allocator,
        request.artifact,
        switch (request.security_policy) {
            .secure => .secure,
            .functional => .functional,
            .smoke => .smoke,
        },
    );
    const proof_sha256 = std.fmt.bytesToHex(verified.proof_sha256, .lower);
    const receipt = .{
        .schema_version = @as(u32, 1),
        .status = "verified",
        .product = identity.value(),
        .artifact_schema_version = artifacts.SCHEMA_VERSION,
        .upstream_commit = artifacts.UPSTREAM_COMMIT,
        .exchange_mode = artifacts.EXCHANGE_MODE,
        .security_policy = @tagName(request.security_policy),
        .claimed_generator = @tagName(verified.claimed_generator),
        .air = @tagName(verified.example),
        .proof_bytes = verified.proof_bytes,
        .proof_sha256 = &proof_sha256,
    };
    const encoded = try std.json.Stringify.valueAlloc(allocator, receipt, .{});
    defer allocator.free(encoded);
    try writeLine(std.fs.File.stdout().deprecatedWriter(), encoded);
}

fn publishResult(
    allocator: std.mem.Allocator,
    proof_temporary: []const u8,
    proof_output: []const u8,
    report: []const u8,
    report_output: ?[]const u8,
) !void {
    if (report_output) |output| {
        const report_temporary = try atomic_file.temporaryPathAlloc(allocator, output, "report");
        defer allocator.free(report_temporary);
        defer std.fs.cwd().deleteFile(report_temporary) catch {};
        try atomic_file.writeExclusive(allocator, report_temporary, report);
        try atomic_file.publishExclusive(proof_temporary, proof_output);
        errdefer std.fs.cwd().deleteFile(proof_output) catch {};
        try atomic_file.publishExclusive(report_temporary, output);
        return;
    }
    try atomic_file.publishExclusive(proof_temporary, proof_output);
    try writeLine(std.fs.File.stdout().deprecatedWriter(), report);
}

fn publishReport(
    allocator: std.mem.Allocator,
    report: []const u8,
    report_output: ?[]const u8,
) !void {
    if (report_output) |output| return atomic_file.writeExclusive(allocator, output, report);
    try writeLine(std.fs.File.stdout().deprecatedWriter(), report);
}

fn writeApplications() !void {
    var buffer: [4096]u8 = undefined;
    var output = std.fs.File.stdout().writer(&buffer);
    try registry.write(&output.interface);
    try output.interface.writeByte('\n');
    try output.interface.flush();
}

fn rejectPathCollision(path: []const u8, other: ?[]const u8) !void {
    if (other) |value| if (std.mem.eql(u8, path, value)) return error.OutputPathCollision;
}

fn requireAbsent(path: []const u8) !void {
    std.fs.cwd().access(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    return error.OutputAlreadyExists;
}

fn writeLine(writer: anytype, bytes: []const u8) !void {
    try writer.writeAll(bytes);
    try writer.writeByte('\n');
}

test "bounded proving report carries the exact focused product identity" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const proof_path = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(proof_path);
    const artifact_path = try std.fs.path.join(std.testing.allocator, &.{ proof_path, "proof.json" });
    defer std.testing.allocator.free(artifact_path);
    var args = runner.config.Args{
        .protocol = .smoke,
        .warmups = 0,
        .samples = 1,
        .proof_artifact_out = artifact_path,
        .proof_artifact_report_path = "proof.json",
        .product_identity = identity.value(),
    };
    args.wide_fibonacci = .{ .log_n_rows = 5, .sequence_len = 8 };
    const report = try run(std.testing.allocator, args);
    defer std.testing.allocator.free(report);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, report, .{});
    defer parsed.deinit();
    const product = parsed.value.object.get("product_identity").?.object;
    try std.testing.expectEqualStrings("stwo-native-cpu", product.get("name").?.string);
    try std.testing.expectEqualStrings("cpu", product.get("backend").?.string);
    _ = try artifact_verifier.verifyPath(std.testing.allocator, artifact_path, .smoke);
    const proof_artifact = try std.fs.openFileAbsolute(artifact_path, .{});
    defer proof_artifact.close();
    const artifact_bytes = try proof_artifact.readToEndAlloc(std.testing.allocator, 1 << 20);
    defer std.testing.allocator.free(artifact_bytes);
    const product_identity = identity.value();
    try std.testing.expect(std.mem.indexOf(
        u8,
        artifact_bytes,
        product_identity.identity_sha256,
    ) == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        artifact_bytes,
        product_identity.implementation_commit,
    ) == null);
}
