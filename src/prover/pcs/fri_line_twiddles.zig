//! Exact mapping from canonical FFT inverse twiddles to FRI line folds.

const std = @import("std");
const core = @import("stwo_core");
const twiddles_mod = @import("../poly/twiddles.zig");

const M31 = core.fields.m31.M31;
const QM31 = core.fields.qm31.QM31;

pub const M31TwiddleTree = twiddles_mod.TwiddleTree([]const M31);

pub const Error = error{
    InvalidTwiddleDomain,
    InvalidTwiddleTree,
};

/// Returns the consecutive inverse FFT layers for `n_folds` of `domain`.
///
/// For tree length `N` and current doubled-domain size `S`, the first layer
/// starts at `N-S`; after `n_folds`, the exclusive end is `N-S/2^n_folds`.
pub fn inverseForFolds(
    tree: M31TwiddleTree,
    domain: core.poly.line.LineDomain,
    n_folds: u32,
) ![]const M31 {
    if (tree.twiddles.len != tree.itwiddles.len or
        tree.itwiddles.len != tree.root_coset.size())
    {
        return Error.InvalidTwiddleTree;
    }
    if (!domain.coset().isDoublingOf(tree.root_coset)) {
        return Error.InvalidTwiddleDomain;
    }

    const source_size = domain.size();
    var result_size = source_size;
    var step: u32 = 0;
    while (step < n_folds) : (step += 1) {
        if (result_size < 2 or (result_size & 1) != 0)
            return error.InvalidEvaluationLength;
        result_size /= 2;
    }

    const start = tree.itwiddles.len - source_size;
    const end = tree.itwiddles.len - result_size;
    return tree.itwiddles[start..end];
}

test "fri inverse FFT twiddle slices exactly match line fold coordinates" {
    const allocator = std.testing.allocator;

    var circle_log: u32 = 2;
    while (circle_log <= 11) : (circle_log += 1) {
        var owned_tree = try twiddles_mod.precomputeM31(
            allocator,
            core.circle.Coset.halfOdds(circle_log - 1),
        );
        defer twiddles_mod.deinitM31(allocator, &owned_tree);
        const tree = M31TwiddleTree.init(
            owned_tree.root_coset,
            owned_tree.twiddles,
            owned_tree.itwiddles,
        );

        var domain = try core.poly.line.LineDomain.init(tree.root_coset);
        while (domain.logSize() > 0) : (domain = domain.double()) {
            const max_folds: u32 = @min(4, domain.logSize());
            var n_folds: u32 = 1;
            while (n_folds <= max_folds) : (n_folds += 1) {
                const inverse_layers = try inverseForFolds(tree, domain, n_folds);

                var layer_domain = domain;
                var offset: usize = 0;
                var step: u32 = 0;
                while (step < n_folds) : (step += 1) {
                    const layer_len = layer_domain.size() / 2;
                    for (inverse_layers[offset .. offset + layer_len], 0..) |actual, i| {
                        const x = layer_domain.at(core.utils.bitReverseIndex(
                            i << 1,
                            layer_domain.logSize(),
                        ));
                        try std.testing.expect(actual.eql(try x.inv()));
                    }
                    offset += layer_len;
                    layer_domain = layer_domain.double();
                }
                try std.testing.expectEqual(inverse_layers.len, offset);
            }
        }

        const shifted = try core.poly.line.LineDomain.init(
            tree.root_coset.shift(tree.root_coset.step_size),
        );
        try std.testing.expectError(
            Error.InvalidTwiddleDomain,
            inverseForFolds(tree, shifted, 1),
        );
    }
}

test "retained inverse twiddles match legacy line folds across domains and fold sizes" {
    const allocator = std.testing.allocator;
    const alpha = QM31.fromU32Unchecked(3, 5, 7, 11);

    var circle_log: u32 = 2;
    while (circle_log <= 10) : (circle_log += 1) {
        var owned_tree = try twiddles_mod.precomputeM31(
            allocator,
            core.circle.Coset.halfOdds(circle_log - 1),
        );
        defer twiddles_mod.deinitM31(allocator, &owned_tree);
        const tree = M31TwiddleTree.init(
            owned_tree.root_coset,
            owned_tree.twiddles,
            owned_tree.itwiddles,
        );

        var domain = try core.poly.line.LineDomain.init(tree.root_coset);
        while (domain.logSize() > 0) : (domain = domain.double()) {
            const max_folds: u32 = @min(4, domain.logSize());
            var n_folds: u32 = 1;
            while (n_folds <= max_folds) : (n_folds += 1) {
                const values = try allocator.alloc(QM31, domain.size());
                defer allocator.free(values);
                for (values, 0..) |*value, i| {
                    const seed: u32 = @intCast(i + 1 + circle_log * 17 + n_folds * 31);
                    value.* = QM31.fromU32Unchecked(
                        seed,
                        seed + 1,
                        seed + 2,
                        seed + 3,
                    );
                }

                const legacy_values = try allocator.dupe(QM31, values);
                const reused_values = try allocator.dupe(QM31, values);
                var workspace = try core.fri.FoldLineWorkspace.init(
                    allocator,
                    domain.size() / 2,
                );
                defer workspace.deinit(allocator);

                const legacy = try core.fri.foldLineInPlaceNWithWorkspace(
                    allocator,
                    legacy_values,
                    domain,
                    alpha,
                    &workspace,
                    n_folds,
                );
                defer allocator.free(legacy.values);

                const reused = try core.fri.foldLineInPlaceNWithInvTwiddles(
                    allocator,
                    reused_values,
                    domain,
                    alpha,
                    try inverseForFolds(tree, domain, n_folds),
                    n_folds,
                );
                defer allocator.free(reused.values);

                try std.testing.expect(legacy.domain.coset().eql(reused.domain.coset()));
                try std.testing.expectEqual(legacy.values.len, reused.values.len);
                for (legacy.values, reused.values) |expected, actual| {
                    try std.testing.expect(expected.eql(actual));
                }
            }
        }
    }
}
