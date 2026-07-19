//! Disabled Cairo + CUDA composition descriptor.

const policy = @import("../graph/product.zig");

pub const descriptor = policy.Descriptor{
    .product = .{
        .name = "stwo-cairo-cuda",
        .frontend = .cairo,
        .backend = .cuda,
        .role = .cli,
        .protocol_features = "cairo-semantics-deferred+cuda-runtime-explicit",
    },
    .state = .disabled,
    .target_support = .any,
    .unavailable_reason = "Cairo CUDA proving is disabled until Cairo CPU semantics pass their separate Rust-oracle release goal",
    .build_step = "stwo-cairo-cuda",
    .test_step = null,
    .executable = null,
};
