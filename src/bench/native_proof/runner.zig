const std = @import("std");
const builtin = @import("builtin");
const stwo = @import("stwo");
const config = @import("config.zig");
const examples = @import("examples.zig");
const report_mod = @import("report.zig");
const statistics = @import("statistics.zig");

const examples_artifact = stwo.interop.examples_artifact;
const proof_wire = stwo.interop.proof_wire;
const stage_profile = stwo.prover.stage_profile;
const M31_PACK_WIDTH = stwo.core.fields.m31.PACK_WIDTH;
const HOST_TWIDDLE_BUDGET_BYTES: usize = 256 * 1024 * 1024;

const OVERRIDE_NAMES = [_][]const u8{
    "STWO_ZIG_WORKERS",
    "STWO_ZIG_POW_WORKERS",
    "STWO_ZIG_MERKLE_WORKERS",
    "STWO_ZIG_LEAF_BATCH_SIZE",
    "STWO_ZIG_MERKLE_POOL_REUSE",
    "STWO_ZIG_METAL_RADIX4_RFFT",
};

const SampleOutcome = struct {
    timing: report_mod.Sample,
    canonical_proof: []u8,
    stage_profile: ?report_mod.StageProfile,

    fn deinit(self: *SampleOutcome, allocator: std.mem.Allocator) void {
        allocator.free(self.canonical_proof);
        if (self.stage_profile) |*profile| profile.deinit(allocator);
        self.* = undefined;
    }
};

const GatedSampleOutcome = struct {
    sample: SampleOutcome,
    telemetry: ?report_mod.BackendTelemetryDelta,
};

const OwnedProvenance = struct {
    git_commit: []u8,
    environment_overrides: []report_mod.EnvironmentOverride,

    fn deinit(self: *OwnedProvenance, allocator: std.mem.Allocator) void {
        allocator.free(self.git_commit);
        for (self.environment_overrides) |entry| allocator.free(entry.value);
        allocator.free(self.environment_overrides);
        self.* = undefined;
    }
};

pub fn main(comptime Engine: type, comptime backend: config.Backend) !void {
    const allocator = std.heap.smp_allocator;
    const process_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, process_args);

    const parsed = parse: {
        const result = config.parseArgs(process_args[1..]) catch |err| {
            try config.writeUsage(std.fs.File.stderr().deprecatedWriter());
            return err;
        };
        break :parse result;
    };
    switch (parsed) {
        .help => return config.writeUsage(std.fs.File.stdout().deprecatedWriter()),
        .run => |args| try execute(Engine, backend, allocator, args),
    }
}

fn execute(
    comptime Engine: type,
    comptime backend: config.Backend,
    allocator: std.mem.Allocator,
    args: config.Args,
) !void {
    return switch (args.workload()) {
        .wide_fibonacci => |parameters| executeExample(
            Engine,
            backend,
            examples.WideFibonacciSpec,
            allocator,
            args,
            args.workload(),
            examples.WideFibonacciSpec.request(parameters),
        ),
        .xor => |parameters| executeExample(
            Engine,
            backend,
            examples.XorSpec,
            allocator,
            args,
            args.workload(),
            examples.XorSpec.request(parameters),
        ),
        .plonk => |parameters| executeExample(
            Engine,
            backend,
            examples.PlonkSpec,
            allocator,
            args,
            args.workload(),
            examples.PlonkSpec.request(parameters),
        ),
    };
}

