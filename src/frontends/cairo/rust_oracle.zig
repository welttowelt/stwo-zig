//! Pinned process boundary for canonical Rust Cairo proof verification.
const std = @import("std");
const prover = @import("prover.zig");
const compact_interchange = @import("compact_verifier_interchange.zig");

pub const cargo_lock_sha256 = "72ee6a80235ff78a6e2c1724a8c6d1c45798c2a11c1c1539bc675af066b0e31c";
pub const adapter_version = "0.1.0";

const result_suffix = ".rust-verify.json";
const max_result_bytes: usize = 1 << 20;
const verifier_timeout_ns: u64 = 30 * std.time.ns_per_s;
const termination_grace_ns: u64 = 2 * std.time.ns_per_s;

pub const AuthenticatedExecutable = struct {
    path: []const u8,
    sha256: [32]u8,
};

/// Concrete implementation of `prover.proveCairo`'s `Oracle` contract.
///
/// Paths and expected digests are borrowed for the lifetime of this value.
/// `verifyCairo` authenticates them again before and after every invocation.
pub const RustOracle = struct {
    executable: AuthenticatedExecutable,
    cargo_lock_path: []const u8,

    pub fn init(
        executable: AuthenticatedExecutable,
        cargo_lock_path: []const u8,
    ) !RustOracle {
        try validateCanonicalAbsolutePath(executable.path);
        try validateCanonicalAbsolutePath(cargo_lock_path);
        const executable_measurement = try measureFile(executable.path, null);
        if (!std.mem.eql(u8, &executable_measurement.sha256, &executable.sha256))
            return error.RustVerifierExecutableDigestMismatch;
        _ = try measurePinnedCargoLock(cargo_lock_path);
        return .{
            .executable = executable,
            .cargo_lock_path = cargo_lock_path,
        };
    }

    pub fn verifyCairo(
        self: *RustOracle,
        allocator: std.mem.Allocator,
        envelope_path: []const u8,
    ) !prover.OracleEvidence {
        try validateCanonicalAbsolutePath(envelope_path);
        const executable_before = try self.measureExecutable();
        const lock_before = try measurePinnedCargoLock(self.cargo_lock_path);
        const envelope_before = try inspectEnvelope(envelope_path);

        const result_path = try std.mem.concat(allocator, u8, &.{ envelope_path, result_suffix });
        defer allocator.free(result_path);
        try requireAbsent(result_path);
        defer std.fs.deleteFileAbsolute(result_path) catch {};

        const term = try runDirectWithTimeout(
            allocator,
            &.{
                self.executable.path,
                "verify",
                "--envelope",
                envelope_path,
                "--result",
                result_path,
            },
            std.fs.path.dirname(envelope_path),
        );
        switch (term) {
            .Exited => |code| if (code != 0) return error.RustVerifierRejected,
            else => return error.RustVerifierAbnormalTermination,
        }

        const executable_after = try self.measureExecutable();
        const lock_after = try measurePinnedCargoLock(self.cargo_lock_path);
        if (!executable_before.eql(executable_after) or !lock_before.eql(lock_after))
            return error.RustVerifierIdentityChanged;

        try validateResult(allocator, result_path, executable_after.sha256, envelope_before);
        const envelope_after = try inspectEnvelope(envelope_path);
        if (!envelope_before.eql(envelope_after)) return error.EnvelopeChangedDuringVerification;

        return .{
            .verified = true,
            .envelope_sha256 = envelope_after.sha256,
            .envelope_abi = prover.canonical_envelope_abi,
            .verification_mode = prover.canonical_verification_mode,
            .stwo_cairo_revision = prover.pinned_stwo_cairo_revision,
            .stwo_revision = prover.pinned_stwo_revision,
        };
    }

    fn measureExecutable(self: RustOracle) !Measurement {
        const measurement = try measureFile(self.executable.path, null);
        if (!std.mem.eql(u8, &measurement.sha256, &self.executable.sha256))
            return error.RustVerifierExecutableDigestMismatch;
        return measurement;
    }
};

