//! Explicit experimental Native + CUDA composition descriptor.

const policy = @import("../graph/product.zig");

pub const descriptor = policy.Descriptor{
    .product = .{
        .name = "stwo-native-cuda",
        .frontend = .native,
        .backend = .cuda,
        .role = .cli,
        .protocol_features = "native-examples-v1+cuda-runtime-explicit",
    },
    .state = .experimental,
    .target_support = .any,
    .unavailable_reason = "the experimental Native CUDA product requires an explicit toolchain contract and a separately parity-gated kernel implementation",
    .build_step = "stwo-native-cuda",
    .test_step = null,
    .executable = null,
};
