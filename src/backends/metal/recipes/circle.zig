const std = @import("std");

const M31 = @import("../../../core/fields/m31.zig").M31;
const arena_plan = @import("../arena_plan.zig");
const recovery = @import("../recovery.zig");
const runtime = @import("../runtime.zig");

/// Rebuilds one coefficient/evaluation column from another resident column.
/// Copy and transform both target the final arena slot; no intermediate device
/// allocation or compatibility readback is introduced.
pub const TransformRecipe = struct {
    metal: *runtime.Runtime,
    access: recovery.BufferAccess,
    source: arena_plan.Binding,
    twiddles: []const M31,
    log_size: u32,
    inverse: bool,
    accumulated_gpu_ms: f64 = 0,

    pub fn recipe(self: *TransformRecipe, logical_id: u32) recovery.Recipe {
        return .{ .logical_id = logical_id, .context = self, .run = run };
    }

    fn run(raw: *anyopaque, _: u16, binding: arena_plan.Binding, destination_bytes: []u8) !void {
        const self: *TransformRecipe = @ptrCast(@alignCast(raw));
        const source = try self.access.bytes(self.source);
        if (source.len != destination_bytes.len or binding.size_bytes != destination_bytes.len or destination_bytes.len % @sizeOf(M31) != 0)
            return recovery.RecoveryError.BindingSizeMismatch;
        if (source.ptr != destination_bytes.ptr) @memcpy(destination_bytes, source);
        const aligned: []align(@alignOf(M31)) u8 = @alignCast(destination_bytes);
        self.accumulated_gpu_ms += try self.metal.transformCircleResident(
            std.mem.bytesAsSlice(M31, aligned),
            self.twiddles,
            self.log_size,
            self.inverse,
        );
    }
};

/// Re-evaluates sparse coefficient columns directly into their retained LDE
/// bindings. The prepared plan owns only compact offset tables; coefficients,
/// twiddles, and outputs remain in the single resident arena.
pub const LdeRecipe = struct {
    allocator: std.mem.Allocator,
    metal: *runtime.Runtime,
    arena: *arena_plan.ResidentArena,
    destinations: []arena_plan.Binding,
    prepared: runtime.CircleLdePlan,
    last_tick: ?u16 = null,
    accumulated_gpu_ms: f64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        metal: *runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        sources: []const arena_plan.Binding,
        destinations: []const arena_plan.Binding,
        twiddles: arena_plan.Binding,
        base_log_size: u32,
        extended_log_size: u32,
    ) !LdeRecipe {
        if (sources.len == 0 or sources.len != destinations.len or base_log_size < 3 or extended_log_size <= base_log_size)
            return recovery.RecoveryError.BindingSizeMismatch;
        const base_bytes = (@as(u64, 1) << @intCast(base_log_size)) * 4;
        const extended_bytes = (@as(u64, 1) << @intCast(extended_log_size)) * 4;
        const twiddle_bytes = (@as(u64, 1) << @intCast(extended_log_size - 1)) * 4;
        if (twiddles.offset_bytes % 4 != 0 or twiddles.size_bytes < twiddle_bytes)
            return recovery.RecoveryError.BindingSizeMismatch;
        const source_offsets = try allocator.alloc(u64, sources.len);
        defer allocator.free(source_offsets);
        const destination_offsets = try allocator.alloc(u64, destinations.len);
        defer allocator.free(destination_offsets);
        for (sources, destinations, source_offsets, destination_offsets) |source, destination, *source_offset, *destination_offset| {
            if (source.offset_bytes % 4 != 0 or destination.offset_bytes % 4 != 0 or
                source.size_bytes != base_bytes or destination.size_bytes != extended_bytes)
                return recovery.RecoveryError.BindingSizeMismatch;
            source_offset.* = source.offset_bytes / 4;
            destination_offset.* = destination.offset_bytes / 4;
        }
        var prepared = try metal.prepareCircleLde(
            source_offsets,
            destination_offsets,
            base_log_size,
            extended_log_size,
            std.math.cast(u32, twiddles.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch,
        );
        errdefer prepared.deinit();
        return .{
            .allocator = allocator,
            .metal = metal,
            .arena = resident_arena,
            .destinations = try allocator.dupe(arena_plan.Binding, destinations),
            .prepared = prepared,
        };
    }

    pub fn deinit(self: *LdeRecipe) void {
        self.prepared.deinit();
        self.allocator.free(self.destinations);
        self.* = undefined;
    }

    pub fn makeRecipes(self: *LdeRecipe, allocator: std.mem.Allocator) ![]recovery.Recipe {
        const recipes = try allocator.alloc(recovery.Recipe, self.destinations.len);
        for (self.destinations, recipes) |binding, *recipe_entry| {
            recipe_entry.* = .{ .logical_id = binding.logical_id, .context = self, .run = run };
        }
        return recipes;
    }

    fn run(raw: *anyopaque, tick: u16, requested: arena_plan.Binding, _: []u8) !void {
        const self: *LdeRecipe = @ptrCast(@alignCast(raw));
        if (self.last_tick == tick) return;
        var found = false;
        for (self.destinations) |binding| found = found or binding.logical_id == requested.logical_id;
        if (!found) return recovery.RecoveryError.MissingRecipe;
        self.accumulated_gpu_ms += try self.metal.circleLdePrepared(self.arena.buffer, self.prepared);
        self.last_tick = tick;
    }
};

