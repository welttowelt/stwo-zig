//! Disabled Cairo + Metal composition descriptor.

const policy = @import("../graph/product.zig");

pub const descriptor = policy.Descriptor{
    .product = .{
        .name = "stwo-cairo-metal",
        .frontend = .cairo,
        .backend = .metal,
        .role = .cli,
        .protocol_features = "cairo-semantics-deferred+metal-runtime-v1",
    },
    .state = .disabled,
    .target_support = .macos,
    .unsupported_target_reason = "the Metal backend requires a macOS target and Apple Metal SDK",
    .unavailable_reason = "Cairo Metal proving is disabled until Cairo CPU semantics pass their separate Rust-oracle release goal",
    .build_step = "stwo-cairo-metal",
    .test_step = null,
    .executable = null,
};
