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
    var output = try riscv_cpu.proveRiscV(
        allocator,
        config,
        &run_result.execution_trace,
        &run_result.state_chain_tracker,
        &run_result.rw_memory,
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

/// Recognizes and structurally validates the staged artifact before refusing
/// cryptographic acceptance. This prevents malformed or provenance-drifted
/// envelopes from being mislabeled as merely pending the release gate.
pub fn verifyArtifact(allocator: std.mem.Allocator, path: []const u8) !void {
    try stwo.interop.riscv_artifact.validatePath(allocator, path);
    return error.AdapterNotReleaseGated;
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
