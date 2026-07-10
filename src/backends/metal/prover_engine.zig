const std = @import("std");
const pcs_core = @import("../../core/pcs/mod.zig");
const proof = @import("../../core/proof.zig");
const channel_blake2s = @import("../../core/channel/blake2s.zig");
const blake2_merkle = @import("../../core/vcs_lifted/blake2_merkle.zig");
const component = @import("../../prover/air/component_prover.zig");
const pcs = @import("../../prover/pcs/mod.zig");
const prove_mod = @import("../../prover/prove.zig");
const stage_profile = @import("../../prover/stage_profile.zig");
const MetalCommitBackend = @import("commit_backend.zig").MetalCommitBackend;

const Hasher = blake2_merkle.Blake2sMerkleHasher;
const MerkleChannel = blake2_merkle.Blake2sMerkleChannel;
const Channel = channel_blake2s.Blake2sChannel;

/// First executable Metal engine: all PCS trace/composition commitments use
/// Metal while composition and FRI arithmetic continue through the CPU
/// compatibility implementation. The outer contract does not change when
/// those remaining stages become resident.
pub const MetalProverEngine = struct {
    pub const Scheme = pcs.CommitmentSchemeProver(MetalCommitBackend, Hasher, MerkleChannel);

    pub fn init(allocator: std.mem.Allocator, config: pcs_core.PcsConfig) !Scheme {
        return Scheme.init(allocator, config);
    }

    pub fn warmup() !void {
        return @import("commit_backend.zig").warmup();
    }

    pub fn commit(
        scheme: *Scheme,
        allocator: std.mem.Allocator,
        columns: []pcs.ColumnEvaluation,
        recorder: ?*stage_profile.Recorder,
        channel: *Channel,
    ) !void {
        return scheme.commitOwnedWithRecorder(allocator, columns, recorder, channel);
    }

    pub fn prove(
        allocator: std.mem.Allocator,
        components: []const component.ComponentProver,
        channel: *Channel,
        scheme: Scheme,
        recorder: ?*stage_profile.Recorder,
    ) !proof.ExtendedStarkProof(Hasher) {
        return prove_mod.proveExWithRecorder(
            MetalCommitBackend,
            Hasher,
            MerkleChannel,
            allocator,
            components,
            channel,
            scheme,
            false,
            recorder,
        );
    }
};