fn executeExample(
    comptime Engine: type,
    comptime backend: config.Backend,
    comptime Spec: type,
    allocator: std.mem.Allocator,
    args: config.Args,
    workload: config.Workload,
    request: Spec.Request,
) !void {
    const protocol_parameters = args.protocol.parameters();
    var fri_config = try stwo.core.fri.FriConfig.init(
        protocol_parameters.log_last_layer_degree_bound,
        protocol_parameters.log_blowup_factor,
        protocol_parameters.n_queries,
    );
    fri_config.fold_step = protocol_parameters.fold_step;
    const pcs_config = stwo.core.pcs.PcsConfig{
        .pow_bits = protocol_parameters.pow_bits,
        .fri_config = fri_config,
    };
    const workload_geometry = try examples.geometry(workload);
    const max_circle_log = try Spec.requiredCircleLog(request, pcs_config);

    var init_timer = try std.time.Timer.start();
    if (comptime @hasDecl(Engine, "warmup")) try Engine.warmup();
    var session = try Engine.initSession(
        allocator,
        pcs_config,
        max_circle_log,
        HOST_TWIDDLE_BUDGET_BYTES,
    );
    defer session.deinit(allocator);
    const session_construction = session.constructionTelemetry();
    const backend_init_seconds = nsToSeconds(init_timer.read());

    const warmup_seconds = try allocator.alloc(f64, args.warmups);
    defer allocator.free(warmup_seconds);
    const warmup_telemetry = try allocator.alloc(
        report_mod.BackendTelemetryDelta,
        if (backend == .metal_hybrid) args.warmups else 0,
    );
    defer allocator.free(warmup_telemetry);
    for (warmup_seconds, 0..) |*elapsed, index| {
        var outcome = try runGatedSample(
            Engine,
            backend,
            Spec,
            &session,
            allocator,
            pcs_config,
            request,
            workload_geometry,
            false,
        );
        defer outcome.sample.deinit(allocator);
        elapsed.* = outcome.sample.timing.request_seconds;
        if (comptime backend == .metal_hybrid) warmup_telemetry[index] = outcome.telemetry.?;
    }
    const post_warmup_pipeline_cache: ?report_mod.PipelineCacheDelta = if (backend == .metal_hybrid) blk: {
        const snapshot = try Engine.telemetrySnapshot();
        break :blk pipelineCacheReport(snapshot.pipeline_cache);
    } else null;

    const samples = try allocator.alloc(report_mod.Sample, args.samples);
    defer allocator.free(samples);
    const input_values = try allocator.alloc(f64, args.samples);
    defer allocator.free(input_values);
    const prove_values = try allocator.alloc(f64, args.samples);
    defer allocator.free(prove_values);
    const encode_values = try allocator.alloc(f64, args.samples);
    defer allocator.free(encode_values);
    const verify_values = try allocator.alloc(f64, args.samples);
    defer allocator.free(verify_values);
    const request_values = try allocator.alloc(f64, args.samples);
    defer allocator.free(request_values);
    const native_rates = try allocator.alloc(f64, args.samples);
    defer allocator.free(native_rates);
    const request_native_rates = try allocator.alloc(f64, args.samples);
    defer allocator.free(request_native_rates);
    const trace_row_rates = try allocator.alloc(f64, args.samples);
    defer allocator.free(trace_row_rates);
    const request_trace_row_rates = try allocator.alloc(f64, args.samples);
    defer allocator.free(request_trace_row_rates);
    const cell_rates = try allocator.alloc(f64, args.samples);
    defer allocator.free(cell_rates);
    const proof_records = try allocator.alloc(report_mod.CanonicalProof, args.samples);
    defer allocator.free(proof_records);
    const proof_digest_hexes = try allocator.alloc([64]u8, args.samples);
    defer allocator.free(proof_digest_hexes);
    const sample_telemetry = try allocator.alloc(
        report_mod.BackendTelemetryDelta,
        if (backend == .metal_hybrid) args.samples else 0,
    );
    defer allocator.free(sample_telemetry);
    const sample_stage_profiles = try allocator.alloc(
        report_mod.StageProfile,
        if (args.profiled) args.samples else 0,
    );
    var initialized_stage_profiles: usize = 0;
    defer {
        for (sample_stage_profiles[0..initialized_stage_profiles]) |*profile| profile.deinit(allocator);
        allocator.free(sample_stage_profiles);
    }

    var canonical_proof: ?[]u8 = null;
    defer if (canonical_proof) |bytes| allocator.free(bytes);
    var all_samples_byte_identical = true;
    for (samples, 0..) |*sample, index| {
        const gated = try runGatedSample(
            Engine,
            backend,
            Spec,
            &session,
            allocator,
            pcs_config,
            request,
            workload_geometry,
            args.profiled,
        );
        var outcome = gated.sample;
        var outcome_owned = true;
        defer {
            if (outcome_owned) allocator.free(outcome.canonical_proof);
            if (outcome.stage_profile) |*profile| profile.deinit(allocator);
        }
        if (comptime backend == .metal_hybrid) sample_telemetry[index] = gated.telemetry.?;
        if (args.profiled) {
            sample_stage_profiles[index] = outcome.stage_profile.?;
            outcome.stage_profile = null;
            initialized_stage_profiles += 1;
        }

        var proof_digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(outcome.canonical_proof, &proof_digest, .{});
        proof_digest_hexes[index] = std.fmt.bytesToHex(proof_digest, .lower);
        proof_records[index] = .{
            .bytes = outcome.canonical_proof.len,
            .sha256 = &proof_digest_hexes[index],
        };
        if (canonical_proof) |expected| {
            all_samples_byte_identical = all_samples_byte_identical and
                std.mem.eql(u8, expected, outcome.canonical_proof);
        } else {
            canonical_proof = outcome.canonical_proof;
            outcome_owned = false;
        }
        sample.* = outcome.timing;
        input_values[index] = sample.input_seconds;
        prove_values[index] = sample.prove_seconds;
        encode_values[index] = sample.proof_encode_seconds;
        verify_values[index] = sample.verify_seconds;
        request_values[index] = sample.request_seconds;
        native_rates[index] = sample.native_mhz;
        request_native_rates[index] = sample.request_native_mhz;
        trace_row_rates[index] = sample.trace_row_mhz;
        request_trace_row_rates[index] = sample.request_trace_row_mhz;
        cell_rates[index] = sample.committed_mcells_per_second;
    }

    const proof_artifact_binding: ?report_mod.ProofArtifactBinding = if (args.proof_artifact_out) |path| blk: {
        try Spec.writeArtifact(allocator, path, pcs_config, request, canonical_proof.?);
        break :blk .{
            .path = path,
            .sample_index = 0,
            .bytes = proof_records[0].bytes,
            .sha256 = proof_records[0].sha256,
            .artifact_schema_version = examples_artifact.SCHEMA_VERSION,
            .upstream_commit = examples_artifact.UPSTREAM_COMMIT,
            .exchange_mode = examples_artifact.EXCHANGE_MODE,
        };
    } else null;

    const workload_digest = examples.descriptorDigest(workload, args.protocol);
    var workload_digest_hex = std.fmt.bytesToHex(workload_digest, .lower);

    var provenance_owned = try collectProvenance(allocator);
    defer provenance_owned.deinit(allocator);
    const dirty_output = try runCommand(allocator, &.{ "git", "status", "--porcelain", "--untracked-files=normal" });
    defer allocator.free(dirty_output);
    const overrides = provenance_owned.environment_overrides;

    const input_summary = try statistics.summarize(allocator, input_values);
    const prove_summary = try statistics.summarize(allocator, prove_values);
    const encode_summary = try statistics.summarize(allocator, encode_values);
    const verify_summary = try statistics.summarize(allocator, verify_values);
    const request_summary = try statistics.summarize(allocator, request_values);
    const native_summary = try statistics.summarize(allocator, native_rates);
    const request_native_summary = try statistics.summarize(allocator, request_native_rates);
    const trace_row_summary = try statistics.summarize(allocator, trace_row_rates);
    const request_trace_row_summary = try statistics.summarize(allocator, request_trace_row_rates);
    const cell_summary = try statistics.summarize(allocator, cell_rates);
    const minimum_samples: usize = if (prove_summary.median < 1.0) 5 else 3;
    const meets_sampling_contract = args.warmups >= config.MIN_HEADLINE_WARMUPS and
        args.samples >= minimum_samples;
    const evidence_class = args.evidenceClass(meets_sampling_contract);
    const git_dirty = dirty_output.len != 0;
    const provenance_complete = true;
    const telemetry_valid = backendTelemetryValid(backend, warmup_telemetry, sample_telemetry);
    const byte_identical_verified_samples =
        args.samples == proof_records.len and all_samples_byte_identical;
    const headline_requirements = report_mod.HeadlineRequirements{
        .verified_unprofiled = evidence_class == .verified_unprofiled,
        .sampling_contract = meets_sampling_contract,
        .functional_protocol = args.protocol == .functional,
        .release_fast = builtin.mode == .ReleaseFast,
        .clean_complete_provenance = provenance_complete and !git_dirty,
        .thread_parallelism_enabled = !builtin.single_threaded,
        .byte_identical_verified_samples = byte_identical_verified_samples,
        .backend_telemetry_valid = telemetry_valid,
    };
    const headline_eligible = headlineRequirementsMet(headline_requirements);
    const telemetry_totals = sumTelemetry(warmup_telemetry, sample_telemetry);

    const report = report_mod.Report{
        .backend = backend,
        .evidence_class = evidence_class,
        .profiled = args.profiled,
        .provenance = .{
            .git_commit = provenance_owned.git_commit,
            .git_dirty = git_dirty,
            .zig_version = builtin.zig_version_string,
            .optimization = @tagName(builtin.mode),
            .target_os = @tagName(builtin.os.tag),
            .target_arch = @tagName(builtin.cpu.arch),
            .cpu_count = try std.Thread.getCpuCount(),
            .simd_pack_width = M31_PACK_WIDTH,
            .single_threaded = builtin.single_threaded,
            .thread_parallelism_enabled = !builtin.single_threaded,
            .environment_overrides = overrides,
            .complete = provenance_complete,
        },
        .protocol = .{
            .name = args.protocol,
            .pow_bits = protocol_parameters.pow_bits,
            .log_blowup_factor = protocol_parameters.log_blowup_factor,
            .log_last_layer_degree_bound = protocol_parameters.log_last_layer_degree_bound,
            .n_queries = protocol_parameters.n_queries,
            .fold_step = protocol_parameters.fold_step,
        },
        .workload = .{
            .name = examples.name(workload),
            .descriptor_sha256 = &workload_digest_hex,
            .parameters = examples.parameters(workload),
            .trace_log_rows = workload_geometry.trace_log_rows,
            .trace_rows = workload_geometry.trace_rows,
            .committed_trees = workload_geometry.committed_trees,
            .committed_columns = workload_geometry.committed_columns,
            .committed_trace_cells = workload_geometry.committed_trace_cells,
            .native_unit = workload_geometry.native_unit,
            .native_units = workload_geometry.native_units,
        },
        .proof = .{
            .samples = proof_records,
            .verified_samples = args.samples,
            .all_samples_byte_identical = all_samples_byte_identical,
            .artifact = proof_artifact_binding,
        },
        .session = .{
            .max_circle_log = max_circle_log,
            .host_byte_budget = HOST_TWIDDLE_BUDGET_BYTES,
            .retained_host_twiddle_bytes = session_construction.retained_twiddle_bytes,
            .tower_build_count = session_construction.tower_build_count,
        },
        .backend_telemetry = if (backend == .metal_hybrid) .{
            .post_warmup_pipeline_cache = post_warmup_pipeline_cache.?,
            .warmups = warmup_telemetry,
            .samples = sample_telemetry,
            .total_metal_dispatches = telemetry_totals.metal_dispatches,
            .total_cpu_fallbacks = telemetry_totals.cpu_fallbacks,
            .valid = telemetry_valid,
        } else null,
        .timing = .{
            .backend_init_seconds = backend_init_seconds,
            .warmup_request_seconds = warmup_seconds,
            .samples = samples,
            .stage_profiles = if (args.profiled) sample_stage_profiles else null,
            .input_seconds = input_summary,
            .prove_seconds = prove_summary,
            .proof_encode_seconds = encode_summary,
            .verify_seconds = verify_summary,
            .request_seconds = request_summary,
        },
        .throughput = .{
            .headline_eligible = headline_eligible,
            .headline_native_mhz = if (headline_eligible) native_summary else null,
            .diagnostic_native_mhz = if (evidence_class == .profiled_diagnostic) native_summary else null,
            .headline_request_native_mhz = if (headline_eligible) request_native_summary else null,
            .diagnostic_request_native_mhz = if (evidence_class == .profiled_diagnostic) request_native_summary else null,
            .headline_trace_row_mhz = if (headline_eligible) trace_row_summary else null,
            .diagnostic_trace_row_mhz = if (evidence_class == .profiled_diagnostic) trace_row_summary else null,
            .headline_request_trace_row_mhz = if (headline_eligible) request_trace_row_summary else null,
            .diagnostic_request_trace_row_mhz = if (evidence_class == .profiled_diagnostic) request_trace_row_summary else null,
            .headline_committed_mcells_per_second = if (headline_eligible) cell_summary else null,
            .diagnostic_committed_mcells_per_second = if (evidence_class == .profiled_diagnostic) cell_summary else null,
            .headline_requirements = headline_requirements,
        },
    };
    const encoded = try report_mod.encodeAlloc(allocator, report);
    defer allocator.free(encoded);
    const stdout = std.fs.File.stdout().deprecatedWriter();
    try stdout.writeAll(encoded);
    try stdout.writeByte('\n');
}

