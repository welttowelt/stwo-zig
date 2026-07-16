const std = @import("std");
const circle = @import("circle.zig");
const fft = @import("fft.zig");
const fields = @import("fields/mod.zig");
const m31 = @import("fields/m31.zig");
const qm31 = @import("fields/qm31.zig");
const line = @import("poly/line.zig");
const canonic = @import("poly/circle/canonic.zig");
const circle_domain = @import("poly/circle/domain.zig");
const queries_mod = @import("queries.zig");
const core_utils = @import("utils.zig");
const vcs_verifier = @import("vcs_lifted/verifier.zig");

const M31 = m31.M31;
const QM31 = qm31.QM31;

const config_mod = @import("fri/config.zig");
const folding = @import("fri/folding.zig");

pub const FriConfig = config_mod.FriConfig;
pub const FOLD_STEP = config_mod.FOLD_STEP;
pub const CIRCLE_TO_LINE_FOLD_STEP = config_mod.CIRCLE_TO_LINE_FOLD_STEP;
pub const LOG_PACKED_LEAF_SIZE = config_mod.LOG_PACKED_LEAF_SIZE;
pub const FriVerificationError = config_mod.FriVerificationError;
pub const CirclePolyDegreeBound = config_mod.CirclePolyDegreeBound;
pub const LinePolyDegreeBound = config_mod.LinePolyDegreeBound;

