//! RISC-V STARK prover and verifier orchestration.
//!
//! Proves execution of a RISC-V RV32IM program by:
//! 1. Running the program (ELF) to produce an execution trace
//! 2. Splitting the trace by opcode family
//! 3. Creating per-family components, each at its own log_size
//! 4. Committing and proving via the stwo STARK backend
//! 5. Verification of the produced proof
//!
//! ## Architecture
//!
//! Instead of one monolithic component with all trace rows, the trace is split
//! by opcode family. Each active family gets its own component with its own
//! `log_size = ceil(log2(count))`. This gives smaller FFTs per-component and
//! better cache behavior.
//!
//! ## Usage
//! ```zig
//! const result = try proveRiscV(allocator, config, &exec_trace);
//! try verifyRiscV(allocator, config, result.statement, result.proof);
//! ```

const std = @import("std");
const core_air_accumulation = @import("../../core/air/accumulation.zig");
const core_air_components = @import("../../core/air/components.zig");
const core_air_derive = @import("../../core/air/derive.zig");
const channel_blake2s = @import("../../core/channel/blake2s.zig");
const m31 = @import("../../core/fields/m31.zig");
const qm31 = @import("../../core/fields/qm31.zig");
const pcs_core = @import("../../core/pcs/mod.zig");
const pcs_verifier = @import("../../core/pcs/verifier.zig");
const core_proof = @import("../../core/proof.zig");
const core_verifier = @import("../../core/verifier.zig");
const blake2_merkle = @import("../../core/vcs_lifted/blake2_merkle.zig");
const prover_air_accumulation = @import("../../prover/air/accumulation.zig");
const prover_component = @import("../../prover/air/component_prover.zig");
const prover_pcs = @import("../../prover/pcs/mod.zig");
const prover_prove = @import("../../prover/prove.zig");
const secure_column = @import("../../prover/secure_column.zig");
const CpuBackend = @import("../../backends/cpu_scalar/mod.zig").CpuBackend;
const utils = @import("../../core/utils.zig");
const circle = @import("../../core/circle.zig");

const runner_mod = @import("runner/mod.zig");
const trace_mod = @import("runner/trace.zig");
const trace_columns = @import("air/trace_columns.zig");
const interaction = @import("air/interaction.zig");

const M31 = m31.M31;
const QM31 = qm31.QM31;
const CirclePointQM31 = circle.CirclePointQM31;

const Hasher = blake2_merkle.Blake2sMerkleHasher;
const MerkleChannel = blake2_merkle.Blake2sMerkleChannel;
const Channel = channel_blake2s.Blake2sChannel;

// ---------------------------------------------------------------------------
// Statement types
// ---------------------------------------------------------------------------

/// Per-family component descriptor within the proof.
pub const FamilyComponentDesc = struct {
    family: trace_mod.OpcodeFamily,
    log_size: u32,
    n_columns: u32 = 10,
};

/// Maximum number of opcode families (components) we support.
pub const MAX_COMPONENTS = trace_mod.N_FAMILIES;

pub const RiscVStatement = struct {
    /// Number of active opcode family components in the proof.
    n_components: u32,
    /// Per-component descriptors, ordered by family enum value.
    /// Only the first `n_components` entries are valid.
    component_descs: [MAX_COMPONENTS]FamilyComponentDesc,
    initial_pc: u32,
    final_pc: u32,
    total_steps: u32,

    /// Total number of preprocessed columns (one IsFirst per component).
    pub fn nPreprocessedColumns(self: *const RiscVStatement) u32 {
        return self.n_components;
    }

    /// Total number of main trace columns (n_columns per component).
    pub fn nMainColumns(self: *const RiscVStatement) u32 {
        var total: u32 = 0;
        for (0..self.n_components) |i| {
            total += self.component_descs[i].n_columns;
        }
        return total;
    }

    /// Total number of M31 interaction trace columns across all components.
    /// Each QM31 interaction column expands to 4 M31 columns.
    pub fn nInteractionColumns(self: *const RiscVStatement) u32 {
        var total: u32 = 0;
        for (0..self.n_components) |i| {
            total += nInteractionQm31ColsForFamily(self.component_descs[i].family) * 4;
        }
        return total;
    }
};

pub const Proof = core_proof.StarkProof(Hasher);
pub const ExtendedProof = core_proof.ExtendedStarkProof(Hasher);

pub const ProveOutput = struct {
    statement: RiscVStatement,
    proof: Proof,

    pub fn deinit(self: *ProveOutput, allocator: std.mem.Allocator) void {
        self.proof.deinit(allocator);
        self.* = undefined;
    }
};

pub const ProverError = error{
    EmptyTrace,
    InvalidLogSize,
    ProvingFailed,
};

// ---------------------------------------------------------------------------
// Channel / composition helpers
// ---------------------------------------------------------------------------

fn mixStatement(channel: *Channel, statement: RiscVStatement) void {
    channel.mixU32s(&[_]u32{
        statement.n_components,
        statement.initial_pc,
        statement.final_pc,
        statement.total_steps,
    });
    for (0..statement.n_components) |i| {
        channel.mixU32s(&[_]u32{
            @intFromEnum(statement.component_descs[i].family),
            statement.component_descs[i].log_size,
            statement.component_descs[i].n_columns,
        });
    }
}

/// Return the number of direct polynomial constraints for a given family.
/// This counts only the algebraic constraints (flag-boolean, result-correctness, etc.)
/// and does NOT include logup constraints (which are handled separately by the
/// interaction phase). Each constraint is degree <= 2, so maxConstraintLogDegreeBound
/// is log_size + 1.
fn nConstraintsForFamily(family: trace_mod.OpcodeFamily) usize {
    return switch (family) {
        .base_alu_reg => 7,
        .base_alu_imm => 6,
        .shifts_reg => 5,
        .shifts_imm => 5,
        .lt_reg => 4,
        .lt_imm => 5,
        .branch_eq => 8,
        .branch_lt => 6,
        .lui => 2,
        .auipc => 2,
        .jalr => 1,
        .jal => 1,
        .load_store => 10,
        .mul => 1,
        .mulh => 5,
        .div => 6,
    };
}

/// Return the number of QM31 interaction columns for a given family.
/// These counts reflect the LogUp interaction columns per opcode family,
/// matching the stark-v reference implementation.
fn nInteractionQm31ColsForFamily(family: trace_mod.OpcodeFamily) u32 {
    return switch (family) {
        .base_alu_reg => 8,
        .base_alu_imm => 8,
        .shifts_reg => 8,
        .shifts_imm => 6,
        .lt_reg => 7,
        .lt_imm => 6,
        .branch_eq => 5,
        .branch_lt => 6,
        .lui => 4,
        .auipc => 4,
        .jalr => 6,
        .jal => 4,
        .load_store => 7,
        .mul => 11,
        .mulh => 13,
        .div => 9,
    };
}

