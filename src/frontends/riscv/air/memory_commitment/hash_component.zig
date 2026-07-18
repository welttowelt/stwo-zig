//! Prover/verifier adapter for the exact Merkle-node and Poseidon2 AIRs.

const std = @import("std");
const core_air_accumulation = @import("../../../../core/air/accumulation.zig");
const core_air_components = @import("../../../../core/air/components.zig");
const core_air_derive = @import("../../../../core/air/derive.zig");
const core_constraints = @import("../../../../core/constraints.zig");
const circle = @import("../../../../core/circle.zig");
const M31 = @import("../../../../core/fields/m31.zig").M31;
const QM31 = @import("../../../../core/fields/qm31.zig").QM31;
const canonic = @import("../../../../core/poly/circle/canonic.zig");
const utils = @import("../../../../core/utils.zig");
const prover_air_accumulation = @import("../../../../prover/air/accumulation.zig");
const prover_component = @import("../../../../prover/air/component_prover.zig");
const prover_eval = @import("../../../../prover/poly/circle/evaluation.zig");
const prover_poly = @import("../../../../prover/poly/circle/poly.zig");
const prover_twiddles = @import("../../../../prover/poly/twiddles.zig");
const logup = @import("../logup.zig");
const relations_mod = @import("../relation_challenges.zig");
const merkle_node = @import("merkle_node.zig");
const poseidon2_air = @import("poseidon2_air.zig");

const CirclePointQM31 = circle.CirclePointQM31;
const EMPTY_PREV: [4][]const M31 = .{ &.{}, &.{}, &.{}, &.{} };

pub const Kind = enum { merkle, poseidon2 };

