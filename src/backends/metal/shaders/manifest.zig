const std = @import("std");

pub const core_shader_abi: u32 = 2;

pub const CompileProfile = struct {
    math_mode: []const u8,
};

pub const compile_profile: CompileProfile = .{
    .math_mode = "safe",
};

pub const Unit = enum {
    transcript,
    commitments,
    cairo_trace,
    cairo_witness_feed,
    cairo_fixed_tables,
    cairo_ec_op,
    circle_transform,
    composition,
    relation,
    compaction,
    quotient,
    fri,
    decommit,
    polynomial_eval,
    arena_ops,
};

pub const Export = struct {
    name: []const u8,
    owner: Unit,
};

/// The logical owner map is authoritative even while unmoved kernels remain in
/// the legacy translation unit during the staged migration.
pub const exports = [_]Export{
    .{ .name = "stwo_zig_transcript_init_resident", .owner = .transcript },
    .{ .name = "stwo_zig_transcript_mix_resident", .owner = .transcript },
    .{ .name = "stwo_zig_transcript_draw_secure_resident", .owner = .transcript },
    .{ .name = "stwo_zig_transcript_draw_queries_resident", .owner = .transcript },
    .{ .name = "stwo_zig_blake2s_leaves", .owner = .commitments },
    .{ .name = "stwo_zig_blake2s_leaf_absorb_resident", .owner = .commitments },
    .{ .name = "stwo_zig_blake2s_leaf_absorb_compact_resident", .owner = .commitments },
    .{ .name = "stwo_zig_blake2s_parents", .owner = .commitments },
    .{ .name = "stwo_zig_blake2s_parents_sparse", .owner = .commitments },
    .{ .name = "stwo_zig_blake2s_parent_tail_sparse", .owner = .commitments },
    .{ .name = "stwo_zig_blake2s_parents_plain_sparse", .owner = .commitments },
    .{ .name = "stwo_zig_witness_input_gather_resident", .owner = .cairo_trace },
    .{ .name = "stwo_zig_execution_table_split_resident", .owner = .cairo_trace },
    .{ .name = "stwo_zig_memory_address_base_trace_resident", .owner = .cairo_trace },
    .{ .name = "stwo_zig_memory_value_base_trace_resident", .owner = .cairo_trace },
    .{ .name = "stwo_zig_memory_rc99_count_resident", .owner = .cairo_trace },
    .{ .name = "stwo_zig_public_memory_seed_resident", .owner = .cairo_trace },
    .{ .name = "stwo_zig_felt252_oracle", .owner = .cairo_ec_op },
    .{ .name = "stwo_zig_ec_op_lookup", .owner = .cairo_ec_op },
    .{ .name = "stwo_zig_ec_op_witness", .owner = .cairo_ec_op },
    .{ .name = "stwo_zig_ec_op_base_finalize", .owner = .cairo_ec_op },
    .{ .name = "stwo_zig_circle_ifft_first", .owner = .circle_transform },
    .{ .name = "stwo_zig_circle_ifft_layer", .owner = .circle_transform },
    .{ .name = "stwo_zig_circle_rfft_layer", .owner = .circle_transform },
    .{ .name = "stwo_zig_circle_rfft_last", .owner = .circle_transform },
    .{ .name = "stwo_zig_circle_rescale", .owner = .circle_transform },
    .{ .name = "stwo_zig_circle_expand_coefficients", .owner = .circle_transform },
    .{ .name = "stwo_zig_circle_expand_sparse", .owner = .circle_transform },
    .{ .name = "stwo_zig_composition_expand_sparse", .owner = .composition },
    .{ .name = "stwo_zig_circle_copy_sparse", .owner = .circle_transform },
    .{ .name = "stwo_zig_circle_ifft_first_sparse", .owner = .circle_transform },
    .{ .name = "stwo_zig_circle_ifft_layer_sparse", .owner = .circle_transform },
    .{ .name = "stwo_zig_circle_rescale_sparse", .owner = .circle_transform },
    .{ .name = "stwo_zig_fixed_table_lookup_sparse", .owner = .cairo_fixed_tables },
    .{ .name = "stwo_zig_circle_rfft_layer_sparse", .owner = .circle_transform },
    .{ .name = "stwo_zig_circle_rfft_radix4_sparse", .owner = .circle_transform },
    .{ .name = "stwo_zig_circle_rfft_last_sparse", .owner = .circle_transform },
    .{ .name = "stwo_zig_circle_rfft_layer_sparse_wide", .owner = .circle_transform },
    .{ .name = "stwo_zig_circle_rfft_last_sparse_wide", .owner = .circle_transform },
    .{ .name = "stwo_zig_composition_lift_accumulate", .owner = .composition },
    .{ .name = "stwo_zig_composition_split_coordinates", .owner = .composition },
    .{ .name = "stwo_zig_composition_random_powers", .owner = .composition },
    .{ .name = "stwo_zig_composition_ext_params", .owner = .composition },
    .{ .name = "stwo_zig_circle_ifft_fused_tail", .owner = .circle_transform },
    .{ .name = "stwo_zig_circle_rfft_fused_tail", .owner = .circle_transform },
    .{ .name = "stwo_zig_circle_rfft_fused_tail_sparse", .owner = .circle_transform },
    .{ .name = "stwo_zig_relation_fused", .owner = .relation },
    .{ .name = "stwo_zig_relation_block_scan", .owner = .relation },
    .{ .name = "stwo_zig_relation_scan_blocks", .owner = .relation },
    .{ .name = "stwo_zig_relation_scan_finalize", .owner = .relation },
    .{ .name = "stwo_zig_witness_feed_counts", .owner = .cairo_witness_feed },
    .{ .name = "stwo_zig_clear_arena_spans", .owner = .arena_ops },
    .{ .name = "stwo_zig_compact_gather", .owner = .compaction },
    .{ .name = "stwo_zig_compact_radix_histogram", .owner = .compaction },
    .{ .name = "stwo_zig_compact_radix_prefix", .owner = .compaction },
    .{ .name = "stwo_zig_compact_radix_scatter", .owner = .compaction },
    .{ .name = "stwo_zig_compact_heads", .owner = .compaction },
    .{ .name = "stwo_zig_compact_scan_local", .owner = .compaction },
    .{ .name = "stwo_zig_compact_scan_blocks", .owner = .compaction },
    .{ .name = "stwo_zig_compact_scan_add", .owner = .compaction },
    .{ .name = "stwo_zig_compact_clear_outputs", .owner = .compaction },
    .{ .name = "stwo_zig_compact_scatter", .owner = .compaction },
    .{ .name = "stwo_zig_compact_finalize", .owner = .compaction },
    .{ .name = "stwo_zig_fri_fold_circle", .owner = .fri },
    .{ .name = "stwo_zig_fri_fold_line", .owner = .fri },
    .{ .name = "stwo_zig_qm31_to_coordinates", .owner = .quotient },
    .{ .name = "stwo_zig_quotient_rows", .owner = .quotient },
    .{ .name = "stwo_zig_quotient_rows_raw", .owner = .quotient },
    .{ .name = "stwo_zig_quotient_numerator_raw", .owner = .quotient },
    .{ .name = "stwo_zig_quotient_finalize", .owner = .quotient },
    .{ .name = "stwo_zig_quotient_coefficients_resident", .owner = .quotient },
    .{ .name = "stwo_zig_quotient_domain_points_resident", .owner = .quotient },
    .{ .name = "stwo_zig_quotient_denominators_resident", .owner = .quotient },
    .{ .name = "stwo_zig_quotient_combine_resident", .owner = .quotient },
    .{ .name = "stwo_zig_fri_fold3_resident", .owner = .fri },
    .{ .name = "stwo_zig_fri_fold2_resident", .owner = .fri },
    .{ .name = "stwo_zig_fri_packed_leaves_resident", .owner = .fri },
    .{ .name = "stwo_zig_fri_final_line_resident", .owner = .fri },
    .{ .name = "stwo_zig_decommit_normalize_queries_resident", .owner = .decommit },
    .{ .name = "stwo_zig_decommit_prepare_fri_queries_resident", .owner = .decommit },
    .{ .name = "stwo_zig_decommit_prepare_trace_queries_resident", .owner = .decommit },
    .{ .name = "stwo_zig_decommit_gather_trace_values_resident", .owner = .decommit },
    .{ .name = "stwo_zig_decommit_gather_fri_values_resident", .owner = .decommit },
    .{ .name = "stwo_zig_decommit_sparse_parent_resident", .owner = .decommit },
    .{ .name = "stwo_zig_decommit_sparse_leaves_resident", .owner = .decommit },
    .{ .name = "stwo_zig_decommit_sparse_leaf_group_resident", .owner = .decommit },
    .{ .name = "stwo_zig_decommit_assemble_trace_resident", .owner = .decommit },
    .{ .name = "stwo_zig_decommit_assemble_fri_resident", .owner = .decommit },
    .{ .name = "stwo_zig_eval_basis", .owner = .polynomial_eval },
    .{ .name = "stwo_zig_eval_polynomials", .owner = .polynomial_eval },
};

