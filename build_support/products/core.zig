//! Build ownership for the independently consumable Stwo core library.

const std = @import("std");
const graph = @import("../graph/modules.zig");

pub const Context = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

pub const Result = struct {
    module: *std.Build.Module,
};

pub fn addProduct(context: Context) Result {
    const module = graph.addPublic(context.b, "stwo_core", .{
        .product = graph.coreProduct(.library),
        .root_source_file = "src/core/mod.zig",
        .target = context.target,
        .optimize = context.optimize,
    });

    const surface = surfaceModule(context, module);
    const object = context.b.addObject(.{ .name = "stwo-core", .root_module = surface });
    const purity = purityCheck(context, "core");
    const build_step = context.b.step("stwo-core", "Build the focused Stwo core library");
    build_step.dependOn(&object.step);
    build_step.dependOn(&purity.step);

    const tests = context.b.addTest(.{ .root_module = surfaceModule(context, module) });
    const test_step = context.b.step("test-stwo-core", "Test the focused Stwo core library and purity boundary");
    test_step.dependOn(&context.b.addRunArtifact(tests).step);
    test_step.dependOn(&purity.step);

    return .{ .module = module };
}

fn surfaceModule(context: Context, core: *std.Build.Module) *std.Build.Module {
    const root = graph.create(context.b, .{
        .product = graph.coreProduct(.@"test"),
        .root_source_file = "src/products/core/surface.zig",
        .target = context.target,
        .optimize = context.optimize,
    });
    root.addImport("stwo_core", core);
    return root;
}

fn purityCheck(context: Context, product: []const u8) *std.Build.Step.Run {
    const check = context.b.addSystemCommand(&.{
        "python3",
        "scripts/check_library_products.py",
        "--product",
        product,
    });
    return check;
}
