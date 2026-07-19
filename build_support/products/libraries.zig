//! Public library products and the aggregate downstream compatibility module.

const std = @import("std");
const graph = @import("../graph/modules.zig");
const core_product = @import("core.zig");
const prover_product = @import("prover.zig");

pub const Context = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

pub const Result = struct {
    stwo: *std.Build.Module,
    protocol: graph.ProtocolModules,
};

/// Declares the package's public import surface without constructing product
/// tests, tools, gates, or install steps. Root build dispatch uses this path so
/// focused commands configure only their delegated product graph.
pub fn addPublicModules(context: Context) Result {
    const core = graph.addPublic(context.b, "stwo_core", .{
        .product = graph.coreProduct(.library),
        .root_source_file = "src/core/mod.zig",
        .target = context.target,
        .optimize = context.optimize,
    });
    const protocol = graph.createProtocolModules(
        context.b,
        core,
        context.target,
        context.optimize,
    );
    const prover = graph.addPublic(context.b, "stwo_prover", .{
        .product = graph.proverProduct(.library),
        .root_source_file = "src/products/prover/root.zig",
        .target = context.target,
        .optimize = context.optimize,
    });
    protocol.addImports(prover);
    const stwo = context.b.addModule("stwo", .{
        .root_source_file = context.b.path("src/stwo.zig"),
        .target = context.target,
        .optimize = context.optimize,
    });
    protocol.addImports(stwo);
    return .{ .stwo = stwo, .protocol = protocol };
}

pub fn addProducts(context: Context) Result {
    const core = core_product.addProduct(.{
        .b = context.b,
        .target = context.target,
        .optimize = context.optimize,
    });
    const prover = prover_product.addProduct(.{
        .b = context.b,
        .target = context.target,
        .optimize = context.optimize,
        .core = core.module,
    });
    const stwo = context.b.addModule("stwo", .{
        .root_source_file = context.b.path("src/stwo.zig"),
        .target = context.target,
        .optimize = context.optimize,
    });
    prover.protocol.addImports(stwo);

    const downstream = context.b.addSystemCommand(&.{
        "python3",
        "scripts/check_downstream_package.py",
        "--repo",
        context.b.build_root.path.?,
    });
    const downstream_step = context.b.step(
        "test-downstream-modules",
        "Compile and run a clean external consumer of stwo_core, stwo_prover, and stwo",
    );
    downstream_step.dependOn(&downstream.step);
    prover.test_step.dependOn(&downstream.step);

    return .{ .stwo = stwo, .protocol = prover.protocol };
}

pub fn consumer(
    b: *std.Build,
    protocol: graph.ProtocolModules,
    options: std.Build.Module.CreateOptions,
) *std.Build.Module {
    const module = b.createModule(options);
    protocol.addImports(module);
    return module;
}
