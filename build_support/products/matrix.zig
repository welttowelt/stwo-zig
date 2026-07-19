//! Authoritative accelerated and deferred composition matrix.

const std = @import("std");
const product_policy = @import("../graph/product.zig");
const core = @import("core.zig");
const prover = @import("prover.zig");
const native_cpu = @import("native_cpu.zig");
const riscv_cpu = @import("riscv_cpu.zig");
const cairo_cpu = @import("cairo_cpu.zig");
const cairo_metal = @import("cairo_metal.zig");
const riscv_metal = @import("riscv_metal.zig");
const native_cuda = @import("native_cuda.zig");
const native_metal = @import("native_metal.zig");
const cairo_cuda = @import("cairo_cuda.zig");
const riscv_cuda = @import("riscv_cuda.zig");
const aggregate = @import("aggregate.zig");

pub const descriptors = [_]product_policy.Descriptor{
    aggregate.descriptor,
    core.descriptor,
    prover.descriptor,
    native_cpu.descriptor(.cli),
    riscv_cpu.descriptor,
    native_metal.descriptor(.cli),
    cairo_cpu.descriptor,
    cairo_metal.descriptor,
    riscv_metal.descriptor,
    native_cuda.descriptor,
    cairo_cuda.descriptor,
    riscv_cuda.descriptor,
};

pub fn find(name: []const u8) ?product_policy.Descriptor {
    for (descriptors) |descriptor| {
        if (std.mem.eql(u8, descriptor.product.name, name)) return descriptor;
    }
    return null;
}

pub fn addDeferredProducts(b: *std.Build, target: std.Build.ResolvedTarget) void {
    inline for (descriptors) |descriptor| {
        if (!descriptor.isConstructible())
            product_policy.registerUnavailable(b, descriptor, target.result.os.tag);
    }
}

pub fn addIdentity(b: *std.Build) void {
    var products: [descriptors.len]MatrixProduct = undefined;
    inline for (descriptors, 0..) |descriptor, index| {
        const closure = descriptor.source_closure;
        products[index] = .{
            .product_id = descriptor.product.name,
            .frontend = @tagName(descriptor.product.frontend),
            .backend = @tagName(descriptor.product.backend),
            .role = @tagName(descriptor.product.role),
            .protocol_manifest = descriptor.product.protocol_features,
            .state = @tagName(descriptor.state),
            .target_support = @tagName(descriptor.target_support),
            .build_step = descriptor.build_step,
            .test_step = descriptor.test_step,
            .executable = descriptor.executable,
            .module_roots = descriptor.dependencies.module_roots,
            .external_dependencies = descriptor.dependencies.external_dependencies,
            .required_dynamic_dependencies = if (closure) |value|
                value.required_dynamic_dependencies
            else
                &.{},
            .forbidden_dynamic_dependencies = if (closure) |value|
                value.forbidden_dynamic_dependencies
            else
                &.{},
        };
    }
    const payload = std.json.Stringify.valueAlloc(b.allocator, .{
        .schema = "stwo-product-matrix-v1",
        .products = &products,
    }, .{}) catch @panic("cannot encode product matrix");
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const encoded = std.json.Stringify.valueAlloc(b.allocator, .{
        .schema = "stwo-product-matrix-v1",
        .matrix_sha256 = &hex,
        .products = &products,
    }, .{}) catch @panic("cannot encode product matrix identity");
    const files = b.addWriteFiles();
    const generated = files.add("product-matrix.json", encoded);
    const install = b.addInstallFile(
        generated,
        "identity/product-matrix.json",
    );
    b.step(
        "product-matrix-identity",
        "Emit the hashed authoritative product capability matrix",
    ).dependOn(&install.step);
}

const MatrixProduct = struct {
    product_id: []const u8,
    frontend: []const u8,
    backend: []const u8,
    role: []const u8,
    protocol_manifest: []const u8,
    state: []const u8,
    target_support: []const u8,
    build_step: []const u8,
    test_step: ?[]const u8,
    executable: ?[]const u8,
    module_roots: []const []const u8,
    external_dependencies: []const []const u8,
    required_dynamic_dependencies: []const []const u8,
    forbidden_dynamic_dependencies: []const []const u8,
};

test "every central product descriptor is valid" {
    inline for (descriptors) |descriptor| try descriptor.validate();
}

test "aggregate matrix identity is the default CPU capability" {
    try std.testing.expectEqualStrings("stwo-zig", aggregate.descriptor.product.name);
    try std.testing.expectEqual(.aggregate, aggregate.descriptor.product.frontend);
    try std.testing.expectEqual(.cpu, aggregate.descriptor.product.backend);
    try std.testing.expectEqualDeep(
        aggregate.descriptor.product,
        aggregate.product(false),
    );
    try std.testing.expect(!std.meta.eql(aggregate.product(false), aggregate.product(true)));
}
