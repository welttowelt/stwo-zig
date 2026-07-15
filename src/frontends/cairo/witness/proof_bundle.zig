const std = @import("std");

pub const hash_words = 8;
pub const nonce_words = 2;
pub const decommit_magic: u32 = 0x4457_5453;
pub const decommit_version: u32 = 1;
pub const decommit_header_words = 8;
pub const decommit_tree_meta_words = 16;
pub const decommit_aux_node_words = 10;
pub const m31_prime: u32 = 0x7fff_ffff;

pub const Error = error{
    InvalidLayout,
    InvalidWordCount,
    InvalidDecommitHeader,
    InvalidDecommitRange,
    InvalidTreeMetadata,
    NonCanonicalM31,
};

pub const Range = struct { start: usize, end: usize };

pub const Layout = struct {
    commitments: Range,
    interaction_claim: Range,
    interaction_pow: Range,
    sampled_values: Range,
    fri_commitments: Range,
    final_line_poly: Range,
    query_pow: Range,
    decommitment: Range,
    total_words: usize,

    pub fn init(
        interaction_claim_words: usize,
        sampled_value_words: usize,
        fri_tree_count: usize,
        final_line_poly_words: usize,
        decommitment_words: usize,
    ) !Layout {
        if (interaction_claim_words == 0 or interaction_claim_words % 4 != 0 or
            sampled_value_words == 0 or sampled_value_words % 4 != 0 or fri_tree_count == 0 or
            final_line_poly_words == 0 or final_line_poly_words % 4 != 0 or decommitment_words == 0)
            return Error.InvalidLayout;
        var cursor: usize = 0;
        const take = struct {
            fn run(position: *usize, count: usize) !Range {
                const start = position.*;
                position.* = std.math.add(usize, position.*, count) catch return Error.InvalidLayout;
                return .{ .start = start, .end = position.* };
            }
        }.run;
        const commitments = try take(&cursor, 4 * hash_words);
        const interaction_claim = try take(&cursor, interaction_claim_words);
        const interaction_pow = try take(&cursor, nonce_words);
        const sampled_values = try take(&cursor, sampled_value_words);
        const fri_commitments = try take(&cursor, fri_tree_count * hash_words);
        const final_line_poly = try take(&cursor, final_line_poly_words);
        const query_pow = try take(&cursor, nonce_words);
        const decommitment = try take(&cursor, decommitment_words);
        return .{
            .commitments = commitments,
            .interaction_claim = interaction_claim,
            .interaction_pow = interaction_pow,
            .sampled_values = sampled_values,
            .fri_commitments = fri_commitments,
            .final_line_poly = final_line_poly,
            .query_pow = query_pow,
            .decommitment = decommitment,
            .total_words = cursor,
        };
    }
};

pub const TreeMeta = struct {
    kind: u32,
    role: u32,
    query_offset: usize,
    query_count: usize,
    values_offset: usize,
    values_count: usize,
    fri_witness_offset: usize,
    fri_witness_count: usize,
    hash_witness_offset: usize,
    hash_witness_count: usize,
    aux_offset: usize,
    aux_count: usize,
    all_values_offset: usize,
    all_values_count: usize,
    leaf_log_size: u32,
    used_words: usize,
};

