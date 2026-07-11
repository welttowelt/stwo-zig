const std = @import("std");

const kernel_source: [:0]const u8 = @embedFile("kernels.metal") ++ "\x00";

extern fn stwo_zig_metal_runtime_create(
    source: [*:0]const u8,
    error_message: [*]u8,
    error_message_len: usize,
) ?*anyopaque;
extern fn stwo_zig_metal_runtime_destroy(runtime: ?*anyopaque) void;
extern fn stwo_zig_metal_buffer_create(
    runtime: *anyopaque,
    byte_length: usize,
    contents: **anyopaque,
    error_message: [*]u8,
    error_message_len: usize,
) ?*anyopaque;
extern fn stwo_zig_metal_buffer_destroy(buffer: ?*anyopaque) void;
extern fn stwo_zig_metal_clear_arena_ranges(
    runtime: *anyopaque,
    arena: *anyopaque,
    ranges: [*]const [2]u32,
    range_count: u32,
    max_length: u32,
    error_message: [*]u8,
    error_message_len: usize,
) bool;
extern fn stwo_zig_metal_witness_feed_prepare(
    runtime: *anyopaque,
    descriptors: [*]const u32,
    descriptor_count: u32,
    luts: [*]const u32,
    lut_words: usize,
    destination_offsets: [*]const u32,
    destination_count: usize,
    source_offsets: [*]const u32,
    source_count: usize,
    clear_ranges: [*]const [2]u32,
    clear_range_count: u32,
    clear_max_length: u32,
    error_message: [*]u8,
    error_message_len: usize,
) ?*anyopaque;
extern fn stwo_zig_metal_witness_feed_plan_destroy(plan: ?*anyopaque) void;
extern fn stwo_zig_metal_witness_feed_batch_prepare(
    runtime: *anyopaque,
    plans: [*]const *anyopaque,
    column_lengths: [*]const u32,
    plan_count: u32,
    clear_ranges: [*]const [2]u32,
    clear_range_count: u32,
    error_message: [*]u8,
    error_message_len: usize,
) ?*anyopaque;
extern fn stwo_zig_metal_witness_feed_batch_destroy(batch: ?*anyopaque) void;
extern fn stwo_zig_metal_witness_feed_batch_counts_prepared(
    runtime: *anyopaque,
    arena: *anyopaque,
    batch: *anyopaque,
    gpu_milliseconds: *f64,
    error_message: [*]u8,
    error_message_len: usize,
) bool;
extern fn stwo_zig_metal_circle_lde_prepare(
    runtime: *anyopaque,
    source_offsets: [*]const u32,
    destination_offsets: [*]const u32,
    column_count: u32,
    base_log_size: u32,
    extended_log_size: u32,
    twiddle_offset_words: u32,
    error_message: [*]u8,
    error_message_len: usize,
) ?*anyopaque;
extern fn stwo_zig_metal_circle_lde_plan_destroy(plan: ?*anyopaque) void;
extern fn stwo_zig_metal_circle_lde_prepared(
    runtime: *anyopaque,
    arena: *anyopaque,
    plan: *anyopaque,
    gpu_milliseconds: *f64,
    error_message: [*]u8,
    error_message_len: usize,
) bool;
extern fn stwo_zig_metal_circle_ifft_prepare(
    runtime: *anyopaque,
    source_offsets: [*]const u32,
    destination_offsets: [*]const u32,
    column_count: u32,
    log_size: u32,
    twiddle_offset_words: u32,
    scale_factor: u32,
    error_message: [*]u8,
    error_message_len: usize,
) ?*anyopaque;
extern fn stwo_zig_metal_circle_ifft_plan_destroy(plan: ?*anyopaque) void;
extern fn stwo_zig_metal_circle_ifft_prepared(
    runtime: *anyopaque,
    arena: *anyopaque,
    plan: *anyopaque,
    gpu_milliseconds: *f64,
    error_message: [*]u8,
    error_message_len: usize,
) bool;
extern fn stwo_zig_metal_fixed_table_prepare(
    runtime: *anyopaque,
    descriptors: [*]const u32,
    descriptor_words: u32,
    source_offsets: [*]const u32,
    source_count: u32,
    multiplicity_offsets: [*]const u32,
    multiplicity_count: u32,
    destination_offset: u32,
    row_count: u32,
    error_message: [*]u8,
    error_message_len: usize,
) ?*anyopaque;
extern fn stwo_zig_metal_fixed_table_plan_destroy(plan: ?*anyopaque) void;
extern fn stwo_zig_metal_fixed_table_batch_prepare(
    runtime: *anyopaque,
    plans: [*]const *anyopaque,
    plan_count: u32,
    error_message: [*]u8,
    error_message_len: usize,
) ?*anyopaque;
extern fn stwo_zig_metal_fixed_table_batch_destroy(batch: ?*anyopaque) void;
extern fn stwo_zig_metal_fixed_table_batch_prepared(
    runtime: *anyopaque,
    arena: *anyopaque,
    batch: *anyopaque,
    gpu_milliseconds: *f64,
    error_message: [*]u8,
    error_message_len: usize,
) bool;
extern fn stwo_zig_metal_merkle_parent_chain_prepare(
    runtime: *anyopaque,
    child_offsets: [*]const u32,
    destination_offsets: [*]const u32,
    parent_counts: [*]const u32,
    level_count: u32,
    node_seed: *const [8]u32,
    error_message: [*]u8,
    error_message_len: usize,
) ?*anyopaque;
extern fn stwo_zig_metal_merkle_parent_chain_destroy(plan: ?*anyopaque) void;
extern fn stwo_zig_metal_merkle_parent_chain_prepared(
    runtime: *anyopaque,
    arena: *anyopaque,
    plan: *anyopaque,
    gpu_milliseconds: *f64,
    error_message: [*]u8,
    error_message_len: usize,
) bool;
extern fn stwo_zig_metal_ec_op_prepare(
    runtime: *anyopaque,
    execution_offsets: *const [37]u32,
    trace_offsets: *const [273]u32,
    partial_offsets: *const [127]u32,
    multiplicity_offsets: *const [4]u32,
    lookup_offset: u32,
    segment_offset: u32,
    scratch_offset: u32,
    row_count: u32,
    error_message: [*]u8,
    error_message_len: usize,
) ?*anyopaque;
extern fn stwo_zig_metal_ec_op_plan_destroy(plan: ?*anyopaque) void;
extern fn stwo_zig_metal_ec_op_prepared(
    runtime: *anyopaque,
    arena: *anyopaque,
    plan: *anyopaque,
    gpu_milliseconds: *f64,
    error_message: [*]u8,
    error_message_len: usize,
) bool;
extern fn stwo_zig_metal_relation_prepare(
    runtime: *anyopaque,
    geometry: [*]const u32,
    instance_count: u32,
    source_offsets: [*]const u32,
    source_count: u32,
    descriptors: [*]const u32,
    descriptor_words: u32,
    output_offsets: [*]const u32,
    output_count: u32,
    total_blocks: u32,
    alpha_offset_words: u32,
    z_offset_words: u32,
    scratch_offset_words: u32,
    error_message: [*]u8,
    error_message_len: usize,
) ?*anyopaque;
extern fn stwo_zig_metal_relation_plan_destroy(plan: ?*anyopaque) void;
extern fn stwo_zig_metal_relation_prepared(
    runtime: *anyopaque,
    arena: *anyopaque,
    plan: *anyopaque,
    gpu_milliseconds: *f64,
    error_message: [*]u8,
    error_message_len: usize,
) bool;
extern fn stwo_zig_metal_witness_feed_counts_prepared(
    runtime: *anyopaque,
    arena: *anyopaque,
    plan: *anyopaque,
    column_length: u32,
    gpu_milliseconds: *f64,
    error_message: [*]u8,
    error_message_len: usize,
) bool;
extern fn stwo_zig_metal_fri_fold_circle(
    runtime: *anyopaque,
    source: [*]const u32,
    source_count: u32,
    inverse_y: [*]const u32,
    alpha: *const [4]u32,
    destination: [*]u32,
    gpu_milliseconds: *f64,
    error_message: [*]u8,
    error_message_len: usize,
) bool;
extern fn stwo_zig_metal_fri_fold_line(
    runtime: *anyopaque,
    source: [*]const u32,
    source_count: u32,
    inverse_x: [*]const u32,
    alpha: *const [4]u32,
    destination: [*]u32,
    gpu_milliseconds: *f64,
    error_message: [*]u8,
    error_message_len: usize,
) bool;
extern fn stwo_zig_metal_qm31_to_coordinates(
    runtime: *anyopaque,
    source: [*]const u32,
    value_count: u32,
    destination: [*]u32,
    gpu_milliseconds: *f64,
    error_message: [*]u8,
    error_message_len: usize,
) bool;
extern fn stwo_zig_metal_felt252_oracle(
    runtime: *anyopaque,
    inputs: [*]const u32,
    count: u32,
    outputs: [*]u32,
    gpu_milliseconds: *f64,
    error_message: [*]u8,
    error_message_len: usize,
) bool;
extern fn stwo_zig_metal_merkle_commit(
    runtime: *anyopaque,
    columns: [*]const [*]const u32,
    column_lengths: [*]const usize,
    column_log_sizes: [*]const u32,
    column_count: u32,
    lifting_log_size: u32,
    leaf_seed: *const [8]u32,
    node_seed: *const [8]u32,
    error_message: [*]u8,
    error_message_len: usize,
) ?*anyopaque;
extern fn stwo_zig_metal_tree_destroy(tree: ?*anyopaque) void;
extern fn stwo_zig_metal_tree_root(
    tree: *anyopaque,
    root: *[32]u8,
    gpu_milliseconds: *f64,
) bool;
extern fn stwo_zig_metal_tree_copy_layers(
    runtime: *anyopaque,
    tree: *anyopaque,
    destination: [*]u8,
    destination_len: usize,
    error_message: [*]u8,
    error_message_len: usize,
) bool;
extern fn stwo_zig_metal_tree_copy_hashes(
    runtime: *anyopaque,
    tree: *anyopaque,
    layer_log_size: u32,
    indices: [*]const u32,
    index_count: u32,
    destination: [*]u8,
    error_message: [*]u8,
    error_message_len: usize,
) bool;
extern fn stwo_zig_metal_compute_quotients(
    runtime: *anyopaque,
    flat_views: [*]const u32,
    flat_views_len: usize,
    raw_columns: [*]const [*]const u32,
    raw_column_lengths: [*]const usize,
    raw_column_count: u32,
    views: *const anyopaque,
    view_count: u32,
    raw_views: bool,
    sample_components: [*]const u32,
    linear_terms: [*]const u32,
    batch_count: u32,
    domain_x: [*]const u32,
    domain_y: [*]const u32,
    row_count: u32,
    output: [*]u32,
    gpu_milliseconds: *f64,
    error_message: [*]u8,
    error_message_len: usize,
) bool;
extern fn stwo_zig_metal_eval_polynomials(
    runtime: *anyopaque,
    coefficients: [*]const [*]const u32,
    coefficient_lengths: [*]const usize,
    coefficient_column_count: u32,
    coefficient_count: usize,
    factors: [*]const u32,
    factor_word_count: usize,
    basis_tasks: *const anyopaque,
    basis_task_count: u32,
    basis_count: u32,
    tasks: *const anyopaque,
    task_count: u32,
    output_count: u32,
    output: [*]u32,
    gpu_milliseconds: *f64,
    error_message: [*]u8,
    error_message_len: usize,
) bool;
extern fn stwo_zig_metal_circle_transform(
    runtime: *anyopaque,
    columns: [*]const [*]u32,
    column_count: u32,
    log_size: u32,
    twiddles: [*]const u32,
    inverse: bool,
    scale_factor: u32,
    gpu_milliseconds: *f64,
    error_message: [*]u8,
    error_message_len: usize,
) bool;
extern fn stwo_zig_metal_circle_lde(
    runtime: *anyopaque,
    source_columns: [*]const [*]const u32,
    base_columns: [*]const [*]u32,
    extended_columns: [*]const [*]u32,
    column_count: u32,
    base_log_size: u32,
    extended_log_size: u32,
    inverse_twiddles: [*]const u32,
    forward_twiddles: [*]const u32,
    scale_factor: u32,
    gpu_milliseconds: *f64,
    error_message: [*]u8,
    error_message_len: usize,
) bool;

