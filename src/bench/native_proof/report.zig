const std = @import("std");
const stwo = @import("stwo");
const config = @import("config.zig");
const statistics = @import("statistics.zig");

pub const SCHEMA_VERSION: u32 = 1;

pub const EnvironmentOverride = struct {
    name: []const u8,
    value: []const u8,
};

pub const Provenance = struct {
    git_commit: []const u8,
    git_dirty: bool,
    zig_version: []const u8,
    optimization: []const u8,
    target_os: []const u8,
    target_arch: []const u8,
    cpu_count: usize,
    simd_pack_width: usize,
    single_threaded: bool,
    thread_parallelism_enabled: bool,
    environment_overrides: []const EnvironmentOverride,
    complete: bool,
};

pub const Protocol = struct {
    name: config.Protocol,
    pow_bits: u32,
    log_blowup_factor: u32,
    log_last_layer_degree_bound: u32,
    n_queries: usize,
    fold_step: u32,
};

pub const Workload = struct {
    name: []const u8,
    descriptor_sha256: []const u8,
    log_rows: u32,
    rows: u64,
    sequence_len: u32,
    committed_trace_cells: u64,
};

pub const CanonicalProof = struct {
    bytes: usize,
    sha256: []const u8,
};

pub const ProofEvidence = struct {
    samples: []const CanonicalProof,
    verified_samples: usize,
    all_samples_byte_identical: bool,
};

pub const BackendCounterDelta = struct {
    host_merkle_commits: u64 = 0,
    resident_merkle_commits: u64 = 0,
    metal_quotient_dispatches: u64 = 0,
    metal_sampled_value_dispatches: u64 = 0,
    metal_circle_transform_dispatches: u64 = 0,
    metal_circle_lde_dispatches: u64 = 0,
    metal_fri_circle_fold_dispatches: u64 = 0,
    metal_fri_line_fold_dispatches: u64 = 0,
    metal_qm31_coordinate_dispatches: u64 = 0,
    cpu_small_merkle_commits: u64 = 0,
    cpu_streaming_merkle_commits: u64 = 0,
    cpu_sampled_value_evaluations: u64 = 0,
    cpu_small_circle_interpolations: u64 = 0,
    cpu_small_circle_evaluations: u64 = 0,
    cpu_small_circle_ldes: u64 = 0,
};

pub const PipelineCacheDelta = struct {
    library_cache_hits: u64 = 0,
    library_cache_misses: u64 = 0,
    pipeline_cache_hits: u64 = 0,
    binary_archive_hits: u64 = 0,
    binary_archive_misses: u64 = 0,
    direct_compiles: u64 = 0,
    archive_populations: u64 = 0,
    archive_serializations: u64 = 0,
    pipeline_preparation_seconds: f64 = 0,
};

pub const BackendTelemetryDelta = struct {
    classification: []const u8,
    metal_dispatches: u64,
    cpu_fallbacks: u64,
    counters: BackendCounterDelta,
    pipeline_cache: PipelineCacheDelta,
};

pub const BackendTelemetry = struct {
    scope: []const u8 = "verified_proof_request",
    post_warmup_pipeline_cache: PipelineCacheDelta,
    warmups: []const BackendTelemetryDelta,
    samples: []const BackendTelemetryDelta,
    total_metal_dispatches: u64,
    total_cpu_fallbacks: u64,
    valid: bool,
};

pub const Sample = struct {
    input_seconds: f64,
    prove_seconds: f64,
    proof_encode_seconds: f64,
    verify_seconds: f64,
    request_seconds: f64,
    row_mhz: f64,
    committed_mcells_per_second: f64,
};

pub const StageProfile = stwo.prover.stage_profile.StageProfile;

pub const Timing = struct {
    backend_init_seconds: f64,
    warmup_request_seconds: []const f64,
    samples: []const Sample,
    stage_profiles: ?[]const StageProfile,
    input_seconds: statistics.Summary,
    prove_seconds: statistics.Summary,
    proof_encode_seconds: statistics.Summary,
    verify_seconds: statistics.Summary,
    request_seconds: statistics.Summary,
};

pub const Throughput = struct {
    native_unit: []const u8 = "trace_rows",
    headline_eligible: bool,
    headline_row_mhz: ?statistics.Summary,
    diagnostic_row_mhz: ?statistics.Summary,
    headline_committed_mcells_per_second: ?statistics.Summary,
    diagnostic_committed_mcells_per_second: ?statistics.Summary,
    headline_requirements: HeadlineRequirements,
};

