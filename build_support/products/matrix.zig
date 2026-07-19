//! Authoritative accelerated and deferred composition matrix.

const std = @import("std");
const build_identity = @import("../build_identity.zig");
const delegation = @import("../graph/delegation.zig");
const graph = @import("../graph/modules.zig");
const product_policy = @import("../graph/product.zig");
const aggregate_cli = @import("aggregate_cli.zig");
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

pub const Constructor = enum {
    aggregate,
    core,
    prover,
    native_cpu,
    riscv_cpu,
    native_metal,
    unavailable,
};

pub const Spec = struct {
    descriptor: product_policy.Descriptor,
    scope: []const u8,
    constructor: Constructor,
    identity_step: ?[]const u8 = null,
    configure_tools: []const []const u8 = &.{},
    runtime_probes: []const []const u8 = &.{},
    configure_allowed_files: []const []const u8 = &.{},
    configure_allowed_prefixes: []const []const u8 = &.{},
};

/// The sole released/deferred product catalog. Build construction, root
/// proxies, registry assertions, help, tests, and evidence derive from this.
pub const products = [_]Spec{
    .{ .descriptor = aggregate.descriptor, .scope = "aggregate", .constructor = .aggregate, .identity_step = "identity-stwo-zig", .configure_tools = &.{"python3"}, .configure_allowed_files = &.{"build_support/graph/identity/emitter.zig"} },
    .{ .descriptor = core.descriptor, .scope = "core", .constructor = .core, .identity_step = "identity-stwo-core", .configure_tools = &.{"python3"}, .configure_allowed_files = &.{"build_support/graph/identity/emitter.zig"} },
    .{ .descriptor = prover.descriptor, .scope = "prover", .constructor = .prover, .identity_step = "identity-stwo-prover", .configure_tools = &.{"python3"}, .configure_allowed_files = &.{ "build_support/graph/identity/emitter.zig", "src/products/core/surface.zig" } },
    .{ .descriptor = native_cpu.descriptor(.cli), .scope = "native_cpu", .constructor = .native_cpu, .configure_tools = &.{"python3"} },
    .{ .descriptor = riscv_cpu.descriptor, .scope = "riscv_cpu", .constructor = .riscv_cpu, .configure_tools = &.{"python3"} },
    .{
        .descriptor = native_metal.descriptor(.cli),
        .scope = "native_metal",
        .constructor = .native_metal,
        .configure_tools = &.{ "python3", "xcrun" },
        .runtime_probes = &.{ "Metal.framework", "Foundation.framework", "libobjc" },
        .configure_allowed_files = &.{"build_support/product_policy_test.zig"},
    },
    .{ .descriptor = cairo_cpu.descriptor, .scope = "deferred", .constructor = .unavailable },
    .{ .descriptor = cairo_metal.descriptor, .scope = "deferred", .constructor = .unavailable },
    .{ .descriptor = riscv_metal.descriptor, .scope = "deferred", .constructor = .unavailable },
    .{ .descriptor = native_cuda.descriptor, .scope = "deferred", .constructor = .unavailable },
    .{ .descriptor = cairo_cuda.descriptor, .scope = "deferred", .constructor = .unavailable },
    .{ .descriptor = riscv_cuda.descriptor, .scope = "deferred", .constructor = .unavailable },
};

pub const descriptors = blk: {
    var result: [products.len]product_policy.Descriptor = undefined;
    for (products, 0..) |spec, index| result[index] = spec.descriptor;
    break :blk result;
};

pub const ConstructionContext = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    identity: build_identity.Identity,
};

pub fn constructAggregate(b: *std.Build) void {
    const spec = findByScope("aggregate") orelse @panic("aggregate product missing from catalog");
    if (spec.constructor != .aggregate) @panic("aggregate catalog constructor mismatch");
    aggregate_cli.addProduct(b);
}

pub fn construct(context: ConstructionContext, scope: []const u8) bool {
    for (products) |spec| {
        if (!std.mem.eql(u8, spec.scope, scope) or spec.constructor == .unavailable) continue;
        switch (spec.constructor) {
            .aggregate => unreachable,
            .core => _ = core.addProduct(.{
                .b = context.b,
                .target = context.target,
                .optimize = context.optimize,
                .identity = context.identity,
            }),
            .prover => {
                const core_result = core.addProduct(.{
                    .b = context.b,
                    .target = context.target,
                    .optimize = context.optimize,
                    .identity = context.identity,
                });
                _ = prover.addProduct(.{
                    .b = context.b,
                    .target = context.target,
                    .optimize = context.optimize,
                    .core = core_result.module,
                    .identity = context.identity,
                });
            },
            .native_cpu => native_cpu.addProduct(.{
                .b = context.b,
                .target = context.target,
                .optimize = context.optimize,
                .identity = context.identity,
                .protocol = graph.createPrivateProtocolModules(context.b, context.target, context.optimize),
            }),
            .native_metal => native_metal.addProduct(.{
                .b = context.b,
                .target = context.target,
                .optimize = context.optimize,
                .identity = context.identity,
                .protocol = graph.createPrivateProtocolModules(context.b, context.target, context.optimize),
            }),
            .riscv_cpu => riscv_cpu.addProduct(.{
                .b = context.b,
                .target = context.target,
                .optimize = context.optimize,
                .identity = context.identity,
                .protocol = graph.createPrivateProtocolModules(context.b, context.target, context.optimize),
            }),
            .unavailable => unreachable,
        }
        return true;
    }
    return false;
}

