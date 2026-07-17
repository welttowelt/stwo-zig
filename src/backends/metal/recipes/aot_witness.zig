//! Prepared execution of generated witness kernels over a resident arena.

const std = @import("std");
const arena_plan = @import("../arena_plan.zig");
const recovery = @import("../recovery.zig");
const runtime = @import("../runtime.zig");

pub const Invocation = struct {
    kernel_name: []const u8,
    layout: runtime.WitnessLayout,
    destinations: []const arena_plan.Binding,
    workspace_writes: []const WorkspaceWrite,
};

/// One small arena-resident indirection table consumed by a generated witness
/// kernel. These tables are component-local and may alias, so they are
/// materialized immediately before the owning invocation is dispatched.
pub const WorkspaceWrite = struct {
    destination: arena_plan.Binding,
    binding_offsets: []const arena_plan.Binding = &.{},
    words: []const u32 = &.{},
};

const OwnedWorkspaceWrite = struct {
    destination: arena_plan.Binding,
    words: []u32,
};

/// Executes the canonical recorded witness programs directly against one
/// resident arena. Pipeline creation is AOT-only; every output, lookup slab,
/// and subcomponent slab is tracked as a product of the same prepared batch.
pub const BatchRecipe = struct {
    allocator: std.mem.Allocator,
    metal: *runtime.Runtime,
    arena: *arena_plan.ResidentArena,
    plans: []runtime.WitnessPlan,
    destinations: []arena_plan.Binding,
    workspace_writes: [][]OwnedWorkspaceWrite,
    last_tick: ?u16 = null,
    accumulated_gpu_ms: f64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        metal: *runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        metallib_path: []const u8,
        invocations: []const Invocation,
    ) !BatchRecipe {
        var library = try metal.loadEvalLibrary(metallib_path);
        defer library.deinit();
        return initPlans(allocator, metal, resident_arena, library, null, invocations, true);
    }

    pub fn initSource(
        allocator: std.mem.Allocator,
        metal: *runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        source: []const u8,
        invocations: []const Invocation,
    ) !BatchRecipe {
        var library = try metal.compileEvalLibrary(source);
        defer library.deinit();
        return initPlans(allocator, metal, resident_arena, library, null, invocations, false);
    }

    pub fn initSources(
        allocator: std.mem.Allocator,
        metal: *runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        sources: []const []const u8,
        invocations: []const Invocation,
    ) !BatchRecipe {
        return initPlans(allocator, metal, resident_arena, null, sources, invocations, false);
    }

    fn initPlans(
        allocator: std.mem.Allocator,
        metal: *runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        library: ?runtime.EvalLibrary,
        sources: ?[]const []const u8,
        invocations: []const Invocation,
        serialize: bool,
    ) !BatchRecipe {
        if (invocations.len == 0) return recovery.RecoveryError.BindingSizeMismatch;
        if ((library == null) == (sources == null)) return recovery.RecoveryError.BindingSizeMismatch;
        if (sources) |items| if (items.len != invocations.len) return recovery.RecoveryError.BindingSizeMismatch;
        const plans = try allocator.alloc(runtime.WitnessPlan, invocations.len);
        var initialized: usize = 0;
        errdefer {
            for (plans[0..initialized]) |*plan| plan.deinit();
            allocator.free(plans);
        }
        const workspace_writes = try allocator.alloc([]OwnedWorkspaceWrite, invocations.len);
        var workspaces_initialized: usize = 0;
        errdefer {
            for (workspace_writes[0..workspaces_initialized]) |writes| deinitWorkspaceWrites(allocator, writes);
            allocator.free(workspace_writes);
        }
        var destinations = std.ArrayList(arena_plan.Binding).empty;
        errdefer destinations.deinit(allocator);
        for (invocations, plans, workspace_writes, 0..) |invocation, *plan, *writes, index| {
            if (invocation.kernel_name.len == 0 or invocation.destinations.len == 0 or
                invocation.workspace_writes.len == 0 or invocation.layout.row_count == 0 or
                !std.math.isPowerOfTwo(invocation.layout.row_count))
                return recovery.RecoveryError.BindingSizeMismatch;
            if (sources) |items| {
                var source_library = try metal.compileEvalLibrary(items[index]);
                defer source_library.deinit();
                plan.* = try metal.prepareWitnessFromLibrary(source_library, invocation.kernel_name, invocation.layout);
            } else {
                plan.* = try metal.prepareWitnessFromLibrary(library.?, invocation.kernel_name, invocation.layout);
            }
            initialized += 1;
            writes.* = try initWorkspaceWrites(allocator, invocation.workspace_writes);
            workspaces_initialized += 1;
            for (invocation.destinations) |destination| {
                for (destinations.items) |existing| if (existing.logical_id == destination.logical_id)
                    return recovery.RecoveryError.BindingSizeMismatch;
                try destinations.append(allocator, destination);
            }
        }
        if (serialize) try library.?.serialize();
        return .{
            .allocator = allocator,
            .metal = metal,
            .arena = resident_arena,
            .plans = plans,
            .destinations = try destinations.toOwnedSlice(allocator),
            .workspace_writes = workspace_writes,
        };
    }

    pub fn deinit(self: *BatchRecipe) void {
        for (self.plans) |*plan| plan.deinit();
        self.allocator.free(self.plans);
        self.allocator.free(self.destinations);
        for (self.workspace_writes) |writes| deinitWorkspaceWrites(self.allocator, writes);
        self.allocator.free(self.workspace_writes);
        self.* = undefined;
    }

    /// Clears request-local execution bookkeeping while retaining the prepared
    /// Metal plans and immutable arena workspace descriptions.
    pub fn resetForRequest(self: *BatchRecipe) void {
        self.last_tick = null;
        self.accumulated_gpu_ms = 0;
    }

    pub fn execute(self: *BatchRecipe) !void {
        for (self.plans, 0..) |_, index| try self.executeIndex(index);
    }

    pub fn executeIndex(self: *BatchRecipe, index: usize) !void {
        if (index >= self.plans.len) return recovery.RecoveryError.BindingSizeMismatch;
        try self.materializeWorkspaces(index);
        self.accumulated_gpu_ms += try self.metal.witnessPrepared(self.arena.buffer, self.plans[index]);
    }

    fn materializeWorkspaces(self: *BatchRecipe, index: usize) !void {
        for (self.workspace_writes[index]) |write| {
            const bytes = try self.arena.bytes(write.destination);
            if (bytes.len % 4 != 0 or bytes.len < write.words.len * 4)
                return recovery.RecoveryError.BindingSizeMismatch;
            const aligned: []align(4) u8 = @alignCast(bytes);
            const destination = std.mem.bytesAsSlice(u32, aligned);
            @memset(destination, 0);
            @memcpy(destination[0..write.words.len], write.words);
        }
    }

    pub fn makeRecipes(self: *BatchRecipe, allocator: std.mem.Allocator) ![]recovery.Recipe {
        const recipes = try allocator.alloc(recovery.Recipe, self.destinations.len);
        for (self.destinations, recipes) |destination, *recipe_entry|
            recipe_entry.* = .{ .logical_id = destination.logical_id, .context = self, .run = run };
        return recipes;
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

fn initWorkspaceWrites(
    allocator: std.mem.Allocator,
    source: []const WorkspaceWrite,
) ![]OwnedWorkspaceWrite {
    const result = try allocator.alloc(OwnedWorkspaceWrite, source.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |write| allocator.free(write.words);
        allocator.free(result);
    }
    while (initialized < source.len) : (initialized += 1) {
        const write = source[initialized];
        if ((write.binding_offsets.len != 0 and write.words.len != 0) or
            write.destination.offset_bytes % 4 != 0 or write.destination.size_bytes % 4 != 0)
            return recovery.RecoveryError.BindingSizeMismatch;
        const word_count = if (write.binding_offsets.len != 0) write.binding_offsets.len else write.words.len;
        if (write.destination.size_bytes < word_count * 4)
            return recovery.RecoveryError.BindingSizeMismatch;
        for (write.binding_offsets) |binding| {
            if (binding.offset_bytes % 4 != 0 or binding.offset_bytes / 4 > std.math.maxInt(u32))
                return recovery.RecoveryError.BindingSizeMismatch;
        }
        const words = try allocator.alloc(u32, word_count);
        if (write.binding_offsets.len != 0) {
            for (write.binding_offsets, words) |binding, *word| {
                word.* = @intCast(binding.offset_bytes / 4);
            }
        } else {
            @memcpy(words, write.words);
        }
        result[initialized] = .{ .destination = write.destination, .words = words };
    }
    return result;
}

fn deinitWorkspaceWrites(allocator: std.mem.Allocator, writes: []OwnedWorkspaceWrite) void {
    for (writes) |write| allocator.free(write.words);
    allocator.free(writes);
}

test "AOT witness batch request reset preserves prepared ownership" {
    const plans = [_]runtime.WitnessPlan{.{ .handle = undefined }};
    const destinations = [_]arena_plan.Binding{undefined};
    const workspace_writes = [_][]OwnedWorkspaceWrite{&.{}};
    var recipe = BatchRecipe{
        .allocator = std.testing.allocator,
        .metal = undefined,
        .arena = undefined,
        .plans = @constCast(&plans),
        .destinations = @constCast(&destinations),
        .workspace_writes = @constCast(&workspace_writes),
        .last_tick = 17,
        .accumulated_gpu_ms = 42.5,
    };

    const plans_ptr = recipe.plans.ptr;
    const destinations_ptr = recipe.destinations.ptr;
    const workspace_writes_ptr = recipe.workspace_writes.ptr;
    recipe.resetForRequest();

    try std.testing.expectEqual(@as(?u16, null), recipe.last_tick);
    try std.testing.expectEqual(@as(f64, 0), recipe.accumulated_gpu_ms);
    try std.testing.expectEqual(plans_ptr, recipe.plans.ptr);
    try std.testing.expectEqual(destinations_ptr, recipe.destinations.ptr);
    try std.testing.expectEqual(workspace_writes_ptr, recipe.workspace_writes.ptr);
}
