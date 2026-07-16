const std = @import("std");
const air_accumulation = @import("../../../core/air/accumulation.zig");
const air_components = @import("../../../core/air/components.zig");
const circle = @import("../../../core/circle.zig");
const constraints = @import("../../../core/constraints.zig");
const channel_blake2s = @import("../../../core/channel/blake2s.zig");
const fri = @import("../../../core/fri.zig");
const m31 = @import("../../../core/fields/m31.zig");
const qm31 = @import("../../../core/fields/qm31.zig");
const pcs = @import("../../../core/pcs/mod.zig");
const pcs_verifier = @import("../../../core/pcs/verifier.zig");
const line = @import("../../../core/poly/line.zig");
const canonic = @import("../../../core/poly/circle/canonic.zig");
const proof_mod = @import("../../../core/proof.zig");
const core_verifier = @import("../../../core/verifier.zig");
const blake2_merkle = @import("../../../core/vcs_lifted/blake2_merkle.zig");
const vcs_verifier = @import("../../../core/vcs_lifted/verifier.zig");
const composition_bundle = @import("composition_bundle.zig");
const eval_program = @import("eval_program.zig");
const proof_bundle = @import("proof_bundle.zig");

const M31 = m31.M31;
const QM31 = qm31.QM31;
const Point = circle.CirclePointQM31;

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

/// Replays the direct Cairo transcript and runs the generic AIR/PCS/FRI
/// verifier. Success is the only state a caller may expose as `verified`.
pub fn verify(allocator: std.mem.Allocator, input: VerifyInput) !void {
    if (input.tree_logs[0].len == 0 or input.tree_logs[1].len == 0 or
        input.tree_logs[2].len == 0 or input.composition.components.len == 0)
        return Error.InvalidTraceShape;
    const config_words = transcriptWords(input.transcript_inputs, 2) orelse
        return Error.InvalidProofShape;
    const expected_config = [_]u32{ sn2_pow_bits, 1, sn2_query_count, 0, sn2_fold_step, 0, 0, 0 };
    if (!std.mem.eql(u32, config_words, &expected_config)) return Error.InvalidProofShape;

    const commitment_words = input.bundle.words[input.bundle.layout.commitments.start..input.bundle.layout.commitments.end];
    if (!hashWordsEqual(transcriptWords(input.transcript_inputs, 3), commitment_words[0..8]) or
        !hashWordsEqual(transcriptWords(input.transcript_inputs, 20), commitment_words[8..16]))
        return Error.InvalidProofShape;

    var channel = Channel{};
    for ([_]u32{ 1, 2, 3, 10, 11, 12, 13, 14, 15, 16, 20 }) |ordinal| {
        channel.mixU32s(transcriptWords(input.transcript_inputs, ordinal) orelse
            return Error.InvalidProofShape);
    }
    if (!channel.verifyPowNonce(sn2_interaction_pow_bits, input.bundle.interactionNonce()))
        return error.ProofOfWork;
    channel.mixU64(input.bundle.interactionNonce());
    const lookup_challenges = try channel.drawSecureFelts(allocator, 2);
    defer allocator.free(lookup_challenges);
    const lookup_z = lookup_challenges[0];
    const lookup_alpha = lookup_challenges[1];

    const claim_words = input.bundle.words[input.bundle.layout.interaction_claim.start..input.bundle.layout.interaction_claim.end];
    if (claim_words.len != input.composition.components.len * 4)
        return Error.InvalidComponentShape;
    var base_cursor: usize = 0;
    var interaction_cursor: usize = 0;
    for (input.composition.components) |component| {
        const base_span = try componentSpan(component, 1);
        const interaction_span = try componentSpan(component, 2);
        if (base_span.start != base_cursor or interaction_span.start != interaction_cursor)
            return Error.InvalidComponentShape;
        base_cursor = base_span.end;
        interaction_cursor = interaction_span.end;
    }
    if (base_cursor != input.tree_logs[1].len or interaction_cursor != input.tree_logs[2].len)
        return Error.InvalidComponentShape;
    channel.mixU32s(claim_words);
    channel.mixU32s(commitment_words[16..24]);

    var diagnostic_point: ?Point = null;
    if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_VERIFIER_ACCUMULATORS")) {
        var diagnostic_channel = channel;
        const random_coefficient = diagnostic_channel.drawSecureFelt();
        var composition_root: Hasher.Hash = undefined;
        @memcpy(&composition_root, std.mem.sliceAsBytes(commitment_words[24..32]));
        MerkleChannel.mixRoot(&diagnostic_channel, composition_root);
        const parameter = diagnostic_channel.drawSecureFelt();
        const parameter_square = parameter.square();
        const denominator = parameter_square.add(QM31.one()).inv() catch unreachable;
        diagnostic_point = .{
            .x = QM31.one().sub(parameter_square).mul(denominator),
            .y = parameter.add(parameter).mul(denominator),
        };
        std.debug.print(
            "verifier_transcript random_coefficient={any} oods_parameter={any} oods_x={any} oods_y={any}\n",
            .{
                qm31Words(random_coefficient),
                qm31Words(parameter),
                qm31Words(diagnostic_point.?.x),
                qm31Words(diagnostic_point.?.y),
            },
        );
    }

    const runtime_components = try allocator.alloc(RuntimeComponent, input.composition.components.len);
    defer allocator.free(runtime_components);
    const verifier_components = try allocator.alloc(air_components.Component, runtime_components.len);
    defer allocator.free(verifier_components);
    for (runtime_components, verifier_components, 0..) |*runtime, *component, index| {
        runtime.* = .{
            .allocator = allocator,
            .captured = &input.composition.components[index],
            .preprocessed_logs = input.tree_logs[0],
            .lifting_log_size = input.composition.max_evaluation_log_size,
            .lookup_z = lookup_z,
            .lookup_alpha = lookup_alpha,
            .claimed_sum = try qm31FromWords(claim_words[index * 4 ..][0..4]),
        };
        component.* = runtime.asComponent();
    }

    const shape = try sampleShape(allocator, input.composition, .{
        input.tree_logs[0].len,
        input.tree_logs[1].len,
        input.tree_logs[2].len,
    });
    defer freeSampleShape(allocator, shape);
    var proof = try decodeProof(allocator, input.bundle, .{ .trees = shape });
    var proof_moved = false;
    defer if (!proof_moved) proof.deinit(allocator);
    if (diagnostic_point) |point| {
        const expected = proof.extractCompositionOodsEval(
            point,
            input.composition.max_evaluation_log_size,
        ) orelse return Error.InvalidProofShape;
        std.debug.print("verifier_composition expected={any}\n", .{qm31Words(expected)});
    }

    const config = proof.commitment_scheme_proof.config;
    var commitment_scheme = try pcs_verifier.CommitmentSchemeVerifier(Hasher, MerkleChannel).init(
        allocator,
        config,
    );
    defer commitment_scheme.deinit(allocator);
    commitment_scheme.trees.deinit(allocator);
    const trees = try allocator.alloc(vcs_verifier.MerkleVerifierLifted(Hasher), 3);
    var initialized: usize = 0;
    var trees_moved = false;
    errdefer if (!trees_moved) {
        for (trees[0..initialized]) |*tree| tree.deinit(allocator);
        allocator.free(trees);
    };
    for (trees, input.tree_logs, 0..) |*tree, logs, tree_index| {
        const extended = try allocator.alloc(u32, logs.len);
        defer allocator.free(extended);
        for (logs, extended) |log_size, *value| value.* = log_size + config.fri_config.log_blowup_factor;
        var root: Hasher.Hash = undefined;
        @memcpy(
            &root,
            std.mem.sliceAsBytes(commitment_words[tree_index * proof_bundle.hash_words ..][0..proof_bundle.hash_words]),
        );
        tree.* = try vcs_verifier.MerkleVerifierLifted(Hasher).init(allocator, root, extended);
        initialized += 1;
    }
    commitment_scheme.trees = pcs.TreeVec(vcs_verifier.MerkleVerifierLifted(Hasher)).initOwned(trees);
    trees_moved = true;
    initialized = 0;

    proof_moved = true;
    if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_VERIFIER_DECOMMIT")) {
        std.debug.print("verifier_bundle_raw_queries={any}\n", .{input.bundle.decommitment.raw_queries});
        std.debug.print("verifier_bundle_unique_queries={any}\n", .{input.bundle.decommitment.unique_queries});
        for (input.bundle.decommitment.trees, 0..) |tree, index| {
            std.debug.print(
                "verifier_bundle_tree index={} role={} query_count={} value_count={} hash_count={} leaf_log={}\n",
                .{ index, tree.role, tree.query_count, tree.values_count, tree.hash_witness_count, tree.leaf_log_size },
            );
        }
    }
    try core_verifier.verify(
        Hasher,
        MerkleChannel,
        allocator,
        verifier_components,
        &channel,
        &commitment_scheme,
        proof,
    );
}