pub const HashComponent = struct {
    kind: Kind,
    log_size: u32,
    n_rows: u32,
    is_first_col_idx: usize,
    is_active_col_idx: usize,
    main_col_offset: usize,
    interaction_col_offset: usize,
    relations: *const relations_mod.Relations,
    merkle_claims: [merkle_node.N_SUMS]QM31 = .{QM31.zero()} ** merkle_node.N_SUMS,
    poseidon_claims: [poseidon2_air.N_SUMS]QM31 = .{QM31.zero()} ** poseidon2_air.N_SUMS,
    s_merkle_prev: [merkle_node.N_SUMS][4][]const M31 =
        .{EMPTY_PREV} ** merkle_node.N_SUMS,
    s_poseidon_prev: [poseidon2_air.N_SUMS][4][]const M31 =
        .{EMPTY_PREV} ** poseidon2_air.N_SUMS,

    const Adapter = core_air_derive.ComponentAdapter(
        @This(),
        prover_component.ComponentProver,
        prover_component.Trace,
        prover_air_accumulation.DomainEvaluationAccumulator,
    );

    pub fn asProverComponent(self: *const @This()) prover_component.ComponentProver {
        return Adapter.asProverComponent(self);
    }

    pub fn asVerifierComponent(self: *const @This()) core_air_components.Component {
        return Adapter.asVerifierComponent(self);
    }

    pub fn nConstraints(self: *const @This()) usize {
        return switch (self.kind) {
            .merkle => merkle_node.N_CONSTRAINTS,
            .poseidon2 => poseidon2_air.N_CONSTRAINTS + poseidon2_air.N_SUMS,
        };
    }

    pub fn maxConstraintLogDegreeBound(self: *const @This()) u32 {
        return self.log_size + 1;
    }

    pub fn traceLogDegreeBounds(
        self: *const @This(),
        allocator: std.mem.Allocator,
    ) !core_air_components.TraceLogDegreeBounds {
        const preprocessed = try allocator.dupe(u32, &[_]u32{ self.log_size, self.log_size });
        const main = try allocator.alloc(u32, nMainColumns(self.kind));
        @memset(main, self.log_size);
        const interaction = try allocator.alloc(u32, nInteractionColumns(self.kind));
        @memset(interaction, self.log_size);
        return core_air_components.TraceLogDegreeBounds.initOwned(
            try allocator.dupe([]u32, &[_][]u32{ preprocessed, main, interaction }),
        );
    }

    pub fn maskPoints(
        self: *const @This(),
        allocator: std.mem.Allocator,
        point: CirclePointQM31,
        max_log_degree_bound: u32,
    ) !core_air_components.MaskPoints {
        const first = try allocator.dupe(CirclePointQM31, &.{point});
        const active = try allocator.dupe(CirclePointQM31, &.{point});
        const preprocessed = try allocator.dupe([]CirclePointQM31, &.{ first, active });
        const main = try allocator.alloc([]CirclePointQM31, nMainColumns(self.kind));
        for (main) |*column| column.* = try allocator.dupe(CirclePointQM31, &.{point});
        const previous_point = logup.prevRowPoint(max_log_degree_bound, point);
        const interaction = try allocator.alloc([]CirclePointQM31, nInteractionColumns(self.kind));
        for (interaction) |*column| {
            column.* = try allocator.dupe(CirclePointQM31, &.{ point, previous_point });
        }
        return core_air_components.MaskPoints.initOwned(
            try allocator.dupe([][]CirclePointQM31, &.{ preprocessed, main, interaction }),
        );
    }

    pub fn preprocessedColumnIndices(
        self: *const @This(),
        allocator: std.mem.Allocator,
    ) ![]usize {
        return allocator.dupe(usize, &.{ self.is_first_col_idx, self.is_active_col_idx });
    }

    pub fn evaluateConstraintQuotientsAtPoint(
        self: *const @This(),
        point: CirclePointQM31,
        mask: *const core_air_components.MaskValues,
        accumulator: *core_air_accumulation.PointEvaluationAccumulator,
        max_log_degree_bound: u32,
    ) !void {
        if (max_log_degree_bound < self.log_size or mask.items.len < 3)
            return error.InvalidProofShape;
        const preprocessed = mask.items[0];
        const main_mask = mask.items[1];
        const interaction_mask = mask.items[2];
        const n_main = nMainColumns(self.kind);
        const n_interaction = nInteractionColumns(self.kind);
        if (preprocessed.len <= self.is_active_col_idx or
            preprocessed[self.is_first_col_idx].len < 1 or
            preprocessed[self.is_active_col_idx].len < 1 or
            main_mask.len < self.main_col_offset + n_main or
            interaction_mask.len < self.interaction_col_offset + n_interaction)
            return error.InvalidProofShape;
        const fold = max_log_degree_bound - self.log_size;
        const denominator_inv = try core_constraints.cosetVanishing(
            QM31,
            canonic.CanonicCoset.new(self.log_size).coset(),
            point.repeatedDouble(fold),
        ).inv();
        const is_first = preprocessed[self.is_first_col_idx][0];
        const is_active = preprocessed[self.is_active_col_idx][0];

        switch (self.kind) {
            .merkle => {
                const main = try sampleMain(
                    merkle_node.N_MAIN_COLUMNS,
                    main_mask,
                    self.main_col_offset,
                );
                var sums: [merkle_node.N_SUMS]QM31 = undefined;
                var previous: [merkle_node.N_SUMS]QM31 = undefined;
                try sampleInteraction(
                    merkle_node.N_SUMS,
                    interaction_mask,
                    self.interaction_col_offset,
                    &sums,
                    &previous,
                );
                const constraints = merkle_node.evaluate(
                    main,
                    is_active,
                    is_first,
                    sums,
                    previous,
                    self.merkle_claims,
                    self.relations,
                );
                for (constraints) |constraint| accumulator.accumulate(constraint.mul(denominator_inv));
            },
            .poseidon2 => {
                const main = try sampleMain(
                    poseidon2_air.N_MAIN_COLUMNS,
                    main_mask,
                    self.main_col_offset,
                );
                const permutation_constraints = poseidon2_air.evaluate(main, is_active);
                for (permutation_constraints) |constraint| {
                    accumulator.accumulate(constraint.mul(denominator_inv));
                }
                var sums: [poseidon2_air.N_SUMS]QM31 = undefined;
                var previous: [poseidon2_air.N_SUMS]QM31 = undefined;
                try sampleInteraction(
                    poseidon2_air.N_SUMS,
                    interaction_mask,
                    self.interaction_col_offset,
                    &sums,
                    &previous,
                );
                const interaction_constraints = poseidon2_air.interactionConstraints(
                    main,
                    is_first,
                    sums,
                    previous,
                    self.poseidon_claims,
                    self.relations,
                );
                for (interaction_constraints) |constraint| {
                    accumulator.accumulate(constraint.mul(denominator_inv));
                }
            },
        }
    }

    pub fn evaluateConstraintQuotientsOnDomain(
        self: *const @This(),
        trace: *const prover_component.Trace,
        accumulator: *prover_air_accumulation.DomainEvaluationAccumulator,
    ) !void {
        if (trace.polys.items.len < 3) return error.InvalidProofShape;
        const allocator = accumulator.allocator;
        const eval_log_size = self.log_size + 1;
        const eval_domain = canonic.CanonicCoset.new(eval_log_size).circleDomain();
        const eval_size = eval_domain.size();
        const n_main = nMainColumns(self.kind);
        const n_interaction = nInteractionColumns(self.kind);
        const n_previous = n_interaction;
        const n_committed = 2 + n_main + n_interaction;
        const n_sources = n_committed + n_previous;
        const preprocessed = trace.polys.items[0];
        const main_polys = trace.polys.items[1];
        const interaction_polys = trace.polys.items[2];
        if (preprocessed.len <= self.is_active_col_idx or
            main_polys.len < self.main_col_offset + n_main or
            interaction_polys.len < self.interaction_col_offset + n_interaction)
            return error.InvalidProofShape;

        const evaluations = try allocator.alloc([]const M31, n_sources);
        defer allocator.free(evaluations);
        var source: usize = 0;
        const committed = try allocator.alloc(prover_component.Poly, n_committed);
        defer allocator.free(committed);
        committed[0] = preprocessed[self.is_first_col_idx];
        committed[1] = preprocessed[self.is_active_col_idx];
        for (0..n_main) |index| committed[2 + index] = main_polys[self.main_col_offset + index];
        for (0..n_interaction) |index| {
            committed[2 + n_main + index] = interaction_polys[self.interaction_col_offset + index];
        }
        for (committed) |poly| {
            try poly.validate();
            if (poly.log_size != eval_log_size) return error.InvalidProofShape;
            evaluations[source] = poly.values;
            source += 1;
        }

        var extension_buffers = std.ArrayList([]M31).empty;
        defer {
            for (extension_buffers.items) |values| allocator.free(values);
            extension_buffers.deinit(allocator);
        }
        var trace_twiddles = try prover_twiddles.precomputeM31(
            allocator,
            canonic.CanonicCoset.new(self.log_size).circleDomain().half_coset,
        );
        defer prover_twiddles.deinitM31(allocator, &trace_twiddles);
        const trace_twiddle_view = prover_twiddles.TwiddleTree([]const M31).init(
            trace_twiddles.root_coset,
            trace_twiddles.twiddles,
            trace_twiddles.itwiddles,
        );
        switch (self.kind) {
            .merkle => try appendPrevious(
                merkle_node.N_SUMS,
                allocator,
                self.s_merkle_prev,
                self.log_size,
                eval_size,
                trace_twiddle_view,
                evaluations,
                &source,
                &extension_buffers,
            ),
            .poseidon2 => try appendPrevious(
                poseidon2_air.N_SUMS,
                allocator,
                self.s_poseidon_prev,
                self.log_size,
                eval_size,
                trace_twiddle_view,
                evaluations,
                &source,
                &extension_buffers,
            ),
        }
        std.debug.assert(source == n_sources);
        var eval_twiddles = try prover_twiddles.precomputeM31(allocator, eval_domain.half_coset);
        defer prover_twiddles.deinitM31(allocator, &eval_twiddles);
        const eval_twiddle_view = prover_twiddles.TwiddleTree([]const M31).init(
            eval_twiddles.root_coset,
            eval_twiddles.twiddles,
            eval_twiddles.itwiddles,
        );
        try prover_poly.evaluateBuffersWithTwiddles(
            extension_buffers.items,
            eval_domain,
            eval_twiddle_view,
        );

        const trace_coset = canonic.CanonicCoset.new(self.log_size).coset();
        var denominator_inv: [2]M31 = undefined;
        for (&denominator_inv, 0..) |*inverse, index| {
            inverse.* = try core_constraints.cosetVanishing(
                M31,
                trace_coset,
                eval_domain.at(index),
            ).inv();
        }
        var accumulators = try accumulator.columns(
            allocator,
            &.{.{ .log_size = eval_log_size, .n_cols = self.nConstraints() }},
        );
        defer allocator.free(accumulators);
        const column_accumulator = &accumulators[0];
        const main_start: usize = 2;
        const interaction_start = main_start + n_main;
        const previous_start = interaction_start + n_interaction;
        for (0..eval_size) |row| {
            const is_first = QM31.fromBase(evaluations[0][row]);
            const is_active = QM31.fromBase(evaluations[1][row]);
            var row_evaluation = QM31.zero();
            switch (self.kind) {
                .merkle => {
                    const main = readMain(
                        merkle_node.N_MAIN_COLUMNS,
                        evaluations[main_start..][0..merkle_node.N_MAIN_COLUMNS],
                        row,
                    );
                    var sums: [merkle_node.N_SUMS]QM31 = undefined;
                    var previous: [merkle_node.N_SUMS]QM31 = undefined;
                    readInteraction(
                        merkle_node.N_SUMS,
                        evaluations,
                        interaction_start,
                        previous_start,
                        row,
                        &sums,
                        &previous,
                    );
                    const constraints = merkle_node.evaluate(
                        main,
                        is_active,
                        is_first,
                        sums,
                        previous,
                        self.merkle_claims,
                        self.relations,
                    );
                    row_evaluation = combineConstraints(column_accumulator.random_coeff_powers, &constraints);
                },
                .poseidon2 => {
                    const main = readMain(
                        poseidon2_air.N_MAIN_COLUMNS,
                        evaluations[main_start..][0..poseidon2_air.N_MAIN_COLUMNS],
                        row,
                    );
                    const permutation_constraints = poseidon2_air.evaluate(main, is_active);
                    row_evaluation = combineConstraints(
                        column_accumulator.random_coeff_powers,
                        &permutation_constraints,
                    );
                    var sums: [poseidon2_air.N_SUMS]QM31 = undefined;
                    var previous: [poseidon2_air.N_SUMS]QM31 = undefined;
                    readInteraction(
                        poseidon2_air.N_SUMS,
                        evaluations,
                        interaction_start,
                        previous_start,
                        row,
                        &sums,
                        &previous,
                    );
                    const interaction_constraints = poseidon2_air.interactionConstraints(
                        main,
                        is_first,
                        sums,
                        previous,
                        self.poseidon_claims,
                        self.relations,
                    );
                    for (interaction_constraints, 0..) |constraint, index| {
                        const power_index = column_accumulator.random_coeff_powers.len -
                            1 - poseidon2_air.N_CONSTRAINTS - index;
                        row_evaluation = row_evaluation.add(
                            column_accumulator.random_coeff_powers[power_index].mul(constraint),
                        );
                    }
                },
            }
            column_accumulator.accumulate(
                row,
                row_evaluation.mulM31(denominator_inv[row >> self.log_size]),
            );
        }
    }
};

