const std = @import("std");
const fraction = @import("../../core/fraction.zig");
const m31 = @import("../../core/fields/m31.zig");
const qm31 = @import("../../core/fields/qm31.zig");
const gkr_circuit = @import("gkr_circuit.zig");
const gkr_verifier = @import("gkr_verifier.zig");
const mle_mod = @import("mle.zig");
const sumcheck = @import("sumcheck.zig");
const utils = @import("utils.zig");

const M31 = m31.M31;
const QM31 = qm31.QM31;
const MleBase = mle_mod.Mle(M31);
const MleSecure = mle_mod.Mle(QM31);

pub const GkrProverError = gkr_circuit.GkrProverError;
pub const EqEvals = gkr_circuit.EqEvals;
pub const Layer = gkr_circuit.Layer;
pub const GkrMultivariatePolyOracle = gkr_circuit.GkrMultivariatePolyOracle;
pub const correctSumAsPolyInFirstVariable = gkr_circuit.correctSumAsPolyInFirstVariable;

pub const ProveBatchResult = struct {
    proof: gkr_verifier.GkrBatchProof,
    artifact: gkr_verifier.GkrArtifact,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.proof.deinit(allocator);
        self.artifact.deinit(allocator);
        self.* = undefined;
    }
};

/// Batch-proves lookup circuits with GKR.
pub fn proveBatch(
    allocator: std.mem.Allocator,
    channel: anytype,
    input_layer_by_instance: []const Layer,
) (std.mem.Allocator.Error || GkrProverError)!ProveBatchResult {
    if (input_layer_by_instance.len == 0) return GkrProverError.EmptyBatch;

    const n_instances = input_layer_by_instance.len;

    const n_layers_by_instance = try allocator.alloc(usize, n_instances);
    defer allocator.free(n_layers_by_instance);

    var n_layers: usize = 0;
    for (input_layer_by_instance, 0..) |layer, i| {
        n_layers_by_instance[i] = layer.nVariables();
        n_layers = @max(n_layers, n_layers_by_instance[i]);
    }

    const layers_by_instance = try allocator.alloc([]Layer, n_instances);
    errdefer allocator.free(layers_by_instance);
    var layers_initialized: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < layers_initialized) : (i += 1) {
            for (layers_by_instance[i]) |*layer| layer.deinit(allocator);
            allocator.free(layers_by_instance[i]);
        }
    }

    for (input_layer_by_instance, 0..) |input_layer, i| {
        layers_by_instance[i] = try gkr_circuit.buildLayers(allocator, input_layer);
        layers_initialized += 1;
    }

    defer {
        for (layers_by_instance) |layers| {
            for (layers) |*layer| layer.deinit(allocator);
            allocator.free(layers);
        }
        allocator.free(layers_by_instance);
    }

    const next_layer_idx = try allocator.alloc(usize, n_instances);
    defer allocator.free(next_layer_idx);
    for (layers_by_instance, 0..) |layers, i| next_layer_idx[i] = layers.len;

    var output_claims_by_instance = try allocator.alloc(?[]QM31, n_instances);
    defer {
        for (output_claims_by_instance) |maybe_claims| {
            if (maybe_claims) |claims| allocator.free(claims);
        }
        allocator.free(output_claims_by_instance);
    }
    @memset(output_claims_by_instance, null);

    var claims_to_verify_by_instance = try allocator.alloc(?[]QM31, n_instances);
    defer {
        for (claims_to_verify_by_instance) |maybe_claims| {
            if (maybe_claims) |claims| allocator.free(claims);
        }
        allocator.free(claims_to_verify_by_instance);
    }
    @memset(claims_to_verify_by_instance, null);

    const mask_builders = try allocator.alloc(std.ArrayList(gkr_verifier.GkrMask), n_instances);
    defer {
        for (mask_builders) |*builder| {
            for (builder.items) |*mask| mask.deinit(allocator);
            builder.deinit(allocator);
        }
        allocator.free(mask_builders);
    }
    for (mask_builders) |*builder| builder.* = .empty;

    var sumcheck_proofs = std.ArrayList(sumcheck.SumcheckProof).empty;
    defer {
        for (sumcheck_proofs.items) |*proof| proof.deinit(allocator);
        sumcheck_proofs.deinit(allocator);
    }

    var ood_point = try allocator.alloc(QM31, 0);
    defer allocator.free(ood_point);

    var layer_idx: usize = 0;
    while (layer_idx < n_layers) : (layer_idx += 1) {
        const n_remaining_layers = n_layers - layer_idx;

        var instance: usize = 0;
        while (instance < n_instances) : (instance += 1) {
            if (n_layers_by_instance[instance] == n_remaining_layers) {
                const output_layer = try popNextLayer(
                    layers_by_instance[instance],
                    &next_layer_idx[instance],
                );
                const output_values = try output_layer.outputLayerValues(allocator);
                try replaceOwnedSlice(
                    allocator,
                    &claims_to_verify_by_instance[instance],
                    try allocator.dupe(QM31, output_values),
                );
                try replaceOwnedSlice(
                    allocator,
                    &output_claims_by_instance[instance],
                    output_values,
                );
            }
        }

        for (claims_to_verify_by_instance) |maybe_claims| {
            if (maybe_claims) |claims| channel.mixFelts(claims);
        }

        var eq_evals = try EqEvals.generate(allocator, ood_point);
        defer eq_evals.deinit(allocator);

        const sumcheck_alpha = channel.drawSecureFelt();
        const instance_lambda = channel.drawSecureFelt();

        var sumcheck_oracles = std.ArrayList(GkrMultivariatePolyOracle).empty;
        defer {
            for (sumcheck_oracles.items) |*oracle| oracle.deinit(allocator);
            sumcheck_oracles.deinit(allocator);
        }

        var sumcheck_claims = std.ArrayList(QM31).empty;
        defer sumcheck_claims.deinit(allocator);

        var sumcheck_instances = std.ArrayList(usize).empty;
        defer sumcheck_instances.deinit(allocator);

        instance = 0;
        while (instance < n_instances) : (instance += 1) {
            if (claims_to_verify_by_instance[instance]) |claims| {
                const layer = try popNextLayer(
                    layers_by_instance[instance],
                    &next_layer_idx[instance],
                );
                try sumcheck_oracles.append(
                    allocator,
                    try layer.intoMultivariatePoly(
                        allocator,
                        instance_lambda,
                        &eq_evals,
                    ),
                );
                try sumcheck_claims.append(
                    allocator,
                    utils.randomLinearCombination(claims, instance_lambda),
                );
                try sumcheck_instances.append(allocator, instance);
            }
        }

        const sumcheck_result = sumcheck.proveBatch(
            GkrMultivariatePolyOracle,
            allocator,
            sumcheck_claims.items,
            sumcheck_oracles.items,
            sumcheck_alpha,
            channel,
        ) catch |err| switch (err) {
            std.mem.Allocator.Error.OutOfMemory => return error.OutOfMemory,
            else => return GkrProverError.InvalidSumcheck,
        };

        try sumcheck_proofs.append(allocator, sumcheck_result.proof);

        const masks = try allocator.alloc(gkr_verifier.GkrMask, sumcheck_result.constant_polys.len);
        var masks_initialized: usize = 0;
        errdefer {
            for (masks[0..masks_initialized]) |*mask| mask.deinit(allocator);
            allocator.free(masks);
        }

        for (sumcheck_result.constant_polys, 0..) |oracle, i| {
            masks[i] = try oracle.tryIntoMask(allocator);
            masks_initialized += 1;
        }

        for (sumcheck_result.constant_polys) |*oracle| oracle.deinit(allocator);
        allocator.free(sumcheck_result.constant_polys);

        for (masks, sumcheck_instances.items) |mask, instance_idx| {
            const flattened = try flattenMaskColumns(allocator, &mask);
            defer allocator.free(flattened);
            channel.mixFelts(flattened);
            try mask_builders[instance_idx].append(allocator, mask);
        }

        const challenge = channel.drawSecureFelt();

        const next_ood = try allocator.alloc(QM31, sumcheck_result.assignment.len + 1);
        @memcpy(next_ood[0..sumcheck_result.assignment.len], sumcheck_result.assignment);
        next_ood[sumcheck_result.assignment.len] = challenge;
        allocator.free(ood_point);
        allocator.free(sumcheck_result.assignment);
        ood_point = next_ood;

        allocator.free(sumcheck_result.claimed_evals);

        for (masks, sumcheck_instances.items) |mask, instance_idx| {
            const reduced = try mask.reduceAtPoint(allocator, challenge);
            try replaceOwnedSlice(
                allocator,
                &claims_to_verify_by_instance[instance_idx],
                reduced,
            );
        }

        allocator.free(masks);
    }

    const proof_sumcheck = try sumcheck_proofs.toOwnedSlice(allocator);

    const proof_layer_masks = try allocator.alloc([]gkr_verifier.GkrMask, n_instances);
    for (mask_builders, 0..) |*builder, i| {
        proof_layer_masks[i] = try builder.toOwnedSlice(allocator);
    }

    const proof_output_claims = try allocator.alloc([]QM31, n_instances);
    for (output_claims_by_instance, 0..) |*maybe_claims, i| {
        proof_output_claims[i] = maybe_claims.* orelse return GkrProverError.InvalidLayerStructure;
        maybe_claims.* = null;
    }

    const artifact_claims = try allocator.alloc([]QM31, n_instances);
    for (claims_to_verify_by_instance, 0..) |*maybe_claims, i| {
        artifact_claims[i] = maybe_claims.* orelse return GkrProverError.InvalidLayerStructure;
        maybe_claims.* = null;
    }

    const artifact_n_vars = try allocator.dupe(usize, n_layers_by_instance);

    const proof = gkr_verifier.GkrBatchProof{
        .sumcheck_proofs = proof_sumcheck,
        .layer_masks_by_instance = proof_layer_masks,
        .output_claims_by_instance = proof_output_claims,
    };

    const artifact = gkr_verifier.GkrArtifact{
        .ood_point = ood_point,
        .claims_to_verify_by_instance = artifact_claims,
        .n_variables_by_instance = artifact_n_vars,
    };

    ood_point = &[_]QM31{};
    return .{ .proof = proof, .artifact = artifact };
}

