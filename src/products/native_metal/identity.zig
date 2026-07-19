//! Runtime view of the generated Native Metal product identity.

const runner = @import("native_proof_runner");
const generated = @import("product_identity");

pub fn value() runner.config.ProductIdentity {
    return .{
        .schema_version = generated.schema_version,
        .name = generated.product,
        .frontend = generated.frontend,
        .backend = generated.backend,
        .role = generated.role,
        .protocol_features = generated.protocol_features,
        .identity_sha256 = generated.identity_sha256,
        .implementation_commit = generated.implementation_commit,
        .implementation_tree = if (generated.implementation_tree_available)
            generated.implementation_tree
        else
            null,
        .implementation_dirty = generated.implementation_dirty,
        .target_arch = generated.target_arch,
        .target_os = generated.target_os,
        .target_abi = generated.target_abi,
        .cpu_model = generated.cpu_model,
        .cpu_features_sha256 = generated.cpu_features_sha256,
        .optimize = generated.optimize,
    };
}
