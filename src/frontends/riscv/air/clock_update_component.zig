//! Prover/verifier AIR adapter for the canonical unified clock-gap component.

const std = @import("std");
const core_air_accumulation = @import("../../../core/air/accumulation.zig");
const core_air_components = @import("../../../core/air/components.zig");
const core_air_derive = @import("../../../core/air/derive.zig");
const core_constraints = @import("../../../core/constraints.zig");
const circle = @import("../../../core/circle.zig");
const M31 = @import("../../../core/fields/m31.zig").M31;
const QM31 = @import("../../../core/fields/qm31.zig").QM31;
const canonic = @import("../../../core/poly/circle/canonic.zig");
const utils = @import("../../../core/utils.zig");
const prover_air_accumulation = @import("../../../prover/air/accumulation.zig");
const prover_component = @import("../../../prover/air/component_prover.zig");
const prover_eval = @import("../../../prover/poly/circle/evaluation.zig");
const prover_poly = @import("../../../prover/poly/circle/poly.zig");
const prover_twiddles = @import("../../../prover/poly/twiddles.zig");
const interaction = @import("clock_update_interaction.zig");
const logup = @import("logup.zig");
const relations_mod = @import("relation_challenges.zig");

const CirclePointQM31 = circle.CirclePointQM31;
const EMPTY_PREVIOUS: [interaction.N_INTERACTION_COLUMNS][]const M31 =
    .{&.{}} ** interaction.N_INTERACTION_COLUMNS;

pub const Evaluation = struct {
    values: [3]QM31,

    pub fn allZero(self: Evaluation) bool {
        for (self.values) |value| if (!value.isZero()) return false;
        return true;
    }
};