fn runGatedSample(
    comptime Engine: type,
    comptime backend: config.Backend,
    comptime Spec: type,
    session: *const Engine.Session,
    allocator: std.mem.Allocator,
    pcs_config: stwo.core.pcs.PcsConfig,
    request: Spec.Request,
    workload_geometry: examples.Geometry,
    profiled: bool,
) !GatedSampleOutcome {
    if (comptime backend == .metal_hybrid) {
        const before = try Engine.telemetrySnapshot();
        var sample = try runSample(
            Engine,
            Spec,
            session,
            allocator,
            pcs_config,
            request,
            workload_geometry,
            profiled,
        );
        errdefer sample.deinit(allocator);
        const after = try Engine.telemetrySnapshot();
        const delta = after.delta(before);
        try delta.requireMetalDispatch();
        return .{ .sample = sample, .telemetry = telemetryReport(delta) };
    }
    return .{
        .sample = try runSample(
            Engine,
            Spec,
            session,
            allocator,
            pcs_config,
            request,
            workload_geometry,
            profiled,
        ),
        .telemetry = null,
    };
}

fn runSample(
    comptime Engine: type,
    comptime Spec: type,
    session: *const Engine.Session,
    allocator: std.mem.Allocator,
    pcs_config: stwo.core.pcs.PcsConfig,
    request: Spec.Request,
    workload_geometry: examples.Geometry,
    profiled: bool,
) !SampleOutcome {
    var recorder = stage_profile.Recorder.init(allocator, @tagName(builtin.mode), Spec.example_name);
    defer recorder.deinit();

    var request_timer = try std.time.Timer.start();
    var input_timer = try std.time.Timer.start();
    const prepared = try Spec.prepareInput(allocator, request);
    const input_seconds = nsToSeconds(input_timer.read());
    var prepared_owned = true;
    errdefer if (prepared_owned) {
        var owned = prepared;
        owned.deinit(allocator);
    };
    var prove_timer = try std.time.Timer.start();
    prepared_owned = false;
    const output = try Spec.provePrepared(
        Engine,
        session,
        allocator,
        pcs_config,
        prepared,
        if (profiled) &recorder else null,
    );
    const prove_seconds = nsToSeconds(prove_timer.read());
    var proof_owned = true;
    defer if (proof_owned) {
        var proof = output.proof;
        proof.deinit(allocator);
    };

    var encode_timer = try std.time.Timer.start();
    const canonical = try proof_wire.encodeProofBytes(allocator, output.proof);
    errdefer allocator.free(canonical);
    const encode_seconds = nsToSeconds(encode_timer.read());

    var verify_timer = try std.time.Timer.start();
    proof_owned = false;
    try Spec.verify(allocator, pcs_config, output.statement, output.proof);
    const verify_seconds = nsToSeconds(verify_timer.read());
    const request_seconds = nsToSeconds(request_timer.read());
    return .{
        .timing = .{
            .input_seconds = input_seconds,
            .prove_seconds = prove_seconds,
            .proof_encode_seconds = encode_seconds,
            .verify_seconds = verify_seconds,
            .request_seconds = request_seconds,
            .native_mhz = rate(workload_geometry.native_units, prove_seconds),
            .request_native_mhz = rate(workload_geometry.native_units, request_seconds),
            .trace_row_mhz = rate(workload_geometry.trace_rows, prove_seconds),
            .request_trace_row_mhz = rate(workload_geometry.trace_rows, request_seconds),
            .committed_mcells_per_second = rate(workload_geometry.committed_trace_cells, prove_seconds),
        },
        .canonical_proof = canonical,
        .stage_profile = if (profiled) try recorder.snapshot(allocator) else null,
    };
}