pub fn nMainColumns(kind: Kind) usize {
    return switch (kind) {
        .merkle => merkle_node.N_MAIN_COLUMNS,
        .poseidon2 => poseidon2_air.N_MAIN_COLUMNS,
    };
}

pub fn nInteractionColumns(kind: Kind) usize {
    return switch (kind) {
        .merkle => merkle_node.N_INTERACTION_COLUMNS,
        .poseidon2 => poseidon2_air.N_INTERACTION_COLUMNS,
    };
}

fn sampleMain(
    comptime n: usize,
    columns: [][]QM31,
    offset: usize,
) ![n]QM31 {
    if (columns.len < offset + n) return error.InvalidProofShape;
    var result: [n]QM31 = undefined;
    for (&result, columns[offset..][0..n]) |*value, column| {
        if (column.len < 1) return error.InvalidProofShape;
        value.* = column[0];
    }
    return result;
}

fn sampleInteraction(
    comptime n: usize,
    columns: [][]QM31,
    offset: usize,
    sums: *[n]QM31,
    previous: *[n]QM31,
) !void {
    for (0..n) |index| {
        sums[index] = try sampledSecure(columns, offset + 4 * index, 0);
        previous[index] = try sampledSecure(columns, offset + 4 * index, 1);
    }
}

fn sampledSecure(columns: [][]QM31, offset: usize, point: usize) !QM31 {
    var coordinates: [4]QM31 = undefined;
    for (&coordinates, 0..) |*value, index| {
        if (columns[offset + index].len <= point) return error.InvalidProofShape;
        value.* = columns[offset + index][point];
    }
    return QM31.fromPartialEvals(coordinates);
}

