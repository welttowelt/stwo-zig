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
const registry = @import("registry.zig");

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
    experimental: bool,
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
    try registry.requireRiscVAdmission(options.experimental);
    if (options.backend != .cpu) return error.AdapterNotReleaseGated;
    return switch (options.mode) {
        .prove => runProve(allocator, elf_path, input_path, options),
        .bench => |benchmark| runBenchmark(
            allocator,
            elf_path,
            input_path,
            options,
            benchmark,
        ),
    };
}

fn runProve(
    allocator: std.mem.Allocator,
    elf_path: []const u8,
    input_path: ?[]const u8,
    options: Options,
) ![]u8 {
    const proof_temporary = options.proof_temporary orelse return error.AdapterNotReleaseGated;
    var total_timer = try std.time.Timer.start();

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

    var execution_timer = try std.time.Timer.start();
    var run_result = if (input_path != null)
        try runner.runWithInput(allocator, elf_bytes, input_bytes, 10_000_000)
    else
        try runner.run(allocator, elf_bytes, 10_000_000);
    defer run_result.deinit();
    const execution_seconds = seconds(execution_timer.read());

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
    var recorder = stwo.prover.stage_profile.Recorder.init(
        allocator,
        @tagName(@import("builtin").mode),
        "stark_v_rv32im",
    );
    defer recorder.deinit();
    var proving_timer = try std.time.Timer.start();
    var output = try riscv_cpu.proveRiscVWithPublicData(
        allocator,
        config,
        &run_result.execution_trace,
        &run_result.state_chain_tracker,
        &run_result.rw_memory,
        &recorder,
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
    const proving_with_witness_seconds = seconds(proving_timer.read());
    var profile = try recorder.snapshot(allocator);
    defer profile.deinit(allocator);
    const witness_seconds = witnessSeconds(profile.stages);
    const proving_seconds = @max(0.0, proving_with_witness_seconds - witness_seconds);
    var proof_owned = true;
    defer if (proof_owned) output.proof.deinit(allocator);

    // Serialize the proof FIRST: verification consumes ownership of it.
    var proof_bytes: std.ArrayList(u8) = .{};
    defer proof_bytes.deinit(allocator);
    try stwo.interop.postcard.serializeProof(
        prover.Hasher,
        proof_bytes.writer(allocator),
        output.proof,
    );

    // Independent in-process verification BEFORE anything is written.
    // The verifier consumes the proof on both success and failure.
    var verification_timer = try std.time.Timer.start();
    proof_owned = false;
    try riscv_cpu.verifyRiscV(
        allocator,
        config,
        output.statement,
        output.proof,
        output.interaction_claim,
    );
    const verification_seconds = seconds(verification_timer.read());
    const proof_hex = try allocator.alloc(u8, proof_bytes.items.len * 2);
    defer allocator.free(proof_hex);
    for (proof_bytes.items, 0..) |byte, i| {
        _ = std.fmt.bufPrint(proof_hex[i * 2 ..][0..2], "{x:0>2}", .{byte}) catch unreachable;
    }

    var wires = try WireArena.init(allocator, &output);
    defer wires.deinit(allocator);
    const statement_digest = artifact_mod.statementDigest(wires.statement);
    const statement_digest_hex = std.fmt.bytesToHex(statement_digest, .lower);

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
            "\"experimental\":{},\"verified_in_process\":true," ++
            "\"total_steps\":{d},\"n_components\":{d}," ++
            "\"execution_seconds\":{d},\"witness_seconds\":{d}," ++
            "\"proving_seconds\":{d},\"verification_seconds\":{d}," ++
            "\"total_seconds\":{d}," ++
            "\"statement_sha256\":\"{s}\",\"proof_path\":\"{s}\"}}",
        .{
            artifact_mod.RELEASE_STATUS,
            options.experimental,
            output.statement.total_steps,
            output.statement.n_components,
            execution_seconds,
            witness_seconds,
            proving_seconds,
            verification_seconds,
            seconds(total_timer.read()),
            &statement_digest_hex,
            options.proof_report_path orelse proof_temporary,
        },
    );
}