const Measurement = struct {
    sha256: [32]u8,
    stat: std.fs.File.Stat,

    fn eql(left: Measurement, right: Measurement) bool {
        return sameFile(left.stat, right.stat) and
            std.mem.eql(u8, &left.sha256, &right.sha256);
    }
};

const EnvelopeInspection = struct {
    sha256: [32]u8,
    stat: std.fs.File.Stat,
    section_sha256: [compact_interchange.section_count][32]u8,

    fn eql(left: EnvelopeInspection, right: EnvelopeInspection) bool {
        return sameFile(left.stat, right.stat) and
            std.mem.eql(u8, &left.sha256, &right.sha256) and
            std.mem.eql(u8, std.mem.asBytes(&left.section_sha256), std.mem.asBytes(&right.section_sha256));
    }
};

fn validateCanonicalAbsolutePath(path: []const u8) !void {
    if (!std.fs.path.isAbsolute(path)) return error.PathNotAbsolute;
    const canonical = try std.fs.realpathAlloc(std.heap.page_allocator, path);
    defer std.heap.page_allocator.free(canonical);
    if (!std.mem.eql(u8, canonical, path)) return error.PathNotCanonical;
}

fn measurePinnedCargoLock(path: []const u8) !Measurement {
    const measurement = try measureFile(path, null);
    const actual = std.fmt.bytesToHex(measurement.sha256, .lower);
    if (!std.mem.eql(u8, &actual, cargo_lock_sha256)) return error.CargoLockDigestMismatch;
    return measurement;
}

fn measureFile(path: []const u8, maximum_bytes: ?u64) !Measurement {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const before = try file.stat();
    if (before.kind != .file or before.size == 0 or
        (maximum_bytes != null and before.size > maximum_bytes.?))
        return error.InvalidAuthenticatedFile;

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [256 * 1024]u8 = undefined;
    var byte_count: u64 = 0;
    while (true) {
        const read = try file.read(&buffer);
        if (read == 0) break;
        hasher.update(buffer[0..read]);
        byte_count = std.math.add(u64, byte_count, read) catch return error.FileLengthOverflow;
    }
    const after = try file.stat();
    if (byte_count != before.size or !sameFile(before, after))
        return error.AuthenticatedFileChangedDuringRead;
    return .{ .sha256 = hasher.finalResult(), .stat = after };
}