pub const MetalError = error{
    RuntimeInitializationFailed,
    CommitmentFailed,
    RootReadFailed,
    InvalidColumns,
    ColumnTooLarge,
    QuotientFailed,
    TimerUnsupported,
    PolynomialEvaluationFailed,
    CircleTransformFailed,
    WitnessFeedFailed,
};

pub const Runtime = struct {
    handle: *anyopaque,

    pub fn init() MetalError!Runtime {
        var message: [1024]u8 = [_]u8{0} ** 1024;
        const handle = stwo_zig_metal_runtime_create(kernel_source.ptr, &message, message.len) orelse {
            std.log.err("Metal initialization failed: {s}", .{std.mem.sliceTo(&message, 0)});
            return MetalError.RuntimeInitializationFailed;
        };
        return .{ .handle = handle };
    }

    pub fn deinit(self: *Runtime) void {
        stwo_zig_metal_runtime_destroy(self.handle);
        self.* = undefined;
    }

    pub fn allocateResidentBuffer(self: *Runtime, byte_length: usize) MetalError!ResidentBuffer {
        var contents: *anyopaque = undefined;
        var message: [1024]u8 = [_]u8{0} ** 1024;
        const handle = stwo_zig_metal_buffer_create(
            self.handle,
            byte_length,
            &contents,
            &message,
            message.len,
        ) orelse {
            std.log.err("Metal resident buffer allocation failed: {s}", .{std.mem.sliceTo(&message, 0)});
            return MetalError.RuntimeInitializationFailed;
        };
        return .{ .handle = handle, .contents = contents, .byte_length = byte_length };
    }

    pub fn clearArenaRanges(self: *Runtime, arena: ResidentBuffer, ranges: []const [2]u32) MetalError!void {
        if (ranges.len == 0) return;
        var max_length: u32 = 0;
        for (ranges) |range| {
            max_length = @max(max_length, range[1]);
            const end = @as(u64, range[0]) + range[1];
            if (end * @sizeOf(u32) > arena.byte_length) return MetalError.WitnessFeedFailed;
        }
        var message: [1024]u8 = [_]u8{0} ** 1024;
        if (!stwo_zig_metal_clear_arena_ranges(self.handle, arena.handle, ranges.ptr, @intCast(ranges.len), max_length, &message, message.len)) {
            std.log.err("Metal arena clear failed: {s}", .{std.mem.sliceTo(&message, 0)});
            return MetalError.WitnessFeedFailed;
        }
    }

    pub fn witnessFeedCounts(
        self: *Runtime,
        arena: ResidentBuffer,
        column_length: u32,
        descriptors: []const u32,
        luts: []const u32,
        destination_offsets: []const u32,
        source_offsets: []const u32,
        clear_ranges: []const [2]u32,
    ) MetalError!f64 {
        if (descriptors.len == 0 or descriptors.len % 14 != 0 or column_length == 0 or destination_offsets.len == 0 or source_offsets.len == 0)
            return MetalError.WitnessFeedFailed;
        const arena_words = arena.byte_length / @sizeOf(u32);
        for (source_offsets) |offset| {
            if (@as(u64, offset) + column_length > arena_words) return MetalError.WitnessFeedFailed;
        }
        var descriptor_index: usize = 0;
        while (descriptor_index < descriptors.len) : (descriptor_index += 14) {
            const e = descriptors[descriptor_index .. descriptor_index + 14];
            const source_count: u32 = if (e[11] == 1) 1 else if (e[11] == 2 or e[11] == 3) 3 else e[1];
            if (@as(u64, e[0]) + source_count > source_offsets.len) return MetalError.WitnessFeedFailed;
            const destination_count: u32 = if (e[11] == 3) 16 else e[7] + 1;
            if (@as(u64, e[10]) + destination_count > destination_offsets.len) return MetalError.WitnessFeedFailed;
            for (destination_offsets[e[10] .. e[10] + destination_count]) |offset| {
                if (@as(u64, offset) + e[8] > arena_words) return MetalError.WitnessFeedFailed;
            }
            if (e[11] == 1) {
                if (@as(u64, e[13]) + e[7] >= destination_offsets.len or
                    @as(u64, destination_offsets[e[13] + e[7]]) + e[12] > arena_words)
                    return MetalError.WitnessFeedFailed;
            }
            if (e[9] != std.math.maxInt(u32)) {
                const required_lut_words: u64 = if (e[11] == 2)
                    @as(u64, 1) << @intCast(2 * e[2])
                else
                    e[8];
                if (@as(u64, e[9]) + required_lut_words > luts.len) return MetalError.WitnessFeedFailed;
            }
        }
        const descriptor_count: u32 = @intCast(descriptors.len / 14);
        _ = descriptor_count;
        var plan = try self.prepareWitnessFeed(descriptors, luts, destination_offsets, source_offsets, clear_ranges);
        defer plan.deinit();
        return self.witnessFeedCountsPrepared(arena, column_length, plan);
    }

    pub fn prepareWitnessFeed(
        self: *Runtime,
        descriptors: []const u32,
        luts: []const u32,
        destination_offsets: []const u32,
        source_offsets: []const u32,
        clear_ranges: []const [2]u32,
    ) MetalError!WitnessFeedPlan {
        if (descriptors.len == 0 or descriptors.len % 14 != 0 or destination_offsets.len == 0 or source_offsets.len == 0 or clear_ranges.len == 0)
            return MetalError.WitnessFeedFailed;
        var clear_max_length: u32 = 0;
        for (clear_ranges) |range| {
            if (range[1] == 0) return MetalError.WitnessFeedFailed;
            clear_max_length = @max(clear_max_length, range[1]);
        }
        const empty_lut = [_]u32{0};
        const lut_words = if (luts.len == 0) empty_lut[0..] else luts;
        var message: [1024]u8 = [_]u8{0} ** 1024;
        const handle = stwo_zig_metal_witness_feed_prepare(
            self.handle,
            descriptors.ptr,
            @intCast(descriptors.len / 14),
            lut_words.ptr,
            luts.len,
            destination_offsets.ptr,
            destination_offsets.len,
            source_offsets.ptr,
            source_offsets.len,
            clear_ranges.ptr,
            @intCast(clear_ranges.len),
            clear_max_length,
            &message,
            message.len,
        ) orelse {
            std.log.err("Metal witness feed preparation failed: {s}", .{std.mem.sliceTo(&message, 0)});
            return MetalError.WitnessFeedFailed;
        };
        return .{ .handle = handle };
    }

    pub fn witnessFeedCountsPrepared(
        self: *Runtime,
        arena: ResidentBuffer,
        column_length: u32,
        plan: WitnessFeedPlan,
    ) MetalError!f64 {
        if (column_length == 0) return MetalError.WitnessFeedFailed;
        var gpu_ms: f64 = 0;
        var message: [1024]u8 = [_]u8{0} ** 1024;
        if (!stwo_zig_metal_witness_feed_counts_prepared(
            self.handle,
            arena.handle,
            plan.handle,
            column_length,
            &gpu_ms,
            &message,
            message.len,
        )) {
            std.log.err("Metal witness feed failed: {s}", .{std.mem.sliceTo(&message, 0)});
            return MetalError.WitnessFeedFailed;
        }
        return gpu_ms;
    }

    pub fn prepareWitnessFeedBatch(
        self: *Runtime,
        plans: []const WitnessFeedPlan,
        column_lengths: []const u32,
        clear_ranges: []const [2]u32,
    ) MetalError!WitnessFeedBatchPlan {
        if (plans.len == 0 or plans.len > 256 or plans.len != column_lengths.len or clear_ranges.len == 0)
            return MetalError.WitnessFeedFailed;
        var handles: [256]*anyopaque = undefined;
        for (plans, handles[0..plans.len]) |plan, *handle| handle.* = plan.handle;
        var message: [1024]u8 = [_]u8{0} ** 1024;
        const handle = stwo_zig_metal_witness_feed_batch_prepare(
            self.handle,
            handles[0..plans.len].ptr,
            column_lengths.ptr,
            @intCast(plans.len),
            clear_ranges.ptr,
            @intCast(clear_ranges.len),
            &message,
            message.len,
        ) orelse {
            std.log.err("Metal witness feed batch preparation failed: {s}", .{std.mem.sliceTo(&message, 0)});
            return MetalError.WitnessFeedFailed;
        };
        return .{ .handle = handle };
    }

    pub fn witnessFeedBatchCountsPrepared(
        self: *Runtime,
        arena: ResidentBuffer,
        batch: WitnessFeedBatchPlan,
    ) MetalError!f64 {
        var gpu_ms: f64 = 0;
        var message: [1024]u8 = [_]u8{0} ** 1024;
        if (!stwo_zig_metal_witness_feed_batch_counts_prepared(
            self.handle,
            arena.handle,
            batch.handle,
            &gpu_ms,
            &message,
            message.len,
        )) {
            std.log.err("Metal witness feed batch failed: {s}", .{std.mem.sliceTo(&message, 0)});
            return MetalError.WitnessFeedFailed;
        }
        return gpu_ms;
    }

    pub fn prepareCircleLde(
        self: *Runtime,
        source_offsets: []const u32,
        destination_offsets: []const u32,
        base_log_size: u32,
        extended_log_size: u32,
        twiddle_offset_words: u32,
    ) MetalError!CircleLdePlan {
        if (source_offsets.len == 0 or source_offsets.len != destination_offsets.len or
            base_log_size < 3 or extended_log_size <= base_log_size or extended_log_size >= 31)
            return MetalError.CircleTransformFailed;
        var message: [1024]u8 = [_]u8{0} ** 1024;
        const handle = stwo_zig_metal_circle_lde_prepare(
            self.handle,
            source_offsets.ptr,
            destination_offsets.ptr,
            @intCast(source_offsets.len),
            base_log_size,
            extended_log_size,
            twiddle_offset_words,
            &message,
            message.len,
        ) orelse {
            std.log.err("Metal sparse circle LDE preparation failed: {s}", .{std.mem.sliceTo(&message, 0)});
            return MetalError.CircleTransformFailed;
        };
        return .{ .handle = handle };
    }

    pub fn circleLdePrepared(self: *Runtime, arena: ResidentBuffer, plan: CircleLdePlan) MetalError!f64 {
        var gpu_ms: f64 = 0;
        var message: [1024]u8 = [_]u8{0} ** 1024;
        if (!stwo_zig_metal_circle_lde_prepared(
            self.handle,
            arena.handle,
            plan.handle,
            &gpu_ms,
            &message,
            message.len,
        )) {
            std.log.err("Metal sparse circle LDE failed: {s}", .{std.mem.sliceTo(&message, 0)});
            return MetalError.CircleTransformFailed;
        }
        return gpu_ms;
    }

    pub fn prepareCircleIfft(
        self: *Runtime,
        source_offsets: []const u32,
        destination_offsets: []const u32,
        log_size: u32,
        twiddle_offset_words: u32,
        scale_factor: u32,
    ) MetalError!CircleIfftPlan {
        if (source_offsets.len == 0 or source_offsets.len != destination_offsets.len or log_size < 3 or log_size >= 31)
            return MetalError.CircleTransformFailed;
        var message: [1024]u8 = [_]u8{0} ** 1024;
        const handle = stwo_zig_metal_circle_ifft_prepare(
            self.handle,
            source_offsets.ptr,
            destination_offsets.ptr,
            @intCast(source_offsets.len),
            log_size,
            twiddle_offset_words,
            scale_factor,
            &message,
            message.len,
        ) orelse {
            std.log.err("Metal sparse circle IFFT preparation failed: {s}", .{std.mem.sliceTo(&message, 0)});
            return MetalError.CircleTransformFailed;
        };
        return .{ .handle = handle };
    }

    pub fn circleIfftPrepared(self: *Runtime, arena: ResidentBuffer, plan: CircleIfftPlan) MetalError!f64 {
        var gpu_ms: f64 = 0;
        var message: [1024]u8 = [_]u8{0} ** 1024;
        if (!stwo_zig_metal_circle_ifft_prepared(
            self.handle,
            arena.handle,
            plan.handle,
            &gpu_ms,
            &message,
            message.len,
        )) {
            std.log.err("Metal sparse circle IFFT failed: {s}", .{std.mem.sliceTo(&message, 0)});
            return MetalError.CircleTransformFailed;
        }
        return gpu_ms;
    }

    pub fn prepareFixedTable(
        self: *Runtime,
        descriptors: []const u32,
        source_offsets: []const u32,
        multiplicity_offsets: []const u32,
        destination_offset: u32,
        row_count: u32,
    ) MetalError!FixedTablePlan {
        if (descriptors.len == 0 or descriptors.len % 4 != 0 or multiplicity_offsets.len == 0 or row_count == 0)
            return MetalError.WitnessFeedFailed;
        var message: [1024]u8 = [_]u8{0} ** 1024;
        const handle = stwo_zig_metal_fixed_table_prepare(
            self.handle,
            descriptors.ptr,
            @intCast(descriptors.len),
            source_offsets.ptr,
            @intCast(source_offsets.len),
            multiplicity_offsets.ptr,
            @intCast(multiplicity_offsets.len),
            destination_offset,
            row_count,
            &message,
            message.len,
        ) orelse {
            std.log.err("Metal fixed-table preparation failed: {s}", .{std.mem.sliceTo(&message, 0)});
            return MetalError.WitnessFeedFailed;
        };
        return .{ .handle = handle };
    }

    pub fn prepareFixedTableBatch(self: *Runtime, plans: []const FixedTablePlan) MetalError!FixedTableBatchPlan {
        if (plans.len == 0 or plans.len > 64) return MetalError.WitnessFeedFailed;
        var handles: [64]*anyopaque = undefined;
        for (plans, handles[0..plans.len]) |plan, *handle| handle.* = plan.handle;
        var message: [1024]u8 = [_]u8{0} ** 1024;
        const handle = stwo_zig_metal_fixed_table_batch_prepare(
            self.handle,
            handles[0..plans.len].ptr,
            @intCast(plans.len),
            &message,
            message.len,
        ) orelse {
            std.log.err("Metal fixed-table batch preparation failed: {s}", .{std.mem.sliceTo(&message, 0)});
            return MetalError.WitnessFeedFailed;
        };
        return .{ .handle = handle };
    }

    pub fn fixedTableBatchPrepared(self: *Runtime, arena: ResidentBuffer, batch: FixedTableBatchPlan) MetalError!f64 {
        var gpu_ms: f64 = 0;
        var message: [1024]u8 = [_]u8{0} ** 1024;
        if (!stwo_zig_metal_fixed_table_batch_prepared(self.handle, arena.handle, batch.handle, &gpu_ms, &message, message.len)) {
            std.log.err("Metal fixed-table batch failed: {s}", .{std.mem.sliceTo(&message, 0)});
            return MetalError.WitnessFeedFailed;
        }
        return gpu_ms;
    }

    pub fn prepareMerkleParentChain(
        self: *Runtime,
        child_offsets: []const u32,
        destination_offsets: []const u32,
        parent_counts: []const u32,
        node_seed: [8]u32,
    ) MetalError!MerkleParentChainPlan {
        if (child_offsets.len == 0 or child_offsets.len != destination_offsets.len or child_offsets.len != parent_counts.len)
            return MetalError.CommitmentFailed;
        var message: [1024]u8 = [_]u8{0} ** 1024;
        const handle = stwo_zig_metal_merkle_parent_chain_prepare(
            self.handle,
            child_offsets.ptr,
            destination_offsets.ptr,
            parent_counts.ptr,
            @intCast(child_offsets.len),
            &node_seed,
            &message,
            message.len,
        ) orelse {
            std.log.err("Metal Merkle parent-chain preparation failed: {s}", .{std.mem.sliceTo(&message, 0)});
            return MetalError.CommitmentFailed;
        };
        return .{ .handle = handle };
    }

    pub fn merkleParentChainPrepared(self: *Runtime, arena: ResidentBuffer, plan: MerkleParentChainPlan) MetalError!f64 {
        var gpu_ms: f64 = 0;
        var message: [1024]u8 = [_]u8{0} ** 1024;
        if (!stwo_zig_metal_merkle_parent_chain_prepared(self.handle, arena.handle, plan.handle, &gpu_ms, &message, message.len)) {
            std.log.err("Metal Merkle parent-chain failed: {s}", .{std.mem.sliceTo(&message, 0)});
            return MetalError.CommitmentFailed;
        }
        return gpu_ms;
    }

    pub fn prepareEcOp(
        self: *Runtime,
        execution_offsets: [37]u32,
        trace_offsets: [273]u32,
        partial_offsets: [127]u32,
        multiplicity_offsets: [4]u32,
        lookup_offset: u32,
        segment_offset: u32,
        scratch_offset: u32,
        row_count: u32,
    ) MetalError!EcOpPlan {
        if (row_count < 16 or !std.math.isPowerOfTwo(row_count)) return MetalError.WitnessFeedFailed;
        var message: [1024]u8 = [_]u8{0} ** 1024;
        const handle = stwo_zig_metal_ec_op_prepare(
            self.handle,
            &execution_offsets,
            &trace_offsets,
            &partial_offsets,
            &multiplicity_offsets,
            lookup_offset,
            segment_offset,
            scratch_offset,
            row_count,
            &message,
            message.len,
        ) orelse {
            std.log.err("Metal EC-op preparation failed: {s}", .{std.mem.sliceTo(&message, 0)});
            return MetalError.WitnessFeedFailed;
        };
        return .{ .handle = handle };
    }

    pub fn ecOpPrepared(self: *Runtime, arena: ResidentBuffer, plan: EcOpPlan) MetalError!f64 {
        var gpu_ms: f64 = 0;
        var message: [1024]u8 = [_]u8{0} ** 1024;
        if (!stwo_zig_metal_ec_op_prepared(self.handle, arena.handle, plan.handle, &gpu_ms, &message, message.len)) {
            std.log.err("Metal EC-op execution failed: {s}", .{std.mem.sliceTo(&message, 0)});
            return MetalError.WitnessFeedFailed;
        }
        return gpu_ms;
    }

    pub fn prepareRelation(
        self: *Runtime,
        geometry: []const u32,
        source_offsets: []const u32,
        descriptors: []const u32,
        output_offsets: []const u32,
        total_blocks: u32,
        alpha_offset_words: u32,
        z_offset_words: u32,
        scratch_offset_words: u32,
    ) MetalError!RelationPlan {
        if (geometry.len == 0 or geometry.len % 10 != 0 or source_offsets.len == 0 or
            descriptors.len == 0 or descriptors.len % 16 != 0 or output_offsets.len == 0 or total_blocks == 0)
            return MetalError.PolynomialEvaluationFailed;
        var message: [1024]u8 = [_]u8{0} ** 1024;
        const handle = stwo_zig_metal_relation_prepare(
            self.handle,
            geometry.ptr,
            @intCast(geometry.len / 10),
            source_offsets.ptr,
            @intCast(source_offsets.len),
            descriptors.ptr,
            @intCast(descriptors.len),
            output_offsets.ptr,
            @intCast(output_offsets.len),
            total_blocks,
            alpha_offset_words,
            z_offset_words,
            scratch_offset_words,
            &message,
            message.len,
        ) orelse {
            std.log.err("Metal relation preparation failed: {s}", .{std.mem.sliceTo(&message, 0)});
            return MetalError.PolynomialEvaluationFailed;
        };
        return .{ .handle = handle };
    }

    pub fn relationPrepared(self: *Runtime, arena: ResidentBuffer, plan: RelationPlan) MetalError!f64 {
        var gpu_ms: f64 = 0;
        var message: [1024]u8 = [_]u8{0} ** 1024;
        if (!stwo_zig_metal_relation_prepared(
            self.handle,
            arena.handle,
            plan.handle,
            &gpu_ms,
            &message,
            message.len,
        )) {
            std.log.err("Metal relation execution failed: {s}", .{std.mem.sliceTo(&message, 0)});
            return MetalError.PolynomialEvaluationFailed;
        }
        return gpu_ms;
    }

    pub fn foldFriCircle(
        self: *Runtime,
        source: [*]const u32,
        source_count: u32,
        inverse_y: []const u32,
        alpha: [4]u32,
        destination: [*]u32,
    ) MetalError!f64 {
        if (inverse_y.len != source_count / 2) return MetalError.InvalidColumns;
        var gpu_ms: f64 = 0;
        var message: [1024]u8 = [_]u8{0} ** 1024;
        if (!stwo_zig_metal_fri_fold_circle(self.handle, source, source_count, inverse_y.ptr, &alpha, destination, &gpu_ms, &message, message.len)) {
            std.log.err("Metal FRI circle fold failed: {s}", .{std.mem.sliceTo(&message, 0)});
            return MetalError.CircleTransformFailed;
        }
        return gpu_ms;
    }

    pub fn foldFriLine(
        self: *Runtime,
        source: [*]const u32,
        source_count: u32,
        inverse_x: []const u32,
        alpha: [4]u32,
        destination: [*]u32,
    ) MetalError!f64 {
        if (inverse_x.len != source_count / 2) return MetalError.InvalidColumns;
        var gpu_ms: f64 = 0;
        var message: [1024]u8 = [_]u8{0} ** 1024;
        if (!stwo_zig_metal_fri_fold_line(self.handle, source, source_count, inverse_x.ptr, &alpha, destination, &gpu_ms, &message, message.len)) {
            std.log.err("Metal FRI line fold failed: {s}", .{std.mem.sliceTo(&message, 0)});
            return MetalError.CircleTransformFailed;
        }
        return gpu_ms;
    }

    pub fn qm31ToCoordinates(
        self: *Runtime,
        source: [*]const u32,
        value_count: u32,
        destination: [*]u32,
    ) MetalError!f64 {
        var gpu_ms: f64 = 0;
        var message: [1024]u8 = [_]u8{0} ** 1024;
        if (!stwo_zig_metal_qm31_to_coordinates(self.handle, source, value_count, destination, &gpu_ms, &message, message.len)) {
            std.log.err("Metal QM31 coordinate conversion failed: {s}", .{std.mem.sliceTo(&message, 0)});
            return MetalError.CircleTransformFailed;
        }
        return gpu_ms;
    }

    pub fn felt252Oracle(self: *Runtime, inputs: []const u32, outputs: []u32) MetalError!f64 {
        if (inputs.len == 0 or inputs.len % 16 != 0 or outputs.len != inputs.len) return MetalError.InvalidColumns;
        var gpu_ms: f64 = 0;
        var message: [1024]u8 = [_]u8{0} ** 1024;
        if (!stwo_zig_metal_felt252_oracle(
            self.handle,
            inputs.ptr,
            @intCast(inputs.len / 16),
            outputs.ptr,
            &gpu_ms,
            &message,
            message.len,
        )) {
            std.log.err("Metal Felt252 oracle failed: {s}", .{std.mem.sliceTo(&message, 0)});
            return MetalError.PolynomialEvaluationFailed;
        }
        return gpu_ms;
    }

    pub fn commitColumns(
        self: *Runtime,
        allocator: std.mem.Allocator,
        columns: []const []const u32,
        log_sizes: []const u32,
        lifting_log_size: u32,
        leaf_seed: [8]u32,
        node_seed: [8]u32,
    ) (MetalError || std.mem.Allocator.Error)!Tree {
        if (columns.len == 0 or columns.len != log_sizes.len) return MetalError.InvalidColumns;

        const order = try allocator.alloc(usize, columns.len);
        defer allocator.free(order);
        for (order, 0..) |*entry, index| entry.* = index;
        const SortContext = struct {
            log_sizes: []const u32,

            fn lessThan(context: @This(), lhs: usize, rhs: usize) bool {
                const lhs_log = context.log_sizes[lhs];
                const rhs_log = context.log_sizes[rhs];
                return lhs_log < rhs_log or (lhs_log == rhs_log and lhs < rhs);
            }
        };
        std.sort.heap(usize, order, SortContext{ .log_sizes = log_sizes }, SortContext.lessThan);

        const sorted_log_sizes = try allocator.alloc(u32, columns.len);
        defer allocator.free(sorted_log_sizes);
        const sorted_columns = try allocator.alloc([*]const u32, columns.len);
        defer allocator.free(sorted_columns);
        const sorted_lengths = try allocator.alloc(usize, columns.len);
        defer allocator.free(sorted_lengths);
        for (order, 0..) |source_index, sorted_index| {
            const column = columns[source_index];
            const log_size = log_sizes[source_index];
            if (log_size > lifting_log_size or column.len != @as(usize, 1) << @intCast(log_size)) {
                return MetalError.InvalidColumns;
            }
            sorted_columns[sorted_index] = column.ptr;
            sorted_lengths[sorted_index] = column.len;
            sorted_log_sizes[sorted_index] = log_size;
        }

        var message: [1024]u8 = [_]u8{0} ** 1024;
        const tree = stwo_zig_metal_merkle_commit(
            self.handle,
            sorted_columns.ptr,
            sorted_lengths.ptr,
            sorted_log_sizes.ptr,
            @intCast(columns.len),
            lifting_log_size,
            &leaf_seed,
            &node_seed,
            &message,
            message.len,
        ) orelse {
            std.log.err("Metal commitment failed: {s}", .{std.mem.sliceTo(&message, 0)});
            return MetalError.CommitmentFailed;
        };
        return .{ .handle = tree, .runtime_handle = self.handle, .log_size = lifting_log_size };
    }

    pub fn computeQuotients(
        self: *Runtime,
        allocator: std.mem.Allocator,
        provider: anytype,
        out: anytype,
    ) (MetalError || std.mem.Allocator.Error)!f64 {
        var total_timer = try std.time.Timer.start();
        const raw_views = provider.raw_columns.len != 0;
        const view_count = if (raw_views)
            provider.prepared.contribution_plan.contributions.len
        else
            provider.combined_views.len;
        const descriptor_width: usize = if (raw_views) 9 else 5;
        const descriptors = try allocator.alloc(u32, view_count * descriptor_width);
        defer allocator.free(descriptors);
        const raw_column_count = if (raw_views)
            provider.prepared.contribution_plan.active_column_indices.len
        else
            0;
        const raw_column_ptrs = try allocator.alloc([*]const u32, raw_column_count);
        defer allocator.free(raw_column_ptrs);
        const raw_column_lengths = try allocator.alloc(usize, raw_column_count);
        defer allocator.free(raw_column_lengths);
        var flat_len: usize = 0;
        if (!raw_views) {
            for (provider.combined_views) |view| flat_len += 4 * view.coordinates[0].len;
        }
        const flat = try allocator.alloc(u32, flat_len);
        defer allocator.free(flat);
        var cursor: usize = 0;
        var descriptor_index: usize = 0;
        if (raw_views) {
            for (
                provider.prepared.contribution_plan.active_column_indices,
                provider.prepared.contribution_plan.ranges,
                0..,
            ) |column_index, contribution_range, raw_column_index| {
                const column = provider.raw_columns[column_index];
                const words = std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(column.values));
                raw_column_ptrs[raw_column_index] = words.ptr;
                raw_column_lengths[raw_column_index] = words.len;
                const log_shift = provider.lifting_log_size - column.log_size;
                const contributions = provider.prepared.contribution_plan.contributions[contribution_range.start .. contribution_range.start + contribution_range.len];
                for (contributions) |contribution| {
                    const coefficient = contribution.value_coeff.toM31Array();
                    const base = descriptor_index * descriptor_width;
                    descriptors[base..][0..9].* = .{
                        @intCast(cursor),
                        @intCast(column.values.len),
                        @intCast(contribution.batch_index),
                        @intCast(log_shift + 1),
                        @intFromBool(column.log_size == provider.lifting_log_size),
                        coefficient[0].v,
                        coefficient[1].v,
                        coefficient[2].v,
                        coefficient[3].v,
                    };
                    descriptor_index += 1;
                }
                cursor += words.len;
            }
        } else {
            for (provider.combined_views, 0..) |view, index| {
                const coordinate_len = view.coordinates[0].len;
                const base = index * descriptor_width;
                descriptors[base..][0..5].* = .{
                    @intCast(cursor),
                    @intCast(coordinate_len),
                    @intCast(view.batch_index),
                    @intCast(view.shift_amt),
                    @intFromBool(view.is_direct),
                };
                for (view.coordinates) |coordinate| {
                    const words = std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(coordinate));
                    @memcpy(flat[cursor .. cursor + words.len], words);
                    cursor += words.len;
                }
            }
        }
        std.debug.assert((raw_views and flat.len == 0) or cursor == flat.len);
        std.debug.assert(descriptor_index == 0 or descriptor_index == view_count);

        const samples = provider.workspace.sample_point_components;
        const packed_ns = total_timer.lap();
        const sample_words = try allocator.alloc(u32, samples.len * 8);
        defer allocator.free(sample_words);
        for (samples, 0..) |sample, index| {
            const base = index * 8;
            sample_words[base..][0..8].* = .{
                sample.prx.a.v, sample.prx.b.v,
                sample.pry.a.v, sample.pry.b.v,
                sample.pix.a.v, sample.pix.b.v,
                sample.piy.a.v, sample.piy.b.v,
            };
        }

        const terms = provider.prepared.quotient_constants.batch_linear_terms;
        const linear_words = try allocator.alloc(u32, terms.len * 8);
        defer allocator.free(linear_words);
        for (terms, 0..) |term, index| {
            const sum_a = term.sum_a.toM31Array();
            const sum_b = term.sum_b.toM31Array();
            const base = index * 8;
            inline for (0..4) |coordinate| {
                linear_words[base + coordinate] = sum_a[coordinate].v;
                linear_words[base + 4 + coordinate] = sum_b[coordinate].v;
            }
        }

        const row_count = provider.domain_size;
        const domain_x = try allocator.alloc(u32, row_count);
        defer allocator.free(domain_x);
        const domain_y = try allocator.alloc(u32, row_count);
        defer allocator.free(domain_y);
        const utils = @import("../../core/utils.zig");
        for (0..row_count) |position| {
            const point = provider.domain.at(utils.bitReverseIndex(position, provider.lifting_log_size));
            domain_x[position] = point.x.v;
            domain_y[position] = point.y.v;
        }

        if (!out.contiguous or out.columns[0].len != row_count) return MetalError.QuotientFailed;
        const output = std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(out.columns[0].ptr[0 .. row_count * 4]));
        const prepared_ns = total_timer.lap();
        var gpu_ms: f64 = 0;
        var message: [1024]u8 = [_]u8{0} ** 1024;
        if (!stwo_zig_metal_compute_quotients(
            self.handle,
            flat.ptr,
            flat.len,
            raw_column_ptrs.ptr,
            raw_column_lengths.ptr,
            @intCast(raw_column_count),
            @ptrCast(descriptors.ptr),
            @intCast(view_count),
            raw_views,
            sample_words.ptr,
            linear_words.ptr,
            @intCast(samples.len),
            domain_x.ptr,
            domain_y.ptr,
            @intCast(row_count),
            output.ptr,
            &gpu_ms,
            &message,
            message.len,
        )) {
            std.log.err("Metal quotient failed: {s}", .{std.mem.sliceTo(&message, 0)});
            return MetalError.QuotientFailed;
        }
        const dispatch_and_copy_ns = total_timer.lap();
        std.log.debug(
            "Metal quotient wall: pack={d:.3}ms prepare={d:.3}ms dispatch-copy={d:.3}ms",
            .{
                @as(f64, @floatFromInt(packed_ns)) / std.time.ns_per_ms,
                @as(f64, @floatFromInt(prepared_ns)) / std.time.ns_per_ms,
                @as(f64, @floatFromInt(dispatch_and_copy_ns)) / std.time.ns_per_ms,
            },
        );
        return gpu_ms;
    }

    pub fn evaluateCoefficientPlans(
        self: *Runtime,
        allocator: std.mem.Allocator,
        coefficients: anytype,
        tree_values: anytype,
        plans: anytype,
    ) (MetalError || std.mem.Allocator.Error)!f64 {
        const coefficient_offsets = try allocator.alloc(u32, coefficients.len);
        defer allocator.free(coefficient_offsets);
        const coefficient_ptrs = try allocator.alloc([*]const u32, coefficients.len);
        defer allocator.free(coefficient_ptrs);
        const coefficient_lengths = try allocator.alloc(usize, coefficients.len);
        defer allocator.free(coefficient_lengths);
        var coefficient_count: usize = 0;
        for (coefficients, 0..) |coefficient, index| {
            const words = std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(coefficient.coefficients()));
            coefficient_offsets[index] = @intCast(coefficient_count);
            coefficient_ptrs[index] = words.ptr;
            coefficient_lengths[index] = words.len;
            coefficient_count += words.len;
        }

        var factor_word_count: usize = 0;
        var task_count: usize = 0;
        var basis_task_count: usize = 0;
        var basis_count: usize = 0;
        for (plans) |plan| {
            factor_word_count += plan.flat_factors.len * 4;
            task_count += plan.column_indices.items.len * plan.normalized_points.len;
            basis_task_count += plan.normalized_points.len;
            basis_count += plan.normalized_points.len * (@as(usize, 1) << @intCast(plan.coeff_log_size));
        }
        const factor_words = try allocator.alloc(u32, factor_word_count);
        defer allocator.free(factor_words);
        const task_words = try allocator.alloc(u32, task_count * 5);
        defer allocator.free(task_words);
        const basis_task_words = try allocator.alloc(u32, basis_task_count * 4);
        defer allocator.free(basis_task_words);

        const output_offsets = try allocator.alloc(u32, tree_values.len);
        defer allocator.free(output_offsets);
        var output_count: usize = 0;
        for (tree_values, 0..) |values, index| {
            output_offsets[index] = @intCast(output_count);
            output_count += values.len;
        }

        var factor_cursor: usize = 0;
        var task_cursor: usize = 0;
        var basis_task_cursor: usize = 0;
        var basis_cursor: usize = 0;
        for (plans) |plan| {
            const plan_factor_start = factor_cursor;
            for (plan.flat_factors) |factor| {
                const coordinates = factor.toM31Array();
                inline for (0..4) |coordinate| {
                    factor_words[factor_cursor] = coordinates[coordinate].v;
                    factor_cursor += 1;
                }
            }
            const plan_basis_start = basis_cursor;
            const coefficient_length = @as(usize, 1) << @intCast(plan.coeff_log_size);
            for (0..plan.normalized_points.len) |point_index| {
                const base = basis_task_cursor * 4;
                basis_task_words[base..][0..4].* = .{
                    @intCast(plan_factor_start + point_index * plan.coeff_log_size * 4),
                    plan.coeff_log_size,
                    @intCast(basis_cursor),
                    @intCast(coefficient_length),
                };
                basis_task_cursor += 1;
                basis_cursor += coefficient_length;
            }
            for (plan.column_indices.items) |column_index| {
                for (0..plan.normalized_points.len) |point_index| {
                    const base = task_cursor * 5;
                    task_words[base..][0..5].* = .{
                        coefficient_offsets[column_index],
                        @intCast(coefficients[column_index].coefficients().len),
                        @intCast(plan_basis_start + point_index * coefficient_length),
                        plan.coeff_log_size,
                        output_offsets[column_index] + @as(u32, @intCast(point_index)),
                    };
                    task_cursor += 1;
                }
            }
        }

        const output_words = try allocator.alloc(u32, output_count * 4);
        defer allocator.free(output_words);
        var gpu_ms: f64 = 0;
        var message: [1024]u8 = [_]u8{0} ** 1024;
        if (!stwo_zig_metal_eval_polynomials(
            self.handle,
            coefficient_ptrs.ptr,
            coefficient_lengths.ptr,
            @intCast(coefficients.len),
            coefficient_count,
            factor_words.ptr,
            factor_words.len,
            @ptrCast(basis_task_words.ptr),
            @intCast(basis_task_count),
            @intCast(basis_count),
            @ptrCast(task_words.ptr),
            @intCast(task_count),
            @intCast(output_count),
            output_words.ptr,
            &gpu_ms,
            &message,
            message.len,
        )) {
            std.log.err("Metal polynomial evaluation failed: {s}", .{std.mem.sliceTo(&message, 0)});
            return MetalError.PolynomialEvaluationFailed;
        }
        for (tree_values, output_offsets) |values, output_offset| {
            for (values, 0..) |*value, point_index| {
                var coordinates: [4]@import("../../core/fields/m31.zig").M31 = undefined;
                inline for (0..4) |coordinate| {
                    coordinates[coordinate].v = output_words[(@as(usize, output_offset) + point_index) * 4 + coordinate];
                }
                value.* = @import("../../core/fields/qm31.zig").QM31.fromM31Array(coordinates);
            }
        }
        return gpu_ms;
    }

    pub fn transformCircle(
        self: *Runtime,
        allocator: std.mem.Allocator,
        columns: []const []@import("../../core/fields/m31.zig").M31,
        twiddles: []const @import("../../core/fields/m31.zig").M31,
        log_size: u32,
        inverse: bool,
    ) (MetalError || std.mem.Allocator.Error)!f64 {
        if (columns.len == 0 or log_size < 3) return MetalError.CircleTransformFailed;
        const expected_len = @as(usize, 1) << @intCast(log_size);
        if (twiddles.len != expected_len / 2) return MetalError.CircleTransformFailed;
        const pointers = try allocator.alloc([*]u32, columns.len);
        defer allocator.free(pointers);
        for (columns, 0..) |column, index| {
            if (column.len != expected_len) return MetalError.CircleTransformFailed;
            pointers[index] = std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(column)).ptr;
        }
        const scale_factor = if (inverse)
            (@import("../../core/fields/m31.zig").M31.fromCanonical(@intCast(expected_len)).inv() catch
                return MetalError.CircleTransformFailed).v
        else
            1;
        const words = std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(twiddles));
        var gpu_ms: f64 = 0;
        var message: [1024]u8 = [_]u8{0} ** 1024;
        if (!stwo_zig_metal_circle_transform(
            self.handle,
            pointers.ptr,
            @intCast(columns.len),
            log_size,
            words.ptr,
            inverse,
            scale_factor,
            &gpu_ms,
            &message,
            message.len,
        )) {
            std.log.err("Metal circle transform failed: {s}", .{std.mem.sliceTo(&message, 0)});
            return MetalError.CircleTransformFailed;
        }
        return gpu_ms;
    }

    /// Allocation-free single-column transform for arena recomputation. The
    /// column pointer already aliases resident shared storage.
    pub fn transformCircleResident(
        self: *Runtime,
        column: []@import("../../core/fields/m31.zig").M31,
        twiddles: []const @import("../../core/fields/m31.zig").M31,
        log_size: u32,
        inverse: bool,
    ) MetalError!f64 {
        if (log_size < 3) return MetalError.CircleTransformFailed;
        const expected_len = @as(usize, 1) << @intCast(log_size);
        if (column.len != expected_len or twiddles.len != expected_len / 2) return MetalError.CircleTransformFailed;
        var pointers = [_][*]u32{std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(column)).ptr};
        const scale_factor = if (inverse)
            (@import("../../core/fields/m31.zig").M31.fromCanonical(@intCast(expected_len)).inv() catch
                return MetalError.CircleTransformFailed).v
        else
            1;
        const words = std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(twiddles));
        var gpu_ms: f64 = 0;
        var message: [1024]u8 = [_]u8{0} ** 1024;
        if (!stwo_zig_metal_circle_transform(
            self.handle,
            &pointers,
            1,
            log_size,
            words.ptr,
            inverse,
            scale_factor,
            &gpu_ms,
            &message,
            message.len,
        )) {
            std.log.err("Metal resident circle recomputation failed: {s}", .{std.mem.sliceTo(&message, 0)});
            return MetalError.CircleTransformFailed;
        }
        return gpu_ms;
    }

    pub fn transformCircleLde(
        self: *Runtime,
        allocator: std.mem.Allocator,
        source_columns: []const []const @import("../../core/fields/m31.zig").M31,
        base_columns: []const []@import("../../core/fields/m31.zig").M31,
        extended_columns: []const []@import("../../core/fields/m31.zig").M31,
        inverse_twiddles: []const @import("../../core/fields/m31.zig").M31,
        forward_twiddles: []const @import("../../core/fields/m31.zig").M31,
        base_log_size: u32,
        extended_log_size: u32,
    ) (MetalError || std.mem.Allocator.Error)!f64 {
        if (base_columns.len == 0 or source_columns.len != base_columns.len or base_columns.len != extended_columns.len or base_log_size < 3 or extended_log_size <= base_log_size) {
            return MetalError.CircleTransformFailed;
        }
        const base_len = @as(usize, 1) << @intCast(base_log_size);
        const extended_len = @as(usize, 1) << @intCast(extended_log_size);
        if (inverse_twiddles.len != base_len / 2 or forward_twiddles.len != extended_len / 2) return MetalError.CircleTransformFailed;
        const base_ptrs = try allocator.alloc([*]u32, base_columns.len);
        defer allocator.free(base_ptrs);
        const source_ptrs = try allocator.alloc([*]const u32, source_columns.len);
        defer allocator.free(source_ptrs);
        const extended_ptrs = try allocator.alloc([*]u32, extended_columns.len);
        defer allocator.free(extended_ptrs);
        for (source_columns, base_columns, extended_columns, 0..) |source, base, extended, index| {
            if (source.len != base_len or base.len != base_len or extended.len != extended_len) return MetalError.CircleTransformFailed;
            source_ptrs[index] = std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(source)).ptr;
            base_ptrs[index] = std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(base)).ptr;
            extended_ptrs[index] = std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(extended)).ptr;
        }
        const inverse_words = std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(inverse_twiddles));
        const forward_words = std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(forward_twiddles));
        const scale_factor = (@import("../../core/fields/m31.zig").M31.fromCanonical(@intCast(base_len)).inv() catch
            return MetalError.CircleTransformFailed).v;
        var gpu_ms: f64 = 0;
        var message: [1024]u8 = [_]u8{0} ** 1024;
        if (!stwo_zig_metal_circle_lde(
            self.handle,
            source_ptrs.ptr,
            base_ptrs.ptr,
            extended_ptrs.ptr,
            @intCast(base_columns.len),
            base_log_size,
            extended_log_size,
            inverse_words.ptr,
            forward_words.ptr,
            scale_factor,
            &gpu_ms,
            &message,
            message.len,
        )) {
            std.log.err("Metal circle LDE failed: {s}", .{std.mem.sliceTo(&message, 0)});
            return MetalError.CircleTransformFailed;
        }
        return gpu_ms;
    }
};

