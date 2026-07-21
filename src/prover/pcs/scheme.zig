//! Stateful PCS commitment, opening, and proof orchestration.

const std = @import("std");
const backend_merkle = @import("stwo_backend_contracts").merkle_ops;
const circle = @import("stwo_core").circle;
const m31 = @import("stwo_core").fields.m31;
const qm31 = @import("stwo_core").fields.qm31;
const pcs_core = @import("stwo_core").pcs;
const pcs_utils = @import("stwo_core").pcs.utils;
const verifier_types = @import("stwo_core").verifier_types;
const vcs_verifier = @import("stwo_core").vcs_lifted.verifier;
const canonic = @import("stwo_core").poly.circle.canonic;
const component_prover = @import("../air/component_prover.zig");
const prover_circle = @import("../poly/circle/mod.zig");
const twiddle_source_mod = @import("../poly/twiddle_source.zig");
const stage_profile = @import("../stage_profile.zig");
const prover_fri = @import("../fri.zig");
const commitment_tree = @import("commitment_tree.zig");
const circle_transforms = @import("columns/circle_transforms.zig");
const column_preparation = @import("columns/preparation.zig");
const column_storage = @import("columns/storage.zig");
const pow_search = @import("proof_of_work.zig");
const sampled_value_transcript = @import("sampled_value_transcript.zig");
const sampled_value_evaluation = @import("sampled_values.zig");
const tree_builders = @import("tree_builders.zig");

pub const quotient_ops = @import("quotient_ops.zig");

