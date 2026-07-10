//! RISC-V RV32IM zkVM frontend (stark-v port).
//!
//! Provides an execution runner for RISC-V RV32IM programs (ELF loading,
//! decode, execute) and AIR constraints for STARK proving of execution traces.

pub const runner = @import("runner/mod.zig");
pub const air = @import("air/mod.zig");
pub const prover_mod = @import("prover.zig");
pub const infra_trace = @import("infra_trace.zig");
pub const host = @import("host/mod.zig");

// Convenience re-exports.
pub const Cpu = runner.Cpu;
pub const Memory = runner.Memory;
pub const Opcode = runner.Opcode;
pub const HostInterface = host.HostInterface;
pub const HostRuntime = host.HostRuntime;
pub const runWithHost = runner.runWithHost;
pub const runWithInput = runner.runWithInput;
pub const RiscVClaim = air.claims.RiscVClaim;
pub const proveRiscV = prover_mod.proveRiscV;
pub const verifyRiscV = prover_mod.verifyRiscV;
pub const proveAndVerifyElf = prover_mod.proveAndVerifyElf;

test {
    @import("std").testing.refAllDeclsRecursive(infra_trace);
}