fn inspectEnvelope(path: []const u8) !EnvelopeInspection {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const before = try file.stat();
    if (before.kind != .file or before.size == 0 or
        before.size > compact_interchange.max_envelope_bytes)
        return error.InvalidCompactEnvelope;

    var envelope_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var envelope_header: [compact_interchange.envelope_header_bytes]u8 = undefined;
    if (try file.readAll(&envelope_header) != envelope_header.len or
        !std.mem.eql(u8, envelope_header[0..8], &compact_interchange.envelope_magic) or
        std.mem.readInt(u16, envelope_header[8..10], .little) != compact_interchange.envelope_version or
        std.mem.readInt(u16, envelope_header[10..12], .little) != compact_interchange.envelope_header_bytes or
        std.mem.readInt(u32, envelope_header[12..16], .little) != 0 or
        std.mem.readInt(u32, envelope_header[16..20], .little) != compact_interchange.section_count or
        std.mem.readInt(u32, envelope_header[20..24], .little) != 0 or
        std.mem.readInt(u64, envelope_header[24..32], .little) != before.size)
        return error.InvalidCompactEnvelope;
    envelope_hasher.update(&envelope_header);

    var section_digests: [compact_interchange.section_count][32]u8 = undefined;
    var consumed: u64 = compact_interchange.envelope_header_bytes;
    for (0..compact_interchange.section_count) |index| {
        var section_header: [compact_interchange.section_header_bytes]u8 = undefined;
        if (try file.readAll(&section_header) != section_header.len or
            std.mem.readInt(u16, section_header[0..2], .little) != index + 1 or
            std.mem.readInt(u16, section_header[2..4], .little) != compact_interchange.section_flag_mandatory or
            std.mem.readInt(u32, section_header[4..8], .little) != 0)
            return error.InvalidCompactEnvelope;
        envelope_hasher.update(&section_header);
        const payload_bytes = std.mem.readInt(u64, section_header[8..16], .little);
        const maximum = sectionMaximumBytes(index);
        if (payload_bytes == 0 or payload_bytes > maximum)
            return error.InvalidCompactEnvelope;
        @memcpy(&section_digests[index], section_header[16..48]);
        consumed = std.math.add(u64, consumed, section_header.len) catch
            return error.InvalidCompactEnvelope;
        consumed = std.math.add(u64, consumed, payload_bytes) catch
            return error.InvalidCompactEnvelope;
        if (consumed > before.size) return error.InvalidCompactEnvelope;

        var payload_hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var remaining = payload_bytes;
        var buffer: [256 * 1024]u8 = undefined;
        while (remaining != 0) {
            const requested: usize = @intCast(@min(remaining, buffer.len));
            const read = try file.read(buffer[0..requested]);
            if (read == 0) return error.InvalidCompactEnvelope;
            payload_hasher.update(buffer[0..read]);
            envelope_hasher.update(buffer[0..read]);
            remaining -= read;
        }
        const actual_digest = payload_hasher.finalResult();
        if (!std.mem.eql(u8, &actual_digest, &section_digests[index]))
            return error.InvalidCompactEnvelope;
    }
    if (consumed != before.size) return error.InvalidCompactEnvelope;
    const after = try file.stat();
    if (!sameFile(before, after)) return error.EnvelopeChangedDuringRead;
    return .{
        .sha256 = envelope_hasher.finalResult(),
        .stat = after,
        .section_sha256 = section_digests,
    };
}

fn sectionMaximumBytes(index: usize) u64 {
    return switch (index) {
        0 => 4 << 20,
        1 => 256 << 20,
        2 => 512 << 20,
        3 => 16 << 20,
        else => unreachable,
    };
}

fn requireAbsent(path: []const u8) !void {
    if (std.fs.accessAbsolute(path, .{})) |_| return error.RustVerifierResultAlreadyExists else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
}

const VerifierWatchdog = struct {
    pid: std.posix.pid_t,
    complete: std.Thread.ResetEvent = .{},
    timed_out: bool = false,
    signal_failed: bool = false,

    fn signalGroup(self: *VerifierWatchdog, signal: u8) void {
        std.posix.kill(-self.pid, signal) catch |group_error| switch (group_error) {
            error.ProcessNotFound => return,
            else => std.posix.kill(self.pid, signal) catch |leader_error| switch (leader_error) {
                error.ProcessNotFound => return,
                else => self.signal_failed = true,
            },
        };
    }

    fn run(self: *VerifierWatchdog) void {
        self.complete.timedWait(verifier_timeout_ns) catch |wait_error| switch (wait_error) {
            error.Timeout => {
                self.timed_out = true;
                self.signalGroup(std.posix.SIG.TERM);
                self.complete.timedWait(termination_grace_ns) catch |grace_error| switch (grace_error) {
                    error.Timeout => {},
                };
                self.signalGroup(std.posix.SIG.KILL);
            },
        };
    }
};

fn runDirectWithTimeout(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8,
) !std.process.Child.Term {
    if (argv.len != 6 or !std.fs.path.isAbsolute(argv[0])) return error.InvalidVerifierCommand;
    var empty_environment = std.process.EnvMap.init(allocator);
    defer empty_environment.deinit();
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.env_map = &empty_environment;
    child.cwd = cwd;
    child.expand_arg0 = .no_expand;
    child.pgid = 0;
    try child.spawn();
    child.waitForSpawn() catch |err| {
        _ = child.wait() catch {};
        return err;
    };

    var watchdog = VerifierWatchdog{ .pid = child.id };
    const watchdog_thread = std.Thread.spawn(.{}, VerifierWatchdog.run, .{&watchdog}) catch |err| {
        watchdog.signalGroup(std.posix.SIG.KILL);
        _ = child.wait() catch {};
        return err;
    };
    const wait_result = child.wait();
    watchdog.complete.set();
    watchdog_thread.join();
    const term = try wait_result;
    if (watchdog.signal_failed) return error.ProcessGroupTerminationFailed;
    if (watchdog.timed_out) return error.RustVerifierTimedOut;
    return term;
}