pub const TranslationUnit = struct {
    path: []const u8,
    source: []const u8,
};

const legacy_source = @embedFile("../kernels.metal");
const base_source = @embedFile("include/base.metal");
const blake2s_source = @embedFile("include/blake2s.metal");
const abi_types_source = @embedFile("include/abi_types.metal");
const arena_ops_source = @embedFile("core/arena_ops.metal");
const transcript_source = @embedFile("core/transcript.metal");
const polynomial_eval_source = @embedFile("core/polynomial_eval.metal");

pub const support_headers = [_]TranslationUnit{
    .{ .path = "src/backends/metal/shaders/include/base.metal", .source = base_source },
    .{ .path = "src/backends/metal/shaders/include/blake2s.metal", .source = blake2s_source },
    .{ .path = "src/backends/metal/shaders/include/abi_types.metal", .source = abi_types_source },
};

pub const translation_units = [_]TranslationUnit{
    .{ .path = "src/backends/metal/kernels.metal", .source = legacy_source },
    .{ .path = "src/backends/metal/shaders/core/arena_ops.metal", .source = arena_ops_source },
    .{ .path = "src/backends/metal/shaders/core/transcript.metal", .source = transcript_source },
    .{ .path = "src/backends/metal/shaders/core/polynomial_eval.metal", .source = polynomial_eval_source },
};

