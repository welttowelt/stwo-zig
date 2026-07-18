//! Stark-V RV32IM ELF adapter seam behind the production proof CLI.
//!
//! The adapter is deliberately fail-closed: `proveElf` is the one call site
//! the CLI routes `--elf` runs through, and it returns
//! `error.AdapterNotReleaseGated` until the RV32IM AIR and public I/O binding
//! pass the release gate. Wiring the real prover is a one-function change
//! here; the registry entry in `registry.zig` flips only at that moment.

const std = @import("std");
const stwo = @import("stwo");
const cli = @import("cli.zig");

pub const AdapterError = error{AdapterNotReleaseGated};

pub const PENDING_DIAGNOSTIC =
    "stark-v adapter: pending release gate (opcode, memory, and public I/O AIR constraints are incomplete)";

pub const Benchmark = struct {
    warmups: usize,
    samples: usize,
    profiled: bool,
};

pub const Mode = union(enum) {
    prove,
    bench: Benchmark,
};

pub const Options = struct {
    backend: cli.Backend,
    protocol: cli.Protocol,
    blake2_backend: cli.Blake2Backend,
    metal_runtime: cli.MetalRuntime,
    mode: Mode,
    /// Sibling temporary path owned and published by the CLI transaction.
    proof_temporary: ?[]const u8,
    /// Final path recorded in the report; the adapter never publishes it.
    proof_report_path: ?[]const u8,
};