pub const SparseEvaluation = folding.SparseEvaluation;
pub const ComputeDecommitmentResult = folding.ComputeDecommitmentResult;
pub fn FriVerifier(comptime H: type, comptime MC: type) type {
    return struct {
        config: FriConfig,
        first_layer: FriFirstLayerVerifier(H),
        inner_layers: []FriInnerLayerVerifier(H),
        last_layer_domain: line.LineDomain,
        last_layer_poly: line.LinePoly,
        queries: ?queries_mod.Queries = null,

        const Self = @This();

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.first_layer.deinit(allocator);
            for (self.inner_layers) |*layer| layer.deinit(allocator);
            allocator.free(self.inner_layers);
            self.last_layer_poly.deinit(allocator);
            if (self.queries) |*queries| queries.deinit(allocator);
            self.* = undefined;
        }

        pub fn commit(
            allocator: std.mem.Allocator,
            channel: anytype,
            config: FriConfig,
            proof_in: FriProof(H),
            column_bound: CirclePolyDegreeBound,
        ) (std.mem.Allocator.Error || FriVerificationError)!Self {
            MC.mixRoot(channel, proof_in.first_layer.commitment);

            const column_commitment_domain = canonic.CanonicCoset
                .new(column_bound.logDegreeBound() + config.log_blowup_factor)
                .circleDomain();
            var first_layer = FriFirstLayerVerifier(H){
                .column_commitment_domain = column_commitment_domain,
                .folding_alpha = channel.drawSecureFelt(),
                .proof = try cloneLayerProof(H, allocator, proof_in.first_layer),
                .pack_leaves = column_commitment_domain.logSize() >= LOG_PACKED_LEAF_SIZE and
                    config.fold_step > 1,
            };
            errdefer first_layer.deinit(allocator);

            var layer_bound = column_bound.foldToLineWithStep(config.fold_step);
            var layer_domain = line.LineDomain.init(
                circle.Coset.halfOdds(layer_bound.logDegreeBound() + config.log_blowup_factor),
            ) catch return FriVerificationError.InvalidNumFriLayers;

            const inner_layers = try allocator.alloc(FriInnerLayerVerifier(H), proof_in.inner_layers.len);
            errdefer allocator.free(inner_layers);
            var initialized: usize = 0;
            errdefer {
                for (inner_layers[0..initialized]) |*layer| layer.deinit(allocator);
            }

            for (proof_in.inner_layers, 0..) |inner_proof, i| {
                MC.mixRoot(channel, inner_proof.commitment);

                // Determine fold count: normally FOLD_STEP, clamped to the
                // remaining degree so we don't overshoot.
                const remaining = layer_bound.logDegreeBound() - config.log_last_layer_degree_bound;
                const this_fold_step: u32 = @min(config.fold_step, remaining);

                inner_layers[i] = .{
                    .domain = layer_domain,
                    .folding_alpha = channel.drawSecureFelt(),
                    .layer_index = i,
                    .proof = try cloneLayerProof(H, allocator, inner_proof),
                    .fold_step = this_fold_step,
                    .pack_leaves = layer_domain.logSize() >= LOG_PACKED_LEAF_SIZE and
                        this_fold_step > 1,
                };
                initialized += 1;

                layer_bound = layer_bound.fold(this_fold_step) orelse return FriVerificationError.InvalidNumFriLayers;
                // Advance domain by this_fold_step halvings.
                {
                    var step: u32 = 0;
                    while (step < this_fold_step) : (step += 1) {
                        layer_domain = layer_domain.double();
                    }
                }
            }

            if (layer_bound.logDegreeBound() != config.log_last_layer_degree_bound) {
                return FriVerificationError.InvalidNumFriLayers;
            }
            var last_layer_poly = line.LinePoly.initOwned(
                try allocator.dupe(QM31, proof_in.last_layer_poly.coefficients()),
            );
            errdefer last_layer_poly.deinit(allocator);
            if (last_layer_poly.len() > (@as(usize, 1) << @intCast(config.log_last_layer_degree_bound))) {
                return FriVerificationError.LastLayerDegreeInvalid;
            }

            channel.mixFelts(last_layer_poly.coefficients());

            return .{
                .config = config,
                .first_layer = first_layer,
                .inner_layers = inner_layers,
                .last_layer_domain = layer_domain,
                .last_layer_poly = last_layer_poly,
                .queries = null,
            };
        }

        pub fn sampleQueryPositions(
            self: *Self,
            allocator: std.mem.Allocator,
            channel: anytype,
        ) ![]usize {
            const first_layer_log_size = self.first_layer.column_commitment_domain.logSize();
            const unsorted = try queries_mod.drawQueries(
                channel,
                allocator,
                first_layer_log_size,
                self.config.n_queries,
            );
            defer allocator.free(unsorted);

            if (self.queries) |*queries| queries.deinit(allocator);
            self.queries = try queries_mod.Queries.init(allocator, unsorted, first_layer_log_size);
            return allocator.dupe(usize, self.queries.?.positions);
        }

        pub fn decommit(
            self: *Self,
            allocator: std.mem.Allocator,
            first_layer_query_evals: []const QM31,
        ) !void {
            const queries = self.queries orelse return FriVerificationError.FirstLayerEvaluationsInvalid;
            var first_layer_sparse_eval = try self.first_layer.verify(
                allocator,
                queries,
                first_layer_query_evals,
                self.config.fold_step,
            );
            defer first_layer_sparse_eval.deinit(allocator);

            var layer_queries = try queries.fold(allocator, self.config.fold_step);
            defer layer_queries.deinit(allocator);
            var layer_query_evals = try first_layer_sparse_eval.foldCircleSubsets(
                allocator,
                self.first_layer.folding_alpha,
                self.first_layer.column_commitment_domain,
                self.config.fold_step,
            );
            defer allocator.free(layer_query_evals);

            for (self.inner_layers) |layer| {
                const folded = try layer.verifyAndFold(allocator, layer_queries, layer_query_evals);

                layer_queries.deinit(allocator);
                allocator.free(layer_query_evals);
                layer_queries = folded.queries;
                layer_query_evals = folded.evals;
            }

            try self.decommitLastLayer(allocator, layer_queries, layer_query_evals);
        }

        fn decommitLastLayer(
            self: Self,
            allocator: std.mem.Allocator,
            queries: queries_mod.Queries,
            query_evals: []const QM31,
        ) !void {
            if (queries.positions.len != query_evals.len) {
                return FriVerificationError.LastLayerEvaluationsInvalid;
            }

            for (queries.positions, query_evals) |query, query_eval| {
                const x = self.last_layer_domain.at(core_utils.bitReverseIndex(
                    query,
                    self.last_layer_domain.logSize(),
                ));
                const expected = try self.last_layer_poly.evalAtPoint(allocator, QM31.fromBase(x));
                if (!query_eval.eql(expected)) {
                    return FriVerificationError.LastLayerEvaluationsInvalid;
                }
            }
        }
    };
}