/// Interpolates sparse evaluation columns into their coefficient bindings in
/// one resident Metal submission. Plans are grouped by log size so every
/// dispatch has uniform geometry without materializing a packed matrix.
pub const IfftRecipe = struct {
    allocator: std.mem.Allocator,
    metal: *runtime.Runtime,
    arena: *arena_plan.ResidentArena,
    sources: []arena_plan.Binding,
    destinations: []arena_plan.Binding,
    prepared: runtime.CircleIfftPlan,
    log_size: u32,
    inverse_twiddle_offset_words: u32,
    scale_factor: u32,
    last_tick: ?u16 = null,
    accumulated_gpu_ms: f64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        metal: *runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        sources: []const arena_plan.Binding,
        destinations: []const arena_plan.Binding,
        inverse_twiddles: arena_plan.Binding,
        log_size: u32,
        scale_factor: M31,
    ) !IfftRecipe {
        if (sources.len == 0 or sources.len != destinations.len or log_size < 3 or log_size >= 31)
            return recovery.RecoveryError.BindingSizeMismatch;
        const column_bytes = (@as(u64, 1) << @intCast(log_size)) * @sizeOf(M31);
        const twiddle_bytes = (@as(u64, 1) << @intCast(log_size - 1)) * @sizeOf(M31);
        if (inverse_twiddles.offset_bytes % 4 != 0 or inverse_twiddles.size_bytes < twiddle_bytes)
            return recovery.RecoveryError.BindingSizeMismatch;
        const source_offsets = try allocator.alloc(u64, sources.len);
        defer allocator.free(source_offsets);
        const destination_offsets = try allocator.alloc(u64, destinations.len);
        defer allocator.free(destination_offsets);
        for (sources, destinations, source_offsets, destination_offsets) |source, destination, *source_offset, *destination_offset| {
            if (source.offset_bytes % 4 != 0 or destination.offset_bytes % 4 != 0 or
                source.size_bytes != column_bytes or destination.size_bytes != column_bytes)
                return recovery.RecoveryError.BindingSizeMismatch;
            source_offset.* = source.offset_bytes / 4;
            destination_offset.* = destination.offset_bytes / 4;
        }
        const inverse_twiddle_offset_words = std.math.cast(u32, inverse_twiddles.offset_bytes / 4) orelse
            return recovery.RecoveryError.BindingSizeMismatch;
        var prepared = try metal.prepareCircleIfft(
            source_offsets,
            destination_offsets,
            log_size,
            inverse_twiddle_offset_words,
            scale_factor.v,
        );
        errdefer prepared.deinit();
        const retained_sources = try allocator.dupe(arena_plan.Binding, sources);
        errdefer allocator.free(retained_sources);
        return .{
            .allocator = allocator,
            .metal = metal,
            .arena = resident_arena,
            .sources = retained_sources,
            .destinations = try allocator.dupe(arena_plan.Binding, destinations),
            .prepared = prepared,
            .log_size = log_size,
            .inverse_twiddle_offset_words = inverse_twiddle_offset_words,
            .scale_factor = scale_factor.v,
        };
    }

    pub fn deinit(self: *IfftRecipe) void {
        self.prepared.deinit();
        self.allocator.free(self.sources);
        self.allocator.free(self.destinations);
        self.* = undefined;
    }

    /// Clears bookkeeping that is scoped to one proof without rebuilding the
    /// retained Metal interpolation plan.
    pub fn resetForRequest(self: *IfftRecipe) void {
        self.last_tick = null;
        self.accumulated_gpu_ms = 0;
    }

    pub fn executeColumn(self: *IfftRecipe, column: usize) !f64 {
        if (column >= self.sources.len or column >= self.destinations.len)
            return recovery.RecoveryError.BindingSizeMismatch;
        const source_offsets = [_]u64{self.sources[column].offset_bytes / 4};
        const destination_offsets = [_]u64{self.destinations[column].offset_bytes / 4};
        var prepared = try self.metal.prepareCircleIfft(
            &source_offsets,
            &destination_offsets,
            self.log_size,
            self.inverse_twiddle_offset_words,
            self.scale_factor,
        );
        defer prepared.deinit();
        return self.metal.circleIfftPrepared(self.arena.buffer, prepared);
    }

    pub fn makeRecipes(self: *IfftRecipe, allocator: std.mem.Allocator) ![]recovery.Recipe {
        const recipes = try allocator.alloc(recovery.Recipe, self.destinations.len);
        for (self.destinations, recipes) |binding, *recipe_entry| {
            recipe_entry.* = .{ .logical_id = binding.logical_id, .context = self, .run = run };
        }
        return recipes;
    }

    pub fn execute(self: *IfftRecipe) !void {
        self.accumulated_gpu_ms += try self.metal.circleIfftPrepared(self.arena.buffer, self.prepared);
    }

    fn run(raw: *anyopaque, tick: u16, requested: arena_plan.Binding, _: []u8) !void {
        const self: *IfftRecipe = @ptrCast(@alignCast(raw));
        if (self.last_tick == tick) return;
        var found = false;
        for (self.destinations) |binding| found = found or binding.logical_id == requested.logical_id;
        if (!found) return recovery.RecoveryError.MissingRecipe;
        try self.execute();
        self.last_tick = tick;
    }
};

test "circle IFFT request reset preserves the prepared recipe" {
    var recipe = IfftRecipe{
        .allocator = std.testing.allocator,
        .metal = undefined,
        .arena = undefined,
        .sources = &.{},
        .destinations = &.{},
        .prepared = undefined,
        .log_size = 19,
        .inverse_twiddle_offset_words = 17,
        .scale_factor = 23,
        .last_tick = 41,
        .accumulated_gpu_ms = 12.5,
    };
    recipe.resetForRequest();
    try std.testing.expectEqual(@as(?u16, null), recipe.last_tick);
    try std.testing.expectEqual(@as(f64, 0), recipe.accumulated_gpu_ms);
    try std.testing.expectEqual(@as(u32, 19), recipe.log_size);
    try std.testing.expectEqual(@as(u32, 17), recipe.inverse_twiddle_offset_words);
    try std.testing.expectEqual(@as(u32, 23), recipe.scale_factor);
}
