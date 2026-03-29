//! Cairo VM trace adapter.
//!
//! Converts raw Cairo VM execution output into typed `ProverInput`:
//! - Instruction decoding (`decode.zig`)
//! - Opcode classification into 20 categories (`opcodes.zig`)
//! - Memory relocation (segment:offset → flat addresses)
//! - State transition grouping by opcode

const std = @import("std");
const cpu = @import("../common/cpu.zig");
const memory_mod = @import("../common/memory.zig");

pub const decode = @import("decode.zig");
pub const opcodes = @import("opcodes.zig");
pub const trace_reader = @import("trace_reader.zig");

const CasmState = cpu.CasmState;
const Memory = memory_mod.Memory;

/// Builtin segment descriptors.
pub const BuiltinSegments = struct {
    /// Segment presence flags for 11 builtin types.
    present: [N_PUBLIC_SEGMENTS]bool = .{false} ** N_PUBLIC_SEGMENTS,

    pub const N_PUBLIC_SEGMENTS: usize = 11;
    // 0=output, 1=pedersen, 2=range_check, 3=ecdsa, 4=bitwise,
    // 5=ec_op, 6=keccak, 7=poseidon, 8=range_check96, 9=add_mod, 10=mul_mod
};

/// State transitions extracted from a Cairo VM trace.
pub const StateTransitions = struct {
    initial_state: CasmState,
    final_state: CasmState,
    casm_states_by_opcode: opcodes.CasmStatesByOpcode,

    pub fn deinit(self: *StateTransitions, allocator: std.mem.Allocator) void {
        self.casm_states_by_opcode.deinit(allocator);
        self.* = undefined;
    }
};

/// Input to the Cairo prover, produced by adapting a Cairo VM trace.
pub const ProverInput = struct {
    state_transitions: StateTransitions,
    memory: Memory,
    pc_count: usize,
    public_memory_addresses: []u32,
    builtin_segments: BuiltinSegments,

    pub fn deinit(self: *ProverInput, allocator: std.mem.Allocator) void {
        self.state_transitions.deinit(allocator);
        self.memory.deinit(allocator);
        allocator.free(self.public_memory_addresses);
        self.* = undefined;
    }
};