fn popNextLayer(layers: []const Layer, next_idx: *usize) GkrProverError!Layer {
    if (next_idx.* == 0) return GkrProverError.InvalidLayerStructure;
    next_idx.* -= 1;
    return layers[next_idx.*];
}

fn replaceOwnedSlice(
    allocator: std.mem.Allocator,
    slot: *?[]QM31,
    next: []QM31,
) !void {
    if (slot.*) |old| allocator.free(old);
    slot.* = next;
}

fn flattenMaskColumns(allocator: std.mem.Allocator, mask: *const gkr_verifier.GkrMask) ![]QM31 {
    const out = try allocator.alloc(QM31, mask.columnsSlice().len * 2);
    for (mask.columnsSlice(), 0..) |column, i| {
        out[2 * i] = column[0];
        out[2 * i + 1] = column[1];
    }
    return out;
}

test "gkr prover: grand product prove and verify" {
    const alloc = std.testing.allocator;
    const Channel = @import("../../core/channel/blake2s.zig").Blake2sChannel;

    var draw_channel = Channel{};
    const values = try draw_channel.drawSecureFelts(alloc, 1 << 5);

    var claim = QM31.one();
    for (values) |v| claim = claim.mul(v);

    var mle = try MleSecure.initOwned(values);
    defer mle.deinit(alloc);
    var mle_check = try mle.cloneOwned(alloc);
    defer mle_check.deinit(alloc);

    const input_layers = [_]Layer{.{ .GrandProduct = mle }};

    var prover_channel = Channel{};
    var result = try proveBatch(alloc, &prover_channel, input_layers[0..]);
    defer result.deinit(alloc);

    var verify_channel = Channel{};
    var verify_artifact = try gkr_verifier.partiallyVerifyBatch(
        alloc,
        &[_]gkr_verifier.Gate{.GrandProduct},
        &result.proof,
        &verify_channel,
    );
    defer verify_artifact.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), result.proof.output_claims_by_instance.len);
    try std.testing.expect(result.proof.output_claims_by_instance[0][0].eql(claim));

    const expected = try mle_check.evalAtPoint(alloc, verify_artifact.ood_point);
    try std.testing.expect(verify_artifact.claims_to_verify_by_instance[0][0].eql(expected));
}