fn transcriptWords(inputs: []const TranscriptInput, ordinal: u32) ?[]const u32 {
    for (inputs) |input| if (input.ordinal == ordinal) return input.words;
    return null;
}

fn hashWordsEqual(candidate: ?[]const u32, expected: []const u32) bool {
    const words = candidate orelse return false;
    return words.len == proof_bundle.hash_words and std.mem.eql(u32, words, expected);
}

/// Converts the compact resident SN2 serialization into the verifier's owned
/// generic proof type. AIR sample cardinalities are deliberately supplied by
/// the caller: they are statement metadata and must not be inferred from the
/// untrusted flattened sample payload.
pub fn decodeProof(
    allocator: std.mem.Allocator,
    bundle: proof_bundle.ProofBundle,
    sample_shape: SampleShape,
) !Proof {
    if (sample_shape.trees.len != 4 or bundle.decommitment.trees.len != 12)
        return Error.InvalidProofShape;

    const commitments = try decodeCommitments(allocator, bundle);
    errdefer allocator.free(commitments);
    const sampled_values = try decodeSampledValues(allocator, bundle, sample_shape);
    errdefer {
        var values = sampled_values;
        values.deinitDeep(allocator);
    }
    const trace = try decodeTraceOpenings(allocator, bundle);
    errdefer {
        var decommitments = trace.decommitments;
        for (decommitments.items) |*decommitment| decommitment.deinit(allocator);
        decommitments.deinit(allocator);
        var queried_values = trace.queried_values;
        queried_values.deinitDeep(allocator);
    }
    const fri_proof = try decodeFriProof(allocator, bundle);
    errdefer {
        var proof = fri_proof;
        proof.deinit(allocator);
    }

    var fri_config = try fri.FriConfig.init(0, 1, sn2_query_count);
    fri_config.fold_step = sn2_fold_step;
    return .{
        .commitment_scheme_proof = .{
            .config = .{
                .pow_bits = sn2_pow_bits,
                .fri_config = fri_config,
                .lifting_log_size = null,
            },
            .commitments = pcs.TreeVec(Hasher.Hash).initOwned(commitments),
            .sampled_values = sampled_values,
            .decommitments = trace.decommitments,
            .queried_values = trace.queried_values,
            .proof_of_work = bundle.queryNonce(),
            .fri_proof = fri_proof,
        },
    };
}

const TraceOpenings = struct {
    decommitments: pcs.TreeVec(vcs_verifier.MerkleDecommitmentLifted(Hasher)),
    queried_values: pcs.TreeVec([][]M31),
};

fn decodeCommitments(allocator: std.mem.Allocator, bundle: proof_bundle.ProofBundle) ![]Hasher.Hash {
    const words = bundle.words[bundle.layout.commitments.start..bundle.layout.commitments.end];
    if (words.len != 4 * proof_bundle.hash_words) return Error.InvalidProofShape;
    const out = try allocator.alloc(Hasher.Hash, 4);
    for (out, 0..) |*hash, index| {
        @memcpy(hash, std.mem.sliceAsBytes(words[index * proof_bundle.hash_words ..][0..proof_bundle.hash_words]));
    }
    return out;
}

