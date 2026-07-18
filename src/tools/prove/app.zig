//! Production proof CLI lifecycle, dispatch, verification, and publication.

const std = @import("std");
const stwo = @import("stwo");
const cli = @import("cli.zig");
const native_dispatch = @import("native_dispatch.zig");
const registry = @import("registry.zig");

const atomic_file = stwo.interop.atomic_file;
const artifact_verifier = stwo.interop.examples_artifact_verifier;

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
    const proof_temporary = try atomic_file.temporaryPathAlloc(allocator, request.output, "proof");
    defer allocator.free(proof_temporary);
    defer std.fs.cwd().deleteFile(proof_temporary) catch {};
    const report = try native_dispatch.run(allocator, request.run, .{
        .warmups = 0,
        .samples = 1,
        .profiled = false,
        .proof_temporary = proof_temporary,
        .proof_report_path = request.output,
    });
    defer allocator.free(report);
    try publishResult(allocator, proof_temporary, request.output, report, request.report_out);
}

fn bench(allocator: std.mem.Allocator, request: cli.Bench) !void {
    if (request.proof_out) |proof_out| try rejectPathCollision(proof_out, request.report_out);
    if (request.proof_out) |path| try requireAbsent(path);
    if (request.report_out) |path| try requireAbsent(path);
    const proof_temporary = if (request.proof_out) |proof_out|
        try atomic_file.temporaryPathAlloc(allocator, proof_out, "proof")
    else
        null;
    defer if (proof_temporary) |path| allocator.free(path);
    defer if (proof_temporary) |path| std.fs.cwd().deleteFile(path) catch {};
    const report = try native_dispatch.run(allocator, request.run, .{
        .warmups = request.warmups,
        .samples = request.samples,
        .profiled = request.profiled,
        .proof_temporary = proof_temporary,
        .proof_report_path = request.proof_out,
    });
    defer allocator.free(report);
    if (request.proof_out) |proof_out| {
        try publishResult(allocator, proof_temporary.?, proof_out, report, request.report_out);
    } else {
        try publishReport(allocator, report, request.report_out);
    }
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

fn verifyArtifact(allocator: std.mem.Allocator, request: cli.Verify) !void {
    const verified = try artifact_verifier.verifyPath(
        allocator,
        request.artifact,
        switch (request.protocol) {
            .secure => .secure,
            .functional => .functional,
            .smoke => .smoke,
        },
    );
    var proof_sha256 = std.fmt.bytesToHex(verified.proof_sha256, .lower);
    const receipt = .{
        .schema_version = @as(u32, 1),
        .status = "verified",
        .artifact_schema_version = stwo.interop.examples_artifact.SCHEMA_VERSION,
        .upstream_commit = stwo.interop.examples_artifact.UPSTREAM_COMMIT,
        .exchange_mode = stwo.interop.examples_artifact.EXCHANGE_MODE,
        .security_policy = @tagName(request.protocol),
        .claimed_generator = @tagName(verified.claimed_generator),
        .air = @tagName(verified.example),
        .proof_bytes = verified.proof_bytes,
        .proof_sha256 = &proof_sha256,
    };
    const encoded = try std.json.Stringify.valueAlloc(allocator, receipt, .{});
    defer allocator.free(encoded);
    try writeLine(std.fs.File.stdout().deprecatedWriter(), encoded);
}

fn writeApplications() !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    try registry.write(stdout);
    try stdout.writeByte('\n');
}

fn rejectPathCollision(path: []const u8, maybe_other: ?[]const u8) !void {
    if (maybe_other) |other| {
        if (std.mem.eql(u8, path, other)) return error.OutputPathCollision;
    }
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

test "publication never replaces a competing report or deletes its verified proof" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const proof_temporary = try std.fs.path.join(std.testing.allocator, &.{ root, "proof.tmp" });
    defer std.testing.allocator.free(proof_temporary);
    const proof_output = try std.fs.path.join(std.testing.allocator, &.{ root, "proof.json" });
    defer std.testing.allocator.free(proof_output);
    const report_output = try std.fs.path.join(std.testing.allocator, &.{ root, "report.json" });
    defer std.testing.allocator.free(report_output);

    try atomic_file.writeExclusive(std.testing.allocator, proof_temporary, "proof");
    try atomic_file.writeExclusive(std.testing.allocator, report_output, "existing");
    try std.testing.expectError(
        error.PathAlreadyExists,
        publishResult(
            std.testing.allocator,
            proof_temporary,
            proof_output,
            "report",
            report_output,
        ),
    );
    const proof = try std.fs.cwd().readFileAlloc(std.testing.allocator, proof_output, 32);
    defer std.testing.allocator.free(proof);
    try std.testing.expectEqualStrings("proof", proof);
    const report = try std.fs.cwd().readFileAlloc(std.testing.allocator, report_output, 32);
    defer std.testing.allocator.free(report);
    try std.testing.expectEqualStrings("existing", report);
}
