//! Configure-manifest projection of the authoritative typed product catalog.

const std = @import("std");
const configure_manifest = @import("../graph/configure_manifest.zig");
const matrix = @import("../products/matrix.zig");

pub const Scope = matrix.Scope;

pub fn add(b: *std.Build, scope: Scope, aggregate_metal: bool) void {
    const selected = matrix.scopeManifest(b, scope, aggregate_metal);
    configure_manifest.add(.{
        .b = b,
        .scope = @tagName(scope),
        .scope_role = @tagName(selected.role),
        .product_ids = selected.product_ids,
        .module_roots = selected.module_roots,
        .generated_module_roots = selected.generated_module_roots,
        .dependency_module_roots = selected.dependency_module_roots,
        .allowed_module_files = selected.allowed_module_files,
        .allowed_module_prefixes = selected.allowed_module_prefixes,
        .external_tools = selected.external_tools,
        .runtime_probes = selected.runtime_probes,
        .constructors = selected.constructors,
        .constructed_products = selected.constructed_products,
    });
}