fn telemetryReport(delta: anytype) report_mod.BackendTelemetryDelta {
    const counters = delta.counters;
    const pipeline_cache = delta.pipeline_cache;
    return .{
        .classification = @tagName(delta.classification()),
        .metal_dispatches = counters.metalDispatchTotal(),
        .cpu_fallbacks = counters.cpuFallbackTotal(),
        .counters = .{
            .host_merkle_commits = counters.host_merkle_commits,
            .resident_merkle_commits = counters.resident_merkle_commits,
            .metal_quotient_dispatches = counters.metal_quotient_dispatches,
            .metal_sampled_value_dispatches = counters.metal_sampled_value_dispatches,
            .metal_circle_transform_dispatches = counters.metal_circle_transform_dispatches,
            .metal_circle_lde_dispatches = counters.metal_circle_lde_dispatches,
            .metal_fri_circle_fold_dispatches = counters.metal_fri_circle_fold_dispatches,
            .metal_fri_line_fold_dispatches = counters.metal_fri_line_fold_dispatches,
            .metal_qm31_coordinate_dispatches = counters.metal_qm31_coordinate_dispatches,
            .cpu_small_merkle_commits = counters.cpu_small_merkle_commits,
            .cpu_streaming_merkle_commits = counters.cpu_streaming_merkle_commits,
            .cpu_sampled_value_evaluations = counters.cpu_sampled_value_evaluations,
            .cpu_small_circle_interpolations = counters.cpu_small_circle_interpolations,
            .cpu_small_circle_evaluations = counters.cpu_small_circle_evaluations,
            .cpu_small_circle_ldes = counters.cpu_small_circle_ldes,
        },
        .pipeline_cache = pipelineCacheReport(pipeline_cache),
    };
}

