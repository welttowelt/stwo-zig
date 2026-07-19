//! Explicit installation ownership for focused executables.

const std = @import("std");

pub const InstalledExecutable = struct {
    executable: *std.Build.Step.Compile,
    install: *std.Build.Step.InstallArtifact,
    build_step: *std.Build.Step,
};

pub fn executable(
    b: *std.Build,
    name: []const u8,
    root_module: *std.Build.Module,
    step_name: []const u8,
    description: []const u8,
) InstalledExecutable {
    const artifact = b.addExecutable(.{ .name = name, .root_module = root_module });
    const install = b.addInstallArtifact(artifact, .{});
    const build_step = b.step(step_name, description);
    build_step.dependOn(&install.step);
    return .{
        .executable = artifact,
        .install = install,
        .build_step = build_step,
    };
}