/// The runtime still compiles one library. Translation-unit boundaries are
/// explicit here so AOT compilation can consume the same ordered manifest.
pub const amalgamated_source: [:0]const u8 = "#define STWO_ZIG_AMALGAMATED 1\n" ++
    "#line 1 \"src/backends/metal/shaders/include/base.metal\"\n" ++
    base_source ++
    "\n#line 1 \"src/backends/metal/shaders/include/blake2s.metal\"\n" ++
    blake2s_source ++
    "\n#line 1 \"src/backends/metal/kernels.metal\"\n" ++
    legacy_source ++
    "\n#line 1 \"src/backends/metal/shaders/core/arena_ops.metal\"\n" ++
    arena_ops_source ++
    "\n#line 1 \"src/backends/metal/shaders/core/transcript.metal\"\n" ++
    transcript_source ++
    "\n#line 1 \"src/backends/metal/shaders/include/abi_types.metal\"\n" ++
    abi_types_source ++
    "\n#line 1 \"src/backends/metal/shaders/core/polynomial_eval.metal\"\n" ++
    polynomial_eval_source ++ "\x00";

pub const amalgamated_source_sha256: [32]u8 = digest: {
    var result: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(
        amalgamated_source[0 .. amalgamated_source.len - 1],
        &result,
        .{},
    );
    break :digest result;
};

fn manifestContains(name: []const u8) bool {
    for (exports) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return true;
    }
    return false;
}

fn countKernelDeclarations(source: []const u8, name: []const u8) usize {
    var pattern_buffer: [160]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buffer, "kernel void {s}(", .{name}) catch unreachable;
    return std.mem.count(u8, source, pattern);
}

fn kernelDeclaration(source: []const u8, name: []const u8) ![]const u8 {
    var pattern_buffer: [160]u8 = undefined;
    const pattern = try std.fmt.bufPrint(&pattern_buffer, "kernel void {s}(", .{name});
    const start = std.mem.indexOf(u8, source, pattern) orelse return error.MissingMetalKernelDeclaration;
    const end = std.mem.indexOfPos(u8, source, start, ") {") orelse
        return error.MalformedMetalKernelDeclaration;
    return source[start .. end + 3];
}

test "metal shader manifest exactly covers source and runtime exports" {
    const runtime_source = @embedFile("../runtime.m");
    try std.testing.expectEqual(@as(usize, 90), exports.len);

    var declaration_count: usize = 0;
    var remaining: []const u8 = amalgamated_source[0 .. amalgamated_source.len - 1];
    const marker = "kernel void ";
    while (std.mem.indexOf(u8, remaining, marker)) |marker_index| {
        const name_start = marker_index + marker.len;
        const name_end = std.mem.indexOfScalarPos(u8, remaining, name_start, '(') orelse
            return error.MalformedMetalKernelDeclaration;
        try std.testing.expect(manifestContains(remaining[name_start..name_end]));
        declaration_count += 1;
        remaining = remaining[name_end + 1 ..];
    }
    try std.testing.expectEqual(exports.len, declaration_count);

    for (exports, 0..) |entry, index| {
        try std.testing.expectEqual(@as(usize, 1), countKernelDeclarations(amalgamated_source, entry.name));
        for (exports[index + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, entry.name, other.name));
        }

        var lookup_buffer: [160]u8 = undefined;
        const lookup = try std.fmt.bufPrint(&lookup_buffer, "@\"{s}\"", .{entry.name});
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, runtime_source, lookup));
    }
}

