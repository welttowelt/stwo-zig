//! Build ownership for the backend-generic Stwo prover library.

const std = @import("std");
const graph = @import("../graph/modules.zig");

pub const Context = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core: *std.Build.Module,
};

pub const Result = struct {
    module: *std.Build.Module,
    protocol: graph.ProtocolModules,
    test_step: *std.Build.Step,
};

pub fn addProduct(context: Context) Result {
    const protocol = graph.createProtocolModules(
        context.b,
        context.core,
        context.target,
        context.optimize,
    );
    const module = graph.addPublic(context.b, "stwo_prover", .{
        .product = graph.proverProduct(.library),
        .root_source_file = "src/products/prover/root.zig",
        .target = context.target,
        .optimize = context.optimize,
    });
    protocol.addImports(module);

    const surface = surfaceModule(context, module);
    const object = context.b.addObject(.{ .name = "stwo-prover", .root_module = surface });
    const purity = purityCheck(context);
    const build_step = context.b.step("stwo-prover", "Build the focused backend-generic Stwo prover library");
    build_step.dependOn(&object.step);
    build_step.dependOn(&purity.step);

    const tests = context.b.addTest(.{ .root_module = surfaceModule(context, module) });
    const test_step = context.b.step(
        "test-stwo-prover",
        "Test the focused generic prover, backend contracts, and purity boundary",
    );
    test_step.dependOn(&context.b.addRunArtifact(tests).step);
    test_step.dependOn(&purity.step);

    return .{ .module = module, .protocol = protocol, .test_step = test_step };
}

fn surfaceModule(context: Context, prover: *std.Build.Module) *std.Build.Module {
    const root = graph.create(context.b, .{
        .product = graph.proverProduct(.@"test"),
        .root_source_file = "src/products/prover/surface.zig",
        .target = context.target,
        .optimize = context.optimize,
    });
    root.addImport("stwo_prover", prover);
    return root;
}

fn purityCheck(context: Context) *std.Build.Step.Run {
    return context.b.addSystemCommand(&.{
        "python3",
        "scripts/check_library_products.py",
        "--product",
        "prover",
    });
}
