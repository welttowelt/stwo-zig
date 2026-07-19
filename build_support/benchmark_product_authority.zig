//! Emit the host-independent focused benchmark product authority for BG-12.

const std = @import("std");
const identity = @import("graph/identity.zig");
const modules = @import("graph/modules.zig");
const native_cpu = @import("products/native_cpu.zig");
const native_metal = @import("products/native_metal.zig");

const ProductAuthority = struct {
    name: []const u8,
    frontend: []const u8,
    backend: []const u8,
    role: []const u8,
    protocol_features: []const u8,
};

pub fn main() !void {
    const cpu = native_cpu.descriptor(.benchmark);
    const metal_product = native_metal.descriptor(.benchmark);
    try cpu.validate();
    try metal_product.validate();
    const document = .{
        .identity_schema_version = identity.SCHEMA_VERSION,
        .products = .{
            .cpu = authority(cpu.product),
            .metal = authority(metal_product.product),
        },
    };
    const encoded = try std.json.Stringify.valueAlloc(std.heap.page_allocator, document, .{});
    defer std.heap.page_allocator.free(encoded);
    try std.fs.File.stdout().writeAll(encoded);
    try std.fs.File.stdout().writeAll("\n");
}

fn authority(product: modules.Product) ProductAuthority {
    return .{
        .name = product.name,
        .frontend = product.frontendManifest(),
        .backend = product.backendManifest(),
        .role = @tagName(product.role),
        .protocol_features = product.protocol_features,
    };
}