pub fn addRootProxies(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: delegation.Options,
) void {
    for (products) |spec| {
        addProxy(b, target, optimize, options, spec.descriptor.build_step, spec.scope);
        if (spec.descriptor.test_step) |step| addProxy(b, target, optimize, options, step, spec.scope);
        if (spec.descriptor.benchmark_step) |step| {
            if (!std.mem.eql(u8, step, spec.descriptor.build_step))
                addProxy(b, target, optimize, options, step, spec.scope);
        }
        if (spec.identity_step) |step| addProxy(b, target, optimize, options, step, spec.scope);
    }
    addProxy(b, target, optimize, options, "product-matrix-identity", "aggregate");
}

fn addProxy(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: delegation.Options,
    name: []const u8,
    scope: []const u8,
) void {
    delegation.addProxy(
        b,
        target,
        optimize,
        options,
        name,
        b.fmt("Build or validate product step {s}", .{name}),
        scope,
    );
}

pub fn find(name: []const u8) ?product_policy.Descriptor {
    for (descriptors) |descriptor| {
        if (std.mem.eql(u8, descriptor.product.name, name)) return descriptor;
    }
    return null;
}

pub fn findByScope(scope: []const u8) ?Spec {
    for (products) |spec| {
        if (std.mem.eql(u8, spec.scope, scope) and spec.constructor != .unavailable) return spec;
    }
    return null;
}

pub fn productIdsForScope(b: *std.Build, scope: []const u8) []const []const u8 {
    var count: usize = 0;
    for (products) |spec| count += @intFromBool(std.mem.eql(u8, spec.scope, scope));
    const result = b.allocator.alloc([]const u8, count) catch @panic("out of memory");
    var index: usize = 0;
    for (products) |spec| {
        if (!std.mem.eql(u8, spec.scope, scope)) continue;
        result[index] = spec.descriptor.product.name;
        index += 1;
    }
    return result;
}

pub fn addDeferredProducts(b: *std.Build, target: std.Build.ResolvedTarget) void {
    inline for (descriptors) |descriptor| {
        if (!descriptor.isConstructible())
            product_policy.registerUnavailable(b, descriptor, target.result.os.tag);
    }
}

pub fn addIdentity(b: *std.Build) void {
    var records: [descriptors.len]MatrixProduct = undefined;
    inline for (descriptors, 0..) |descriptor, index| {
        const closure = descriptor.source_closure;
        records[index] = .{
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
            .allowed_files = if (closure) |value| value.allowed_files else &.{},
            .allowed_prefixes = if (closure) |value| value.allowed_prefixes else &.{},
            .configure_allowed_files = specForDescriptor(descriptor).configure_allowed_files,
            .configure_allowed_prefixes = specForDescriptor(descriptor).configure_allowed_prefixes,
        };
    }
    const payload = std.json.Stringify.valueAlloc(b.allocator, .{
        .schema = "stwo-product-matrix-v1",
        .products = &records,
    }, .{}) catch @panic("cannot encode product matrix");
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const encoded = std.json.Stringify.valueAlloc(b.allocator, .{
        .schema = "stwo-product-matrix-v1",
        .matrix_sha256 = &hex,
        .products = &records,
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
    allowed_files: []const []const u8,
    allowed_prefixes: []const []const u8,
    configure_allowed_files: []const []const u8,
    configure_allowed_prefixes: []const []const u8,
};

fn specForDescriptor(descriptor: product_policy.Descriptor) Spec {
    for (products) |spec| {
        if (std.mem.eql(u8, spec.descriptor.product.name, descriptor.product.name)) return spec;
    }
    unreachable;
}

test "every central product descriptor is valid" {
    inline for (descriptors) |descriptor| try descriptor.validate();
}

test "every catalog product is represented exactly once" {
    inline for (products, 0..) |candidate, index| {
        var product_count: usize = 0;
        var build_step_count: usize = 0;
        inline for (products) |other| {
            product_count += @intFromBool(std.mem.eql(
                u8,
                candidate.descriptor.product.name,
                other.descriptor.product.name,
            ));
            build_step_count += @intFromBool(std.mem.eql(
                u8,
                candidate.descriptor.build_step,
                other.descriptor.build_step,
            ));
        }
        try std.testing.expectEqual(@as(usize, 1), product_count);
        try std.testing.expectEqual(@as(usize, 1), build_step_count);
        try std.testing.expectEqualDeep(candidate.descriptor, descriptors[index]);
    }
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