pub const HeadlineRequirements = struct {
    verified_unprofiled: bool,
    sampling_contract: bool,
    functional_protocol: bool,
    release_fast: bool,
    clean_complete_provenance: bool,
    thread_parallelism_enabled: bool,
    byte_identical_verified_samples: bool,
    backend_telemetry_valid: bool,
};

pub const Report = struct {
    schema_version: u32 = SCHEMA_VERSION,
    backend: config.Backend,
    evidence_class: config.EvidenceClass,
    profiled: bool,
    provenance: Provenance,
    protocol: Protocol,
    workload: Workload,
    proof: ProofEvidence,
    backend_telemetry: ?BackendTelemetry,
    timing: Timing,
    throughput: Throughput,
};

pub fn encodeAlloc(allocator: std.mem.Allocator, value: Report) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

test "native proof report: diagnostic evidence cannot populate headline rates" {
    const summary = statistics.Summary{ .median = 2, .min = 1, .max = 3, .mad = 1 };
    var profile_stages = [_]stwo.prover.stage_profile.StageNode{.{
        .id = "main_trace_commit",
        .label = "Main trace commit",
        .seconds = 1.25,
    }};
    const profiles = [_]StageProfile{.{
        .runtime = "ReleaseFast",
        .example = "wide_fibonacci",
        .stages = &profile_stages,
    }};
    const value = Report{
        .backend = .cpu_native,
        .evidence_class = .profiled_diagnostic,
        .profiled = true,
        .provenance = .{
            .git_commit = "0123456789012345678901234567890123456789",
            .git_dirty = false,
            .zig_version = "0.15.2",
            .optimization = "ReleaseFast",
            .target_os = "macos",
            .target_arch = "aarch64",
            .cpu_count = 8,
            .simd_pack_width = 4,
            .single_threaded = false,
            .thread_parallelism_enabled = true,
            .environment_overrides = &.{},
            .complete = true,
        },
        .protocol = .{ .name = .smoke, .pow_bits = 0, .log_blowup_factor = 1, .log_last_layer_degree_bound = 0, .n_queries = 3, .fold_step = 1 },
        .workload = .{ .name = "wide_fibonacci", .descriptor_sha256 = "abc", .log_rows = 5, .rows = 32, .sequence_len = 8, .committed_trace_cells = 256 },
        .proof = .{ .samples = &.{.{ .bytes = 42, .sha256 = "def" }}, .verified_samples = 1, .all_samples_byte_identical = true },
        .backend_telemetry = null,
        .timing = .{
            .backend_init_seconds = 0,
            .warmup_request_seconds = &.{},
            .samples = &.{},
            .stage_profiles = &profiles,
            .input_seconds = summary,
            .prove_seconds = summary,
            .proof_encode_seconds = summary,
            .verify_seconds = summary,
            .request_seconds = summary,
        },
        .throughput = .{
            .headline_eligible = false,
            .headline_row_mhz = null,
            .diagnostic_row_mhz = summary,
            .headline_committed_mcells_per_second = null,
            .diagnostic_committed_mcells_per_second = summary,
            .headline_requirements = .{
                .verified_unprofiled = false,
                .sampling_contract = true,
                .functional_protocol = true,
                .release_fast = true,
                .clean_complete_provenance = true,
                .thread_parallelism_enabled = true,
                .byte_identical_verified_samples = true,
                .backend_telemetry_valid = true,
            },
        },
    };
    const encoded = try encodeAlloc(std.testing.allocator, value);
    defer std.testing.allocator.free(encoded);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, encoded, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqualStrings("profiled_diagnostic", object.get("evidence_class").?.string);
    const throughput = object.get("throughput").?.object;
    try std.testing.expect(throughput.get("headline_row_mhz").? == .null);
    try std.testing.expect(throughput.get("diagnostic_row_mhz").? == .object);
    try std.testing.expect(object.get("backend_telemetry").? == .null);
    try std.testing.expectEqual(@as(usize, 1), object.get("timing").?.object.get("stage_profiles").?.array.items.len);
}

test "native proof report: Metal telemetry includes post-warmup cache evidence" {
    const value = BackendTelemetry{
        .post_warmup_pipeline_cache = .{
            .library_cache_hits = 2,
            .direct_compiles = 1,
            .pipeline_preparation_seconds = 0.125,
        },
        .warmups = &.{},
        .samples = &.{},
        .total_metal_dispatches = 0,
        .total_cpu_fallbacks = 0,
        .valid = true,
    };
    const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, value, .{});
    defer std.testing.allocator.free(encoded);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, encoded, .{});
    defer parsed.deinit();
    const cache = parsed.value.object.get("post_warmup_pipeline_cache").?.object;
    try std.testing.expectEqual(@as(i64, 1), cache.get("direct_compiles").?.integer);
}
