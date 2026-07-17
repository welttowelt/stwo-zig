const std = @import("std");
const backend_merkle = @import("../../backend/merkle_ops.zig");
const circle = @import("../../core/circle.zig");
const m31 = @import("../../core/fields/m31.zig");
const qm31 = @import("../../core/fields/qm31.zig");
const pcs_core = @import("../../core/pcs/mod.zig");
const pcs_utils = @import("../../core/pcs/utils.zig");
const verifier_types = @import("../../core/verifier_types.zig");
const vcs_verifier = @import("../../core/vcs_lifted/verifier.zig");
const canonic = @import("../../core/poly/circle/canonic.zig");
const component_prover = @import("../air/component_prover.zig");
const prover_circle = @import("../poly/circle/mod.zig");
const stage_profile = @import("../stage_profile.zig");
const twiddles_mod = @import("../poly/twiddles.zig");
const prover_fri = @import("../fri.zig");
const vcs_lifted_prover = @import("../vcs_lifted/prover.zig");
const commitment_tree = @import("commitment_tree.zig");
const circle_transforms = @import("columns/circle_transforms.zig");
const column_preparation = @import("columns/preparation.zig");
const column_storage = @import("columns/storage.zig");
const sampled_value_transcript = @import("sampled_value_transcript.zig");
const sampled_value_evaluation = @import("sampled_values.zig");

pub const quotient_ops = @import("quotient_ops.zig");

const M31 = m31.M31;
const QM31 = qm31.QM31;
const CirclePointQM31 = circle.CirclePointQM31;
const PcsConfig = pcs_core.PcsConfig;
const TreeVec = pcs_core.TreeVec;
const TreeSubspan = pcs_core.TreeSubspan;
const PREPROCESSED_TRACE_IDX = verifier_types.PREPROCESSED_TRACE_IDX;

pub const CommitmentSchemeError = error{
    ShapeMismatch,
    InvalidPreprocessedTree,
};

const CoefficientRetentionPolicy = column_storage.CoefficientRetentionPolicy;

pub const ColumnEvaluation = commitment_tree.ColumnEvaluation;

pub fn CommitmentTreeProver(comptime H: type) type {
    return commitment_tree.CommitmentTreeProver(H);
}

pub fn TreeDecommitmentResult(comptime H: type) type {
    return struct {
        queried_values: TreeVec([][]M31),
        decommitments: TreeVec(vcs_verifier.MerkleDecommitmentLifted(H)),
        aux: TreeVec(vcs_verifier.MerkleDecommitmentLiftedAux(H)),

        const Self = @This();

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.queried_values.deinitDeep(allocator);
            for (self.decommitments.items) |*d| d.deinit(allocator);
            self.decommitments.deinit(allocator);
            for (self.aux.items) |*a| a.deinit(allocator);
            self.aux.deinit(allocator);
            self.* = undefined;
        }
    };
}

