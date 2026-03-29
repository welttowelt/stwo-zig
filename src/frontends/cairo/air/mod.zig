//! Cairo AIR (Algebraic Intermediate Representation) definitions.
//!
//! Contains ~70 component constraint files and ~90 shared subroutines
//! that define the polynomial constraints for each Cairo opcode, builtin,
//! and memory operation.
//!
//! These constraints are evaluated via the `ExprEvaluator` API from
//! `core/constraint_framework/`.

/// Component constraint definitions (add_opcode, ret_opcode, etc.)
pub const components = struct {};

/// Shared subroutine constraints (instruction decoding, memory reads, etc.)
pub const relations = struct {};

/// Claim types for each component.
pub const claims = struct {};
