const std = @import("std");
const shader_manifest = @import("shader_manifest");

pub const format = "stwo-zig-metal-core-aot-v1";
pub const source_filename = "stwo_zig_core.metal";
pub const manifest_filename = "stwo_zig_core.manifest.json";
pub const air_filename = "stwo_zig_core.air";
pub const metallib_filename = "stwo_zig_core.metallib";

const SourceIdentity = struct {
    path: []const u8,
    sha256: []const u8,
    bytes: usize,
};

pub const Measurement = struct {
    sha256: [32]u8,
    bytes: u64,
};

pub const BuildMeasurements = struct {
    air: Measurement,
    metallib: Measurement,
};

const ArtifactIdentity = struct {
    path: []const u8,
    sha256: ?[]const u8,
    bytes: ?u64,
};

const ArtifactIdentities = struct {
    air: ArtifactIdentity,
    metallib: ArtifactIdentity,
};

const Manifest = struct {
    format: []const u8,
    core_shader_abi: u32,
    source: SourceIdentity,
    compile_profile: shader_manifest.CompileProfile,
    artifacts: ArtifactIdentities,
    exports: []const shader_manifest.Export,
};

pub fn source() []const u8 {
    return shader_manifest.amalgamated_source[0 .. shader_manifest.amalgamated_source.len - 1];
}

pub fn renderManifest(allocator: std.mem.Allocator, measurements: ?BuildMeasurements) ![]u8 {
    const digest = sourceDigest();
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    const air_hex = if (measurements) |value|
        std.fmt.bytesToHex(value.air.sha256, .lower)
    else
        null;
    const metallib_hex = if (measurements) |value|
        std.fmt.bytesToHex(value.metallib.sha256, .lower)
    else
        null;
    const body = try std.json.Stringify.valueAlloc(allocator, Manifest{
        .format = format,
        .core_shader_abi = shader_manifest.core_shader_abi,
        .source = .{
            .path = source_filename,
            .sha256 = digest_hex[0..],
            .bytes = source().len,
        },
        .compile_profile = shader_manifest.compile_profile,
        .artifacts = .{
            .air = .{
                .path = air_filename,
                .sha256 = if (air_hex) |value| value[0..] else null,
                .bytes = if (measurements) |value| value.air.bytes else null,
            },
            .metallib = .{
                .path = metallib_filename,
                .sha256 = if (metallib_hex) |value| value[0..] else null,
                .bytes = if (measurements) |value| value.metallib.bytes else null,
            },
        },
        .exports = shader_manifest.exports[0..],
    }, .{ .whitespace = .indent_2 });
    defer allocator.free(body);
    return std.fmt.allocPrint(allocator, "{s}\n", .{body});
}

pub fn emit(allocator: std.mem.Allocator, output_dir: []const u8) !void {
    try verifyAuthority();
    const manifest_bytes = try renderManifest(allocator, null);
    defer allocator.free(manifest_bytes);

    var directory = try std.fs.cwd().makeOpenPath(output_dir, .{});
    defer directory.close();
    try writeAtomic(directory, source_filename, source());
    try writeAtomic(directory, manifest_filename, manifest_bytes);
}

pub fn finalizeBuild(allocator: std.mem.Allocator, output_dir: []const u8) !BuildMeasurements {
    var directory = try std.fs.cwd().openDir(output_dir, .{});
    defer directory.close();
    const measurements: BuildMeasurements = .{
        .air = try measure(directory, air_filename),
        .metallib = try measure(directory, metallib_filename),
    };
    const manifest_bytes = try renderManifest(allocator, measurements);
    defer allocator.free(manifest_bytes);
    try writeAtomic(directory, manifest_filename, manifest_bytes);
    return measurements;
}

fn sourceDigest() [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source(), &digest, .{});
    return digest;
}

fn verifyAuthority() !void {
    if (shader_manifest.exports.len != 90) return error.InvalidCoreExportCount;
    if (!std.mem.eql(u8, &sourceDigest(), &shader_manifest.amalgamated_source_sha256))
        return error.CoreSourceDigestMismatch;
}

