const std = @import("std");
const build_identity = @import("build_identity.zig");
const metal_products = @import("metal_products.zig");

pub const Context = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    stwo_module: *std.Build.Module,
    native_proof_runner_module: *std.Build.Module,
    test_step: *std.Build.Step,
};

pub fn addProduct(context: Context) void {
    const b = context.b;
    const identity = resolveBuildIdentity(b);
    const identity_options = b.addOptions();
    identity_options.addOption(
        []const u8,
        "implementation_commit",
        &identity.implementation_commit,
    );
    identity_options.addOption(
        bool,
        "implementation_dirty",
        identity.implementation_dirty,
    );
    const module = b.createModule(.{
        .root_source_file = b.path("src/tools/prove/main.zig"),
        .target = context.target,
        .optimize = context.optimize,
    });
    module.addImport("stwo", context.stwo_module);
    module.addImport("native_proof_runner", context.native_proof_runner_module);
    module.addOptions("build_identity", identity_options);
    const executable = b.addExecutable(.{ .name = "stwo-zig", .root_module = module });
    executable.linkLibC();
    if (context.target.result.os.tag == .macos) metal_products.linkRuntime(b, executable);
    const install = b.addInstallArtifact(executable, .{});
    b.getInstallStep().dependOn(&install.step);
    const build_step = b.step("stwo-zig", "Build the production proof CLI");
    build_step.dependOn(&install.step);

    const parser_module = b.createModule(.{
        .root_source_file = b.path("src/tools/prove/cli.zig"),
        .target = context.target,
        .optimize = context.optimize,
    });
    const parser_tests = b.addTest(.{ .root_module = parser_module });
    context.test_step.dependOn(&b.addRunArtifact(parser_tests).step);

    const registry_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tools/prove/registry.zig"),
        .target = context.target,
        .optimize = context.optimize,
    }) });
    context.test_step.dependOn(&b.addRunArtifact(registry_tests).step);

    const riscv_artifact_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/interop/riscv_artifact.zig"),
        .target = context.target,
        .optimize = context.optimize,
    }) });
    context.test_step.dependOn(&b.addRunArtifact(riscv_artifact_tests).step);

    const dispatch_module = b.createModule(.{
        .root_source_file = b.path("src/tools/prove/native_dispatch.zig"),
        .target = context.target,
        .optimize = context.optimize,
    });
    dispatch_module.addImport("stwo", context.stwo_module);
    dispatch_module.addImport("native_proof_runner", context.native_proof_runner_module);
    const dispatch_tests = b.addTest(.{ .root_module = dispatch_module });
    if (context.target.result.os.tag == .macos) metal_products.linkRuntime(b, dispatch_tests);
    context.test_step.dependOn(&b.addRunArtifact(dispatch_tests).step);

    const app_module = b.createModule(.{
        .root_source_file = b.path("src/tools/prove/app.zig"),
        .target = context.target,
        .optimize = context.optimize,
    });
    app_module.addImport("stwo", context.stwo_module);
    app_module.addImport("native_proof_runner", context.native_proof_runner_module);
    app_module.addOptions("build_identity", identity_options);
    const app_tests = b.addTest(.{ .root_module = app_module });
    app_tests.linkLibC();
    if (context.target.result.os.tag == .macos) metal_products.linkRuntime(b, app_tests);
    context.test_step.dependOn(&b.addRunArtifact(app_tests).step);
}

fn resolveBuildIdentity(b: *std.Build) build_identity.Identity {
    const explicit_commit = b.option(
        []const u8,
        "implementation-commit",
        "Exact lowercase 40-hex source commit embedded in the production CLI",
    );
    const explicit_dirty = b.option(
        bool,
        "implementation-dirty",
        "Whether the source embedded in the production CLI has local modifications",
    );
    return build_identity.resolve(
        b.allocator,
        b.pathFromRoot("."),
        explicit_commit,
        explicit_dirty,
    ) catch |err| std.debug.panic("cannot resolve production CLI build identity: {s}", .{@errorName(err)});
}
