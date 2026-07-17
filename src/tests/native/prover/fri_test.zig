//! Native CPU FRI commit/decommit integration tests.

const std = @import("std");
const fri = @import("../../../prover/fri.zig");
const circle = @import("../../../core/circle.zig");
const core_fri = @import("../../../core/fri.zig");
const m31 = @import("../../../core/fields/m31.zig");
const qm31 = @import("../../../core/fields/qm31.zig");
const circle_domain = @import("../../../core/poly/circle/domain.zig");
const secure_column = @import("../../../prover/secure_column.zig");

const M31 = m31.M31;
const QM31 = qm31.QM31;
const FriProverError = fri.FriProverError;
const FriProver = fri.FriProver;

test "prover fri: commit and decommit roundtrip with verifier" {
    const CpuBackend = @import("../../../backends/cpu_scalar/mod.zig").CpuBackend;
    const Hasher = @import("../../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleHasher;
    const MerkleChannel = @import("../../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleChannel;
    const Channel = @import("../../../core/channel/blake2s.zig").Blake2sChannel;
    const Prover = FriProver(CpuBackend, Hasher, MerkleChannel);
    const Verifier = core_fri.FriVerifier(Hasher, MerkleChannel);
    const alloc = std.testing.allocator;

    const config = try core_fri.FriConfig.init(0, 1, 4);
    const column_log_size: u32 = 3;
    const domain = @import("../../../core/poly/circle/canonic.zig").CanonicCoset
        .new(column_log_size)
        .circleDomain();

    const constant_value = QM31.fromU32Unchecked(7, 0, 0, 0);
    const values = try alloc.alloc(QM31, domain.size());
    defer alloc.free(values);
    @memset(values, constant_value);

    const column = try secure_column.SecureColumnByCoords.fromSecureSlice(alloc, values);

    var prover_channel = Channel{};
    var prover = try Prover.commit(
        alloc,
        &prover_channel,
        config,
        domain,
        column,
    );
    var decommit_result = try prover.decommit(alloc, &prover_channel);
    defer decommit_result.deinit(alloc);

    var verifier_channel = Channel{};
    const bound = core_fri.CirclePolyDegreeBound.init(column_log_size - config.log_blowup_factor);
    var verifier = try Verifier.commit(
        alloc,
        &verifier_channel,
        config,
        decommit_result.fri_proof.proof,
        bound,
    );
    defer verifier.deinit(alloc);

    const query_positions = try verifier.sampleQueryPositions(alloc, &verifier_channel);
    defer alloc.free(query_positions);
    try std.testing.expectEqualSlices(usize, decommit_result.query_positions, query_positions);

    const first_layer_answers = try alloc.alloc(QM31, query_positions.len);
    defer alloc.free(first_layer_answers);
    @memset(first_layer_answers, constant_value);
    try verifier.decommit(alloc, first_layer_answers);
}

test "prover fri: commit rejects non-canonic domain" {
    const CpuBackend = @import("../../../backends/cpu_scalar/mod.zig").CpuBackend;
    const Hasher = @import("../../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleHasher;
    const MerkleChannel = @import("../../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleChannel;
    const Channel = @import("../../../core/channel/blake2s.zig").Blake2sChannel;
    const Prover = FriProver(CpuBackend, Hasher, MerkleChannel);
    const alloc = std.testing.allocator;

    const invalid_domain = circle_domain.CircleDomain.new(
        circle.Coset.new(circle.CirclePointIndex.generator(), 3),
    );
    try std.testing.expect(!invalid_domain.isCanonic());

    const values = try alloc.alloc(QM31, invalid_domain.size());
    defer alloc.free(values);
    @memset(values, QM31.one());

    const column = try secure_column.SecureColumnByCoords.fromSecureSlice(alloc, values);
    var channel = Channel{};
    try std.testing.expectError(
        FriProverError.NotCanonicDomain,
        Prover.commit(
            alloc,
            &channel,
            try core_fri.FriConfig.init(0, 1, 3),
            invalid_domain,
            column,
        ),
    );
}

test "prover fri: commit rejects high-degree last layer" {
    const CpuBackend = @import("../../../backends/cpu_scalar/mod.zig").CpuBackend;
    const Hasher = @import("../../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleHasher;
    const MerkleChannel = @import("../../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleChannel;
    const Channel = @import("../../../core/channel/blake2s.zig").Blake2sChannel;
    const Prover = FriProver(CpuBackend, Hasher, MerkleChannel);
    const alloc = std.testing.allocator;

    const config = try core_fri.FriConfig.init(0, 1, 3);
    const domain = @import("../../../core/poly/circle/canonic.zig").CanonicCoset
        .new(3)
        .circleDomain();

    const values = try alloc.alloc(QM31, domain.size());
    defer alloc.free(values);
    for (values, 0..) |*v, i| {
        v.* = QM31.fromBase(M31.fromCanonical(@intCast(i + 1)));
    }

    const column = try secure_column.SecureColumnByCoords.fromSecureSlice(alloc, values);
    var channel = Channel{};
    try std.testing.expectError(
        FriProverError.InvalidLastLayerDegree,
        Prover.commit(alloc, &channel, config, domain, column),
    );
}