fn writeAtomic(directory: std.fs.Dir, filename: []const u8, bytes: []const u8) !void {
    var write_buffer: [64 * 1024]u8 = undefined;
    var file = try directory.atomicFile(filename, .{ .write_buffer = &write_buffer });
    defer file.deinit();
    try file.file_writer.interface.writeAll(bytes);
    try file.finish();
}

fn measure(directory: std.fs.Dir, filename: []const u8) !Measurement {
    const file = try directory.openFile(filename, .{});
    defer file.close();
    const before = try file.stat();
    if (before.kind != .file or before.size == 0) return error.InvalidCompilerArtifact;
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    var bytes: u64 = 0;
    var buffer: [256 * 1024]u8 = undefined;
    while (true) {
        const count = try file.read(&buffer);
        if (count == 0) break;
        digest.update(buffer[0..count]);
        bytes = std.math.add(u64, bytes, count) catch return error.CompilerArtifactTooLarge;
    }
    const after = try file.stat();
    if (after.kind != .file or after.size != before.size or bytes != before.size)
        return error.CompilerArtifactChangedDuringMeasurement;
    return .{ .sha256 = digest.finalResult(), .bytes = bytes };
}

test "AOT manifest is deterministic and binds the shader authority" {
    const first = try renderManifest(std.testing.allocator, null);
    defer std.testing.allocator.free(first);
    const second = try renderManifest(std.testing.allocator, null);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings(first, second);
    try std.testing.expectEqual(@as(u8, '\n'), first[first.len - 1]);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, first, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings(format, root.get("format").?.string);
    try std.testing.expectEqual(@as(i64, shader_manifest.core_shader_abi), root.get("core_shader_abi").?.integer);
    try std.testing.expectEqual(@as(usize, 90), root.get("exports").?.array.items.len);

    const source_json = root.get("source").?.object;
    const digest_hex = std.fmt.bytesToHex(shader_manifest.amalgamated_source_sha256, .lower);
    try std.testing.expectEqualStrings(digest_hex[0..], source_json.get("sha256").?.string);
    try std.testing.expectEqual(@as(i64, @intCast(source().len)), source_json.get("bytes").?.integer);

    const profile = root.get("compile_profile").?.object;
    try std.testing.expectEqualStrings(shader_manifest.compile_profile.sdk, profile.get("sdk").?.string);
    try std.testing.expectEqualStrings(
        shader_manifest.compile_profile.language_standard,
        profile.get("language_standard").?.string,
    );
    try std.testing.expectEqualStrings(shader_manifest.compile_profile.math_mode, profile.get("math_mode").?.string);
    try std.testing.expect(profile.get("warnings_as_errors").?.bool);

    const artifacts = root.get("artifacts").?.object;
    try std.testing.expect(artifacts.get("air").?.object.get("sha256").? == .null);
    try std.testing.expect(artifacts.get("metallib").?.object.get("bytes").? == .null);
}

test "built manifest authenticates synthetic compiler outputs" {
    const measurements: BuildMeasurements = .{
        .air = .{ .sha256 = .{0x31} ** 32, .bytes = 1234 },
        .metallib = .{ .sha256 = .{0xa7} ** 32, .bytes = 5678 },
    };
    const rendered = try renderManifest(std.testing.allocator, measurements);
    defer std.testing.allocator.free(rendered);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, rendered, .{});
    defer parsed.deinit();
    const artifacts = parsed.value.object.get("artifacts").?.object;
    const air = artifacts.get("air").?.object;
    const metallib = artifacts.get("metallib").?.object;
    try std.testing.expectEqualStrings("31" ** 32, air.get("sha256").?.string);
    try std.testing.expectEqual(@as(i64, 1234), air.get("bytes").?.integer);
    try std.testing.expectEqualStrings("a7" ** 32, metallib.get("sha256").?.string);
    try std.testing.expectEqual(@as(i64, 5678), metallib.get("bytes").?.integer);
}

test "emission writes the exact sentinel-free amalgamated source" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const output_dir = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(output_dir);

    try emit(std.testing.allocator, output_dir);
    const emitted = try temporary.dir.readFileAlloc(std.testing.allocator, source_filename, source().len + 1);
    defer std.testing.allocator.free(emitted);
    try std.testing.expectEqualStrings(source(), emitted);
    try std.testing.expect(emitted.len == 0 or emitted[emitted.len - 1] != 0);
}
