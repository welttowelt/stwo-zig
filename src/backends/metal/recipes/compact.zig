const std = @import("std");

const arena_plan = @import("../arena_plan.zig");
const recovery = @import("../recovery.zig");
const runtime = @import("../runtime.zig");

pub const Bindings = struct {
    sources: []const arena_plan.Binding,
    descriptors: []const u32,
    descriptor_destination: arena_plan.Binding,
    outputs: []const arena_plan.Binding,
    tuple_words: u32,
    key_words: u32,
    total_rows: u32,
    sort_rows: u32,
    consumer_rows: u32,
    enabler_slot: u32,
    multiplicity_slot: u32,
    iota_slot: u32,
    tuples: arena_plan.Binding,
    keys_a: arena_plan.Binding,
    keys_b: arena_plan.Binding,
    indices_a: arena_plan.Binding,
    indices_b: arena_plan.Binding,
    heads: arena_plan.Binding,
    positions: arena_plan.Binding,
    unique: arena_plan.Binding,
    sort_temp: arena_plan.Binding,
    scan_temp: arena_plan.Binding,
};

const DescriptorImage = struct {
    allocator: std.mem.Allocator,
    destination: arena_plan.Binding,
    words: []u32,

    fn init(
        allocator: std.mem.Allocator,
        destination: arena_plan.Binding,
        source: []const u32,
    ) !DescriptorImage {
        const byte_count = std.math.mul(usize, source.len, @sizeOf(u32)) catch
            return recovery.RecoveryError.BindingSizeMismatch;
        if (destination.offset_bytes % @alignOf(u32) != 0 or destination.size_bytes != byte_count)
            return recovery.RecoveryError.BindingSizeMismatch;
        return .{
            .allocator = allocator,
            .destination = destination,
            .words = try allocator.dupe(u32, source),
        };
    }

    fn deinit(self: *DescriptorImage) void {
        self.allocator.free(self.words);
        self.* = undefined;
    }

    fn rematerialize(self: DescriptorImage, resident_arena: *arena_plan.ResidentArena) !void {
        const destination = try resident_arena.bytes(self.destination);
        const source = std.mem.sliceAsBytes(self.words);
        if (destination.len != source.len) return recovery.RecoveryError.BindingSizeMismatch;
        @memcpy(destination, source);
    }
};

