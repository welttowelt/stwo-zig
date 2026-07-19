//! Public build-step registry and focused delegation boundary.

const std = @import("std");
const catalog = @import("products/catalog.zig");
const libraries = @import("products/libraries.zig");
const matrix = @import("products/matrix.zig");
const delegation = @import("graph/delegation.zig");

pub fn add(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Dependency builds need the package's public module table. Root command
    // dispatch builds no module until its selected delegated scope runs.
    if (b.pkg_hash.len != 0)
        _ = libraries.addPublicModules(.{ .b = b, .target = target, .optimize = optimize });

    const options = delegation.Options.read(b);
    matrix.addRootProxies(b, target, optimize, options);
    for (catalog.steps) |spec| delegation.addProxy(
        b,
        target,
        optimize,
        options,
        spec.name,
        spec.description,
        @tagName(spec.scope),
    );
    delegation.addInstallProxy(b, target, optimize, options);
}
