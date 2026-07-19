//! Backend-neutral Native proof transaction used by focused and aggregate CLIs.

const std = @import("std");

pub fn prove(
    comptime AtomicFile: type,
    allocator: std.mem.Allocator,
    proof_output: []const u8,
    report_output: ?[]const u8,
    context: anytype,
    comptime run: fn (@TypeOf(context), ?[]const u8, ?[]const u8) anyerror![]u8,
) !void {
    try rejectPathCollision(proof_output, report_output);
    try requireAbsent(proof_output);
    if (report_output) |path| try requireAbsent(path);
    const temporary = try AtomicFile.temporaryPathAlloc(allocator, proof_output, "proof");
    defer allocator.free(temporary);
    defer std.fs.cwd().deleteFile(temporary) catch {};
    const report = try run(context, temporary, proof_output);
    defer allocator.free(report);
    try publishResult(AtomicFile, allocator, temporary, proof_output, report, report_output);
}

pub fn bench(
    comptime AtomicFile: type,
    allocator: std.mem.Allocator,
    proof_output: ?[]const u8,
    report_output: ?[]const u8,
    context: anytype,
    comptime run: fn (@TypeOf(context), ?[]const u8, ?[]const u8) anyerror![]u8,
) !void {
    if (proof_output) |proof| try rejectPathCollision(proof, report_output);
    if (proof_output) |path| try requireAbsent(path);
    if (report_output) |path| try requireAbsent(path);
    const temporary = if (proof_output) |proof|
        try AtomicFile.temporaryPathAlloc(allocator, proof, "proof")
    else
        null;
    defer if (temporary) |path| allocator.free(path);
    defer if (temporary) |path| std.fs.cwd().deleteFile(path) catch {};
    const report = try run(context, temporary, proof_output);
    defer allocator.free(report);
    if (proof_output) |proof| {
        try publishResult(AtomicFile, allocator, temporary.?, proof, report, report_output);
    } else {
        try publishReport(AtomicFile, allocator, report, report_output);
    }
}

pub fn publishResult(
    comptime AtomicFile: type,
    allocator: std.mem.Allocator,
    proof_temporary: []const u8,
    proof_output: []const u8,
    report: []const u8,
    report_output: ?[]const u8,
) !void {
    if (report_output) |output| {
        const report_temporary = try AtomicFile.temporaryPathAlloc(allocator, output, "report");
        defer allocator.free(report_temporary);
        defer std.fs.cwd().deleteFile(report_temporary) catch {};
        try AtomicFile.writeExclusive(allocator, report_temporary, report);
        try AtomicFile.publishExclusive(proof_temporary, proof_output);
        errdefer std.fs.cwd().deleteFile(proof_output) catch {};
        try AtomicFile.publishExclusive(report_temporary, output);
        return;
    }
    try AtomicFile.publishExclusive(proof_temporary, proof_output);
    try writeLine(std.fs.File.stdout().deprecatedWriter(), report);
}

pub fn publishReport(
    comptime AtomicFile: type,
    allocator: std.mem.Allocator,
    report: []const u8,
    report_output: ?[]const u8,
) !void {
    if (report_output) |output| return AtomicFile.writeExclusive(allocator, output, report);
    try writeLine(std.fs.File.stdout().deprecatedWriter(), report);
}

pub fn verifyPath(
    comptime Verifier: type,
    comptime Artifacts: type,
    allocator: std.mem.Allocator,
    path: []const u8,
    policy: Verifier.SecurityPolicy,
    product: anytype,
) ![]u8 {
    const verified = try Verifier.verifyPath(allocator, path, policy);
    return verificationReceipt(Artifacts, allocator, verified, policy, product);
}

pub fn verifyBytes(
    comptime Verifier: type,
    comptime Artifacts: type,
    allocator: std.mem.Allocator,
    bytes: []const u8,
    policy: Verifier.SecurityPolicy,
    product: anytype,
) ![]u8 {
    const verified = try Verifier.verifyBytes(allocator, bytes, policy);
    return verificationReceipt(Artifacts, allocator, verified, policy, product);
}

fn verificationReceipt(
    comptime Artifacts: type,
    allocator: std.mem.Allocator,
    verified: anytype,
    policy: anytype,
    product: anytype,
) ![]u8 {
    const proof_sha256 = std.fmt.bytesToHex(verified.proof_sha256, .lower);
    return std.json.Stringify.valueAlloc(allocator, .{
        .schema_version = @as(u32, 1),
        .status = "verified",
        .product = product,
        .artifact_schema_version = Artifacts.SCHEMA_VERSION,
        .upstream_commit = Artifacts.UPSTREAM_COMMIT,
        .exchange_mode = Artifacts.EXCHANGE_MODE,
        .security_policy = @tagName(policy),
        .claimed_generator = @tagName(verified.claimed_generator),
        .air = @tagName(verified.example),
        .proof_bytes = verified.proof_bytes,
        .proof_sha256 = &proof_sha256,
    }, .{});
}

pub fn writeLine(writer: anytype, bytes: []const u8) !void {
    try writer.writeAll(bytes);
    try writer.writeByte('\n');
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