fn appendPrevious(
    comptime n: usize,
    allocator: std.mem.Allocator,
    previous: [n][4][]const M31,
    log_size: u32,
    eval_size: usize,
    twiddles: anytype,
    evaluations: [][]const M31,
    source: *usize,
    buffers: *std.ArrayList([]M31),
) !void {
    const domain = canonic.CanonicCoset.new(log_size).circleDomain();
    for (previous) |set| {
        for (set) |values| {
            if (values.len != domain.size()) return error.InvalidProofShape;
            const evaluation = try prover_eval.CircleEvaluation.init(domain, values);
            var coefficients = try prover_poly.interpolateFromEvaluationWithTwiddles(
                allocator,
                evaluation,
                twiddles,
            );
            defer coefficients.deinit(allocator);
            const extended = try allocator.alloc(M31, eval_size);
            errdefer allocator.free(extended);
            @memcpy(extended[0..coefficients.coefficients().len], coefficients.coefficients());
            @memset(extended[coefficients.coefficients().len..], M31.zero());
            try buffers.append(allocator, extended);
            evaluations[source.*] = extended;
            source.* += 1;
        }
    }
}

fn readMain(comptime n: usize, columns: []const []const M31, row: usize) [n]QM31 {
    var result: [n]QM31 = undefined;
    for (&result, columns) |*value, column| value.* = QM31.fromBase(column[row]);
    return result;
}

