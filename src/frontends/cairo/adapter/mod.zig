//! Cairo VM trace adapter.
//!
//! Converts raw Cairo VM execution output into typed `ProverInput`:
//! - Instruction decoding and opcode classification (~25 categories)
//! - Memory relocation (segment:offset → flat addresses)
//! - State transition grouping by opcode
//! - Builtin segment padding to power-of-2

const std = @import("std");

/// Input to the Cairo prover, produced by adapting a Cairo VM trace.
pub const ProverInput = struct {
    /// TODO: memory, instructions, component inputs
    _placeholder: u8 = 0,
};

/// Decode raw Cairo VM output into typed prover input.
pub fn adaptTrace(allocator: std.mem.Allocator, raw_trace: []const u8) !ProverInput {
    _ = allocator;
    _ = raw_trace;
    return .{};
}
