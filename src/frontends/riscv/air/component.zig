//! Per-shard RISC-V AIR component with real LogUp constraints.
//!
//! Every component references three committed trees:
//!   tree 0: its IsFirst column at `preprocessed_col_idx`;
//!   tree 1: `desc.n_columns` main columns starting at `main_col_offset`;
//!   tree 2: its interaction columns starting at `interaction_col_offset`
//!           (12 for opcode shards, 7 for the program ROM, 0 otherwise).
//!
//! Opcode components enforce the two pairs-batched LogUp transitions (CPU
//! state chain and program-bus consume); the program component enforces the
//! ROM emission column. All other infrastructure components are `silent`:
//! they contribute a single literal-zero constraint so the accumulator
//! bookkeeping stays uniform.

const std = @import("std");
const core_air_accumulation = @import("../../../core/air/accumulation.zig");
const core_air_components = @import("../../../core/air/components.zig");
const core_air_derive = @import("../../../core/air/derive.zig");
const core_constraints = @import("../../../core/constraints.zig");
const circle = @import("../../../core/circle.zig");
const m31 = @import("../../../core/fields/m31.zig");
const qm31 = @import("../../../core/fields/qm31.zig");
const canonic = @import("../../../core/poly/circle/canonic.zig");
const utils = @import("../../../core/utils.zig");
const prover_air_accumulation = @import("../../../prover/air/accumulation.zig");
const prover_component = @import("../../../prover/air/component_prover.zig");
const prover_eval = @import("../../../prover/poly/circle/evaluation.zig");
const prover_poly = @import("../../../prover/poly/circle/poly.zig");
const prover_twiddles = @import("../../../prover/poly/twiddles.zig");
const interaction = @import("interaction.zig");
const interaction_gen = @import("interaction_gen.zig");
const logup = @import("logup.zig");
const semantics = @import("semantics/mod.zig");
const trace_mod = @import("../runner/trace.zig");

const M31 = m31.M31;
const QM31 = qm31.QM31;
const CirclePointQM31 = circle.CirclePointQM31;

/// Per-family component descriptor within the proof.
pub const FamilyComponentDesc = struct {
    family: trace_mod.OpcodeFamily,
    log_size: u32,
    n_rows: u32,
    n_columns: u32 = 10,
};

/// Constraint role of a component.
pub const Kind = enum { opcode, program, silent };

/// Number of committed M31 interaction columns for a component kind.
pub fn nInteractionCols(kind: Kind) u32 {
    return switch (kind) {
        .opcode => @intCast(interaction_gen.OPCODE_INTERACTION_COLS),
        .program => @intCast(interaction_gen.PROGRAM_INTERACTION_COLS),
        .silent => 0,
    };
}

const EMPTY_PREV: [4][]const M31 = .{ &.{}, &.{}, &.{}, &.{} };

