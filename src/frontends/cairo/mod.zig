//! stwo-cairo-zig: Cairo execution trace prover frontend.
//!
//! Implements a Cairo STARK prover in Zig, equivalent to the Rust
//! `stwo-cairo` crate. Converts Cairo VM execution traces into
//! STARK proofs using the stwo prover backend.
//!
//! ## Architecture
//!
//! ```
//! Cairo Program → cairo-vm → raw trace
//!   → adapter.ProverInput
//!   → prover.proveCairo(B, H, MC, input) → StarkProof(H)
//! ```
//!
//! ## Submodules
//!
//! - `adapter` — Instruction decoding, opcode classification, memory model
//! - `air` — AIR component constraints (~70 components)
//! - `common` — Felt252, CasmState, Memory, preprocessed tables

pub const adapter = @import("adapter/mod.zig");
pub const air = @import("air/mod.zig");
pub const common = @import("common/mod.zig");

// Convenience re-exports.
pub const Felt252 = common.Felt252;
pub const CasmState = common.CasmState;
pub const ProverInput = adapter.ProverInput;