test "gkr prover: logup generic prove and verify" {
    const alloc = std.testing.allocator;
    const Channel = @import("../../core/channel/blake2s.zig").Blake2sChannel;

    var draw_channel = Channel{};
    const numerators_values = try draw_channel.drawSecureFelts(alloc, 1 << 5);
    const denominators_values = try draw_channel.drawSecureFelts(alloc, 1 << 5);

    const terms = try alloc.alloc(fraction.Fraction(QM31, QM31), numerators_values.len);
    defer alloc.free(terms);

    for (numerators_values, denominators_values, 0..) |n, d, i| {
        terms[i] = fraction.Fraction(QM31, QM31).new(n, d);
    }
    const sum = fraction.sumFractions(QM31, QM31, terms);

    var numerators = try MleSecure.initOwned(numerators_values);
    defer numerators.deinit(alloc);
    var denominators = try MleSecure.initOwned(denominators_values);
    defer denominators.deinit(alloc);

    var numerators_check = try numerators.cloneOwned(alloc);
    defer numerators_check.deinit(alloc);
    var denominators_check = try denominators.cloneOwned(alloc);
    defer denominators_check.deinit(alloc);

    const input_layers = [_]Layer{.{ .LogUpGeneric = .{
        .numerators = numerators,
        .denominators = denominators,
    } }};

    var prover_channel = Channel{};
    var result = try proveBatch(alloc, &prover_channel, input_layers[0..]);
    defer result.deinit(alloc);

    var verify_channel = Channel{};
    var verify_artifact = try gkr_verifier.partiallyVerifyBatch(
        alloc,
        &[_]gkr_verifier.Gate{.LogUp},
        &result.proof,
        &verify_channel,
    );
    defer verify_artifact.deinit(alloc);

    try std.testing.expect(result.proof.output_claims_by_instance[0][0].eql(sum.numerator));
    try std.testing.expect(result.proof.output_claims_by_instance[0][1].eql(sum.denominator));

    const expected_num = try numerators_check.evalAtPoint(alloc, verify_artifact.ood_point);
    const expected_den = try denominators_check.evalAtPoint(alloc, verify_artifact.ood_point);

    try std.testing.expect(verify_artifact.claims_to_verify_by_instance[0][0].eql(expected_num));
    try std.testing.expect(verify_artifact.claims_to_verify_by_instance[0][1].eql(expected_den));
}