fn decodeSampledValues(
    allocator: std.mem.Allocator,
    bundle: proof_bundle.ProofBundle,
    shape: SampleShape,
) !pcs.TreeVec([][]QM31) {
    const words = bundle.words[bundle.layout.sampled_values.start..bundle.layout.sampled_values.end];
    if (words.len % 4 != 0) return Error.InvalidSampleShape;
    var expected: usize = 0;
    for (shape.trees) |tree| for (tree) |count| {
        expected = std.math.add(usize, expected, count) catch return Error.InvalidSampleShape;
    };
    if (expected * 4 != words.len) return Error.InvalidSampleShape;

    const trees = try allocator.alloc([][]QM31, shape.trees.len);
    errdefer allocator.free(trees);
    var initialized: usize = 0;
    errdefer for (trees[0..initialized]) |tree| freeQm31Tree(allocator, tree);
    var cursor: usize = 0;
    for (shape.trees, 0..) |tree_shape, tree_index| {
        const columns = try allocator.alloc([]QM31, tree_shape.len);
        errdefer allocator.free(columns);
        var columns_initialized: usize = 0;
        errdefer for (columns[0..columns_initialized]) |column| allocator.free(column);
        for (tree_shape, columns) |count, *column| {
            column.* = try allocator.alloc(QM31, count);
            for (column.*) |*value| {
                value.* = try qm31FromWords(words[cursor..][0..4]);
                cursor += 4;
            }
            columns_initialized += 1;
        }
        trees[tree_index] = columns;
        initialized += 1;
    }
    return pcs.TreeVec([][]QM31).initOwned(trees);
}

fn decodeTraceOpenings(allocator: std.mem.Allocator, bundle: proof_bundle.ProofBundle) !TraceOpenings {
    const decommitments = try allocator.alloc(vcs_verifier.MerkleDecommitmentLifted(Hasher), 4);
    errdefer allocator.free(decommitments);
    const queried_values = try allocator.alloc([][]M31, 4);
    errdefer allocator.free(queried_values);
    var initialized: usize = 0;
    errdefer {
        for (decommitments[0..initialized]) |*decommitment| decommitment.deinit(allocator);
        for (queried_values[0..initialized]) |tree| freeM31Tree(allocator, tree);
    }

    for (0..4) |tree_index| {
        const meta = bundle.decommitment.trees[tree_index];
        if (meta.kind != 0 or meta.role != tree_index or meta.query_count == 0 or
            meta.values_count % meta.query_count != 0 or meta.fri_witness_count != 0)
            return Error.InvalidTraceShape;
        const column_count = meta.values_count / meta.query_count;
        const values_words = treeWords(bundle, meta.values_offset, meta.values_count) catch
            return Error.InvalidTraceShape;
        const columns = try allocator.alloc([]M31, column_count);
        errdefer allocator.free(columns);
        var columns_initialized: usize = 0;
        errdefer for (columns[0..columns_initialized]) |column| allocator.free(column);
        for (columns, 0..) |*column, column_index| {
            column.* = try allocator.alloc(M31, meta.query_count);
            for (column.*, 0..) |*value, query_index| {
                value.* = try m31FromWord(values_words[column_index * meta.query_count + query_index]);
            }
            columns_initialized += 1;
        }
        queried_values[tree_index] = columns;
        decommitments[tree_index] = .{
            .hash_witness = try decodeHashes(allocator, bundle, meta.hash_witness_offset, meta.hash_witness_count),
        };
        initialized += 1;
    }

    return .{
        .decommitments = pcs.TreeVec(vcs_verifier.MerkleDecommitmentLifted(Hasher)).initOwned(decommitments),
        .queried_values = pcs.TreeVec([][]M31).initOwned(queried_values),
    };
}

fn decodeFriProof(allocator: std.mem.Allocator, bundle: proof_bundle.ProofBundle) !fri.FriProof(Hasher) {
    const layers = try allocator.alloc(fri.FriLayerProof(Hasher), 8);
    defer allocator.free(layers);
    var initialized: usize = 0;
    errdefer for (layers[0..initialized]) |*layer| layer.deinit(allocator);
    const roots = bundle.words[bundle.layout.fri_commitments.start..bundle.layout.fri_commitments.end];
    if (roots.len != 8 * proof_bundle.hash_words) return Error.InvalidFriShape;

    for (0..8) |round| {
        const meta = bundle.decommitment.trees[4 + round];
        if (meta.kind != 1 or meta.role != 4 + round or meta.values_count != 0)
            return Error.InvalidFriShape;
        const witness_words = treeWords(
            bundle,
            meta.fri_witness_offset,
            meta.fri_witness_count * 4,
        ) catch return Error.InvalidFriShape;
        const witness = try allocator.alloc(QM31, meta.fri_witness_count);
        errdefer allocator.free(witness);
        for (witness, 0..) |*value, index| value.* = try qm31FromWords(witness_words[index * 4 ..][0..4]);
        var commitment: Hasher.Hash = undefined;
        @memcpy(
            &commitment,
            std.mem.sliceAsBytes(roots[round * proof_bundle.hash_words ..][0..proof_bundle.hash_words]),
        );
        layers[round] = .{
            .fri_witness = witness,
            .decommitment = .{
                .hash_witness = try decodeHashes(
                    allocator,
                    bundle,
                    meta.hash_witness_offset,
                    meta.hash_witness_count,
                ),
            },
            .commitment = commitment,
        };
        initialized += 1;
    }

    const inner = try allocator.alloc(fri.FriLayerProof(Hasher), 7);
    errdefer allocator.free(inner);
    @memcpy(inner, layers[1..8]);
    const final_words = bundle.words[bundle.layout.final_line_poly.start..bundle.layout.final_line_poly.end];
    if (final_words.len % 4 != 0) return Error.InvalidFriShape;
    const coefficients = try allocator.alloc(QM31, final_words.len / 4);
    errdefer allocator.free(coefficients);
    for (coefficients, 0..) |*coefficient, index| {
        coefficient.* = try qm31FromWords(final_words[index * 4 ..][0..4]);
    }
    initialized = 0;
    return .{
        .first_layer = layers[0],
        .inner_layers = inner,
        .last_layer_poly = line.LinePoly.initOwned(coefficients),
    };
}