fn validateResult(
    allocator: std.mem.Allocator,
    result_path: []const u8,
    executable_sha256: [32]u8,
    envelope: EnvelopeInspection,
) !void {
    const file = try std.fs.openFileAbsolute(result_path, .{});
    defer file.close();
    const before = try file.stat();
    if (before.kind != .file or before.size == 0 or before.size > max_result_bytes)
        return error.InvalidRustVerifierResult;
    const encoded = try file.readToEndAlloc(allocator, max_result_bytes);
    defer allocator.free(encoded);
    const after = try file.stat();
    if (!sameFile(before, after)) return error.RustVerifierResultChanged;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, encoded, .{}) catch
        return error.InvalidRustVerifierResult;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRustVerifierResult;
    const object = parsed.value.object;
    const required_keys = [_][]const u8{
        "schema_version",
        "envelope_abi",
        "adapter_version",
        "cargo_lock_sha256",
        "executable_sha256",
        "stwo_cairo_revision",
        "stwo_revision",
        "protocol_digest",
        "statement_digest",
        "proof_digest",
        "provenance_digest",
        "verification_mode",
        "verified",
        "wall_time_ns",
        "error",
    };
    if (object.count() != required_keys.len) return error.InvalidRustVerifierResult;
    for (required_keys) |key| if (!object.contains(key)) return error.InvalidRustVerifierResult;

    const executable_hex = std.fmt.bytesToHex(executable_sha256, .lower);
    if (!jsonIntegerIs(object.get("schema_version"), 1) or
        !jsonStringIs(object.get("envelope_abi"), prover.canonical_envelope_abi) or
        !jsonStringIs(object.get("adapter_version"), adapter_version) or
        !jsonStringIs(object.get("cargo_lock_sha256"), cargo_lock_sha256) or
        !jsonStringIs(object.get("executable_sha256"), &executable_hex) or
        !jsonStringIs(object.get("stwo_cairo_revision"), prover.pinned_stwo_cairo_revision) or
        !jsonStringIs(object.get("stwo_revision"), prover.pinned_stwo_revision) or
        !jsonStringIs(object.get("verification_mode"), prover.canonical_verification_mode) or
        !jsonBoolIs(object.get("verified"), true) or
        object.get("error").? != .null)
        return error.InvalidRustVerifierResult;

    inline for (.{
        .{ "protocol_digest", 0 },
        .{ "statement_digest", 1 },
        .{ "proof_digest", 2 },
        .{ "provenance_digest", 3 },
    }) |field| {
        const expected = std.fmt.bytesToHex(envelope.section_sha256[field[1]], .lower);
        if (!jsonStringIs(object.get(field[0]), &expected))
            return error.RustVerifierDigestMismatch;
    }
    const wall_time = object.get("wall_time_ns").?;
    if (wall_time != .integer or wall_time.integer <= 0)
        return error.InvalidRustVerifierResult;
}

fn jsonIntegerIs(value: ?std.json.Value, expected: u64) bool {
    const actual = value orelse return false;
    return actual == .integer and actual.integer >= 0 and actual.integer == expected;
}

fn jsonStringIs(value: ?std.json.Value, expected: []const u8) bool {
    const actual = value orelse return false;
    return actual == .string and std.mem.eql(u8, actual.string, expected);
}

fn jsonBoolIs(value: ?std.json.Value, expected: bool) bool {
    const actual = value orelse return false;
    return actual == .bool and actual.bool == expected;
}

fn sameFile(left: std.fs.File.Stat, right: std.fs.File.Stat) bool {
    return left.kind == right.kind and left.inode == right.inode and left.size == right.size and
        left.mtime == right.mtime and left.ctime == right.ctime;
}

