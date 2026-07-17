const std = @import("std");

const arena_plan = @import("../arena_plan.zig");
const recovery = @import("../recovery.zig");
const runtime = @import("../runtime.zig");

pub const Bindings = struct {
    descriptors: []const u32,
    row_count: u32,
    sources: []const arena_plan.Binding,
    multiplicities: []const arena_plan.Binding,
    destination: arena_plan.Binding,
};

/// Materializes every fixed-table LookupInputs slab with one Metal command
/// buffer. The descriptors are immutable setup data; all variable columns and
/// outputs are addressed inside the resident arena.
pub const BatchRecipe = struct {
    allocator: std.mem.Allocator,
    metal: *runtime.Runtime,
    arena: *arena_plan.ResidentArena,
    plans: []runtime.FixedTablePlan,
    batch: runtime.FixedTableBatchPlan,
    single_batches: []runtime.FixedTableBatchPlan,
    destinations: []arena_plan.Binding,
    last_tick: ?u16 = null,
    accumulated_gpu_ms: f64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        metal: *runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        bindings: []const Bindings,
    ) !BatchRecipe {
        if (bindings.len == 0 or bindings.len > 64) return recovery.RecoveryError.BindingSizeMismatch;
        const plans = try allocator.alloc(runtime.FixedTablePlan, bindings.len);
        var initialized: usize = 0;
        errdefer {
            for (plans[0..initialized]) |*plan| plan.deinit();
            allocator.free(plans);
        }
        const destinations = try allocator.alloc(arena_plan.Binding, bindings.len);
        errdefer allocator.free(destinations);
        for (bindings, plans, destinations, 0..) |binding, *plan, *destination, binding_index| {
            if (binding.row_count == 0 or binding.descriptors.len == 0 or binding.descriptors.len % 4 != 0 or
                binding.multiplicities.len == 0 or binding.destination.offset_bytes % 4 != 0 or
                binding.destination.size_bytes != @as(u64, binding.row_count) * (binding.descriptors.len / 4) * 4)
            {
                std.debug.print("fixed_table_invalid index={d} rows={d} descriptors={d} multiplicities={d} destination_offset={d} destination_size={d} expected_size={d}\n", .{
                    binding_index,
                    binding.row_count,
                    binding.descriptors.len,
                    binding.multiplicities.len,
                    binding.destination.offset_bytes,
                    binding.destination.size_bytes,
                    @as(u64, binding.row_count) * (binding.descriptors.len / 4) * 4,
                });
                return recovery.RecoveryError.BindingSizeMismatch;
            }
            const source_offsets = try allocator.alloc(u32, binding.sources.len);
            defer allocator.free(source_offsets);
            const multiplicity_offsets = try allocator.alloc(u32, binding.multiplicities.len);
            defer allocator.free(multiplicity_offsets);
            for (binding.sources, source_offsets) |source, *offset| {
                if (source.offset_bytes % 4 != 0 or source.size_bytes != @as(u64, binding.row_count) * 4) {
                    std.debug.print("fixed_table_source_invalid index={d} rows={d} offset={d} size={d} expected_size={d}\n", .{
                        binding_index, binding.row_count, source.offset_bytes, source.size_bytes, @as(u64, binding.row_count) * 4,
                    });
                    return recovery.RecoveryError.BindingSizeMismatch;
                }
                offset.* = std.math.cast(u32, source.offset_bytes / 4) orelse {
                    std.debug.print("fixed_table_source_offset_overflow index={d} offset={d}\n", .{ binding_index, source.offset_bytes });
                    return recovery.RecoveryError.BindingSizeMismatch;
                };
            }
            for (binding.multiplicities, multiplicity_offsets) |multiplicity, *offset| {
                if (multiplicity.offset_bytes % 4 != 0 or multiplicity.size_bytes != @as(u64, binding.row_count) * 4) {
                    std.debug.print("fixed_table_multiplicity_invalid index={d} rows={d} offset={d} size={d} expected_size={d}\n", .{
                        binding_index, binding.row_count, multiplicity.offset_bytes, multiplicity.size_bytes, @as(u64, binding.row_count) * 4,
                    });
                    return recovery.RecoveryError.BindingSizeMismatch;
                }
                offset.* = std.math.cast(u32, multiplicity.offset_bytes / 4) orelse {
                    std.debug.print("fixed_table_multiplicity_offset_overflow index={d} offset={d}\n", .{ binding_index, multiplicity.offset_bytes });
                    return recovery.RecoveryError.BindingSizeMismatch;
                };
            }
            const destination_offset = std.math.cast(u32, binding.destination.offset_bytes / 4) orelse {
                std.debug.print("fixed_table_destination_offset_overflow index={d} offset={d}\n", .{ binding_index, binding.destination.offset_bytes });
                return recovery.RecoveryError.BindingSizeMismatch;
            };
            plan.* = try metal.prepareFixedTable(
                binding.descriptors,
                source_offsets,
                multiplicity_offsets,
                destination_offset,
                binding.row_count,
            );
            initialized += 1;
            destination.* = binding.destination;
        }
        var batch = try metal.prepareFixedTableBatch(plans);
        errdefer batch.deinit();
        const single_batches = try allocator.alloc(runtime.FixedTableBatchPlan, plans.len);
        var singles_initialized: usize = 0;
        errdefer {
            for (single_batches[0..singles_initialized]) |*single| single.deinit();
            allocator.free(single_batches);
        }
        while (singles_initialized < plans.len) : (singles_initialized += 1)
            single_batches[singles_initialized] = try metal.prepareFixedTableBatch(plans[singles_initialized .. singles_initialized + 1]);
        return .{
            .allocator = allocator,
            .metal = metal,
            .arena = resident_arena,
            .plans = plans,
            .batch = batch,
            .single_batches = single_batches,
            .destinations = destinations,
        };
    }

    pub fn deinit(self: *BatchRecipe) void {
        for (self.single_batches) |*single| single.deinit();
        self.allocator.free(self.single_batches);
        self.batch.deinit();
        for (self.plans) |*plan| plan.deinit();
        self.allocator.free(self.plans);
        self.allocator.free(self.destinations);
        self.* = undefined;
    }

    /// Clears request-local recovery bookkeeping while retaining the prepared
    /// fixed-table plans and stable resident-arena bindings.
    pub fn resetForRequest(self: *BatchRecipe) void {
        self.last_tick = null;
        self.accumulated_gpu_ms = 0;
    }

    pub fn makeRecipes(self: *BatchRecipe, allocator: std.mem.Allocator) ![]recovery.Recipe {
        const recipes = try allocator.alloc(recovery.Recipe, self.destinations.len);
        for (self.destinations, recipes) |destination, *recipe_entry| {
            recipe_entry.* = .{ .logical_id = destination.logical_id, .context = self, .run = run };
        }
        return recipes;
    }

    pub fn execute(self: *BatchRecipe) !void {
        self.accumulated_gpu_ms += try self.metal.fixedTableBatchPrepared(self.arena.buffer, self.batch);
    }

    pub fn executeIndex(self: *BatchRecipe, index: usize) !void {
        if (index >= self.single_batches.len) return recovery.RecoveryError.BindingSizeMismatch;
        self.accumulated_gpu_ms += try self.metal.fixedTableBatchPrepared(self.arena.buffer, self.single_batches[index]);
    }

    fn run(raw: *anyopaque, tick: u16, requested: arena_plan.Binding, _: []u8) !void {
        const self: *BatchRecipe = @ptrCast(@alignCast(raw));
        if (self.last_tick == tick) return;
        var found = false;
        for (self.destinations) |destination| found = found or destination.logical_id == requested.logical_id;
        if (!found) return recovery.RecoveryError.MissingRecipe;
        try self.execute();
        self.last_tick = tick;
    }
};

