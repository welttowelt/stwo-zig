//! Canonical Stark-V claim-phase transcript foundation for RISC-V proofs.

const std = @import("std");

pub const claims = @import("claims.zig");
pub const protocol = @import("protocol.zig");

pub const Component = claims.Component;
pub const COMPONENT_COUNT = claims.COMPONENT_COUNT;
pub const MainClaim = claims.MainClaim;
pub const InteractionClaim = claims.InteractionClaim;
pub const INTERACTION_POW_BITS = protocol.INTERACTION_POW_BITS;
pub const ProverRelations = protocol.ProverRelations;
pub const PrefixError = protocol.PrefixError;
pub const mixCommittedPrefix = protocol.mixCommittedPrefix;
pub const proveToRelations = protocol.proveToRelations;
pub const verifyToRelations = protocol.verifyToRelations;
pub const finishWithInteractionRoot = protocol.finishWithInteractionRoot;
pub const finishWithoutInteractionRoot = protocol.finishWithoutInteractionRoot;

const Blake2sChannel = @import("../../../../core/channel/blake2s.zig").Blake2sChannel;
const Blake2sMerkleChannel = @import("../../../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleChannel;
const QM31 = @import("../../../../core/fields/qm31.zig").QM31;
const PublicData = @import("../public_data.zig").PublicData;

fn fixturePublicData() PublicData {
    return .{
        .initial_pc = 0x1000,
        .final_pc = 0x1040,
        .clock = 17,
        .initial_regs = [_]u32{0} ** 32,
        .final_regs = [_]u32{0} ** 32,
        .reg_last_clock = [_]u32{0} ** 32,
        .program_root = 101,
        .initial_rw_root = 202,
        .final_rw_root = 303,
        .io_entries = .{
            .input_start = 0x0018_0000,
            .input_len = 0,
            .input_words = &.{},
            .output_len = 0,
            .output_len_addr = 0x0010_0004,
            .output_data_addr = 0x0010_0008,
            .output_words = &.{},
        },
    };
}

fn fixtureMainClaim() MainClaim {
    var log_sizes: [COMPONENT_COUNT]u32 = undefined;
    for (&log_sizes, 0..) |*value, index| value.* = @intCast(4 + index % 5);
    return MainClaim.init(log_sizes);
}

fn fixtureInteractionClaim() InteractionClaim {
    var sums: [COMPONENT_COUNT]QM31 = undefined;
    for (&sums, 0..) |*value, index| {
        value.* = QM31.fromU32Unchecked(@intCast(31 + index), 0, 0, 0);
    }
    return InteractionClaim.init(sums, &.{ 4, 5, 6, 7 });
}

test "claim phase: prover and verifier replay are byte symmetric" {
    const allocator = std.testing.allocator;
    const data = fixturePublicData();
    const main_claim = fixtureMainClaim();
    const preprocessed_root = [_]u8{0x11} ** 32;
    const main_root = [_]u8{0x22} ** 32;
    const interaction_root = [_]u8{0x33} ** 32;
    var prover_channel = Blake2sChannel{};
    const prover_result = try proveToRelations(
        Blake2sMerkleChannel,
        allocator,
        &prover_channel,
        &data,
        preprocessed_root,
        main_root,
        &main_claim,
    );
    const interaction_claim = fixtureInteractionClaim();
    finishWithInteractionRoot(
        Blake2sMerkleChannel,
        &prover_channel,
        &interaction_claim,
        interaction_root,
    );

    var verifier_channel = Blake2sChannel{};
    const verifier_relations = try verifyToRelations(
        Blake2sMerkleChannel,
        allocator,
        &verifier_channel,
        &data,
        preprocessed_root,
        main_root,
        &main_claim,
        prover_result.interaction_pow,
    );
    finishWithInteractionRoot(
        Blake2sMerkleChannel,
        &verifier_channel,
        &interaction_claim,
        interaction_root,
    );

    try std.testing.expect(prover_result.relations.registers_state.z.eql(
        verifier_relations.registers_state.z,
    ));
    try std.testing.expectEqual(prover_channel.digestBytes(), verifier_channel.digestBytes());
    try std.testing.expectEqual(prover_channel.n_draws, verifier_channel.n_draws);
}

test "claim phase: invalid interaction proof of work fails before relation draws" {
    const data = fixturePublicData();
    const main_claim = fixtureMainClaim();
    const preprocessed_root = [_]u8{0x11} ** 32;
    const main_root = [_]u8{0x22} ** 32;
    var prover_channel = Blake2sChannel{};
    mixCommittedPrefix(
        Blake2sMerkleChannel,
        &prover_channel,
        &data,
        preprocessed_root,
        main_root,
        &main_claim,
    );
    const valid_nonce = prover_channel.grind(INTERACTION_POW_BITS);
    var invalid_nonce = valid_nonce +% 1;
    while (prover_channel.verifyPowNonce(INTERACTION_POW_BITS, invalid_nonce)) invalid_nonce +%= 1;

    var verifier_channel = Blake2sChannel{};
    try std.testing.expectError(
        PrefixError.InvalidInteractionProofOfWork,
        verifyToRelations(
            Blake2sMerkleChannel,
            std.testing.allocator,
            &verifier_channel,
            &data,
            preprocessed_root,
            main_root,
            &main_claim,
            invalid_nonce,
        ),
    );
    try std.testing.expectEqual(@as(u32, 0), verifier_channel.n_draws);
}

test "claim phase: deterministic pinned transcript checkpoints" {
    // Independently reproduced with Stark-V d478f783 and its pinned Stwo
    // submodule 52a5d60d. These checkpoints bind mix-call boundaries, not only
    // a flattened value stream. The 1-bit grind retains the upstream debug
    // reference vector; production helpers always use INTERACTION_POW_BITS.
    const data = fixturePublicData();
    const main_claim = fixtureMainClaim();
    const interaction_claim = fixtureInteractionClaim();
    var channel = Blake2sChannel{};

    data.mixInto(&channel);
    try expectDigest(channel.digestBytes(), .{
        243, 94, 114, 83,  220, 199, 43, 226, 66,  39,  152, 20, 239, 247, 175, 39,
        12,  54, 75,  142, 118, 103, 93, 142, 216, 187, 46,  57, 208, 248, 9,   71,
    });

    Blake2sMerkleChannel.mixRoot(&channel, [_]u8{0x11} ** 32);
    try expectDigest(channel.digestBytes(), .{
        92, 49, 1,  163, 41, 55,  72,  115, 200, 9,  204, 91, 67, 215, 172, 130,
        63, 16, 45, 101, 49, 178, 146, 31,  136, 92, 189, 88, 80, 216, 150, 121,
    });

    Blake2sMerkleChannel.mixRoot(&channel, [_]u8{0x22} ** 32);
    main_claim.mixInto(&channel);
    try expectDigest(channel.digestBytes(), .{
        137, 69,  61,  44,  39, 159, 75,  59,  233, 220, 0,   19,  73,  11, 99,  227,
        246, 218, 139, 174, 37, 126, 158, 202, 92,  183, 122, 142, 118, 69, 172, 183,
    });

    const nonce = channel.grind(1);
    try std.testing.expectEqual(@as(u64, 1), nonce);
    channel.mixU64(nonce);
    const relations = try @import("../relation_challenges.zig").Relations.draw(
        std.testing.allocator,
        &channel,
    );
    try expectLimbs(relations.registers_state.z, .{
        785836679, 449169374, 69398469, 247787857,
    });
    try expectLimbs(relations.range_check_m31.alpha, .{
        519161478, 1731743397, 1523336811, 607284992,
    });
    try std.testing.expectEqual(@as(u32, 12), channel.n_draws);
    try expectDigest(channel.digestBytes(), .{
        206, 246, 152, 149, 32, 235, 37,  145, 27, 223, 93, 98, 14, 149, 192, 249,
        170, 138, 134, 94,  72, 10,  167, 184, 12, 26,  89, 93, 42, 230, 146, 59,
    });

    finishWithInteractionRoot(
        Blake2sMerkleChannel,
        &channel,
        &interaction_claim,
        [_]u8{0x33} ** 32,
    );
    try expectDigest(channel.digestBytes(), .{
        6,   139, 114, 95,  103, 97,  239, 120, 229, 228, 56, 26,  70,  172, 27, 72,
        198, 42,  235, 157, 152, 192, 193, 95,  191, 175, 48, 206, 172, 231, 28, 80,
    });
}

fn expectDigest(actual: [32]u8, expected: [32]u8) !void {
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

fn expectLimbs(actual: QM31, expected: [4]u32) !void {
    for (actual.toM31Array(), expected) |limb, expected_limb| {
        try std.testing.expectEqual(expected_limb, limb.toU32());
    }
}
