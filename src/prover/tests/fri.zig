const std = @import("std");
const fri = @import("../fri.zig");
const circle = @import("../../core/circle.zig");
const core_fri = @import("../../core/fri.zig");
const m31 = @import("../../core/fields/m31.zig");
const qm31 = @import("../../core/fields/qm31.zig");
const circle_domain = @import("../../core/poly/circle/domain.zig");
const secure_column = @import("../secure_column.zig");
const vcs_lifted_prover = @import("../vcs_lifted/prover.zig");
const vcs_lifted_verifier = @import("../../core/vcs_lifted/verifier.zig");

const M31 = m31.M31;
const QM31 = qm31.QM31;
const FriDecommitError = fri.FriDecommitError;
const FriProverError = fri.FriProverError;
const FriProver = fri.FriProver;
const computeDecommitmentPositionsAndWitnessEvals = fri.computeDecommitmentPositionsAndWitnessEvals;
const decommitLayer = fri.decommitLayer;
const decommitLayerExtended = fri.decommitLayerExtended;

test "prover fri: decommitment positions and witness evals" {
    const alloc = std.testing.allocator;

    const column = [_]QM31{
        QM31.fromBase(.fromCanonical(1)),
        QM31.fromBase(.fromCanonical(2)),
        QM31.fromBase(.fromCanonical(3)),
        QM31.fromBase(.fromCanonical(4)),
        QM31.fromBase(.fromCanonical(5)),
        QM31.fromBase(.fromCanonical(6)),
        QM31.fromBase(.fromCanonical(7)),
        QM31.fromBase(.fromCanonical(8)),
    };
    const queries = [_]usize{ 1, 3, 6 };

    var result = try computeDecommitmentPositionsAndWitnessEvals(
        alloc,
        column[0..],
        queries[0..],
        1,
    );
    defer result.deinit(alloc);

    try std.testing.expectEqualSlices(usize, &[_]usize{ 0, 1, 2, 3, 6, 7 }, result.decommitment_positions);
    try std.testing.expectEqual(@as(usize, 3), result.witness_evals.len);
    try std.testing.expect(result.witness_evals[0].eql(column[0]));
    try std.testing.expect(result.witness_evals[1].eql(column[2]));
    try std.testing.expect(result.witness_evals[2].eql(column[7]));

    try std.testing.expectEqual(@as(usize, 6), result.value_map.len);
    for (result.value_map, 0..) |entry, i| {
        try std.testing.expectEqual(result.decommitment_positions[i], entry.position);
        try std.testing.expect(entry.value.eql(column[entry.position]));
    }
}

test "prover fri: query out of range fails" {
    const column = [_]QM31{
        QM31.fromBase(.fromCanonical(1)),
        QM31.fromBase(.fromCanonical(2)),
        QM31.fromBase(.fromCanonical(3)),
        QM31.fromBase(.fromCanonical(4)),
    };
    const queries = [_]usize{7};
    try std.testing.expectError(
        FriDecommitError.QueryOutOfRange,
        computeDecommitmentPositionsAndWitnessEvals(
            std.testing.allocator,
            column[0..],
            queries[0..],
            0,
        ),
    );
}

test "prover fri: fold step too large fails" {
    const column = [_]QM31{QM31.fromBase(.fromCanonical(1))};
    const queries = [_]usize{0};
    try std.testing.expectError(
        FriDecommitError.FoldStepTooLarge,
        computeDecommitmentPositionsAndWitnessEvals(
            std.testing.allocator,
            column[0..],
            queries[0..],
            @bitSizeOf(usize),
        ),
    );
}