fn cloneLayerProof(
    comptime H: type,
    allocator: std.mem.Allocator,
    proof: FriLayerProof(H),
) !FriLayerProof(H) {
    const fri_witness = try allocator.dupe(QM31, proof.fri_witness);
    errdefer allocator.free(fri_witness);

    return .{
        .fri_witness = fri_witness,
        .decommitment = .{
            .hash_witness = try allocator.dupe(H.Hash, proof.decommitment.hash_witness),
        },
        .commitment = proof.commitment,
    };
}

pub fn FriLayerProof(comptime H: type) type {
    return struct {
        fri_witness: []QM31,
        decommitment: vcs_verifier.MerkleDecommitmentLifted(H),
        commitment: H.Hash,

        const Self = @This();

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.fri_witness);
            self.decommitment.deinit(allocator);
            self.* = undefined;
        }
    };
}

fn FriFirstLayerVerifier(comptime H: type) type {
    return struct {
        column_commitment_domain: circle_domain.CircleDomain,
        folding_alpha: QM31,
        proof: FriLayerProof(H),
        pack_leaves: bool,

        const Self = @This();

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.proof.deinit(allocator);
            self.* = undefined;
        }

        fn verify(
            self: Self,
            allocator: std.mem.Allocator,
            queries: queries_mod.Queries,
            column_query_evals: []const QM31,
            fold_step: u32,
        ) !SparseEvaluation {
            if (queries.log_domain_size != self.column_commitment_domain.logSize()) {
                return FriVerificationError.FirstLayerEvaluationsInvalid;
            }

            var rebuilt = computeDecommitmentPositionsAndRebuildEvals(
                allocator,
                queries,
                column_query_evals,
                self.proof.fri_witness,
                fold_step,
            ) catch return FriVerificationError.FirstLayerEvaluationsInvalid;
            errdefer rebuilt.deinit(allocator);

            if (rebuilt.consumed_witness != self.proof.fri_witness.len) {
                return FriVerificationError.FirstLayerEvaluationsInvalid;
            }

            const leaf_log_size: u32 = if (self.pack_leaves) LOG_PACKED_LEAF_SIZE else 0;
            var merkle_inputs = try buildMerkleVerificationInputs(
                allocator,
                rebuilt.decommitment_positions,
                rebuilt.sparse_evaluation,
                leaf_log_size,
            );
            defer merkle_inputs.deinit(allocator);
            const repeated_sizes = try allocator.alloc(u32, merkle_inputs.columns.len);
            defer allocator.free(repeated_sizes);
            @memset(repeated_sizes, self.column_commitment_domain.logSize() - leaf_log_size);
            var merkle_verifier = try vcs_verifier.MerkleVerifierLifted(H).init(
                allocator,
                self.proof.commitment,
                repeated_sizes,
            );
            defer merkle_verifier.deinit(allocator);

            merkle_verifier.verify(
                allocator,
                merkle_inputs.positions,
                merkle_inputs.columns,
                self.proof.decommitment,
            ) catch return FriVerificationError.FirstLayerCommitmentInvalid;

            allocator.free(rebuilt.decommitment_positions);
            return rebuilt.sparse_evaluation;
        }
    };
}

