const std = @import("std");
const m31 = @import("../../../core/fields/m31.zig");
const canonic = @import("../../../core/poly/circle/canonic.zig");
const eval_mod = @import("../../poly/circle/evaluation.zig");
const circle_poly = @import("../../poly/circle/poly.zig");
const twiddles_mod = @import("../../poly/twiddles.zig");

const M31 = m31.M31;
const CircleCoefficients = circle_poly.CircleCoefficients;

test "prover poly circle poly: owned interpolation matches cloned interpolation" {
    const alloc = std.testing.allocator;
    const domain = canonic.CanonicCoset.new(5).circleDomain();
    const values = try alloc.alloc(M31, domain.size());
    defer alloc.free(values);
    for (values, 0..) |*value, i| {
        value.* = M31.fromCanonical(@intCast((i * 13 + 7) % m31.Modulus));
    }

    const twiddle_tree = try twiddles_mod.precomputeM31(alloc, domain.half_coset);
    defer {
        var owned = twiddle_tree;
        twiddles_mod.deinitM31(alloc, &owned);
    }

    const evaluation = try eval_mod.CircleEvaluation.init(domain, values);
    var cloned = try circle_poly.interpolateFromEvaluationWithTwiddles(
        alloc,
        evaluation,
        .{
            .root_coset = twiddle_tree.root_coset,
            .twiddles = twiddle_tree.twiddles,
            .itwiddles = twiddle_tree.itwiddles,
        },
    );
    defer cloned.deinit(alloc);

    const owned_values = try alloc.dupe(M31, values);
    var in_place = try circle_poly.interpolateOwnedValuesWithTwiddles(
        domain,
        owned_values,
        .{
            .root_coset = twiddle_tree.root_coset,
            .twiddles = twiddle_tree.twiddles,
            .itwiddles = twiddle_tree.itwiddles,
        },
    );
    defer in_place.deinit(alloc);

    try std.testing.expectEqual(cloned.logSize(), in_place.logSize());
    try std.testing.expectEqualSlices(M31, cloned.coefficients(), in_place.coefficients());
}

test "prover poly circle poly: batched owned interpolation matches scalar helper" {
    const alloc = std.testing.allocator;
    const domain = canonic.CanonicCoset.new(5).circleDomain();
    const twiddle_tree = try twiddles_mod.precomputeM31(alloc, domain.half_coset);
    defer {
        var owned = twiddle_tree;
        twiddles_mod.deinitM31(alloc, &owned);
    }

    var prng = std.Random.DefaultPrng.init(0x6d41_9b83_7e52_4c11);
    const random = prng.random();

    for ([_]usize{ 1, 2, 3, 4, 5, 6, 7, 8 }) |column_count| {
        const batch_values = try alloc.alloc([]M31, column_count);
        defer alloc.free(batch_values);
        const scalar_values = try alloc.alloc([]M31, column_count);
        defer alloc.free(scalar_values);

        for (0..column_count) |idx| {
            batch_values[idx] = try alloc.alloc(M31, domain.size());
            scalar_values[idx] = try alloc.alloc(M31, domain.size());
            for (batch_values[idx], scalar_values[idx]) |*batch, *scalar| {
                const value = M31.fromCanonical(random.intRangeLessThan(u32, 0, m31.Modulus));
                batch.* = value;
                scalar.* = value;
            }
        }

        defer {
            for (batch_values) |values| alloc.free(values);
            for (scalar_values) |values| if (values.len != 0) alloc.free(values);
        }

        try circle_poly.interpolateOwnedValuesBatchWithTwiddles(
            domain,
            batch_values,
            .{
                .root_coset = twiddle_tree.root_coset,
                .twiddles = twiddle_tree.twiddles,
                .itwiddles = twiddle_tree.itwiddles,
            },
        );
        for (scalar_values, 0..) |values, idx| {
            var scalar = try circle_poly.interpolateOwnedValuesWithTwiddles(
                domain,
                values,
                .{
                    .root_coset = twiddle_tree.root_coset,
                    .twiddles = twiddle_tree.twiddles,
                    .itwiddles = twiddle_tree.itwiddles,
                },
            );
            defer scalar.deinit(alloc);
            scalar_values[idx] = &[_]M31{};
            try std.testing.expectEqualSlices(M31, scalar.coefficients(), batch_values[idx]);
        }
    }
}

test "prover poly circle poly: batched evaluation matches scalar helper" {
    const alloc = std.testing.allocator;
    const log_size: u32 = 5;
    const extended_log_size: u32 = 7;
    const domain = canonic.CanonicCoset.new(extended_log_size).circleDomain();
    const twiddle_tree = try twiddles_mod.precomputeM31(alloc, domain.half_coset);
    defer {
        var owned = twiddle_tree;
        twiddles_mod.deinitM31(alloc, &owned);
    }

    var prng = std.Random.DefaultPrng.init(0x4f17_5c32_e992_120d);
    const random = prng.random();

    for ([_]usize{ 1, 2, 3, 4, 5, 6, 7, 8 }) |poly_count| {
        const polys = try alloc.alloc(CircleCoefficients, poly_count);
        defer alloc.free(polys);
        var initialized: usize = 0;
        defer {
            for (polys[0..initialized]) |*poly| poly.deinit(alloc);
        }

        for (0..poly_count) |idx| {
            const coeffs = try alloc.alloc(M31, @as(usize, 1) << @intCast(log_size));
            for (coeffs) |*coeff| {
                coeff.* = M31.fromCanonical(random.intRangeLessThan(u32, 0, m31.Modulus));
            }
            polys[idx] = try CircleCoefficients.initOwned(coeffs);
            initialized += 1;
        }

        const batch_values = try circle_poly.evaluateManyWithTwiddles(
            alloc,
            polys,
            domain,
            .{
                .root_coset = twiddle_tree.root_coset,
                .twiddles = twiddle_tree.twiddles,
                .itwiddles = twiddle_tree.itwiddles,
            },
        );
        defer {
            for (batch_values) |values| alloc.free(values);
            alloc.free(batch_values);
        }

        for (polys, 0..) |poly, idx| {
            const scalar = try poly.evaluateWithTwiddles(
                alloc,
                domain,
                .{
                    .root_coset = twiddle_tree.root_coset,
                    .twiddles = twiddle_tree.twiddles,
                    .itwiddles = twiddle_tree.itwiddles,
                },
            );
            defer alloc.free(@constCast(scalar.values));
            try std.testing.expectEqualSlices(M31, scalar.values, batch_values[idx]);
        }
    }
}