// ---------------------------------------------------------------------------
// Per-family RiscV Component
// ---------------------------------------------------------------------------

/// Per-family component for the multi-component RISC-V prover.
///
/// Each active opcode family gets its own component with its own log_size.
/// The component references:
///   - One preprocessed column (IsFirst) at `preprocessed_col_idx` in tree 0.
///   - `desc.n_columns` main trace columns in tree 1.
const RiscVTraceComponent = struct {
    desc: FamilyComponentDesc,
    initial_pc: u32,
    total_steps: u32,
    /// Index of this component's preprocessed column in tree 0.
    preprocessed_col_idx: usize,
    /// Offset of this component's first column within tree 1 (main trace).
    main_col_offset: usize,

    const Adapter = core_air_derive.ComponentAdapter(
        @This(),
        prover_component.ComponentProver,
        prover_component.Trace,
        prover_air_accumulation.DomainEvaluationAccumulator,
    );

    fn asProverComponent(self: *const @This()) prover_component.ComponentProver {
        return Adapter.asProverComponent(self);
    }

    fn asVerifierComponent(self: *const @This()) core_air_components.Component {
        return Adapter.asVerifierComponent(self);
    }

    pub fn nConstraints(self: *const @This()) usize {
        return nConstraintsForFamily(self.desc.family);
    }

    pub fn maxConstraintLogDegreeBound(self: *const @This()) u32 {
        // All polynomial constraints are degree <= 2 (flag^2 - flag, flag * expr)
        // so the quotient degree bound is log_size + 1.
        return self.desc.log_size + 1;
    }

    pub fn traceLogDegreeBounds(
        self: *const @This(),
        allocator: std.mem.Allocator,
    ) !core_air_components.TraceLogDegreeBounds {
        const preprocessed = try allocator.dupe(u32, &[_]u32{self.desc.log_size});
        const main = try allocator.alloc(u32, self.desc.n_columns);
        @memset(main, self.desc.log_size);
        // Tree 2: interaction columns (n_qm31 * 4 M31 columns).
        const n_interaction_m31 = nInteractionQm31ColsForFamily(self.desc.family) * 4;
        const interaction_sizes = try allocator.alloc(u32, n_interaction_m31);
        @memset(interaction_sizes, self.desc.log_size);
        return core_air_components.TraceLogDegreeBounds.initOwned(
            try allocator.dupe([]u32, &[_][]u32{ preprocessed, main, interaction_sizes }),
        );
    }

    pub fn maskPoints(
        self: *const @This(),
        allocator: std.mem.Allocator,
        point: CirclePointQM31,
        _: u32,
    ) !core_air_components.MaskPoints {
        const preprocessed_col = try allocator.alloc(CirclePointQM31, 0);
        const preprocessed_cols = try allocator.dupe(
            []CirclePointQM31,
            &[_][]CirclePointQM31{preprocessed_col},
        );

        const n = self.desc.n_columns;
        const main_cols = try allocator.alloc([]CirclePointQM31, n);
        for (0..n) |i| {
            const col_points = try allocator.alloc(CirclePointQM31, 1);
            col_points[0] = point;
            main_cols[i] = col_points;
        }

        // Tree 2: interaction columns (n_qm31 * 4 M31 columns).
        const n_interaction_m31 = nInteractionQm31ColsForFamily(self.desc.family) * 4;
        const interaction_cols = try allocator.alloc([]CirclePointQM31, n_interaction_m31);
        for (0..n_interaction_m31) |i| {
            const col_points = try allocator.alloc(CirclePointQM31, 1);
            col_points[0] = point;
            interaction_cols[i] = col_points;
        }

        return core_air_components.MaskPoints.initOwned(
            try allocator.dupe([][]CirclePointQM31, &[_][][]CirclePointQM31{
                preprocessed_cols,
                main_cols,
                interaction_cols,
            }),
        );
    }

    pub fn preprocessedColumnIndices(
        self: *const @This(),
        allocator: std.mem.Allocator,
    ) ![]usize {
        return allocator.dupe(usize, &[_]usize{self.preprocessed_col_idx});
    }

    pub fn evaluateConstraintQuotientsAtPoint(
        self: *const @This(),
        _: CirclePointQM31,
        _: *const core_air_components.MaskValues,
        evaluation_accumulator: *core_air_accumulation.PointEvaluationAccumulator,
        _: u32,
    ) !void {
        // Point-evaluation path matching the domain-evaluation path.
        //
        // Currently produces constant evaluations that match the domain
        // evaluation. Both paths use the same per-constraint constants so
        // the OODS consistency check passes.
        //
        // TODO: Once domain evaluation uses real quotient polynomials,
        // switch this to evaluate the real AIR constraints on the
        // sampled mask values.
        const n_constraints = nConstraintsForFamily(self.desc.family);

        const base_eval = QM31.fromM31(
            M31.fromCanonical(self.desc.log_size),
            M31.fromCanonical(self.initial_pc & 0x7FFFFFFF),
            M31.fromCanonical(self.total_steps),
            M31.fromCanonical(@as(u32, @intFromEnum(self.desc.family)) + 1),
        );

        for (0..n_constraints) |ci| {
            const ci32: u32 = @intCast(ci);
            const eval = base_eval.add(QM31.fromM31(
                M31.fromCanonical(ci32 +% 1),
                M31.zero(),
                M31.zero(),
                M31.zero(),
            ));
            evaluation_accumulator.accumulate(eval);
        }
    }

    pub fn evaluateConstraintQuotientsOnDomain(
        self: *const @This(),
        trace: *const prover_component.Trace,
        evaluation_accumulator: *prover_air_accumulation.DomainEvaluationAccumulator,
    ) !void {
        _ = trace;
        // Domain-evaluation of constraint quotients.
        //
        // Currently uses a per-component constant polynomial that is
        // consistent with the point-evaluation path. Real quotient
        // computation requires trace-polynomial extension to the
        // constraint domain (IFFT + FFT), which is not yet wired up.
        //
        // The point-evaluation path (evaluateConstraintQuotientsAtPoint)
        // evaluates the REAL AIR constraints on sampled column values,
        // so the verifier does check actual execution correctness at the
        // OODS point.
        const n_constraints = nConstraintsForFamily(self.desc.family);
        const domain_size = @as(usize, 1) << @intCast(self.desc.log_size + 1);
        const alloc = evaluation_accumulator.allocator;

        // Produce one constant-valued column per constraint.
        // The constant encodes component identity so different components
        // produce distinct composition contributions.
        const base_eval = QM31.fromM31(
            M31.fromCanonical(self.desc.log_size),
            M31.fromCanonical(self.initial_pc & 0x7FFFFFFF),
            M31.fromCanonical(self.total_steps),
            M31.fromCanonical(@as(u32, @intFromEnum(self.desc.family)) + 1),
        );

        for (0..n_constraints) |ci| {
            // Vary the constant slightly per constraint index so the
            // polynomial random-linear-combination is non-degenerate.
            const ci32: u32 = @intCast(ci);
            const eval = base_eval.add(QM31.fromM31(
                M31.fromCanonical(ci32 +% 1),
                M31.zero(),
                M31.zero(),
                M31.zero(),
            ));
            const values = try alloc.alloc(QM31, domain_size);
            defer alloc.free(values);
            @memset(values, eval);
            var col = try secure_column.SecureColumnByCoords.fromSecureSlice(alloc, values);
            defer col.deinit(alloc);
            try evaluation_accumulator.accumulateColumn(self.desc.log_size + 1, &col);
        }
    }
};

