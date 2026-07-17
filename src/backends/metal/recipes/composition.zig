const std = @import("std");

const M31 = @import("../../../core/fields/m31.zig").M31;
const arena_plan = @import("../arena_plan.zig");
const recovery = @import("../recovery.zig");
const runtime = @import("../runtime.zig");

pub const FinalizeRecipe = struct {
    allocator: std.mem.Allocator,
    metal: *runtime.Runtime,
    arena: *arena_plan.ResidentArena,
    destinations: []arena_plan.Binding,
    prepared: runtime.CompositionFinalizePlan,
    last_tick: ?u16 = null,
    accumulated_gpu_ms: f64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        metal: *runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        accumulators: []const arena_plan.Binding,
        accumulator_logs: []const u32,
        inverse_twiddles: arena_plan.Binding,
        outputs: [8]arena_plan.Binding,
        scale_factor: M31,
    ) !FinalizeRecipe {
        if (accumulators.len == 0 or accumulators.len != accumulator_logs.len or scale_factor.v == 0 or
            inverse_twiddles.offset_bytes % 4 != 0)
            return recovery.RecoveryError.BindingSizeMismatch;
        const offsets = try allocator.alloc(u32, accumulators.len);
        defer allocator.free(offsets);
        for (accumulators, accumulator_logs, offsets) |binding, log_size, *offset| {
            const words = (@as(u64, 1) << @intCast(log_size)) * 4;
            if (binding.offset_bytes % 4 != 0 or binding.size_bytes < words * 4)
                return recovery.RecoveryError.BindingSizeMismatch;
            offset.* = std.math.cast(u32, binding.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch;
        }
        const max_log = accumulator_logs[accumulator_logs.len - 1];
        const output_bytes = (@as(u64, 1) << @intCast(max_log - 1)) * 4;
        var output_offsets: [8]u32 = undefined;
        for (outputs, &output_offsets) |binding, *offset| {
            if (binding.offset_bytes % 4 != 0 or binding.size_bytes != output_bytes)
                return recovery.RecoveryError.BindingSizeMismatch;
            offset.* = std.math.cast(u32, binding.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch;
        }
        var prepared = try metal.prepareCompositionFinalize(
            offsets,
            accumulator_logs,
            std.math.cast(u32, inverse_twiddles.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch,
            output_offsets,
            scale_factor.v,
        );
        errdefer prepared.deinit();
        return .{
            .allocator = allocator,
            .metal = metal,
            .arena = resident_arena,
            .destinations = try allocator.dupe(arena_plan.Binding, &outputs),
            .prepared = prepared,
        };
    }

    pub fn deinit(self: *FinalizeRecipe) void {
        self.prepared.deinit();
        self.allocator.free(self.destinations);
        self.* = undefined;
    }

    pub fn makeRecipes(self: *FinalizeRecipe, allocator: std.mem.Allocator) ![]recovery.Recipe {
        const recipes = try allocator.alloc(recovery.Recipe, self.destinations.len);
        for (self.destinations, recipes) |binding, *entry| entry.* = .{
            .logical_id = binding.logical_id,
            .context = self,
            .run = run,
        };
        return recipes;
    }

    fn run(raw: *anyopaque, tick: u16, requested: arena_plan.Binding, _: []u8) !void {
        const self: *FinalizeRecipe = @ptrCast(@alignCast(raw));
        if (self.last_tick == tick) return;
        var found = false;
        for (self.destinations) |binding| found = found or binding.logical_id == requested.logical_id;
        if (!found) return recovery.RecoveryError.MissingRecipe;
        self.accumulated_gpu_ms += try self.metal.compositionFinalizePrepared(self.arena.buffer, self.prepared);
        self.last_tick = tick;
    }
};

/// Owns the complete resident composition substitution. The front plan reuses
/// one LDE tile across components; the finalize plan lifts and interpolates the
/// accumulator slab into the eight committed coefficient columns. Neither
/// boundary exposes host values or compatibility readback.
pub const Recipe = struct {
    allocator: std.mem.Allocator,
    metal: *runtime.Runtime,
    arena: *arena_plan.ResidentArena,
    destinations: []arena_plan.Binding,
    front: runtime.CompositionFrontPlan,
    finalize: runtime.CompositionFinalizePlan,
    complete: bool,
    last_tick: ?u16 = null,
    accumulated_gpu_ms: f64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        metal: *runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        front: runtime.CompositionFrontPlan,
        finalize: runtime.CompositionFinalizePlan,
        outputs: [8]arena_plan.Binding,
        complete: bool,
    ) !Recipe {
        for (outputs) |binding| if (binding.offset_bytes % 4 != 0 or binding.size_bytes == 0)
            return recovery.RecoveryError.BindingSizeMismatch;
        return .{
            .allocator = allocator,
            .metal = metal,
            .arena = resident_arena,
            .destinations = try allocator.dupe(arena_plan.Binding, &outputs),
            .front = front,
            .finalize = finalize,
            .complete = complete,
        };
    }

    pub fn deinit(self: *Recipe) void {
        self.finalize.deinit();
        self.front.deinit();
        self.allocator.free(self.destinations);
        self.* = undefined;
    }

    pub fn makeRecipes(self: *Recipe, allocator: std.mem.Allocator) ![]recovery.Recipe {
        if (!self.complete) return recovery.RecoveryError.MissingRecipe;
        const recipes = try allocator.alloc(recovery.Recipe, self.destinations.len);
        for (self.destinations, recipes) |binding, *entry| entry.* = .{
            .logical_id = binding.logical_id,
            .context = self,
            .run = run,
        };
        return recipes;
    }

    pub fn execute(self: *Recipe) !void {
        self.accumulated_gpu_ms += if (self.complete)
            try self.metal.compositionPrepared(self.arena.buffer, self.front, self.finalize)
        else
            try self.metal.compositionFrontPrepared(self.arena.buffer, self.front);
    }

    pub fn isComplete(self: Recipe) bool {
        return self.complete;
    }

    fn run(raw: *anyopaque, tick: u16, requested: arena_plan.Binding, _: []u8) !void {
        const self: *Recipe = @ptrCast(@alignCast(raw));
        if (self.last_tick == tick) return;
        var found = false;
        for (self.destinations) |binding| found = found or binding.logical_id == requested.logical_id;
        if (!found) return recovery.RecoveryError.MissingRecipe;
        try self.execute();
        self.last_tick = tick;
    }
};
