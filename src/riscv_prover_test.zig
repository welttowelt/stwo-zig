//! Test shim for RISC-V prover tests.
//!
//! Exists as a separate root so that `zig build test-riscv-prover` can
//! discover tests in the riscv prover module without pulling in all
//! transitive test dependencies.

const std = @import("std");
pub const prover = @import("frontends/riscv/prover.zig");

test {
    _ = prover;
}
