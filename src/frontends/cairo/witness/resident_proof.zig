//! Reconstruction of generic STWO proofs from compact resident Cairo bundles.

const std = @import("std");
const fri = @import("../../../core/fri.zig");
const pcs = @import("../../../core/pcs/mod.zig");
const line = @import("../../../core/poly/line.zig");
const vcs_verifier = @import("../../../core/vcs_lifted/verifier.zig");
const proof_bundle = @import("proof_bundle.zig");
const types = @import("resident_types.zig");

const M31 = types.M31;
const QM31 = types.QM31;
const Hasher = types.Hasher;
const Proof = types.Proof;
const Error = types.Error;
const SampleShape = types.SampleShape;
const sn2_pow_bits = types.sn2_pow_bits;
const sn2_query_count = types.sn2_query_count;
const sn2_fold_step = types.sn2_fold_step;
const m31FromWord = types.m31FromWord;
const qm31FromWords = types.qm31FromWords;

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

fn freeQm31Tree(allocator: std.mem.Allocator, tree: [][]QM31) void {
    for (tree) |column| allocator.free(column);
    allocator.free(tree);
}

fn freeM31Tree(allocator: std.mem.Allocator, tree: [][]M31) void {
    for (tree) |column| allocator.free(column);
    allocator.free(tree);
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