test "commitment shader bindings match core ABI version 2" {
    try std.testing.expectEqual(@as(u32, 2), core_shader_abi);
    const bindings = [_]struct { kernel: []const u8, argument: []const u8 }{
        .{ .kernel = "stwo_zig_blake2s_leaves", .argument = "prefix_bytes [[buffer(7)]]" },
        .{ .kernel = "stwo_zig_blake2s_parents", .argument = "prefix_bytes [[buffer(4)]]" },
        .{ .kernel = "stwo_zig_blake2s_parents_sparse", .argument = "prefix_bytes [[buffer(5)]]" },
        .{ .kernel = "stwo_zig_blake2s_parent_tail_sparse", .argument = "prefix_bytes [[buffer(6)]]" },
        .{ .kernel = "stwo_zig_fri_packed_leaves_resident", .argument = "prefix_bytes [[buffer(7)]]" },
    };
    for (bindings) |binding| {
        const declaration = try kernelDeclaration(amalgamated_source, binding.kernel);
        try std.testing.expect(std.mem.indexOf(u8, declaration, binding.argument) != null);
    }
}

test "polynomial evaluation is isolated in its owning shader unit" {
    try std.testing.expectEqual(@as(usize, 0), countKernelDeclarations(legacy_source, "stwo_zig_eval_basis"));
    try std.testing.expectEqual(@as(usize, 0), countKernelDeclarations(legacy_source, "stwo_zig_eval_polynomials"));
    try std.testing.expectEqual(@as(usize, 1), countKernelDeclarations(polynomial_eval_source, "stwo_zig_eval_basis"));
    try std.testing.expectEqual(@as(usize, 1), countKernelDeclarations(polynomial_eval_source, "stwo_zig_eval_polynomials"));
    try std.testing.expect(std.mem.indexOf(u8, abi_types_source, "struct PolynomialEvalTask") != null);
    try std.testing.expect(std.mem.indexOf(u8, abi_types_source, "struct PolynomialBasisTask") != null);
    try std.testing.expect(std.mem.indexOf(u8, polynomial_eval_source, "struct PolynomialEvalTask") == null);
}

test "transcript is isolated in its owning shader unit with a stable ABI" {
    const transcript_exports = [_][]const u8{
        "stwo_zig_transcript_init_resident",
        "stwo_zig_transcript_mix_resident",
        "stwo_zig_transcript_draw_secure_resident",
        "stwo_zig_transcript_draw_queries_resident",
    };
    for (transcript_exports) |name| {
        try std.testing.expectEqual(@as(usize, 0), countKernelDeclarations(legacy_source, name));
        try std.testing.expectEqual(@as(usize, 1), countKernelDeclarations(transcript_source, name));
    }

    const AbiFragment = struct { source: []const u8, count: usize };
    const abi_fragments = [_]AbiFragment{
        .{ .source = "device uint *arena [[buffer(0)]], constant uint &state_base [[buffer(1)]]", .count = 4 },
        .{ .source = "constant uint &source_base [[buffer(2)]], constant uint &source_words [[buffer(3)]]", .count = 1 },
        .{ .source = "constant uint &destination_base [[buffer(2)]], constant uint &felt_count [[buffer(3)]]", .count = 1 },
        .{ .source = "constant uint &destination_base [[buffer(2)]], constant uint &log_domain_size [[buffer(3)]]", .count = 1 },
        .{ .source = "constant uint &query_count [[buffer(4)]], uint lane [[thread_position_in_grid]]", .count = 1 },
    };
    for (abi_fragments) |fragment| {
        try std.testing.expectEqual(fragment.count, std.mem.count(u8, transcript_source, fragment.source));
    }
    try std.testing.expectEqual(
        @as(usize, 4),
        std.mem.count(u8, transcript_source, "uint lane [[thread_position_in_grid]]"),
    );
}

test "transcript declares only its standalone Blake support dependencies" {
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, legacy_source, "inline void blake2s_compress"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, blake2s_source, "inline void blake2s_compress"));
    try std.testing.expect(std.mem.indexOf(u8, transcript_source, "#include \"stwo_zig/base.metal\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript_source, "#include \"stwo_zig/blake2s.metal\"") != null);
}

test "arena resource operations are isolated in their owning shader unit" {
    const name = "stwo_zig_clear_arena_spans";
    try std.testing.expectEqual(@as(usize, 0), countKernelDeclarations(legacy_source, name));
    try std.testing.expectEqual(@as(usize, 1), countKernelDeclarations(arena_ops_source, name));
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, arena_ops_source, "device const uint *spans [[buffer(1)]]"),
    );
}
