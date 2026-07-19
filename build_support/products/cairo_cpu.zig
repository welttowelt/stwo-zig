//! Disabled Cairo + CPU product descriptor; semantic port work is out of scope.

const policy = @import("../graph/product.zig");

pub const descriptor = policy.Descriptor{
    .product = .{
        .name = "stwo-cairo-cpu",
        .frontend = .cairo,
        .backend = .cpu,
        .role = .cli,
        .protocol_features = "cairo-semantics-deferred",
    },
    .state = .disabled,
    .target_support = .any,
    .unavailable_reason = "Cairo proving remains disabled until its separate Rust-oracle semantic release goal passes",
    .build_step = "stwo-cairo-cpu",
    .test_step = null,
    .executable = null,
};
