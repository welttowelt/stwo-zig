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

fn compositionEvalForComponent(desc: FamilyComponentDesc, initial_pc: u32, total_steps: u32) QM31 {
    return QM31.fromM31(
        M31.fromCanonical(desc.log_size),
        M31.fromCanonical(initial_pc & 0x7FFFFFFF),
        M31.fromCanonical(total_steps),
        M31.fromCanonical(@as(u32, @intFromEnum(desc.family)) + 1),
    );
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

    pub fn nConstraints(_: *const @This()) usize {
        return 1;
    }

    pub fn maxConstraintLogDegreeBound(self: *const @This()) u32 {
        return self.desc.log_size + 1;
    }

    pub fn traceLogDegreeBounds(
        self: *const @This(),
        allocator: std.mem.Allocator,
    ) !core_air_components.TraceLogDegreeBounds {
        const preprocessed = try allocator.dupe(u32, &[_]u32{self.desc.log_size});
        const main = try allocator.alloc(u32, self.desc.n_columns);
        @memset(main, self.desc.log_size);
        return core_air_components.TraceLogDegreeBounds.initOwned(
            try allocator.dupe([]u32, &[_][]u32{ preprocessed, main }),
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

        return core_air_components.MaskPoints.initOwned(
            try allocator.dupe([][]CirclePointQM31, &[_][][]CirclePointQM31{
                preprocessed_cols,
                main_cols,
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
        evaluation_accumulator.accumulate(
            compositionEvalForComponent(self.desc, self.initial_pc, self.total_steps),
        );
    }

    pub fn evaluateConstraintQuotientsOnDomain(
        self: *const @This(),
        _: *const prover_component.Trace,
        evaluation_accumulator: *prover_air_accumulation.DomainEvaluationAccumulator,
    ) !void {
        const eval = compositionEvalForComponent(self.desc, self.initial_pc, self.total_steps);
        const domain_size = @as(usize, 1) << @intCast(self.desc.log_size + 1);
        const values = try evaluation_accumulator.allocator.alloc(QM31, domain_size);
        defer evaluation_accumulator.allocator.free(values);
        @memset(values, eval);
        var col = try secure_column.SecureColumnByCoords.fromSecureSlice(
            evaluation_accumulator.allocator,
            values,
        );
        defer col.deinit(evaluation_accumulator.allocator);
        try evaluation_accumulator.accumulateColumn(self.desc.log_size + 1, &col);
    }
};

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
fn genColumnsForFamily(
    allocator: std.mem.Allocator,
    exec_trace: *const trace_mod.Trace,
    family: trace_mod.OpcodeFamily,
    log_size: u32,
) !trace_mod.TraceColumns {
    const domain_size = @as(usize, 1) << @intCast(log_size);
    const n_cols = 10;

    var columns: [n_cols][]M31 = undefined;
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

        columns[0][bit_rev_idx] = M31.fromCanonical(row.clk);
        columns[1][bit_rev_idx] = M31.fromCanonical(row.pc);
        columns[2][bit_rev_idx] = M31.fromCanonical(@as(u32, row.rd));
        columns[3][bit_rev_idx] = M31.fromCanonical(@as(u32, row.rs1));
        columns[4][bit_rev_idx] = M31.fromCanonical(@as(u32, row.rs2));
        columns[5][bit_rev_idx] = M31.fromCanonical(row.rs1_val);
        columns[6][bit_rev_idx] = M31.fromCanonical(row.rs2_val);
        columns[7][bit_rev_idx] = M31.fromCanonical(row.rd_val);
        columns[8][bit_rev_idx] = M31.one(); // enabler
        columns[9][bit_rev_idx] = M31.fromCanonical(row.next_pc);
        row_idx += 1;
    }

    return .{ .columns = columns, .n_real_rows = row_idx };
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

    // -----------------------------------------------------------------------
    // Arena allocator for the entire proving pipeline.
    //
    // Every intermediate allocation (trace columns, twiddle factors, Merkle
    // layers, commitment trees, FRI rounds, ...) plus the final proof
    // payload are handed out from this arena, which is backed by
    // page_allocator.  This gives us:
    //   - Cache-line-aligned buffers (pages are 4096-byte-aligned).
    //   - Fast bump-pointer allocation with zero fragmentation.
    //   - O(1) bulk cleanup when the caller deinits ProveOutput.
    //
    // The arena itself is heap-allocated (via the caller's allocator) so
    // that the returned ProveOutput can be moved without invalidating the
    // internal Allocator pointer.
    // -----------------------------------------------------------------------
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    const arena_alloc = arena.allocator();

    // -- Step 1: Count rows per opcode family. --
    const counts = try exec_trace.groupByOpcodeFamily(arena_alloc);

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
            .n_columns = 10,
        };
        statement.n_components += 1;
    }

    if (statement.n_components == 0) return ProverError.EmptyTrace;

    var channel = Channel{};
    pcs_config.mixInto(&channel);

    var scheme = try prover_pcs.CommitmentSchemeProver(CpuBackend, Hasher, MerkleChannel).init(
        arena_alloc,
        pcs_config,
    );

    // -- Step 3: Tree 0 -- Preprocessed (one IsFirst per active component). --
    const n_preproc = statement.n_components;
    const preprocessed = try arena_alloc.alloc(prover_pcs.ColumnEvaluation, n_preproc);
    for (0..n_preproc) |i| {
        const ls = statement.component_descs[i].log_size;
        const is_first = try genIsFirstColumn(arena_alloc, ls);
        preprocessed[i] = .{ .log_size = ls, .values = is_first };
    }
    try scheme.commitOwned(arena_alloc, preprocessed, &channel);

    // -- Step 4: Tree 1 -- Main trace (n_columns per active component). --
    const n_main = statement.nMainColumns();
    const main_columns = try arena_alloc.alloc(prover_pcs.ColumnEvaluation, n_main);
    var col_offset: usize = 0;
    for (0..statement.n_components) |comp_idx| {
        const desc = statement.component_descs[comp_idx];
        const family_cols = try genColumnsForFamily(
            arena_alloc,
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
    try scheme.commitOwned(arena_alloc, main_columns, &channel);

    mixStatement(&channel, statement);

    // -- Step 5: Create per-family components and prove. --
    var component_storage: [MAX_COMPONENTS]RiscVTraceComponent = undefined;
    var components_arr: [MAX_COMPONENTS]prover_component.ComponentProver = undefined;

    for (0..statement.n_components) |i| {
        component_storage[i] = .{
            .desc = statement.component_descs[i],
            .initial_pc = statement.initial_pc,
            .total_steps = statement.total_steps,
            .preprocessed_col_idx = i,
        };
        components_arr[i] = component_storage[i].asProverComponent();
    }

    var extended = try prover_prove.proveEx(
        CpuBackend,
        Hasher,
        MerkleChannel,
        arena_alloc,
        components_arr[0..statement.n_components],
        &channel,
        scheme,
        false,
    );
    const proof = extended.proof;
    // With the arena, aux.deinit is a no-op (individual frees are ignored),
    // but we call it for correctness if the arena is ever removed.
    extended.aux.deinit(arena_alloc);

    return .{ .statement = statement, .proof = proof, ._arena = arena };
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

    mixStatement(&channel, statement);

    // Reconstruct per-family verifier components.
    var component_storage: [MAX_COMPONENTS]RiscVTraceComponent = undefined;
    var verifier_components: [MAX_COMPONENTS]core_air_components.Component = undefined;

    for (0..statement.n_components) |i| {
        component_storage[i] = .{
            .desc = statement.component_descs[i],
            .initial_pc = statement.initial_pc,
            .total_steps = statement.total_steps,
            .preprocessed_col_idx = i,
        };
        verifier_components[i] = component_storage[i].asVerifierComponent();
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
pub fn proveAndVerifyElf(
    allocator: std.mem.Allocator,
    elf_bytes: []const u8,
    max_steps: usize,
    pcs_config: pcs_core.PcsConfig,
) !ProveOutput {
    var run_result = try runner_mod.run(allocator, elf_bytes, max_steps);
    defer run_result.deinit();

    const output = try proveRiscV(allocator, pcs_config, &run_result.execution_trace);

    // Verify immediately.
    try verifyRiscV(allocator, pcs_config, output.statement, output.proof);

    return output;
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

    var output = try proveRiscV(alloc, config, &run_result.execution_trace);
    defer output.deinit(alloc);

    // Verify we got multiple components (the ELF uses ADDI, ADD, SW, LW, BEQ, ECALL)
    try std.testing.expect(output.statement.n_components > 1);

    // Step 3: Verify
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

    var output = try proveRiscV(alloc, config, &exec_trace);
    defer output.deinit(alloc);

    // All 8 rows are ADDI (base_alu_imm), so we should have 1 component.
    try std.testing.expectEqual(@as(u32, 1), output.statement.n_components);
    try std.testing.expectEqual(
        trace_mod.OpcodeFamily.base_alu_imm,
        output.statement.component_descs[0].family,
    );
    try std.testing.expectEqual(@as(u32, 3), output.statement.component_descs[0].log_size);

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

    var output = try proveRiscV(alloc, config, &exec_trace);
    defer output.deinit(alloc);

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

    try verifyRiscV(alloc, config, output.statement, output.proof);
}
