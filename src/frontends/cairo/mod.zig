//! stwo-cairo-zig: Cairo execution trace prover frontend.
//!
//! This module implements a full Cairo STARK prover in Zig, equivalent to
//! the Rust `stwo-cairo` crate. It converts Cairo VM execution traces into
//! STARK proofs using the stwo prover backend.
//!
//! ## Architecture
//!
//! ```
//! Cairo Program → cairo-vm → raw trace
//!   → adapter.adaptTrace() → ProverInput
//!   → prover.proveCairo(B, H, MC, input) → StarkProof(H)
//! ```
//!
//! ## Submodules
//!
//! - `adapter` — Converts Cairo VM output to typed ProverInput
//!   (instruction decoding, memory relocation, opcode classification)
//! - `air` — ~70 AIR component constraint definitions + ~90 subroutines
//! - `prover` — Top-level prove_cairo orchestration
//! - `common` — Preprocessed lookup tables (Pedersen, Poseidon, Blake, XOR)
//!
//! ## Status: Scaffold
//!
//! This module is a structural scaffold. Implementation will be added
//! incrementally in Phase 6.

pub const adapter = @import("adapter/mod.zig");
pub const air = @import("air/mod.zig");
pub const common = @import("common/mod.zig");
