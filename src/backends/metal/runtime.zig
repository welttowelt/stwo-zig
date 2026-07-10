const std = @import("std");

const kernel_source: [:0]const u8 = @embedFile("kernels.metal") ++ "\x00";

extern fn stwo_zig_metal_runtime_create(
    source: [*:0]const u8,
    error_message: [*]u8,
    error_message_len: usize,
) ?*anyopaque;
extern fn stwo_zig_metal_runtime_destroy(runtime: ?*anyopaque) void;
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
    coefficients: [*]const u32,
    coefficient_count: usize,
    factors: [*]const u32,
    factor_word_count: usize,
    tasks: *const anyopaque,
    task_count: u32,
    output_count: u32,
    output: [*]u32,
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
        return .{ .handle = tree };
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

        const output = try allocator.alloc(u32, row_count * 4);
        defer allocator.free(output);
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
        for (0..row_count) |row| {
            inline for (0..4) |coordinate| {
                out.columns[coordinate][row].v = output[row * 4 + coordinate];
            }
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
        var coefficient_count: usize = 0;
        for (coefficients, 0..) |coefficient, index| {
            coefficient_offsets[index] = @intCast(coefficient_count);
            coefficient_count += coefficient.coefficients().len;
        }
        const coefficient_words = try allocator.alloc(u32, coefficient_count);
        defer allocator.free(coefficient_words);
        var coefficient_cursor: usize = 0;
        for (coefficients) |coefficient| {
            const words = std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(coefficient.coefficients()));
            @memcpy(coefficient_words[coefficient_cursor .. coefficient_cursor + words.len], words);
            coefficient_cursor += words.len;
        }

        var factor_word_count: usize = 0;
        var task_count: usize = 0;
        for (plans) |plan| {
            factor_word_count += plan.flat_factors.len * 4;
            task_count += plan.column_indices.items.len * plan.normalized_points.len;
        }
        const factor_words = try allocator.alloc(u32, factor_word_count);
        defer allocator.free(factor_words);
        const task_words = try allocator.alloc(u32, task_count * 5);
        defer allocator.free(task_words);

        const output_offsets = try allocator.alloc(u32, tree_values.len);
        defer allocator.free(output_offsets);
        var output_count: usize = 0;
        for (tree_values, 0..) |values, index| {
            output_offsets[index] = @intCast(output_count);
            output_count += values.len;
        }

        var factor_cursor: usize = 0;
        var task_cursor: usize = 0;
        for (plans) |plan| {
            for (plan.flat_factors) |factor| {
                const coordinates = factor.toM31Array();
                inline for (0..4) |coordinate| {
                    factor_words[factor_cursor] = coordinates[coordinate].v;
                    factor_cursor += 1;
                }
            }
            for (plan.column_indices.items) |column_index| {
                for (0..plan.normalized_points.len) |point_index| {
                    const base = task_cursor * 5;
                    task_words[base..][0..5].* = .{
                        coefficient_offsets[column_index],
                        @intCast(coefficients[column_index].coefficients().len),
                        @intCast(factor_cursor - plan.flat_factors.len * 4 + point_index * plan.coeff_log_size * 4),
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
            coefficient_words.ptr,
            coefficient_words.len,
            factor_words.ptr,
            factor_words.len,
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
};

pub const Tree = struct {
    handle: *anyopaque,

    pub fn deinit(self: *Tree) void {
        stwo_zig_metal_tree_destroy(self.handle);
        self.* = undefined;
    }

    pub fn root(self: Tree) MetalError!struct { hash: [32]u8, gpu_ms: f64 } {
        var hash: [32]u8 = undefined;
        var gpu_ms: f64 = 0;
        if (!stwo_zig_metal_tree_root(self.handle, &hash, &gpu_ms)) return MetalError.RootReadFailed;
        return .{ .hash = hash, .gpu_ms = gpu_ms };
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