fn pipelineCacheReport(stats: anytype) report_mod.PipelineCacheDelta {
    return .{
        .library_cache_hits = stats.library_cache_hits,
        .library_cache_misses = stats.library_cache_misses,
        .pipeline_cache_hits = stats.pipeline_cache_hits,
        .binary_archive_hits = stats.binary_archive_hits,
        .binary_archive_misses = stats.binary_archive_misses,
        .direct_compiles = stats.direct_compiles,
        .archive_populations = stats.archive_populations,
        .archive_serializations = stats.archive_serializations,
        .pipeline_preparation_seconds = stats.pipeline_preparation_seconds,
    };
}

fn backendTelemetryValid(
    comptime backend: config.Backend,
    warmups: []const report_mod.BackendTelemetryDelta,
    samples: []const report_mod.BackendTelemetryDelta,
) bool {
    if (comptime backend == .cpu_native) return warmups.len == 0 and samples.len == 0;
    for (warmups) |delta| if (delta.metal_dispatches == 0) return false;
    for (samples) |delta| {
        if (delta.metal_dispatches == 0 or pipelinePreparationOccurred(delta.pipeline_cache))
            return false;
    }
    return true;
}

fn pipelinePreparationOccurred(cache: report_mod.PipelineCacheDelta) bool {
    // A pipeline cache hit still accrues lookup time; these counters identify
    // samples that actually create or load pipeline state after warmup.
    return cache.library_cache_misses > 0 or
        cache.binary_archive_hits > 0 or
        cache.binary_archive_misses > 0 or
        cache.direct_compiles > 0 or
        cache.archive_populations > 0 or
        cache.archive_serializations > 0;
}

