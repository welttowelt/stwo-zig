//! Cairo prover orchestration.
//!
//! Implements the top-level `proveCairo` function that converts a
//! `ProverInput` into a STARK proof by orchestrating the prover pipeline:
//!
//! 1. Preprocessed trace: generate lookup table columns, interpolate, commit
//! 2. Base trace: generate witness columns from opcode states, commit
//! 3. Interaction trace: draw random lookup elements, generate logup columns, commit
//! 4. Verify logup sum == 0
//! 5. Build component list, call generic `prove(B, H, MC, ...)`

const std = @import("std");
const backend_mod = @import("../../backend/mod.zig");
const proof_mod = @import("../../core/proof.zig");
const pcs_mod = @import("../../core/pcs/mod.zig");
const adapter_mod = @import("adapter/mod.zig");
const air_mod = @import("air/mod.zig");
const common = @import("common/mod.zig");

const ProverInput = adapter_mod.ProverInput;
const CairoClaim = air_mod.CairoClaim;

pub const CairoProverError = error{
    EmptyInput,
    LogupSumNonZero,
    ProvingFailed,
};

/// Prove a Cairo execution trace.
///
/// Takes a `ProverInput` (from the adapter) and produces a STARK proof
/// using the specified backend, hash function, and Merkle channel.
///
/// ## Type parameters
/// - `B`: Prover backend (e.g., `CpuBackend`, `SimdBackend`, `CudaBackend`)
/// - `H`: Merkle hash function (e.g., `Blake2sMerkleHasher`)
/// - `MC`: Merkle channel type (e.g., `Blake2sMerkleChannel`)
///
/// ## Example
/// ```zig
/// const CpuBackend = @import("backends/cpu_scalar/mod.zig").CpuBackend;
/// const Hasher = @import("core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleHasher;
/// const MC = @import("core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleChannel;
///
/// const proof = try proveCairo(CpuBackend, Hasher, MC, allocator, input, config);
/// ```
pub fn proveCairo(
    comptime B: type,
    comptime H: type,
    comptime MC: type, // Used in Phase 5 of the pipeline (prove call).
    allocator: std.mem.Allocator,
    input: *ProverInput,
    config: pcs_mod.PcsConfig,
) (std.mem.Allocator.Error || CairoProverError)!proof_mod.StarkProof(H) {
    comptime backend_mod.assertBackendForChannel(B, H);
    _ = MC; // Will be passed to prove(B, H, MC, ...) when pipeline is complete.

    if (input.state_transitions.casm_states_by_opcode.totalCount() == 0) {
        return CairoProverError.EmptyInput;
    }

    // Build the claim from the input.
    const claim = CairoClaim.fromOpcodeStates(
        .{
            .initial_state = input.state_transitions.initial_state,
            .final_state = input.state_transitions.final_state,
        },
        &input.state_transitions.casm_states_by_opcode,
    );
    _ = claim;

    // Phase 1: Preprocessed trace (lookup tables).
    // TODO: Generate and commit preprocessed columns for Pedersen, Poseidon,
    // Blake, bitwise XOR lookup tables.

    // Phase 2: Base trace (witness columns).
    // TODO: For each enabled component, generate trace columns from the
    // corresponding opcode state vectors and commit.

    // Phase 3: Interaction trace (logup).
    // TODO: Draw CommonLookupElements from channel, generate interaction
    // columns, commit.

    // Phase 4: Verify logup sum == 0.
    // TODO: Sum all component interaction claims and verify.

    // Phase 5: Build components and call prove.
    // TODO: Collect all enabled FrameworkComponent instances and call
    // prover.prove(B, H, MC, allocator, components, channel, scheme).

    _ = allocator;
    _ = config;

    // Placeholder: full implementation requires wiring all ~67 component
    // witness generators and the preprocessed trace pipeline.
    return CairoProverError.ProvingFailed;
}