/// Runs the staged ELF adapter and returns an owned machine-readable report.
///
/// Keeping publication outside the adapter gives Native and RISC-V workloads
/// identical exclusive-output and rollback behavior when the release gate is
/// eventually opened.
pub fn run(
    allocator: std.mem.Allocator,
    elf_path: []const u8,
    input_path: ?[]const u8,
    options: Options,
) ![]u8 {
    // Staged scope: CPU proving of the prove transaction only. Bench stays
    // gated until promoted sampling semantics are defined, and device
    // backends stay Native-only until the release gate opens.
    if (options.mode != .prove) return error.AdapterNotReleaseGated;
    if (options.backend != .cpu) return error.AdapterNotReleaseGated;
    const proof_temporary = options.proof_temporary orelse return error.AdapterNotReleaseGated;

    const runner = stwo.frontends.riscv.runner;
    const prover = stwo.frontends.riscv.prover_mod;
    const riscv_cpu = stwo.integrations.riscv_cpu;
    const artifact_mod = stwo.interop.riscv_artifact;

    const elf_bytes = try std.fs.cwd().readFileAlloc(allocator, elf_path, 64 * 1024 * 1024);
    defer allocator.free(elf_bytes);
    var elf_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(elf_bytes, &elf_digest, .{});

    const input_bytes: []const u8 = if (input_path) |path|
        try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024)
    else
        &.{};
    defer if (input_path != null) allocator.free(@constCast(input_bytes));
    var input_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(input_bytes, &input_digest, .{});

    var run_result = if (input_path != null)
        try runner.runWithInput(allocator, elf_bytes, input_bytes, 10_000_000)
    else
        try runner.run(allocator, elf_bytes, 10_000_000);
    defer run_result.deinit();

    const config = stagedPcsConfig(options.protocol);
    const pd_mod = stwo.frontends.riscv.air.public_data;
    const input_words = try pd_mod.packInputWords(allocator, run_result.input);
    defer allocator.free(input_words);
    const out_words = try allocator.alloc(pd_mod.OutputWord, run_result.output_words.len);
    defer allocator.free(out_words);
    for (run_result.output_words, 0..) |word, i| out_words[i] = .{
        .addr = word.addr,
        .value = word.value,
        .clock = word.clock,
    };
    var output = try riscv_cpu.proveRiscVWithPublicData(
        allocator,
        config,
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
                .input_words = input_words,
                .output_len = run_result.output_len,
                .output_len_addr = run_result.output_len_addr,
                .output_data_addr = run_result.output_data_addr,
                .output_words = out_words,
            },
        },
    );

    // Serialize the proof FIRST: verification consumes ownership of it.
    var proof_bytes: std.ArrayList(u8) = .{};
    defer proof_bytes.deinit(allocator);
    try stwo.interop.postcard.serializeProof(
        prover.Hasher,
        proof_bytes.writer(allocator),
        output.proof,
    );

    // Independent in-process verification BEFORE anything is written.
    try riscv_cpu.verifyRiscV(
        allocator,
        config,
        output.statement,
        output.proof,
        output.interaction_claim,
    );
    const proof_hex = try allocator.alloc(u8, proof_bytes.items.len * 2);
    defer allocator.free(proof_hex);
    for (proof_bytes.items, 0..) |byte, i| {
        _ = std.fmt.bufPrint(proof_hex[i * 2 ..][0..2], "{x:0>2}", .{byte}) catch unreachable;
    }

    var wires = try WireArena.init(allocator, &output);
    defer wires.deinit(allocator);

    try artifact_mod.writeArtifact(allocator, proof_temporary, .{
        .schema_version = artifact_mod.SCHEMA_VERSION,
        .exchange_mode = artifact_mod.EXCHANGE_MODE,
        .release_status = artifact_mod.RELEASE_STATUS,
        .generator = artifact_mod.GENERATOR,
        .air = artifact_mod.AIR,
        .backend = "cpu",
        .protocol = @tagName(options.protocol),
        .source = .{
            .elf_sha256 = &std.fmt.bytesToHex(elf_digest, .lower),
            .input_sha256 = &std.fmt.bytesToHex(input_digest, .lower),
        },
        .provenance = .{
            .oracle_repository = artifact_mod.ORACLE_REPOSITORY,
            .oracle_commit = artifact_mod.ORACLE_COMMIT,
            .implementation_repository = artifact_mod.IMPLEMENTATION_REPOSITORY,
        },
        .pcs_config = .{
            .pow_bits = config.pow_bits,
            .fri_config = .{
                .log_blowup_factor = config.fri_config.log_blowup_factor,
                .log_last_layer_degree_bound = config.fri_config.log_last_layer_degree_bound,
                .n_queries = config.fri_config.n_queries,
            },
        },
        .statement = wires.statement,
        .interaction_claim = wires.claim,
        .proof_bytes_hex = proof_hex,
    });

    return std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"riscv-staged-report-v1\",\"release_status\":\"{s}\"," ++
            "\"verified_in_process\":true,\"total_steps\":{d},\"n_components\":{d}," ++
            "\"proof_path\":\"{s}\"}}",
        .{
            artifact_mod.RELEASE_STATUS,
            output.statement.total_steps,
            output.statement.n_components,
            options.proof_report_path orelse proof_temporary,
        },
    );
}

fn stagedPcsConfig(protocol: cli.Protocol) stwo.core.pcs.PcsConfig {
    return switch (protocol) {
        .secure => .{
            .pow_bits = 24,
            .fri_config = .{
                .log_blowup_factor = 1,
                .log_last_layer_degree_bound = 0,
                .n_queries = 70,
            },
        },
        .functional => .{
            .pow_bits = 10,
            .fri_config = .{
                .log_blowup_factor = 1,
                .log_last_layer_degree_bound = 0,
                .n_queries = 3,
            },
        },
        .smoke => .{
            .pow_bits = 0,
            .fri_config = .{
                .log_blowup_factor = 1,
                .log_last_layer_degree_bound = 0,
                .n_queries = 2,
            },
        },
    };
}