fn decodeHashes(
    allocator: std.mem.Allocator,
    bundle: proof_bundle.ProofBundle,
    offset: usize,
    count: usize,
) ![]Hasher.Hash {
    const words = treeWords(bundle, offset, count * proof_bundle.hash_words) catch
        return Error.InvalidProofShape;
    const hashes = try allocator.alloc(Hasher.Hash, count);
    for (hashes, 0..) |*hash, index| {
        @memcpy(hash, std.mem.sliceAsBytes(words[index * proof_bundle.hash_words ..][0..proof_bundle.hash_words]));
    }
    return hashes;
}

fn treeWords(bundle: proof_bundle.ProofBundle, offset: usize, count: usize) ![]const u32 {
    const words = bundle.decommitment.words;
    const end = std.math.add(usize, offset, count) catch return Error.InvalidProofShape;
    if (end > words.len) return Error.InvalidProofShape;
    return words[offset..end];
}

fn m31FromWord(word: u32) Error!M31 {
    if (word >= m31.Modulus) return Error.NonCanonicalM31;
    return M31.fromCanonical(word);
}

fn qm31FromWords(words: []const u32) Error!QM31 {
    if (words.len != 4) return Error.InvalidProofShape;
    return QM31.fromM31(
        try m31FromWord(words[0]),
        try m31FromWord(words[1]),
        try m31FromWord(words[2]),
        try m31FromWord(words[3]),
    );
}

fn qm31Words(value: QM31) [4]u32 {
    const coordinates = value.toM31Array();
    return .{ coordinates[0].v, coordinates[1].v, coordinates[2].v, coordinates[3].v };
}

fn freeQm31Tree(allocator: std.mem.Allocator, tree: [][]QM31) void {
    for (tree) |column| allocator.free(column);
    allocator.free(tree);
}

fn freeM31Tree(allocator: std.mem.Allocator, tree: [][]M31) void {
    for (tree) |column| allocator.free(column);
    allocator.free(tree);
}