fn sha256(bytes: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

const TestEnvelope = struct {
    inspection: EnvelopeInspection,
    section_hex: [compact_interchange.section_count][64]u8,
};

fn writeTestEnvelope(path: []const u8) !TestEnvelope {
    const payloads = [_][]const u8{ "protocol", "statement", "proof", "provenance" };
    var total_bytes: u64 = compact_interchange.envelope_header_bytes;
    for (payloads) |payload| total_bytes += compact_interchange.section_header_bytes + payload.len;
    var file = try std.fs.createFileAbsolute(path, .{ .exclusive = true });
    defer file.close();
    var header = [_]u8{0} ** compact_interchange.envelope_header_bytes;
    @memcpy(header[0..8], &compact_interchange.envelope_magic);
    std.mem.writeInt(u16, header[8..10], compact_interchange.envelope_version, .little);
    std.mem.writeInt(u16, header[10..12], compact_interchange.envelope_header_bytes, .little);
    std.mem.writeInt(u32, header[16..20], compact_interchange.section_count, .little);
    std.mem.writeInt(u64, header[24..32], total_bytes, .little);
    try file.writeAll(&header);
    var section_hex: [compact_interchange.section_count][64]u8 = undefined;
    for (payloads, 0..) |payload, index| {
        const digest = sha256(payload);
        section_hex[index] = std.fmt.bytesToHex(digest, .lower);
        var section_header = [_]u8{0} ** compact_interchange.section_header_bytes;
        std.mem.writeInt(u16, section_header[0..2], @intCast(index + 1), .little);
        std.mem.writeInt(u16, section_header[2..4], compact_interchange.section_flag_mandatory, .little);
        std.mem.writeInt(u64, section_header[8..16], payload.len, .little);
        @memcpy(section_header[16..48], &digest);
        try file.writeAll(&section_header);
        try file.writeAll(payload);
    }
    try file.sync();
    return .{ .inspection = try inspectEnvelope(path), .section_hex = section_hex };
}

fn writeVerifierScript(
    allocator: std.mem.Allocator,
    path: []const u8,
    sections: [compact_interchange.section_count][64]u8,
) ![32]u8 {
    const script = try std.fmt.allocPrint(
        allocator,
        "#!/bin/sh\n" ++
            "[ \"$#\" -eq 5 ] || exit 91\n" ++
            "[ \"$1\" = \"verify\" ] || exit 92\n" ++
            "[ \"$2\" = \"--envelope\" ] || exit 93\n" ++
            "[ \"$4\" = \"--result\" ] || exit 94\n" ++
            "digest=$(/usr/bin/shasum -a 256 \"$0\")\n" ++
            "digest=${{digest%% *}}\n" ++
            "/usr/bin/printf '%s\\n' '{{\"schema_version\":1,\"envelope_abi\":\"STWZCVE/1\",\"adapter_version\":\"0.1.0\",\"cargo_lock_sha256\":\"{s}\",\"executable_sha256\":\"'\"$digest\"'\",\"stwo_cairo_revision\":\"{s}\",\"stwo_revision\":\"{s}\",\"protocol_digest\":\"{s}\",\"statement_digest\":\"{s}\",\"proof_digest\":\"{s}\",\"provenance_digest\":\"{s}\",\"verification_mode\":\"compact_metal_proof_v1\",\"verified\":true,\"wall_time_ns\":1,\"error\":null}}' > \"$5\"\n",
        .{
            cargo_lock_sha256,
            prover.pinned_stwo_cairo_revision,
            prover.pinned_stwo_revision,
            &sections[0],
            &sections[1],
            &sections[2],
            &sections[3],
        },
    );
    defer allocator.free(script);
    var file = try std.fs.createFileAbsolute(path, .{ .exclusive = true, .mode = 0o700 });
    defer file.close();
    try file.writeAll(script);
    try file.sync();
    return sha256(script);
}

fn testCargoLockPath(allocator: std.mem.Allocator) ![]u8 {
    return std.fs.realpathAlloc(allocator, "tools/stwo-cairo-verifier-rs/Cargo.lock");
}

test "Rust Cairo oracle: direct argv and exact evidence return envelope digest" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const envelope_path = try std.fs.path.join(std.testing.allocator, &.{ root, "proof.stwzcve" });
    defer std.testing.allocator.free(envelope_path);
    const script_path = try std.fs.path.join(std.testing.allocator, &.{ root, "verifier" });
    defer std.testing.allocator.free(script_path);
    const test_envelope = try writeTestEnvelope(envelope_path);
    const executable_digest = try writeVerifierScript(
        std.testing.allocator,
        script_path,
        test_envelope.section_hex,
    );
    const lock_path = try testCargoLockPath(std.testing.allocator);
    defer std.testing.allocator.free(lock_path);
    var oracle = try RustOracle.init(
        .{ .path = script_path, .sha256 = executable_digest },
        lock_path,
    );
    const evidence = try oracle.verifyCairo(std.testing.allocator, envelope_path);
    try std.testing.expect(evidence.verified);
    try std.testing.expectEqual(test_envelope.inspection.sha256, evidence.envelope_sha256);
    try std.testing.expectEqualStrings(prover.canonical_verification_mode, evidence.verification_mode);
    const result_path = try std.mem.concat(std.testing.allocator, u8, &.{ envelope_path, result_suffix });
    defer std.testing.allocator.free(result_path);
    try std.testing.expectError(
        error.FileNotFound,
        std.fs.accessAbsolute(result_path, .{}),
    );
}

