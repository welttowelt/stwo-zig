//! RISC-V RV32IM zkVM frontend (stark-v port).
//!
//! Provides an execution runner for RISC-V RV32IM programs (ELF loading,
//! decode, execute) and will eventually include AIR constraints and trace
//! generation for STARK proving.

pub const runner = @import("runner/mod.zig");

// Convenience re-exports.
pub const Cpu = runner.Cpu;
pub const Memory = runner.Memory;
pub const Opcode = runner.Opcode;
