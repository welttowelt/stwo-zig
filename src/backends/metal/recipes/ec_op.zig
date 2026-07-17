const std = @import("std");

const arena_plan = @import("../arena_plan.zig");
const recovery = @import("../recovery.zig");
const runtime = @import("../runtime.zig");

pub const Bindings = struct {
    execution_columns: [37]arena_plan.Binding,
    trace_columns: [273]arena_plan.Binding,
    partial_columns: [127]arena_plan.Binding,
    multiplicities: [4]arena_plan.Binding,
    lookup: arena_plan.Binding,
    segment_start: arena_plan.Binding,
    scratch: arena_plan.Binding,
    row_count: u32,
};

pub const OutputMode = enum {
    base,
    lookup,
};

pub const Recipe = struct {
    allocator: std.mem.Allocator,
    metal: *runtime.Runtime,
    arena: *arena_plan.ResidentArena,
    destinations: []arena_plan.Binding,
    prepared: runtime.EcOpPlan,
    last_tick: ?u16 = null,
    accumulated_gpu_ms: f64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        metal: *runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        bindings: Bindings,
        output_mode: OutputMode,
    ) !Recipe {
        if (bindings.row_count < 16 or !std.math.isPowerOfTwo(bindings.row_count))
            return recovery.RecoveryError.BindingSizeMismatch;
        const column_bytes = @as(u64, bindings.row_count) * 4;
        const partial_bytes = column_bytes * 256;
        const asOffset = struct {
            fn get(binding: arena_plan.Binding) !u32 {
                const address_limit_bytes = (@as(u64, std.math.maxInt(u32)) + 1) * @sizeOf(u32);
                if (binding.offset_bytes % @sizeOf(u32) != 0 or
                    binding.size_bytes % @sizeOf(u32) != 0 or
                    binding.offset_bytes > address_limit_bytes or
                    binding.size_bytes > address_limit_bytes - binding.offset_bytes)
                {
                    std.debug.print(
                        "ec_op_high_binding id={} offset={} end={} words={} limit_bytes={}\n",
                        .{
                            binding.logical_id,
                            binding.offset_bytes,
                            binding.offset_bytes + binding.size_bytes,
                            binding.size_bytes / @sizeOf(u32),
                            address_limit_bytes,
                        },
                    );
                    return recovery.RecoveryError.BindingSizeMismatch;
                }
                return std.math.cast(u32, binding.offset_bytes / 4) orelse recovery.RecoveryError.BindingSizeMismatch;
            }
        }.get;
        var execution_offsets: [37]u32 = undefined;
        for (bindings.execution_columns, &execution_offsets) |binding, *offset| {
            if (binding.size_bytes < column_bytes) return recovery.RecoveryError.BindingSizeMismatch;
            offset.* = try asOffset(binding);
        }
        var trace_offsets: [273]u32 = undefined;
        for (bindings.trace_columns, &trace_offsets) |binding, *offset| {
            if (binding.size_bytes != column_bytes) return recovery.RecoveryError.BindingSizeMismatch;
            offset.* = try asOffset(binding);
        }
        var partial_offsets: [127]u32 = undefined;
        for (bindings.partial_columns, &partial_offsets) |binding, *offset| {
            if (binding.size_bytes != partial_bytes) return recovery.RecoveryError.BindingSizeMismatch;
            offset.* = try asOffset(binding);
        }
        var multiplicity_offsets: [4]u32 = undefined;
        for (bindings.multiplicities, &multiplicity_offsets) |binding, *offset| {
            if (binding.size_bytes == 0) return recovery.RecoveryError.BindingSizeMismatch;
            offset.* = try asOffset(binding);
        }
        // The current Metal EC kernel uses threadgroup prefix/suffix products;
        // `scratch` is retained in the ABI for schedule compatibility only.
        if (bindings.lookup.size_bytes != column_bytes * 488 or bindings.segment_start.size_bytes != 4 or
            bindings.scratch.size_bytes < 4)
            return recovery.RecoveryError.BindingSizeMismatch;
        var prepared = try metal.prepareEcOp(
            execution_offsets,
            trace_offsets,
            partial_offsets,
            multiplicity_offsets,
            try asOffset(bindings.lookup),
            try asOffset(bindings.segment_start),
            try asOffset(bindings.scratch),
            bindings.row_count,
            output_mode == .base,
            output_mode == .lookup,
        );
        errdefer prepared.deinit();
        const destination_count: usize = if (output_mode == .base) 273 + 127 else 1;
        const destinations = try allocator.alloc(arena_plan.Binding, destination_count);
        if (output_mode == .base) {
            @memcpy(destinations[0..273], &bindings.trace_columns);
            @memcpy(destinations[273..], &bindings.partial_columns);
        } else {
            destinations[0] = bindings.lookup;
        }
        return .{ .allocator = allocator, .metal = metal, .arena = resident_arena, .destinations = destinations, .prepared = prepared };
    }

    pub fn deinit(self: *Recipe) void {
        self.prepared.deinit();
        self.allocator.free(self.destinations);
        self.* = undefined;
    }

    pub fn makeRecipes(self: *Recipe, allocator: std.mem.Allocator) ![]recovery.Recipe {
        const recipes = try allocator.alloc(recovery.Recipe, self.destinations.len);
        for (self.destinations, recipes) |destination, *recipe_entry| {
            recipe_entry.* = .{ .logical_id = destination.logical_id, .context = self, .run = run };
        }
        return recipes;
    }

    pub fn execute(self: *Recipe) !void {
        self.accumulated_gpu_ms += try self.metal.ecOpPrepared(self.arena.buffer, self.prepared);
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