/// Verifier-side wrapper for one captured Cairo AIR component. The captured
/// eval program is the protocol artifact used by the Metal prover; interpreting
/// the same operations on OODS samples avoids maintaining a second AIR model.
pub const RuntimeComponent = struct {
    allocator: std.mem.Allocator,
    captured: *const composition_bundle.Component,
    preprocessed_logs: []const u32,
    lifting_log_size: u32,
    lookup_z: QM31,
    lookup_alpha: QM31,
    claimed_sum: QM31,

    pub fn asComponent(self: *const RuntimeComponent) air_components.Component {
        return .{
            .ctx = self,
            .vtable = &.{
                .nConstraints = nConstraints,
                .maxConstraintLogDegreeBound = maxConstraintLogDegreeBound,
                .traceLogDegreeBounds = traceLogDegreeBounds,
                .maskPoints = maskPoints,
                .preprocessedColumnIndices = preprocessedColumnIndices,
                .evaluateConstraintQuotientsAtPoint = evaluateConstraintQuotientsAtPoint,
            },
        };
    }

    fn cast(ctx: *const anyopaque) *const RuntimeComponent {
        return @ptrCast(@alignCast(ctx));
    }

    fn nConstraints(ctx: *const anyopaque) usize {
        return cast(ctx).captured.n_constraints;
    }

    fn maxConstraintLogDegreeBound(ctx: *const anyopaque) u32 {
        return cast(ctx).captured.evaluation_log_size;
    }

    fn traceLogDegreeBounds(
        ctx: *const anyopaque,
        allocator: std.mem.Allocator,
    ) !air_components.TraceLogDegreeBounds {
        const self = cast(ctx);
        const component = self.captured;
        const preprocessed = try allocator.alloc(u32, component.preprocessed_indices.len);
        errdefer allocator.free(preprocessed);
        for (component.preprocessed_indices, preprocessed) |index, *log_size| {
            if (index >= self.preprocessed_logs.len) return Error.InvalidComponentShape;
            log_size.* = self.preprocessed_logs[index];
        }
        const base = try allocator.alloc(u32, try spanLength(component.*, 1));
        errdefer allocator.free(base);
        @memset(base, component.trace_log_size);
        const interaction = try allocator.alloc(u32, try spanLength(component.*, 2));
        errdefer allocator.free(interaction);
        @memset(interaction, component.trace_log_size);
        return air_components.TraceLogDegreeBounds.initOwned(
            try allocator.dupe([]u32, &[_][]u32{ preprocessed, base, interaction }),
        );
    }

    fn maskPoints(
        ctx: *const anyopaque,
        allocator: std.mem.Allocator,
        point: Point,
        max_log_degree_bound: u32,
    ) !air_components.MaskPoints {
        const self = cast(ctx);
        try validateMaximumDegreeLog(self.lifting_log_size, max_log_degree_bound);
        const component = self.captured;
        const preprocessed = try allocator.alloc([]Point, component.preprocessed_indices.len);
        errdefer allocator.free(preprocessed);
        var pp_initialized: usize = 0;
        errdefer for (preprocessed[0..pp_initialized]) |column| allocator.free(column);
        for (preprocessed) |*column| {
            column.* = try allocator.alloc(Point, 0);
            pp_initialized += 1;
        }

        const base_offsets = try componentOffsets(allocator, component.*, 1);
        defer freeOffsetLists(allocator, base_offsets);
        const interaction_offsets = try componentOffsets(allocator, component.*, 2);
        defer freeOffsetLists(allocator, interaction_offsets);
        const trace_step_m31 = canonic.CanonicCoset.new(max_log_degree_bound).step();
        const trace_step = Point{
            .x = QM31.fromBase(trace_step_m31.x),
            .y = QM31.fromBase(trace_step_m31.y),
        };
        const base = try pointsFromOffsets(allocator, base_offsets, point, trace_step);
        errdefer freePointTree(allocator, base);
        const interaction = try pointsFromOffsets(allocator, interaction_offsets, point, trace_step);
        errdefer freePointTree(allocator, interaction);
        return air_components.MaskPoints.initOwned(
            try allocator.dupe([][]Point, &[_][][]Point{ preprocessed, base, interaction }),
        );
    }

    fn preprocessedColumnIndices(
        ctx: *const anyopaque,
        allocator: std.mem.Allocator,
    ) ![]usize {
        const indices = cast(ctx).captured.preprocessed_indices;
        const out = try allocator.alloc(usize, indices.len);
        for (indices, out) |index, *destination| destination.* = index;
        return out;
    }

    fn evaluateConstraintQuotientsAtPoint(
        ctx: *const anyopaque,
        point: Point,
        mask: *const air_components.MaskValues,
        accumulator: *air_accumulation.PointEvaluationAccumulator,
        max_log_degree_bound: u32,
    ) !void {
        const self = cast(ctx);
        try validateMaximumDegreeLog(self.lifting_log_size, max_log_degree_bound);
        const component = self.captured;
        const ext_params = try self.extParams();
        defer self.allocator.free(ext_params);
        const base_offsets = try componentOffsets(self.allocator, component.*, 1);
        defer freeOffsetLists(self.allocator, base_offsets);
        const interaction_offsets = try componentOffsets(self.allocator, component.*, 2);
        defer freeOffsetLists(self.allocator, interaction_offsets);
        const zeroifier = constraints.cosetVanishing(
            QM31,
            canonic.CanonicCoset.new(max_log_degree_bound).coset(),
            point,
        );
        const denominator_inverse = try zeroifier.inv();

        for (component.parts) |part| {
            try self.evaluateProgram(
                part.program,
                part.rc_base,
                mask,
                base_offsets,
                interaction_offsets,
                ext_params,
                denominator_inverse,
                accumulator,
            );
        }
        if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_VERIFIER_ACCUMULATORS")) {
            std.debug.print(
                "verifier_accumulator component={s} instance={} constraint_end={} cumulative={any}\n",
                .{
                    component.label,
                    component.instance,
                    component.random_coefficient_offset + component.n_constraints,
                    qm31Words(accumulator.finalize()),
                },
            );
        }
    }

    fn extParams(self: RuntimeComponent) ![]QM31 {
        const sources = self.captured.ext_sources;
        const out = try self.allocator.alloc(QM31, sources.len);
        const claimed_scale = try M31.fromCanonical(
            @as(u32, 1) << @intCast(self.captured.trace_log_size),
        ).inv();
        for (sources, out) |source, *value| value.* = switch (source) {
            .constant => |words| try qm31FromWords(&words),
            .lookup_z => self.lookup_z,
            .lookup_alpha_power => |power| self.lookup_alpha.pow(power),
            .lookup_alpha_power_scaled => |scaled| self.lookup_alpha
                .pow(scaled.power)
                .mulM31(M31.fromCanonical(scaled.scale)),
            .claimed_sum_scaled => self.claimed_sum.mulM31(claimed_scale),
        };
        return out;
    }

    fn evaluateProgram(
        self: RuntimeComponent,
        program: eval_program.Program,
        constraint_base: u32,
        mask: *const air_components.MaskValues,
        base_offsets: []const std.ArrayList(i32),
        interaction_offsets: []const std.ArrayList(i32),
        ext_params: []const QM31,
        denominator_inverse: QM31,
        accumulator: *air_accumulation.PointEvaluationAccumulator,
    ) !void {
        if (program.header.n_base_params != 0 or program.header.n_ext_params != ext_params.len)
            return Error.InvalidProgram;
        // Base-column expressions are evaluated at the secure OODS point, so their
        // values live in QM31 even though the underlying trace columns are M31.
        const base = try self.allocator.alloc(QM31, program.header.max_base_regs);
        defer self.allocator.free(base);
        const extension = try self.allocator.alloc(QM31, program.header.max_ext_regs);
        defer self.allocator.free(extension);
        for (program.base_insts) |instruction| {
            base[instruction.dst] = switch (instruction.op) {
                .trace_col, .preprocessed_col => try self.traceValue(
                    mask,
                    base_offsets,
                    interaction_offsets,
                    instruction.interaction,
                    instruction.a,
                    instruction.imm,
                ),
                .param => return Error.InvalidProgram,
                .constant => QM31.fromBase(M31.fromCanonical(instruction.a)),
                .add => base[instruction.a].add(base[instruction.b]),
                .sub => base[instruction.a].sub(base[instruction.b]),
                .mul => base[instruction.a].mul(base[instruction.b]),
                .neg => base[instruction.a].neg(),
                .inv => try base[instruction.a].inv(),
            };
            if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_VERIFIER_LOGUP_INPUTS") and
                self.captured.random_coefficient_offset == 0 and instruction.op == .trace_col and
                instruction.interaction == 2)
            {
                std.debug.print(
                    "verifier_logup_base dst={} column={} offset={} value={any}\n",
                    .{ instruction.dst, instruction.a, instruction.imm, qm31Words(base[instruction.dst]) },
                );
            }
        }
        for (program.ext_insts) |instruction| {
            extension[instruction.dst] = switch (instruction.op) {
                .secure_col => QM31.fromPartialEvals(.{
                    base[instruction.a],
                    base[instruction.b],
                    base[instruction.c],
                    base[instruction.d],
                }),
                .param => ext_params[instruction.a],
                .constant => QM31.fromU32Unchecked(
                    instruction.a,
                    instruction.b,
                    instruction.c,
                    instruction.d,
                ),
                .add => extension[instruction.a].add(extension[instruction.b]),
                .sub => extension[instruction.a].sub(extension[instruction.b]),
                .mul => extension[instruction.a].mul(extension[instruction.b]),
                .neg => extension[instruction.a].neg(),
            };
            if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_VERIFIER_LOGUP_INPUTS") and
                self.captured.random_coefficient_offset == 0 and
                (instruction.op == .secure_col or instruction.op == .param))
            {
                std.debug.print(
                    "verifier_logup_ext op={s} dst={} slot={} value={any}\n",
                    .{ @tagName(instruction.op), instruction.dst, instruction.a, qm31Words(extension[instruction.dst]) },
                );
            }
        }
        for (program.constraint_roots, 0..) |root, root_index| {
            const evaluation = extension[root].mul(denominator_inverse);
            if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_VERIFIER_CONSTRAINTS")) {
                std.debug.print(
                    "verifier_constraint component={s} local={} evaluation={any}\n",
                    .{
                        self.captured.label,
                        constraint_base + root_index,
                        qm31Words(evaluation),
                    },
                );
            }
            accumulator.accumulate(evaluation);
        }
    }

    fn traceValue(
        self: RuntimeComponent,
        mask: *const air_components.MaskValues,
        base_offsets: []const std.ArrayList(i32),
        interaction_offsets: []const std.ArrayList(i32),
        interaction: u8,
        local_column: u32,
        offset: i32,
    ) !QM31 {
        const component = self.captured;
        const selection = switch (interaction) {
            0 => blk: {
                if (local_column >= component.preprocessed_indices.len or mask.items.len <= 0)
                    return Error.MissingMaskValue;
                const global = component.preprocessed_indices[local_column];
                if (global >= mask.items[0].len or mask.items[0][global].len != 1)
                    return Error.MissingMaskValue;
                break :blk mask.items[0][global][0];
            },
            1, 2 => blk: {
                const span = try componentSpan(component.*, interaction);
                const offsets = if (interaction == 1) base_offsets else interaction_offsets;
                if (local_column >= offsets.len) return Error.MissingMaskValue;
                const sample_index = offsetIndex(offsets[local_column].items, offset) orelse
                    return Error.MissingMaskValue;
                const global = span.start + local_column;
                if (interaction >= mask.items.len or global >= mask.items[interaction].len or
                    sample_index >= mask.items[interaction][global].len)
                    return Error.MissingMaskValue;
                break :blk mask.items[interaction][global][sample_index];
            },
            else => return Error.MissingMaskValue,
        };
        return selection;
    }
};