pub const RiscVTraceComponent = struct {
    desc: FamilyComponentDesc,
    initial_pc: u32,
    total_steps: u32,
    /// Deterministic selector columns in tree 0.
    is_first_col_idx: usize,
    is_active_col_idx: usize,
    /// Offset of this component's first column within tree 1 (main trace).
    main_col_offset: usize,
    kind: Kind,
    lookup: *const interaction.LookupElements,
    /// Offset of this component's first column within tree 2 (interaction).
    interaction_col_offset: usize = 0,
    state_claim: QM31 = QM31.zero(),
    prog_claim: QM31 = QM31.zero(),
    rom_claim: QM31 = QM31.zero(),
    /// Trace-order-shifted S coordinate columns in committed order at
    /// `desc.log_size`. Prover-side only (empty on the verifier); consumed by
    /// the on-domain evaluator as uncommitted column sources.
    s_state_prev: [4][]const M31 = EMPTY_PREV,
    s_prog_prev: [4][]const M31 = EMPTY_PREV,
    s_rom_prev: [4][]const M31 = EMPTY_PREV,

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
            .opcode => 2 + switch (self.desc.family) {
                .base_alu_reg => semantics.base_alu_reg.N_CONSTRAINTS,
                .base_alu_imm => semantics.base_alu_imm.N_CONSTRAINTS,
                else => 0,
            },
            .program => 2,
            .silent => 1,
        };
    }

    pub fn maxConstraintLogDegreeBound(self: *const @This()) u32 {
        // The pairs-batched LogUp constraint is degree 3, whose quotient fits
        // in the log_size + 1 coefficient space (the standard stwo bound with
        // one constraint-evaluation blowup bit).
        return self.desc.log_size + 1;
    }

    pub fn traceLogDegreeBounds(
        self: *const @This(),
        allocator: std.mem.Allocator,
    ) !core_air_components.TraceLogDegreeBounds {
        const preprocessed = try allocator.dupe(u32, &[_]u32{
            self.desc.log_size,
            self.desc.log_size,
        });
        const main = try allocator.alloc(u32, self.desc.n_columns);
        @memset(main, self.desc.log_size);
        const inter = try allocator.alloc(u32, nInteractionCols(self.kind));
        @memset(inter, self.desc.log_size);
        return core_air_components.TraceLogDegreeBounds.initOwned(
            try allocator.dupe([]u32, &[_][]u32{ preprocessed, main, inter }),
        );
    }

    pub fn maskPoints(
        self: *const @This(),
        allocator: std.mem.Allocator,
        point: CirclePointQM31,
        max_log_degree_bound: u32,
    ) !core_air_components.MaskPoints {
        const is_first_col = try allocator.dupe(CirclePointQM31, &[_]CirclePointQM31{point});
        const is_active_col = try allocator.dupe(CirclePointQM31, &[_]CirclePointQM31{point});
        const preprocessed_cols = try allocator.dupe(
            []CirclePointQM31,
            &[_][]CirclePointQM31{ is_first_col, is_active_col },
        );

        const n = self.desc.n_columns;
        const main_cols = try allocator.alloc([]CirclePointQM31, n);
        for (0..n) |i| {
            main_cols[i] = try allocator.dupe(CirclePointQM31, &[_]CirclePointQM31{point});
        }

        // The PCS samples a column committed at log k+1 at the FOLDED point
        // double^(max_log_degree_bound - k)(q) for a requested point q. The
        // canonic step halves per doubling, so subtracting the step of the
        // MAXIMAL coset from the request shifts the folded point by exactly
        // this component's own coset step — the previous trace row.
        const prev_point = logup.prevRowPoint(max_log_degree_bound, point);
        const n_inter = nInteractionCols(self.kind);
        const inter_cols = try allocator.alloc([]CirclePointQM31, n_inter);
        for (0..n_inter) |i| {
            inter_cols[i] = try allocator.dupe(
                CirclePointQM31,
                &[_]CirclePointQM31{ point, prev_point },
            );
        }

        return core_air_components.MaskPoints.initOwned(
            try allocator.dupe([][]CirclePointQM31, &[_][][]CirclePointQM31{
                preprocessed_cols,
                main_cols,
                inter_cols,
            }),
        );
    }

    pub fn preprocessedColumnIndices(
        self: *const @This(),
        allocator: std.mem.Allocator,
    ) ![]usize {
        return allocator.dupe(
            usize,
            &[_]usize{ self.is_first_col_idx, self.is_active_col_idx },
        );
    }

    fn sampledSecure(cols: [][]QM31, base: usize, point_idx: usize) !QM31 {
        var coords: [4]QM31 = undefined;
        for (0..4) |c| {
            if (cols[base + c].len <= point_idx) return error.InvalidProofShape;
            coords[c] = cols[base + c][point_idx];
        }
        return QM31.fromPartialEvals(coords);
    }

    fn sampledMainRow(
        comptime n: usize,
        main: [][]QM31,
        offset: usize,
    ) ![n]QM31 {
        if (main.len < offset + n) return error.InvalidProofShape;
        var row: [n]QM31 = undefined;
        for (&row, main[offset .. offset + n]) |*value, column| {
            if (column.len < 1) return error.InvalidProofShape;
            value.* = column[0];
        }
        return row;
    }

    pub fn evaluateConstraintQuotientsAtPoint(
        self: *const @This(),
        point: CirclePointQM31,
        mask: *const core_air_components.MaskValues,
        evaluation_accumulator: *core_air_accumulation.PointEvaluationAccumulator,
        max_log_degree_bound: u32,
    ) !void {
        if (self.kind == .silent) {
            evaluation_accumulator.accumulate(QM31.zero());
            return;
        }
        if (max_log_degree_bound < self.desc.log_size) return error.InvalidProofShape;
        if (mask.items.len < 3) return error.InvalidProofShape;
        const pp = mask.items[0];
        const main = mask.items[1];
        const inter = mask.items[2];
        const o = self.interaction_col_offset;
        if (pp.len <= self.is_active_col_idx or
            pp[self.is_first_col_idx].len < 1 or
            pp[self.is_active_col_idx].len < 1)
            return error.InvalidProofShape;
        if (main.len < self.main_col_offset + self.desc.n_columns) return error.InvalidProofShape;
        if (inter.len < o + nInteractionCols(self.kind)) return error.InvalidProofShape;
        for (inter[o .. o + nInteractionCols(self.kind)]) |col| {
            if (col.len < 2) return error.InvalidProofShape;
        }
        for (main[self.main_col_offset .. self.main_col_offset + 2]) |col| {
            if (col.len < 1) return error.InvalidProofShape;
        }

        // The sampled values of this component's columns (committed at
        // log_size + 1) are the base polynomials evaluated at the folded
        // point double^fold(point); check the constraint there.
        const fold = max_log_degree_bound - self.desc.log_size;
        const folded_point = point.repeatedDouble(fold);
        const denominator_inv = try core_constraints.cosetVanishing(
            QM31,
            canonic.CanonicCoset.new(self.desc.log_size).coset(),
            folded_point,
        ).inv();
        const is_first = pp[self.is_first_col_idx][0];
        const is_active = pp[self.is_active_col_idx][0];

        switch (self.kind) {
            .opcode => {
                const pc = main[self.main_col_offset + 1][0];
                const clk = main[self.main_col_offset + 0][0];
                const bus = self.main_col_offset + self.desc.n_columns - 3;
                const next_pc = main[bus][0];
                const inst_lo = main[bus + 1][0];
                const inst_hi = main[bus + 2][0];
                const s_state = try sampledSecure(inter, o, 0);
                const s_state_prev = try sampledSecure(inter, o, 1);
                const s_prog = try sampledSecure(inter, o + 4, 0);
                const s_prog_prev = try sampledSecure(inter, o + 4, 1);

                const state_pair = logup.stateChainPair(self.lookup, pc, clk, next_pc, is_active);
                evaluation_accumulator.accumulate(
                    logup.pairConstraint(s_state, s_state_prev, is_first, self.state_claim, state_pair)
                        .mul(denominator_inv),
                );
                const prog_pair = logup.programConsume(self.lookup, pc, inst_lo, inst_hi, is_active);
                evaluation_accumulator.accumulate(
                    logup.pairConstraint(s_prog, s_prog_prev, is_first, self.prog_claim, prog_pair)
                        .mul(denominator_inv),
                );
                switch (self.desc.family) {
                    .base_alu_reg => {
                        const sampled = try sampledMainRow(
                            semantics.base_alu_reg.N_MAIN_COLUMNS,
                            main,
                            self.main_col_offset,
                        );
                        const row = try semantics.base_alu_reg.Row.fromMainColumns(&sampled);
                        const constraints = semantics.base_alu_reg.evaluate(row, is_active);
                        for (constraints.values) |constraint| {
                            evaluation_accumulator.accumulate(constraint.mul(denominator_inv));
                        }
                    },
                    .base_alu_imm => {
                        const sampled = try sampledMainRow(
                            semantics.base_alu_imm.N_MAIN_COLUMNS,
                            main,
                            self.main_col_offset,
                        );
                        const row = try semantics.base_alu_imm.Row.fromMainColumns(&sampled);
                        const constraints = semantics.base_alu_imm.evaluate(row, is_active);
                        for (constraints.values) |constraint| {
                            evaluation_accumulator.accumulate(constraint.mul(denominator_inv));
                        }
                    },
                    else => {},
                }
            },
            .program => {
                const main_o = self.main_col_offset;
                const enabler = main[main_o][0];
                const pc = main[main_o + 1][0];
                const radix = QM31.fromBase(M31.fromCanonical(256));
                const inst_lo = main[main_o + 2][0].add(main[main_o + 3][0].mul(radix));
                const inst_hi = main[main_o + 4][0].add(main[main_o + 5][0].mul(radix));
                const mult = main[main_o + 6][0].mul(is_active);
                const s_rom = try sampledSecure(inter, o, 0);
                const s_rom_prev = try sampledSecure(inter, o, 1);

                const rom_pair = logup.programEmit(self.lookup, pc, inst_lo, inst_hi, mult);
                evaluation_accumulator.accumulate(
                    logup.pairConstraint(s_rom, s_rom_prev, is_first, self.rom_claim, rom_pair)
                        .mul(denominator_inv),
                );
                evaluation_accumulator.accumulate(
                    enabler.sub(is_active).mul(denominator_inv),
                );
            },
            .silent => unreachable,
        }
    }

    pub fn evaluateConstraintQuotientsOnDomain(
        self: *const @This(),
        trace: *const prover_component.Trace,
        evaluation_accumulator: *prover_air_accumulation.DomainEvaluationAccumulator,
    ) !void {
        if (self.kind == .silent) {
            try evaluation_accumulator.accumulateConstant(self.desc.log_size + 1, QM31.zero());
            return;
        }

        const allocator = evaluation_accumulator.allocator;
        const log_size = self.desc.log_size;
        // Evaluate the quotient on the committed LDE domain (log_size + 1):
        // the retained commitment columns already hold those values in
        // committed order. The accumulator position-lifts the bucket to the
        // composition domain, which composes the quotient with the doubling
        // map — exactly matching the folded points at which the PCS samples
        // this component's columns for the at-point OODS check.
        const eval_log_size = log_size + 1;
        const eval_domain = canonic.CanonicCoset.new(eval_log_size).circleDomain();
        const eval_size = eval_domain.size();

        if (trace.polys.items.len < 3) return error.InvalidProofShape;
        const pp = trace.polys.items[0];
        const main = trace.polys.items[1];
        const inter = trace.polys.items[2];
        const n_inter: usize = nInteractionCols(self.kind);
        if (pp.len <= self.is_active_col_idx) return error.InvalidProofShape;
        if (main.len < self.main_col_offset + self.desc.n_columns) return error.InvalidProofShape;
        if (inter.len < self.interaction_col_offset + n_inter) return error.InvalidProofShape;

        // Source order is selectors, relation inputs from the pre-challenge
        // main tree, cumulative interaction columns, then shifted S columns.
        const has_direct_semantics = self.kind == .opcode and switch (self.desc.family) {
            .base_alu_reg, .base_alu_imm => true,
            else => false,
        };
        const opcode_main_sources: usize = if (has_direct_semantics)
            self.desc.n_columns
        else
            5;
        const n_sources: usize = switch (self.kind) {
            .opcode => 2 + opcode_main_sources + n_inter + 8,
            .program => 2 + 7 + n_inter + 4,
            .silent => unreachable,
        };
        const evaluations = try allocator.alloc([]const M31, n_sources);
        defer allocator.free(evaluations);

        var extension_buffers = std.ArrayList([]M31).empty;
        defer {
            for (extension_buffers.items) |values| allocator.free(values);
            extension_buffers.deinit(allocator);
        }

        var trace_twiddles = try prover_twiddles.precomputeM31(
            allocator,
            canonic.CanonicCoset.new(log_size).circleDomain().half_coset,
        );
        defer prover_twiddles.deinitM31(allocator, &trace_twiddles);
        const trace_twiddle_view = prover_twiddles.TwiddleTree([]const M31).init(
            trace_twiddles.root_coset,
            trace_twiddles.twiddles,
            trace_twiddles.itwiddles,
        );

        var source_index: usize = 0;
        // Committed polynomials: deterministic selectors, relation inputs
        // from main, and cumulative columns from interaction.
        {
            var polys_buf: [96]prover_component.Poly = undefined;
            var n_polys: usize = 0;
            polys_buf[n_polys] = pp[self.is_first_col_idx];
            n_polys += 1;
            polys_buf[n_polys] = pp[self.is_active_col_idx];
            n_polys += 1;
            if (self.kind == .opcode) {
                if (has_direct_semantics) {
                    for (0..self.desc.n_columns) |i| {
                        polys_buf[n_polys] = main[self.main_col_offset + i];
                        n_polys += 1;
                    }
                } else {
                    polys_buf[n_polys] = main[self.main_col_offset + 0]; // clk
                    n_polys += 1;
                    polys_buf[n_polys] = main[self.main_col_offset + 1]; // pc
                    n_polys += 1;
                    const bus = self.main_col_offset + self.desc.n_columns - 3;
                    for (0..3) |i| {
                        polys_buf[n_polys] = main[bus + i];
                        n_polys += 1;
                    }
                }
            } else {
                for (0..7) |i| {
                    polys_buf[n_polys] = main[self.main_col_offset + i];
                    n_polys += 1;
                }
            }
            for (0..n_inter) |i| {
                polys_buf[n_polys] = inter[self.interaction_col_offset + i];
                n_polys += 1;
            }
            for (polys_buf[0..n_polys]) |poly| {
                try poly.validate();
                // The committed column with one blowup bit is already the
                // quotient-domain evaluation in committed order.
                if (poly.log_size != eval_log_size) return error.InvalidProofShape;
                evaluations[source_index] = poly.values;
                source_index += 1;
            }
        }
        // Uncommitted shifted S columns: interpolate committed-order values on
        // the trace domain, then extend exactly like the committed columns.
        {
            const prev_sets: []const [4][]const M31 = switch (self.kind) {
                .opcode => &.{ self.s_state_prev, self.s_prog_prev },
                .program => &.{self.s_rom_prev},
                .silent => unreachable,
            };
            const trace_domain = canonic.CanonicCoset.new(log_size).circleDomain();
            for (prev_sets) |prev_set| {
                for (prev_set) |values| {
                    if (values.len != trace_domain.size()) return error.InvalidProofShape;
                    const evaluation = try prover_eval.CircleEvaluation.init(trace_domain, values);
                    var coeffs = try prover_poly.interpolateFromEvaluationWithTwiddles(
                        allocator,
                        evaluation,
                        trace_twiddle_view,
                    );
                    defer coeffs.deinit(allocator);
                    evaluations[source_index] = try appendExtensionBuffer(
                        allocator,
                        &extension_buffers,
                        coeffs.coefficients(),
                        eval_size,
                    );
                    source_index += 1;
                }
            }
        }
        std.debug.assert(source_index == n_sources);

        if (extension_buffers.items.len != 0) {
            var eval_twiddles = try prover_twiddles.precomputeM31(allocator, eval_domain.half_coset);
            defer prover_twiddles.deinitM31(allocator, &eval_twiddles);
            const twiddle_view = prover_twiddles.TwiddleTree([]const M31).init(
                eval_twiddles.root_coset,
                eval_twiddles.twiddles,
                eval_twiddles.itwiddles,
            );
            try prover_poly.evaluateBuffersWithTwiddles(
                extension_buffers.items,
                eval_domain,
                twiddle_view,
            );
        }

        // The trace-coset vanishing polynomial is block-constant over the
        // extended domain in committed order: block b (of 2^log_size rows)
        // carries the value at domain point index bitrev(b, extension_bits)
        // (see the geometry test below). With a single extension bit the
        // reversal is the identity, which is why the wide-Fibonacci template
        // can use `at(k)` directly.
        const extension_bits: u5 = @intCast(eval_log_size - log_size);
        const trace_coset = canonic.CanonicCoset.new(log_size).coset();
        const denominator_inv = try allocator.alloc(M31, @as(usize, 1) << extension_bits);
        defer allocator.free(denominator_inv);
        for (denominator_inv, 0..) |*inv, k| {
            inv.* = try core_constraints.cosetVanishing(
                M31,
                trace_coset,
                eval_domain.at(utils.bitReverseIndex(k, extension_bits)),
            ).inv();
        }

        var accumulators = try evaluation_accumulator.columns(
            allocator,
            &[_]prover_air_accumulation.ColumnRequest{.{
                .log_size = eval_log_size,
                .n_cols = self.nConstraints(),
            }},
        );
        defer allocator.free(accumulators);
        var column_accumulator = &accumulators[0];

        const denominator_shift: std.math.Log2Int(usize) = @intCast(log_size);
        for (0..eval_size) |row| {
            const is_first = QM31.fromBase(evaluations[0][row]);
            const is_active = QM31.fromBase(evaluations[1][row]);
            var row_evaluation: QM31 = undefined;
            switch (self.kind) {
                .opcode => {
                    const main_start: usize = 2;
                    const inter_start = main_start + opcode_main_sources;
                    const prev_start = inter_start + n_inter;
                    const clk = QM31.fromBase(evaluations[main_start][row]);
                    const pc = QM31.fromBase(evaluations[main_start + 1][row]);
                    const bus = if (has_direct_semantics)
                        main_start + self.desc.n_columns - 3
                    else
                        main_start + 2;
                    const next_pc = QM31.fromBase(evaluations[bus][row]);
                    const inst_lo = QM31.fromBase(evaluations[bus + 1][row]);
                    const inst_hi = QM31.fromBase(evaluations[bus + 2][row]);
                    const s_state = secureAt(evaluations[inter_start .. inter_start + 4], row);
                    const s_prog = secureAt(evaluations[inter_start + 4 .. inter_start + 8], row);
                    const s_state_prev = secureAt(evaluations[prev_start .. prev_start + 4], row);
                    const s_prog_prev = secureAt(evaluations[prev_start + 4 .. prev_start + 8], row);

                    const c_state = logup.pairConstraint(
                        s_state,
                        s_state_prev,
                        is_first,
                        self.state_claim,
                        logup.stateChainPair(self.lookup, pc, clk, next_pc, is_active),
                    );
                    const c_prog = logup.pairConstraint(
                        s_prog,
                        s_prog_prev,
                        is_first,
                        self.prog_claim,
                        logup.programConsume(self.lookup, pc, inst_lo, inst_hi, is_active),
                    );
                    const powers = column_accumulator.random_coeff_powers;
                    row_evaluation = powers[powers.len - 1].mul(c_state)
                        .add(powers[powers.len - 2].mul(c_prog));
                    if (self.desc.family == .base_alu_reg) {
                        var sampled: [semantics.base_alu_reg.N_MAIN_COLUMNS]QM31 = undefined;
                        for (&sampled, 0..) |*value, column| {
                            value.* = QM31.fromBase(evaluations[main_start + column][row]);
                        }
                        const semantic_row = try semantics.base_alu_reg.Row.fromMainColumns(&sampled);
                        const constraints = semantics.base_alu_reg.evaluate(semantic_row, is_active);
                        for (constraints.values, 0..) |constraint, index| {
                            row_evaluation = row_evaluation.add(
                                powers[powers.len - 3 - index].mul(constraint),
                            );
                        }
                    }
                    if (self.desc.family == .base_alu_imm) {
                        var sampled: [semantics.base_alu_imm.N_MAIN_COLUMNS]QM31 = undefined;
                        for (&sampled, 0..) |*value, column| {
                            value.* = QM31.fromBase(evaluations[main_start + column][row]);
                        }
                        const semantic_row = try semantics.base_alu_imm.Row.fromMainColumns(&sampled);
                        const constraints = semantics.base_alu_imm.evaluate(semantic_row, is_active);
                        for (constraints.values, 0..) |constraint, index| {
                            row_evaluation = row_evaluation.add(
                                powers[powers.len - 3 - index].mul(constraint),
                            );
                        }
                    }
                },
                .program => {
                    const enabler = QM31.fromBase(evaluations[2][row]);
                    const pc = QM31.fromBase(evaluations[3][row]);
                    const radix = M31.fromCanonical(256);
                    const inst_lo = QM31.fromBase(
                        evaluations[4][row].add(evaluations[5][row].mul(radix)),
                    );
                    const inst_hi = QM31.fromBase(
                        evaluations[6][row].add(evaluations[7][row].mul(radix)),
                    );
                    const mult = QM31.fromBase(evaluations[8][row]).mul(is_active);
                    const s_rom = secureAt(evaluations[9..13], row);
                    const s_rom_prev = secureAt(evaluations[13..17], row);

                    const c_rom = logup.pairConstraint(
                        s_rom,
                        s_rom_prev,
                        is_first,
                        self.rom_claim,
                        logup.programEmit(self.lookup, pc, inst_lo, inst_hi, mult),
                    );
                    const c_active = enabler.sub(is_active);
                    row_evaluation = column_accumulator.random_coeff_powers[1].mul(c_rom)
                        .add(column_accumulator.random_coeff_powers[0].mul(c_active));
                },
                .silent => unreachable,
            }
            column_accumulator.accumulate(
                row,
                row_evaluation.mulM31(denominator_inv[row >> denominator_shift]),
            );
        }
    }
};