pub fn CommitmentSchemeProver(comptime B: type, comptime H: type, comptime MC: type) type {
    comptime backend_merkle.assertMerkleOps(B, H);
    const BackendCommitmentTree = commitment_tree.CommitmentTreeProverForBackend(B, H);
    return struct {
        trees: std.ArrayListUnmanaged(BackendCommitmentTree),
        config: PcsConfig,
        coefficient_retention_policy: CoefficientRetentionPolicy,
        twiddle_cache: std.AutoHashMap(u32, twiddles_mod.TwiddleTree([]M31)),

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, config: PcsConfig) !Self {
            return .{
                .trees = .{},
                .config = config,
                .coefficient_retention_policy = .always,
                .twiddle_cache = std.AutoHashMap(u32, twiddles_mod.TwiddleTree([]M31)).init(allocator),
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            for (self.trees.items) |*tree| tree.deinit(allocator);
            self.trees.deinit(allocator);
            circle_transforms.deinitTwiddleCache(allocator, &self.twiddle_cache);
            self.* = undefined;
        }

        pub fn setStorePolynomialsCoefficients(self: *Self) void {
            self.coefficient_retention_policy = .always;
        }

        pub fn commit(
            self: *Self,
            allocator: std.mem.Allocator,
            columns: []const ColumnEvaluation,
            channel: anytype,
        ) !void {
            var prepared = try column_preparation.prepareColumnsForCommitBorrowedForBackend(
                B,
                allocator,
                columns,
                self.config.fri_config.log_blowup_factor,
                self.coefficient_retention_policy,
                &self.twiddle_cache,
            );
            errdefer prepared.deinit(allocator);

            var tree = try BackendCommitmentTree.initOwnedWithBacking(
                allocator,
                prepared.columns,
                prepared.coefficients,
                prepared.column_backing_buffers,
                prepared.coefficient_backing_buffers,
            );
            errdefer tree.deinit(allocator);
            try self.appendCommittedTree(allocator, tree, channel);
        }

        /// Commits owned evaluation columns directly, avoiding an extra column clone.
        ///
        /// Ownership:
        /// - On success, ownership is transferred into the commitment tree.
        /// - On failure, owned columns are fully deinitialized.
        pub fn commitOwned(
            self: *Self,
            allocator: std.mem.Allocator,
            owned_columns: []ColumnEvaluation,
            channel: anytype,
        ) !void {
            return self.commitOwnedWithRecorder(allocator, owned_columns, null, channel);
        }

        /// Default batch size for streaming column commitment.
        const streaming_batch_size: usize = 64;
        /// Column count threshold above which commitOwnedWithRecorder
        /// automatically uses the streaming path.  Below this threshold
        /// the monolithic path is used (the overhead of streaming state
        /// management is not worthwhile for small column sets).
        const streaming_column_threshold: usize = 128;

        pub fn commitOwnedWithRecorder(
            self: *Self,
            allocator: std.mem.Allocator,
            owned_columns: []ColumnEvaluation,
            recorder: ?*stage_profile.Recorder,
            channel: anytype,
        ) !void {
            if (column_preparation.columnEvaluationsAreConstant(owned_columns)) {
                errdefer column_storage.freeOwnedColumnEvaluations(allocator, owned_columns);
                var prepared = try column_preparation.prepareConstantColumnsForCommitOwned(
                    allocator,
                    owned_columns,
                    self.config.fri_config.log_blowup_factor,
                    self.coefficient_retention_policy,
                );
                errdefer prepared.deinit(allocator);

                var tree = try BackendCommitmentTree.initOwnedWithCoefficients(
                    allocator,
                    prepared.columns,
                    prepared.coefficients,
                );
                errdefer tree.deinit(allocator);
                return self.appendCommittedTree(allocator, tree, channel);
            }

            // Auto-dispatch to streaming path for large column sets
            // to reduce peak memory by processing in batches.
            const backend_prefers_monolithic = comptime @hasDecl(B, "preferMonolithicCommit") and B.preferMonolithicCommit;
            if (owned_columns.len >= streaming_column_threshold and !backend_prefers_monolithic) {
                return self.commitOwnedStreamingWithRecorder(
                    allocator,
                    owned_columns,
                    streaming_batch_size,
                    recorder,
                    channel,
                );
            }

            errdefer column_storage.freeOwnedColumnEvaluations(allocator, owned_columns);
            var prepared = try column_preparation.prepareColumnsForCommitOwnedForBackend(
                B,
                allocator,
                owned_columns,
                self.config.fri_config.log_blowup_factor,
                self.coefficient_retention_policy,
                &self.twiddle_cache,
                recorder,
            );
            errdefer prepared.deinit(allocator);

            var merkle_commit_stage = try stage_profile.StageScope.begin(
                recorder,
                "merkle_commit",
                "Merkle commit",
            );
            defer merkle_commit_stage.end();
            var tree = try BackendCommitmentTree.initOwnedWithBacking(
                allocator,
                prepared.columns,
                prepared.coefficients,
                prepared.column_backing_buffers,
                prepared.coefficient_backing_buffers,
            );
            errdefer tree.deinit(allocator);
            try self.appendCommittedTree(allocator, tree, channel);
        }

        /// Commits coefficient-form circle polynomials directly.
        ///
        /// Inputs:
        /// - `polys`: coefficient polynomials over canonic cosets.
        ///
        /// Semantics:
        /// - evaluates each polynomial on the commitment domain extended by
        ///   `config.fri_config.log_blowup_factor`.
        /// - optionally stores cloned coefficients according to the
        ///   configured retention policy.
        pub fn commitPolys(
            self: *Self,
            allocator: std.mem.Allocator,
            polys: []const prover_circle.CircleCoefficients,
            channel: anytype,
        ) !void {
            const blowup = self.config.fri_config.log_blowup_factor;
            const columns = try circle_transforms.extendCoefficientColumnsByGroupForBackend(
                B,
                allocator,
                polys,
                blowup,
                &self.twiddle_cache,
            );
            errdefer column_storage.freeOwnedColumnEvaluations(allocator, columns);

            var stored_coefficients: ?[]prover_circle.CircleCoefficients = null;
            if (column_storage.shouldRetainPolynomialCoefficients(polys, self.coefficient_retention_policy)) {
                const coeffs = try allocator.alloc(prover_circle.CircleCoefficients, polys.len);
                errdefer allocator.free(coeffs);

                var initialized_coeffs: usize = 0;
                errdefer {
                    for (coeffs[0..initialized_coeffs]) |*coeff| coeff.deinit(allocator);
                    allocator.free(coeffs);
                }

                for (polys, 0..) |poly, i| {
                    coeffs[i] = try prover_circle.CircleCoefficients.initOwned(
                        try allocator.dupe(M31, poly.coefficients()),
                    );
                    initialized_coeffs += 1;
                }
                stored_coefficients = coeffs;
            }

            var tree = try BackendCommitmentTree.initOwnedWithCoefficients(
                allocator,
                columns,
                stored_coefficients,
            );
            errdefer tree.deinit(allocator);
            try self.appendCommittedTree(allocator, tree, channel);
        }

        pub fn treeBuilder(self: *Self, allocator: std.mem.Allocator) TreeBuilder(B, H, MC) {
            return .{
                .allocator = allocator,
                .tree_index = self.trees.items.len,
                .commitment_scheme = self,
                .columns = std.ArrayList(ColumnEvaluation).empty,
            };
        }

        /// Returns a `StreamingTreeBuilder` that commits columns in
        /// configurable batches, reducing peak memory.
        ///
        /// Usage:
        ///   1. Call `streamingTreeBuilder()` to obtain a builder.
        ///   2. Call `builder.addColumns(batch)` for each batch of
        ///      `ColumnEvaluation` (owned values).  The batch data is prepared
        ///      (interpolated + extended), hashed into the Merkle leaf layer,
        ///      and the extended column data is freed immediately.
        ///   3. Call `builder.commit(channel)` to finalise the Merkle tree and
        ///      append it to the commitment scheme.
        ///
        /// The final Merkle root is bit-identical to `commitOwned()`.
        pub fn streamingTreeBuilder(
            self: *Self,
            allocator: std.mem.Allocator,
            batch_size: u32,
        ) StreamingTreeBuilder(B, H, MC) {
            return StreamingTreeBuilder(B, H, MC).init(
                allocator,
                self,
                batch_size,
            );
        }

        /// Commits owned evaluation columns in streaming batches to reduce peak
        /// memory.  Semantically identical to `commitOwned()` but processes
        /// columns in groups of `batch_size`, freeing each batch's extended
        /// evaluation data before the next batch is prepared.
        ///
        /// `batch_size` controls the number of columns prepared and hashed in
        /// each round.  A value of 0 uses the default (64).
        pub fn commitOwnedStreaming(
            self: *Self,
            allocator: std.mem.Allocator,
            owned_columns: []ColumnEvaluation,
            batch_size: u32,
            channel: anytype,
        ) !void {
            return self.commitOwnedStreamingWithRecorder(
                allocator,
                owned_columns,
                batch_size,
                null,
                channel,
            );
        }

        pub fn commitOwnedStreamingWithRecorder(
            self: *Self,
            allocator: std.mem.Allocator,
            owned_columns: []ColumnEvaluation,
            batch_size_arg: u32,
            recorder: ?*stage_profile.Recorder,
            channel: anytype,
        ) !void {
            const effective_batch_size: usize = if (batch_size_arg == 0) 64 else @as(usize, batch_size_arg);

            const ColumnOrder = struct {
                columns: []const ColumnEvaluation,

                fn lessThan(context: @This(), lhs: usize, rhs: usize) bool {
                    const lhs_log_size = context.columns[lhs].log_size;
                    const rhs_log_size = context.columns[rhs].log_size;
                    return lhs_log_size < rhs_log_size or
                        (lhs_log_size == rhs_log_size and lhs < rhs);
                }
            };
            const order = try allocator.alloc(usize, owned_columns.len);
            defer allocator.free(order);
            for (order, 0..) |*index, i| index.* = i;
            std.sort.heap(
                usize,
                order,
                ColumnOrder{ .columns = owned_columns },
                ColumnOrder.lessThan,
            );

            var builder = StreamingTreeBuilder(B, H, MC).init(allocator, self, effective_batch_size);
            errdefer builder.deinit();

            // Process columns in batches.  Each iteration:
            //  1. Allocates a new batch array and moves column entries into it.
            //  2. Nulls out the moved entries in the original array.
            //  3. Passes the batch to addColumnsOwned (which takes full ownership).
            //
            // On error, `builder.deinit()` cleans up already-consumed data,
            // and we manually free remaining unconsumed columns below.
            var consumed: usize = 0;
            while (consumed < owned_columns.len) {
                const end = @min(owned_columns.len, consumed + effective_batch_size);
                const batch_len = end - consumed;

                const batch = allocator.alloc(ColumnEvaluation, batch_len) catch |err| {
                    for (owned_columns) |col| {
                        if (col.values.len > 0) allocator.free(col.values);
                    }
                    allocator.free(owned_columns);
                    return err;
                };
                for (order[consumed..end], 0..) |original_index, batch_index| {
                    batch[batch_index] = owned_columns[original_index];
                    owned_columns[original_index].values = &[_]M31{};
                }

                builder.addColumnsOwnedIndexed(batch, order[consumed..end], recorder) catch |err| {
                    // batch is owned by addColumnsOwned on success.
                    // On error, addColumnsOwned's errdefer handles the batch
                    // via prepareColumnsForCommitOwned's errdefer.
                    for (owned_columns) |col| {
                        if (col.values.len > 0) allocator.free(col.values);
                    }
                    allocator.free(owned_columns);
                    return err;
                };
                consumed = end;
            }

            // All column values have been transferred to the builder.
            allocator.free(owned_columns);

            try builder.commit(channel);
        }

        pub fn roots(self: Self, allocator: std.mem.Allocator) !TreeVec(H.Hash) {
            const out = try allocator.alloc(H.Hash, self.trees.items.len);
            for (self.trees.items, 0..) |tree, i| {
                out[i] = tree.root();
            }
            return TreeVec(H.Hash).initOwned(out);
        }

        /// Returns committed columns as prover-air `Poly` views.
        ///
        /// The returned wrappers borrow underlying column storage from the commitment scheme.
        pub fn polynomials(
            self: Self,
            allocator: std.mem.Allocator,
        ) !TreeVec([]const component_prover.Poly) {
            const out = try allocator.alloc([]const component_prover.Poly, self.trees.items.len);
            errdefer allocator.free(out);

            var initialized: usize = 0;
            errdefer {
                for (out[0..initialized]) |tree_polys| allocator.free(tree_polys);
            }

            for (self.trees.items, 0..) |tree, tree_idx| {
                const polys = try allocator.alloc(component_prover.Poly, tree.columns.len);
                out[tree_idx] = polys;
                initialized += 1;
                for (tree.columns, 0..) |column, col_idx| {
                    polys[col_idx] = .{
                        .log_size = column.log_size,
                        .values = column.values,
                    };
                }
            }
            return TreeVec([]const component_prover.Poly).initOwned(out);
        }

        pub fn trace(
            self: Self,
            allocator: std.mem.Allocator,
        ) !component_prover.Trace {
            return .{
                .polys = try self.polynomials(allocator),
            };
        }

        pub fn columnLogSizes(self: Self, allocator: std.mem.Allocator) !TreeVec([]u32) {
            const out = try allocator.alloc([]u32, self.trees.items.len);
            errdefer allocator.free(out);

            var initialized: usize = 0;
            errdefer {
                for (out[0..initialized]) |tree_sizes| allocator.free(tree_sizes);
            }

            for (self.trees.items, 0..) |tree, i| {
                out[i] = try tree.columnLogSizes(allocator);
                initialized += 1;
            }

            return TreeVec([]u32).initOwned(out);
        }

        pub fn buildQueryPositionsTree(
            self: Self,
            allocator: std.mem.Allocator,
            query_positions: []const usize,
            lifting_log_size: u32,
        ) !TreeVec([]usize) {
            const out = try allocator.alloc([]usize, self.trees.items.len);
            errdefer allocator.free(out);

            var initialized: usize = 0;
            errdefer {
                for (out[0..initialized]) |positions| allocator.free(positions);
            }

            const pp_max_log_size = if (self.trees.items.len > PREPROCESSED_TRACE_IDX)
                maxLogSize(self.trees.items[PREPROCESSED_TRACE_IDX].columns)
            else
                return CommitmentSchemeError.InvalidPreprocessedTree;

            const preprocessed_positions = try pcs_utils.preparePreprocessedQueryPositions(
                allocator,
                query_positions,
                lifting_log_size,
                pp_max_log_size,
            );
            defer allocator.free(preprocessed_positions);

            for (0..self.trees.items.len) |tree_idx| {
                if (tree_idx == PREPROCESSED_TRACE_IDX) {
                    out[tree_idx] = try allocator.dupe(usize, preprocessed_positions);
                } else {
                    out[tree_idx] = try allocator.dupe(usize, query_positions);
                }
                initialized += 1;
            }

            return TreeVec([]usize).initOwned(out);
        }

        pub fn decommitByTreePositions(
            self: Self,
            allocator: std.mem.Allocator,
            query_positions_tree: TreeVec([]const usize),
        ) !TreeDecommitmentResult(H) {
            if (query_positions_tree.items.len != self.trees.items.len) {
                return CommitmentSchemeError.ShapeMismatch;
            }

            const queried_values_out = try allocator.alloc([][]M31, self.trees.items.len);
            errdefer allocator.free(queried_values_out);
            const decommitments_out = try allocator.alloc(vcs_verifier.MerkleDecommitmentLifted(H), self.trees.items.len);
            errdefer allocator.free(decommitments_out);
            const aux_out = try allocator.alloc(vcs_verifier.MerkleDecommitmentLiftedAux(H), self.trees.items.len);
            errdefer allocator.free(aux_out);

            var initialized: usize = 0;
            errdefer {
                for (queried_values_out[0..initialized]) |tree_values| {
                    for (tree_values) |col| allocator.free(col);
                    allocator.free(tree_values);
                }
                for (decommitments_out[0..initialized]) |*d| d.deinit(allocator);
                for (aux_out[0..initialized]) |*a| a.deinit(allocator);
            }

            for (self.trees.items, query_positions_tree.items, 0..) |tree, positions, i| {
                const decommit = try tree.decommit(allocator, positions);
                queried_values_out[i] = decommit.queried_values;
                decommitments_out[i] = decommit.decommitment.decommitment;
                aux_out[i] = decommit.decommitment.aux;
                initialized += 1;
            }

            return .{
                .queried_values = TreeVec([][]M31).initOwned(queried_values_out),
                .decommitments = TreeVec(vcs_verifier.MerkleDecommitmentLifted(H)).initOwned(decommitments_out),
                .aux = TreeVec(vcs_verifier.MerkleDecommitmentLiftedAux(H)).initOwned(aux_out),
            };
        }

        /// Proves sampled values for already-committed trees.
        ///
        /// Inputs:
        /// - `sampled_points`: per tree -> per column sampled points.
        ///
        /// Output:
        /// - full PCS opening proof with sampled values computed in-prover.
        ///
        /// Invariants:
        /// - sampled-point tree/column shape must match committed trees/columns.
        /// - every sampled point is folded to each column's log size before evaluation.
        pub fn proveValues(
            self: Self,
            allocator: std.mem.Allocator,
            sampled_points: TreeVec([][]CirclePointQM31),
            channel: anytype,
        ) !pcs_core.ExtendedCommitmentSchemeProof(H) {
            return self.proveValuesWithRecorder(allocator, sampled_points, null, channel);
        }

        pub fn proveValuesWithRecorder(
            self: Self,
            allocator: std.mem.Allocator,
            sampled_points: TreeVec([][]CirclePointQM31),
            recorder: ?*stage_profile.Recorder,
            channel: anytype,
        ) !pcs_core.ExtendedCommitmentSchemeProof(H) {
            var scheme = self;
            const lifting_log_size = try scheme.maxTreeLogSize();
            const sampled_values = blk: {
                var sampled_value_eval_stage = try stage_profile.StageScope.begin(
                    recorder,
                    "sampled_value_evaluation",
                    "Sampled-value evaluation",
                );
                defer sampled_value_eval_stage.end();
                break :blk try scheme.evaluateSampledValuesAndRelease(
                    allocator,
                    sampled_points,
                    lifting_log_size,
                );
            };
            return scheme.proveValuesFromSamplesWithRecorder(
                allocator,
                sampled_points,
                sampled_values,
                recorder,
                channel,
            );
        }

        /// Proves sampled values for already-committed trees using precomputed point evaluations.
        ///
        /// Inputs:
        /// - `sampled_points`: per tree -> per column sampled points.
        /// - `sampled_values`: per tree -> per column sampled values (same shape as points).
        ///
        /// Invariants:
        /// - `sampled_points` and `sampled_values` must match the tree/column shape.
        /// - Values are assumed to match the committed columns at those points.
        pub fn proveValuesFromSamples(
            self: Self,
            allocator: std.mem.Allocator,
            sampled_points: TreeVec([][]CirclePointQM31),
            sampled_values: TreeVec([][]QM31),
            channel: anytype,
        ) !pcs_core.ExtendedCommitmentSchemeProof(H) {
            return self.proveValuesFromSamplesWithRecorder(
                allocator,
                sampled_points,
                sampled_values,
                null,
                channel,
            );
        }

        pub fn proveValuesFromSamplesWithRecorder(
            self: Self,
            allocator: std.mem.Allocator,
            sampled_points: TreeVec([][]CirclePointQM31),
            sampled_values: TreeVec([][]QM31),
            recorder: ?*stage_profile.Recorder,
            channel: anytype,
        ) !pcs_core.ExtendedCommitmentSchemeProof(H) {
            var scheme = self;
            defer scheme.deinit(allocator);
            var sampled_points_owned = sampled_points;
            defer sampled_points_owned.deinitDeep(allocator);
            var sampled_values_owned = sampled_values;
            errdefer sampled_values_owned.deinitDeep(allocator);

            if (scheme.trees.items.len != sampled_points_owned.items.len) {
                return CommitmentSchemeError.ShapeMismatch;
            }
            if (scheme.trees.items.len != sampled_values_owned.items.len) {
                return CommitmentSchemeError.ShapeMismatch;
            }

            for (scheme.trees.items, sampled_points_owned.items, sampled_values_owned.items) |tree, tree_points, tree_values| {
                if (tree.columns.len != tree_points.len) return CommitmentSchemeError.ShapeMismatch;
                if (tree.columns.len != tree_values.len) return CommitmentSchemeError.ShapeMismatch;
            }

            {
                var sampled_value_mix_stage = try stage_profile.StageScope.begin(
                    recorder,
                    "sampled_value_channel_mix",
                    "Sampled-value channel mix",
                );
                defer sampled_value_mix_stage.end();
                try sampled_value_transcript.mixIntoChannel(allocator, channel, sampled_values_owned);
            }

            const random_coeff = channel.drawSecureFelt();

            const lifting_log_size = try scheme.maxTreeLogSize();
            const domain = canonic.CanonicCoset.new(lifting_log_size).circleDomain();

            var fri_prover = blk: {
                var fri_quotient_stage = try stage_profile.StageScope.begin(
                    recorder,
                    "fri_quotient_build_and_commit",
                    "FRI quotient build + commit (lazy)",
                );
                defer fri_quotient_stage.end();

                const borrowed_columns_items = try allocator.alloc([]const ColumnEvaluation, scheme.trees.items.len);
                defer allocator.free(borrowed_columns_items);
                for (scheme.trees.items, 0..) |tree, i| {
                    borrowed_columns_items[i] = tree.columns;
                }

                var provider = try quotient_ops.LazyQuotientProvider.initForBackend(
                    B,
                    allocator,
                    TreeVec([]const ColumnEvaluation).initOwned(borrowed_columns_items),
                    sampled_points_owned,
                    sampled_values_owned,
                    random_coeff,
                    lifting_log_size,
                );
                defer provider.deinit(allocator);

                break :blk try prover_fri.FriProver(B, H, MC).commitLazy(
                    allocator,
                    channel,
                    scheme.config.fri_config,
                    domain,
                    &provider,
                );
            };

            const proof_of_work = blk: {
                var proof_of_work_stage = try stage_profile.StageScope.begin(
                    recorder,
                    "proof_of_work",
                    "Proof of work",
                );
                defer proof_of_work_stage.end();
                const nonce = grind(channel, scheme.config.pow_bits);
                channel.mixU64(nonce);
                break :blk nonce;
            };

            var fri_decommit = blk: {
                var fri_decommit_stage = try stage_profile.StageScope.begin(
                    recorder,
                    "fri_decommit",
                    "FRI decommit",
                );
                defer fri_decommit_stage.end();
                break :blk try fri_prover.decommit(allocator, channel);
            };
            errdefer fri_decommit.deinit(allocator);

            var trace_decommit = blk: {
                var trace_decommit_stage = try stage_profile.StageScope.begin(
                    recorder,
                    "trace_decommit",
                    "Trace decommit",
                );
                defer trace_decommit_stage.end();
                var query_positions_tree = try scheme.buildQueryPositionsTree(
                    allocator,
                    fri_decommit.query_positions,
                    lifting_log_size,
                );
                defer query_positions_tree.deinitDeep(allocator);

                const query_positions_const = try allocator.alloc([]const usize, query_positions_tree.items.len);
                defer allocator.free(query_positions_const);
                for (query_positions_tree.items, 0..) |positions, i| {
                    query_positions_const[i] = positions;
                }

                break :blk try scheme.decommitByTreePositions(
                    allocator,
                    TreeVec([]const usize).initOwned(query_positions_const),
                );
            };
            errdefer trace_decommit.deinit(allocator);

            var commitments = try scheme.roots(allocator);
            errdefer commitments.deinit(allocator);

            // `query_positions` are only needed for prover-side decommit orchestration.
            allocator.free(fri_decommit.query_positions);
            fri_decommit.query_positions = &[_]usize{};

            return .{
                .proof = .{
                    .config = scheme.config,
                    .commitments = commitments,
                    .sampled_values = sampled_values_owned,
                    .decommitments = trace_decommit.decommitments,
                    .queried_values = trace_decommit.queried_values,
                    .proof_of_work = proof_of_work,
                    .fri_proof = fri_decommit.fri_proof.proof,
                },
                .aux = .{
                    .unsorted_query_locations = fri_decommit.unsorted_query_locations,
                    .trace_decommitment = trace_decommit.aux,
                    .fri = fri_decommit.fri_proof.aux,
                },
            };
        }

        fn appendCommittedTree(
            self: *Self,
            allocator: std.mem.Allocator,
            tree: BackendCommitmentTree,
            channel: anytype,
        ) !void {
            try self.trees.append(allocator, tree);
            MC.mixRoot(channel, tree.root());
        }

        fn maxLogSize(columns: []const ColumnEvaluation) u32 {
            var max_size: u32 = 0;
            for (columns) |column| max_size = @max(max_size, column.log_size);
            return max_size;
        }

        fn maxTreeLogSize(self: Self) !u32 {
            if (self.trees.items.len == 0) return CommitmentSchemeError.ShapeMismatch;
            var max_size: u32 = 0;
            for (self.trees.items) |tree| {
                max_size = @max(max_size, maxLogSize(tree.columns));
            }
            return max_size;
        }

        fn evaluateSampledValuesAndRelease(
            self: *Self,
            allocator: std.mem.Allocator,
            sampled_points: TreeVec([][]CirclePointQM31),
            lifting_log_size: u32,
        ) !TreeVec([][]QM31) {
            return sampled_value_evaluation.evaluateAndRelease(
                B,
                H,
                allocator,
                self.trees.items,
                sampled_points,
                lifting_log_size,
            );
        }
    };
}