fn validateMaximumDegreeLog(lifting_log_size: u32, max_log_degree_bound: u32) !void {
    if (lifting_log_size == 0 or max_log_degree_bound != lifting_log_size - 1)
        return Error.InvalidComponentShape;
}

const Span = struct { start: usize, end: usize };

fn componentSpan(component: composition_bundle.Component, tree: u32) !Span {
    var found: ?Span = null;
    for (component.trace_spans) |span| {
        if (span.tree != tree) continue;
        if (found != null or span.start > span.end) return Error.InvalidComponentShape;
        found = .{ .start = span.start, .end = span.end };
    }
    return found orelse Error.InvalidComponentShape;
}

fn spanLength(component: composition_bundle.Component, tree: u32) !usize {
    const span = try componentSpan(component, tree);
    return span.end - span.start;
}

fn componentOffsets(
    allocator: std.mem.Allocator,
    component: composition_bundle.Component,
    tree: u32,
) ![]std.ArrayList(i32) {
    const offsets = try allocator.alloc(std.ArrayList(i32), try spanLength(component, tree));
    for (offsets) |*list| list.* = .empty;
    errdefer freeOffsetLists(allocator, offsets);
    for (component.parts) |part| for (part.program.base_insts) |instruction| {
        if (instruction.op != .trace_col or instruction.interaction != tree) continue;
        if (instruction.a >= offsets.len) return Error.InvalidComponentShape;
        var exists = false;
        for (offsets[instruction.a].items) |existing| exists = exists or existing == instruction.imm;
        if (!exists) try offsets[instruction.a].append(allocator, instruction.imm);
    };
    for (offsets) |list| if (list.items.len == 0) return Error.InvalidComponentShape;
    return offsets;
}

fn freeOffsetLists(allocator: std.mem.Allocator, lists: []std.ArrayList(i32)) void {
    for (lists) |*list| list.deinit(allocator);
    allocator.free(lists);
}

fn pointsFromOffsets(
    allocator: std.mem.Allocator,
    offsets: []const std.ArrayList(i32),
    point: Point,
    step: Point,
) ![][]Point {
    const columns = try allocator.alloc([]Point, offsets.len);
    errdefer allocator.free(columns);
    var initialized: usize = 0;
    errdefer for (columns[0..initialized]) |column| allocator.free(column);
    for (offsets, columns) |column_offsets, *column| {
        column.* = try allocator.alloc(Point, column_offsets.items.len);
        for (column_offsets.items, column.*) |offset, *sample_point| {
            sample_point.* = point.add(step.mulSigned(offset));
        }
        initialized += 1;
    }
    return columns;
}

fn freePointTree(allocator: std.mem.Allocator, tree: [][]Point) void {
    for (tree) |column| allocator.free(column);
    allocator.free(tree);
}

fn offsetIndex(offsets: []const i32, wanted: i32) ?usize {
    for (offsets, 0..) |offset, index| if (offset == wanted) return index;
    return null;
}