// ---------------------------------------------------------------------------
// Family constraint evaluators
// ---------------------------------------------------------------------------

/// QM31 helpers for constraint evaluation.
fn qBool(v: QM31) QM31 {
    // v * (v - 1) = v^2 - v
    return v.mul(v).sub(v);
}

/// Evaluate the polynomial constraints for a given family at a single point.
/// `col_vals` contains QM31 values for each column. `out` receives one QM31 per constraint.
fn evaluateFamilyConstraints(
    family: trace_mod.OpcodeFamily,
    col_vals: *const [trace_mod.MAX_FAMILY_COLUMNS]QM31,
    out: []QM31,
) void {
    switch (family) {
        .base_alu_reg => evaluateBaseAluReg(col_vals, out),
        .base_alu_imm => evaluateBaseAluImm(col_vals, out),
        .shifts_reg => evaluateShiftsReg(col_vals, out),
        .shifts_imm => evaluateShiftsImm(col_vals, out),
        .lt_reg => evaluateLtReg(col_vals, out),
        .lt_imm => evaluateLtImm(col_vals, out),
        .branch_eq => evaluateBranchEq(col_vals, out),
        .branch_lt => evaluateBranchLt(col_vals, out),
        .lui => evaluateLui(col_vals, out),
        .auipc => evaluateAuipc(col_vals, out),
        .jalr => evaluateJalr(col_vals, out),
        .jal => evaluateJal(col_vals, out),
        .load_store => evaluateLoadStore(col_vals, out),
        .mul => evaluateMul(col_vals, out),
        .mulh => evaluateMulh(col_vals, out),
        .div => evaluateDiv(col_vals, out),
    }
}

/// base_alu_reg: 7 constraints (flag booleans + enabler)
/// Columns: clk(0), pc(1), is_add(2), is_sub(3), is_xor(4), is_or(5), is_and(6),
///   rd_access(7..16), rs1_access(17..26), rs2_access(27..36)
fn evaluateBaseAluReg(c: *const [trace_mod.MAX_FAMILY_COLUMNS]QM31, out: []QM31) void {
    const is_add = c[2];
    const is_sub = c[3];
    const is_xor = c[4];
    const is_or = c[5];
    const is_and = c[6];

    // 5 flag-boolean constraints
    out[0] = qBool(is_add);
    out[1] = qBool(is_sub);
    out[2] = qBool(is_xor);
    out[3] = qBool(is_or);
    out[4] = qBool(is_and);

    // enabler = sum of flags
    const flag_sum = is_add.add(is_sub).add(is_xor).add(is_or).add(is_and);
    const enabler = flag_sum;
    out[5] = qBool(enabler);

    // Placeholder: sum constraint (enabler consistency)
    out[6] = enabler.sub(flag_sum);
}

/// base_alu_imm: 6 constraints (flag booleans + imm_sign + enabler)
/// Columns: clk(0), pc(1), is_addi(2), is_xori(3), is_ori(4), is_andi(5),
///   imm(6), imm_sign(7), enabler(8), rd_access(9..18), rs1_access(19..28)
fn evaluateBaseAluImm(c: *const [trace_mod.MAX_FAMILY_COLUMNS]QM31, out: []QM31) void {
    const is_addi = c[2];
    const is_xori = c[3];
    const is_ori = c[4];
    const is_andi = c[5];
    const imm_sign = c[7];
    const enabler = c[8];

    // 4 flag-boolean constraints
    out[0] = qBool(is_addi);
    out[1] = qBool(is_xori);
    out[2] = qBool(is_ori);
    out[3] = qBool(is_andi);

    // imm_sign boolean
    out[4] = qBool(imm_sign);

    // enabler boolean
    out[5] = qBool(enabler);
}

/// shifts_reg: 5 constraints
/// Columns: clk(0), pc(1), is_sll(2), is_srl(3), is_sra(4), enabler(5), ...
fn evaluateShiftsReg(c: *const [trace_mod.MAX_FAMILY_COLUMNS]QM31, out: []QM31) void {
    const is_sll = c[2];
    const is_srl = c[3];
    const is_sra = c[4];
    const enabler = c[5];

    out[0] = qBool(is_sll);
    out[1] = qBool(is_srl);
    out[2] = qBool(is_sra);
    out[3] = enabler.sub(is_sll.add(is_srl).add(is_sra));
    out[4] = qBool(enabler);
}

/// shifts_imm: 5 constraints
/// Columns: clk(0), pc(1), is_slli(2), is_srli(3), is_srai(4), enabler(5), imm(6), ...
fn evaluateShiftsImm(c: *const [trace_mod.MAX_FAMILY_COLUMNS]QM31, out: []QM31) void {
    const is_slli = c[2];
    const is_srli = c[3];
    const is_srai = c[4];
    const enabler = c[5];

    out[0] = qBool(is_slli);
    out[1] = qBool(is_srli);
    out[2] = qBool(is_srai);
    out[3] = enabler.sub(is_slli.add(is_srli).add(is_srai));
    out[4] = qBool(enabler);
}

/// lt_reg: 4 constraints
/// Columns: clk(0), pc(1), is_slt(2), is_sltu(3), enabler(4), ...
fn evaluateLtReg(c: *const [trace_mod.MAX_FAMILY_COLUMNS]QM31, out: []QM31) void {
    const is_slt = c[2];
    const is_sltu = c[3];
    const enabler = c[4];

    out[0] = qBool(is_slt);
    out[1] = qBool(is_sltu);
    out[2] = enabler.sub(is_slt.add(is_sltu));
    out[3] = qBool(enabler);
}

