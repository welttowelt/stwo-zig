//! Test shim for RISC-V prover tests.
//!
//! Exists as a separate root so that `zig build test-riscv-prover` can
//! discover tests in the riscv prover module without pulling in all
//! transitive test dependencies.

const std = @import("std");
pub const prover = @import("frontends/riscv/prover.zig");
pub const prover_tests = @import("tests/riscv/prover_test.zig");
pub const malicious_witness_tests = @import("tests/riscv/malicious_witness_test.zig");
pub const infra_trace = @import("frontends/riscv/infra_trace.zig");
pub const interaction_gen = @import("frontends/riscv/air/interaction_gen.zig");
pub const riscv_air_component = @import("frontends/riscv/air/component.zig");
pub const hash_component = @import("frontends/riscv/air/memory_commitment/hash_component.zig");
pub const proof_transcript = @import("frontends/riscv/proof_transcript.zig");

test {
    _ = prover;
    _ = prover_tests;
    _ = malicious_witness_tests;
    _ = interaction_gen;
    _ = riscv_air_component;
    _ = hash_component;
    _ = proof_transcript;
    std.testing.refAllDeclsRecursive(infra_trace);
}
