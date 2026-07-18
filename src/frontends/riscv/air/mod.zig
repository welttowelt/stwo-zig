//! RISC-V AIR (Algebraic Intermediate Representation) module.
//!
//! Provides the constraint definitions, trace column layouts, claim types,
//! and relation definitions for the RV32IM zkVM.

pub const claims = @import("claims.zig");
pub const interaction = @import("interaction.zig");
pub const memory_commitment = @import("memory_commitment/mod.zig");
pub const memory_logup = @import("memory_logup.zig");
pub const opcode_memory = @import("opcode_memory.zig");
pub const public_data = @import("public_data.zig");
pub const public_logup = @import("public_logup.zig");
pub const program = @import("program/mod.zig");
pub const relation_challenges = @import("relation_challenges.zig");
pub const relations = @import("relations.zig");
pub const semantic_eval = @import("semantic_eval.zig");
pub const semantics = @import("semantics/mod.zig");
pub const statement = @import("statement.zig");
pub const transcript = @import("transcript/mod.zig");
pub const trace_columns = @import("trace_columns.zig");
pub const components = @import("components/mod.zig");
pub const preprocessed = @import("preprocessed/mod.zig");

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
