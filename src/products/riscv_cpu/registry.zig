//! Machine-readable capability surface for the focused RISC-V CPU product.

const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("riscv_cpu_capabilities");
const identity = @import("product_identity");

pub fn write(writer: anytype) !void {
    try std.json.Stringify.value(.{
        .schema_version = @as(u32, 1),
        .product = .{
            .schema_version = identity.schema_version,
            .name = identity.product,
            .frontend = identity.frontend,
            .backend = identity.backend,
            .role = identity.role,
            .protocol_features = identity.protocol_features,
            .protocol_manifest_sha256 = identity.protocol_manifest_sha256,
            .identity_sha256 = identity.identity_sha256,
            .source = .{
                .repository = identity.implementation_repository,
                .commit = identity.implementation_commit,
                .tree = if (identity.implementation_tree_available)
                    identity.implementation_tree
                else
                    null,
                .dirty = identity.implementation_dirty,
                .dirty_content_sha256 = if (identity.dirty_content_sha256_available)
                    identity.dirty_content_sha256
                else
                    null,
            },
            .zig_version = identity.zig_version,
            .target = .{
                .arch = identity.target_arch,
                .os = identity.target_os,
                .abi = identity.target_abi,
                .cpu_model = identity.cpu_model,
                .cpu_features_sha256 = identity.cpu_features_sha256,
            },
            .optimize = identity.optimize,
            .runtime = .{
                .manifest = identity.runtime_manifest,
                .sdk = identity.sdk_manifest,
                .aot = identity.aot_manifest,
            },
        },
        .backend_availability = .{ .cpu = true },
        .applications = if (capabilities.adapter_release_gated)
            &[_]Application{Application.releaseGated()}
        else
            &[_]Application{},
        .deferred_adapters = if (capabilities.adapter_release_gated)
            &[_]Application{}
        else
            &[_]Application{Application.deferred()},
    }, .{}, writer);
}

const Application = struct {
    adapter: []const u8 = capabilities.adapter,
    air: []const u8 = capabilities.air,
    status: []const u8,
    isa: []const u8 = capabilities.isa,
    backends: []const []const u8 = &.{capabilities.backend},
    reason: ?[]const u8 = null,

    fn releaseGated() Application {
        return .{ .status = "release_gated" };
    }

    fn deferred() Application {
        return .{
            .status = "not_release_gated",
            .reason = capabilities.deferred_reason,
        };
    }
};

test "registry exposes exactly the RISC-V CPU capability" {
    var storage: [4096]u8 = undefined;
    var output = std.Io.Writer.fixed(&storage);
    try write(&output);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        output.buffered(),
        .{},
    );
    defer parsed.deinit();

    const root = parsed.value.object;
    const product = root.get("product").?.object;
    try std.testing.expectEqual(@as(i64, 2), product.get("schema_version").?.integer);
    try std.testing.expectEqualStrings(builtin.zig_version_string, product.get("zig_version").?.string);
    try std.testing.expectEqualStrings(
        "https://github.com/teddyjfpender/stwo-zig",
        product.get("source").?.object.get("repository").?.string,
    );
    try std.testing.expectEqual(@as(usize, 1), root.get("backend_availability").?.object.count());
    try std.testing.expect(root.get("backend_availability").?.object.get("cpu").?.bool);
    const encoded = output.buffered();
    inline for (.{ "metal", "cuda", "cairo", "wide_fibonacci", "poseidon" }) |forbidden| {
        try std.testing.expect(std.mem.indexOf(u8, encoded, forbidden) == null);
    }
}