fn FriInnerLayerVerifier(comptime H: type) type {
    return struct {
        domain: line.LineDomain,
        folding_alpha: QM31,
        layer_index: usize,
        proof: FriLayerProof(H),
        /// Number of folds this layer performs (normally FOLD_STEP, may be
        /// smaller for the last inner layer when the remaining degree is not
        /// evenly divisible by FOLD_STEP).
        fold_step: u32 = FOLD_STEP,
        pack_leaves: bool,

        const Self = @This();

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.proof.deinit(allocator);
            self.* = undefined;
        }

        fn verifyAndFold(
            self: Self,
            allocator: std.mem.Allocator,
            queries: queries_mod.Queries,
            evals_at_queries: []const QM31,
        ) !FoldedLayerState {
            if (queries.log_domain_size != self.domain.logSize()) {
                return FriVerificationError.InnerLayerEvaluationsInvalid;
            }

            var rebuilt = computeDecommitmentPositionsAndRebuildEvals(
                allocator,
                queries,
                evals_at_queries,
                self.proof.fri_witness,
                self.fold_step,
            ) catch return FriVerificationError.InnerLayerEvaluationsInvalid;
            errdefer rebuilt.deinit(allocator);

            if (rebuilt.consumed_witness != self.proof.fri_witness.len) {
                return FriVerificationError.InnerLayerEvaluationsInvalid;
            }

            const leaf_log_size: u32 = if (self.pack_leaves) LOG_PACKED_LEAF_SIZE else 0;
            var merkle_inputs = try buildMerkleVerificationInputs(
                allocator,
                rebuilt.decommitment_positions,
                rebuilt.sparse_evaluation,
                leaf_log_size,
            );
            defer merkle_inputs.deinit(allocator);
            const repeated_sizes = try allocator.alloc(u32, merkle_inputs.columns.len);
            defer allocator.free(repeated_sizes);
            @memset(repeated_sizes, self.domain.logSize() - leaf_log_size);
            var merkle_verifier = try vcs_verifier.MerkleVerifierLifted(H).init(
                allocator,
                self.proof.commitment,
                repeated_sizes,
            );
            defer merkle_verifier.deinit(allocator);

            merkle_verifier.verify(
                allocator,
                merkle_inputs.positions,
                merkle_inputs.columns,
                self.proof.decommitment,
            ) catch return FriVerificationError.InnerLayerCommitmentInvalid;

            var folded_queries = try queries.fold(allocator, self.fold_step);
            errdefer folded_queries.deinit(allocator);
            const folded_evals = try rebuilt.sparse_evaluation.foldLineSubsetsN(
                allocator,
                self.folding_alpha,
                self.domain,
                self.fold_step,
            );

            allocator.free(rebuilt.decommitment_positions);
            rebuilt.sparse_evaluation.deinit(allocator);
            return .{
                .queries = folded_queries,
                .evals = folded_evals,
            };
        }
    };
}

const FoldedLayerState = struct {
    queries: queries_mod.Queries,
    evals: []QM31,

    fn deinit(self: *FoldedLayerState, allocator: std.mem.Allocator) void {
        self.queries.deinit(allocator);
        allocator.free(self.evals);
        self.* = undefined;
    }
};

const MerkleVerificationInputs = struct {
    positions: []usize,
    columns: [][]M31,

    fn deinit(self: *MerkleVerificationInputs, allocator: std.mem.Allocator) void {
        allocator.free(self.positions);
        for (self.columns) |column| allocator.free(column);
        allocator.free(self.columns);
        self.* = undefined;
    }
};

/// Converts reconstructed FRI evaluations into the leaf layout committed by
/// STWO. With packed leaves, four consecutive QM31 values become one Merkle
/// row with coordinates ordered by value first, then extension coordinate.
fn buildMerkleVerificationInputs(
    allocator: std.mem.Allocator,
    decommitment_positions: []const usize,
    sparse: SparseEvaluation,
    leaf_log_size: u32,
) !MerkleVerificationInputs {
    if (leaf_log_size >= @bitSizeOf(usize)) return error.ShapeMismatch;
    const leaf_size: usize = @as(usize, 1) << @intCast(leaf_log_size);

    var value_count: usize = 0;
    for (sparse.subset_evals) |subset| value_count += subset.len;
    if (value_count != decommitment_positions.len or
        decommitment_positions.len % leaf_size != 0)
    {
        return error.ShapeMismatch;
    }

    const merkle_position_count = decommitment_positions.len / leaf_size;
    const positions = try allocator.alloc(usize, merkle_position_count);
    errdefer allocator.free(positions);

    var leaf_index: usize = 0;
    while (leaf_index < merkle_position_count) : (leaf_index += 1) {
        const first_index = leaf_index * leaf_size;
        const merkle_position = decommitment_positions[first_index] >> @intCast(leaf_log_size);
        positions[leaf_index] = merkle_position;
        var offset: usize = 0;
        while (offset < leaf_size) : (offset += 1) {
            const position = decommitment_positions[first_index + offset];
            if ((position >> @intCast(leaf_log_size)) != merkle_position or
                (position & (leaf_size - 1)) != offset)
            {
                return error.ShapeMismatch;
            }
        }
        if (leaf_index > 0 and positions[leaf_index - 1] >= merkle_position) {
            return error.ShapeMismatch;
        }
    }

    const flattened_values = try allocator.alloc(QM31, value_count);
    defer allocator.free(flattened_values);
    var value_index: usize = 0;
    for (sparse.subset_evals) |subset| {
        @memcpy(flattened_values[value_index..][0..subset.len], subset);
        value_index += subset.len;
    }

    const column_count = qm31.SECURE_EXTENSION_DEGREE * leaf_size;
    const columns = try allocator.alloc([]M31, column_count);
    errdefer allocator.free(columns);
    var initialized_columns: usize = 0;
    errdefer {
        for (columns[0..initialized_columns]) |column| allocator.free(column);
    }
    while (initialized_columns < columns.len) : (initialized_columns += 1) {
        columns[initialized_columns] = try allocator.alloc(M31, merkle_position_count);
    }

    leaf_index = 0;
    while (leaf_index < merkle_position_count) : (leaf_index += 1) {
        var offset: usize = 0;
        while (offset < leaf_size) : (offset += 1) {
            const coords = flattened_values[leaf_index * leaf_size + offset].toM31Array();
            inline for (coords, 0..) |coord, coordinate| {
                columns[offset * qm31.SECURE_EXTENSION_DEGREE + coordinate][leaf_index] = coord;
            }
        }
    }

    return .{
        .positions = positions,
        .columns = columns,
    };
}

