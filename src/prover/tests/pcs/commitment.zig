//! PCS commitment construction, decommitment, and streaming tests.

const std = @import("std");
const circle = @import("../../../core/circle.zig");
const m31 = @import("../../../core/fields/m31.zig");
const pcs_core = @import("../../../core/pcs/mod.zig");
const pcs_utils = @import("../../../core/pcs/utils.zig");
const vcs_verifier = @import("../../../core/vcs_lifted/verifier.zig");
const prover_circle = @import("../../poly/circle/mod.zig");
const pcs_prover = @import("../../pcs/mod.zig");

const M31 = m31.M31;
const CirclePointQM31 = circle.CirclePointQM31;
const PcsConfig = pcs_core.PcsConfig;
const TreeVec = pcs_core.TreeVec;
const ColumnEvaluation = pcs_prover.ColumnEvaluation;
const CommitmentTreeProver = pcs_prover.CommitmentTreeProver;
const CommitmentSchemeProver = pcs_prover.CommitmentSchemeProver;

test "prover pcs: commitment tree decommit verifies" {
    const Hasher = @import("../../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleHasher;
    const Verifier = vcs_verifier.MerkleVerifierLifted(Hasher);
    const alloc = std.testing.allocator;

    const col0 = [_]M31{
        M31.fromCanonical(1),
        M31.fromCanonical(2),
        M31.fromCanonical(3),
        M31.fromCanonical(4),
        M31.fromCanonical(5),
        M31.fromCanonical(6),
        M31.fromCanonical(7),
        M31.fromCanonical(8),
    };
    const col1 = [_]M31{
        M31.fromCanonical(9),
        M31.fromCanonical(10),
        M31.fromCanonical(11),
        M31.fromCanonical(12),
    };

    var tree = try CommitmentTreeProver(Hasher).init(
        alloc,
        &[_]ColumnEvaluation{
            .{ .log_size = 3, .values = col0[0..] },
            .{ .log_size = 2, .values = col1[0..] },
        },
    );
    defer tree.deinit(alloc);

    const queries = [_]usize{ 1, 3, 6 };
    var decommit = try tree.decommit(alloc, queries[0..]);
    defer decommit.deinit(alloc);

    const log_sizes = try tree.columnLogSizes(alloc);
    defer alloc.free(log_sizes);

    var verifier = try Verifier.init(alloc, tree.root(), log_sizes);
    defer verifier.deinit(alloc);

    try verifier.verify(
        alloc,
        queries[0..],
        decommit.queried_values,
        decommit.decommitment.decommitment,
    );
}

test "prover pcs: commitment scheme commit, roots and log sizes" {
    const Hasher = @import("../../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleHasher;
    const MerkleChannel = @import("../../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleChannel;
    const Channel = @import("../../../core/channel/blake2s.zig").Blake2sChannel;
    const CpuBackend = @import("../../../backends/cpu_scalar/mod.zig").CpuBackend;
    const Scheme = CommitmentSchemeProver(CpuBackend, Hasher, MerkleChannel);
    const alloc = std.testing.allocator;

    var scheme = try Scheme.init(alloc, PcsConfig.default());
    defer scheme.deinit(alloc);

    var channel = Channel{};
    const before = channel.digestBytes();

    const tree0_col = [_]M31{ M31.fromCanonical(1), M31.fromCanonical(2), M31.fromCanonical(3), M31.fromCanonical(4) };
    try scheme.commit(
        alloc,
        &[_]ColumnEvaluation{.{ .log_size = 2, .values = tree0_col[0..] }},
        &channel,
    );

    const tree1_col = [_]M31{
        M31.fromCanonical(5),
        M31.fromCanonical(6),
        M31.fromCanonical(7),
        M31.fromCanonical(8),
    };
    try scheme.commit(
        alloc,
        &[_]ColumnEvaluation{.{ .log_size = 2, .values = tree1_col[0..] }},
        &channel,
    );

    try std.testing.expect(!std.mem.eql(u8, before[0..], channel.digestBytes()[0..]));
    try std.testing.expectEqual(@as(usize, 2), scheme.trees.items.len);

    var roots = try scheme.roots(alloc);
    defer roots.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), roots.items.len);

    var sizes = try scheme.columnLogSizes(alloc);
    defer sizes.deinitDeep(alloc);
    const extended_log_size = @as(u32, 2) + scheme.config.fri_config.log_blowup_factor;
    const expected_sizes = [_]u32{extended_log_size};
    try std.testing.expectEqual(@as(usize, 2), sizes.items.len);
    try std.testing.expectEqualSlices(u32, expected_sizes[0..], sizes.items[0]);
    try std.testing.expectEqualSlices(u32, expected_sizes[0..], sizes.items[1]);
}

test "prover pcs: polynomials and trace expose committed columns" {
    const Hasher = @import("../../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleHasher;
    const MerkleChannel = @import("../../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleChannel;
    const Channel = @import("../../../core/channel/blake2s.zig").Blake2sChannel;
    const CpuBackend = @import("../../../backends/cpu_scalar/mod.zig").CpuBackend;
    const Scheme = CommitmentSchemeProver(CpuBackend, Hasher, MerkleChannel);
    const alloc = std.testing.allocator;

    var scheme = try Scheme.init(alloc, PcsConfig.default());
    defer scheme.deinit(alloc);

    var channel = Channel{};
    const tree0_col = [_]M31{
        M31.fromCanonical(1),
        M31.fromCanonical(2),
        M31.fromCanonical(3),
        M31.fromCanonical(4),
    };
    try scheme.commit(
        alloc,
        &[_]ColumnEvaluation{.{ .log_size = 2, .values = tree0_col[0..] }},
        &channel,
    );

    var polys = try scheme.polynomials(alloc);
    defer polys.deinitDeep(alloc);
    const expected_column = scheme.trees.items[0].columns[0];
    try std.testing.expectEqual(@as(usize, 1), polys.items.len);
    try std.testing.expectEqual(@as(usize, 1), polys.items[0].len);
    try std.testing.expectEqual(expected_column.log_size, polys.items[0][0].log_size);
    try std.testing.expectEqualSlices(M31, expected_column.values, polys.items[0][0].values);

    var trace = try scheme.trace(alloc);
    defer trace.polys.deinitDeep(alloc);
    try std.testing.expectEqual(@as(usize, 1), trace.polys.items.len);
    try std.testing.expectEqualSlices(M31, expected_column.values, trace.polys.items[0][0].values);
}

test "prover pcs: tree builder extends and commits" {
    const Hasher = @import("../../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleHasher;
    const MerkleChannel = @import("../../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleChannel;
    const Channel = @import("../../../core/channel/blake2s.zig").Blake2sChannel;
    const CpuBackend = @import("../../../backends/cpu_scalar/mod.zig").CpuBackend;
    const Scheme = CommitmentSchemeProver(CpuBackend, Hasher, MerkleChannel);
    const alloc = std.testing.allocator;

    var scheme = try Scheme.init(alloc, PcsConfig.default());
    defer scheme.deinit(alloc);

    var builder = scheme.treeBuilder(alloc);
    defer builder.deinit();

    const col0 = [_]M31{ M31.fromCanonical(1), M31.fromCanonical(2), M31.fromCanonical(3), M31.fromCanonical(4) };
    const col1 = [_]M31{ M31.fromCanonical(11), M31.fromCanonical(12), M31.fromCanonical(13), M31.fromCanonical(14) };

    const span0 = try builder.extendColumns(
        &[_]ColumnEvaluation{.{ .log_size = 2, .values = col0[0..] }},
    );
    try std.testing.expectEqual(@as(usize, 0), span0.tree_index);
    try std.testing.expectEqual(@as(usize, 0), span0.col_start);
    try std.testing.expectEqual(@as(usize, 1), span0.col_end);

    const span1 = try builder.extendColumns(
        &[_]ColumnEvaluation{.{ .log_size = 2, .values = col1[0..] }},
    );
    try std.testing.expectEqual(@as(usize, 1), span1.col_start);
    try std.testing.expectEqual(@as(usize, 2), span1.col_end);

    var channel = Channel{};
    try builder.commit(&channel);

    try std.testing.expectEqual(@as(usize, 1), scheme.trees.items.len);
    try std.testing.expectEqual(@as(usize, 2), scheme.trees.items[0].columns.len);
}

test "prover pcs: commit polys applies blowup and stores coefficients" {
    const Hasher = @import("../../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleHasher;
    const MerkleChannel = @import("../../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleChannel;
    const Channel = @import("../../../core/channel/blake2s.zig").Blake2sChannel;
    const CpuBackend = @import("../../../backends/cpu_scalar/mod.zig").CpuBackend;
    const Scheme = CommitmentSchemeProver(CpuBackend, Hasher, MerkleChannel);
    const alloc = std.testing.allocator;

    const config = PcsConfig{
        .pow_bits = 0,
        .fri_config = try @import("../../../core/fri.zig").FriConfig.init(0, 2, 3),
    };

    var scheme = try Scheme.init(alloc, config);
    defer scheme.deinit(alloc);
    scheme.setStorePolynomialsCoefficients();

    const coeffs = [_]M31{
        M31.fromCanonical(7),
        M31.zero(),
        M31.zero(),
        M31.zero(),
        M31.zero(),
        M31.zero(),
        M31.zero(),
        M31.zero(),
    };
    const poly = try prover_circle.CircleCoefficients.initBorrowed(coeffs[0..]);

    var channel = Channel{};
    try scheme.commitPolys(alloc, &[_]prover_circle.CircleCoefficients{poly}, &channel);

    try std.testing.expectEqual(@as(usize, 1), scheme.trees.items.len);
    try std.testing.expectEqual(@as(usize, 1), scheme.trees.items[0].columns.len);
    try std.testing.expectEqual(@as(u32, 5), scheme.trees.items[0].columns[0].log_size);
    try std.testing.expectEqual(@as(usize, 32), scheme.trees.items[0].columns[0].values.len);
    try std.testing.expect(scheme.trees.items[0].coefficients != null);
    try std.testing.expectEqual(@as(usize, 1), scheme.trees.items[0].coefficients.?.len);
}

test "prover pcs: commit polys reuses mixed log sizes through twiddle source" {
    const Hasher = @import("../../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleHasher;
    const MerkleChannel = @import("../../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleChannel;
    const Channel = @import("../../../core/channel/blake2s.zig").Blake2sChannel;
    const CpuBackend = @import("../../../backends/cpu_scalar/mod.zig").CpuBackend;
    const Scheme = CommitmentSchemeProver(CpuBackend, Hasher, MerkleChannel);
    const alloc = std.testing.allocator;

    const config = PcsConfig{
        .pow_bits = 0,
        .fri_config = try @import("../../../core/fri.zig").FriConfig.init(0, 1, 3),
    };

    var scheme = try Scheme.init(alloc, config);
    defer scheme.deinit(alloc);

    const coeffs_log2 = [_]M31{
        M31.fromCanonical(3),
        M31.zero(),
        M31.zero(),
        M31.zero(),
    };
    const coeffs_log3 = [_]M31{
        M31.fromCanonical(11),
        M31.zero(),
        M31.zero(),
        M31.zero(),
        M31.zero(),
        M31.zero(),
        M31.zero(),
        M31.zero(),
    };
    const poly0 = try prover_circle.CircleCoefficients.initBorrowed(coeffs_log2[0..]);
    const poly1 = try prover_circle.CircleCoefficients.initBorrowed(coeffs_log3[0..]);

    var channel = Channel{};
    try scheme.commitPolys(
        alloc,
        &[_]prover_circle.CircleCoefficients{ poly0, poly1 },
        &channel,
    );

    try std.testing.expectEqual(@as(usize, 1), scheme.trees.items.len);
    try std.testing.expectEqual(@as(usize, 2), scheme.trees.items[0].columns.len);
    try std.testing.expectEqual(@as(u32, 3), scheme.trees.items[0].columns[0].log_size);
    try std.testing.expectEqual(@as(u32, 4), scheme.trees.items[0].columns[1].log_size);
    try std.testing.expectEqual(@as(usize, 8), scheme.trees.items[0].columns[0].values.len);
    try std.testing.expectEqual(@as(usize, 16), scheme.trees.items[0].columns[1].values.len);
    for (scheme.trees.items[0].columns[0].values) |value| {
        try std.testing.expect(value.eql(M31.fromCanonical(3)));
    }
    for (scheme.trees.items[0].columns[1].values) |value| {
        try std.testing.expect(value.eql(M31.fromCanonical(11)));
    }

    const cold = scheme.twiddle_source.telemetry();
    try std.testing.expectEqual(@as(u64, 2), cold.tree_build_count);
    try std.testing.expectEqual(@as(usize, 2), cold.retained_tree_count);

    try scheme.commitPolys(
        alloc,
        &[_]prover_circle.CircleCoefficients{ poly0, poly1 },
        &channel,
    );
    const warm = scheme.twiddle_source.telemetry();
    try std.testing.expectEqual(cold.tree_build_count, warm.tree_build_count);
    try std.testing.expectEqual(cold.cache_hit_count + 2, warm.cache_hit_count);
    try std.testing.expectEqual(cold.retained_bytes, warm.retained_bytes);
}

test "prover pcs: borrowed twiddle tower initializer leaves tower ownership external" {
    const Hasher = @import("../../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleHasher;
    const MerkleChannel = @import("../../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleChannel;
    const CpuBackend = @import("../../../backends/cpu_scalar/mod.zig").CpuBackend;
    const M31TwiddleTower = @import("../../poly/twiddle_tower.zig").M31TwiddleTower;
    const TwiddleSource = @import("../../poly/twiddle_source.zig").TwiddleSource;
    const Scheme = CommitmentSchemeProver(CpuBackend, Hasher, MerkleChannel);
    const alloc = std.testing.allocator;

    var tower = try M31TwiddleTower.init(alloc, 8, std.math.maxInt(usize));
    defer tower.deinit(alloc);

    var scheme = Scheme.initWithTwiddleTower(PcsConfig.default(), &tower);
    defer scheme.deinit(alloc);

    _ = try scheme.twiddle_source.get(alloc, 6);
    const stats = scheme.twiddle_source.telemetry();
    try std.testing.expectEqual(TwiddleSource.Mode.borrowed_tower, stats.mode);
    try std.testing.expectEqual(@as(u64, 0), stats.tree_build_count);
    try std.testing.expectEqual(tower.retainedBytes(), stats.retained_bytes);
}

test "prover pcs: prove values deinitializes scheme before sample transfer" {
    const Hasher = @import("../../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleHasher;
    const MerkleChannel = @import("../../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleChannel;
    const Channel = @import("../../../core/channel/blake2s.zig").Blake2sChannel;
    const CpuBackend = @import("../../../backends/cpu_scalar/mod.zig").CpuBackend;
    const Scheme = CommitmentSchemeProver(CpuBackend, Hasher, MerkleChannel);
    const alloc = std.testing.allocator;

    var scheme = try Scheme.init(alloc, PcsConfig.default());
    _ = try scheme.twiddle_source.get(alloc, 6);
    var channel = Channel{};
    const column_values = [_]M31{
        M31.fromCanonical(1),
        M31.fromCanonical(2),
        M31.fromCanonical(3),
        M31.fromCanonical(4),
    };
    try scheme.commit(
        alloc,
        &[_]ColumnEvaluation{.{ .log_size = 2, .values = column_values[0..] }},
        &channel,
    );

    var sampled_points = TreeVec([][]CirclePointQM31).initOwned(
        try alloc.alloc([][]CirclePointQM31, 0),
    );
    defer sampled_points.deinitDeep(alloc);

    try std.testing.expectError(
        error.ShapeMismatch,
        scheme.proveValues(alloc, sampled_points, &channel),
    );
}

test "prover pcs: build query positions tree applies preprocessed mapping" {
    const Hasher = @import("../../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleHasher;
    const MerkleChannel = @import("../../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleChannel;
    const Channel = @import("../../../core/channel/blake2s.zig").Blake2sChannel;
    const CpuBackend = @import("../../../backends/cpu_scalar/mod.zig").CpuBackend;
    const Scheme = CommitmentSchemeProver(CpuBackend, Hasher, MerkleChannel);
    const alloc = std.testing.allocator;

    var scheme = try Scheme.init(alloc, PcsConfig.default());
    defer scheme.deinit(alloc);

    var channel = Channel{};

    const pp_col = [_]M31{ M31.one(), M31.one(), M31.one(), M31.one() };
    try scheme.commit(
        alloc,
        &[_]ColumnEvaluation{.{ .log_size = 2, .values = pp_col[0..] }},
        &channel,
    );

    const main_col = [_]M31{
        M31.fromCanonical(1),
        M31.fromCanonical(2),
        M31.fromCanonical(3),
        M31.fromCanonical(4),
        M31.fromCanonical(5),
        M31.fromCanonical(6),
        M31.fromCanonical(7),
        M31.fromCanonical(8),
    };
    try scheme.commit(
        alloc,
        &[_]ColumnEvaluation{.{ .log_size = 3, .values = main_col[0..] }},
        &channel,
    );

    const query_positions = [_]usize{ 0, 1, 5, 6 };
    const lifting_log_size = @as(u32, 3) + scheme.config.fri_config.log_blowup_factor;
    const pp_max_log_size = @as(u32, 2) + scheme.config.fri_config.log_blowup_factor;
    var tree_queries = try scheme.buildQueryPositionsTree(alloc, query_positions[0..], lifting_log_size);
    defer tree_queries.deinitDeep(alloc);

    const expected_pp = try pcs_utils.preparePreprocessedQueryPositions(
        alloc,
        query_positions[0..],
        lifting_log_size,
        pp_max_log_size,
    );
    defer alloc.free(expected_pp);

    try std.testing.expectEqual(@as(usize, 2), tree_queries.items.len);
    try std.testing.expectEqualSlices(usize, expected_pp, tree_queries.items[0]);
    try std.testing.expectEqualSlices(usize, query_positions[0..], tree_queries.items[1]);
}

test "prover pcs: decommit by tree positions verifies" {
    const Hasher = @import("../../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleHasher;
    const MerkleChannel = @import("../../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleChannel;
    const Channel = @import("../../../core/channel/blake2s.zig").Blake2sChannel;
    const CpuBackend = @import("../../../backends/cpu_scalar/mod.zig").CpuBackend;
    const Scheme = CommitmentSchemeProver(CpuBackend, Hasher, MerkleChannel);
    const Verifier = vcs_verifier.MerkleVerifierLifted(Hasher);
    const alloc = std.testing.allocator;

    var scheme = try Scheme.init(alloc, PcsConfig.default());
    defer scheme.deinit(alloc);

    var channel = Channel{};

    const tree0 = [_]M31{ M31.fromCanonical(1), M31.fromCanonical(2), M31.fromCanonical(3), M31.fromCanonical(4) };
    try scheme.commit(
        alloc,
        &[_]ColumnEvaluation{.{ .log_size = 2, .values = tree0[0..] }},
        &channel,
    );

    const tree1 = [_]M31{
        M31.fromCanonical(10),
        M31.fromCanonical(11),
        M31.fromCanonical(12),
        M31.fromCanonical(13),
        M31.fromCanonical(14),
        M31.fromCanonical(15),
        M31.fromCanonical(16),
        M31.fromCanonical(17),
    };
    try scheme.commit(
        alloc,
        &[_]ColumnEvaluation{.{ .log_size = 3, .values = tree1[0..] }},
        &channel,
    );

    const tree0_queries = try alloc.dupe(usize, &[_]usize{ 3, 0, 3, 1 });
    const tree1_queries = try alloc.dupe(usize, &[_]usize{ 6, 1, 6, 0 });
    var query_tree = TreeVec([]const usize).initOwned(
        try alloc.dupe([]const usize, &[_][]const usize{ tree0_queries, tree1_queries }),
    );
    defer query_tree.deinitDeep(alloc);

    var decommit = try scheme.decommitByTreePositions(alloc, query_tree);
    defer decommit.deinit(alloc);

    try std.testing.expectEqualSlices(M31, &[_]M31{
        scheme.trees.items[0].columns[0].values[3],
        scheme.trees.items[0].columns[0].values[0],
        scheme.trees.items[0].columns[0].values[3],
        scheme.trees.items[0].columns[0].values[1],
    }, decommit.queried_values.items[0][0]);
    try std.testing.expectEqualSlices(M31, &[_]M31{
        scheme.trees.items[1].columns[0].values[6],
        scheme.trees.items[1].columns[0].values[1],
        scheme.trees.items[1].columns[0].values[6],
        scheme.trees.items[1].columns[0].values[0],
    }, decommit.queried_values.items[1][0]);

    var sizes = try scheme.columnLogSizes(alloc);
    defer sizes.deinitDeep(alloc);

    var verifier0 = try Verifier.init(alloc, scheme.trees.items[0].root(), sizes.items[0]);
    defer verifier0.deinit(alloc);
    try verifier0.verify(
        alloc,
        tree0_queries,
        decommit.queried_values.items[0],
        decommit.decommitments.items[0],
    );

    var verifier1 = try Verifier.init(alloc, scheme.trees.items[1].root(), sizes.items[1]);
    defer verifier1.deinit(alloc);
    try verifier1.verify(
        alloc,
        tree1_queries,
        decommit.queried_values.items[1],
        decommit.decommitments.items[1],
    );
}

test "prover pcs: streaming commitment produces identical root to non-streaming" {
    const Hasher = @import("../../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleHasher;
    const MerkleChannel = @import("../../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleChannel;
    const Channel = @import("../../../core/channel/blake2s.zig").Blake2sChannel;
    const CpuBackend = @import("../../../backends/cpu_scalar/mod.zig").CpuBackend;
    const Scheme = CommitmentSchemeProver(CpuBackend, Hasher, MerkleChannel);
    const alloc = std.testing.allocator;

    // Create test columns of various sizes.
    const n_large: usize = 16;
    const n_small: usize = 4;
    const large_len: usize = 1 << 4;
    const small_len: usize = 1 << 2;

    // Build column values.
    const all_columns = try alloc.alloc(ColumnEvaluation, n_large + n_small);
    defer {
        for (all_columns) |col| {
            if (col.values.len > 0) alloc.free(col.values);
        }
        alloc.free(all_columns);
    }

    for (0..n_large) |i| {
        const values = try alloc.alloc(M31, large_len);
        for (values, 0..) |*v, j| {
            v.* = M31.fromU64(@as(u64, @intCast((i + 1) * 1009 + (j + 3) * 37)));
        }
        all_columns[i] = .{ .log_size = 4, .values = values };
    }
    for (0..n_small) |offset| {
        const i = n_large + offset;
        const values = try alloc.alloc(M31, small_len);
        for (values, 0..) |*v, j| {
            v.* = M31.fromU64(@as(u64, @intCast((i + 5) * 1223 + (j + 7) * 19)));
        }
        all_columns[i] = .{ .log_size = 2, .values = values };
    }

    // Non-streaming: commit all at once.
    var scheme_ref = try Scheme.init(alloc, PcsConfig.default());
    defer scheme_ref.deinit(alloc);
    var channel_ref = Channel{};
    try scheme_ref.commit(
        alloc,
        all_columns,
        &channel_ref,
    );

    // Streaming: commit in batches of 5.
    var scheme_stream = try Scheme.init(alloc, PcsConfig.default());
    defer scheme_stream.deinit(alloc);
    var channel_stream = Channel{};

    // Build owned copies for the streaming path.
    const stream_columns = try alloc.alloc(ColumnEvaluation, all_columns.len);
    for (all_columns, 0..) |col, i| {
        stream_columns[i] = .{
            .log_size = col.log_size,
            .values = try alloc.dupe(M31, col.values),
        };
    }

    try scheme_stream.commitOwnedStreaming(
        alloc,
        stream_columns,
        5,
        &channel_stream,
    );

    // Verify identical roots.
    var roots_ref = try scheme_ref.roots(alloc);
    defer roots_ref.deinit(alloc);
    var roots_stream = try scheme_stream.roots(alloc);
    defer roots_stream.deinit(alloc);

    try std.testing.expectEqual(roots_ref.items.len, roots_stream.items.len);
    for (roots_ref.items, roots_stream.items) |root_ref, root_stream| {
        try std.testing.expectEqualSlices(u8, root_ref[0..], root_stream[0..]);
    }

    // Verify identical channel state (the root mixing should match).
    try std.testing.expectEqualSlices(u8, channel_ref.digestBytes()[0..], channel_stream.digestBytes()[0..]);
}

test "prover pcs: streaming commitment with batch_size=1 matches non-streaming" {
    const Hasher = @import("../../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleHasher;
    const MerkleChannel = @import("../../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleChannel;
    const Channel = @import("../../../core/channel/blake2s.zig").Blake2sChannel;
    const CpuBackend = @import("../../../backends/cpu_scalar/mod.zig").CpuBackend;
    const Scheme = CommitmentSchemeProver(CpuBackend, Hasher, MerkleChannel);
    const alloc = std.testing.allocator;

    const col_len: usize = 1 << 3;
    const n_cols: usize = 4;

    const all_columns = try alloc.alloc(ColumnEvaluation, n_cols);
    defer {
        for (all_columns) |col| {
            if (col.values.len > 0) alloc.free(col.values);
        }
        alloc.free(all_columns);
    }

    for (0..n_cols) |i| {
        const values = try alloc.alloc(M31, col_len);
        for (values, 0..) |*v, j| {
            v.* = M31.fromU64(@as(u64, @intCast((i + 1) * 101 + (j + 1) * 7)));
        }
        all_columns[i] = .{ .log_size = 3, .values = values };
    }

    // Non-streaming.
    var scheme_ref = try Scheme.init(alloc, PcsConfig.default());
    defer scheme_ref.deinit(alloc);
    var channel_ref = Channel{};
    try scheme_ref.commit(alloc, all_columns, &channel_ref);

    // Streaming with batch_size=1.
    var scheme_stream = try Scheme.init(alloc, PcsConfig.default());
    defer scheme_stream.deinit(alloc);
    var channel_stream = Channel{};

    const stream_columns = try alloc.alloc(ColumnEvaluation, n_cols);
    for (all_columns, 0..) |col, i| {
        stream_columns[i] = .{
            .log_size = col.log_size,
            .values = try alloc.dupe(M31, col.values),
        };
    }

    try scheme_stream.commitOwnedStreaming(alloc, stream_columns, 1, &channel_stream);

    var roots_ref = try scheme_ref.roots(alloc);
    defer roots_ref.deinit(alloc);
    var roots_stream = try scheme_stream.roots(alloc);
    defer roots_stream.deinit(alloc);

    try std.testing.expectEqual(roots_ref.items.len, roots_stream.items.len);
    for (roots_ref.items, roots_stream.items) |root_ref, root_stream| {
        try std.testing.expectEqualSlices(u8, root_ref[0..], root_stream[0..]);
    }
    try std.testing.expectEqualSlices(u8, channel_ref.digestBytes()[0..], channel_stream.digestBytes()[0..]);
}

test "prover pcs: streaming tree builder API matches non-streaming" {
    const Hasher = @import("../../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleHasher;
    const MerkleChannel = @import("../../../core/vcs_lifted/blake2_merkle.zig").Blake2sMerkleChannel;
    const Channel = @import("../../../core/channel/blake2s.zig").Blake2sChannel;
    const CpuBackend = @import("../../../backends/cpu_scalar/mod.zig").CpuBackend;
    const Scheme = CommitmentSchemeProver(CpuBackend, Hasher, MerkleChannel);
    const alloc = std.testing.allocator;

    const col_len: usize = 1 << 3;
    const n_cols: usize = 6;

    const all_columns = try alloc.alloc(ColumnEvaluation, n_cols);
    defer {
        for (all_columns) |col| {
            if (col.values.len > 0) alloc.free(col.values);
        }
        alloc.free(all_columns);
    }

    for (0..n_cols) |i| {
        const values = try alloc.alloc(M31, col_len);
        for (values, 0..) |*v, j| {
            v.* = M31.fromU64(@as(u64, @intCast((i + 3) * 503 + (j + 2) * 41)));
        }
        all_columns[i] = .{ .log_size = 3, .values = values };
    }

    // Non-streaming.
    var scheme_ref = try Scheme.init(alloc, PcsConfig.default());
    defer scheme_ref.deinit(alloc);
    var channel_ref = Channel{};
    try scheme_ref.commit(alloc, all_columns, &channel_ref);

    // Streaming tree builder API: add two batches of 3.
    var scheme_stream = try Scheme.init(alloc, PcsConfig.default());
    defer scheme_stream.deinit(alloc);
    var channel_stream = Channel{};

    var builder = scheme_stream.streamingTreeBuilder(alloc, 3);
    defer builder.deinit();

    // Batch 1: first 3 columns.
    const batch1 = try alloc.alloc(ColumnEvaluation, 3);
    for (0..3) |i| {
        batch1[i] = .{
            .log_size = all_columns[i].log_size,
            .values = try alloc.dupe(M31, all_columns[i].values),
        };
    }
    try builder.addColumnsOwned(batch1, null);

    // Batch 2: remaining 3 columns.
    const batch2 = try alloc.alloc(ColumnEvaluation, 3);
    for (0..3) |i| {
        batch2[i] = .{
            .log_size = all_columns[3 + i].log_size,
            .values = try alloc.dupe(M31, all_columns[3 + i].values),
        };
    }
    try builder.addColumnsOwned(batch2, null);

    try builder.commit(&channel_stream);

    var roots_ref = try scheme_ref.roots(alloc);
    defer roots_ref.deinit(alloc);
    var roots_stream = try scheme_stream.roots(alloc);
    defer roots_stream.deinit(alloc);

    try std.testing.expectEqual(roots_ref.items.len, roots_stream.items.len);
    for (roots_ref.items, roots_stream.items) |root_ref, root_stream| {
        try std.testing.expectEqualSlices(u8, root_ref[0..], root_stream[0..]);
    }
    try std.testing.expectEqualSlices(u8, channel_ref.digestBytes()[0..], channel_stream.digestBytes()[0..]);
}
