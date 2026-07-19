//! Versioned configure plan emitted by each delegated internal build scope.

const std = @import("std");
const observer = @import("construction_observer.zig");

pub const Inputs = struct {
    b: *std.Build,
    scope: []const u8,
    product_ids: []const []const u8,
    module_roots: []const []const u8,
    external_tools: []const []const u8 = &.{},
    runtime_probes: []const []const u8 = &.{},
    constructors: []const []const u8,
    declarative_exports_only: bool = false,
};

pub fn add(inputs: Inputs) void {
    const actual = observer.observe(inputs.b);
    const encoded = std.json.Stringify.valueAlloc(inputs.b.allocator, .{
        .schema = "stwo-configure-manifest-v2",
        .scope = inputs.scope,
        .product_ids = inputs.product_ids,
        .module_roots = inputs.module_roots,
        .external_tools = inputs.external_tools,
        .runtime_probes = inputs.runtime_probes,
        .constructors = inputs.constructors,
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