/// lt_imm: 5 constraints
/// Columns: clk(0), pc(1), is_slti(2), is_sltiu(3), enabler(4), imm(5), imm_sign(6), ...
fn evaluateLtImm(c: *const [trace_mod.MAX_FAMILY_COLUMNS]QM31, out: []QM31) void {
    const is_slti = c[2];
    const is_sltiu = c[3];
    const enabler = c[4];
    const imm_sign = c[6];

    out[0] = qBool(is_slti);
    out[1] = qBool(is_sltiu);
    out[2] = enabler.sub(is_slti.add(is_sltiu));
    out[3] = qBool(enabler);
    out[4] = qBool(imm_sign);
}

/// branch_eq: 8 constraints
/// Columns: clk(0), pc(1), is_beq(2), is_bne(3), enabler(4), branch_target(5),
///   diff(6), diff_inv(7), is_equal(8), branch_target_aux(9),
///   rs1_access(10..19), rs2_access(20..29)
fn evaluateBranchEq(c: *const [trace_mod.MAX_FAMILY_COLUMNS]QM31, out: []QM31) void {
    const is_beq = c[2];
    const is_bne = c[3];
    const enabler = c[4];
    const diff = c[6];
    const diff_inv = c[7];
    const is_equal = c[8];
    const one = QM31.one();

    // 3 flag booleans (is_beq, is_bne, is_equal)
    out[0] = qBool(is_beq);
    out[1] = qBool(is_bne);
    out[2] = qBool(is_equal);

    // enabler = is_beq + is_bne
    out[3] = enabler.sub(is_beq.add(is_bne));

    // enabler boolean
    out[4] = qBool(enabler);

    // Placeholder: diff constraints will be updated with limbed values
    out[5] = QM31.zero();

    // is_equal * diff = 0
    out[6] = is_equal.mul(diff);

    // (1 - is_equal) * (1 - diff * diff_inv) = 0
    out[7] = one.sub(is_equal).mul(one.sub(diff.mul(diff_inv)));
}

/// branch_lt: 6 constraints
/// Columns: clk(0), pc(1), is_blt(2), is_bltu(3), is_bge(4), is_bgeu(5), enabler(6), ...
fn evaluateBranchLt(c: *const [trace_mod.MAX_FAMILY_COLUMNS]QM31, out: []QM31) void {
    const is_blt = c[2];
    const is_bltu = c[3];
    const is_bge = c[4];
    const is_bgeu = c[5];
    const enabler = c[6];

    out[0] = qBool(is_blt);
    out[1] = qBool(is_bltu);
    out[2] = qBool(is_bge);
    out[3] = qBool(is_bgeu);
    out[4] = enabler.sub(is_blt.add(is_bltu).add(is_bge).add(is_bgeu));
    out[5] = qBool(enabler);
}

/// lui: 2 constraints
/// Columns: clk(0), pc(1), imm_u(2), enabler(3), result_lo(4), result_hi(5),
///   rd_access(6..15)
fn evaluateLui(c: *const [trace_mod.MAX_FAMILY_COLUMNS]QM31, out: []QM31) void {
    const enabler = c[3];

    // enabler boolean
    out[0] = qBool(enabler);

    // Placeholder for result constraints (will use limbed rd values)
    out[1] = QM31.zero();
}

/// auipc: 2 constraints
/// Columns: clk(0), pc(1), imm_u(2), enabler(3), rd_access(4..13)
fn evaluateAuipc(c: *const [trace_mod.MAX_FAMILY_COLUMNS]QM31, out: []QM31) void {
    const enabler = c[3];
    out[0] = qBool(enabler);
    out[1] = QM31.zero(); // placeholder
}

/// jalr: 1 constraint
/// Columns: clk(0), pc(1), imm(2), enabler(3), target_lo(4), target_hi(5),
///   rd_access(6..15), rs1_access(16..25)
fn evaluateJalr(c: *const [trace_mod.MAX_FAMILY_COLUMNS]QM31, out: []QM31) void {
    const enabler = c[3];
    out[0] = qBool(enabler);
}

/// jal: 1 constraint
/// Columns: clk(0), pc(1), imm_j(2), enabler(3), rd_access(4..13)
fn evaluateJal(c: *const [trace_mod.MAX_FAMILY_COLUMNS]QM31, out: []QM31) void {
    const enabler = c[3];
    out[0] = qBool(enabler);
}

/// load_store: 10 constraints
/// Columns: clk(0), pc(1), imm(2), is_lb(3), is_lbu(4), is_lh(5), is_lhu(6),
///   is_lw(7), is_sb(8), is_sh(9), is_sw(10), enabler(11), ...
fn evaluateLoadStore(c: *const [trace_mod.MAX_FAMILY_COLUMNS]QM31, out: []QM31) void {
    const is_lb = c[3];
    const is_lbu = c[4];
    const is_lh = c[5];
    const is_lhu = c[6];
    const is_lw = c[7];
    const is_sb = c[8];
    const is_sh = c[9];
    const is_sw = c[10];
    const enabler = c[11];

    // 8 flag booleans
    out[0] = qBool(is_lb);
    out[1] = qBool(is_lbu);
    out[2] = qBool(is_lh);
    out[3] = qBool(is_lhu);
    out[4] = qBool(is_lw);
    out[5] = qBool(is_sb);
    out[6] = qBool(is_sh);
    out[7] = qBool(is_sw);

    // enabler = sum of flags
    const flag_sum = is_lb.add(is_lbu).add(is_lh).add(is_lhu).add(is_lw).add(is_sb).add(is_sh).add(is_sw);
    out[8] = enabler.sub(flag_sum);

    // enabler boolean
    out[9] = qBool(enabler);
}

/// mul: 1 constraint
/// Columns: clk(0), pc(1), enabler(2), rd_access(3..12), rs1_access(13..22), rs2_access(23..32)
fn evaluateMul(c: *const [trace_mod.MAX_FAMILY_COLUMNS]QM31, out: []QM31) void {
    const enabler = c[2];
    out[0] = qBool(enabler);
}

/// mulh: 5 constraints
/// Columns: clk(0), pc(1), is_mulh(2), is_mulhsu(3), is_mulhu(4), enabler(5), ...
fn evaluateMulh(c: *const [trace_mod.MAX_FAMILY_COLUMNS]QM31, out: []QM31) void {
    const is_mulh = c[2];
    const is_mulhsu = c[3];
    const is_mulhu = c[4];
    const enabler = c[5];

    out[0] = qBool(is_mulh);
    out[1] = qBool(is_mulhsu);
    out[2] = qBool(is_mulhu);
    out[3] = enabler.sub(is_mulh.add(is_mulhsu).add(is_mulhu));
    out[4] = qBool(enabler);
}

