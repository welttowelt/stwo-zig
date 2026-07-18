//! Test shim for RISC-V prover tests.
//!
//! Exists as a separate root so that `zig build test-riscv-prover` can
//! discover tests in the riscv prover module without pulling in all
//! transitive test dependencies.

const std = @import("std");
pub const prover = @import("frontends/riscv/prover.zig");
pub const infra_trace = @import("frontends/riscv/infra_trace.zig");
pub const interaction_gen = @import("frontends/riscv/air/interaction_gen.zig");
pub const riscv_air_component = @import("frontends/riscv/air/component.zig");

test {
    _ = prover;
    _ = interaction_gen;
    _ = riscv_air_component;
    std.testing.refAllDeclsRecursive(infra_trace);
}