pub const WitnessFeedPlan = struct {
    handle: *anyopaque,

    pub fn deinit(self: *WitnessFeedPlan) void {
        stwo_zig_metal_witness_feed_plan_destroy(self.handle);
        self.* = undefined;
    }
};

pub const WitnessFeedBatchPlan = struct {
    handle: *anyopaque,

    pub fn deinit(self: *WitnessFeedBatchPlan) void {
        stwo_zig_metal_witness_feed_batch_destroy(self.handle);
        self.* = undefined;
    }
};

pub const CircleLdePlan = struct {
    handle: *anyopaque,

    pub fn deinit(self: *CircleLdePlan) void {
        stwo_zig_metal_circle_lde_plan_destroy(self.handle);
        self.* = undefined;
    }
};

pub const CircleIfftPlan = struct {
    handle: *anyopaque,

    pub fn deinit(self: *CircleIfftPlan) void {
        stwo_zig_metal_circle_ifft_plan_destroy(self.handle);
        self.* = undefined;
    }
};

pub const FixedTablePlan = struct {
    handle: *anyopaque,

    pub fn deinit(self: *FixedTablePlan) void {
        stwo_zig_metal_fixed_table_plan_destroy(self.handle);
        self.* = undefined;
    }
};

pub const FixedTableBatchPlan = struct {
    handle: *anyopaque,

    pub fn deinit(self: *FixedTableBatchPlan) void {
        stwo_zig_metal_fixed_table_batch_destroy(self.handle);
        self.* = undefined;
    }
};