pub fn FriLayerProofAux(comptime H: type) type {
    return struct {
        all_values: [][]IndexedValue,
        decommitment: vcs_verifier.MerkleDecommitmentLiftedAux(H),

        pub const IndexedValue = struct {
            index: usize,
            value: QM31,
        };

        const Self = @This();

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            for (self.all_values) |layer_values| allocator.free(layer_values);
            allocator.free(self.all_values);
            self.decommitment.deinit(allocator);
            self.* = undefined;
        }
    };
}

pub fn ExtendedFriLayerProof(comptime H: type) type {
    return struct {
        proof: FriLayerProof(H),
        aux: FriLayerProofAux(H),

        const Self = @This();

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.proof.deinit(allocator);
            self.aux.deinit(allocator);
            self.* = undefined;
        }
    };
}

pub fn FriProof(comptime H: type) type {
    return struct {
        first_layer: FriLayerProof(H),
        inner_layers: []FriLayerProof(H),
        last_layer_poly: line.LinePoly,

        const Self = @This();

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.first_layer.deinit(allocator);
            for (self.inner_layers) |*layer_proof| layer_proof.deinit(allocator);
            allocator.free(self.inner_layers);
            self.last_layer_poly.deinit(allocator);
            self.* = undefined;
        }
    };
}

pub fn FriProofAux(comptime H: type) type {
    return struct {
        first_layer: FriLayerProofAux(H),
        inner_layers: []FriLayerProofAux(H),

        const Self = @This();

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.first_layer.deinit(allocator);
            for (self.inner_layers) |*layer_aux| layer_aux.deinit(allocator);
            allocator.free(self.inner_layers);
            self.* = undefined;
        }
    };
}

pub fn ExtendedFriProof(comptime H: type) type {
    return struct {
        proof: FriProof(H),
        aux: FriProofAux(H),

        const Self = @This();

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.proof.deinit(allocator);
            self.aux.deinit(allocator);
            self.* = undefined;
        }
    };
}

pub const computeDecommitmentPositionsAndRebuildEvals = folding.computeDecommitmentPositionsAndRebuildEvals;
pub const FoldLineResult = folding.FoldLineResult;
pub const FoldLineWorkspace = folding.FoldLineWorkspace;
pub const FoldCircleWorkspace = folding.FoldCircleWorkspace;
pub const foldLine = folding.foldLine;
pub const foldLineSingleStep = folding.foldLineSingleStep;
pub const foldLineNWithWorkspace = folding.foldLineNWithWorkspace;
pub const foldLineWithWorkspace = folding.foldLineWithWorkspace;
pub const foldLineInPlaceNWithWorkspace = folding.foldLineInPlaceNWithWorkspace;
pub const foldLineInPlaceWithWorkspace = folding.foldLineInPlaceWithWorkspace;
pub const foldCircleIntoLine = folding.foldCircleIntoLine;
pub const foldCircleIntoLineWithWorkspace = folding.foldCircleIntoLineWithWorkspace;
pub const foldCircleColumnsIntoLineWithWorkspace = folding.foldCircleColumnsIntoLineWithWorkspace;
pub const accumulateLine = folding.accumulateLine;

