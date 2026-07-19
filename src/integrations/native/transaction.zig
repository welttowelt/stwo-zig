//! Backend-neutral Native proof transaction used by focused and aggregate CLIs.

const std = @import("std");
const output_transaction = @import("output_transaction");

pub fn prove(
    comptime AtomicFile: type,
    allocator: std.mem.Allocator,
    proof_output: []const u8,
    report_output: ?[]const u8,
    context: anytype,
    comptime run: fn (@TypeOf(context), ?[]const u8, ?[]const u8) anyerror![]u8,
) !void {
    try output_transaction.prepare(proof_output, report_output);
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
    try output_transaction.prepare(proof_output, report_output);
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

pub fn prepare(proof_output: ?[]const u8, report_output: ?[]const u8) !void {
    return output_transaction.prepare(proof_output, report_output);
}

pub fn publishResult(
    comptime AtomicFile: type,
    allocator: std.mem.Allocator,
    proof_temporary: []const u8,
    proof_output: []const u8,
    report: []const u8,
    report_output: ?[]const u8,
) !void {
    try output_transaction.publishResult(
        AtomicFile,
        allocator,
        proof_temporary,
        proof_output,
        report,
        report_output,
        std.fs.File.stdout().deprecatedWriter(),
    );
}

pub fn publishReport(
    comptime AtomicFile: type,
    allocator: std.mem.Allocator,
    report: []const u8,
    report_output: ?[]const u8,
) !void {
    try output_transaction.publishReport(
        AtomicFile,
        allocator,
        report,
        report_output,
        std.fs.File.stdout().deprecatedWriter(),
    );
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
