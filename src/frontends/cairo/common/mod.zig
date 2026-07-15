//! Common types and preprocessed data for the Cairo frontend.
//!
//! Contains:
//! - Field element types (Felt252)
//! - CPU state types (CasmState)
//! - Memory model (address-to-id, small/big value tables)
//! - Preprocessed lookup tables (Pedersen, Poseidon, Blake, XOR) [future]

pub const felt252 = @import("felt252.zig");
pub const cpu = @import("cpu.zig");
pub const memory = @import("memory.zig");

pub const Felt252 = felt252.Felt252;
pub const CasmState = cpu.CasmState;
pub const Memory = memory.Memory;
pub const EncodedMemoryValueId = memory.EncodedMemoryValueId;