const TelemetryTotals = struct {
    metal_dispatches: u64 = 0,
    cpu_fallbacks: u64 = 0,
};

fn sumTelemetry(
    warmups: []const report_mod.BackendTelemetryDelta,
    samples: []const report_mod.BackendTelemetryDelta,
) TelemetryTotals {
    var result: TelemetryTotals = .{};
    for (warmups) |delta| {
        result.metal_dispatches +|= delta.metal_dispatches;
        result.cpu_fallbacks +|= delta.cpu_fallbacks;
    }
    for (samples) |delta| {
        result.metal_dispatches +|= delta.metal_dispatches;
        result.cpu_fallbacks +|= delta.cpu_fallbacks;
    }
    return result;
}

fn headlineRequirementsMet(requirements: report_mod.HeadlineRequirements) bool {
    inline for (std.meta.fields(report_mod.HeadlineRequirements)) |field| {
        if (!@field(requirements, field.name)) return false;
    }
    return true;
}

fn collectProvenance(allocator: std.mem.Allocator) !OwnedProvenance {
    const git_commit = try runCommand(allocator, &.{ "git", "rev-parse", "HEAD" });
    errdefer allocator.free(git_commit);
    if (git_commit.len != 40) return error.InvalidGitCommit;

    var overrides = std.ArrayList(report_mod.EnvironmentOverride).empty;
    errdefer {
        for (overrides.items) |entry| allocator.free(entry.value);
        overrides.deinit(allocator);
    }
    for (OVERRIDE_NAMES) |name| {
        const value = std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
            error.EnvironmentVariableNotFound => continue,
            else => return err,
        };
        try overrides.append(allocator, .{ .name = name, .value = value });
    }
    return .{
        .git_commit = git_commit,
        .environment_overrides = try overrides.toOwnedSlice(allocator),
    };
}

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 1024 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .Exited => |code| if (code != 0) return error.ProvenanceCommandFailed,
        else => return error.ProvenanceCommandFailed,
    }
    return allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \t\r\n"));
}