fn readInteraction(
    comptime n: usize,
    evaluations: []const []const M31,
    interaction_start: usize,
    previous_start: usize,
    row: usize,
    sums: *[n]QM31,
    previous: *[n]QM31,
) void {
    for (0..n) |index| {
        sums[index] = secureAt(evaluations[interaction_start + 4 * index ..][0..4], row);
        previous[index] = secureAt(evaluations[previous_start + 4 * index ..][0..4], row);
    }
}

fn secureAt(columns: []const []const M31, row: usize) QM31 {
    return QM31.fromM31(columns[0][row], columns[1][row], columns[2][row], columns[3][row]);
}

fn combineConstraints(powers: []const QM31, constraints: []const QM31) QM31 {
    var result = QM31.zero();
    for (constraints, 0..) |constraint, index| {
        result = result.add(powers[powers.len - 1 - index].mul(constraint));
    }
    return result;
}

test "hash component: exact shapes remain pinned" {
    try std.testing.expectEqual(@as(usize, 445), nMainColumns(.poseidon2));
    try std.testing.expectEqual(@as(usize, 8), nInteractionColumns(.poseidon2));
    try std.testing.expectEqual(@as(usize, 10), nMainColumns(.merkle));
    try std.testing.expectEqual(@as(usize, 12), nInteractionColumns(.merkle));
}