pub fn TreeBuilder(comptime B: type, comptime H: type, comptime MC: type) type {
    return struct {
        allocator: std.mem.Allocator,
        tree_index: usize,
        commitment_scheme: *CommitmentSchemeProver(B, H, MC),
        columns: std.ArrayList(ColumnEvaluation),

        const Self = @This();

        pub fn deinit(self: *Self) void {
            for (self.columns.items) |column| self.allocator.free(column.values);
            self.columns.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn extendColumns(self: *Self, cols: []const ColumnEvaluation) !TreeSubspan {
            const col_start = self.columns.items.len;
            for (cols) |column| {
                try column.validate();
                try self.columns.append(self.allocator, .{
                    .log_size = column.log_size,
                    .values = try self.allocator.dupe(M31, column.values),
                });
            }
            const col_end = self.columns.items.len;
            return .{
                .tree_index = self.tree_index,
                .col_start = col_start,
                .col_end = col_end,
            };
        }

        pub fn commit(self: *Self, channel: anytype) !void {
            const base_columns = try self.columns.toOwnedSlice(self.allocator);
            self.columns = std.ArrayList(ColumnEvaluation).empty;
            errdefer {
                column_storage.freeOwnedColumnEvaluations(self.allocator, base_columns);
            }

            var prepared = try column_preparation.prepareColumnsForCommitOwnedForBackend(
                B,
                self.allocator,
                base_columns,
                self.commitment_scheme.config.fri_config.log_blowup_factor,
                self.commitment_scheme.coefficient_retention_policy,
                &self.commitment_scheme.twiddle_cache,
                null,
            );
            errdefer prepared.deinit(self.allocator);

            var tree = try commitment_tree.CommitmentTreeProverForBackend(B, H).initOwnedWithBacking(
                self.allocator,
                prepared.columns,
                prepared.coefficients,
                prepared.column_backing_buffers,
                prepared.coefficient_backing_buffers,
            );
            errdefer tree.deinit(self.allocator);
            try self.commitment_scheme.appendCommittedTree(self.allocator, tree, channel);
        }
    };
}

fn adoptStreamingCommitment(
    comptime B: type,
    comptime H: type,
    host_tree: vcs_lifted_prover.MerkleProverLifted(H),
) !B.MerkleTree(H) {
    if (comptime B.MerkleTree(H) == vcs_lifted_prover.MerkleProverLifted(H)) {
        return host_tree;
    }
    if (comptime @hasDecl(B, "adoptHostMerkle")) {
        return B.adoptHostMerkle(H, host_tree);
    }
    @compileError("Backend-specific Merkle trees require `adoptHostMerkle` for streaming PCS commits.");
}

/// A streaming tree builder that commits columns in configurable batches,
/// building the Merkle leaf layer incrementally and freeing each batch's
/// extended column data before the next batch is prepared.
///
/// The resulting Merkle root is bit-identical to building the tree from all
/// columns at once.
pub fn StreamingTreeBuilder(comptime B: type, comptime H: type, comptime MC: type) type {
    const MerkleProver = vcs_lifted_prover.MerkleProverLifted(H);
    return struct {
        allocator: std.mem.Allocator,
        commitment_scheme: *CommitmentSchemeProver(B, H, MC),
        batch_size: usize,

        /// Streaming Merkle committer that accumulates leaf hashes incrementally.
        streaming_committer: MerkleProver.StreamingCommitter,

        /// Columns retained for later decommitment and sampled-value evaluation.
        /// Each entry stores the *extended* column values and their log_size.
        retained_columns: std.ArrayList(ColumnEvaluation),

        /// Original PCS position for each retained column. Streaming hashes
        /// columns in log-size order, then restores this order before commit.
        retained_column_indices: std.ArrayList(usize),

        /// Coefficient polynomials retained for sampled-value evaluation
        /// (only when the retention policy says to keep them).
        retained_coefficients: std.ArrayList(prover_circle.CircleCoefficients),

        /// Whether we should retain coefficients.
        retain_coefficients: bool,

        const Self = @This();

        pub fn init(
            allocator: std.mem.Allocator,
            scheme: *CommitmentSchemeProver(B, H, MC),
            batch_size: usize,
        ) Self {
            return .{
                .allocator = allocator,
                .commitment_scheme = scheme,
                .batch_size = if (batch_size == 0) 64 else batch_size,
                .streaming_committer = MerkleProver.StreamingCommitter.init(allocator),
                .retained_columns = std.ArrayList(ColumnEvaluation).empty,
                .retained_column_indices = std.ArrayList(usize).empty,
                .retained_coefficients = std.ArrayList(prover_circle.CircleCoefficients).empty,
                .retain_coefficients = scheme.coefficient_retention_policy == .always,
            };
        }

        pub fn deinit(self: *Self) void {
            self.streaming_committer.deinit();
            for (self.retained_columns.items) |col| {
                if (col.values.len > 0) self.allocator.free(col.values);
            }
            self.retained_columns.deinit(self.allocator);
            self.retained_column_indices.deinit(self.allocator);
            for (self.retained_coefficients.items) |*coeff| {
                var c = coeff.*;
                c.deinit(self.allocator);
            }
            self.retained_coefficients.deinit(self.allocator);
            self.* = undefined;
        }

        /// Add a batch of owned columns.  The column values are consumed:
        /// they are interpolated, extended to the commitment domain, hashed into
        /// the streaming Merkle leaf layer, and the *original* values freed.
        /// The *extended* values are retained (needed for decommitment).
        ///
        /// Columns MUST be supplied so that within each call (and across calls)
        /// their extended log_sizes are non-decreasing.  In practice, grouping
        /// columns by their original log_size achieves this.
        pub fn addColumnsOwned(
            self: *Self,
            owned_batch: []ColumnEvaluation,
            recorder: ?*stage_profile.Recorder,
        ) !void {
            const first_index = self.retained_column_indices.items.len;
            const indices = try self.allocator.alloc(usize, owned_batch.len);
            defer self.allocator.free(indices);
            for (indices, 0..) |*index, i| index.* = first_index + i;
            return self.addColumnsOwnedIndexed(owned_batch, indices, recorder);
        }

        fn addColumnsOwnedIndexed(
            self: *Self,
            owned_batch: []ColumnEvaluation,
            original_indices: []const usize,
            recorder: ?*stage_profile.Recorder,
        ) !void {
            std.debug.assert(owned_batch.len == original_indices.len);
            if (owned_batch.len == 0) {
                self.allocator.free(owned_batch);
                return;
            }

            const log_blowup = self.commitment_scheme.config.fri_config.log_blowup_factor;

            // Determine coefficient retention for this batch.
            const batch_retain = self.retain_coefficients or
                column_storage.shouldRetainCoefficients(owned_batch, self.commitment_scheme.coefficient_retention_policy);

            // Prepare: interpolate + extend.
            // Follow the same ownership convention as commitOwnedWithRecorder:
            // on error from prepareColumnsForCommitOwned the caller cleans up
            // the input; on success the result owns the data.
            var prepared = column_preparation.prepareColumnsForCommitOwnedForBackend(
                B,
                self.allocator,
                owned_batch,
                log_blowup,
                if (batch_retain) CoefficientRetentionPolicy.always else CoefficientRetentionPolicy.never,
                &self.commitment_scheme.twiddle_cache,
                recorder,
            ) catch |err| {
                column_storage.freeOwnedColumnEvaluations(self.allocator, owned_batch);
                return err;
            };
            errdefer prepared.deinit(self.allocator);

            // Build sorted ColumnRef array for the streaming Merkle committer.
            const col_refs = try self.allocator.alloc([]const M31, prepared.columns.len);
            defer self.allocator.free(col_refs);
            for (prepared.columns, 0..) |col, i| {
                col_refs[i] = col.values;
            }
            const sorted = try MerkleProver.sortColumnsByLogSizeAsc(self.allocator, col_refs);
            defer self.allocator.free(sorted);

            // Pre-allocate space in retained lists before any ownership transfer.
            try self.retained_columns.ensureUnusedCapacity(self.allocator, prepared.columns.len);
            try self.retained_column_indices.ensureUnusedCapacity(self.allocator, prepared.columns.len);
            if (prepared.coefficients) |coeffs| {
                try self.retained_coefficients.ensureUnusedCapacity(self.allocator, coeffs.len);
            }

            // Feed into streaming Merkle leaf layer.
            try self.streaming_committer.addColumns(sorted);

            // From here, all operations are guaranteed not to fail (no try).
            // Retain extended columns (needed for decommitment and quotient evaluation).
            for (prepared.columns, original_indices) |col, original_index| {
                self.retained_columns.appendAssumeCapacity(col);
                self.retained_column_indices.appendAssumeCapacity(original_index);
            }

            // Retain coefficients if needed.
            if (prepared.coefficients) |coeffs| {
                for (coeffs) |coeff| {
                    self.retained_coefficients.appendAssumeCapacity(coeff);
                }
                self.allocator.free(coeffs);
            }

            // The prepared.columns outer slice was consumed into retained_columns
            // element-by-element.  Free only the outer allocation.
            self.allocator.free(prepared.columns);
        }

        /// Finalize the streaming commitment: build the full Merkle tree from
        /// the accumulated leaf hashes, create a `CommitmentTreeProver`, mix
        /// the root into the channel, and append the tree to the commitment
        /// scheme.
        pub fn commit(self: *Self, channel: anytype) !void {
            // Finalize the Merkle tree.
            var merkle = try self.streaming_committer.finalize();
            // streaming_committer is now consumed; reinitialize to safe state for deinit.
            self.streaming_committer = MerkleProver.StreamingCommitter.init(self.allocator);
            errdefer merkle.deinit(self.allocator);

            const original_indices = try self.retained_column_indices.toOwnedSlice(self.allocator);
            self.retained_column_indices = std.ArrayList(usize).empty;
            defer self.allocator.free(original_indices);

            // Assemble the retained columns and coefficients into original PCS order.
            const columns = blk: {
                const streamed = try self.retained_columns.toOwnedSlice(self.allocator);
                self.retained_columns = std.ArrayList(ColumnEvaluation).empty;
                errdefer column_storage.freeOwnedColumnEvaluations(self.allocator, streamed);

                const ordered = try self.allocator.alloc(ColumnEvaluation, streamed.len);
                for (streamed, original_indices) |column, original_index| {
                    ordered[original_index] = column;
                }
                self.allocator.free(streamed);
                break :blk ordered;
            };
            errdefer column_storage.freeOwnedColumnEvaluations(self.allocator, columns);

            var coefficients: ?[]prover_circle.CircleCoefficients = null;
            errdefer if (coefficients) |owned| column_storage.deinitOwnedCoefficientColumns(self.allocator, owned);
            if (self.retained_coefficients.items.len > 0) {
                const streamed_coefficients = try self.retained_coefficients.toOwnedSlice(self.allocator);
                self.retained_coefficients = std.ArrayList(prover_circle.CircleCoefficients).empty;
                errdefer column_storage.deinitOwnedCoefficientColumns(self.allocator, streamed_coefficients);
                if (streamed_coefficients.len == columns.len) {
                    const ordered_coefficients = try self.allocator.alloc(
                        prover_circle.CircleCoefficients,
                        streamed_coefficients.len,
                    );
                    for (streamed_coefficients, original_indices) |coefficient, original_index| {
                        ordered_coefficients[original_index] = coefficient;
                    }
                    self.allocator.free(streamed_coefficients);
                    coefficients = ordered_coefficients;
                } else {
                    coefficients = streamed_coefficients;
                }
            }

            const BackendCommitmentTree = commitment_tree.CommitmentTreeProverForBackend(B, H);
            const tree = BackendCommitmentTree{
                .columns = columns,
                .coefficients = coefficients,
                .commitment = try adoptStreamingCommitment(B, H, merkle),
            };
            try self.commitment_scheme.appendCommittedTree(self.allocator, tree, channel);
        }
    };
}

fn grind(channel: anytype, pow_bits: u32) u64 {
    // Use the channel's optimized grind method if available (prefix caching + SIMD path).
    if (@hasDecl(@TypeOf(channel.*), "grind")) {
        return channel.grind(pow_bits);
    }
    // Fallback: per-nonce verification without caching.
    var nonce: u64 = 0;
    while (true) : (nonce += 1) {
        if (channel.verifyPowNonce(pow_bits, nonce)) return nonce;
    }
}
