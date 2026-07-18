//! CP-12 malicious-witness rejection matrix for the RISC-V verifier.
//!
//! One honest ELF execution is proven once; the proof is serialized through
//! the postcard wire and re-decoded for every adversarial attempt so a single
//! prove backs the whole matrix. An untampered decoded clone must verify,
//! proving that later rejections come from the mutation and not from
//! proof-encoding drift. Every claim family in `RiscVInteractionClaim` and
//! every statement field the public boundary sums depend on is then mutated
//! individually, and `verifyRiscV` must reject each mutation.

const std = @import("std");
const riscv_cpu = @import("../../integrations/riscv_cpu/mod.zig");
const prover = @import("../../frontends/riscv/prover.zig");
const postcard = @import("../../interop/postcard.zig");
const runner_mod = @import("../../frontends/riscv/runner/mod.zig");
const public_data_mod = @import("../../frontends/riscv/air/public_data.zig");
const opcode_entries = @import("../../frontends/riscv/air/lookups/opcode_entries.zig");
const merkle_node = @import("../../frontends/riscv/air/memory_commitment/merkle_node.zig");
const poseidon2_air = @import("../../frontends/riscv/air/memory_commitment/poseidon2_air.zig");
const pcs_core = @import("../../core/pcs/mod.zig");
const qm31 = @import("../../core/fields/qm31.zig");

const QM31 = qm31.QM31;

const TEST_PCS_CONFIG = pcs_core.PcsConfig{
    .pow_bits = 0,
    .fri_config = .{
        .log_blowup_factor = 1,
        .log_last_layer_degree_bound = 0,
        .n_queries = 3,
    },
};

const N_GUEST_INSTS = 6;
const GUEST_ELF_SIZE = 84 + N_GUEST_INSTS * 4;

/// Guest that commits one public output word (42, length 4) then self-halts.
/// Mirrors the end-to-end prover test so the matrix covers opcode components
/// (base_alu_imm, load_store, lui), RW memory, and public output words.
fn buildPublicOutputElf() [GUEST_ELF_SIZE]u8 {
    var elf_buf: [GUEST_ELF_SIZE]u8 = [_]u8{0} ** GUEST_ELF_SIZE;

    // ELF header.
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
    elf_buf[26] = 0x01; // e_entry = 0x10000
    elf_buf[28] = 52; // e_phoff
    elf_buf[40] = 52; // e_ehsize
    elf_buf[42] = 32; // e_phentsize
    elf_buf[44] = 1; // e_phnum

    // Program header at offset 52.
    elf_buf[52] = 1; // p_type = PT_LOAD
    elf_buf[56] = 84; // p_offset
    elf_buf[62] = 0x01; // p_vaddr = 0x10000
    elf_buf[68] = N_GUEST_INSTS * 4; // p_filesz
    elf_buf[72] = N_GUEST_INSTS * 4; // p_memsz

    const instructions = [N_GUEST_INSTS]u32{
        0x001000B7, // LUI x1, 0x100 -- io RW region base
        0x00400113, // ADDI x2, x0, 4 -- output length
        0x0020A223, // SW x2, 4(x1)
        0x02A00193, // ADDI x3, x0, 42 -- output word
        0x0030A423, // SW x3, 8(x1)
        0x0000006F, // JAL x0, 0 -- runner stops before tracing the sentinel
    };
    for (instructions, 0..) |inst_word, i| {
        std.mem.writeInt(u32, elf_buf[84 + i * 4 ..][0..4], inst_word, .little);
    }
    return elf_buf;
}

fn bump(value: QM31) QM31 {
    return value.add(QM31.one());
}

/// One prove, many verify attempts: every attempt decodes a fresh proof from
/// the shared wire bytes because `verifyRiscV` consumes the proof it is given.
const RejectionMatrix = struct {
    allocator: std.mem.Allocator,
    config: pcs_core.PcsConfig,
    proof_bytes: []const u8,
    statement: prover.RiscVStatement,
    claim: prover.RiscVInteractionClaim,
    rejected: usize = 0,

    fn cloneProof(self: *const RejectionMatrix) !prover.Proof {
        var stream = std.io.fixedBufferStream(self.proof_bytes);
        return postcard.deserializeProof(prover.Hasher, self.allocator, stream.reader());
    }

    fn expectRejected(
        self: *RejectionMatrix,
        label: []const u8,
        index: usize,
        sub: usize,
        statement: prover.RiscVStatement,
        claim: prover.RiscVInteractionClaim,
    ) !void {
        const proof = try self.cloneProof();
        const result = riscv_cpu.verifyRiscV(self.allocator, self.config, statement, proof, claim);
        if (!std.meta.isError(result)) {
            std.debug.print("forged {s}[{d}][{d}] was accepted\n", .{ label, index, sub });
            return error.ForgedWitnessAccepted;
        }
        self.rejected += 1;
    }

    fn expectClaimRejected(
        self: *RejectionMatrix,
        label: []const u8,
        index: usize,
        sub: usize,
        claim: prover.RiscVInteractionClaim,
    ) !void {
        try self.expectRejected(label, index, sub, self.statement, claim);
    }

    fn expectStatementRejected(
        self: *RejectionMatrix,
        label: []const u8,
        index: usize,
        statement: prover.RiscVStatement,
    ) !void {
        try self.expectRejected(label, index, 0, statement, self.claim);
    }
};