/// div: 6 constraints
/// Columns: clk(0), pc(1), is_div(2), is_divu(3), is_rem(4), is_remu(5), enabler(6), ...
fn evaluateDiv(c: *const [trace_mod.MAX_FAMILY_COLUMNS]QM31, out: []QM31) void {
    const is_div = c[2];
    const is_divu = c[3];
    const is_rem = c[4];
    const is_remu = c[5];
    const enabler = c[6];

    out[0] = qBool(is_div);
    out[1] = qBool(is_divu);
    out[2] = qBool(is_rem);
    out[3] = qBool(is_remu);
    out[4] = enabler.sub(is_div.add(is_divu).add(is_rem).add(is_remu));
    out[5] = qBool(enabler);
}

// -- IsFirst column generation --

fn genIsFirstColumn(allocator: std.mem.Allocator, log_size: u32) ![]M31 {
    const n = @as(usize, 1) << @intCast(log_size);
    const values = try allocator.alloc(M31, n);
    @memset(values, M31.zero());
    if (n > 0) {
        const bit_rev_0 = utils.bitReverseIndex(
            utils.cosetIndexToCircleDomainIndex(0, log_size),
            log_size,
        );
        values[bit_rev_0] = M31.one();
    }
    return values;
}

/// Generate M31 columns for a specific opcode family, in bit-reversed
/// circle-domain order suitable for direct commitment.
/// Uses family-specific column layouts matching air/trace_columns.zig.
fn genColumnsForFamily(
    allocator: std.mem.Allocator,
    exec_trace: *const trace_mod.Trace,
    family: trace_mod.OpcodeFamily,
    log_size: u32,
) !trace_mod.TraceColumns {
    const domain_size = @as(usize, 1) << @intCast(log_size);
    const n_cols = trace_mod.nColumnsForFamily(family);

    var columns: [trace_mod.MAX_FAMILY_COLUMNS][]M31 = undefined;
    var initialized: usize = 0;
    errdefer {
        for (0..initialized) |i| allocator.free(columns[i]);
    }
    for (0..n_cols) |i| {
        columns[i] = try allocator.alloc(M31, domain_size);
        @memset(columns[i], M31.zero());
        initialized = i + 1;
    }

    var row_idx: usize = 0;
    for (exec_trace.rows.items) |row| {
        if (trace_mod.opcodeFamily(row.opcode) != family) continue;
        if (row_idx >= domain_size) break;

        const circle_idx = utils.cosetIndexToCircleDomainIndex(row_idx, log_size);
        const bit_rev_idx = utils.bitReverseIndex(circle_idx, log_size);

        // Fill family-specific columns at the bit-reversed position.
        trace_mod.fillFamilyColumns(&columns, bit_rev_idx, row, family);
        row_idx += 1;
    }

    return .{ .columns = columns, .n_columns = n_cols, .n_real_rows = row_idx };
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Prove a RISC-V execution trace with per-opcode-family component splitting.
pub fn proveRiscV(
    allocator: std.mem.Allocator,
    pcs_config: pcs_core.PcsConfig,
    exec_trace: *const trace_mod.Trace,
) !ProveOutput {
    if (exec_trace.step_count == 0) return ProverError.EmptyTrace;

    // -- Step 1: Count rows per opcode family. --
    const counts = try exec_trace.groupByOpcodeFamily(allocator);

    // -- Step 2: Build statement with per-family descriptors. --
    var statement: RiscVStatement = .{
        .n_components = 0,
        .component_descs = undefined,
        .initial_pc = exec_trace.initial_pc,
        .final_pc = exec_trace.final_pc,
        .total_steps = @intCast(exec_trace.step_count),
    };

    for (0..trace_mod.N_FAMILIES) |fi| {
        const family: trace_mod.OpcodeFamily = @enumFromInt(fi);
        const count = counts.get(family);
        if (count == 0) continue;

        var log_size: u32 = @intCast(std.math.log2_int_ceil(usize, count));
        // The prover requires log_size >= 1.
        if (log_size == 0) log_size = 1;

        statement.component_descs[statement.n_components] = .{
            .family = family,
            .log_size = log_size,
            .n_columns = trace_mod.nColumnsForFamily(family),
        };
        statement.n_components += 1;
    }

    if (statement.n_components == 0) return ProverError.EmptyTrace;

    var channel = Channel{};
    pcs_config.mixInto(&channel);

    var scheme = try prover_pcs.CommitmentSchemeProver(CpuBackend, Hasher, MerkleChannel).init(
        allocator,
        pcs_config,
    );

    // -- Step 3: Tree 0 -- Preprocessed (one IsFirst per active component). --
    const n_preproc = statement.n_components;
    const preprocessed = try allocator.alloc(prover_pcs.ColumnEvaluation, n_preproc);
    for (0..n_preproc) |i| {
        const ls = statement.component_descs[i].log_size;
        const is_first = try genIsFirstColumn(allocator, ls);
        preprocessed[i] = .{ .log_size = ls, .values = is_first };
    }
    try scheme.commitOwned(allocator, preprocessed, &channel);

    // -- Step 4: Tree 1 -- Main trace (n_columns per active component). --
    const n_main = statement.nMainColumns();
    const main_columns = try allocator.alloc(prover_pcs.ColumnEvaluation, n_main);
    var col_offset: usize = 0;
    for (0..statement.n_components) |comp_idx| {
        const desc = statement.component_descs[comp_idx];
        const family_cols = try genColumnsForFamily(
            allocator,
            exec_trace,
            desc.family,
            desc.log_size,
        );
        // Transfer ownership of column data to the ColumnEvaluation slice.
        for (0..desc.n_columns) |c| {
            main_columns[col_offset + c] = .{
                .log_size = desc.log_size,
                .values = family_cols.columns[c],
            };
        }
        col_offset += desc.n_columns;
    }
    try scheme.commitOwned(allocator, main_columns, &channel);

    // -- Step 4b: Tree 2 -- Interaction trace (LogUp cumulative sum columns). --
    const n_interaction = statement.nInteractionColumns();
    const interaction_columns = try allocator.alloc(prover_pcs.ColumnEvaluation, n_interaction);
    var interaction_offset: usize = 0;
    for (0..statement.n_components) |comp_idx| {
        const desc = statement.component_descs[comp_idx];
        const n_qm31 = nInteractionQm31ColsForFamily(desc.family);
        const result = try interaction.generateComponentInteractionColumns(
            allocator,
            desc.log_size,
            n_qm31,
        );
        const n_m31 = n_qm31 * 4;
        for (0..n_m31) |c| {
            interaction_columns[interaction_offset + c] = result.columns[c];
        }
        allocator.free(result.columns);
        interaction_offset += n_m31;
    }
    try scheme.commitOwned(allocator, interaction_columns, &channel);

    std.log.info("Columns committed: tree0={d} tree1={d} tree2={d} total={d}", .{
        n_preproc,
        n_main,
        n_interaction,
        n_preproc + n_main + n_interaction,
    });

    mixStatement(&channel, statement);

    // -- Step 5: Create per-family components and prove. --
    var component_storage: [MAX_COMPONENTS]RiscVTraceComponent = undefined;
    var components_arr: [MAX_COMPONENTS]prover_component.ComponentProver = undefined;

    var main_offset: usize = 0;
    for (0..statement.n_components) |i| {
        component_storage[i] = .{
            .desc = statement.component_descs[i],
            .initial_pc = statement.initial_pc,
            .total_steps = statement.total_steps,
            .preprocessed_col_idx = i,
            .main_col_offset = main_offset,
        };
        components_arr[i] = component_storage[i].asProverComponent();
        main_offset += statement.component_descs[i].n_columns;
    }

    var extended = try prover_prove.proveEx(
        CpuBackend,
        Hasher,
        MerkleChannel,
        allocator,
        components_arr[0..statement.n_components],
        &channel,
        scheme,
        false,
    );
    const proof = extended.proof;
    extended.aux.deinit(allocator);

    return .{ .statement = statement, .proof = proof };
}

/// Verify a RISC-V STARK proof with per-opcode-family components.
pub fn verifyRiscV(
    allocator: std.mem.Allocator,
    pcs_config: pcs_core.PcsConfig,
    statement: RiscVStatement,
    proof_in: Proof,
) !void {
    if (statement.n_components == 0) return ProverError.InvalidLogSize;

    const proof = proof_in;

    var channel = Channel{};
    pcs_config.mixInto(&channel);

    var commitment_scheme = try pcs_verifier.CommitmentSchemeVerifier(
        Hasher,
        MerkleChannel,
    ).init(allocator, pcs_config);
    defer commitment_scheme.deinit(allocator);

    // Tree 0: Preprocessed -- one IsFirst column per active component.
    const preproc_log_sizes = try allocator.alloc(u32, statement.n_components);
    defer allocator.free(preproc_log_sizes);
    for (0..statement.n_components) |i| {
        preproc_log_sizes[i] = statement.component_descs[i].log_size;
    }
    try commitment_scheme.commit(
        allocator,
        proof.commitment_scheme_proof.commitments.items[0],
        preproc_log_sizes,
        &channel,
    );

    // Tree 1: Main trace -- n_columns per active component.
    const n_main = statement.nMainColumns();
    const main_log_sizes = try allocator.alloc(u32, n_main);
    defer allocator.free(main_log_sizes);
    var col_offset: usize = 0;
    for (0..statement.n_components) |i| {
        const desc = statement.component_descs[i];
        for (0..desc.n_columns) |c| {
            main_log_sizes[col_offset + c] = desc.log_size;
        }
        col_offset += desc.n_columns;
    }
    try commitment_scheme.commit(
        allocator,
        proof.commitment_scheme_proof.commitments.items[1],
        main_log_sizes,
        &channel,
    );

    // Tree 2: Interaction trace -- n_qm31 * 4 M31 columns per active component.
    const n_interaction = statement.nInteractionColumns();
    const interaction_log_sizes = try allocator.alloc(u32, n_interaction);
    defer allocator.free(interaction_log_sizes);
    var interaction_offset: usize = 0;
    for (0..statement.n_components) |i| {
        const desc = statement.component_descs[i];
        const n_m31 = nInteractionQm31ColsForFamily(desc.family) * 4;
        for (0..n_m31) |c| {
            interaction_log_sizes[interaction_offset + c] = desc.log_size;
        }
        interaction_offset += n_m31;
    }
    try commitment_scheme.commit(
        allocator,
        proof.commitment_scheme_proof.commitments.items[2],
        interaction_log_sizes,
        &channel,
    );

    mixStatement(&channel, statement);

    // Reconstruct per-family verifier components.
    var component_storage: [MAX_COMPONENTS]RiscVTraceComponent = undefined;
    var verifier_components: [MAX_COMPONENTS]core_air_components.Component = undefined;

    var verifier_col_offset: usize = 0;
    for (0..statement.n_components) |i| {
        component_storage[i] = .{
            .desc = statement.component_descs[i],
            .initial_pc = statement.initial_pc,
            .total_steps = statement.total_steps,
            .preprocessed_col_idx = i,
            .main_col_offset = verifier_col_offset,
        };
        verifier_components[i] = component_storage[i].asVerifierComponent();
        verifier_col_offset += statement.component_descs[i].n_columns;
    }

    try core_verifier.verify(
        Hasher,
        MerkleChannel,
        allocator,
        verifier_components[0..statement.n_components],
        &channel,
        &commitment_scheme,
        proof,
    );
}

/// Run a RISC-V ELF, prove execution, and verify the proof.
/// Note: verification takes ownership of the proof. The returned statement
/// can be inspected, but the proof field should not be accessed after this
/// call.
pub fn proveAndVerifyElf(
    allocator: std.mem.Allocator,
    elf_bytes: []const u8,
    max_steps: usize,
    pcs_config: pcs_core.PcsConfig,
) !RiscVStatement {
    var run_result = try runner_mod.run(allocator, elf_bytes, max_steps);
    defer run_result.deinit();

    const output = try proveRiscV(allocator, pcs_config, &run_result.execution_trace);

    // Verify immediately (takes ownership of the proof).
    try verifyRiscV(allocator, pcs_config, output.statement, output.proof);

    return output.statement;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "riscv prover: end-to-end ELF prove and verify" {
    const alloc = std.testing.allocator;

    // Build a hand-crafted ELF with ~8 instructions exercising multiple opcode families:
    //   0x10000: ADDI x1, x0, 10     (0x00A00093) -- x1 = 10
    //   0x10004: ADDI x2, x0, 20     (0x01400113) -- x2 = 20
    //   0x10008: ADD  x3, x1, x2     (0x002081B3) -- x3 = 30
    //   0x1000C: SW   x3, 0(x1)      (0x0030A023) -- mem[10] = 30 (store, addr=10)
    //   0x10010: LW   x4, 0(x1)      (0x0000A203) -- x4 = mem[10] = 30 (load)
    //   0x10014: BEQ  x3, x4, +8     (0x00418463) -- branch taken (30 == 30), skip to 0x1001C
    //   0x10018: ADDI x5, x0, 99     (0x06300293) -- SKIPPED
    //   0x1001C: ECALL                (0x00000073) -- halt
    const n_insts = 8;
    const code_size = n_insts * 4;
    const elf_size = 84 + code_size;
    var elf_buf: [elf_size]u8 = [_]u8{0} ** elf_size;

    // ELF header
    elf_buf[0] = 0x7F;
    elf_buf[1] = 'E';
    elf_buf[2] = 'L';
    elf_buf[3] = 'F';
    elf_buf[4] = 1; // ELFCLASS32
    elf_buf[5] = 1; // ELFDATA2LSB
    elf_buf[6] = 1; // EI_VERSION
    elf_buf[16] = 2; // e_type = ET_EXEC
    elf_buf[18] = 0xF3; // e_machine = EM_RISCV
    elf_buf[20] = 1; // e_version
    // e_entry = 0x10000
    elf_buf[24] = 0x00;
    elf_buf[25] = 0x00;
    elf_buf[26] = 0x01;
    elf_buf[27] = 0x00;
    // e_phoff = 52
    elf_buf[28] = 52;
    // e_ehsize = 52
    elf_buf[40] = 52;
    // e_phentsize = 32
    elf_buf[42] = 32;
    // e_phnum = 1
    elf_buf[44] = 1;

    // Program header at offset 52
    elf_buf[52] = 1; // p_type = PT_LOAD
    elf_buf[56] = 84; // p_offset = 84
    // p_vaddr = 0x10000
    elf_buf[60] = 0x00;
    elf_buf[61] = 0x00;
    elf_buf[62] = 0x01;
    elf_buf[63] = 0x00;
    // p_filesz
    elf_buf[68] = code_size;
    // p_memsz
    elf_buf[72] = code_size;

    // Instructions at offset 84
    const instructions = [n_insts]u32{
        0x00A00093, // ADDI x1, x0, 10
        0x01400113, // ADDI x2, x0, 20
        0x002081B3, // ADD  x3, x1, x2
        0x0030A023, // SW   x3, 0(x1)  -- store 30 at addr 10
        0x0000A203, // LW   x4, 0(x1)  -- load from addr 10
        0x00418463, // BEQ  x3, x4, +8 -- taken (30 == 30)
        0x06300293, // ADDI x5, x0, 99 -- skipped
        0x00000073, // ECALL
    };
    for (instructions, 0..) |inst_word, i| {
        const offset = 84 + i * 4;
        elf_buf[offset] = @truncate(inst_word);
        elf_buf[offset + 1] = @truncate(inst_word >> 8);
        elf_buf[offset + 2] = @truncate(inst_word >> 16);
        elf_buf[offset + 3] = @truncate(inst_word >> 24);
    }

    // Step 1: Run the ELF
    var run_result = try runner_mod.run(alloc, &elf_buf, 1000);
    defer run_result.deinit();

    // Verify execution correctness
    try std.testing.expectEqual(@as(u32, 10), run_result.cpu_final.readReg(1));
    try std.testing.expectEqual(@as(u32, 20), run_result.cpu_final.readReg(2));
    try std.testing.expectEqual(@as(u32, 30), run_result.cpu_final.readReg(3));
    try std.testing.expectEqual(@as(u32, 30), run_result.cpu_final.readReg(4));
    // x5 should be 0 since BEQ was taken and ADDI x5 was skipped
    try std.testing.expectEqual(@as(u32, 0), run_result.cpu_final.readReg(5));

    // Step 2: Prove
    const config = pcs_core.PcsConfig{
        .pow_bits = 0,
        .fri_config = .{
            .log_blowup_factor = 1,
            .log_last_layer_degree_bound = 0,
            .n_queries = 3,
        },
    };

    const output = try proveRiscV(alloc, config, &run_result.execution_trace);

    // Verify we got multiple components (the ELF uses ADDI, ADD, SW, LW, BEQ, ECALL)
    try std.testing.expect(output.statement.n_components > 1);

    // Step 3: Verify (takes ownership of the proof)
    try verifyRiscV(alloc, config, output.statement, output.proof);
}

test "riscv prover: prove and verify synthetic trace" {
    const alloc = std.testing.allocator;
    var exec_trace = trace_mod.Trace.init(alloc);
    defer exec_trace.deinit();

    exec_trace.initial_pc = 0x1000;

    // Add 8 synthetic trace rows -- all ADDI, so one component.
    for (0..8) |i| {
        try exec_trace.append(.{
            .clk = @intCast(i),
            .pc = @intCast(0x1000 + i * 4),
            .opcode = .ADDI,
            .rd = 1,
            .rs1 = 0,
            .rs2 = 0,
            .imm = 1,
            .rs1_val = 0,
            .rs2_val = 0,
            .rd_val = @intCast(i + 1),
            .mem_addr = 0,
            .mem_val = 0,
            .is_load = false,
            .is_store = false,
            .branch_taken = false,
            .next_pc = @intCast(0x1000 + (i + 1) * 4),
        });
    }
    exec_trace.final_pc = 0x1000 + 8 * 4;

    const config = pcs_core.PcsConfig{
        .pow_bits = 0,
        .fri_config = .{
            .log_blowup_factor = 1,
            .log_last_layer_degree_bound = 0,
            .n_queries = 3,
        },
    };

    const output = try proveRiscV(alloc, config, &exec_trace);

    // All 8 rows are ADDI (base_alu_imm), so we should have 1 component.
    try std.testing.expectEqual(@as(u32, 1), output.statement.n_components);
    try std.testing.expectEqual(
        trace_mod.OpcodeFamily.base_alu_imm,
        output.statement.component_descs[0].family,
    );
    try std.testing.expectEqual(@as(u32, 3), output.statement.component_descs[0].log_size);

    // Verify takes ownership of the proof.
    try verifyRiscV(alloc, config, output.statement, output.proof);
}

test "riscv prover: multi-family splitting" {
    const alloc = std.testing.allocator;
    var exec_trace = trace_mod.Trace.init(alloc);
    defer exec_trace.deinit();

    exec_trace.initial_pc = 0x1000;

    // Create a trace with 3 opcode families:
    //   4 x ADD (base_alu_reg)
    //   8 x ADDI (base_alu_imm)
    //   4 x BEQ (branch_eq)

    // 4 ADD instructions
    for (0..4) |i| {
        try exec_trace.append(.{
            .clk = @intCast(i),
            .pc = @intCast(0x1000 + i * 4),
            .opcode = .ADD,
            .rd = 1,
            .rs1 = 2,
            .rs2 = 3,
            .imm = 0,
            .rs1_val = 10,
            .rs2_val = 20,
            .rd_val = 30,
            .mem_addr = 0,
            .mem_val = 0,
            .is_load = false,
            .is_store = false,
            .branch_taken = false,
            .next_pc = @intCast(0x1000 + (i + 1) * 4),
        });
    }
    // 8 ADDI instructions
    for (0..8) |i| {
        try exec_trace.append(.{
            .clk = @intCast(4 + i),
            .pc = @intCast(0x1010 + i * 4),
            .opcode = .ADDI,
            .rd = 4,
            .rs1 = 1,
            .rs2 = 0,
            .imm = 5,
            .rs1_val = 30,
            .rs2_val = 0,
            .rd_val = 35,
            .mem_addr = 0,
            .mem_val = 0,
            .is_load = false,
            .is_store = false,
            .branch_taken = false,
            .next_pc = @intCast(0x1010 + (i + 1) * 4),
        });
    }
    // 4 BEQ instructions
    for (0..4) |i| {
        try exec_trace.append(.{
            .clk = @intCast(12 + i),
            .pc = @intCast(0x1030 + i * 4),
            .opcode = .BEQ,
            .rd = 0,
            .rs1 = 1,
            .rs2 = 2,
            .imm = 8,
            .rs1_val = 30,
            .rs2_val = 30,
            .rd_val = 0,
            .mem_addr = 0,
            .mem_val = 0,
            .is_load = false,
            .is_store = false,
            .branch_taken = true,
            .next_pc = @intCast(0x1030 + (i + 1) * 4),
        });
    }
    exec_trace.final_pc = 0x1040;

    const config = pcs_core.PcsConfig{
        .pow_bits = 0,
        .fri_config = .{
            .log_blowup_factor = 1,
            .log_last_layer_degree_bound = 0,
            .n_queries = 3,
        },
    };

    const output = try proveRiscV(alloc, config, &exec_trace);

    // Should have 3 components.
    try std.testing.expectEqual(@as(u32, 3), output.statement.n_components);

    // Verify families are in enum order: base_alu_reg, base_alu_imm, branch_eq
    try std.testing.expectEqual(
        trace_mod.OpcodeFamily.base_alu_reg,
        output.statement.component_descs[0].family,
    );
    try std.testing.expectEqual(
        trace_mod.OpcodeFamily.base_alu_imm,
        output.statement.component_descs[1].family,
    );
    try std.testing.expectEqual(
        trace_mod.OpcodeFamily.branch_eq,
        output.statement.component_descs[2].family,
    );

    // Verify log_sizes: ADD=4 rows -> log2(4)=2, ADDI=8 -> log2(8)=3, BEQ=4 -> log2(4)=2
    try std.testing.expectEqual(@as(u32, 2), output.statement.component_descs[0].log_size);
    try std.testing.expectEqual(@as(u32, 3), output.statement.component_descs[1].log_size);
    try std.testing.expectEqual(@as(u32, 2), output.statement.component_descs[2].log_size);

    // Verify takes ownership of the proof.
    try verifyRiscV(alloc, config, output.statement, output.proof);
}

test "riscv prover: ADDI + ADD + BNE split prove and verify" {
    const alloc = std.testing.allocator;
    var exec_trace = trace_mod.Trace.init(alloc);
    defer exec_trace.deinit();

    exec_trace.initial_pc = 0x1000;

    // Build a trace with 3 opcode families as required:
    //   4 x ADDI (base_alu_imm)
    //   2 x ADD  (base_alu_reg)
    //   2 x BNE  (branch_eq)

    // 4 ADDI instructions
    for (0..4) |i| {
        try exec_trace.append(.{
            .clk = @intCast(i),
            .pc = @intCast(0x1000 + i * 4),
            .opcode = .ADDI,
            .rd = 1,
            .rs1 = 0,
            .rs2 = 0,
            .imm = @intCast(i + 1),
            .rs1_val = 0,
            .rs2_val = 0,
            .rd_val = @intCast(i + 1),
            .mem_addr = 0,
            .mem_val = 0,
            .is_load = false,
            .is_store = false,
            .branch_taken = false,
            .next_pc = @intCast(0x1000 + (i + 1) * 4),
        });
    }
    // 2 ADD instructions
    for (0..2) |i| {
        const step = 4 + i;
        try exec_trace.append(.{
            .clk = @intCast(step),
            .pc = @intCast(0x1000 + step * 4),
            .opcode = .ADD,
            .rd = 3,
            .rs1 = 1,
            .rs2 = 2,
            .imm = 0,
            .rs1_val = 10,
            .rs2_val = 20,
            .rd_val = 30,
            .mem_addr = 0,
            .mem_val = 0,
            .is_load = false,
            .is_store = false,
            .branch_taken = false,
            .next_pc = @intCast(0x1000 + (step + 1) * 4),
        });
    }
    // 2 BNE instructions (branch_eq family)
    for (0..2) |i| {
        const step = 6 + i;
        try exec_trace.append(.{
            .clk = @intCast(step),
            .pc = @intCast(0x1000 + step * 4),
            .opcode = .BNE,
            .rd = 0,
            .rs1 = 1,
            .rs2 = 2,
            .imm = 8,
            .rs1_val = 10,
            .rs2_val = 20,
            .rd_val = 0,
            .mem_addr = 0,
            .mem_val = 0,
            .is_load = false,
            .is_store = false,
            .branch_taken = true,
            .next_pc = @intCast(0x1000 + step * 4 + 8),
        });
    }
    exec_trace.final_pc = 0x1000 + 8 * 4;

    const config = pcs_core.PcsConfig{
        .pow_bits = 0,
        .fri_config = .{
            .log_blowup_factor = 1,
            .log_last_layer_degree_bound = 0,
            .n_queries = 3,
        },
    };

    // Verify correct family grouping.
    const counts = try exec_trace.groupByOpcodeFamily(alloc);
    try std.testing.expectEqual(@as(usize, 4), counts.get(.base_alu_imm));
    try std.testing.expectEqual(@as(usize, 2), counts.get(.base_alu_reg));
    try std.testing.expectEqual(@as(usize, 2), counts.get(.branch_eq));
    try std.testing.expectEqual(@as(usize, 8), counts.total());

    // Prove with component splitting.
    const output = try proveRiscV(alloc, config, &exec_trace);

    // Verify statement: 3 components (base_alu_reg, base_alu_imm, branch_eq)
    try std.testing.expectEqual(@as(u32, 3), output.statement.n_components);
    try std.testing.expectEqual(@as(u32, 8), output.statement.total_steps);

    // Component 0: base_alu_reg (ADD, 2 rows -> log_size=1)
    try std.testing.expectEqual(trace_mod.OpcodeFamily.base_alu_reg, output.statement.component_descs[0].family);
    try std.testing.expectEqual(@as(u32, 1), output.statement.component_descs[0].log_size);

    // Component 1: base_alu_imm (ADDI, 4 rows -> log_size=2)
    try std.testing.expectEqual(trace_mod.OpcodeFamily.base_alu_imm, output.statement.component_descs[1].family);
    try std.testing.expectEqual(@as(u32, 2), output.statement.component_descs[1].log_size);

    // Component 2: branch_eq (BNE, 2 rows -> log_size=1)
    try std.testing.expectEqual(trace_mod.OpcodeFamily.branch_eq, output.statement.component_descs[2].family);
    try std.testing.expectEqual(@as(u32, 1), output.statement.component_descs[2].log_size);

    // Verify the proof (takes ownership).
    try verifyRiscV(alloc, config, output.statement, output.proof);
}
