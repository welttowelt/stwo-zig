//! Metal toolchain, runtime source, and link ownership.

const std = @import("std");

pub const runtime_source = "src/backends/metal/runtime.m";
pub const shader_manifest_source = "src/backends/metal/shader_manifest.zig";
pub const runtime_modes = "source-jit+authenticated-aot";

pub fn supports(os: std.Target.Os.Tag) bool {
    return os == .macos;
}

pub fn requireTarget(target: std.Target) !void {
    if (!supports(target.os.tag)) return error.MetalRequiresMacOS;
}

pub fn linkRuntime(b: *std.Build, artifact: *std.Build.Step.Compile) void {
    requireTarget(artifact.root_module.resolved_target.?.result) catch |err| std.debug.panic(
        "cannot link Metal runtime for {s}: {s}",
        .{ artifact.name, @errorName(err) },
    );
    artifact.addCSourceFile(.{
        .file = b.path(runtime_source),
        .flags = &.{ "-fobjc-arc", "-fblocks" },
    });
    linkFrameworks(artifact);
}

pub fn linkFrameworks(artifact: *std.Build.Step.Compile) void {
    artifact.linkLibC();
    artifact.linkFramework("Foundation");
    artifact.linkFramework("Metal");
    artifact.linkSystemLibrary("objc");
}

test "Metal target policy is explicit" {
    try std.testing.expect(supports(.macos));
    try std.testing.expect(!supports(.linux));
}