test "fri: packed Merkle inputs preserve STWO leaf coordinate order" {
    const alloc = std.testing.allocator;
    var first_leaf: [4]QM31 = undefined;
    var second_leaf: [4]QM31 = undefined;
    for (&first_leaf, 0..) |*value, i| {
        const base: u32 = @intCast(i * qm31.SECURE_EXTENSION_DEGREE + 1);
        value.* = QM31.fromU32Unchecked(base, base + 1, base + 2, base + 3);
    }
    for (&second_leaf, 0..) |*value, i| {
        const base: u32 = @intCast((i + first_leaf.len) * qm31.SECURE_EXTENSION_DEGREE + 1);
        value.* = QM31.fromU32Unchecked(base, base + 1, base + 2, base + 3);
    }
    var subsets = [_][]QM31{ first_leaf[0..], second_leaf[0..] };
    var subset_initials = [_]usize{ 0, 0 };
    const sparse = SparseEvaluation{
        .subset_evals = subsets[0..],
        .subset_domain_initial_indexes = subset_initials[0..],
    };
    const decommitment_positions = [_]usize{ 4, 5, 6, 7, 12, 13, 14, 15 };

    var inputs = try buildMerkleVerificationInputs(
        alloc,
        decommitment_positions[0..],
        sparse,
        LOG_PACKED_LEAF_SIZE,
    );
    defer inputs.deinit(alloc);

    try std.testing.expectEqualSlices(usize, &[_]usize{ 1, 3 }, inputs.positions);
    try std.testing.expectEqual(@as(usize, 16), inputs.columns.len);
    for (inputs.columns, 0..) |column, column_index| {
        const offset = column_index / qm31.SECURE_EXTENSION_DEGREE;
        const coordinate = column_index % qm31.SECURE_EXTENSION_DEGREE;
        for (column, 0..) |value, leaf_index| {
            const source_value = leaf_index * 4 + offset;
            const expected: u32 = @intCast(
                source_value * qm31.SECURE_EXTENSION_DEGREE + coordinate + 1,
            );
            try std.testing.expect(value.eql(M31.fromCanonical(expected)));
        }
    }

    const Hasher = @import("vcs_lifted/blake2_merkle.zig").Blake2sMerkleHasher;
    var opened_leaf_hashes: [2]Hasher.Hash = undefined;
    for (&opened_leaf_hashes, 0..) |*hash, opened_index| {
        var row: [16]M31 = undefined;
        for (inputs.columns, 0..) |column, column_index| row[column_index] = column[opened_index];
        var hasher = Hasher.defaultWithInitialState();
        hasher.updateLeaf(row[0..]);
        hash.* = hasher.finalize();
    }
    var sibling_row = [_]M31{M31.zero()} ** 16;
    var sibling_hasher = Hasher.defaultWithInitialState();
    sibling_hasher.updateLeaf(sibling_row[0..]);
    const leaf_zero = sibling_hasher.finalize();
    @memset(sibling_row[0..], M31.one());
    sibling_hasher = Hasher.defaultWithInitialState();
    sibling_hasher.updateLeaf(sibling_row[0..]);
    const leaf_two = sibling_hasher.finalize();
    const root = Hasher.hashChildren(.{
        .left = Hasher.hashChildren(.{ .left = leaf_zero, .right = opened_leaf_hashes[0] }),
        .right = Hasher.hashChildren(.{ .left = leaf_two, .right = opened_leaf_hashes[1] }),
    });
    var verifier = try vcs_verifier.MerkleVerifierLifted(Hasher).init(
        alloc,
        root,
        &([_]u32{2} ** 16),
    );
    defer verifier.deinit(alloc);
    var decommitment = vcs_verifier.MerkleDecommitmentLifted(Hasher){
        .hash_witness = try alloc.dupe(Hasher.Hash, &[_]Hasher.Hash{ leaf_zero, leaf_two }),
    };
    defer decommitment.deinit(alloc);
    try verifier.verify(alloc, inputs.positions, inputs.columns, decommitment);
}
