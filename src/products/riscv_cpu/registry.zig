//! Machine-readable capability surface for the focused RISC-V CPU product.

const std = @import("std");
const admission = @import("../../tools/prove/registry.zig");
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
            .identity_sha256 = identity.identity_sha256,
            .source = .{
                .commit = identity.implementation_commit,
                .tree = if (identity.implementation_tree_available)
                    identity.implementation_tree
                else
                    null,
                .dirty = identity.implementation_dirty,
            },
            .target = .{
                .arch = identity.target_arch,
                .os = identity.target_os,
                .abi = identity.target_abi,
                .cpu_model = identity.cpu_model,
                .cpu_features_sha256 = identity.cpu_features_sha256,
            },
            .optimize = identity.optimize,
        },
        .backend_availability = .{ .cpu = true },
        .applications = if (admission.RISCV_ADAPTER_RELEASE_GATED)
            &[_]Application{Application.releaseGated()}
        else
            &[_]Application{},
        .deferred_adapters = if (admission.RISCV_ADAPTER_RELEASE_GATED)
            &[_]Application{}
        else
            &[_]Application{Application.deferred()},
    }, .{}, writer);
}

const Application = struct {
    adapter: []const u8 = "stark-v-rv32im-elf",
    air: []const u8 = "stark_v_rv32im",
    status: []const u8,
    isa: []const u8 = "rv32im",
    backends: []const []const u8 = &.{"cpu"},
    reason: ?[]const u8 = null,

    fn releaseGated() Application {
        return .{ .status = "release_gated" };
    }

    fn deferred() Application {
        return .{
            .status = "not_release_gated",
            .reason = "RISC-V release contract is not yet fully satisfied",
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
    try std.testing.expectEqual(@as(usize, 1), root.get("backend_availability").?.object.count());
    try std.testing.expect(root.get("backend_availability").?.object.get("cpu").?.bool);
    const encoded = output.buffered();
    inline for (.{ "metal", "cuda", "cairo", "wide_fibonacci", "poseidon" }) |forbidden| {
        try std.testing.expect(std.mem.indexOf(u8, encoded, forbidden) == null);
    }
}
