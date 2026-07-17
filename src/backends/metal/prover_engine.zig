const std = @import("std");
const channel_blake2s = @import("../../core/channel/blake2s.zig");
const blake2_merkle = @import("../../core/vcs_lifted/blake2_merkle.zig");
const prover_engine = @import("../../prover/engine.zig");
const MetalCommitBackend = @import("commit_backend.zig").MetalCommitBackend;

const Hasher = blake2_merkle.Blake2sMerkleHasher;
const MerkleChannel = blake2_merkle.Blake2sMerkleChannel;
const Channel = channel_blake2s.Blake2sChannel;

/// Complete prover composition with Metal commitments and the shared protocol.
pub const MetalProverEngine = prover_engine.ProverEngine(
    MetalCommitBackend,
    Hasher,
    MerkleChannel,
    Channel,
);

comptime {
    prover_engine.assertProverEngine(MetalProverEngine);
}

test "Metal prover engine satisfies the shared transaction contract" {
    comptime prover_engine.assertProverEngine(MetalProverEngine);
    std.testing.refAllDecls(MetalProverEngine);
    _ = MetalProverEngine.TelemetrySnapshot;
    _ = &MetalProverEngine.telemetrySnapshot;
}
