//! Domain-specific proof system frontends for stwo-zig.
//!
//! A frontend defines:
//! - AIR component constraints (via the constraint framework)
//! - Trace generation logic
//! - A prove/verify orchestration function
//!
//! Frontends are parameterized by backend: `proveCairo(CpuBackend, ...)`.
//!
//! ## Available frontends
//!
//! - `examples` — Reference implementations (blake, poseidon, plonk, state_machine, etc.)
//! - `cairo` — (future) Full stwo-cairo prover in Zig

pub const examples = @import("../examples/mod.zig");
