//! Explicit CUDA library and runtime linkage contract.

const std = @import("std");

pub const Toolchain = struct {
    library_dir: ?[]const u8 = null,
    runtime_dir: ?[]const u8 = null,

    pub fn validate(self: Toolchain) !void {
        if (empty(self.library_dir)) return error.MissingCudaLibraryDirectory;
        if (empty(self.runtime_dir)) return error.MissingCudaRuntimeDirectory;
    }
};

pub fn linkRuntime(artifact: *std.Build.Step.Compile, toolchain: Toolchain) void {
    toolchain.validate() catch |err| std.debug.panic(
        "invalid explicit CUDA toolchain: {s}",
        .{@errorName(err)},
    );
    artifact.addLibraryPath(.{ .cwd_relative = toolchain.library_dir.? });
    artifact.addLibraryPath(.{ .cwd_relative = toolchain.runtime_dir.? });
    artifact.linkSystemLibrary("stwo_cuda");
    artifact.linkSystemLibrary("cudart");
    artifact.linkSystemLibrary("stdc++");
}

fn empty(value: ?[]const u8) bool {
    return value == null or value.?.len == 0;
}

test "CUDA toolchain has no implicit local paths" {
    try std.testing.expectError(error.MissingCudaLibraryDirectory, (Toolchain{}).validate());
    try std.testing.expectError(
        error.MissingCudaRuntimeDirectory,
        (Toolchain{ .library_dir = "/explicit/cuda-product/lib" }).validate(),
    );
    try (Toolchain{
        .library_dir = "/explicit/cuda-product/lib",
        .runtime_dir = "/explicit/cuda-runtime/lib",
    }).validate();
}
