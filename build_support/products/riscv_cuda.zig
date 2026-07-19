//! Explicit unavailable Stark-V RV32IM + CUDA composition descriptor.

const policy = @import("../graph/product.zig");

pub const descriptor = policy.Descriptor{
    .product = .{
        .name = "stwo-riscv-cuda",
        .frontend = .riscv,
        .backend = .cuda,
        .role = .cli,
        .protocol_features = "stark-v-rv32im+cuda-composition-deferred",
    },
    .state = .unavailable,
    .target_support = .any,
    .unavailable_reason = "the RISC-V CUDA integration has no parity-gated product implementation",
    .build_step = "stwo-riscv-cuda",
    .test_step = null,
    .executable = null,
};