/// Canonical device multiset writer. All radix, scan, and tuple workspaces are
/// sparse arena bindings whose live range is the consumer's witness tick.
pub const Recipe = struct {
    allocator: std.mem.Allocator,
    metal: *runtime.Runtime,
    arena: *arena_plan.ResidentArena,
    destinations: []arena_plan.Binding,
    descriptor_image: DescriptorImage,
    prepared: runtime.CompactPlan,
    last_tick: ?u16 = null,
    accumulated_gpu_ms: f64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        metal: *runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        bindings: Bindings,
    ) !Recipe {
        if (bindings.sources.len == 0 or bindings.descriptors.len != bindings.sources.len * 5 or
            bindings.outputs.len == 0 or bindings.tuple_words == 0 or bindings.key_words == 0 or
            bindings.key_words > bindings.tuple_words or bindings.total_rows == 0 or
            bindings.sort_rows < bindings.total_rows or !std.math.isPowerOfTwo(bindings.sort_rows) or
            bindings.consumer_rows < 16 or !std.math.isPowerOfTwo(bindings.consumer_rows) or
            bindings.outputs.len <= bindings.multiplicity_slot or bindings.outputs.len <= bindings.enabler_slot or
            bindings.outputs.len <= bindings.iota_slot)
            return recovery.RecoveryError.BindingSizeMismatch;
        var descriptor_image = try DescriptorImage.init(
            allocator,
            bindings.descriptor_destination,
            bindings.descriptors,
        );
        errdefer descriptor_image.deinit();
        const asOffset = struct {
            fn get(binding: arena_plan.Binding) !u32 {
                if (binding.offset_bytes % 4 != 0) return recovery.RecoveryError.BindingSizeMismatch;
                return std.math.cast(u32, binding.offset_bytes / 4) orelse recovery.RecoveryError.BindingSizeMismatch;
            }
        }.get;
        const source_offsets = try allocator.alloc(u32, bindings.sources.len);
        defer allocator.free(source_offsets);
        for (bindings.sources, source_offsets, 0..) |source, *offset, edge| {
            const descriptor = bindings.descriptors[edge * 5 ..][0..5];
            if (descriptor[0] == 0 or descriptor[2] < bindings.tuple_words or descriptor[3] == 0)
                return recovery.RecoveryError.BindingSizeMismatch;
            const last_word = @as(u64, descriptor[1]) + @as(u64, descriptor[3] - 1) * descriptor[2] + bindings.tuple_words;
            if (last_word * descriptor[0] * 4 > source.size_bytes)
                return recovery.RecoveryError.BindingSizeMismatch;
            offset.* = try asOffset(source);
        }
        const output_offsets = try allocator.alloc(u32, bindings.outputs.len);
        defer allocator.free(output_offsets);
        const output_bytes = @as(u64, bindings.consumer_rows) * 4;
        for (bindings.outputs, output_offsets) |output, *offset| {
            if (output.size_bytes != output_bytes) return recovery.RecoveryError.BindingSizeMismatch;
            offset.* = try asOffset(output);
        }
        const sort_bytes = @as(u64, bindings.sort_rows) * 4;
        if (bindings.tuples.size_bytes < sort_bytes * bindings.tuple_words or
            bindings.keys_a.size_bytes < sort_bytes or bindings.keys_b.size_bytes < sort_bytes or
            bindings.indices_a.size_bytes < sort_bytes or bindings.indices_b.size_bytes < sort_bytes or
            bindings.heads.size_bytes < sort_bytes or bindings.positions.size_bytes < sort_bytes or
            bindings.unique.size_bytes < 4 or bindings.sort_temp.size_bytes < 17 * 4 or
            bindings.scan_temp.size_bytes < @as(u64, @max(1, bindings.sort_rows / 256)) * 4)
            return recovery.RecoveryError.BindingSizeMismatch;
        var prepared = try metal.prepareCompact(source_offsets, bindings.descriptors, output_offsets, .{
            .tuple_words = bindings.tuple_words,
            .key_words = bindings.key_words,
            .total_rows = bindings.total_rows,
            .sort_rows = bindings.sort_rows,
            .consumer_rows = bindings.consumer_rows,
            .tuples_offset = try asOffset(bindings.tuples),
            .indices_a_offset = try asOffset(bindings.indices_a),
            .indices_b_offset = try asOffset(bindings.indices_b),
            .counts_offset = try asOffset(bindings.keys_a),
            .radix_offsets_offset = try asOffset(bindings.keys_b),
            .bases_offset = (try asOffset(bindings.sort_temp)) + 1,
            .heads_offset = try asOffset(bindings.heads),
            .positions_offset = try asOffset(bindings.positions),
            .block_sums_offset = try asOffset(bindings.scan_temp),
            .error_offset = try asOffset(bindings.sort_temp),
            .unique_offset = try asOffset(bindings.unique),
            .enabler_slot = bindings.enabler_slot,
            .multiplicity_slot = bindings.multiplicity_slot,
            .iota_slot = bindings.iota_slot,
        });
        errdefer prepared.deinit();
        const destinations = try allocator.dupe(arena_plan.Binding, bindings.outputs);
        errdefer allocator.free(destinations);
        var recipe = Recipe{
            .allocator = allocator,
            .metal = metal,
            .arena = resident_arena,
            .destinations = destinations,
            .descriptor_image = descriptor_image,
            .prepared = prepared,
        };
        try recipe.rematerializeDescriptors();
        return recipe;
    }

    pub fn deinit(self: *Recipe) void {
        self.prepared.deinit();
        self.allocator.free(self.destinations);
        self.descriptor_image.deinit();
        self.* = undefined;
    }

    pub fn rematerializeDescriptors(self: *Recipe) !void {
        try self.descriptor_image.rematerialize(self.arena);
    }

    /// Clears request-local execution bookkeeping and restores the static
    /// descriptor table overwritten by a full resident-arena clear.
    pub fn resetForRequest(self: *Recipe) !void {
        self.last_tick = null;
        self.accumulated_gpu_ms = 0;
        try self.rematerializeDescriptors();
    }

    pub fn makeRecipes(self: *Recipe, allocator: std.mem.Allocator) ![]recovery.Recipe {
        const recipes = try allocator.alloc(recovery.Recipe, self.destinations.len);
        for (self.destinations, recipes) |destination, *recipe_entry|
            recipe_entry.* = .{ .logical_id = destination.logical_id, .context = self, .run = run };
        return recipes;
    }

    pub fn execute(self: *Recipe) !void {
        self.accumulated_gpu_ms += try self.metal.compactPrepared(self.arena.buffer, self.prepared);
    }

    fn run(raw: *anyopaque, tick: u16, requested: arena_plan.Binding, _: []u8) !void {
        const self: *Recipe = @ptrCast(@alignCast(raw));
        if (self.last_tick == tick) return;
        var found = false;
        for (self.destinations) |destination| found = found or destination.logical_id == requested.logical_id;
        if (!found) return recovery.RecoveryError.MissingRecipe;
        try self.execute();
        self.last_tick = tick;
    }
};

test "compact recipe owns and rematerializes descriptors on request reset" {
    const binding = arena_plan.Binding{
        .logical_id = 41,
        .slot = 0,
        .offset_bytes = 16,
        .size_bytes = 5 * @sizeOf(u32),
        .materialization = .resident,
        .occupied = [_]u64{0} ** (arena_plan.max_ticks / 64),
    };
    const expected = [_]u32{ 64, 2, 7, 3, 11 };
    var request_descriptors = expected;
    var storage = [_]u8{0xa5} ** 64;
    var resident_arena = arena_plan.ResidentArena{ .buffer = .{
        .handle = @ptrCast(&storage),
        .contents = @ptrCast(&storage),
        .byte_length = storage.len,
    } };
    var descriptor_image = try DescriptorImage.init(
        std.testing.allocator,
        binding,
        &request_descriptors,
    );
    errdefer descriptor_image.deinit();
    try std.testing.expect(descriptor_image.words.ptr != request_descriptors[0..].ptr);

    const destinations = [_]arena_plan.Binding{binding};
    var recipe = Recipe{
        .allocator = std.testing.allocator,
        .metal = undefined,
        .arena = &resident_arena,
        .destinations = @constCast(&destinations),
        .descriptor_image = descriptor_image,
        .prepared = .{ .handle = @ptrCast(&storage) },
        .last_tick = 37,
        .accumulated_gpu_ms = 28.5,
    };
    defer recipe.descriptor_image.deinit();

    @memset(&request_descriptors, 0);
    @memset(&storage, 0);
    try recipe.resetForRequest();

    try std.testing.expectEqual(@as(?u16, null), recipe.last_tick);
    try std.testing.expectEqual(@as(f64, 0), recipe.accumulated_gpu_ms);
    try std.testing.expectEqualSlices(
        u8,
        std.mem.sliceAsBytes(expected[0..]),
        storage[binding.offset_bytes..][0..binding.size_bytes],
    );
}
