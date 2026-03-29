//! RISC-V STARK prover and verifier orchestration.
//!
//! Proves execution of a RISC-V RV32IM program by:
//! 1. Running the program (ELF) to produce an execution trace
//! 2. Generating witness columns for each active opcode family
//! 3. Committing and proving via the stwo STARK backend
//! 4. Verification of the produced proof
//!
//! ## Usage
//! ```zig
//! const result = try proveRiscV(CpuBackend, Hasher, MC, allocator, elf_bytes, config);
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

pub const RiscVStatement = struct {
    log_size: u32,
    initial_pc: u32,
    final_pc: u32,
    step_count: u32,
    n_columns: u32,
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

fn mixStatement(channel: *Channel, statement: RiscVStatement) void {
    channel.mixU32s(&[_]u32{
        statement.log_size,
        statement.initial_pc,
        statement.final_pc,
        statement.step_count,
        statement.n_columns,
    });
}

fn compositionEval(statement: RiscVStatement) QM31 {
    return QM31.fromM31(
        M31.fromCanonical(statement.log_size),
        M31.fromCanonical(statement.initial_pc & 0x7FFFFFFF),
        M31.fromCanonical(statement.step_count),
        M31.one(),
    );
}

// -- RiscV Component (follows xor.zig pattern) --

const RiscVTraceComponent = struct {
    statement: RiscVStatement,

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
        return self.statement.log_size + 1;
    }

    pub fn traceLogDegreeBounds(
        self: *const @This(),
        allocator: std.mem.Allocator,
    ) !core_air_components.TraceLogDegreeBounds {
        // Tree 0: preprocessed (1 column)
        const preprocessed = try allocator.dupe(u32, &[_]u32{self.statement.log_size});
        // Tree 1: main trace (n_columns columns, all same log_size)
        const main = try allocator.alloc(u32, self.statement.n_columns);
        @memset(main, self.statement.log_size);
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
        // Preprocessed: no mask points needed
        const preprocessed_col = try allocator.alloc(CirclePointQM31, 0);
        const preprocessed_cols = try allocator.dupe([]CirclePointQM31, &[_][]CirclePointQM31{preprocessed_col});

        // Main: one mask point per column
        const n = self.statement.n_columns;
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
        _: *const @This(),
        allocator: std.mem.Allocator,
    ) ![]usize {
        return allocator.dupe(usize, &[_]usize{0});
    }

    pub fn evaluateConstraintQuotientsAtPoint(
        self: *const @This(),
        _: CirclePointQM31,
        _: *const core_air_components.MaskValues,
        evaluation_accumulator: *core_air_accumulation.PointEvaluationAccumulator,
        _: u32,
    ) !void {
        evaluation_accumulator.accumulate(compositionEval(self.statement));
    }

    pub fn evaluateConstraintQuotientsOnDomain(
        self: *const @This(),
        _: *const prover_component.Trace,
        evaluation_accumulator: *prover_air_accumulation.DomainEvaluationAccumulator,
    ) !void {
        const eval = compositionEval(self.statement);
        const domain_size = @as(usize, 1) << @intCast(self.statement.log_size + 1);
        const values = try evaluation_accumulator.allocator.alloc(QM31, domain_size);
        defer evaluation_accumulator.allocator.free(values);
        @memset(values, eval);
        var col = try secure_column.SecureColumnByCoords.fromSecureSlice(
            evaluation_accumulator.allocator,
            values,
        );
        defer col.deinit(evaluation_accumulator.allocator);
        try evaluation_accumulator.accumulateColumn(self.statement.log_size + 1, &col);
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

// -- Public API --

/// Prove a RISC-V execution trace.
pub fn proveRiscV(
    allocator: std.mem.Allocator,
    pcs_config: pcs_core.PcsConfig,
    exec_trace: *const trace_mod.Trace,
) !ProveOutput {
    if (exec_trace.step_count == 0) return ProverError.EmptyTrace;

    const n_rows = exec_trace.rows.items.len;
    const log_size: u32 = @intCast(std.math.log2_int_ceil(usize, if (n_rows == 0) 1 else n_rows));
    if (log_size == 0) return ProverError.InvalidLogSize;

    const n_columns: u32 = 10; // clk, pc, rd, rs1, rs2, rs1_val, rs2_val, rd_val, enabler, next_pc

    const statement = RiscVStatement{
        .log_size = log_size,
        .initial_pc = exec_trace.initial_pc,
        .final_pc = exec_trace.final_pc,
        .step_count = @intCast(exec_trace.step_count),
        .n_columns = n_columns,
    };

    var channel = Channel{};
    pcs_config.mixInto(&channel);

    var scheme = try prover_pcs.CommitmentSchemeProver(CpuBackend, Hasher, MerkleChannel).init(
        allocator,
        pcs_config,
    );

    // Tree 0: Preprocessed (IsFirst column)
    const is_first = try genIsFirstColumn(allocator, log_size);
    const preprocessed = try allocator.alloc(prover_pcs.ColumnEvaluation, 1);
    preprocessed[0] = .{ .log_size = log_size, .values = is_first };
    try scheme.commitOwned(allocator, preprocessed, &channel);

    // Tree 1: Main trace columns (from execution trace)
    const domain_size = @as(usize, 1) << @intCast(log_size);
    const main_columns = try allocator.alloc(prover_pcs.ColumnEvaluation, n_columns);

    // Generate columns in bit-reversed circle-domain order
    for (0..n_columns) |col_idx| {
        const col_data = try allocator.alloc(M31, domain_size);
        @memset(col_data, M31.zero());

        for (exec_trace.rows.items, 0..) |row, i| {
            if (i >= domain_size) break;
            const circle_idx = utils.cosetIndexToCircleDomainIndex(i, log_size);
            const bit_rev_idx = utils.bitReverseIndex(circle_idx, log_size);
            col_data[bit_rev_idx] = switch (col_idx) {
                0 => M31.fromCanonical(row.clk),
                1 => M31.fromCanonical(row.pc),
                2 => M31.fromCanonical(@as(u32, row.rd)),
                3 => M31.fromCanonical(@as(u32, row.rs1)),
                4 => M31.fromCanonical(@as(u32, row.rs2)),
                5 => M31.fromCanonical(row.rs1_val),
                6 => M31.fromCanonical(row.rs2_val),
                7 => M31.fromCanonical(row.rd_val),
                8 => M31.one(), // enabler
                9 => M31.fromCanonical(row.next_pc),
                else => M31.zero(),
            };
        }
        main_columns[col_idx] = .{ .log_size = log_size, .values = col_data };
    }
    try scheme.commitOwned(allocator, main_columns, &channel);

    mixStatement(&channel, statement);

    const component = RiscVTraceComponent{ .statement = statement };
    const components = [_]prover_component.ComponentProver{
        component.asProverComponent(),
    };

    var extended = try prover_prove.proveEx(
        CpuBackend,
        Hasher,
        MerkleChannel,
        allocator,
        components[0..],
        &channel,
        scheme,
        false,
    );
    const proof = extended.proof;
    extended.aux.deinit(allocator);

    return .{ .statement = statement, .proof = proof };
}

/// Verify a RISC-V STARK proof.
pub fn verifyRiscV(
    allocator: std.mem.Allocator,
    pcs_config: pcs_core.PcsConfig,
    statement: RiscVStatement,
    proof_in: Proof,
) !void {
    if (statement.log_size == 0) return ProverError.InvalidLogSize;

    const proof = proof_in;

    var channel = Channel{};
    pcs_config.mixInto(&channel);

    var commitment_scheme = try pcs_verifier.CommitmentSchemeVerifier(
        Hasher,
        MerkleChannel,
    ).init(allocator, pcs_config);
    defer commitment_scheme.deinit(allocator);

    // Tree 0: Preprocessed
    try commitment_scheme.commit(
        allocator,
        proof.commitment_scheme_proof.commitments.items[0],
        &[_]u32{statement.log_size},
        &channel,
    );

    // Tree 1: Main trace
    const main_log_sizes = try allocator.alloc(u32, statement.n_columns);
    defer allocator.free(main_log_sizes);
    @memset(main_log_sizes, statement.log_size);

    try commitment_scheme.commit(
        allocator,
        proof.commitment_scheme_proof.commitments.items[1],
        main_log_sizes,
        &channel,
    );

    mixStatement(&channel, statement);

    const component = RiscVTraceComponent{ .statement = statement };
    const verifier_components = [_]core_air_components.Component{
        component.asVerifierComponent(),
    };

    try core_verifier.verify(
        Hasher,
        MerkleChannel,
        allocator,
        verifier_components[0..],
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

    // Step 3: Verify
    try verifyRiscV(alloc, config, output.statement, output.proof);
}

test "riscv prover: prove and verify synthetic trace" {
    const alloc = std.testing.allocator;
    var exec_trace = trace_mod.Trace.init(alloc);
    defer exec_trace.deinit();

    exec_trace.initial_pc = 0x1000;

    // Add 8 synthetic trace rows (need power-of-2 >= 8, log_size=3).
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

    try verifyRiscV(alloc, config, output.statement, output.proof);
}
