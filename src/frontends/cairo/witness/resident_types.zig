//! Public contracts and canonical field decoding shared by resident verification.

const std = @import("std");
const channel_blake2s = @import("../../../core/channel/blake2s.zig");
const m31 = @import("../../../core/fields/m31.zig");
const qm31 = @import("../../../core/fields/qm31.zig");
const proof_mod = @import("../../../core/proof.zig");
const blake2_merkle = @import("../../../core/vcs_lifted/blake2_merkle.zig");
const composition_bundle = @import("composition_bundle.zig");
const proof_bundle = @import("proof_bundle.zig");

pub const M31 = m31.M31;
pub const QM31 = qm31.QM31;

pub const Hasher = blake2_merkle.Blake2sMerkleHasher;
pub const Proof = proof_mod.StarkProof(Hasher);
pub const Channel = channel_blake2s.Blake2sChannel;
pub const MerkleChannel = blake2_merkle.Blake2sMerkleChannel;

pub const sn2_pow_bits: u32 = 26;
pub const sn2_interaction_pow_bits: u32 = 24;
pub const sn2_query_count: usize = 70;
pub const sn2_fold_step: u32 = 3;

pub const Error = error{
    InvalidProofShape,
    InvalidSampleShape,
    InvalidTraceShape,
    InvalidFriShape,
    InvalidComponentShape,
    InvalidProgram,
    NonCanonicalM31,
    MissingMaskValue,
};

pub const SampleShape = struct {
    /// Per tree, per column, number of OODS samples in transcript order.
    trees: []const []const usize,
};

pub const TranscriptInput = struct {
    ordinal: u32,
    words: []const u32,
};

pub const VerifyInput = struct {
    bundle: proof_bundle.ProofBundle,
    composition: composition_bundle.Bundle,
    /// Degree logs for the preprocessed, base, and interaction trees.
    tree_logs: [3][]const u32,
    /// Direct-PIE statement transcript prefix. Roots and proof payloads are
    /// cross-checked against the resident bundle before they are absorbed.
    transcript_inputs: []const TranscriptInput,
};

pub fn m31FromWord(word: u32) Error!M31 {
    if (word >= m31.Modulus) return Error.NonCanonicalM31;
    return M31.fromCanonical(word);
}

pub fn qm31FromWords(words: []const u32) Error!QM31 {
    if (words.len != 4) return Error.InvalidProofShape;
    return QM31.fromM31(
        try m31FromWord(words[0]),
        try m31FromWord(words[1]),
        try m31FromWord(words[2]),
        try m31FromWord(words[3]),
    );
}

pub fn qm31Words(value: QM31) [4]u32 {
    const coordinates = value.toM31Array();
    return .{ coordinates[0].v, coordinates[1].v, coordinates[2].v, coordinates[3].v };
}

test "resident verifier rejects non-canonical field words" {
    try std.testing.expectError(Error.NonCanonicalM31, m31FromWord(m31.Modulus));
}