test "fixed table batch request reset preserves prepared ownership" {
    const plans = [_]runtime.FixedTablePlan{.{ .handle = undefined }};
    const single_batches = [_]runtime.FixedTableBatchPlan{.{ .handle = undefined }};
    const destinations = [_]arena_plan.Binding{undefined};
    var recipe = BatchRecipe{
        .allocator = std.testing.allocator,
        .metal = undefined,
        .arena = undefined,
        .plans = @constCast(&plans),
        .batch = undefined,
        .single_batches = @constCast(&single_batches),
        .destinations = @constCast(&destinations),
        .last_tick = 29,
        .accumulated_gpu_ms = 31.25,
    };

    const plans_ptr = recipe.plans.ptr;
    const single_batches_ptr = recipe.single_batches.ptr;
    const destinations_ptr = recipe.destinations.ptr;
    recipe.resetForRequest();

    try std.testing.expectEqual(@as(?u16, null), recipe.last_tick);
    try std.testing.expectEqual(@as(f64, 0), recipe.accumulated_gpu_ms);
    try std.testing.expectEqual(plans_ptr, recipe.plans.ptr);
    try std.testing.expectEqual(single_batches_ptr, recipe.single_batches.ptr);
    try std.testing.expectEqual(destinations_ptr, recipe.destinations.ptr);
}