test "gkr prover: logup singles prove and verify" {
    const alloc = std.testing.allocator;
    const Channel = @import("../../core/channel/blake2s.zig").Blake2sChannel;

    var draw_channel = Channel{};
    const denominators_values = try draw_channel.drawSecureFelts(alloc, 1 << 5);

    const terms = try alloc.alloc(fraction.Fraction(QM31, QM31), denominators_values.len);
    defer alloc.free(terms);
    for (denominators_values, 0..) |d, i| {
        terms[i] = fraction.Fraction(QM31, QM31).new(QM31.one(), d);
    }
    const sum = fraction.sumFractions(QM31, QM31, terms);

    var denominators = try MleSecure.initOwned(denominators_values);
    defer denominators.deinit(alloc);
    var denominators_check = try denominators.cloneOwned(alloc);
    defer denominators_check.deinit(alloc);

    const input_layers = [_]Layer{.{ .LogUpSingles = .{ .denominators = denominators } }};

    var prover_channel = Channel{};
    var result = try proveBatch(alloc, &prover_channel, input_layers[0..]);
    defer result.deinit(alloc);

    var verify_channel = Channel{};
    var verify_artifact = try gkr_verifier.partiallyVerifyBatch(
        alloc,
        &[_]gkr_verifier.Gate{.LogUp},
        &result.proof,
        &verify_channel,
    );
    defer verify_artifact.deinit(alloc);

    try std.testing.expect(result.proof.output_claims_by_instance[0][0].eql(sum.numerator));
    try std.testing.expect(result.proof.output_claims_by_instance[0][1].eql(sum.denominator));

    const expected_den = try denominators_check.evalAtPoint(alloc, verify_artifact.ood_point);
    try std.testing.expect(verify_artifact.claims_to_verify_by_instance[0][0].eql(QM31.one()));
    try std.testing.expect(verify_artifact.claims_to_verify_by_instance[0][1].eql(expected_den));
}