const M31 = m31.M31;
const QM31 = qm31.QM31;
const CirclePointQM31 = circle.CirclePointQM31;
const PcsConfig = pcs_core.PcsConfig;
const TreeVec = pcs_core.TreeVec;
const PREPROCESSED_TRACE_IDX = verifier_types.PREPROCESSED_TRACE_IDX;
const TwiddleSource = twiddle_source_mod.TwiddleSource;
const M31TwiddleTower = @import("../poly/twiddle_tower.zig").M31TwiddleTower;

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
        twiddle_source: TwiddleSource,
        /// A first-tree commit whose build was deferred to a worker thread.
        /// Resolved (joined, appended, root-mixed) before any later tree is
        /// appended or the transcript is otherwise consumed, preserving the
        /// exact mix order of the sequential path.
        pending_commit: ?PendingCommit,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, config: PcsConfig) !Self {
            return initWithTwiddleSource(config, TwiddleSource.initOwned(allocator));
        }
        pub fn initWithTwiddleTower(config: PcsConfig, tower: *const M31TwiddleTower) Self {
            return initWithTwiddleSource(config, TwiddleSource.initBorrowed(tower));
        }
        fn initWithTwiddleSource(config: PcsConfig, twiddle_source: TwiddleSource) Self {
            return .{
                .trees = .{},
                .config = config,
                .coefficient_retention_policy = .always,
                .twiddle_source = twiddle_source,
                .pending_commit = null,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.discardPending(allocator);
            for (self.trees.items) |*tree| tree.deinit(allocator);
            self.trees.deinit(allocator);
            self.twiddle_source.deinit(allocator);
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
                &self.twiddle_source,
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

            // First-tree deferral: the tree's contents are channel-independent
            // and only its root MIX is order-bound, so the whole build can
            // overlap the next commit's build. The deferred mix is replayed
            // (in original order) before any later tree is appended.
            if (canDeferFirstTree(self, owned_columns)) {
                if (self.trySpawnDeferredCommit(allocator, owned_columns)) return;
            }

            errdefer column_storage.freeOwnedColumnEvaluations(allocator, owned_columns);
            var prepared = try column_preparation.prepareColumnsForCommitOwnedForBackend(
                B,
                allocator,
                owned_columns,
                self.config.fri_config.log_blowup_factor,
                self.coefficient_retention_policy,
                &self.twiddle_source,
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

        const PendingCommit = struct {
            thread: std.Thread,
            slot: *Slot,

            const Slot = struct {
                tree: ?BackendCommitmentTree = null,
                err: ?anyerror = null,
            };
        };

        /// Deferral applies only to the very first committed tree, off the
        /// single-threaded build, for non-trivial non-constant column sets,
        /// and only when the twiddle source is a borrowed (read-only,
        /// pre-built) tower so the worker thread never mutates shared cache
        /// state. All other cases keep the exact sequential path.
        fn canDeferFirstTree(self: *Self, owned_columns: []const ColumnEvaluation) bool {
            if (comptime @import("builtin").single_threaded) return false;
            if (self.pending_commit != null) return false;
            if (self.trees.items.len != 0) return false;
            if (owned_columns.len == 0) return false;
            if (!self.twiddle_source.isBorrowed()) return false;
            return true;
        }

        fn trySpawnDeferredCommit(
            self: *Self,
            allocator: std.mem.Allocator,
            owned_columns: []ColumnEvaluation,
        ) bool {
            const slot = allocator.create(PendingCommit.Slot) catch return false;
            slot.* = .{};
            const thread = std.Thread.spawn(
                .{},
                deferredCommitWorker,
                .{ self, allocator, owned_columns, slot },
            ) catch {
                allocator.destroy(slot);
                return false;
            };
            self.pending_commit = .{ .thread = thread, .slot = slot };
            return true;
        }

        fn deferredCommitWorker(
            self: *Self,
            allocator: std.mem.Allocator,
            owned_columns: []ColumnEvaluation,
            slot: *PendingCommit.Slot,
        ) void {
            var prepared = column_preparation.prepareColumnsForCommitOwnedForBackend(
                B,
                allocator,
                owned_columns,
                self.config.fri_config.log_blowup_factor,
                self.coefficient_retention_policy,
                &self.twiddle_source,
                null,
            ) catch |err| {
                column_storage.freeOwnedColumnEvaluations(allocator, owned_columns);
                slot.err = err;
                return;
            };
            const tree = BackendCommitmentTree.initOwnedWithBacking(
                allocator,
                prepared.columns,
                prepared.coefficients,
                prepared.column_backing_buffers,
                prepared.coefficient_backing_buffers,
            ) catch |err| {
                prepared.deinit(allocator);
                slot.err = err;
                return;
            };
            slot.tree = tree;
        }

        /// Joins a deferred first-tree build and replays its root mix. Must
        /// run before any later tree is appended and before the scheme's
        /// trees or transcript are consumed.
        pub fn resolvePending(self: *Self, allocator: std.mem.Allocator, channel: anytype) anyerror!void {
            const pending = self.pending_commit orelse return;
            self.pending_commit = null;
            pending.thread.join();
            const slot = pending.slot;
            defer allocator.destroy(slot);
            if (slot.err) |err| return err;
            var tree = slot.tree.?;
            errdefer tree.deinit(allocator);
            try self.appendCommittedTree(allocator, tree, channel);
        }

        /// Abort path: join and discard a deferred build without mixing.
        fn discardPending(self: *Self, allocator: std.mem.Allocator) void {
            const pending = self.pending_commit orelse return;
            self.pending_commit = null;
            pending.thread.join();
            if (pending.slot.tree) |*tree| tree.deinit(allocator);
            allocator.destroy(pending.slot);
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
                &self.twiddle_source,
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

            // Each batch moves entries out of `owned_columns`; the builder owns
            // consumed entries and the error paths below free the remainder.
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

                tree_builders.addColumnsOwnedIndexed(
                    &builder,
                    batch,
                    order[consumed..end],
                    recorder,
                ) catch |err| {
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

            var merkle_commit_stage = try stage_profile.StageScope.begin(
                recorder,
                "merkle_commit",
                "Merkle commit",
            );
            defer merkle_commit_stage.end();
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
                        .coefficients = if (tree.coefficients) |coefficients|
                            try prover_circle.CircleCoefficients.initBorrowed(
                                coefficients[col_idx].coefficients(),
                            )
                        else
                            null,
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
            var owns_scheme = true;
            errdefer if (owns_scheme) scheme.deinit(allocator);

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

            // The downstream method consumes the scheme on both success and error.
            owns_scheme = false;
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
                const nonce = pow_search.grind(channel, scheme.config.pow_bits);
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
            return tree_builders.appendCommittedTree(MC, self, allocator, tree, channel);
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
    return tree_builders.TreeBuilder(B, H, MC, CommitmentSchemeProver(B, H, MC));
}

pub fn StreamingTreeBuilder(comptime B: type, comptime H: type, comptime MC: type) type {
    return tree_builders.StreamingTreeBuilder(B, H, MC, CommitmentSchemeProver(B, H, MC));
}
