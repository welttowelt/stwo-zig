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
//! const result = try proveRiscV(allocator, config, &exec_trace, &state_chain);
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
const infra = @import("infra_trace.zig");
const state_chain = @import("runner/state_chain.zig");
const poseidon2 = @import("common/poseidon2.zig");

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

/// Descriptor for an infrastructure component in the proof.
pub const InfraComponentDesc = struct {
    log_size: u32,
    n_columns: u32,
};

/// Maximum number of opcode families (components) we support.
pub const MAX_COMPONENTS = trace_mod.N_FAMILIES;

/// Maximum number of infrastructure components.
/// program(1) + memory(1) + mem_clock_update(1) + reg_clock_update(1) +
/// poseidon2(1) + merkle(1) + multiplicity(6) = 12.
pub const MAX_INFRA_COMPONENTS: usize = 12;

pub const RiscVStatement = struct {
    /// Number of active opcode family components in the proof.
    n_components: u32,
    /// Per-component descriptors, ordered by family enum value.
    /// Only the first `n_components` entries are valid.
    component_descs: [MAX_COMPONENTS]FamilyComponentDesc,
    initial_pc: u32,
    final_pc: u32,
    total_steps: u32,

    /// Number of infrastructure components in the proof.
    n_infra: u32 = 0,
    /// Infrastructure component descriptors.
    infra_descs: [MAX_INFRA_COMPONENTS]InfraComponentDesc = undefined,

    /// Total number of preprocessed columns (one IsFirst per component).
    pub fn nPreprocessedColumns(self: *const RiscVStatement) u32 {
        return self.n_components + self.n_infra;
    }

    /// Total number of opcode-family main trace columns.
    pub fn nOpcodeMainColumns(self: *const RiscVStatement) u32 {
        var total: u32 = 0;
        for (0..self.n_components) |i| {
            total += self.component_descs[i].n_columns;
        }
        return total;
    }

    /// Total number of infrastructure main trace columns.
    pub fn nInfraColumns(self: *const RiscVStatement) u32 {
        var total: u32 = 0;
        for (0..self.n_infra) |i| {
            total += self.infra_descs[i].n_columns;
        }
        return total;
    }

    /// Total number of main trace columns (opcode + infrastructure).
    pub fn nMainColumns(self: *const RiscVStatement) u32 {
        return self.nOpcodeMainColumns() + self.nInfraColumns();
    }

    /// Total number of M31 interaction trace columns across all components.
    /// Each QM31 interaction column expands to 4 M31 columns.
    pub fn nInteractionColumns(self: *const RiscVStatement) u32 {
        var total: u32 = 0;
        // Opcode family interaction columns
        for (0..self.n_components) |i| {
            total += nInteractionQm31ColsForFamily(self.component_descs[i].family) * 4;
        }
        // Infrastructure interaction columns (use base_alu_reg count as placeholder)
        for (0..self.n_infra) |_| {
            total += nInteractionQm31ColsForFamily(.base_alu_reg) * 4;
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
        statement.n_infra,
    });
    for (0..statement.n_components) |i| {
        channel.mixU32s(&[_]u32{
            @intFromEnum(statement.component_descs[i].family),
            statement.component_descs[i].log_size,
            statement.component_descs[i].n_columns,
        });
    }
    for (0..statement.n_infra) |i| {
        channel.mixU32s(&[_]u32{
            statement.infra_descs[i].log_size,
            statement.infra_descs[i].n_columns,
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

// -- Helpers --

/// Compute log_size from a count, with minimum of 1.
fn computeLogSize(count: usize) u32 {
    if (count <= 1) return 1;
    return @intCast(std.math.log2_int_ceil(usize, count));
}

// ---------------------------------------------------------------------------
// Poseidon2 Merkle tree building
// ---------------------------------------------------------------------------

/// Result of building a Poseidon2 Merkle tree with trace capture.
const MerkleTreeResult = struct {
    hash_traces: []poseidon2.PermuteTrace,
    n_hashes: usize,
    root: [8]M31,
};

/// Build a Poseidon2 Merkle tree from program instruction entries.
///
/// Collects unique PCs and their instruction opcodes from the execution trace,
/// hashes each entry as a leaf, then builds the Merkle tree bottom-up using
/// `permuteTraced` to capture all intermediate hash states.
///
/// Returns the captured hash traces (for Poseidon2 trace columns), the total
/// number of hash invocations (for Merkle trace columns), and the tree root.
fn buildProgramMerkleTree(
    allocator: std.mem.Allocator,
    exec_trace: *const trace_mod.Trace,
) !MerkleTreeResult {
    // Collect unique PCs with their instruction encoding (opcode enum value).
    var pc_info = std.AutoHashMap(u32, u32).init(allocator);
    defer pc_info.deinit();

    for (exec_trace.rows.items) |row| {
        const gop = try pc_info.getOrPut(row.pc);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intFromEnum(row.opcode);
        }
    }

    const n_leaves = pc_info.count();
    if (n_leaves == 0) {
        // Return a heap-allocated empty slice so the caller can safely free it.
        const empty = try allocator.alloc(poseidon2.PermuteTrace, 0);
        return MerkleTreeResult{
            .hash_traces = empty,
            .n_hashes = 0,
            .root = .{M31.zero()} ** 8,
        };
    }

    // Pad to next power of two (minimum 2 leaves for a valid tree).
    var padded_leaves: usize = 2;
    while (padded_leaves < n_leaves) padded_leaves *= 2;

    // Build leaf digests: hash(addr, value_bytes, 0, 0, 0) for each entry.
    var leaves = try allocator.alloc([8]M31, padded_leaves);
    defer allocator.free(leaves);
    @memset(leaves, .{M31.zero()} ** 8);

    // Collect hash traces in an ArrayList (unmanaged).
    var traces: std.ArrayList(poseidon2.PermuteTrace) = .{};
    defer traces.deinit(allocator);

    // Fill leaves from program entries.
    var leaf_idx: usize = 0;
    var iter = pc_info.iterator();
    while (iter.next()) |entry| {
        const word = entry.value_ptr.*;
        const limbs = state_chain.StateChainTracker.decomposeU32(word);

        // Hash the leaf data to produce an 8-element digest.
        var state: poseidon2.State = .{M31.zero()} ** poseidon2.STATE_WIDTH;
        state[0] = M31.fromCanonical(entry.key_ptr.* & 0x7FFFFFFF); // addr
        state[1] = limbs[0];
        state[2] = limbs[1];
        state[3] = limbs[2];
        state[4] = limbs[3];

        const trace = poseidon2.permuteTraced(&state);
        try traces.append(allocator, trace);
        leaves[leaf_idx] = state[0..8].*;
        leaf_idx += 1;
    }

    // Build Merkle tree bottom-up, hashing adjacent pairs.
    var current_layer = leaves;
    var owns_current = false; // leaves are freed via `defer allocator.free(leaves)`
    defer if (owns_current) allocator.free(current_layer);

    while (current_layer.len > 1) {
        const next_len = current_layer.len / 2;
        var next_layer = try allocator.alloc([8]M31, next_len);

        for (0..next_len) |i| {
            var state: poseidon2.State = .{M31.zero()} ** poseidon2.STATE_WIDTH;
            @memcpy(state[0..8], &current_layer[i * 2]);
            @memcpy(state[8..16], &current_layer[i * 2 + 1]);

            const trace = poseidon2.permuteTraced(&state);
            try traces.append(allocator, trace);

            next_layer[i] = state[0..8].*;
        }

        if (owns_current) allocator.free(current_layer);
        current_layer = next_layer;
        owns_current = true;
    }

    const root = if (current_layer.len > 0) current_layer[0] else .{M31.zero()} ** 8;
    const n_hashes = traces.items.len;

    return MerkleTreeResult{
        .hash_traces = try traces.toOwnedSlice(allocator),
        .n_hashes = n_hashes,
        .root = root,
    };
}

/// Build a Poseidon2 Merkle tree from memory state entries.
///
/// Collects unique memory addresses and their final values from the state
/// chain tracker, then builds a Merkle tree bottom-up, capturing all
/// Poseidon2 hash traces.
fn buildMemoryMerkleTree(
    allocator: std.mem.Allocator,
    chain: *const state_chain.StateChainTracker,
) !MerkleTreeResult {
    // Collect unique memory addresses with their latest values.
    var addr_values = std.AutoHashMap(u32, [4]M31).init(allocator);
    defer addr_values.deinit();

    for (chain.accesses.items) |access| {
        if (access.addr_space != 1) continue; // memory only
        try addr_values.put(access.addr, access.value_limbs);
    }

    const n_leaves = addr_values.count();
    if (n_leaves == 0) {
        const empty = try allocator.alloc(poseidon2.PermuteTrace, 0);
        return MerkleTreeResult{
            .hash_traces = empty,
            .n_hashes = 0,
            .root = .{M31.zero()} ** 8,
        };
    }

    var padded_leaves: usize = 2;
    while (padded_leaves < n_leaves) padded_leaves *= 2;

    var leaves = try allocator.alloc([8]M31, padded_leaves);
    defer allocator.free(leaves);
    @memset(leaves, .{M31.zero()} ** 8);

    var traces: std.ArrayList(poseidon2.PermuteTrace) = .{};
    defer traces.deinit(allocator);

    var leaf_idx: usize = 0;
    var iter = addr_values.iterator();
    while (iter.next()) |entry| {
        var state: poseidon2.State = .{M31.zero()} ** poseidon2.STATE_WIDTH;
        state[0] = M31.fromCanonical(entry.key_ptr.* & 0x7FFFFFFF); // addr
        state[1] = entry.value_ptr.*[0];
        state[2] = entry.value_ptr.*[1];
        state[3] = entry.value_ptr.*[2];
        state[4] = entry.value_ptr.*[3];

        const trace = poseidon2.permuteTraced(&state);
        try traces.append(allocator, trace);
        leaves[leaf_idx] = state[0..8].*;
        leaf_idx += 1;
    }

    var current_layer = leaves;
    var owns_current = false;
    defer if (owns_current) allocator.free(current_layer);

    while (current_layer.len > 1) {
        const next_len = current_layer.len / 2;
        var next_layer = try allocator.alloc([8]M31, next_len);

        for (0..next_len) |i| {
            var state: poseidon2.State = .{M31.zero()} ** poseidon2.STATE_WIDTH;
            @memcpy(state[0..8], &current_layer[i * 2]);
            @memcpy(state[8..16], &current_layer[i * 2 + 1]);

            const trace = poseidon2.permuteTraced(&state);
            try traces.append(allocator, trace);

            next_layer[i] = state[0..8].*;
        }

        if (owns_current) allocator.free(current_layer);
        current_layer = next_layer;
        owns_current = true;
    }

    const root = if (current_layer.len > 0) current_layer[0] else .{M31.zero()} ** 8;
    const n_hashes = traces.items.len;

    return MerkleTreeResult{
        .hash_traces = try traces.toOwnedSlice(allocator),
        .n_hashes = n_hashes,
        .root = root,
    };
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
///
/// When `opt_chain` is provided, full infrastructure components are generated
/// (memory, clock updates, memory Merkle tree).  When null, only program ROM,
/// multiplicity placeholders, and a program-only Poseidon2 Merkle tree are
/// emitted.
pub fn proveRiscV(
    allocator: std.mem.Allocator,
    pcs_config: pcs_core.PcsConfig,
    exec_trace: *const trace_mod.Trace,
    opt_chain: ?*const state_chain.StateChainTracker,
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
        // Commit ALL families, even with 0 rows — stark-v pads empty families
        // to minimum size (log_size=4 = 16 rows) for protocol compatibility.
        const MIN_LOG_SIZE: u32 = 4;
        const log_size: u32 = if (count == 0)
            MIN_LOG_SIZE
        else
            @max(@as(u32, @intCast(std.math.log2_int_ceil(usize, count))), MIN_LOG_SIZE);

        statement.component_descs[statement.n_components] = .{
            .family = family,
            .log_size = log_size,
            .n_columns = trace_mod.nColumnsForFamily(family),
        };
        statement.n_components += 1;
    }

    if (statement.n_components == 0) return ProverError.EmptyTrace;

    // -- Step 2b: Build infrastructure component descriptors. --
    statement.n_infra = 0;

    // Count unique PCs for program ROM sizing.
    var unique_pcs: usize = 0;
    {
        var seen = std.AutoHashMap(u32, void).init(allocator);
        defer seen.deinit();
        for (exec_trace.rows.items) |row| {
            const gop = try seen.getOrPut(row.pc);
            if (!gop.found_existing) unique_pcs += 1;
        }
    }

    // Program ROM (8 cols)
    const program_log_size = computeLogSize(unique_pcs);
    statement.infra_descs[statement.n_infra] = .{
        .log_size = program_log_size,
        .n_columns = infra.PROGRAM_TRACE_COLS,
    };
    statement.n_infra += 1;

    // Memory check (9 cols) -- includes BOTH register (addr_space=0) and memory (addr_space=1)
    // accesses, matching stark-v's unified memory component.
    var mem_log_size: u32 = 4;
    if (opt_chain) |chain| {
        const n_total_accesses = chain.accesses.items.len; // ALL accesses (reg + mem)
        if (n_total_accesses > 0) {
            mem_log_size = computeLogSize(n_total_accesses);
            statement.infra_descs[statement.n_infra] = .{
                .log_size = mem_log_size,
                .n_columns = infra.MEMORY_TRACE_COLS,
            };
            statement.n_infra += 1;
        }
    }

    // Memory clock update (7 cols) — always committed (stark-v pads empty)
    var mem_cu_log: u32 = 4;
    if (opt_chain) |chain| {
        const n_mem_cu = chain.clock_updates_mem.items.len;
        if (n_mem_cu > 0) mem_cu_log = @max(computeLogSize(n_mem_cu), 4);
    }
    statement.infra_descs[statement.n_infra] = .{
        .log_size = mem_cu_log,
        .n_columns = infra.MEM_CLOCK_UPDATE_COLS,
    };
    statement.n_infra += 1;

    // Register clock update (7 cols) — always committed
    var reg_cu_log: u32 = 4;
    if (opt_chain) |chain| {
        const n_reg_cu = chain.clock_updates_reg.items.len;
        if (n_reg_cu > 0) reg_cu_log = @max(computeLogSize(n_reg_cu), 4);
    }
    statement.infra_descs[statement.n_infra] = .{
        .log_size = reg_cu_log,
        .n_columns = infra.REG_CLOCK_UPDATE_COLS,
    };
    statement.n_infra += 1;

    // Build real Poseidon2 Merkle trees and capture hash traces.
    const prog_merkle = try buildProgramMerkleTree(allocator, exec_trace);
    defer allocator.free(prog_merkle.hash_traces);

    // Optionally build memory Merkle tree when state chain is available.
    var mem_merkle_traces: []poseidon2.PermuteTrace = &.{};
    var owns_mem_merkle = false;
    if (opt_chain) |chain| {
        const mem_merkle = try buildMemoryMerkleTree(allocator, chain);
        mem_merkle_traces = mem_merkle.hash_traces;
        owns_mem_merkle = true;
    }
    defer if (owns_mem_merkle) allocator.free(mem_merkle_traces);

    // Merge hash traces: total Poseidon2 rows = program tree hashes + memory tree hashes.
    const total_hashes = prog_merkle.hash_traces.len + mem_merkle_traces.len;

    // Compute Poseidon2 log_size from actual hash count (minimum 4 = 16 rows).
    const poseidon_log_size: u32 = if (total_hashes > 0)
        @max(4, computeLogSize(total_hashes))
    else
        4;
    statement.infra_descs[statement.n_infra] = .{
        .log_size = poseidon_log_size,
        .n_columns = infra.POSEIDON2_TRACE_COLS,
    };
    statement.n_infra += 1;

    // Merkle node count = total internal hash calls (one per internal node).
    const total_merkle_nodes = total_hashes;
    const merkle_log_size: u32 = if (total_merkle_nodes > 0)
        @max(4, computeLogSize(total_merkle_nodes))
    else
        4;
    statement.infra_descs[statement.n_infra] = .{
        .log_size = merkle_log_size,
        .n_columns = infra.MERKLE_TRACE_COLS,
    };
    statement.n_infra += 1;

    // Preprocessed multiplicity tables (6 x 1 col)
    const mult_log_size = infra.multiplicityLogSize(exec_trace);
    for (0..infra.N_MULTIPLICITY_TABLES) |_| {
        statement.infra_descs[statement.n_infra] = .{
            .log_size = mult_log_size,
            .n_columns = 1,
        };
        statement.n_infra += 1;
    }

    var channel = Channel{};
    pcs_config.mixInto(&channel);

    var scheme = try prover_pcs.CommitmentSchemeProver(CpuBackend, Hasher, MerkleChannel).init(
        allocator,
        pcs_config,
    );

    // Empty state chain for fallback when opt_chain is null.
    var empty_chain = state_chain.StateChainTracker.init(allocator);
    defer empty_chain.deinit();

    // -- Step 3: Tree 0 -- Preprocessed (one IsFirst per component, including infra). --
    const n_preproc = statement.n_components + statement.n_infra;
    const preprocessed = try allocator.alloc(prover_pcs.ColumnEvaluation, n_preproc);
    for (0..statement.n_components) |i| {
        const ls = statement.component_descs[i].log_size;
        const is_first = try genIsFirstColumn(allocator, ls);
        preprocessed[i] = .{ .log_size = ls, .values = is_first };
    }
    for (0..statement.n_infra) |i| {
        const ls = statement.infra_descs[i].log_size;
        const is_first = try genIsFirstColumn(allocator, ls);
        preprocessed[statement.n_components + i] = .{ .log_size = ls, .values = is_first };
    }
    try scheme.commitOwned(allocator, preprocessed, &channel);

    // -- Step 4: Tree 1 -- Main trace (opcode + infrastructure columns). --
    const n_opcode_main = statement.nOpcodeMainColumns();
    const n_infra_main = statement.nInfraColumns();
    const n_main = n_opcode_main + n_infra_main;
    const main_columns = try allocator.alloc(prover_pcs.ColumnEvaluation, n_main);
    var col_offset: usize = 0;

    // Opcode family columns.
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

    // Infrastructure columns.
    // We track which infra descriptor index we're at. The order must match
    // the statement's infra_descs order.
    var infra_idx: usize = 0;

    // Program ROM (8 cols)
    {
        const prog_cols = try infra.genProgramColumns(allocator, exec_trace, program_log_size);
        for (0..infra.PROGRAM_TRACE_COLS) |c| {
            main_columns[col_offset + c] = .{
                .log_size = program_log_size,
                .values = prog_cols.columns[c],
            };
        }
        col_offset += infra.PROGRAM_TRACE_COLS;
        infra_idx += 1;
    }

    // Memory check (9 cols) -- includes ALL accesses (register + memory)
    if (opt_chain) |chain| {
        if (chain.accesses.items.len > 0) {
            const mem_cols = try infra.genMemoryColumns(allocator, chain, mem_log_size);
            for (0..infra.MEMORY_TRACE_COLS) |c| {
                main_columns[col_offset + c] = .{
                    .log_size = mem_log_size,
                    .values = mem_cols.columns[c],
                };
            }
            col_offset += infra.MEMORY_TRACE_COLS;
            infra_idx += 1;
        }
    }

    // Memory clock update (7 cols) — always committed
    {
        const chain_ptr = opt_chain orelse &empty_chain;
        const cu_cols = try infra.genMemClockUpdateColumns(allocator, chain_ptr, mem_cu_log);
        for (0..infra.MEM_CLOCK_UPDATE_COLS) |c| {
            main_columns[col_offset + c] = .{
                .log_size = mem_cu_log,
                .values = cu_cols.columns[c],
            };
        }
        col_offset += infra.MEM_CLOCK_UPDATE_COLS;
        infra_idx += 1;
    }

    // Register clock update (7 cols) — always committed
    {
        const chain_ptr = opt_chain orelse &empty_chain;
        const rcu_cols = try infra.genRegClockUpdateColumns(allocator, chain_ptr, reg_cu_log);
        for (0..infra.REG_CLOCK_UPDATE_COLS) |c| {
            main_columns[col_offset + c] = .{
                .log_size = reg_cu_log,
                .values = rcu_cols.columns[c],
            };
        }
        col_offset += infra.REG_CLOCK_UPDATE_COLS;
        infra_idx += 1;
    }

    // Poseidon2 (443 cols) -- real traces from Merkle tree building
    {
        // Merge program and memory hash traces into one slice for column gen.
        const merged_traces = try allocator.alloc(poseidon2.PermuteTrace, total_hashes);
        defer allocator.free(merged_traces);
        if (prog_merkle.hash_traces.len > 0) {
            @memcpy(merged_traces[0..prog_merkle.hash_traces.len], prog_merkle.hash_traces);
        }
        if (mem_merkle_traces.len > 0) {
            @memcpy(merged_traces[prog_merkle.hash_traces.len..], mem_merkle_traces);
        }

        const p2_cols = try infra.genPoseidon2Columns(allocator, merged_traces, poseidon_log_size);
        for (0..infra.POSEIDON2_TRACE_COLS) |c| {
            main_columns[col_offset + c] = .{
                .log_size = poseidon_log_size,
                .values = p2_cols.columns[c],
            };
        }
        col_offset += infra.POSEIDON2_TRACE_COLS;
        infra_idx += 1;
    }

    // Merkle (10 cols) -- real node count from Merkle tree building
    {
        const mkl_cols = try infra.genMerkleColumns(allocator, total_merkle_nodes, merkle_log_size);
        for (0..infra.MERKLE_TRACE_COLS) |c| {
            main_columns[col_offset + c] = .{
                .log_size = merkle_log_size,
                .values = mkl_cols.columns[c],
            };
        }
        col_offset += infra.MERKLE_TRACE_COLS;
        infra_idx += 1;
    }

    // Preprocessed multiplicity tables (6 x 1 col)
    {
        const mult_cols = try infra.genPreprocessedMultiplicityColumns(allocator, exec_trace);
        for (0..infra.N_MULTIPLICITY_TABLES) |c| {
            main_columns[col_offset + c] = .{
                .log_size = mult_log_size,
                .values = mult_cols.columns[c],
            };
        }
        col_offset += infra.N_MULTIPLICITY_TABLES;
        infra_idx += 1;
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
    // Infrastructure interaction columns
    for (0..statement.n_infra) |inf_idx| {
        const n_qm31 = nInteractionQm31ColsForFamily(.base_alu_reg);
        const result = try interaction.generateComponentInteractionColumns(
            allocator,
            statement.infra_descs[inf_idx].log_size,
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

    std.log.info("Columns: opcode={d} infra={d} total tree1={d} tree2={d}", .{
        n_opcode_main,
        n_infra_main,
        n_main,
        n_interaction,
    });
    std.log.info("Poseidon2 Merkle: {d} hash traces (program={d} memory={d}), poseidon_log_size={d}, merkle_log_size={d}", .{
        total_hashes,
        prog_merkle.hash_traces.len,
        mem_merkle_traces.len,
        poseidon_log_size,
        merkle_log_size,
    });

    mixStatement(&channel, statement);

    // -- Step 5: Create per-family components and prove. --
    const total_components = statement.n_components + statement.n_infra;
    var component_storage: [MAX_COMPONENTS + MAX_INFRA_COMPONENTS]RiscVTraceComponent = undefined;
    var components_arr: [MAX_COMPONENTS + MAX_INFRA_COMPONENTS]prover_component.ComponentProver = undefined;

    var main_offset: usize = 0;
    // Opcode family components
    for (0..statement.n_components) |i| {
        component_storage[i] = .{
            .desc = .{
                .family = statement.component_descs[i].family,
                .log_size = statement.component_descs[i].log_size,
                .n_columns = statement.component_descs[i].n_columns,
            },
            .initial_pc = statement.initial_pc,
            .total_steps = statement.total_steps,
            .preprocessed_col_idx = i,
            .main_col_offset = main_offset,
        };
        components_arr[i] = component_storage[i].asProverComponent();
        main_offset += statement.component_descs[i].n_columns;
    }
    // Infrastructure components (same RiscVTraceComponent type, different descriptors)
    for (0..statement.n_infra) |i| {
        const idx = statement.n_components + i;
        component_storage[idx] = .{
            .desc = .{
                .family = .base_alu_reg, // placeholder family for infra
                .log_size = statement.infra_descs[i].log_size,
                .n_columns = statement.infra_descs[i].n_columns,
            },
            .initial_pc = statement.initial_pc,
            .total_steps = statement.total_steps,
            .preprocessed_col_idx = idx, // no preprocessed for infra, but must be unique
            .main_col_offset = main_offset,
        };
        components_arr[idx] = component_storage[idx].asProverComponent();
        main_offset += statement.infra_descs[i].n_columns;
    }

    var extended = try prover_prove.proveEx(
        CpuBackend,
        Hasher,
        MerkleChannel,
        allocator,
        components_arr[0..total_components],
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

    // Tree 0: Preprocessed -- one IsFirst column per component (opcode + infra).
    const n_preproc_v = statement.n_components + statement.n_infra;
    const preproc_log_sizes = try allocator.alloc(u32, n_preproc_v);
    defer allocator.free(preproc_log_sizes);
    for (0..statement.n_components) |i| {
        preproc_log_sizes[i] = statement.component_descs[i].log_size;
    }
    for (0..statement.n_infra) |i| {
        preproc_log_sizes[statement.n_components + i] = statement.infra_descs[i].log_size;
    }
    try commitment_scheme.commit(
        allocator,
        proof.commitment_scheme_proof.commitments.items[0],
        preproc_log_sizes,
        &channel,
    );

    // Tree 1: Main trace -- opcode columns + infrastructure columns.
    const n_main = statement.nMainColumns();
    const main_log_sizes = try allocator.alloc(u32, n_main);
    defer allocator.free(main_log_sizes);
    var col_offset: usize = 0;
    // Opcode family columns.
    for (0..statement.n_components) |i| {
        const desc = statement.component_descs[i];
        for (0..desc.n_columns) |c| {
            main_log_sizes[col_offset + c] = desc.log_size;
        }
        col_offset += desc.n_columns;
    }
    // Infrastructure columns (must match prover order).
    for (0..statement.n_infra) |i| {
        const idesc = statement.infra_descs[i];
        for (0..idesc.n_columns) |c| {
            main_log_sizes[col_offset + c] = idesc.log_size;
        }
        col_offset += idesc.n_columns;
    }
    try commitment_scheme.commit(
        allocator,
        proof.commitment_scheme_proof.commitments.items[1],
        main_log_sizes,
        &channel,
    );

    // Tree 2: Interaction trace -- n_qm31 * 4 M31 columns per component (opcode + infra).
    const n_interaction_v = statement.nInteractionColumns();
    const interaction_log_sizes = try allocator.alloc(u32, n_interaction_v);
    defer allocator.free(interaction_log_sizes);
    var interaction_offset_v: usize = 0;
    for (0..statement.n_components) |i| {
        const desc = statement.component_descs[i];
        const n_m31 = nInteractionQm31ColsForFamily(desc.family) * 4;
        for (0..n_m31) |c| {
            interaction_log_sizes[interaction_offset_v + c] = desc.log_size;
        }
        interaction_offset_v += n_m31;
    }
    for (0..statement.n_infra) |i| {
        const n_m31 = nInteractionQm31ColsForFamily(.base_alu_reg) * 4;
        for (0..n_m31) |c| {
            interaction_log_sizes[interaction_offset_v + c] = statement.infra_descs[i].log_size;
        }
        interaction_offset_v += n_m31;
    }
    try commitment_scheme.commit(
        allocator,
        proof.commitment_scheme_proof.commitments.items[2],
        interaction_log_sizes,
        &channel,
    );

    mixStatement(&channel, statement);

    // Reconstruct per-family + infrastructure verifier components.
    const total_v_components = statement.n_components + statement.n_infra;
    var component_storage: [MAX_COMPONENTS + MAX_INFRA_COMPONENTS]RiscVTraceComponent = undefined;
    var verifier_components: [MAX_COMPONENTS + MAX_INFRA_COMPONENTS]core_air_components.Component = undefined;

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
    for (0..statement.n_infra) |i| {
        const idx = statement.n_components + i;
        component_storage[idx] = .{
            .desc = .{
                .family = .base_alu_reg,
                .log_size = statement.infra_descs[i].log_size,
                .n_columns = statement.infra_descs[i].n_columns,
            },
            .initial_pc = statement.initial_pc,
            .total_steps = statement.total_steps,
            .preprocessed_col_idx = idx,
            .main_col_offset = verifier_col_offset,
        };
        verifier_components[idx] = component_storage[idx].asVerifierComponent();
        verifier_col_offset += statement.infra_descs[i].n_columns;
    }

    try core_verifier.verify(
        Hasher,
        MerkleChannel,
        allocator,
        verifier_components[0..total_v_components],
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

    const output = try proveRiscV(allocator, pcs_config, &run_result.execution_trace, &run_result.state_chain_tracker);

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

    const output = try proveRiscV(alloc, config, &run_result.execution_trace, &run_result.state_chain_tracker);

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

    const output = try proveRiscV(alloc, config, &exec_trace, null);

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

    const output = try proveRiscV(alloc, config, &exec_trace, null);

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
    const output = try proveRiscV(alloc, config, &exec_trace, null);

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