test "gkr prover: logup multiplicities prove and verify" {
    const alloc = std.testing.allocator;
    const Channel = @import("../../core/channel/blake2s.zig").Blake2sChannel;

    var draw_channel = Channel{};
    const numerator_secure = try draw_channel.drawSecureFelts(alloc, 1 << 5);
    defer alloc.free(numerator_secure);

    const numerators_values = try alloc.alloc(M31, numerator_secure.len);
    for (numerator_secure, 0..) |v, i| {
        numerators_values[i] = v.toM31Array()[0];
    }

    const denominators_values = try draw_channel.drawSecureFelts(alloc, 1 << 5);

    const terms = try alloc.alloc(fraction.Fraction(QM31, QM31), numerators_values.len);
    defer alloc.free(terms);
    for (numerators_values, denominators_values, 0..) |n, d, i| {
        terms[i] = fraction.Fraction(QM31, QM31).new(QM31.fromBase(n), d);
    }
    const sum = fraction.sumFractions(QM31, QM31, terms);

    var numerators = try MleBase.initOwned(numerators_values);
    defer numerators.deinit(alloc);
    var denominators = try MleSecure.initOwned(denominators_values);
    defer denominators.deinit(alloc);

    var numerators_check = try numerators.cloneOwned(alloc);
    defer numerators_check.deinit(alloc);
    var denominators_check = try denominators.cloneOwned(alloc);
    defer denominators_check.deinit(alloc);

    const input_layers = [_]Layer{.{ .LogUpMultiplicities = .{
        .numerators = numerators,
        .denominators = denominators,
    } }};

    var prover_channel = Channel{};
    var result = try proveBatch(alloc, &prover_channel, input_layers[0..]);
    defer result.deinit(alloc);

    var verify_channel = Channel{};
    var verify_artifact = try gkr_verifier.partiallyVerifyBatch(
        alloc,
        &[_]gkr_verifier.Gate{.LogUp},
        &result.proof,
        &verify_channel,
    );
    defer verify_artifact.deinit(alloc);

    try std.testing.expect(result.proof.output_claims_by_instance[0][0].eql(sum.numerator));
    try std.testing.expect(result.proof.output_claims_by_instance[0][1].eql(sum.denominator));

    const expected_num = try numerators_check.evalAtPoint(alloc, verify_artifact.ood_point);
    const expected_den = try denominators_check.evalAtPoint(alloc, verify_artifact.ood_point);

    try std.testing.expect(verify_artifact.claims_to_verify_by_instance[0][0].eql(expected_num));
    try std.testing.expect(verify_artifact.claims_to_verify_by_instance[0][1].eql(expected_den));
}