/// Derives the exact sampled-value tree shape from the captured programs.
/// The returned slices are owned and can be passed directly to `decodeProof`.
pub fn sampleShape(
    allocator: std.mem.Allocator,
    bundle: composition_bundle.Bundle,
    tree_column_counts: [3]usize,
) ![][]usize {
    const used_preprocessed = try allocator.alloc(bool, tree_column_counts[0]);
    defer allocator.free(used_preprocessed);
    @memset(used_preprocessed, false);
    const base_counts = try allocator.alloc(usize, tree_column_counts[1]);
    defer allocator.free(base_counts);
    @memset(base_counts, 0);
    const interaction_counts = try allocator.alloc(usize, tree_column_counts[2]);
    defer allocator.free(interaction_counts);
    @memset(interaction_counts, 0);

    for (bundle.components) |component| {
        for (component.preprocessed_indices) |index| {
            if (index >= used_preprocessed.len) return Error.InvalidComponentShape;
        }
        const base_span = try componentSpan(component, 1);
        const interaction_span = try componentSpan(component, 2);
        const base_offsets = try componentOffsets(allocator, component, 1);
        defer freeOffsetLists(allocator, base_offsets);
        const interaction_offsets = try componentOffsets(allocator, component, 2);
        defer freeOffsetLists(allocator, interaction_offsets);
        for (component.parts) |part| for (part.program.base_insts) |instruction| switch (instruction.op) {
            .preprocessed_col => {
                if (instruction.a >= component.preprocessed_indices.len) return Error.InvalidComponentShape;
                used_preprocessed[component.preprocessed_indices[instruction.a]] = true;
            },
            .trace_col => switch (instruction.interaction) {
                0 => {
                    if (instruction.a >= component.preprocessed_indices.len) return Error.InvalidComponentShape;
                    used_preprocessed[component.preprocessed_indices[instruction.a]] = true;
                },
                else => {},
            },
            else => {},
        };
        if (base_span.end > base_counts.len or interaction_span.end > interaction_counts.len)
            return Error.InvalidComponentShape;
        for (base_offsets, 0..) |offsets, local| base_counts[base_span.start + local] = offsets.items.len;
        for (interaction_offsets, 0..) |offsets, local| interaction_counts[interaction_span.start + local] = offsets.items.len;
    }

    const trees = try allocator.alloc([]usize, 4);
    errdefer allocator.free(trees);
    var initialized: usize = 0;
    errdefer for (trees[0..initialized]) |tree| allocator.free(tree);
    trees[0] = try allocator.alloc(usize, used_preprocessed.len);
    initialized += 1;
    for (used_preprocessed, trees[0]) |used, *count| count.* = @intFromBool(used);
    trees[1] = try allocator.dupe(usize, base_counts);
    initialized += 1;
    trees[2] = try allocator.dupe(usize, interaction_counts);
    initialized += 1;
    trees[3] = try allocator.dupe(usize, &[_]usize{1} ** 8);
    return trees;
}

pub fn freeSampleShape(allocator: std.mem.Allocator, shape: [][]usize) void {
    for (shape) |tree| allocator.free(tree);
    allocator.free(shape);
}

test "resident verifier accepts runtime lifting logs 24 and 25" {
    try validateMaximumDegreeLog(24, 23);
    try validateMaximumDegreeLog(25, 24);
    try std.testing.expectError(Error.InvalidComponentShape, validateMaximumDegreeLog(24, 24));
    try std.testing.expectError(Error.InvalidComponentShape, validateMaximumDegreeLog(0, 0));
}

test "resident verifier evaluates secure OODS trace samples in QM31" {
    const allocator = std.testing.allocator;
    var label = [_]u8{'t'};
    var spans = [_]composition_bundle.TraceSpan{.{ .tree = 1, .start = 0, .end = 4 }};
    var preprocessed = [_]u32{};
    var denominators = [_]u32{1};
    var sources = [_]composition_bundle.ExtSource{};
    var parts = [_]composition_bundle.Part{};
    var captured = composition_bundle.Component{
        .label = label[0..],
        .instance = 0,
        .trace_log_size = 1,
        .evaluation_log_size = 1,
        .n_constraints = 1,
        .random_coefficient_offset = 0,
        .trace_spans = spans[0..],
        .preprocessed_indices = preprocessed[0..],
        .denominator_inverses = denominators[0..],
        .ext_sources = sources[0..],
        .parts = parts[0..],
    };
    const values = [_]QM31{
        QM31.fromU32Unchecked(1, 2, 3, 4),
        QM31.fromU32Unchecked(5, 6, 7, 8),
        QM31.fromU32Unchecked(9, 10, 11, 12),
        QM31.fromU32Unchecked(13, 14, 15, 16),
    };
    var column0 = [_]QM31{values[0]};
    var column1 = [_]QM31{values[1]};
    var column2 = [_]QM31{values[2]};
    var column3 = [_]QM31{values[3]};
    var tree0 = [_][]QM31{};
    var tree1 = [_][]QM31{ column0[0..], column1[0..], column2[0..], column3[0..] };
    var tree2 = [_][]QM31{};
    var mask_items = [_][][]QM31{ tree0[0..], tree1[0..], tree2[0..] };
    const mask = air_components.MaskValues.initOwned(mask_items[0..]);

    var zero0 = [_]i32{0};
    var zero1 = [_]i32{0};
    var zero2 = [_]i32{0};
    var zero3 = [_]i32{0};
    const base_offsets = [_]std.ArrayList(i32){
        .fromOwnedSlice(zero0[0..]),
        .fromOwnedSlice(zero1[0..]),
        .fromOwnedSlice(zero2[0..]),
        .fromOwnedSlice(zero3[0..]),
    };
    const no_offsets = [_]std.ArrayList(i32){};
    const no_ext_params = [_]QM31{};
    var base_insts = [_]eval_program.BaseInst{
        .{ .op = .trace_col, .interaction = 1, .dst = 0, .a = 0, .b = 0, .imm = 0 },
        .{ .op = .trace_col, .interaction = 1, .dst = 1, .a = 1, .b = 0, .imm = 0 },
        .{ .op = .trace_col, .interaction = 1, .dst = 2, .a = 2, .b = 0, .imm = 0 },
        .{ .op = .trace_col, .interaction = 1, .dst = 3, .a = 3, .b = 0, .imm = 0 },
    };
    var ext_insts = [_]eval_program.ExtInst{
        .{ .op = .secure_col, .dst = 0, .a = 0, .b = 1, .c = 2, .d = 3 },
    };
    var roots = [_]u32{0};
    var base_consts = [_]u32{};
    var ext_consts = [_][4]u32{};
    const program = eval_program.Program{
        .allocator = allocator,
        .header = .{
            .flags = 0,
            .semantic_hash = 0,
            .capability_bits = 0,
            .n_interactions = 3,
            .n_base_params = 0,
            .n_ext_params = 0,
            .n_constraints = 1,
            .max_base_regs = 4,
            .max_ext_regs = 1,
            .domain_log_size = 1,
        },
        .base_consts = base_consts[0..],
        .ext_consts = ext_consts[0..],
        .base_insts = base_insts[0..],
        .ext_insts = ext_insts[0..],
        .constraint_roots = roots[0..],
    };
    const runtime = RuntimeComponent{
        .allocator = allocator,
        .captured = &captured,
        .preprocessed_logs = &.{},
        .lifting_log_size = 24,
        .lookup_z = QM31.zero(),
        .lookup_alpha = QM31.zero(),
        .claimed_sum = QM31.zero(),
    };
    var accumulator = air_accumulation.PointEvaluationAccumulator.init(QM31.one());

    try runtime.evaluateProgram(
        program,
        0,
        &mask,
        base_offsets[0..],
        no_offsets[0..],
        no_ext_params[0..],
        QM31.one(),
        &accumulator,
    );
    try std.testing.expect(accumulator.finalize().eql(QM31.fromPartialEvals(values)));
}

