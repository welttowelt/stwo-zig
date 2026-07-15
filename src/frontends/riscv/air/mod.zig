//! RISC-V AIR (Algebraic Intermediate Representation) module.
//!
//! Provides the constraint definitions, trace column layouts, claim types,
//! and relation definitions for the RV32IM zkVM.

pub const claims = @import("claims.zig");
pub const interaction = @import("interaction.zig");
pub const relations = @import("relations.zig");
pub const trace_columns = @import("trace_columns.zig");
pub const components = @import("components/mod.zig");
pub const preprocessed = @import("preprocessed/mod.zig");

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
