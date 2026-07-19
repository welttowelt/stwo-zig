//! Authoritative capability and release-admission data for Stark-V RV32IM.

/// RF-01 flips this in the same commit as the artifact release status after
/// every RISC-V soundness and oracle gate passes.
pub const adapter_release_gated = false;
pub const adapter = "stark-v-rv32im-elf";
pub const air = "stark_v_rv32im";
pub const isa = "rv32im";
pub const backend = "cpu";
pub const deferred_reason = "RISC-V release contract is not yet fully satisfied";

pub fn requireAdmission(experimental: bool) !void {
    if (adapter_release_gated) {
        if (experimental) return error.ExperimentalFlagAfterPromotion;
    } else if (!experimental) {
        return error.ExperimentalFlagRequired;
    }
}

test "staged admission is explicit and fail closed" {
    const std = @import("std");
    if (adapter_release_gated) {
        try requireAdmission(false);
        try std.testing.expectError(error.ExperimentalFlagAfterPromotion, requireAdmission(true));
    } else {
        try requireAdmission(true);
        try std.testing.expectError(error.ExperimentalFlagRequired, requireAdmission(false));
    }
}