fn seconds(nanoseconds: u64) f64 {
    return @as(f64, @floatFromInt(nanoseconds)) / std.time.ns_per_s;
}

fn witnessSeconds(nodes: []const stwo.prover.stage_profile.StageNode) f64 {
    var total: f64 = 0;
    for (nodes) |node| {
        if (std.mem.eql(u8, node.id, "riscv_opcode_trace_generation") or
            std.mem.eql(u8, node.id, "riscv_infrastructure_trace_generation"))
            total += node.seconds;
        if (node.children) |children| total += witnessSeconds(children);
    }
    return total;
}

const ProveReport = struct {
    total_steps: u32,
    n_components: u32,
    execution_seconds: f64,
    witness_seconds: f64,
    proving_seconds: f64,
    verification_seconds: f64,
    total_seconds: f64,
    statement_sha256: []const u8,
};

fn runBenchmark(
    allocator: std.mem.Allocator,
    elf_path: []const u8,
    input_path: ?[]const u8,
    options: Options,
    benchmark: Benchmark,
) ![]u8 {
    const sample_seconds = try allocator.alloc(f64, benchmark.samples);
    defer allocator.free(sample_seconds);
    const run_nonce = std.time.nanoTimestamp();
    var artifact_digest: ?[32]u8 = null;
    var statement_digest: [32]u8 = undefined;
    var total_steps: u32 = 0;
    var n_components: u32 = 0;
    var execution_seconds: f64 = 0;
    var witness_seconds: f64 = 0;
    var proving_seconds: f64 = 0;
    var verification_seconds: f64 = 0;

    const iterations = try std.math.add(usize, benchmark.warmups, benchmark.samples);
    for (0..iterations) |iteration| {
        const is_sample = iteration >= benchmark.warmups;
        const sample_index = iteration -| benchmark.warmups;
        const keep_artifact = is_sample and sample_index + 1 == benchmark.samples and
            options.proof_temporary != null;
        const path = if (keep_artifact)
            try allocator.dupe(u8, options.proof_temporary.?)
        else
            try std.fmt.allocPrint(
                allocator,
                ".stwo-zig-riscv-bench-{d}-{d}.json",
                .{ run_nonce, iteration },
            );
        defer allocator.free(path);
        defer if (!keep_artifact) std.fs.cwd().deleteFile(path) catch {};

        var timer = try std.time.Timer.start();
        const report_raw = try runProve(allocator, elf_path, input_path, .{
            .backend = options.backend,
            .protocol = options.protocol,
            .blake2_backend = options.blake2_backend,
            .metal_runtime = options.metal_runtime,
            .mode = .prove,
            .experimental = options.experimental,
            .proof_temporary = path,
            .proof_report_path = if (keep_artifact) options.proof_report_path else null,
        });
        defer allocator.free(report_raw);
        const elapsed = seconds(timer.read());

        var parsed = try std.json.parseFromSlice(ProveReport, allocator, report_raw, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();
        const report = parsed.value;
        if (report.statement_sha256.len != statement_digest.len * 2)
            return error.InvalidStatementDigest;
        _ = std.fmt.hexToBytes(&statement_digest, report.statement_sha256) catch
            return error.InvalidStatementDigest;
        total_steps = report.total_steps;
        n_components = report.n_components;

        if (is_sample) {
            sample_seconds[sample_index] = elapsed;
            execution_seconds += report.execution_seconds;
            witness_seconds += report.witness_seconds;
            proving_seconds += report.proving_seconds;
            verification_seconds += report.verification_seconds;

            const artifact_bytes = try std.fs.cwd().readFileAlloc(
                allocator,
                path,
                stwo.interop.riscv_artifact.MAX_ARTIFACT_BYTES,
            );
            defer allocator.free(artifact_bytes);
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(artifact_bytes, &digest, .{});
            if (artifact_digest) |expected| {
                if (!std.mem.eql(u8, &expected, &digest))
                    return error.NondeterministicProofArtifact;
            } else {
                artifact_digest = digest;
            }
        }
    }

    const denominator = @as(f64, @floatFromInt(benchmark.samples));
    const sorted = try allocator.dupe(f64, sample_seconds);
    defer allocator.free(sorted);
    std.mem.sort(f64, sorted, {}, std.sort.asc(f64));
    const median_seconds = sorted[sorted.len / 2];
    const statement_hex = std.fmt.bytesToHex(statement_digest, .lower);
    const artifact_hex = std.fmt.bytesToHex(artifact_digest.?, .lower);
    const report = .{
        .schema = "riscv_proof_v1",
        .release_status = stwo.interop.riscv_artifact.RELEASE_STATUS,
        .mode = "bench",
        .experimental = options.experimental,
        .profiled = benchmark.profiled,
        .warmups = benchmark.warmups,
        .samples = benchmark.samples,
        .verified_samples = benchmark.samples,
        .total_steps = total_steps,
        .n_components = n_components,
        .throughput_numerator = "vm_steps",
        .median_seconds = median_seconds,
        .throughput_mhz = @as(f64, @floatFromInt(total_steps)) / median_seconds / 1_000_000.0,
        .mean_execution_seconds = execution_seconds / denominator,
        .mean_witness_seconds = witness_seconds / denominator,
        .mean_proving_seconds = proving_seconds / denominator,
        .mean_verification_seconds = verification_seconds / denominator,
        .sample_seconds = sample_seconds,
        .statement_sha256 = &statement_hex,
        .artifact_sha256 = &artifact_hex,
        .proof_path = options.proof_report_path,
    };
    return std.json.Stringify.valueAlloc(allocator, report, .{});
}

fn stagedPcsConfig(protocol: cli.Protocol) stwo.core.pcs.PcsConfig {
    return switch (protocol) {
        .secure => .{
            .pow_bits = 26,
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
                .n_queries = 3,
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
        errdefer allocator.free(self.components);
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
        errdefer allocator.free(self.infrastructure);
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
        errdefer allocator.free(self.input_words);
        self.output_words = try allocator.alloc(
            stwo.interop.riscv_artifact.OutputWordWire,
            io.output_words.len,
        );
        errdefer allocator.free(self.output_words);
        for (self.output_words, io.output_words) |*wire, word| {
            wire.* = .{ .addr = word.addr, .value = word.value, .clock = word.clock };
        }
        self.state_claims = try allocator.alloc(stwo.interop.riscv_artifact.Qm31Wire, n);
        errdefer allocator.free(self.state_claims);
        self.program_claims = try allocator.alloc(stwo.interop.riscv_artifact.Qm31Wire, n);
        errdefer allocator.free(self.program_claims);
        self.opcode_memory = try allocator.alloc(
            stwo.interop.riscv_artifact.OpcodeMemoryClaimsWire,
            n,
        );
        errdefer allocator.free(self.opcode_memory);
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
        errdefer allocator.free(self.memory_claims);
        for (0..n_infra) |i| {
            self.memory_claims[i] = .{.{ 0, 0, 0, 0 }} ** 4;
            const kind = statement.infra_descs[i].kind;
            for (0..stwo.frontends.riscv.air.statement.nClaimedSumsForInfra(kind)) |sum| {
                self.memory_claims[i][sum] = qm31Wire(try claim.infraClaim(kind, i, sum));
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
            // Reserved by the staged v2 envelope; the exact program component
            // now occupies its descriptor-indexed infrastructure slots.
            .rom_claim = .{ 0, 0, 0, 0 },
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
pub fn verifyArtifact(
    allocator: std.mem.Allocator,
    path: []const u8,
    requested_policy: cli.Protocol,
    expected_statement_digest: [32]u8,
) !void {
    const artifact_mod = stwo.interop.riscv_artifact;
    const prover = stwo.frontends.riscv.prover_mod;
    const riscv_cpu = stwo.integrations.riscv_cpu;

    var parsed = try artifact_mod.readArtifact(allocator, path);
    defer parsed.deinit();
    const artifact = parsed.value;
    try artifact_mod.validateForPolicy(artifact, switch (requested_policy) {
        .secure => .secure,
        .functional => .functional,
        .smoke => .smoke,
    });
    const actual_statement_digest = artifact_mod.statementDigest(artifact.statement);
    if (!std.mem.eql(u8, &expected_statement_digest, &actual_statement_digest))
        return error.StatementDigestMismatch;

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
    claim.n_infra = statement.n_infra;
    claim.interaction_pow = wire_claim.interaction_pow;
    const zero_wire: stwo.interop.riscv_artifact.Qm31Wire = .{ 0, 0, 0, 0 };
    if (!std.mem.eql(u32, &wire_claim.rom_claim, &zero_wire)) return error.InvalidArtifact;
    for (0..statement.n_components) |i| {
        claim.state_claims[i] = qm31FromWire(wire_claim.state_claims[i]);
        claim.prog_claims[i] = qm31FromWire(wire_claim.program_claims[i]);
        for (wire_claim.opcode_memory_claims[i], 0..) |value, j| {
            claim.opcode_memory_claims[i][j] = qm31FromWire(value);
        }
    }
    for (0..statement.n_infra) |i| {
        const kind = statement.infra_descs[i].kind;
        const n_sums = stwo.frontends.riscv.air.statement.nClaimedSumsForInfra(kind);
        for (wire_claim.memory_claims[i][0..n_sums], 0..) |value, sum| {
            try claim.setInfraClaim(kind, i, sum, qm31FromWire(value));
        }
        for (wire_claim.memory_claims[i][n_sums..]) |padding| {
            if (!std.mem.eql(u32, &padding, &zero_wire)) return error.InvalidArtifact;
        }
    }

    if (artifact.proof_bytes_hex.len % 2 != 0) return error.InvalidArtifact;
    const proof_raw = try allocator.alloc(u8, artifact.proof_bytes_hex.len / 2);
    defer allocator.free(proof_raw);
    _ = std.fmt.hexToBytes(proof_raw, artifact.proof_bytes_hex) catch
        return error.InvalidArtifact;
    var stream = std.io.fixedBufferStream(proof_raw);
    var proof = try stwo.interop.postcard.deserializeProof(
        prover.Hasher,
        allocator,
        stream.reader(),
    );
    if (stream.pos != proof_raw.len) {
        proof.deinit(allocator);
        return error.InvalidArtifact;
    }

    const config = @TypeOf(stagedPcsConfig(.secure)){
        .pow_bits = artifact.pcs_config.pow_bits,
        .fri_config = .{
            .log_blowup_factor = artifact.pcs_config.fri_config.log_blowup_factor,
            .log_last_layer_degree_bound = artifact.pcs_config.fri_config.log_last_layer_degree_bound,
            .n_queries = artifact.pcs_config.fri_config.n_queries,
        },
    };
    if (!pcsConfigsEqual(config, proof.commitment_scheme_proof.config)) {
        proof.deinit(allocator);
        return error.ProofConfigMismatch;
    }
    try riscv_cpu.verifyRiscV(allocator, config, statement, proof, claim);

    try writeVerifyLine(artifact.release_status, actual_statement_digest);
}

fn pcsConfigsEqual(expected: anytype, actual: @TypeOf(expected)) bool {
    return expected.pow_bits == actual.pow_bits and
        expected.fri_config.log_blowup_factor == actual.fri_config.log_blowup_factor and
        expected.fri_config.log_last_layer_degree_bound == actual.fri_config.log_last_layer_degree_bound and
        expected.fri_config.n_queries == actual.fri_config.n_queries and
        expected.fri_config.fold_step == actual.fri_config.fold_step and
        expected.lifting_log_size == actual.lifting_log_size;
}

fn qm31FromWire(wire: stwo.interop.riscv_artifact.Qm31Wire) stwo.core.fields.qm31.QM31 {
    return stwo.core.fields.qm31.QM31.fromU32Unchecked(wire[0], wire[1], wire[2], wire[3]);
}

fn writeVerifyLine(release_status: []const u8, statement_digest: [32]u8) !void {
    var buffer: [256]u8 = undefined;
    const digest_hex = std.fmt.bytesToHex(statement_digest, .lower);
    const line = try std.fmt.bufPrint(
        &buffer,
        "riscv artifact: proof VERIFIED (status: {s}, statement: {s})\n",
        .{ release_status, &digest_hex },
    );
    try std.fs.File.stdout().writeAll(line);
}

test "adapter preserves the complete sampled benchmark contract" {
    const options = Options{
        .backend = .cpu,
        .protocol = .functional,
        .blake2_backend = .simd,
        .metal_runtime = .{},
        .mode = .{ .bench = .{ .warmups = 3, .samples = 7, .profiled = true } },
        .experimental = !registry.RISCV_ADAPTER_RELEASE_GATED,
        .proof_temporary = "proof.tmp",
        .proof_report_path = "proof.json",
    };
    try std.testing.expectEqual(@as(usize, 3), options.mode.bench.warmups);
    try std.testing.expectEqual(@as(usize, 7), options.mode.bench.samples);
    try std.testing.expect(options.mode.bench.profiled);
    try std.testing.expectError(
        error.FileNotFound,
        run(std.testing.allocator, "guest.elf", "input.bin", options),
    );
}

test "adapter PCS profiles satisfy their advertised artifact policies" {
    const cases = [_]struct {
        protocol: cli.Protocol,
        pow_bits: u32,
        n_queries: usize,
    }{
        .{ .protocol = .secure, .pow_bits = 26, .n_queries = 70 },
        .{ .protocol = .functional, .pow_bits = 10, .n_queries = 3 },
        .{ .protocol = .smoke, .pow_bits = 0, .n_queries = 3 },
    };
    for (cases) |case| {
        const config = stagedPcsConfig(case.protocol);
        try std.testing.expectEqual(case.pow_bits, config.pow_bits);
        try std.testing.expectEqual(case.n_queries, config.fri_config.n_queries);
    }
}

test "wire arena rolls back every partial allocation" {
    const prover = stwo.frontends.riscv.prover_mod;
    const public_data = stwo.frontends.riscv.air.public_data;
    const input_words = [_]u32{7};
    const output_words = [_]public_data.OutputWord{.{ .addr = 8, .value = 9, .clock = 10 }};
    var statement: prover.RiscVStatement = .{
        .n_components = 1,
        .component_descs = undefined,
        .initial_pc = 4,
        .final_pc = 8,
        .total_steps = 1,
        .public_data = .{
            .initial_pc = 4,
            .final_pc = 8,
            .clock = 1,
            .initial_regs = .{0} ** 32,
            .final_regs = .{0} ** 32,
            .reg_last_clock = .{0} ** 32,
            .program_root = null,
            .initial_rw_root = null,
            .final_rw_root = null,
            .io_entries = .{
                .input_start = 0,
                .input_len = 4,
                .input_words = &input_words,
                .output_len = 4,
                .output_len_addr = 8,
                .output_data_addr = 12,
                .output_words = &output_words,
            },
        },
        .n_infra = 1,
        .infra_descs = undefined,
    };
    statement.component_descs[0] = .{
        .family = .base_alu_imm,
        .log_size = 1,
        .n_rows = 1,
        .n_columns = 4,
    };
    statement.infra_descs[0] = .{
        .kind = .program,
        .log_size = 1,
        .n_rows = 1,
        .n_columns = 4,
    };
    var claim = prover.RiscVInteractionClaim.initZero();
    claim.n_components = 1;
    const output = .{ .statement = statement, .interaction_claim = claim };

    for (0..8) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        try std.testing.expectError(
            error.OutOfMemory,
            WireArena.init(failing.allocator(), output),
        );
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}
