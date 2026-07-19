//! Explicit unavailable Stark-V RV32IM + Metal composition descriptor.

const policy = @import("../graph/product.zig");

pub const descriptor = policy.Descriptor{
    .product = .{
        .name = "stwo-riscv-metal",
        .frontend = .riscv,
        .backend = .metal,
        .role = .cli,
        .protocol_features = "stark-v-rv32im+metal-composition-deferred",
    },
    .state = .unavailable,
    .target_support = .macos,
    .unsupported_target_reason = "the Metal backend requires a macOS target and Apple Metal SDK",
    .unavailable_reason = "the RISC-V Metal integration has no parity-gated product implementation",
    .build_step = "stwo-riscv-metal",
    .test_step = null,
    .executable = null,
};