fn secureAt(coords: []const []const M31, row: usize) QM31 {
    return QM31.fromM31(coords[0][row], coords[1][row], coords[2][row], coords[3][row]);
}

/// Zero-extend circle-FFT coefficients into an owned eval-domain buffer.
fn appendExtensionBuffer(
    allocator: std.mem.Allocator,
    extension_buffers: *std.ArrayList([]M31),
    coefficient_values: []const M31,
    eval_size: usize,
) ![]const M31 {
    const values = try allocator.alloc(M31, eval_size);
    errdefer allocator.free(values);
    @memcpy(values[0..coefficient_values.len], coefficient_values);
    @memset(values[coefficient_values.len..], M31.zero());
    try extension_buffers.append(allocator, values);
    return values;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "component: coset vanishing is block-constant over the extended quotient domain" {
    // The on-domain evaluator indexes the vanishing denominators by
    // `row >> log_size` in committed (bit-reversed circle-domain) order,
    // where block b maps to domain point index bitrev(b, extension_bits).
    // Verify this against the exact position -> point mapping.
    inline for ([_][2]u32{ .{ 1, 3 }, .{ 2, 4 }, .{ 2, 5 }, .{ 1, 5 }, .{ 3, 6 } }) |sizes| {
        const log_size = sizes[0];
        const eval_log_size = sizes[1];
        const eval_domain = canonic.CanonicCoset.new(eval_log_size).circleDomain();
        const trace_coset = canonic.CanonicCoset.new(log_size).coset();
        for (0..eval_domain.size()) |position| {
            const domain_index = utils.bitReverseIndex(position, eval_log_size);
            const at_position = core_constraints.cosetVanishing(
                M31,
                trace_coset,
                eval_domain.at(domain_index),
            );
            const block = position >> @intCast(log_size);
            const by_block = core_constraints.cosetVanishing(
                M31,
                trace_coset,
                eval_domain.at(utils.bitReverseIndex(block, eval_log_size - log_size)),
            );
            try std.testing.expect(at_position.eql(by_block));
        }
    }
}