fn nsToSeconds(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_s;
}

fn rate(units: u64, seconds: f64) f64 {
    return @as(f64, @floatFromInt(units)) / seconds / 1_000_000.0;
}

test {
    _ = config;
    _ = report_mod;
    _ = statistics;
}

test "native proof runner: headline requirements fail closed" {
    var requirements = report_mod.HeadlineRequirements{
        .verified_unprofiled = true,
        .sampling_contract = true,
        .functional_protocol = true,
        .release_fast = true,
        .clean_complete_provenance = true,
        .thread_parallelism_enabled = true,
        .byte_identical_verified_samples = true,
        .backend_telemetry_valid = true,
    };
    try std.testing.expect(headlineRequirementsMet(requirements));
    requirements.clean_complete_provenance = false;
    try std.testing.expect(!headlineRequirementsMet(requirements));
}

test "native proof runner: every Metal request needs a dispatch" {
    const valid = report_mod.BackendTelemetryDelta{
        .classification = "accelerated_without_fallbacks",
        .metal_dispatches = 1,
        .cpu_fallbacks = 0,
        .counters = .{},
        .pipeline_cache = .{},
    };
    var invalid = valid;
    invalid.metal_dispatches = 0;
    try std.testing.expect(backendTelemetryValid(.metal_hybrid, &.{valid}, &.{valid}));
    try std.testing.expect(!backendTelemetryValid(.metal_hybrid, &.{valid}, &.{invalid}));
    var cold = valid;
    cold.pipeline_cache.direct_compiles = 1;
    try std.testing.expect(!backendTelemetryValid(.metal_hybrid, &.{valid}, &.{cold}));
    try std.testing.expect(backendTelemetryValid(.cpu_native, &.{}, &.{}));
}

test "native proof runner: oracle artifact wraps exact canonical bytes" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "proof.json" });
    defer std.testing.allocator.free(path);

    const pcs_config = stwo.core.pcs.PcsConfig{
        .pow_bits = 10,
        .fri_config = try stwo.core.fri.FriConfig.init(0, 1, 3),
    };
    const statement = stwo.examples.wide_fibonacci.Statement{ .log_n_rows = 12, .sequence_len = 16 };
    const canonical = [_]u8{ 0, 1, 2, 127, 128, 255 };
    try examples.WideFibonacciSpec.writeArtifact(
        std.testing.allocator,
        path,
        pcs_config,
        statement,
        &canonical,
    );

    var parsed = try examples_artifact.readArtifact(std.testing.allocator, path);
    defer parsed.deinit();
    const artifact = parsed.value;
    try std.testing.expectEqualStrings(examples_artifact.UPSTREAM_COMMIT, artifact.upstream_commit);
    try std.testing.expectEqualStrings("zig", artifact.generator);
    try std.testing.expectEqualStrings("wide_fibonacci", artifact.example);
    try std.testing.expectEqual(@as(u32, 10), artifact.pcs_config.pow_bits);
    try std.testing.expectEqual(@as(u32, 12), artifact.wide_fibonacci_statement.?.log_n_rows);
    try std.testing.expectEqual(@as(u32, 16), artifact.wide_fibonacci_statement.?.sequence_len);
    const decoded = try examples_artifact.hexToBytesAlloc(std.testing.allocator, artifact.proof_bytes_hex);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, &canonical, decoded);
}