test "resident verifier derives exact SN2 OODS shape" {
    const allocator = std.testing.allocator;
    var captured = try composition_bundle.Bundle.readFile(
        allocator,
        "vectors/cairo/sn_pie_2_composition.bin",
    );
    defer captured.deinit();
    if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_CAPTURED_PARTS")) {
        const component = captured.components[0];
        for (component.parts, 0..) |part, part_index| {
            std.debug.print(
                "captured_part index={} rc_base={} constraints={} base_insts={} ext_insts={} roots={any}\n",
                .{
                    part_index,
                    part.rc_base,
                    part.program.header.n_constraints,
                    part.program.base_insts.len,
                    part.program.ext_insts.len,
                    part.program.constraint_roots,
                },
            );
        }
    }
    const shape = try sampleShape(allocator, captured, .{ 161, 3449, 2268 });
    defer freeSampleShape(allocator, shape);
    try std.testing.expectEqual(@as(usize, 4), shape.len);
    try std.testing.expectEqual(@as(usize, 161), shape[0].len);
    try std.testing.expectEqual(@as(usize, 3449), shape[1].len);
    try std.testing.expectEqual(@as(usize, 2268), shape[2].len);
    try std.testing.expectEqual(@as(usize, 8), shape[3].len);
    var samples: usize = 0;
    for (shape) |tree| {
        for (tree) |count| samples += count;
    }
    try std.testing.expectEqual(@as(usize, 6110), samples);
}

test "resident verifier decodes a Merkle opening and rejects a witness mutation" {
    const allocator = std.testing.allocator;
    const layout = try proof_bundle.Layout.init(4, 16, 8, 4, 512);
    const words = try allocator.alloc(u32, layout.total_words);
    defer allocator.free(words);
    @memset(words, 0);

    var queried_hasher = Hasher.defaultWithInitialState();
    queried_hasher.updateLeaf(&[_]M31{M31.fromCanonical(10)});
    const queried_hash = queried_hasher.finalize();
    var sibling_hasher = Hasher.defaultWithInitialState();
    sibling_hasher.updateLeaf(&[_]M31{M31.fromCanonical(9)});
    const sibling_hash = sibling_hasher.finalize();
    const root = Hasher.hashChildren(.{ .left = sibling_hash, .right = queried_hash });
    @memcpy(
        std.mem.sliceAsBytes(words[layout.commitments.start..][0..proof_bundle.hash_words]),
        &root,
    );

    const decommit = words[layout.decommitment.start..layout.decommitment.end];
    decommit[0] = proof_bundle.decommit_magic;
    decommit[1] = proof_bundle.decommit_version;
    decommit[2] = 12;
    decommit[3] = 1;
    decommit[4] = 1;
    decommit[5] = 200;
    decommit[6] = 201;
    decommit[200] = 1;
    decommit[201] = 1;
    var cursor: usize = 202;
    var first_hash_offset: usize = 0;
    for (0..12) |tree_index| {
        const meta = decommit[proof_bundle.decommit_header_words +
            tree_index * proof_bundle.decommit_tree_meta_words ..][0..proof_bundle.decommit_tree_meta_words];
        const tree_start = cursor;
        meta[0] = if (tree_index < 4) 0 else 1;
        meta[1] = @intCast(tree_index);
        meta[2] = @intCast(cursor);
        meta[3] = 1;
        decommit[cursor] = 1;
        cursor += 1;
        if (tree_index < 4) {
            meta[4] = @intCast(cursor);
            meta[5] = 1;
            decommit[cursor] = 10;
            cursor += 1;
        }
        if (tree_index == 0) {
            first_hash_offset = cursor;
            meta[8] = @intCast(cursor);
            meta[9] = 1;
            @memcpy(std.mem.sliceAsBytes(decommit[cursor..][0..proof_bundle.hash_words]), &sibling_hash);
            cursor += proof_bundle.hash_words;
        }
        meta[14] = 1;
        meta[15] = @intCast(cursor - tree_start);
    }
    decommit[7] = @intCast(cursor);

    const tree0_shape = [_]usize{1};
    const tree1_shape = [_]usize{1};
    const tree2_shape = [_]usize{1};
    const tree3_shape = [_]usize{1};
    const shape = [_][]const usize{ &tree0_shape, &tree1_shape, &tree2_shape, &tree3_shape };

    var structural = try proof_bundle.ProofBundle.decode(allocator, words, layout);
    defer structural.deinit(allocator);
    var proof = try decodeProof(allocator, structural, .{ .trees = &shape });
    defer proof.deinit(allocator);
    var verifier = try vcs_verifier.MerkleVerifierLifted(Hasher).init(allocator, root, &[_]u32{1});
    defer verifier.deinit(allocator);
    try verifier.verify(
        allocator,
        &[_]usize{1},
        proof.commitment_scheme_proof.queried_values.items[0],
        proof.commitment_scheme_proof.decommitments.items[0],
    );

    proof.deinit(allocator);
    structural.deinit(allocator);
    decommit[first_hash_offset] ^= 1;
    structural = try proof_bundle.ProofBundle.decode(allocator, words, layout);
    proof = try decodeProof(allocator, structural, .{ .trees = &shape });
    try std.testing.expectError(
        vcs_verifier.MerkleVerificationError.RootMismatch,
        verifier.verify(
            allocator,
            &[_]usize{1},
            proof.commitment_scheme_proof.queried_values.items[0],
            proof.commitment_scheme_proof.decommitments.items[0],
        ),
    );
}