/// Owned wire projections of the statement and claim for artifact assembly.
const WireArena = struct {
    statement: stwo.interop.riscv_artifact.StatementWire,
    claim: stwo.interop.riscv_artifact.InteractionClaimWire,
    components: []stwo.interop.riscv_artifact.ComponentWire,
    infrastructure: []stwo.interop.riscv_artifact.InfraComponentWire,
    input_words: []u32,
    output_words: []stwo.interop.riscv_artifact.OutputWordWire,
    state_claims: []stwo.interop.riscv_artifact.Qm31Wire,
    program_claims: []stwo.interop.riscv_artifact.Qm31Wire,
    opcode_memory: []stwo.interop.riscv_artifact.OpcodeMemoryClaimsWire,
    memory_claims: []stwo.interop.riscv_artifact.MemoryClaimsWire,

    fn qm31Wire(value: anytype) stwo.interop.riscv_artifact.Qm31Wire {
        const limbs = value.toM31Array();
        return .{ limbs[0].v, limbs[1].v, limbs[2].v, limbs[3].v };
    }

    fn init(allocator: std.mem.Allocator, output: anytype) !WireArena {
        const statement = output.statement;
        const claim = output.interaction_claim;
        const n = statement.n_components;
        const n_infra = statement.n_infra;

        var self: WireArena = undefined;
        self.components = try allocator.alloc(
            stwo.interop.riscv_artifact.ComponentWire,
            n,
        );
        for (self.components, 0..) |*wire, i| {
            const desc = statement.component_descs[i];
            wire.* = .{
                .family = @intFromEnum(desc.family),
                .log_size = desc.log_size,
                .n_rows = @intCast(desc.n_rows),
                .n_columns = desc.n_columns,
            };
        }
        self.infrastructure = try allocator.alloc(
            stwo.interop.riscv_artifact.InfraComponentWire,
            n_infra,
        );
        for (self.infrastructure, 0..) |*wire, i| {
            const desc = statement.infra_descs[i];
            wire.* = .{
                .kind = @intFromEnum(desc.kind),
                .log_size = desc.log_size,
                .n_rows = @intCast(desc.n_rows),
                .n_columns = desc.n_columns,
            };
        }
        const io = statement.public_data.io_entries;
        self.input_words = try allocator.dupe(u32, io.input_words);
        self.output_words = try allocator.alloc(
            stwo.interop.riscv_artifact.OutputWordWire,
            io.output_words.len,
        );
        for (self.output_words, io.output_words) |*wire, word| {
            wire.* = .{ .addr = word.addr, .value = word.value, .clock = word.clock };
        }
        self.state_claims = try allocator.alloc(stwo.interop.riscv_artifact.Qm31Wire, n);
        self.program_claims = try allocator.alloc(stwo.interop.riscv_artifact.Qm31Wire, n);
        self.opcode_memory = try allocator.alloc(
            stwo.interop.riscv_artifact.OpcodeMemoryClaimsWire,
            n,
        );
        for (0..n) |i| {
            self.state_claims[i] = qm31Wire(claim.state_claims[i]);
            self.program_claims[i] = qm31Wire(claim.prog_claims[i]);
            for (claim.opcode_memory_claims[i], 0..) |value, j| {
                self.opcode_memory[i][j] = qm31Wire(value);
            }
        }
        self.memory_claims = try allocator.alloc(
            stwo.interop.riscv_artifact.MemoryClaimsWire,
            n_infra,
        );
        for (0..n_infra) |i| {
            for (claim.memory_claims[i], 0..) |value, j| {
                self.memory_claims[i][j] = qm31Wire(value);
            }
        }
        self.statement = .{
            .initial_pc = statement.initial_pc,
            .final_pc = statement.final_pc,
            .total_steps = statement.total_steps,
            .components = self.components,
            .infrastructure = self.infrastructure,
            .public_data = .{
                .initial_pc = statement.public_data.initial_pc,
                .final_pc = statement.public_data.final_pc,
                .clock = statement.public_data.clock,
                .initial_regs = statement.public_data.initial_regs,
                .final_regs = statement.public_data.final_regs,
                .reg_last_clock = statement.public_data.reg_last_clock,
                .program_root = statement.public_data.program_root,
                .initial_rw_root = statement.public_data.initial_rw_root,
                .final_rw_root = statement.public_data.final_rw_root,
                .input_start = io.input_start,
                .input_len = io.input_len,
                .input_words = self.input_words,
                .output_len = io.output_len,
                .output_len_addr = io.output_len_addr,
                .output_data_addr = io.output_data_addr,
                .output_words = self.output_words,
            },
        };
        self.claim = .{
            .interaction_pow = claim.interaction_pow,
            .state_claims = self.state_claims,
            .program_claims = self.program_claims,
            .opcode_memory_claims = self.opcode_memory,
            .rom_claim = qm31Wire(claim.rom_claim),
            .memory_claims = self.memory_claims,
        };
        return self;
    }

    fn deinit(self: *WireArena, allocator: std.mem.Allocator) void {
        allocator.free(self.components);
        allocator.free(self.infrastructure);
        allocator.free(self.input_words);
        allocator.free(self.output_words);
        allocator.free(self.state_claims);
        allocator.free(self.program_claims);
        allocator.free(self.opcode_memory);
        allocator.free(self.memory_claims);
        self.* = undefined;
    }
};

