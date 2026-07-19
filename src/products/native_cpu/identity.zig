//! Runtime view of the generated product identity.

const runner = @import("native_proof_runner");
const generated = @import("product_identity");
const std = @import("std");

pub fn value() runner.config.ProductIdentity {
    return .{
        .schema_version = generated.schema_version,
        .name = generated.product,
        .frontend = generated.frontend,
        .backend = generated.backend,
        .role = generated.role,
        .protocol_features = generated.protocol_features,
        .protocol_manifest_sha256 = generated.protocol_manifest_sha256,
        .identity_sha256 = generated.identity_sha256,
        .implementation_repository = generated.implementation_repository,
        .implementation_commit = generated.implementation_commit,
        .implementation_tree = if (generated.implementation_tree_available)
            generated.implementation_tree
        else
            null,
        .implementation_dirty = generated.implementation_dirty,
        .dirty_content_sha256 = if (generated.dirty_content_sha256_available)
            generated.dirty_content_sha256
        else
            null,
        .zig_version = generated.zig_version,
        .target_arch = generated.target_arch,
        .target_os = generated.target_os,
        .target_abi = generated.target_abi,
        .cpu_model = generated.cpu_model,
        .cpu_features_sha256 = generated.cpu_features_sha256,
        .optimize = generated.optimize,
        .runtime_manifest = generated.runtime_manifest,
        .sdk_manifest = generated.sdk_manifest,
        .aot_manifest = generated.aot_manifest,
    };
}

test "generated Native CPU identity is internally consistent" {
    const actual = value();
    try actual.validate();
    try std.testing.expectEqualStrings("stwo-native-cpu", actual.name);
    try std.testing.expectEqualStrings("cpu", actual.backend);
    try std.testing.expectEqualStrings("none", actual.runtime_manifest);
}
