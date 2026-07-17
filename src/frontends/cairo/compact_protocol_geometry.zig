//! Authenticated runtime geometry for compact Cairo proof interchange.

const std = @import("std");

pub const trace_tree_count: u32 = 4;
pub const legacy_max_log_degree_bound: u32 = 24;
pub const max_runtime_log_degree_bound: u32 = 31;
pub const max_query_count: u32 = 1 << 20;
pub const decommit_header_words: u32 = 8;
pub const decommit_tree_meta_words: u32 = 16;

pub const Error = error{
    InvalidProtocolGeometry,
    LengthOverflow,
};

/// Protocol fields that determine proof section and decommitment geometry.
pub const RuntimeProtocolGeometryV1 = struct {
    query_pow_bits: u32,
    log_blowup_factor: u32,
    query_count: u32,
    log_last_layer_degree_bound: u32,
    fri_fold_step: u32,
    fri_lifting_log_size: ?u32,
    interaction_pow_bits: u32,
    commitment_count: u32,
    sampled_tree_count: u32,
    fri_tree_count: u32,
    decommitment_record_count: u32,
    max_log_degree_bound: u32,

    pub fn sn2() RuntimeProtocolGeometryV1 {
        return .{
            .query_pow_bits = 26,
            .log_blowup_factor = 1,
            .query_count = 70,
            .log_last_layer_degree_bound = 0,
            .fri_fold_step = 3,
            .fri_lifting_log_size = null,
            .interaction_pow_bits = 24,
            .commitment_count = trace_tree_count,
            .sampled_tree_count = trace_tree_count,
            .fri_tree_count = 8,
            .decommitment_record_count = 12,
            .max_log_degree_bound = legacy_max_log_degree_bound,
        };
    }

    pub fn fromResident(resident: anytype) Error!RuntimeProtocolGeometryV1 {
        resident.validate() catch return Error.InvalidProtocolGeometry;
        const query_count = std.math.cast(u32, resident.query_count) orelse
            return Error.InvalidProtocolGeometry;
        const commitment_count = std.math.cast(u32, resident.trace_tree_count) orelse
            return Error.InvalidProtocolGeometry;
        const fri_tree_count = std.math.cast(u32, resident.fri_layer_count) orelse
            return Error.InvalidProtocolGeometry;
        const geometry = RuntimeProtocolGeometryV1{
            .query_pow_bits = resident.query_pow_bits,
            .log_blowup_factor = resident.log_blowup_factor,
            .query_count = query_count,
            .log_last_layer_degree_bound = resident.log_last_layer_degree_bound,
            .fri_fold_step = resident.fold_step,
            .fri_lifting_log_size = resident.lifting_log_size,
            .interaction_pow_bits = resident.interaction_pow_bits,
            .commitment_count = commitment_count,
            .sampled_tree_count = commitment_count,
            .fri_tree_count = fri_tree_count,
            .decommitment_record_count = try addU32(commitment_count, fri_tree_count),
            .max_log_degree_bound = resident.max_log_degree_bound,
        };
        try geometry.validate();
        return geometry;
    }

    pub fn validate(self: RuntimeProtocolGeometryV1) Error!void {
        if (self.query_pow_bits > 64 or self.interaction_pow_bits > 64 or
            self.log_blowup_factor == 0 or self.log_blowup_factor > 16 or
            self.query_count == 0 or self.query_count > max_query_count or
            self.log_last_layer_degree_bound > 10 or
            self.max_log_degree_bound > max_runtime_log_degree_bound or
            self.max_log_degree_bound <= self.log_last_layer_degree_bound)
            return Error.InvalidProtocolGeometry;
        if (self.fri_lifting_log_size) |log_size| {
            if (log_size == 0 or log_size > max_runtime_log_degree_bound)
                return Error.InvalidProtocolGeometry;
        }
        const expected_fri_count = try friLayerCount(
            self.max_log_degree_bound,
            self.log_last_layer_degree_bound,
            self.fri_fold_step,
        );
        if (self.commitment_count != trace_tree_count or
            self.sampled_tree_count != trace_tree_count or
            self.fri_tree_count != expected_fri_count or
            self.decommitment_record_count != try addU32(self.commitment_count, self.fri_tree_count))
            return Error.InvalidProtocolGeometry;
    }
};

pub fn minimumDecommitmentWords(record_count: u32, n_queries: u32) Error!u32 {
    const metadata = std.math.mul(u32, record_count, decommit_tree_meta_words) catch
        return Error.LengthOverflow;
    const queries = std.math.mul(u32, n_queries, 2) catch return Error.LengthOverflow;
    return addU32(try addU32(decommit_header_words, metadata), queries);
}

fn friLayerCount(max_log_degree_bound: u32, final_log: u32, fold_step: u32) Error!u32 {
    if (fold_step == 0 or max_log_degree_bound <= final_log or
        fold_step > max_log_degree_bound - final_log)
        return Error.InvalidProtocolGeometry;
    const folds = max_log_degree_bound - final_log;
    return 1 + (folds - 1) / fold_step;
}

fn addU32(left: u32, right: u32) Error!u32 {
    return std.math.add(u32, left, right) catch Error.LengthOverflow;
}

test "compact protocol geometry derives SN2 and Fib-like FRI counts" {
    const sn2 = RuntimeProtocolGeometryV1.sn2();
    try sn2.validate();
    try std.testing.expectEqual(@as(u32, 8), sn2.fri_tree_count);
    try std.testing.expectEqual(@as(u32, 340), try minimumDecommitmentWords(12, 70));

    var fib = sn2;
    fib.max_log_degree_bound = 20;
    fib.fri_tree_count = 7;
    fib.decommitment_record_count = 11;
    try fib.validate();
    try std.testing.expectEqual(@as(u32, 324), try minimumDecommitmentWords(11, 70));
}

test "compact runtime geometry accepts the resident decoder contract" {
    const ResidentGeometry = struct {
        trace_tree_count: usize = 4,
        fri_layer_count: usize = 7,
        max_log_degree_bound: u32 = 20,
        query_pow_bits: u32 = 26,
        interaction_pow_bits: u32 = 24,
        log_blowup_factor: u32 = 1,
        query_count: usize = 70,
        log_last_layer_degree_bound: u32 = 0,
        fold_step: u32 = 3,
        lifting_log_size: ?u32 = null,

        pub fn validate(_: @This()) !void {}
    };
    const converted = try RuntimeProtocolGeometryV1.fromResident(ResidentGeometry{});
    try std.testing.expectEqual(@as(u32, 4), converted.commitment_count);
    try std.testing.expectEqual(@as(u32, 7), converted.fri_tree_count);
    try std.testing.expectEqual(@as(u32, 11), converted.decommitment_record_count);
    try std.testing.expectEqual(@as(u32, 20), converted.max_log_degree_bound);
}