/// Cryptographically verifies a staged artifact: structural validation,
/// statement/claim/proof reconstruction from the wire, then the full
/// verifier including global LogUp cancellation. Acceptance is reported
/// with the artifact's own release status so staged verification can never
/// be mistaken for promotion.
pub fn verifyArtifact(allocator: std.mem.Allocator, path: []const u8) !void {
    const artifact_mod = stwo.interop.riscv_artifact;
    const prover = stwo.frontends.riscv.prover_mod;
    const riscv_cpu = stwo.integrations.riscv_cpu;

    var parsed = try artifact_mod.readArtifact(allocator, path);
    defer parsed.deinit();
    const artifact = parsed.value;
    try artifact_mod.validate(artifact);

    const wire_statement = artifact.statement;
    if (wire_statement.components.len > prover.MAX_COMPONENTS or
        wire_statement.infrastructure.len > prover.MAX_INFRA_COMPONENTS)
        return error.InvalidArtifact;

    var statement: prover.RiscVStatement = undefined;
    statement.n_components = @intCast(wire_statement.components.len);
    statement.n_infra = @intCast(wire_statement.infrastructure.len);
    statement.initial_pc = wire_statement.initial_pc;
    statement.final_pc = wire_statement.final_pc;
    statement.total_steps = wire_statement.total_steps;
    for (wire_statement.components, 0..) |wire, i| {
        statement.component_descs[i] = .{
            .family = std.meta.intToEnum(
                @TypeOf(statement.component_descs[0].family),
                wire.family,
            ) catch return error.InvalidArtifact,
            .log_size = wire.log_size,
            .n_rows = wire.n_rows,
            .n_columns = wire.n_columns,
        };
    }
    for (wire_statement.infrastructure, 0..) |wire, i| {
        statement.infra_descs[i] = .{
            .kind = std.meta.intToEnum(
                @TypeOf(statement.infra_descs[0].kind),
                wire.kind,
            ) catch return error.InvalidArtifact,
            .log_size = wire.log_size,
            .n_rows = wire.n_rows,
            .n_columns = wire.n_columns,
        };
    }

    const wire_public = wire_statement.public_data;
    const output_words = try allocator.alloc(
        @TypeOf(statement.public_data.io_entries.output_words[0]),
        wire_public.output_words.len,
    );
    defer allocator.free(output_words);
    for (output_words, wire_public.output_words) |*word, wire| {
        word.* = .{ .addr = wire.addr, .value = wire.value, .clock = wire.clock };
    }
    statement.public_data = .{
        .initial_pc = wire_public.initial_pc,
        .final_pc = wire_public.final_pc,
        .clock = wire_public.clock,
        .initial_regs = wire_public.initial_regs,
        .final_regs = wire_public.final_regs,
        .reg_last_clock = wire_public.reg_last_clock,
        .program_root = wire_public.program_root,
        .initial_rw_root = wire_public.initial_rw_root,
        .final_rw_root = wire_public.final_rw_root,
        .io_entries = .{
            .input_start = wire_public.input_start,
            .input_len = wire_public.input_len,
            .input_words = wire_public.input_words,
            .output_len = wire_public.output_len,
            .output_len_addr = wire_public.output_len_addr,
            .output_data_addr = wire_public.output_data_addr,
            .output_words = output_words,
        },
    };

    const wire_claim = artifact.interaction_claim;
    if (wire_claim.state_claims.len != statement.n_components or
        wire_claim.program_claims.len != statement.n_components or
        wire_claim.opcode_memory_claims.len != statement.n_components or
        wire_claim.memory_claims.len != statement.n_infra)
        return error.InvalidArtifact;
    var claim = prover.RiscVInteractionClaim.initZero();
    claim.n_components = statement.n_components;
    claim.interaction_pow = wire_claim.interaction_pow;
    claim.rom_claim = qm31FromWire(wire_claim.rom_claim);
    for (0..statement.n_components) |i| {
        claim.state_claims[i] = qm31FromWire(wire_claim.state_claims[i]);
        claim.prog_claims[i] = qm31FromWire(wire_claim.program_claims[i]);
        for (wire_claim.opcode_memory_claims[i], 0..) |value, j| {
            claim.opcode_memory_claims[i][j] = qm31FromWire(value);
        }
    }
    for (0..statement.n_infra) |i| {
        for (wire_claim.memory_claims[i], 0..) |value, j| {
            claim.memory_claims[i][j] = qm31FromWire(value);
        }
    }

    if (artifact.proof_bytes_hex.len % 2 != 0) return error.InvalidArtifact;
    const proof_raw = try allocator.alloc(u8, artifact.proof_bytes_hex.len / 2);
    defer allocator.free(proof_raw);
    _ = std.fmt.hexToBytes(proof_raw, artifact.proof_bytes_hex) catch
        return error.InvalidArtifact;
    var stream = std.io.fixedBufferStream(proof_raw);
    const proof = try stwo.interop.postcard.deserializeProof(
        prover.Hasher,
        allocator,
        stream.reader(),
    );

    const config = @TypeOf(stagedPcsConfig(.secure)){
        .pow_bits = artifact.pcs_config.pow_bits,
        .fri_config = .{
            .log_blowup_factor = artifact.pcs_config.fri_config.log_blowup_factor,
            .log_last_layer_degree_bound = artifact.pcs_config.fri_config.log_last_layer_degree_bound,
            .n_queries = artifact.pcs_config.fri_config.n_queries,
        },
    };
    try riscv_cpu.verifyRiscV(allocator, config, statement, proof, claim);

    try writeVerifyLine(artifact.release_status);
}

