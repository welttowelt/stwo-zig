//! Active claim-phase transcript helpers for the sharded RISC-V frontend.

const std = @import("std");
const relation_challenges = @import("air/relation_challenges.zig");
const statement_mod = @import("air/statement.zig");
const transcript = @import("air/transcript/mod.zig");

pub const ProverRelations = struct {
    interaction_pow: u64,
    relations: relation_challenges.Relations,
};

pub fn proveToRelations(
    allocator: std.mem.Allocator,
    channel: anytype,
    statement: *const statement_mod.RiscVStatement,
) !ProverRelations {
    const main_claim = statement.canonicalMainClaim();
    main_claim.mixInto(channel);
    statement.mixShardManifest(channel);
    const difficulty = transcript.Difficulty.default();
    const nonce = channel.grind(difficulty.bits);
    channel.mixU64(nonce);
    return .{
        .interaction_pow = nonce,
        .relations = try relation_challenges.Relations.draw(allocator, channel),
    };
}

pub fn verifyToRelations(
    allocator: std.mem.Allocator,
    channel: anytype,
    statement: *const statement_mod.RiscVStatement,
    interaction_pow: u64,
) !relation_challenges.Relations {
    const main_claim = statement.canonicalMainClaim();
    main_claim.mixInto(channel);
    statement.mixShardManifest(channel);
    const difficulty = transcript.Difficulty.default();
    if (!channel.verifyPowNonce(difficulty.bits, interaction_pow))
        return transcript.PrefixError.InvalidInteractionProofOfWork;
    channel.mixU64(interaction_pow);
    return relation_challenges.Relations.draw(allocator, channel);
}

pub fn mixInteractionClaim(
    channel: anytype,
    statement: *const statement_mod.RiscVStatement,
    claim: *const statement_mod.RiscVInteractionClaim,
) !void {
    const canonical = try claim.canonical(statement);
    const view = canonical.view();
    view.mixInto(channel);
}