test "prover fri: layer decommit extended contains proof and aux values" {
    const Hasher = @import("../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleHasher;
    const LiftedProver = vcs_lifted_prover.MerkleProverLifted(Hasher);
    const alloc = std.testing.allocator;

    const values = [_]QM31{
        QM31.fromU32Unchecked(1, 2, 3, 4),
        QM31.fromU32Unchecked(5, 6, 7, 8),
        QM31.fromU32Unchecked(9, 10, 11, 12),
        QM31.fromU32Unchecked(13, 14, 15, 16),
    };
    var column = try secure_column.SecureColumnByCoords.fromSecureSlice(alloc, values[0..]);
    defer column.deinit(alloc);

    const coord_columns = [_][]const M31{
        column.columns[0],
        column.columns[1],
        column.columns[2],
        column.columns[3],
    };
    var merkle = try LiftedProver.commit(alloc, coord_columns[0..]);
    defer merkle.deinit(alloc);

    const query_positions = [_]usize{1};
    var extended = try decommitLayerExtended(
        Hasher,
        alloc,
        merkle,
        column,
        query_positions[0..],
        1,
    );
    defer extended.deinit(alloc);

    try std.testing.expect(std.mem.eql(
        u8,
        std.mem.asBytes(&extended.proof.commitment),
        std.mem.asBytes(&merkle.root()),
    ));
    try std.testing.expectEqual(@as(usize, 1), extended.aux.all_values.len);
    try std.testing.expectEqual(@as(usize, 2), extended.aux.all_values[0].len);
    try std.testing.expectEqual(@as(usize, 0), extended.aux.all_values[0][0].index);
    try std.testing.expect(extended.aux.all_values[0][0].value.eql(values[0]));
    try std.testing.expectEqual(@as(usize, 1), extended.aux.all_values[0][1].index);
    try std.testing.expect(extended.aux.all_values[0][1].value.eql(values[1]));
}

test "prover fri: layer decommit extended query out of range fails" {
    const Hasher = @import("../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleHasher;
    const LiftedProver = vcs_lifted_prover.MerkleProverLifted(Hasher);
    const alloc = std.testing.allocator;

    const values = [_]QM31{
        QM31.fromU32Unchecked(1, 2, 3, 4),
        QM31.fromU32Unchecked(5, 6, 7, 8),
        QM31.fromU32Unchecked(9, 10, 11, 12),
        QM31.fromU32Unchecked(13, 14, 15, 16),
    };
    var column = try secure_column.SecureColumnByCoords.fromSecureSlice(alloc, values[0..]);
    defer column.deinit(alloc);

    const coord_columns = [_][]const M31{
        column.columns[0],
        column.columns[1],
        column.columns[2],
        column.columns[3],
    };
    var merkle = try LiftedProver.commit(alloc, coord_columns[0..]);
    defer merkle.deinit(alloc);

    const query_positions = [_]usize{7};
    try std.testing.expectError(
        FriDecommitError.QueryOutOfRange,
        decommitLayerExtended(
            Hasher,
            alloc,
            merkle,
            column,
            query_positions[0..],
            1,
        ),
    );
}

test "prover fri: layer decommit verifies with lifted merkle verifier" {
    const Hasher = @import("../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleHasher;
    const LiftedProver = vcs_lifted_prover.MerkleProverLifted(Hasher);
    const LiftedVerifier = vcs_lifted_verifier.MerkleVerifierLifted(Hasher);
    const alloc = std.testing.allocator;

    const values = [_]QM31{
        QM31.fromU32Unchecked(1, 2, 3, 4),
        QM31.fromU32Unchecked(5, 6, 7, 8),
        QM31.fromU32Unchecked(9, 10, 11, 12),
        QM31.fromU32Unchecked(13, 14, 15, 16),
        QM31.fromU32Unchecked(17, 18, 19, 20),
        QM31.fromU32Unchecked(21, 22, 23, 24),
        QM31.fromU32Unchecked(25, 26, 27, 28),
        QM31.fromU32Unchecked(29, 30, 31, 32),
    };
    var column = try secure_column.SecureColumnByCoords.fromSecureSlice(alloc, values[0..]);
    defer column.deinit(alloc);

    const coord_columns = [_][]const M31{
        column.columns[0],
        column.columns[1],
        column.columns[2],
        column.columns[3],
    };
    var merkle = try LiftedProver.commit(alloc, coord_columns[0..]);
    defer merkle.deinit(alloc);

    const query_positions = [_]usize{ 1, 3, 6 };
    var decommit = try decommitLayer(
        Hasher,
        alloc,
        merkle,
        column,
        query_positions[0..],
        1,
    );
    defer decommit.deinit(alloc);

    const queried_values = try alloc.alloc([]const M31, qm31.SECURE_EXTENSION_DEGREE);
    defer alloc.free(queried_values);
    const queried_values_owned = try alloc.alloc([]M31, qm31.SECURE_EXTENSION_DEGREE);
    defer {
        for (queried_values_owned) |col_vals| alloc.free(col_vals);
        alloc.free(queried_values_owned);
    }

    for (0..qm31.SECURE_EXTENSION_DEGREE) |coord| {
        queried_values_owned[coord] = try alloc.alloc(M31, decommit.value_map.len);
        for (decommit.value_map, 0..) |entry, i| {
            const coords = entry.value.toM31Array();
            queried_values_owned[coord][i] = coords[coord];
        }
        queried_values[coord] = queried_values_owned[coord];
    }

    const log_size = @as(u32, @intCast(std.math.log2_int(usize, values.len)));
    const repeated_sizes = [_]u32{ log_size, log_size, log_size, log_size };
    var verifier = try LiftedVerifier.init(alloc, merkle.root(), repeated_sizes[0..]);
    defer verifier.deinit(alloc);
    try verifier.verify(
        alloc,
        decommit.decommitment_positions,
        queried_values,
        decommit.proof.decommitment,
    );
}

test "prover fri: layer decommit corrupted witness fails" {
    const Hasher = @import("../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleHasher;
    const LiftedProver = vcs_lifted_prover.MerkleProverLifted(Hasher);
    const LiftedVerifier = vcs_lifted_verifier.MerkleVerifierLifted(Hasher);
    const alloc = std.testing.allocator;

    const values = [_]QM31{
        QM31.fromU32Unchecked(1, 2, 3, 4),
        QM31.fromU32Unchecked(5, 6, 7, 8),
        QM31.fromU32Unchecked(9, 10, 11, 12),
        QM31.fromU32Unchecked(13, 14, 15, 16),
    };
    var column = try secure_column.SecureColumnByCoords.fromSecureSlice(alloc, values[0..]);
    defer column.deinit(alloc);

    const coord_columns = [_][]const M31{
        column.columns[0],
        column.columns[1],
        column.columns[2],
        column.columns[3],
    };
    var merkle = try LiftedProver.commit(alloc, coord_columns[0..]);
    defer merkle.deinit(alloc);

    const query_positions = [_]usize{1};
    var decommit = try decommitLayer(
        Hasher,
        alloc,
        merkle,
        column,
        query_positions[0..],
        1,
    );
    defer decommit.deinit(alloc);

    decommit.proof.decommitment.hash_witness[0][0] ^= 1;

    const queried_values = try alloc.alloc([]const M31, qm31.SECURE_EXTENSION_DEGREE);
    defer alloc.free(queried_values);
    const queried_values_owned = try alloc.alloc([]M31, qm31.SECURE_EXTENSION_DEGREE);
    defer {
        for (queried_values_owned) |col_vals| alloc.free(col_vals);
        alloc.free(queried_values_owned);
    }

    for (0..qm31.SECURE_EXTENSION_DEGREE) |coord| {
        queried_values_owned[coord] = try alloc.alloc(M31, decommit.value_map.len);
        for (decommit.value_map, 0..) |entry, i| {
            const coords = entry.value.toM31Array();
            queried_values_owned[coord][i] = coords[coord];
        }
        queried_values[coord] = queried_values_owned[coord];
    }

    const log_size = @as(u32, @intCast(std.math.log2_int(usize, values.len)));
    const repeated_sizes = [_]u32{ log_size, log_size, log_size, log_size };
    var verifier = try LiftedVerifier.init(alloc, merkle.root(), repeated_sizes[0..]);
    defer verifier.deinit(alloc);

    try std.testing.expectError(
        vcs_lifted_verifier.MerkleVerificationError.RootMismatch,
        verifier.verify(
            alloc,
            decommit.decommitment_positions,
            queried_values,
            decommit.proof.decommitment,
        ),
    );
}

test "prover fri: commit and decommit roundtrip with verifier" {
    const CpuBackend = @import("../../backends/cpu_scalar/mod.zig").CpuBackend;
    const Hasher = @import("../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleHasher;
    const MerkleChannel = @import("../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleChannel;
    const Channel = @import("../../core/channel/blake2s.zig").Blake2sChannel;
    const Prover = FriProver(CpuBackend, Hasher, MerkleChannel);
    const Verifier = core_fri.FriVerifier(Hasher, MerkleChannel);
    const alloc = std.testing.allocator;

    const config = try core_fri.FriConfig.init(0, 1, 4);
    const column_log_size: u32 = 3;
    const domain = @import("../../core/poly/circle/canonic.zig").CanonicCoset
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
    const CpuBackend = @import("../../backends/cpu_scalar/mod.zig").CpuBackend;
    const Hasher = @import("../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleHasher;
    const MerkleChannel = @import("../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleChannel;
    const Channel = @import("../../core/channel/blake2s.zig").Blake2sChannel;
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
    const CpuBackend = @import("../../backends/cpu_scalar/mod.zig").CpuBackend;
    const Hasher = @import("../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleHasher;
    const MerkleChannel = @import("../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleChannel;
    const Channel = @import("../../core/channel/blake2s.zig").Blake2sChannel;
    const Prover = FriProver(CpuBackend, Hasher, MerkleChannel);
    const alloc = std.testing.allocator;

    const config = try core_fri.FriConfig.init(0, 1, 3);
    const domain = @import("../../core/poly/circle/canonic.zig").CanonicCoset
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
