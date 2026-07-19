//! Post-build identity receipt orchestration for libraries and executables.

const std = @import("std");
const build_identity = @import("../../build_identity.zig");
const identity = @import("../identity.zig");
const graph = @import("../modules.zig");

pub const Inputs = struct {
    b: *std.Build,
    source: build_identity.Identity,
    product: graph.Product,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    artifact: std.Build.LazyPath,
    artifact_path: []const u8,
    executable: bool,
    step_name: []const u8,
    output_name: []const u8,
    runtime: identity.RuntimeHooks = .{},
};

pub fn add(inputs: Inputs) *std.Build.Step {
    const emitter_module = inputs.b.createModule(.{
        .root_source_file = inputs.b.path("build_support/graph/identity/emitter.zig"),
        .target = inputs.b.graph.host,
        .optimize = .ReleaseSafe,
    });
    emitter_module.addOptions(
        "product_identity",
        identity.productOptionsWithRuntime(
            inputs.b,
            inputs.source,
            inputs.product,
            inputs.target,
            inputs.optimize,
            inputs.runtime,
        ),
    );
    const emitter = inputs.b.addExecutable(.{
        .name = inputs.b.fmt("{s}-identity-emitter", .{inputs.product.name}),
        .root_module = emitter_module,
    });
    const run = inputs.b.addRunArtifact(emitter);
    run.addFileArg(inputs.artifact);
    run.addArg(if (inputs.executable) "executable" else "library");
    run.addArg(inputs.artifact_path);
    const output = run.captureStdOut();
    const install = inputs.b.addInstallFile(
        output,
        inputs.b.fmt("identity/{s}", .{inputs.output_name}),
    );
    const step = inputs.b.step(
        inputs.step_name,
        inputs.b.fmt("Emit canonical machine identity for {s}", .{inputs.product.name}),
    );
    step.dependOn(&install.step);
    return step;
}
