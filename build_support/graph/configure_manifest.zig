//! Versioned configure plan emitted by each delegated internal build scope.

const std = @import("std");
const observer = @import("construction_observer.zig");

pub const Inputs = struct {
    b: *std.Build,
    scope: []const u8,
    scope_role: []const u8,
    product_ids: []const []const u8,
    module_roots: []const []const u8,
    generated_module_roots: []const []const u8,
    dependency_module_roots: []const []const u8,
    allowed_module_files: []const []const u8,
    allowed_module_prefixes: []const []const u8,
    external_tools: []const []const u8 = &.{},
    runtime_probes: []const []const u8 = &.{},
    constructors: []const []const u8,
    constructed_products: []const observer.ProductIdentity,
    declarative_exports_only: bool = false,
};

pub fn add(inputs: Inputs) void {
    const actual = observer.observe(inputs.b);
    const encoded = std.json.Stringify.valueAlloc(inputs.b.allocator, .{
        .schema = "stwo-configure-manifest-v3",
        .scope = inputs.scope,
        .scope_role = inputs.scope_role,
        .product_ids = inputs.product_ids,
        .module_roots = inputs.module_roots,
        .generated_module_roots = inputs.generated_module_roots,
        .dependency_module_roots = inputs.dependency_module_roots,
        .allowed_module_files = inputs.allowed_module_files,
        .allowed_module_prefixes = inputs.allowed_module_prefixes,
        .external_tools = inputs.external_tools,
        .runtime_probes = inputs.runtime_probes,
        .constructors = inputs.constructors,
        .constructed_products = inputs.constructed_products,
        .declarative_exports_only = inputs.declarative_exports_only,
        .actual = actual,
    }, .{ .whitespace = .indent_2 }) catch @panic("cannot encode configure manifest");
    const files = inputs.b.addWriteFiles();
    const generated = files.add("configure-manifest.json", encoded);
    const install = inputs.b.addInstallFile(
        generated,
        inputs.b.fmt("build-graph/configure-{s}.json", .{inputs.scope}),
    );
    inputs.b.step(
        "configure-manifest",
        "Emit the exact delegated configure plan",
    ).dependOn(&install.step);
}