fn qm31FromWire(wire: stwo.interop.riscv_artifact.Qm31Wire) stwo.core.fields.qm31.QM31 {
    return stwo.core.fields.qm31.QM31.fromU32Unchecked(wire[0], wire[1], wire[2], wire[3]);
}

fn writeVerifyLine(release_status: []const u8) !void {
    var buffer: [128]u8 = undefined;
    const line = try std.fmt.bufPrint(
        &buffer,
        "riscv artifact: proof VERIFIED (status: {s})\n",
        .{release_status},
    );
    try std.fs.File.stdout().writeAll(line);
}

test "adapter preserves the complete sampled benchmark contract while gated" {
    const options = Options{
        .backend = .cpu,
        .protocol = .functional,
        .blake2_backend = .simd,
        .metal_runtime = .{},
        .mode = .{ .bench = .{ .warmups = 3, .samples = 7, .profiled = true } },
        .proof_temporary = "proof.tmp",
        .proof_report_path = "proof.json",
    };
    try std.testing.expectEqual(@as(usize, 3), options.mode.bench.warmups);
    try std.testing.expectEqual(@as(usize, 7), options.mode.bench.samples);
    try std.testing.expect(options.mode.bench.profiled);
    try std.testing.expectError(
        error.AdapterNotReleaseGated,
        run(std.testing.allocator, "guest.elf", "input.bin", options),
    );
}
