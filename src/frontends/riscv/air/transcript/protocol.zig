//! Shared Stark-V RISC-V claim-phase Fiat-Shamir protocol.
//!
//! This module deliberately stops at the generic Stwo composition phase. It
//! owns the protocol prefix through the interaction commitment, so prover and
//! verifier integrations cannot silently reorder claim-phase events.

const std = @import("std");
const builtin = @import("builtin");
const claims = @import("claims.zig");
const public_data = @import("../public_data.zig");
const relation_challenges = @import("../relation_challenges.zig");

pub const INTERACTION_POW_BITS_DEBUG: u32 = 1;
pub const INTERACTION_POW_BITS_RELEASE: u32 = 10;

pub const Difficulty = struct {
    bits: u32,

    pub fn init(bits: u32) Difficulty {
        return .{ .bits = bits };
    }

    pub fn default() Difficulty {
        return .{ .bits = if (builtin.mode == .Debug)
            INTERACTION_POW_BITS_DEBUG
        else
            INTERACTION_POW_BITS_RELEASE };
    }
};

pub const PrefixError = error{InvalidInteractionProofOfWork};

pub const ProverRelations = struct {
    interaction_pow: u64,
    relations: relation_challenges.Relations,
};

test "claim phase: default interaction PoW difficulty matches Stark-V build mode" {
    const expected = if (builtin.mode == .Debug)
        INTERACTION_POW_BITS_DEBUG
    else
        INTERACTION_POW_BITS_RELEASE;
    try std.testing.expectEqual(expected, Difficulty.default().bits);
}

/// Mix public data, preprocessed and main roots, then the canonical main claim.
/// Stark-V does not mix PCS configuration into this protocol prefix.
pub fn mixCommittedPrefix(
    comptime MerkleChannel: type,
    channel: anytype,
    data: *const public_data.PublicData,
    preprocessed_root: anytype,
    main_root: anytype,
    main_claim: *const claims.MainClaim,
) void {
    data.mixInto(channel);
    MerkleChannel.mixRoot(channel, preprocessed_root);
    MerkleChannel.mixRoot(channel, main_root);
    main_claim.mixInto(channel);
}

/// Prover-side prefix: committed data, interaction PoW, then all twelve
/// independent relation challenge pairs.
pub fn proveToRelations(
    comptime MerkleChannel: type,
    allocator: std.mem.Allocator,
    channel: anytype,
    data: *const public_data.PublicData,
    preprocessed_root: anytype,
    main_root: anytype,
    main_claim: *const claims.MainClaim,
    difficulty: Difficulty,
) !ProverRelations {
    mixCommittedPrefix(
        MerkleChannel,
        channel,
        data,
        preprocessed_root,
        main_root,
        main_claim,
    );
    const nonce = channel.grind(difficulty.bits);
    channel.mixU64(nonce);
    return .{
        .interaction_pow = nonce,
        .relations = try relation_challenges.Relations.draw(allocator, channel),
    };
}

/// Verifier-side replay of exactly the same prefix. Invalid PoW fails before
/// the nonce is mixed or any relation challenge is drawn.
pub fn verifyToRelations(
    comptime MerkleChannel: type,
    allocator: std.mem.Allocator,
    channel: anytype,
    data: *const public_data.PublicData,
    preprocessed_root: anytype,
    main_root: anytype,
    main_claim: *const claims.MainClaim,
    difficulty: Difficulty,
    interaction_pow: u64,
) !relation_challenges.Relations {
    mixCommittedPrefix(
        MerkleChannel,
        channel,
        data,
        preprocessed_root,
        main_root,
        main_claim,
    );
    if (!channel.verifyPowNonce(difficulty.bits, interaction_pow)) {
        return PrefixError.InvalidInteractionProofOfWork;
    }
    channel.mixU64(interaction_pow);
    return relation_challenges.Relations.draw(allocator, channel);
}

/// Mix the interaction claim before its non-empty tree root, matching pinned
/// Stark-V. This ordering is intentionally unavailable as separate public
/// operations.
pub fn finishWithInteractionRoot(
    comptime MerkleChannel: type,
    channel: anytype,
    interaction_claim: *const claims.InteractionClaim,
    interaction_root: anytype,
) void {
    interaction_claim.mixInto(channel);
    MerkleChannel.mixRoot(channel, interaction_root);
}

/// Finish a claim phase with no interaction columns. Stark-V still mixes the
/// canonical interaction claim but does not commit an empty tree.
pub fn finishWithoutInteractionRoot(
    channel: anytype,
    interaction_claim: *const claims.InteractionClaim,
) error{UnexpectedInteractionColumns}!void {
    if (interaction_claim.log_sizes.len != 0) return error.UnexpectedInteractionColumns;
    interaction_claim.mixInto(channel);
}