test "riscv prover: malicious-witness matrix rejects every claim and boundary mutation" {
    const alloc = std.testing.allocator;
    const elf_buf = buildPublicOutputElf();

    var run_result = try runner_mod.run(alloc, &elf_buf, 1000);
    defer run_result.deinit();
    try std.testing.expectEqual(@as(u32, 4), run_result.output_len);
    // The output length word plus one output data word.
    try std.testing.expectEqual(@as(usize, 2), run_result.output_words.len);

    const output_words = try alloc.alloc(public_data_mod.OutputWord, run_result.output_words.len);
    defer alloc.free(output_words);
    for (run_result.output_words, 0..) |word, i| output_words[i] = .{
        .addr = word.addr,
        .value = word.value,
        .clock = word.clock,
    };

    var output = try riscv_cpu.proveRiscVWithPublicData(
        alloc,
        TEST_PCS_CONFIG,
        &run_result.execution_trace,
        &run_result.state_chain_tracker,
        &run_result.rw_memory,
        null,
        .{
            .initial_pc = run_result.initial_pc,
            .final_pc = run_result.final_pc,
            .clock = @intCast(run_result.step_count),
            .initial_regs = run_result.initial_regs,
            .final_regs = run_result.final_regs,
            .reg_last_clock = run_result.state_chain_tracker.reg_last_clk,
            .program_root = null,
            .initial_rw_root = null,
            .final_rw_root = null,
            .io_entries = .{
                .input_start = run_result.input_start,
                .input_len = @intCast(run_result.input.len),
                .input_words = &.{},
                .output_len = run_result.output_len,
                .output_len_addr = run_result.output_len_addr,
                .output_data_addr = run_result.output_data_addr,
                .output_words = output_words,
            },
        },
    );
    defer output.deinit(alloc);

    var proof_bytes: std.ArrayList(u8) = .{};
    defer proof_bytes.deinit(alloc);
    try postcard.serializeProof(prover.Hasher, proof_bytes.writer(alloc), output.proof);

    var matrix = RejectionMatrix{
        .allocator = alloc,
        .config = TEST_PCS_CONFIG,
        .proof_bytes = proof_bytes.items,
        .statement = output.statement,
        .claim = output.interaction_claim,
    };

    // Baseline: an untampered decoded clone must verify, so every rejection
    // below is attributable to its mutation rather than to encoding drift.
    try riscv_cpu.verifyRiscV(
        alloc,
        TEST_PCS_CONFIG,
        matrix.statement,
        try matrix.cloneProof(),
        matrix.claim,
    );

    const n_components: usize = matrix.claim.n_components;
    try std.testing.expect(n_components >= 3);

    // -- Interaction-claim families: per-component LogUp sums. --
    var n_opcode_claims: usize = 0;
    for (0..n_components) |i| {
        const family = matrix.statement.component_descs[i].family;
        n_opcode_claims += opcode_entries.batchCount(family);
        for (0..opcode_entries.batchCount(family)) |j| {
            var claim = matrix.claim;
            claim.opcode_claims[i][j] = bump(claim.opcode_claims[i][j]);
            try matrix.expectClaimRejected("opcode_claims", i, j, claim);
        }
    }

    // -- Interaction-claim families: exact infrastructure sums. --
    for (0..matrix.claim.program_claims[0].len) |j| {
        var claim = matrix.claim;
        claim.program_claims[0][j] = bump(claim.program_claims[0][j]);
        try matrix.expectClaimRejected("program_claims", 0, j, claim);
    }
    var n_memory_infra: usize = 0;
    for (0..matrix.statement.n_infra) |i| {
        if (matrix.statement.infra_descs[i].kind != .memory) continue;
        n_memory_infra += 1;
        for (0..matrix.claim.memory_claims[i].len) |j| {
            var claim = matrix.claim;
            claim.memory_claims[i][j] = bump(claim.memory_claims[i][j]);
            try matrix.expectClaimRejected("memory_claims", i, j, claim);
        }
    }
    try std.testing.expect(n_memory_infra >= 1);
    var n_merkle_infra: usize = 0;
    var n_poseidon_infra: usize = 0;
    var n_clock_infra: usize = 0;
    var n_lookup_infra: usize = 0;
    for (0..matrix.statement.n_infra) |i| {
        switch (matrix.statement.infra_descs[i].kind) {
            .merkle => {
                n_merkle_infra += 1;
                for (0..merkle_node.N_SUMS) |j| {
                    var claim = matrix.claim;
                    claim.merkle_claims[i][j] = bump(claim.merkle_claims[i][j]);
                    try matrix.expectClaimRejected("merkle_claims", i, j, claim);
                }
            },
            .poseidon2 => {
                n_poseidon_infra += 1;
                for (0..poseidon2_air.N_SUMS) |j| {
                    var claim = matrix.claim;
                    claim.poseidon_claims[i][j] = bump(claim.poseidon_claims[i][j]);
                    try matrix.expectClaimRejected("poseidon_claims", i, j, claim);
                }
            },
            .clock_update => {
                n_clock_infra += 1;
                var claim = matrix.claim;
                claim.clock_claims[i] = bump(claim.clock_claims[i]);
                try matrix.expectClaimRejected("clock_claims", i, 0, claim);
            },
            .bitwise,
            .range_check_20,
            .range_check_8_11,
            .range_check_8_8_4,
            .range_check_8_8,
            .range_check_m31,
            => {
                n_lookup_infra += 1;
                var claim = matrix.claim;
                claim.lookup_claims[i] = bump(claim.lookup_claims[i]);
                try matrix.expectClaimRejected("lookup_claims", i, 0, claim);
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 1), n_merkle_infra);
    try std.testing.expectEqual(@as(usize, 1), n_poseidon_infra);
    try std.testing.expectEqual(@as(usize, 1), n_clock_infra);

    // -- Interaction-claim envelope: PoW nonce and component count. --
    {
        var claim = matrix.claim;
        claim.interaction_pow +%= 1;
        try matrix.expectClaimRejected("interaction_pow", 0, 0, claim);
    }
    {
        var claim = matrix.claim;
        claim.n_components += 1;
        try matrix.expectClaimRejected("claim.n_components", 0, 0, claim);
    }
    {
        var claim = matrix.claim;
        claim.n_infra += 1;
        try matrix.expectClaimRejected("claim.n_infra", 0, 0, claim);
    }

    // -- Statement PC/step boundary fields. Lone mutations must fail the
    // statement/public-data consistency check; coordinated mutations survive
    // shape validation and must still fail the transcript or boundary sums. --
    {
        var statement = matrix.statement;
        statement.initial_pc +%= 4;
        try matrix.expectStatementRejected("initial_pc (statement only)", 0, statement);
        statement.public_data.initial_pc = statement.initial_pc;
        try matrix.expectStatementRejected("initial_pc (coordinated)", 0, statement);
    }
    {
        var statement = matrix.statement;
        statement.final_pc +%= 4;
        try matrix.expectStatementRejected("final_pc (statement only)", 0, statement);
        statement.public_data.final_pc = statement.final_pc;
        try matrix.expectStatementRejected("final_pc (coordinated)", 0, statement);
    }
    {
        var statement = matrix.statement;
        statement.total_steps +%= 1;
        try matrix.expectStatementRejected("total_steps (statement only)", 0, statement);
        statement.public_data.clock = statement.total_steps;
        try matrix.expectStatementRejected("total_steps (coordinated)", 0, statement);
    }

    // -- Register boundary clocks feeding the registers-state sum. --
    for (0..matrix.statement.public_data.reg_last_clock.len) |r| {
        var statement = matrix.statement;
        statement.public_data.reg_last_clock[r] +%= 1;
        try matrix.expectStatementRejected("reg_last_clock", r, statement);
    }

    // -- Public output words feeding the memory-access boundary sum. The
    // statement copies share this slice, so mutate in place and restore. --
    for (output_words, 0..) |*word, k| {
        const original = word.*;
        word.value +%= 1;
        try matrix.expectStatementRejected("output word value", k, matrix.statement);
        word.* = original;
        word.clock +%= 1;
        try matrix.expectStatementRejected("output word clock", k, matrix.statement);
        word.* = original;
        word.addr +%= 4;
        try matrix.expectStatementRejected("output word addr", k, matrix.statement);
        word.* = original;
    }
    {
        var statement = matrix.statement;
        statement.public_data.io_entries.output_len +%= 4;
        try matrix.expectStatementRejected("output_len", 0, statement);
    }

    // The matrix is exhaustive over the families above: every attempt must
    // have run and been rejected.
    const expected_rejections = n_opcode_claims +
        matrix.claim.program_claims[0].len + // program claims
        n_memory_infra * 4 + // memory_claims entries
        n_merkle_infra * merkle_node.N_SUMS +
        n_poseidon_infra * poseidon2_air.N_SUMS +
        n_clock_infra +
        n_lookup_infra +
        3 + // interaction_pow, claim.n_components, claim.n_infra
        6 + // initial_pc/final_pc/total_steps, lone and coordinated
        matrix.statement.public_data.reg_last_clock.len + // reg_last_clock entries
        output_words.len * 3 + // output word value/clock/addr
        1; // output_len
    try std.testing.expectEqual(expected_rejections, matrix.rejected);
}
