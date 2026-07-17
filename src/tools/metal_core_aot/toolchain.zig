const builtin = @import("builtin");
const std = @import("std");
const artifact = @import("artifact.zig");
const shader_manifest = @import("shader_manifest");

pub const full_xcode_message =
    "full Xcode is required: install Xcode, select Xcode.app/Contents/Developer " ++
    "with xcode-select, and ensure xcrun resolves both metal and metallib";

const xcode_select = "/usr/bin/xcode-select";
const xcrun = "/usr/bin/xcrun";
const language_flag = "-std=" ++ shader_manifest.compile_profile.language_standard;
const math_flag = if (std.mem.eql(u8, shader_manifest.compile_profile.math_mode, "safe"))
    "-fno-fast-math"
else
    @compileError("unsupported core Metal math mode");
const warning_flag = if (shader_manifest.compile_profile.warnings_as_errors)
    "-Werror"
else
    @compileError("core AOT builds must fail on Metal warnings");

pub const metal_argv = [_][]const u8{
    xcrun,
    "--sdk",
    shader_manifest.compile_profile.sdk,
    "metal",
    language_flag,
    math_flag,
    warning_flag,
    "-c",
    artifact.source_filename,
    "-o",
    artifact.air_filename,
};

pub const metallib_argv = [_][]const u8{
    xcrun,
    "--sdk",
    shader_manifest.compile_profile.sdk,
    "metallib",
    artifact.air_filename,
    "-o",
    artifact.metallib_filename,
};

pub fn build(allocator: std.mem.Allocator, output_dir: []const u8) !void {
    try requireFullXcode(allocator);
    try artifact.emit(allocator, output_dir);

    var directory = try std.fs.cwd().openDir(output_dir, .{});
    defer directory.close();
    try deleteOutput(directory, artifact.air_filename);
    try deleteOutput(directory, artifact.metallib_filename);

    try runCompiler(allocator, metal_argv[0..], output_dir);
    try requireNonempty(directory, artifact.air_filename);

    try runCompiler(allocator, metallib_argv[0..], output_dir);
    try requireNonempty(directory, artifact.metallib_filename);
    _ = try artifact.finalizeBuild(allocator, output_dir);
}

pub fn isFullXcodeDeveloperDir(path: []const u8) bool {
    const suffix = ".app/Contents/Developer";
    return std.mem.endsWith(u8, path, suffix) and
        !std.mem.endsWith(u8, path, "/CommandLineTools");
}

fn requireFullXcode(allocator: std.mem.Allocator) !void {
    if (builtin.os.tag != .macos) return error.FullXcodeRequired;
    const developer_dir = commandOutput(allocator, &.{ xcode_select, "-p" }) catch
        return error.FullXcodeRequired;
    defer allocator.free(developer_dir);
    if (!isFullXcodeDeveloperDir(developer_dir)) return error.FullXcodeRequired;

    inline for (.{ "metal", "metallib" }) |tool| {
        const tool_path = commandOutput(allocator, &.{
            xcrun,
            "--sdk",
            shader_manifest.compile_profile.sdk,
            "--find",
            tool,
        }) catch return error.FullXcodeRequired;
        defer allocator.free(tool_path);
        if (!isWithinDeveloperDir(developer_dir, tool_path)) return error.FullXcodeRequired;
    }
}

fn isWithinDeveloperDir(developer_dir: []const u8, tool_path: []const u8) bool {
    if (!std.mem.startsWith(u8, tool_path, developer_dir)) return false;
    return tool_path.len > developer_dir.len and tool_path[developer_dir.len] == '/';
}

fn commandOutput(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 16 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try requireSuccess(result.term);
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyToolOutput;
    return allocator.dupe(u8, trimmed);
}

fn runCompiler(allocator: std.mem.Allocator, argv: []const []const u8, cwd: []const u8) !void {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = cwd,
        .max_output_bytes = 1024 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    requireSuccess(result.term) catch {
        std.debug.print("Metal compiler failed: {s}\n", .{std.mem.trim(u8, result.stderr, " \t\r\n")});
        return error.MetalCompilerFailed;
    };
}

fn requireSuccess(term: std.process.Child.Term) !void {
    switch (term) {
        .Exited => |code| if (code == 0) return,
        else => {},
    }
    return error.CommandFailed;
}

fn requireNonempty(directory: std.fs.Dir, filename: []const u8) !void {
    const stat = try directory.statFile(filename);
    if (stat.kind != .file or stat.size == 0) return error.EmptyCompilerArtifact;
}

fn deleteOutput(directory: std.fs.Dir, filename: []const u8) !void {
    directory.deleteFile(filename) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

test "full Xcode recognition rejects Command Line Tools and path-prefix tricks" {
    try std.testing.expect(isFullXcodeDeveloperDir("/Applications/Xcode.app/Contents/Developer"));
    try std.testing.expect(isFullXcodeDeveloperDir("/Applications/Xcode-beta.app/Contents/Developer"));
    try std.testing.expect(!isFullXcodeDeveloperDir("/Library/Developer/CommandLineTools"));
    try std.testing.expect(!isFullXcodeDeveloperDir("/Applications/Xcode.app"));

    const developer_dir = "/Applications/Xcode.app/Contents/Developer";
    try std.testing.expect(isWithinDeveloperDir(
        developer_dir,
        developer_dir ++ "/Toolchains/XcodeDefault.xctoolchain/usr/bin/metal",
    ));
    try std.testing.expect(!isWithinDeveloperDir(developer_dir, developer_dir ++ "-fake/usr/bin/metal"));
}

test "compiler contract pins safe math and exact artifact names" {
    try std.testing.expectEqualStrings("safe", shader_manifest.compile_profile.math_mode);
    try std.testing.expectEqualSlices([]const u8, &.{
        "/usr/bin/xcrun",
        "--sdk",
        "macosx",
        "metal",
        "-std=metal3.1",
        "-fno-fast-math",
        "-Werror",
        "-c",
        "stwo_zig_core.metal",
        "-o",
        "stwo_zig_core.air",
    }, metal_argv[0..]);
    try std.testing.expectEqualSlices([]const u8, &.{
        "/usr/bin/xcrun",
        "--sdk",
        "macosx",
        "metallib",
        "stwo_zig_core.air",
        "-o",
        "stwo_zig_core.metallib",
    }, metallib_argv[0..]);
}
