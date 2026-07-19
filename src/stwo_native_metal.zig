//! Focused Stwo facade for Native example AIRs on Metal.

const std = @import("std");

pub const core = @import("core/mod.zig");
pub const backend = @import("backend/mod.zig");
pub const prover = @import("prover/mod.zig");

pub const backends = struct {
    pub const cpu = @import("backends/cpu_scalar/mod.zig");
    pub const metal = @import("backends/metal/mod.zig");
};

pub const examples = struct {
    pub const blake = @import("examples/blake.zig");
    pub const plonk = @import("examples/plonk.zig");
    pub const poseidon = @import("examples/poseidon.zig");
    pub const state_machine = @import("examples/state_machine.zig");
    pub const wide_fibonacci = @import("examples/wide_fibonacci.zig");
    pub const xor = @import("examples/xor.zig");
};

pub const interop = struct {
    pub const examples_artifact = @import("interop/examples_artifact.zig");
    pub const postcard = @import("interop/postcard.zig");
    pub const proof_wire = @import("interop/proof_wire.zig");
};

test {
    std.testing.refAllDecls(@This());
}