pub const ClockUpdateComponent = struct {
    log_size: u32,
    is_first_col_idx: usize,
    is_active_col_idx: usize,
    main_col_offset: usize,
    interaction_col_offset: usize,
    relations: *const relations_mod.Relations,
    claim: QM31,
    previous: [interaction.N_INTERACTION_COLUMNS][]const M31 = EMPTY_PREVIOUS,

    const Adapter = core_air_derive.ComponentAdapter(
        @This(),
        prover_component.ComponentProver,
        prover_component.Trace,
        prover_air_accumulation.DomainEvaluationAccumulator,
    );

    pub fn initVerifier(
        log_size: u32,
        is_first_col_idx: usize,
        is_active_col_idx: usize,
        main_col_offset: usize,
        interaction_col_offset: usize,
        relations: *const relations_mod.Relations,
        claim: QM31,
    ) ClockUpdateComponent {
        return init(
            log_size,
            is_first_col_idx,
            is_active_col_idx,
            main_col_offset,
            interaction_col_offset,
            relations,
            claim,
            EMPTY_PREVIOUS,
        );
    }

    pub fn initProver(
        log_size: u32,
        is_first_col_idx: usize,
        is_active_col_idx: usize,
        main_col_offset: usize,
        interaction_col_offset: usize,
        relations: *const relations_mod.Relations,
        claim: QM31,
        previous: [interaction.N_INTERACTION_COLUMNS][]const M31,
    ) !ClockUpdateComponent {
        const size = @as(usize, 1) << @intCast(log_size);
        for (previous) |column| {
            if (column.len != size) return error.InvalidTraceShape;
        }
        return init(
            log_size,
            is_first_col_idx,
            is_active_col_idx,
            main_col_offset,
            interaction_col_offset,
            relations,
            claim,
            previous,
        );
    }

    fn init(
        log_size: u32,
        is_first_col_idx: usize,
        is_active_col_idx: usize,
        main_col_offset: usize,
        interaction_col_offset: usize,
        relations: *const relations_mod.Relations,
        claim: QM31,
        previous: [interaction.N_INTERACTION_COLUMNS][]const M31,
    ) ClockUpdateComponent {
        return .{
            .log_size = log_size,
            .is_first_col_idx = is_first_col_idx,
            .is_active_col_idx = is_active_col_idx,
            .main_col_offset = main_col_offset,
            .interaction_col_offset = interaction_col_offset,
            .relations = relations,
            .claim = claim,
            .previous = previous,
        };
    }

    pub fn asVerifierComponent(self: *const @This()) core_air_components.Component {
        return Adapter.asVerifierComponent(self);
    }

    pub fn asProverComponent(self: *const @This()) prover_component.ComponentProver {
        return Adapter.asProverComponent(self);
    }

    pub fn nConstraints(_: *const @This()) usize {
        return 3;
    }

    pub fn maxConstraintLogDegreeBound(self: *const @This()) u32 {
        return self.log_size + 1;
    }

    pub fn traceLogDegreeBounds(
        self: *const @This(),
        allocator: std.mem.Allocator,
    ) !core_air_components.TraceLogDegreeBounds {
        const preprocessed = try allocator.dupe(u32, &.{ self.log_size, self.log_size });
        errdefer allocator.free(preprocessed);
        const main = try allocator.alloc(u32, interaction.N_MAIN_COLUMNS);
        errdefer allocator.free(main);
        @memset(main, self.log_size);
        const secure = try allocator.alloc(u32, interaction.N_INTERACTION_COLUMNS);
        errdefer allocator.free(secure);
        @memset(secure, self.log_size);
        return core_air_components.TraceLogDegreeBounds.initOwned(
            try allocator.dupe([]u32, &.{ preprocessed, main, secure }),
        );
    }

    pub fn maskPoints(
        self: *const @This(),
        allocator: std.mem.Allocator,
        point: CirclePointQM31,
        max_log_degree_bound: u32,
    ) !core_air_components.MaskPoints {
        if (max_log_degree_bound < self.log_size) return error.InvalidProofShape;
        const preprocessed = try currentPointColumns(allocator, 2, point);
        errdefer freePointColumns(allocator, preprocessed);
        const main = try currentPointColumns(allocator, interaction.N_MAIN_COLUMNS, point);
        errdefer freePointColumns(allocator, main);
        const secure = try currentAndPreviousPointColumns(
            allocator,
            interaction.N_INTERACTION_COLUMNS,
            point,
            logup.prevRowPoint(max_log_degree_bound, point),
        );
        errdefer freePointColumns(allocator, secure);
        return core_air_components.MaskPoints.initOwned(
            try allocator.dupe([][]CirclePointQM31, &.{ preprocessed, main, secure }),
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
        if (max_log_degree_bound < self.log_size or mask.items.len < 3) {
            return error.InvalidProofShape;
        }
        const preprocessed = mask.items[0];
        const main = mask.items[1];
        const secure = mask.items[2];
        if (preprocessed.len <= @max(self.is_first_col_idx, self.is_active_col_idx) or
            preprocessed[self.is_first_col_idx].len < 1 or
            preprocessed[self.is_active_col_idx].len < 1 or
            main.len < self.main_col_offset + interaction.N_MAIN_COLUMNS or
            secure.len < self.interaction_col_offset + interaction.N_INTERACTION_COLUMNS)
        {
            return error.InvalidProofShape;
        }
        var sampled: [interaction.N_MAIN_COLUMNS]QM31 = undefined;
        for (&sampled, main[self.main_col_offset..][0..interaction.N_MAIN_COLUMNS]) |*value, column| {
            if (column.len < 1) return error.InvalidProofShape;
            value.* = column[0];
        }
        const evaluation = try self.evaluateRow(
            &sampled,
            try sampledSecure(secure, self.interaction_col_offset, 0),
            try sampledSecure(secure, self.interaction_col_offset, 1),
            preprocessed[self.is_first_col_idx][0],
            preprocessed[self.is_active_col_idx][0],
        );
        const denominator_inv = try core_constraints.cosetVanishing(
            QM31,
            canonic.CanonicCoset.new(self.log_size).coset(),
            point.repeatedDouble(max_log_degree_bound - self.log_size),
        ).inv();
        for (evaluation.values) |constraint| {
            accumulator.accumulate(constraint.mul(denominator_inv));
        }
    }

    pub fn evaluateConstraintQuotientsOnDomain(
        self: *const @This(),
        trace_data: *const prover_component.Trace,
        accumulator: *prover_air_accumulation.DomainEvaluationAccumulator,
    ) !void {
        if (trace_data.polys.items.len < 3) return error.InvalidProofShape;
        const preprocessed = trace_data.polys.items[0];
        const main = trace_data.polys.items[1];
        const secure = trace_data.polys.items[2];
        if (preprocessed.len <= @max(self.is_first_col_idx, self.is_active_col_idx) or
            main.len < self.main_col_offset + interaction.N_MAIN_COLUMNS or
            secure.len < self.interaction_col_offset + interaction.N_INTERACTION_COLUMNS)
        {
            return error.InvalidProofShape;
        }

        const allocator = accumulator.allocator;
        const eval_log_size = self.log_size + 1;
        const eval_domain = canonic.CanonicCoset.new(eval_log_size).circleDomain();
        const eval_size = eval_domain.size();
        const n_committed = 2 + interaction.N_MAIN_COLUMNS + interaction.N_INTERACTION_COLUMNS;
        const n_sources = n_committed + interaction.N_INTERACTION_COLUMNS;
        const evaluations = try allocator.alloc([]const M31, n_sources);
        defer allocator.free(evaluations);
        var source: usize = 0;
        evaluations[source] = try committedValues(preprocessed[self.is_first_col_idx], eval_log_size);
        source += 1;
        evaluations[source] = try committedValues(preprocessed[self.is_active_col_idx], eval_log_size);
        source += 1;
        for (main[self.main_col_offset..][0..interaction.N_MAIN_COLUMNS]) |poly| {
            evaluations[source] = try committedValues(poly, eval_log_size);
            source += 1;
        }
        for (secure[self.interaction_col_offset..][0..interaction.N_INTERACTION_COLUMNS]) |poly| {
            evaluations[source] = try committedValues(poly, eval_log_size);
            source += 1;
        }

        var extension_buffers = std.ArrayList([]M31).empty;
        defer {
            for (extension_buffers.items) |values| allocator.free(values);
            extension_buffers.deinit(allocator);
        }
        try appendPrevious(
            allocator,
            self.previous,
            self.log_size,
            eval_size,
            evaluations,
            &source,
            &extension_buffers,
        );
        std.debug.assert(source == n_sources);
        if (extension_buffers.items.len != 0) {
            var twiddles = try prover_twiddles.precomputeM31(allocator, eval_domain.half_coset);
            defer prover_twiddles.deinitM31(allocator, &twiddles);
            try prover_poly.evaluateBuffersWithTwiddles(
                extension_buffers.items,
                eval_domain,
                prover_twiddles.TwiddleTree([]const M31).init(
                    twiddles.root_coset,
                    twiddles.twiddles,
                    twiddles.itwiddles,
                ),
            );
        }

        const denominator_inv = try quotientDenominators(
            allocator,
            self.log_size,
            eval_log_size,
            eval_domain,
        );
        defer allocator.free(denominator_inv);
        var accumulators = try accumulator.columns(
            allocator,
            &.{.{ .log_size = eval_log_size, .n_cols = self.nConstraints() }},
        );
        defer allocator.free(accumulators);
        const column_accumulator = &accumulators[0];
        const main_start: usize = 2;
        const secure_start = main_start + interaction.N_MAIN_COLUMNS;
        const previous_start = secure_start + interaction.N_INTERACTION_COLUMNS;
        const denominator_shift: std.math.Log2Int(usize) = @intCast(self.log_size);
        for (0..eval_size) |row| {
            var sampled: [interaction.N_MAIN_COLUMNS]QM31 = undefined;
            for (&sampled, evaluations[main_start..][0..interaction.N_MAIN_COLUMNS]) |*value, column| {
                value.* = QM31.fromBase(column[row]);
            }
            const evaluation = try self.evaluateRow(
                &sampled,
                secureAt(evaluations[secure_start..][0..interaction.N_INTERACTION_COLUMNS], row),
                secureAt(evaluations[previous_start..][0..interaction.N_INTERACTION_COLUMNS], row),
                QM31.fromBase(evaluations[0][row]),
                QM31.fromBase(evaluations[1][row]),
            );
            var folded = QM31.zero();
            for (evaluation.values, 0..) |constraint, index| {
                const powers = column_accumulator.random_coeff_powers;
                folded = folded.add(powers[powers.len - 1 - index].mul(constraint));
            }
            column_accumulator.accumulate(
                row,
                folded.mulM31(denominator_inv[row >> denominator_shift]),
            );
        }
    }

    pub fn evaluateRow(
        self: *const @This(),
        main: []const QM31,
        current: QM31,
        previous: QM31,
        is_first: QM31,
        is_active: QM31,
    ) !Evaluation {
        const row = try interaction.Row.fromMain(main);
        return .{ .values = .{
            row.enabler.mul(QM31.one().sub(row.enabler)),
            row.enabler.sub(is_active),
            logup.pairConstraint(
                current,
                previous,
                is_first,
                self.claim,
                try interaction.pair(row, self.relations),
            ),
        } };
    }
};

fn committedValues(poly: prover_component.Poly, expected_log_size: u32) ![]const M31 {
    try poly.validate();
    if (poly.log_size != expected_log_size) return error.InvalidProofShape;
    return poly.values;
}

fn sampledSecure(columns: [][]QM31, offset: usize, point: usize) !QM31 {
    var coordinates: [interaction.N_INTERACTION_COLUMNS]QM31 = undefined;
    for (&coordinates, 0..) |*value, index| {
        if (columns[offset + index].len <= point) return error.InvalidProofShape;
        value.* = columns[offset + index][point];
    }
    return QM31.fromPartialEvals(coordinates);
}

fn secureAt(columns: []const []const M31, row: usize) QM31 {
    return QM31.fromM31(columns[0][row], columns[1][row], columns[2][row], columns[3][row]);
}

fn appendPrevious(
    allocator: std.mem.Allocator,
    previous: [interaction.N_INTERACTION_COLUMNS][]const M31,
    log_size: u32,
    eval_size: usize,
    evaluations: [][]const M31,
    source: *usize,
    buffers: *std.ArrayList([]M31),
) !void {
    const domain = canonic.CanonicCoset.new(log_size).circleDomain();
    var twiddles = try prover_twiddles.precomputeM31(allocator, domain.half_coset);
    defer prover_twiddles.deinitM31(allocator, &twiddles);
    const view = prover_twiddles.TwiddleTree([]const M31).init(
        twiddles.root_coset,
        twiddles.twiddles,
        twiddles.itwiddles,
    );
    for (previous) |values| {
        if (values.len != domain.size()) return error.InvalidProofShape;
        const evaluation = try prover_eval.CircleEvaluation.init(domain, values);
        var coefficients = try prover_poly.interpolateFromEvaluationWithTwiddles(
            allocator,
            evaluation,
            view,
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

fn quotientDenominators(
    allocator: std.mem.Allocator,
    log_size: u32,
    eval_log_size: u32,
    eval_domain: anytype,
) ![]M31 {
    const extension_bits: u5 = @intCast(eval_log_size - log_size);
    const result = try allocator.alloc(M31, @as(usize, 1) << extension_bits);
    errdefer allocator.free(result);
    const coset = canonic.CanonicCoset.new(log_size).coset();
    for (result, 0..) |*inverse, index| {
        inverse.* = try core_constraints.cosetVanishing(
            M31,
            coset,
            eval_domain.at(utils.bitReverseIndex(index, extension_bits)),
        ).inv();
    }
    return result;
}

fn currentPointColumns(
    allocator: std.mem.Allocator,
    count: usize,
    point: CirclePointQM31,
) ![][]CirclePointQM31 {
    const result = try allocator.alloc([]CirclePointQM31, count);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |column| allocator.free(column);
        allocator.free(result);
    }
    for (result) |*column| {
        column.* = try allocator.dupe(CirclePointQM31, &.{point});
        initialized += 1;
    }
    return result;
}

fn currentAndPreviousPointColumns(
    allocator: std.mem.Allocator,
    count: usize,
    point: CirclePointQM31,
    previous: CirclePointQM31,
) ![][]CirclePointQM31 {
    const result = try allocator.alloc([]CirclePointQM31, count);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |column| allocator.free(column);
        allocator.free(result);
    }
    for (result) |*column| {
        column.* = try allocator.dupe(CirclePointQM31, &.{ point, previous });
        initialized += 1;
    }
    return result;
}

fn freePointColumns(allocator: std.mem.Allocator, columns: [][]CirclePointQM31) void {
    for (columns) |column| allocator.free(column);
    allocator.free(columns);
}