test "Rust Cairo oracle: nonzero verifier exit is rejection" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const envelope_path = try std.fs.path.join(std.testing.allocator, &.{ root, "proof.stwzcve" });
    defer std.testing.allocator.free(envelope_path);
    const script_path = try std.fs.path.join(std.testing.allocator, &.{ root, "verifier" });
    defer std.testing.allocator.free(script_path);
    _ = try writeTestEnvelope(envelope_path);
    const script = "#!/bin/sh\nexit 3\n";
    var file = try std.fs.createFileAbsolute(script_path, .{ .exclusive = true, .mode = 0o700 });
    try file.writeAll(script);
    file.close();
    const lock_path = try testCargoLockPath(std.testing.allocator);
    defer std.testing.allocator.free(lock_path);
    var oracle = try RustOracle.init(
        .{ .path = script_path, .sha256 = sha256(script) },
        lock_path,
    );
    try std.testing.expectError(
        error.RustVerifierRejected,
        oracle.verifyCairo(std.testing.allocator, envelope_path),
    );
}

test "Rust Cairo oracle: executable and Cargo lock authentication fail closed" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const script_path = try std.fs.path.join(std.testing.allocator, &.{ root, "verifier" });
    defer std.testing.allocator.free(script_path);
    var file = try std.fs.createFileAbsolute(script_path, .{ .exclusive = true, .mode = 0o700 });
    try file.writeAll("#!/bin/sh\nexit 0\n");
    file.close();
    const lock_path = try testCargoLockPath(std.testing.allocator);
    defer std.testing.allocator.free(lock_path);
    try std.testing.expectError(
        error.RustVerifierExecutableDigestMismatch,
        RustOracle.init(.{ .path = script_path, .sha256 = [_]u8{0} ** 32 }, lock_path),
    );

    const fake_lock_path = try std.fs.path.join(std.testing.allocator, &.{ root, "Cargo.lock" });
    defer std.testing.allocator.free(fake_lock_path);
    var fake_lock = try std.fs.createFileAbsolute(fake_lock_path, .{ .exclusive = true });
    try fake_lock.writeAll("not the pinned lockfile\n");
    fake_lock.close();
    try std.testing.expectError(
        error.CargoLockDigestMismatch,
        RustOracle.init(
            .{ .path = script_path, .sha256 = sha256("#!/bin/sh\nexit 0\n") },
            fake_lock_path,
        ),
    );
}
