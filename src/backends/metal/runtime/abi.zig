const std = @import("std");

pub const DecommitFriRoundParams = extern struct {
    unique_base: u64,
    unique_count_base: u64,
    tree_queries_base: u64,
    tree_count_base: u64,
    expanded_base: u64,
    expanded_count_base: u64,
    walk_base: u64,
    walk_count_base: u64,
    coordinate_bases: u64,
    values_base: u64,
    walk_scratch_base: u64,
    retained_offsets: u64,
    assembly_base: u64,
    max_queries: u32,
    cumulative_fold: u32,
    fold_step: u32,
    packed_log: u32,
    max_positions: u32,
    tree_index: u32,
    leaf_log: u32,
    assembly_capacity: u32,
};

pub const DecommitTraceGroupParams = extern struct {
    column_offsets: u64,
    column_logs: u64,
    queries: u64,
    query_count_at: u64,
    values: u64,
    leaf_indices: u64,
    leaf_count_at: u64,
    output_hashes: u64,
    column_count: u32,
    lifting_log: u32,
    max_queries: u32,
    first_column: u32,
    stride: u32,
    total_columns: u32,
    max_leaf_count: u32,
    domain_prefix_bytes: u32,
    leaf_seed: [8]u32,
};

pub const PipelineCacheStats = extern struct {
    library_cache_hits: u64,
    library_cache_misses: u64,
    pipeline_cache_hits: u64,
    binary_archive_hits: u64,
    binary_archive_misses: u64,
    direct_compiles: u64,
    archive_populations: u64,
    archive_serializations: u64,
    pipeline_preparation_seconds: f64,
    library_preparation_seconds: f64,
    library_cache_entries: u64,
    library_cache_bytes: u64,
    library_cache_peak_entries: u64,
    library_cache_peak_bytes: u64,
    library_cache_evictions: u64,
    library_cache_rejections: u64,
    pipeline_cache_entries: u64,
    pipeline_cache_bytes: u64,
    pipeline_cache_peak_entries: u64,
    pipeline_cache_peak_bytes: u64,
    pipeline_cache_evictions: u64,
    pipeline_cache_invalidations: u64,
    pipeline_cache_rejections: u64,
    library_cache_entry_limit: u64,
    library_cache_byte_limit: u64,
    pipeline_cache_entry_limit: u64,
    pipeline_cache_byte_limit: u64,

    pub fn zero() PipelineCacheStats {
        return std.mem.zeroes(PipelineCacheStats);
    }
};

pub const ArenaCopyRange = extern struct {
    source_word_offset: u64,
    destination_word_offset: u64,
    word_count: u32,
    reserved: u32 = 0,
};

pub const PreparedStateRange = extern struct {
    arena_byte_offset: u64,
    snapshot_byte_offset: u64,
    byte_count: u64,
};

pub const QuotientCoefficientTerm = extern struct {
    source_word_offset: u64,
    source_word_count: u32,
    value_coefficients: [4]u32,
};

pub const QuotientCoefficientTask = extern struct {
    term_start: u32,
    term_count: u32,
    destination_word_offsets: [4]u32,
    row_count: u32,
    constant_terms: [4]u32,
};

comptime {
    assertLayout(DecommitFriRoundParams, 136, &.{
        .{ "unique_base", 0 },
        .{ "assembly_base", 96 },
        .{ "max_queries", 104 },
        .{ "assembly_capacity", 132 },
    });
    assertLayout(DecommitTraceGroupParams, 128, &.{
        .{ "column_offsets", 0 },
        .{ "domain_prefix_bytes", 92 },
        .{ "leaf_seed", 96 },
    });
    assertLayout(PipelineCacheStats, 216, &.{
        .{ "library_cache_hits", 0 },
        .{ "pipeline_preparation_seconds", 64 },
        .{ "library_preparation_seconds", 72 },
        .{ "library_cache_entries", 80 },
        .{ "pipeline_cache_entries", 128 },
        .{ "pipeline_cache_byte_limit", 208 },
    });
    assertLayout(ArenaCopyRange, 24, &.{
        .{ "source_word_offset", 0 },
        .{ "destination_word_offset", 8 },
        .{ "word_count", 16 },
        .{ "reserved", 20 },
    });
    assertLayout(PreparedStateRange, 24, &.{
        .{ "arena_byte_offset", 0 },
        .{ "snapshot_byte_offset", 8 },
        .{ "byte_count", 16 },
    });
    assertLayout(QuotientCoefficientTerm, 32, &.{
        .{ "source_word_offset", 0 },
        .{ "source_word_count", 8 },
        .{ "value_coefficients", 12 },
    });
    assertLayout(QuotientCoefficientTask, 44, &.{
        .{ "term_start", 0 },
        .{ "destination_word_offsets", 8 },
        .{ "row_count", 24 },
        .{ "constant_terms", 28 },
    });
}

const FieldOffset = struct { []const u8, usize };

fn assertLayout(comptime T: type, expected_size: usize, offsets: []const FieldOffset) void {
    if (@sizeOf(T) != expected_size) @compileError("Metal runtime ABI size drift");
    for (offsets) |entry| {
        if (@offsetOf(T, entry[0]) != entry[1]) @compileError("Metal runtime ABI field drift");
    }
}

test "pipeline cache stats zero value" {
    const stats = PipelineCacheStats.zero();
    inline for (@typeInfo(PipelineCacheStats).@"struct".fields) |field| {
        try std.testing.expectEqual(@as(field.type, 0), @field(stats, field.name));
    }
}

test "arena copy range reserved word defaults to zero" {
    const range = ArenaCopyRange{
        .source_word_offset = 1,
        .destination_word_offset = 2,
        .word_count = 3,
    };
    try std.testing.expectEqual(@as(u32, 0), range.reserved);
}