pub const MerkleParentChainPlan = struct {
    handle: *anyopaque,

    pub fn deinit(self: *MerkleParentChainPlan) void {
        stwo_zig_metal_merkle_parent_chain_destroy(self.handle);
        self.* = undefined;
    }
};

pub const EcOpPlan = struct {
    handle: *anyopaque,

    pub fn deinit(self: *EcOpPlan) void {
        stwo_zig_metal_ec_op_plan_destroy(self.handle);
        self.* = undefined;
    }
};

pub const RelationPlan = struct {
    handle: *anyopaque,

    pub fn deinit(self: *RelationPlan) void {
        stwo_zig_metal_relation_plan_destroy(self.handle);
        self.* = undefined;
    }
};

pub const ResidentBuffer = struct {
    handle: *anyopaque,
    contents: *anyopaque,
    byte_length: usize,

    pub fn deinit(self: *ResidentBuffer) void {
        destroyOpaque(self.handle);
        self.* = undefined;
    }

    pub fn destroyOpaque(handle: *anyopaque) void {
        stwo_zig_metal_buffer_destroy(handle);
    }
};

pub const Tree = struct {
    handle: *anyopaque,
    runtime_handle: *anyopaque,
    log_size: u32,

    pub fn deinit(self: *Tree) void {
        stwo_zig_metal_tree_destroy(self.handle);
        self.* = undefined;
    }

    pub fn destroyOpaque(handle: *anyopaque) void {
        stwo_zig_metal_tree_destroy(handle);
    }

    pub fn copyHashesOpaque(
        runtime_handle: *anyopaque,
        handle: *anyopaque,
        allocator: std.mem.Allocator,
        layer_log_size: u32,
        indices: []const u32,
    ) anyerror![][32]u8 {
        const tree = Tree{
            .handle = handle,
            .runtime_handle = runtime_handle,
            .log_size = layer_log_size,
        };
        return tree.copyHashes(allocator, layer_log_size, indices);
    }

    pub fn root(self: Tree) MetalError!struct { hash: [32]u8, gpu_ms: f64 } {
        var hash: [32]u8 = undefined;
        var gpu_ms: f64 = 0;
        if (!stwo_zig_metal_tree_root(self.handle, &hash, &gpu_ms)) return MetalError.RootReadFailed;
        return .{ .hash = hash, .gpu_ms = gpu_ms };
    }

    /// Reads only selected hashes from one logical root-to-leaf layer.
    /// `layer_log_size == 0` addresses the root and `log_size` the leaves.
    pub fn copyHashes(
        self: Tree,
        allocator: std.mem.Allocator,
        layer_log_size: u32,
        indices: []const u32,
    ) (MetalError || std.mem.Allocator.Error)![][32]u8 {
        if (layer_log_size > self.log_size) return MetalError.RootReadFailed;
        const layer_len = @as(usize, 1) << @intCast(layer_log_size);
        for (indices) |index| {
            if (index >= layer_len) return MetalError.RootReadFailed;
        }
        const output = try allocator.alloc([32]u8, indices.len);
        errdefer allocator.free(output);
        if (indices.len == 0) return output;

        var message: [1024]u8 = [_]u8{0} ** 1024;
        if (!stwo_zig_metal_tree_copy_hashes(
            self.runtime_handle,
            self.handle,
            layer_log_size,
            indices.ptr,
            @intCast(indices.len),
            @ptrCast(output.ptr),
            &message,
            message.len,
        )) {
            std.log.err("Metal selective hash readback failed: {s}", .{std.mem.sliceTo(&message, 0)});
            return MetalError.RootReadFailed;
        }
        return output;
    }

    /// Copies all layers in root-to-leaf order. This is a compatibility path
    /// for the current CPU decommitter; the resident prover consumes layers on
    /// device and reads back only queried siblings.
    pub fn copyLayers(
        self: Tree,
        runtime: *Runtime,
        allocator: std.mem.Allocator,
        log_size: u32,
    ) (MetalError || std.mem.Allocator.Error)![][32]u8 {
        const hash_count = (@as(usize, 1) << @intCast(log_size + 1)) - 1;
        const output = try allocator.alloc([32]u8, hash_count);
        errdefer allocator.free(output);
        var message: [1024]u8 = [_]u8{0} ** 1024;
        if (!stwo_zig_metal_tree_copy_layers(
            runtime.handle,
            self.handle,
            @ptrCast(output.ptr),
            output.len * @sizeOf([32]u8),
            &message,
            message.len,
        )) {
            std.log.err("Metal layer readback failed: {s}", .{std.mem.sliceTo(&message, 0)});
            return MetalError.RootReadFailed;
        }
        return output;
    }
};