pub const DecommitAssembly = struct {
    words: []const u32,
    raw_queries: []const u32,
    unique_queries: []const u32,
    trees: []TreeMeta,

    pub fn decode(allocator: std.mem.Allocator, capacity: []const u32) !DecommitAssembly {
        if (capacity.len < decommit_header_words or capacity[0] != decommit_magic or capacity[1] != decommit_version)
            return Error.InvalidDecommitHeader;
        const tree_count: usize = capacity[2];
        const raw_count: usize = capacity[3];
        const unique_count: usize = capacity[4];
        const raw_offset: usize = capacity[5];
        const unique_offset: usize = capacity[6];
        const used: usize = capacity[7];
        if (used < decommit_header_words or used > capacity.len or
            decommit_header_words + tree_count * decommit_tree_meta_words > used)
            return Error.InvalidDecommitHeader;
        const words = capacity[0..used];
        const raw_queries = try checkedSlice(words, raw_offset, raw_count);
        const unique_queries = try checkedSlice(words, unique_offset, unique_count);
        const trees = try allocator.alloc(TreeMeta, tree_count);
        errdefer allocator.free(trees);
        for (trees, 0..) |*tree, index| {
            const meta = words[decommit_header_words + index * decommit_tree_meta_words ..][0..decommit_tree_meta_words];
            tree.* = .{
                .kind = meta[0],
                .role = meta[1],
                .query_offset = meta[2],
                .query_count = meta[3],
                .values_offset = meta[4],
                .values_count = meta[5],
                .fri_witness_offset = meta[6],
                .fri_witness_count = meta[7],
                .hash_witness_offset = meta[8],
                .hash_witness_count = meta[9],
                .aux_offset = meta[10],
                .aux_count = meta[11],
                .all_values_offset = meta[12],
                .all_values_count = meta[13],
                .leaf_log_size = meta[14],
                .used_words = meta[15],
            };
            if (tree.kind > 1 or tree.used_words == 0) return Error.InvalidTreeMetadata;
            _ = try checkedSlice(words, tree.query_offset, tree.query_count);
            _ = try checkedSlice(words, tree.values_offset, tree.values_count);
            _ = try checkedSlice(words, tree.fri_witness_offset, tree.fri_witness_count * 4);
            _ = try checkedSlice(words, tree.hash_witness_offset, tree.hash_witness_count * hash_words);
            _ = try checkedSlice(words, tree.aux_offset, tree.aux_count * decommit_aux_node_words);
            _ = try checkedSlice(words, tree.all_values_offset, tree.all_values_count * 5);
        }
        return .{ .words = words, .raw_queries = raw_queries, .unique_queries = unique_queries, .trees = trees };
    }

    pub fn deinit(self: *DecommitAssembly, allocator: std.mem.Allocator) void {
        allocator.free(self.trees);
        self.* = undefined;
    }
};

pub const ProofBundle = struct {
    words: []const u32,
    layout: Layout,
    decommitment: DecommitAssembly,

    pub fn decode(allocator: std.mem.Allocator, words: []const u32, layout: Layout) !ProofBundle {
        if (words.len != layout.total_words) return Error.InvalidWordCount;
        try canonical(words[layout.interaction_claim.start..layout.interaction_claim.end]);
        try canonical(words[layout.sampled_values.start..layout.sampled_values.end]);
        try canonical(words[layout.final_line_poly.start..layout.final_line_poly.end]);
        return .{
            .words = words,
            .layout = layout,
            .decommitment = try DecommitAssembly.decode(allocator, words[layout.decommitment.start..layout.decommitment.end]),
        };
    }

    pub fn deinit(self: *ProofBundle, allocator: std.mem.Allocator) void {
        self.decommitment.deinit(allocator);
        self.* = undefined;
    }

    pub fn interactionNonce(self: ProofBundle) u64 {
        const words = self.words[self.layout.interaction_pow.start..self.layout.interaction_pow.end];
        return words[0] | @as(u64, words[1]) << 32;
    }

    pub fn queryNonce(self: ProofBundle) u64 {
        const words = self.words[self.layout.query_pow.start..self.layout.query_pow.end];
        return words[0] | @as(u64, words[1]) << 32;
    }
};

fn checkedSlice(words: []const u32, offset: usize, count: usize) ![]const u32 {
    if (count == 0 and offset == 0) return words[0..0];
    const end = std.math.add(usize, offset, count) catch return Error.InvalidDecommitRange;
    if (end > words.len) return Error.InvalidDecommitRange;
    return words[offset..end];
}

fn canonical(words: []const u32) !void {
    if (words.len % 4 != 0) return Error.InvalidLayout;
    for (words) |word| if (word >= m31_prime) return Error.NonCanonicalM31;
}

test "resident proof bundle rejects unfinished and noncanonical output" {
    const allocator = std.testing.allocator;
    const layout = try Layout.init(4, 4, 1, 4, 64);
    const words = try allocator.alloc(u32, layout.total_words);
    defer allocator.free(words);
    @memset(words, 0);
    const decommit = words[layout.decommitment.start..layout.decommitment.end];
    decommit[0] = decommit_magic;
    decommit[1] = decommit_version;
    decommit[2] = 1;
    decommit[3] = 1;
    decommit[4] = 1;
    decommit[5] = 24;
    decommit[6] = 25;
    decommit[7] = 26;
    decommit[8] = 0;
    decommit[10] = 24;
    decommit[11] = 1;
    decommit[23] = 1;
    decommit[24] = 7;
    decommit[25] = 7;
    var decoded = try ProofBundle.decode(allocator, words, layout);
    decoded.deinit(allocator);
    words[layout.sampled_values.start] = m31_prime;
    try std.testing.expectError(Error.NonCanonicalM31, ProofBundle.decode(allocator, words, layout));
}
