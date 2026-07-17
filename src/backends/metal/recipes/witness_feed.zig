const std = @import("std");

const arena_plan = @import("../arena_plan.zig");
const recovery = @import("../recovery.zig");
const runtime = @import("../runtime.zig");

pub const DestinationColumns = struct {
    columns: []const arena_plan.Binding,
};

/// Planner-resolved form of one canonical Cairo feed. The canonical artifact
/// uses component and LUT indices; this form replaces them with compact table
/// indices whose entries are the sparse arena's actual word offsets.
pub const BoundWitnessFeed = struct {
    allocator: std.mem.Allocator,
    descriptors: []u32,
    luts: []u32,
    source_offsets: []u32,
    destination_offsets: []u32,
    destination_bindings: []arena_plan.Binding,

    fn isRuntimeSizedPrimary(e: []const u32) bool {
        const none = std.math.maxInt(u32);
        return e[11] == 1 or
            (e[11] == 0 and e[1] == 1 and e[2] == 31 and e[9] == none and e[12] == @as(u32, @bitCast(@as(i32, -1))));
    }

    pub fn init(
        allocator: std.mem.Allocator,
        source_columns: []const arena_plan.Binding,
        destination_columns: []const DestinationColumns,
        canonical_descriptors: []const u32,
        canonical_luts: []const []const u32,
        column_length: u32,
    ) !BoundWitnessFeed {
        if (source_columns.len == 0 or destination_columns.len == 0 or canonical_descriptors.len == 0 or
            canonical_descriptors.len % 14 != 0 or column_length == 0)
            return recovery.RecoveryError.BindingSizeMismatch;

        const descriptors = try allocator.dupe(u32, canonical_descriptors);
        errdefer allocator.free(descriptors);
        const source_offsets = try allocator.alloc(u32, source_columns.len);
        errdefer allocator.free(source_offsets);
        for (source_columns, source_offsets) |binding, *offset| {
            if (binding.offset_bytes % 4 != 0 or binding.size_bytes < @as(u64, column_length) * 4)
                return recovery.RecoveryError.BindingSizeMismatch;
            offset.* = std.math.cast(u32, binding.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch;
        }

        const lut_offsets = try allocator.alloc(u32, canonical_luts.len);
        defer allocator.free(lut_offsets);
        var flat_luts = std.ArrayList(u32).empty;
        errdefer flat_luts.deinit(allocator);
        for (canonical_luts, lut_offsets) |lut, *offset| {
            offset.* = std.math.cast(u32, flat_luts.items.len) orelse return recovery.RecoveryError.BindingSizeMismatch;
            try flat_luts.appendSlice(allocator, lut);
        }

        const destination_bases = try allocator.alloc(u32, destination_columns.len);
        defer allocator.free(destination_bases);
        var destination_offsets = std.ArrayList(u32).empty;
        errdefer destination_offsets.deinit(allocator);
        var destination_bindings = std.ArrayList(arena_plan.Binding).empty;
        errdefer destination_bindings.deinit(allocator);
        for (destination_columns, destination_bases) |destination, *base| {
            if (destination.columns.len == 0) return recovery.RecoveryError.BindingSizeMismatch;
            base.* = std.math.cast(u32, destination_offsets.items.len) orelse return recovery.RecoveryError.BindingSizeMismatch;
            for (destination.columns) |binding| {
                if (binding.offset_bytes % 4 != 0 or binding.size_bytes % 4 != 0)
                    return recovery.RecoveryError.BindingSizeMismatch;
                try destination_offsets.append(allocator, std.math.cast(u32, binding.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch);
                try destination_bindings.append(allocator, binding);
            }
        }

        const none = std.math.maxInt(u32);
        var descriptor_index: usize = 0;
        while (descriptor_index < descriptors.len) : (descriptor_index += 14) {
            const e = descriptors[descriptor_index .. descriptor_index + 14];
            const word_count: u32 = if (e[11] == 1) 1 else if (e[11] == 2 or e[11] == 3) 3 else e[1];
            if (@as(u64, e[0]) + word_count > source_columns.len) return recovery.RecoveryError.BindingSizeMismatch;
            if (e[9] != none) {
                if (e[9] >= canonical_luts.len) return recovery.RecoveryError.BindingSizeMismatch;
                e[9] = lut_offsets[e[9]];
            }
            if (e[10] >= destination_columns.len) return recovery.RecoveryError.BindingSizeMismatch;
            const primary = destination_columns[e[10]].columns;
            const primary_columns: u32 = if (e[11] == 3) 16 else e[7] + 1;
            if (primary.len < primary_columns) return recovery.RecoveryError.BindingSizeMismatch;
            if (primary[0].size_bytes % @sizeOf(u32) != 0)
                return recovery.RecoveryError.BindingSizeMismatch;
            const primary_capacity = std.math.cast(u32, primary[0].size_bytes / @sizeOf(u32)) orelse
                return recovery.RecoveryError.BindingSizeMismatch;
            if (e[11] == 1) {
                if (e[13] >= destination_columns.len) return recovery.RecoveryError.BindingSizeMismatch;
                const secondary = destination_columns[e[13]].columns;
                if (secondary.len <= e[7] or
                    secondary[e[7]].size_bytes % @sizeOf(u32) != 0)
                    return recovery.RecoveryError.BindingSizeMismatch;
                const secondary_capacity = std.math.cast(u32, secondary[e[7]].size_bytes / @sizeOf(u32)) orelse
                    return recovery.RecoveryError.BindingSizeMismatch;
                e[12] = secondary_capacity;
            }
            if (isRuntimeSizedPrimary(e)) {
                e[8] = primary_capacity;
            } else if (primary_capacity != e[8]) {
                return recovery.RecoveryError.BindingSizeMismatch;
            }
            for (primary[0..primary_columns]) |binding| if (binding.size_bytes != @as(u64, e[8]) * 4)
                return recovery.RecoveryError.BindingSizeMismatch;
            e[10] = destination_bases[e[10]];
            if (e[11] == 1) {
                if (e[13] >= destination_columns.len) return recovery.RecoveryError.BindingSizeMismatch;
                const secondary = destination_columns[e[13]].columns;
                if (secondary.len <= e[7] or secondary[e[7]].size_bytes < @as(u64, e[12]) * 4)
                    return recovery.RecoveryError.BindingSizeMismatch;
                e[13] = destination_bases[e[13]];
            }
        }

        const owned_luts = try flat_luts.toOwnedSlice(allocator);
        errdefer allocator.free(owned_luts);
        const owned_destination_offsets = try destination_offsets.toOwnedSlice(allocator);
        errdefer allocator.free(owned_destination_offsets);
        const owned_destination_bindings = try destination_bindings.toOwnedSlice(allocator);
        errdefer allocator.free(owned_destination_bindings);
        return .{
            .allocator = allocator,
            .descriptors = descriptors,
            .luts = owned_luts,
            .source_offsets = source_offsets,
            .destination_offsets = owned_destination_offsets,
            .destination_bindings = owned_destination_bindings,
        };
    }

    pub fn deinit(self: *BoundWitnessFeed) void {
        self.allocator.free(self.descriptors);
        self.allocator.free(self.luts);
        self.allocator.free(self.source_offsets);
        self.allocator.free(self.destination_offsets);
        self.allocator.free(self.destination_bindings);
        self.* = undefined;
    }
};

/// Device-native Graph-A feed: clears every consumer multiplicity range and
/// scatters the witness program's resident sub-words through the canonical
/// 14-word descriptors. Descriptor LUT/count indices address the prepared
/// flat LUT and sparse-column offset tables.
pub const WitnessFeedRecipe = struct {
    metal: *runtime.Runtime,
    arena: *arena_plan.ResidentArena,
    bound: *const BoundWitnessFeed,
    prepared: runtime.WitnessFeedPlan,
    column_length: u32,
    last_tick: ?u16 = null,
    accumulated_gpu_ms: f64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        metal: *runtime.Runtime,
        arena: *arena_plan.ResidentArena,
        bound: *const BoundWitnessFeed,
        column_length: u32,
    ) !WitnessFeedRecipe {
        if (bound.destination_bindings.len == 0 or bound.descriptors.len == 0 or column_length == 0)
            return recovery.RecoveryError.BindingSizeMismatch;
        const ranges = try allocator.alloc([2]u32, bound.destination_bindings.len);
        errdefer allocator.free(ranges);
        for (bound.destination_bindings, ranges) |binding, *range| {
            if (binding.offset_bytes % 4 != 0 or binding.size_bytes % 4 != 0) return recovery.RecoveryError.BindingSizeMismatch;
            range.* = .{ @intCast(binding.offset_bytes / 4), @intCast(binding.size_bytes / 4) };
        }
        var prepared = try metal.prepareWitnessFeed(
            bound.descriptors,
            bound.luts,
            bound.destination_offsets,
            bound.source_offsets,
            ranges,
        );
        errdefer prepared.deinit();
        allocator.free(ranges);
        return .{
            .metal = metal,
            .arena = arena,
            .bound = bound,
            .prepared = prepared,
            .column_length = column_length,
        };
    }

    pub fn deinit(self: *WitnessFeedRecipe) void {
        self.prepared.deinit();
        self.* = undefined;
    }

    pub fn makeRecipes(self: *WitnessFeedRecipe, allocator: std.mem.Allocator) ![]recovery.Recipe {
        const recipes = try allocator.alloc(recovery.Recipe, self.bound.destination_bindings.len);
        for (self.bound.destination_bindings, recipes) |binding, *recipe_entry| {
            recipe_entry.* = .{ .logical_id = binding.logical_id, .context = self, .run = run };
        }
        return recipes;
    }

    fn run(raw: *anyopaque, tick: u16, requested: arena_plan.Binding, _: []u8) !void {
        const self: *WitnessFeedRecipe = @ptrCast(@alignCast(raw));
        if (self.last_tick == tick) return;
        var found = false;
        for (self.bound.destination_bindings) |binding| found = found or binding.logical_id == requested.logical_id;
        if (!found) return recovery.RecoveryError.MissingRecipe;
        self.accumulated_gpu_ms += try self.metal.witnessFeedCountsPrepared(
            self.arena.buffer,
            self.column_length,
            self.prepared,
        );
        self.last_tick = tick;
    }
};

pub const WitnessFeedBatchEntry = struct {
    bound: *const BoundWitnessFeed,
    column_length: u32,
};

/// All multiplicity producers for one witness epoch. Shared consumers are
/// cleared once, then every producer is encoded into the same command buffer.
pub const WitnessFeedBatchRecipe = struct {
    allocator: std.mem.Allocator,
    metal: *runtime.Runtime,
    arena: *arena_plan.ResidentArena,
    destinations: []arena_plan.Binding,
    prepared: runtime.WitnessFeedBatchPlan,
    plan_count: usize,
    last_tick: ?u16 = null,
    cleared: bool = false,
    accumulated_gpu_ms: f64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        metal: *runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        entries: []const WitnessFeedBatchEntry,
    ) !WitnessFeedBatchRecipe {
        if (entries.len == 0) return recovery.RecoveryError.BindingSizeMismatch;
        var unique = std.ArrayList(arena_plan.Binding).empty;
        errdefer unique.deinit(allocator);
        for (entries) |entry| {
            if (entry.column_length == 0) return recovery.RecoveryError.BindingSizeMismatch;
            for (entry.bound.destination_bindings) |binding| {
                var found = false;
                for (unique.items) |existing| {
                    if (existing.offset_bytes != binding.offset_bytes or existing.size_bytes != binding.size_bytes) continue;
                    found = true;
                    break;
                }
                if (!found) try unique.append(allocator, binding);
            }
        }
        std.mem.sortUnstable(arena_plan.Binding, unique.items, {}, struct {
            fn lessThan(_: void, lhs: arena_plan.Binding, rhs: arena_plan.Binding) bool {
                if (lhs.offset_bytes != rhs.offset_bytes) return lhs.offset_bytes < rhs.offset_bytes;
                return lhs.size_bytes < rhs.size_bytes;
            }
        }.lessThan);
        const ranges = try allocator.alloc([2]u32, unique.items.len);
        defer allocator.free(ranges);
        for (unique.items, ranges) |binding, *range| {
            if (binding.offset_bytes % 4 != 0 or binding.size_bytes % 4 != 0)
                return recovery.RecoveryError.BindingSizeMismatch;
            range.* = .{
                std.math.cast(u32, binding.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch,
                std.math.cast(u32, binding.size_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch,
            };
        }

        const plans = try allocator.alloc(runtime.WitnessFeedPlan, entries.len);
        defer allocator.free(plans);
        const lengths = try allocator.alloc(u32, entries.len);
        defer allocator.free(lengths);
        var initialized: usize = 0;
        defer for (plans[0..initialized]) |*plan| plan.deinit();
        while (initialized < entries.len) : (initialized += 1) {
            const entry = entries[initialized];
            plans[initialized] = try metal.prepareWitnessFeed(
                entry.bound.descriptors,
                entry.bound.luts,
                entry.bound.destination_offsets,
                entry.bound.source_offsets,
                ranges,
            );
            lengths[initialized] = entry.column_length;
        }
        var prepared = try metal.prepareWitnessFeedBatch(plans, lengths, ranges);
        errdefer prepared.deinit();
        return .{
            .allocator = allocator,
            .metal = metal,
            .arena = resident_arena,
            .destinations = try unique.toOwnedSlice(allocator),
            .prepared = prepared,
            .plan_count = entries.len,
        };
    }

    pub fn deinit(self: *WitnessFeedBatchRecipe) void {
        self.prepared.deinit();
        self.allocator.free(self.destinations);
        self.* = undefined;
    }

    /// Starts a fresh request against a reset resident arena. In particular,
    /// the next `clear` must not inherit the previous request's completion.
    pub fn resetForRequest(self: *WitnessFeedBatchRecipe) void {
        self.last_tick = null;
        self.cleared = false;
        self.accumulated_gpu_ms = 0;
    }

    pub fn makeRecipes(self: *WitnessFeedBatchRecipe, allocator: std.mem.Allocator) ![]recovery.Recipe {
        const recipes = try allocator.alloc(recovery.Recipe, self.destinations.len);
        for (self.destinations, recipes) |binding, *recipe_entry| {
            recipe_entry.* = .{ .logical_id = binding.logical_id, .context = self, .run = run };
        }
        return recipes;
    }

    pub fn execute(self: *WitnessFeedBatchRecipe) !void {
        self.accumulated_gpu_ms += try self.metal.witnessFeedBatchCountsPrepared(self.arena.buffer, self.prepared);
        self.cleared = true;
    }

    pub fn clear(self: *WitnessFeedBatchRecipe) !void {
        if (self.cleared) return;
        self.accumulated_gpu_ms += try self.metal.witnessFeedBatchClearPrepared(self.arena.buffer, self.prepared);
        self.cleared = true;
    }

    pub fn executeIndex(self: *WitnessFeedBatchRecipe, index: usize) !void {
        if (!self.cleared or index >= self.plan_count)
            return recovery.RecoveryError.BindingSizeMismatch;
        self.accumulated_gpu_ms += try self.metal.witnessFeedBatchIndexPrepared(
            self.arena.buffer,
            self.prepared,
            @intCast(index),
        );
    }

    fn run(raw: *anyopaque, tick: u16, requested: arena_plan.Binding, _: []u8) !void {
        const self: *WitnessFeedBatchRecipe = @ptrCast(@alignCast(raw));
        if (self.last_tick == tick) return;
        var found = false;
        for (self.destinations) |binding| found = found or binding.logical_id == requested.logical_id;
        if (!found) return recovery.RecoveryError.MissingRecipe;
        try self.execute();
        self.last_tick = tick;
    }
};
test "witness feed batch request reset requires a fresh clear" {
    const destinations = [_]arena_plan.Binding{undefined};
    var recipe = WitnessFeedBatchRecipe{
        .allocator = std.testing.allocator,
        .metal = undefined,
        .arena = undefined,
        .destinations = @constCast(&destinations),
        .prepared = undefined,
        .plan_count = 9,
        .last_tick = 23,
        .cleared = true,
        .accumulated_gpu_ms = 19.75,
    };

    const destinations_ptr = recipe.destinations.ptr;
    recipe.resetForRequest();

    try std.testing.expectEqual(@as(?u16, null), recipe.last_tick);
    try std.testing.expect(!recipe.cleared);
    try std.testing.expectEqual(@as(f64, 0), recipe.accumulated_gpu_ms);
    try std.testing.expectEqual(@as(usize, 9), recipe.plan_count);
    try std.testing.expectEqual(destinations_ptr, recipe.destinations.ptr);
}
test "Metal protocol recovery: witness feed binds sparse source and destination columns" {
    const binding = struct {
        fn make(id: u32, offset: u64, size: u64) arena_plan.Binding {
            return .{
                .logical_id = id,
                .slot = id,
                .offset_bytes = offset,
                .size_bytes = size,
                .materialization = .recompute,
                .occupied = [_]u64{0} ** (arena_plan.max_ticks / 64),
            };
        }
    }.make;
    const sources = [_]arena_plan.Binding{
        binding(1, 4096, 32),
        binding(2, 12288, 32),
        binding(3, 20480, 32),
    };
    const destination_a = [_]arena_plan.Binding{
        binding(4, 32768, 16),
        binding(5, 49152, 16),
    };
    const destination_b = [_]arena_plan.Binding{binding(6, 65536, 16)};
    const destinations = [_]DestinationColumns{
        .{ .columns = &destination_a },
        .{ .columns = &destination_b },
    };
    const descriptor = [_]u32{
        0, 3, 2, 2, 2, 0, 0,
        1, 4, 0, 0, 2, 0, 0,
    };
    const lut = [_]u32{ 3, 2, 1, 0 };
    const luts = [_][]const u32{&lut};
    var bound = try BoundWitnessFeed.init(std.testing.allocator, &sources, &destinations, &descriptor, &luts, 8);
    defer bound.deinit();

    try std.testing.expectEqualSlices(u32, &.{ 1024, 3072, 5120 }, bound.source_offsets);
    try std.testing.expectEqualSlices(u32, &.{ 8192, 12288, 16384 }, bound.destination_offsets);
    try std.testing.expectEqualSlices(u32, &lut, bound.luts);
    try std.testing.expectEqual(@as(u32, 0), bound.descriptors[9]);
    try std.testing.expectEqual(@as(u32, 0), bound.descriptors[10]);
}

test "metal: protocol recovery retargets runtime-sized memory destinations" {
    const binding = struct {
        fn make(id: u32, offset: u64, size: u64) arena_plan.Binding {
            return .{
                .logical_id = id,
                .slot = id,
                .offset_bytes = offset,
                .size_bytes = size,
                .materialization = .recompute,
                .occupied = [_]u64{0} ** (arena_plan.max_ticks / 64),
            };
        }
    }.make;
    const sources = [_]arena_plan.Binding{binding(1, 4096, 32)};
    const canonical_big_words = @as(u32, 1) << 18;
    const canonical_small_words = @as(u32, 1) << 21;
    const widened_small_words = @as(u32, 1) << 22;
    const narrowed_big_words = @as(u32, 1) << 15;
    const big = [_]arena_plan.Binding{binding(2, 8192, @as(u64, narrowed_big_words) * 4)};
    const small = [_]arena_plan.Binding{binding(3, 12288, @as(u64, widened_small_words) * 4)};
    const destinations = [_]DestinationColumns{
        .{ .columns = &big },
        .{ .columns = &small },
    };
    const descriptor = [_]u32{
        0, 1,                   0,                    0, 0, 0,                     0,
        0, canonical_big_words, std.math.maxInt(u32), 0, 1, canonical_small_words, 1,
    };
    var bound = try BoundWitnessFeed.init(std.testing.allocator, &sources, &destinations, &descriptor, &.{}, 8);
    defer bound.deinit();

    var expected = descriptor;
    expected[8] = narrowed_big_words;
    expected[12] = widened_small_words;
    try std.testing.expectEqualSlices(u32, &expected, bound.descriptors);

    const address_descriptor = [_]u32{
        0, 1,                   31,                   0, 0, 0,                      0,
        0, canonical_big_words, std.math.maxInt(u32), 0, 0, @bitCast(@as(i32, -1)), 0,
    };
    const address_destinations = [_]DestinationColumns{.{ .columns = &big }};
    var address_bound = try BoundWitnessFeed.init(
        std.testing.allocator,
        &sources,
        &address_destinations,
        &address_descriptor,
        &.{},
        8,
    );
    defer address_bound.deinit();
    try std.testing.expectEqual(narrowed_big_words, address_bound.descriptors[8]);
}

test "metal: protocol recovery rejects resized fixed feed destinations" {
    const occupied = [_]u64{0} ** (arena_plan.max_ticks / 64);
    const source = [_]arena_plan.Binding{.{
        .logical_id = 1,
        .slot = 1,
        .offset_bytes = 4096,
        .size_bytes = 32,
        .materialization = .recompute,
        .occupied = occupied,
    }};
    const destination = [_]arena_plan.Binding{.{
        .logical_id = 2,
        .slot = 2,
        .offset_bytes = 8192,
        .size_bytes = 32,
        .materialization = .recompute,
        .occupied = occupied,
    }};
    const destinations = [_]DestinationColumns{.{ .columns = &destination }};
    const descriptor = [_]u32{
        0, 1,  8,                    0, 0, 0, 0,
        0, 16, std.math.maxInt(u32), 0, 0, 0, 0,
    };
    try std.testing.expectError(
        recovery.RecoveryError.BindingSizeMismatch,
        BoundWitnessFeed.init(std.testing.allocator, &source, &destinations, &descriptor, &.{}, 8),
    );
}
