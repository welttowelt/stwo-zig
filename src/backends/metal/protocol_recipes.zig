const std = @import("std");
const M31 = @import("../../core/fields/m31.zig").M31;
const QM31 = @import("../../core/fields/qm31.zig").QM31;
const canonic = @import("../../core/poly/circle/canonic.zig");
const core_utils = @import("../../core/utils.zig");
const circle_poly = @import("../../prover/poly/circle/poly.zig");
const twiddles_mod = @import("../../prover/poly/twiddles.zig");
const arena_plan = @import("arena_plan.zig");
const recovery = @import("recovery.zig");
const runtime = @import("runtime.zig");
const blake2s_channel = @import("../../core/channel/blake2s.zig");
const blake2_hash = @import("../../core/vcs/blake2_hash.zig");
const fri_geometry = @import("../../core/fri/geometry.zig");

pub const FriGeometry = fri_geometry.FriGeometry;

pub const CopyRecipe = struct {
    access: recovery.BufferAccess,
    source: arena_plan.Binding,

    pub fn recipe(self: *CopyRecipe, logical_id: u32) recovery.Recipe {
        return .{ .logical_id = logical_id, .context = self, .run = run };
    }

    fn run(raw: *anyopaque, _: u16, _: arena_plan.Binding, destination: []u8) !void {
        const self: *CopyRecipe = @ptrCast(@alignCast(raw));
        const source = try self.access.bytes(self.source);
        if (source.len != destination.len) return recovery.RecoveryError.BindingSizeMismatch;
        @memcpy(destination, source);
    }
};

/// Restores deterministic adapter/witness seeds from compact host ownership.
/// This is recomputation input, not a second Metal allocation.
pub const HostCopyRecipe = struct {
    source: []const u8,

    pub fn recipe(self: *HostCopyRecipe, logical_id: u32) recovery.Recipe {
        return .{ .logical_id = logical_id, .context = self, .run = run };
    }

    fn run(raw: *anyopaque, _: u16, _: arena_plan.Binding, destination: []u8) !void {
        const self: *HostCopyRecipe = @ptrCast(@alignCast(raw));
        if (self.source.len != destination.len) return recovery.RecoveryError.BindingSizeMismatch;
        @memcpy(destination, self.source);
    }
};

pub const AotWitnessInvocation = struct {
    kernel_name: []const u8,
    layout: runtime.WitnessLayout,
    destinations: []const arena_plan.Binding,
    workspace_writes: []const AotWorkspaceWrite,
};

/// One small arena-resident indirection table consumed by a generated witness
/// kernel. These tables are component-local and may alias, so they are
/// materialized immediately before the owning invocation is dispatched.
pub const AotWorkspaceWrite = struct {
    destination: arena_plan.Binding,
    binding_offsets: []const arena_plan.Binding = &.{},
    words: []const u32 = &.{},
};

const OwnedAotWorkspaceWrite = struct {
    destination: arena_plan.Binding,
    words: []u32,
};

/// Executes the canonical recorded witness programs directly against one
/// resident arena. Pipeline creation is AOT-only; every output, lookup slab,
/// and subcomponent slab is tracked as a product of the same prepared batch.
pub const AotWitnessBatchRecipe = struct {
    allocator: std.mem.Allocator,
    metal: *runtime.Runtime,
    arena: *arena_plan.ResidentArena,
    plans: []runtime.WitnessPlan,
    destinations: []arena_plan.Binding,
    workspace_writes: [][]OwnedAotWorkspaceWrite,
    last_tick: ?u16 = null,
    accumulated_gpu_ms: f64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        metal: *runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        metallib_path: []const u8,
        invocations: []const AotWitnessInvocation,
    ) !AotWitnessBatchRecipe {
        var library = try metal.loadEvalLibrary(metallib_path);
        defer library.deinit();
        return initPlans(allocator, metal, resident_arena, library, null, invocations, true);
    }

    pub fn initSource(
        allocator: std.mem.Allocator,
        metal: *runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        source: []const u8,
        invocations: []const AotWitnessInvocation,
    ) !AotWitnessBatchRecipe {
        var library = try metal.compileEvalLibrary(source);
        defer library.deinit();
        return initPlans(allocator, metal, resident_arena, library, null, invocations, false);
    }

    pub fn initSources(
        allocator: std.mem.Allocator,
        metal: *runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        sources: []const []const u8,
        invocations: []const AotWitnessInvocation,
    ) !AotWitnessBatchRecipe {
        return initPlans(allocator, metal, resident_arena, null, sources, invocations, false);
    }

    fn initPlans(
        allocator: std.mem.Allocator,
        metal: *runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        library: ?runtime.EvalLibrary,
        sources: ?[]const []const u8,
        invocations: []const AotWitnessInvocation,
        serialize: bool,
    ) !AotWitnessBatchRecipe {
        if (invocations.len == 0) return recovery.RecoveryError.BindingSizeMismatch;
        if ((library == null) == (sources == null)) return recovery.RecoveryError.BindingSizeMismatch;
        if (sources) |items| if (items.len != invocations.len) return recovery.RecoveryError.BindingSizeMismatch;
        const plans = try allocator.alloc(runtime.WitnessPlan, invocations.len);
        var initialized: usize = 0;
        errdefer {
            for (plans[0..initialized]) |*plan| plan.deinit();
            allocator.free(plans);
        }
        const workspace_writes = try allocator.alloc([]OwnedAotWorkspaceWrite, invocations.len);
        var workspaces_initialized: usize = 0;
        errdefer {
            for (workspace_writes[0..workspaces_initialized]) |writes| deinitAotWorkspaceWrites(allocator, writes);
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
            writes.* = try initAotWorkspaceWrites(allocator, invocation.workspace_writes);
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

    pub fn deinit(self: *AotWitnessBatchRecipe) void {
        for (self.plans) |*plan| plan.deinit();
        self.allocator.free(self.plans);
        self.allocator.free(self.destinations);
        for (self.workspace_writes) |writes| deinitAotWorkspaceWrites(self.allocator, writes);
        self.allocator.free(self.workspace_writes);
        self.* = undefined;
    }

    /// Clears request-local execution bookkeeping while retaining the prepared
    /// Metal plans and immutable arena workspace descriptions.
    pub fn resetForRequest(self: *AotWitnessBatchRecipe) void {
        self.last_tick = null;
        self.accumulated_gpu_ms = 0;
    }

    pub fn execute(self: *AotWitnessBatchRecipe) !void {
        for (self.plans, 0..) |_, index| try self.executeIndex(index);
    }

    pub fn executeIndex(self: *AotWitnessBatchRecipe, index: usize) !void {
        if (index >= self.plans.len) return recovery.RecoveryError.BindingSizeMismatch;
        try self.materializeWorkspaces(index);
        self.accumulated_gpu_ms += try self.metal.witnessPrepared(self.arena.buffer, self.plans[index]);
    }

    fn materializeWorkspaces(self: *AotWitnessBatchRecipe, index: usize) !void {
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

    pub fn makeRecipes(self: *AotWitnessBatchRecipe, allocator: std.mem.Allocator) ![]recovery.Recipe {
        const recipes = try allocator.alloc(recovery.Recipe, self.destinations.len);
        for (self.destinations, recipes) |destination, *recipe_entry|
            recipe_entry.* = .{ .logical_id = destination.logical_id, .context = self, .run = run };
        return recipes;
    }

    fn run(raw: *anyopaque, tick: u16, requested: arena_plan.Binding, _: []u8) !void {
        const self: *AotWitnessBatchRecipe = @ptrCast(@alignCast(raw));
        if (self.last_tick == tick) return;
        var found = false;
        for (self.destinations) |destination| found = found or destination.logical_id == requested.logical_id;
        if (!found) return recovery.RecoveryError.MissingRecipe;
        try self.execute();
        self.last_tick = tick;
    }
};

fn initAotWorkspaceWrites(
    allocator: std.mem.Allocator,
    source: []const AotWorkspaceWrite,
) ![]OwnedAotWorkspaceWrite {
    const result = try allocator.alloc(OwnedAotWorkspaceWrite, source.len);
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

fn deinitAotWorkspaceWrites(allocator: std.mem.Allocator, writes: []OwnedAotWorkspaceWrite) void {
    for (writes) |write| allocator.free(write.words);
    allocator.free(writes);
}

/// Rebuilds one coefficient/evaluation column from another resident column.
/// Copy and transform both target the final arena slot; no intermediate device
/// allocation or compatibility readback is introduced.
pub const CircleTransformRecipe = struct {
    metal: *runtime.Runtime,
    access: recovery.BufferAccess,
    source: arena_plan.Binding,
    twiddles: []const M31,
    log_size: u32,
    inverse: bool,
    accumulated_gpu_ms: f64 = 0,

    pub fn recipe(self: *CircleTransformRecipe, logical_id: u32) recovery.Recipe {
        return .{ .logical_id = logical_id, .context = self, .run = run };
    }

    fn run(raw: *anyopaque, _: u16, binding: arena_plan.Binding, destination_bytes: []u8) !void {
        const self: *CircleTransformRecipe = @ptrCast(@alignCast(raw));
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
pub const CircleLdeRecipe = struct {
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
    ) !CircleLdeRecipe {
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

    pub fn deinit(self: *CircleLdeRecipe) void {
        self.prepared.deinit();
        self.allocator.free(self.destinations);
        self.* = undefined;
    }

    pub fn makeRecipes(self: *CircleLdeRecipe, allocator: std.mem.Allocator) ![]recovery.Recipe {
        const recipes = try allocator.alloc(recovery.Recipe, self.destinations.len);
        for (self.destinations, recipes) |binding, *recipe_entry| {
            recipe_entry.* = .{ .logical_id = binding.logical_id, .context = self, .run = run };
        }
        return recipes;
    }

    fn run(raw: *anyopaque, tick: u16, requested: arena_plan.Binding, _: []u8) !void {
        const self: *CircleLdeRecipe = @ptrCast(@alignCast(raw));
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
pub const CircleIfftRecipe = struct {
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
    ) !CircleIfftRecipe {
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

    pub fn deinit(self: *CircleIfftRecipe) void {
        self.prepared.deinit();
        self.allocator.free(self.sources);
        self.allocator.free(self.destinations);
        self.* = undefined;
    }

    /// Clears bookkeeping that is scoped to one proof without rebuilding the
    /// retained Metal interpolation plan.
    pub fn resetForRequest(self: *CircleIfftRecipe) void {
        self.last_tick = null;
        self.accumulated_gpu_ms = 0;
    }

    pub fn executeColumn(self: *CircleIfftRecipe, column: usize) !f64 {
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

    pub fn makeRecipes(self: *CircleIfftRecipe, allocator: std.mem.Allocator) ![]recovery.Recipe {
        const recipes = try allocator.alloc(recovery.Recipe, self.destinations.len);
        for (self.destinations, recipes) |binding, *recipe_entry| {
            recipe_entry.* = .{ .logical_id = binding.logical_id, .context = self, .run = run };
        }
        return recipes;
    }

    pub fn execute(self: *CircleIfftRecipe) !void {
        self.accumulated_gpu_ms += try self.metal.circleIfftPrepared(self.arena.buffer, self.prepared);
    }

    fn run(raw: *anyopaque, tick: u16, requested: arena_plan.Binding, _: []u8) !void {
        const self: *CircleIfftRecipe = @ptrCast(@alignCast(raw));
        if (self.last_tick == tick) return;
        var found = false;
        for (self.destinations) |binding| found = found or binding.logical_id == requested.logical_id;
        if (!found) return recovery.RecoveryError.MissingRecipe;
        try self.execute();
        self.last_tick = tick;
    }
};

test "Circle IFFT request reset preserves the prepared recipe" {
    var recipe = CircleIfftRecipe{
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

pub const FixedTableBindings = struct {
    descriptors: []const u32,
    row_count: u32,
    sources: []const arena_plan.Binding,
    multiplicities: []const arena_plan.Binding,
    destination: arena_plan.Binding,
};

/// Materializes every fixed-table LookupInputs slab with one Metal command
/// buffer. The descriptors are immutable setup data; all variable columns and
/// outputs are addressed inside the resident arena.
pub const FixedTableBatchRecipe = struct {
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
        bindings: []const FixedTableBindings,
    ) !FixedTableBatchRecipe {
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

    pub fn deinit(self: *FixedTableBatchRecipe) void {
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
    pub fn resetForRequest(self: *FixedTableBatchRecipe) void {
        self.last_tick = null;
        self.accumulated_gpu_ms = 0;
    }

    pub fn makeRecipes(self: *FixedTableBatchRecipe, allocator: std.mem.Allocator) ![]recovery.Recipe {
        const recipes = try allocator.alloc(recovery.Recipe, self.destinations.len);
        for (self.destinations, recipes) |destination, *recipe_entry| {
            recipe_entry.* = .{ .logical_id = destination.logical_id, .context = self, .run = run };
        }
        return recipes;
    }

    pub fn execute(self: *FixedTableBatchRecipe) !void {
        self.accumulated_gpu_ms += try self.metal.fixedTableBatchPrepared(self.arena.buffer, self.batch);
    }

    pub fn executeIndex(self: *FixedTableBatchRecipe, index: usize) !void {
        if (index >= self.single_batches.len) return recovery.RecoveryError.BindingSizeMismatch;
        self.accumulated_gpu_ms += try self.metal.fixedTableBatchPrepared(self.arena.buffer, self.single_batches[index]);
    }

    fn run(raw: *anyopaque, tick: u16, requested: arena_plan.Binding, _: []u8) !void {
        const self: *FixedTableBatchRecipe = @ptrCast(@alignCast(raw));
        if (self.last_tick == tick) return;
        var found = false;
        for (self.destinations) |destination| found = found or destination.logical_id == requested.logical_id;
        if (!found) return recovery.RecoveryError.MissingRecipe;
        try self.execute();
        self.last_tick = tick;
    }
};

pub const MerkleParentChainRecipe = struct {
    allocator: std.mem.Allocator,
    metal: *runtime.Runtime,
    arena: *arena_plan.ResidentArena,
    destinations: []arena_plan.Binding,
    prepared: runtime.MerkleParentChainPlan,
    last_tick: ?u16 = null,
    accumulated_gpu_ms: f64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        metal: *runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        layers_bottom_up: []const arena_plan.Binding,
        node_seed: [8]u32,
    ) !MerkleParentChainRecipe {
        if (layers_bottom_up.len < 2) return recovery.RecoveryError.BindingSizeMismatch;
        const level_count = layers_bottom_up.len - 1;
        const child_offsets = try allocator.alloc(u32, level_count);
        defer allocator.free(child_offsets);
        const destination_offsets = try allocator.alloc(u32, level_count);
        defer allocator.free(destination_offsets);
        const parent_counts = try allocator.alloc(u32, level_count);
        defer allocator.free(parent_counts);
        for (layers_bottom_up[0..level_count], layers_bottom_up[1..], child_offsets, destination_offsets, parent_counts) |child, destination, *child_offset, *destination_offset, *parent_count| {
            if (child.offset_bytes % 4 != 0 or destination.offset_bytes % 4 != 0 or destination.size_bytes < 32 or
                child.size_bytes != destination.size_bytes * 2 or destination.size_bytes % 32 != 0)
                return recovery.RecoveryError.BindingSizeMismatch;
            child_offset.* = std.math.cast(u32, child.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch;
            destination_offset.* = std.math.cast(u32, destination.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch;
            parent_count.* = std.math.cast(u32, destination.size_bytes / 32) orelse return recovery.RecoveryError.BindingSizeMismatch;
        }
        var prepared = try metal.prepareMerkleParentChain(child_offsets, destination_offsets, parent_counts, node_seed);
        errdefer prepared.deinit();
        return .{
            .allocator = allocator,
            .metal = metal,
            .arena = resident_arena,
            .destinations = try allocator.dupe(arena_plan.Binding, layers_bottom_up[1..]),
            .prepared = prepared,
        };
    }

    pub fn deinit(self: *MerkleParentChainRecipe) void {
        self.prepared.deinit();
        self.allocator.free(self.destinations);
        self.* = undefined;
    }

    pub fn makeRecipes(self: *MerkleParentChainRecipe, allocator: std.mem.Allocator) ![]recovery.Recipe {
        const recipes = try allocator.alloc(recovery.Recipe, self.destinations.len);
        for (self.destinations, recipes) |destination, *recipe_entry| {
            recipe_entry.* = .{ .logical_id = destination.logical_id, .context = self, .run = run };
        }
        return recipes;
    }

    fn run(raw: *anyopaque, tick: u16, requested: arena_plan.Binding, _: []u8) !void {
        const self: *MerkleParentChainRecipe = @ptrCast(@alignCast(raw));
        if (self.last_tick == tick) return;
        var found = false;
        for (self.destinations) |destination| found = found or destination.logical_id == requested.logical_id;
        if (!found) return recovery.RecoveryError.MissingRecipe;
        self.accumulated_gpu_ms += try self.metal.merkleParentChainPrepared(self.arena.buffer, self.prepared);
        self.last_tick = tick;
    }
};

/// Regenerates a complete commitment from resident evaluations. Lower levels
/// ping-pong through the epoch-local leaf/parent workspaces; retained layers
/// are written directly and stay device-owned through decommitment.
pub const MerkleCommitRecipe = struct {
    allocator: std.mem.Allocator,
    metal: *runtime.Runtime,
    arena: *arena_plan.ResidentArena,
    destinations: []arena_plan.Binding,
    prepared: runtime.ResidentMerklePlan,
    last_tick: ?u16 = null,
    accumulated_gpu_ms: f64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        metal: *runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        evaluations: []const arena_plan.Binding,
        leaf_workspace: arena_plan.Binding,
        parent_workspace: arena_plan.Binding,
        retained_layers_bottom_up: []const arena_plan.Binding,
        leaf_seed: [8]u32,
        node_seed: [8]u32,
    ) !MerkleCommitRecipe {
        if (evaluations.len == 0 or retained_layers_bottom_up.len == 0)
            return recovery.RecoveryError.BindingSizeMismatch;
        const asOffset = struct {
            fn get(binding: arena_plan.Binding) !u32 {
                if (binding.offset_bytes % 256 != 0) return recovery.RecoveryError.BindingSizeMismatch;
                return std.math.cast(u32, binding.offset_bytes / 4) orelse recovery.RecoveryError.BindingSizeMismatch;
            }
        }.get;
        const source_offsets = try allocator.alloc(u32, evaluations.len);
        defer allocator.free(source_offsets);
        const source_logs = try allocator.alloc(u32, evaluations.len);
        defer allocator.free(source_logs);
        var maximum_source_log: u32 = 0;
        var previous_size: u64 = 0;
        for (evaluations, source_offsets, source_logs) |evaluation, *offset, *log_size| {
            if (evaluation.size_bytes < 64 or evaluation.size_bytes % 4 != 0 or
                !std.math.isPowerOfTwo(evaluation.size_bytes / 4) or evaluation.size_bytes < previous_size)
                return recovery.RecoveryError.BindingSizeMismatch;
            previous_size = evaluation.size_bytes;
            log_size.* = std.math.log2_int(u64, evaluation.size_bytes / 4);
            maximum_source_log = @max(maximum_source_log, log_size.*);
            offset.* = try asOffset(evaluation);
        }
        if (leaf_workspace.size_bytes % 32 != 0 or !std.math.isPowerOfTwo(leaf_workspace.size_bytes / 32))
            return recovery.RecoveryError.BindingSizeMismatch;
        const lifting_log_size: u32 = std.math.log2_int(u64, leaf_workspace.size_bytes / 32);
        if (lifting_log_size < maximum_source_log) return recovery.RecoveryError.BindingSizeMismatch;
        const leaf_words = leaf_workspace.size_bytes / 4;
        if (parent_workspace.size_bytes < leaf_words * 2)
            return recovery.RecoveryError.BindingSizeMismatch;
        const bottom = retained_layers_bottom_up[0];
        if (bottom.size_bytes == 0 or bottom.size_bytes % 32 != 0 or !std.math.isPowerOfTwo(bottom.size_bytes / 32))
            return recovery.RecoveryError.BindingSizeMismatch;
        const bottom_hashes = bottom.size_bytes / 32;
        const leaf_hashes = @as(u64, 1) << @intCast(lifting_log_size);
        if (bottom_hashes > leaf_hashes or leaf_hashes % bottom_hashes != 0 or
            !std.math.isPowerOfTwo(leaf_hashes / bottom_hashes))
            return recovery.RecoveryError.BindingSizeMismatch;
        const lower_levels: u32 = std.math.log2_int(u64, leaf_hashes / bottom_hashes);
        if (lower_levels == 0) return recovery.RecoveryError.BindingSizeMismatch;
        const lower_count: usize = lower_levels;
        const layer_offsets = try allocator.alloc(u32, lower_count + retained_layers_bottom_up.len);
        defer allocator.free(layer_offsets);
        layer_offsets[0] = try asOffset(leaf_workspace);
        for (1..lower_count) |level| layer_offsets[level] = try asOffset(if (level % 2 == 0) leaf_workspace else parent_workspace);
        for (retained_layers_bottom_up, 0..) |layer, index| {
            const expected_hashes = bottom_hashes >> @intCast(index);
            if (expected_hashes == 0 or layer.size_bytes != expected_hashes * 32)
                return recovery.RecoveryError.BindingSizeMismatch;
            layer_offsets[lower_count + index] = try asOffset(layer);
        }
        var prepared = try metal.prepareResidentMerkle(
            source_offsets,
            source_logs,
            lifting_log_size,
            layer_offsets,
            leaf_seed,
            node_seed,
        );
        errdefer prepared.deinit();
        return .{
            .allocator = allocator,
            .metal = metal,
            .arena = resident_arena,
            .destinations = try allocator.dupe(arena_plan.Binding, retained_layers_bottom_up),
            .prepared = prepared,
        };
    }

    pub fn deinit(self: *MerkleCommitRecipe) void {
        self.prepared.deinit();
        self.allocator.free(self.destinations);
        self.* = undefined;
    }

    pub fn makeRecipes(self: *MerkleCommitRecipe, allocator: std.mem.Allocator) ![]recovery.Recipe {
        const recipes = try allocator.alloc(recovery.Recipe, self.destinations.len);
        for (self.destinations, recipes) |destination, *recipe_entry|
            recipe_entry.* = .{ .logical_id = destination.logical_id, .context = self, .run = run };
        return recipes;
    }

    fn run(raw: *anyopaque, tick: u16, requested: arena_plan.Binding, _: []u8) !void {
        const self: *MerkleCommitRecipe = @ptrCast(@alignCast(raw));
        if (self.last_tick == tick) return;
        var found = false;
        for (self.destinations) |destination| found = found or destination.logical_id == requested.logical_id;
        if (!found) return recovery.RecoveryError.MissingRecipe;
        self.accumulated_gpu_ms += try self.metal.residentMerklePrepared(self.arena.buffer, self.prepared);
        self.last_tick = tick;
    }
};

pub const EcOpBindings = struct {
    execution_columns: [37]arena_plan.Binding,
    trace_columns: [273]arena_plan.Binding,
    partial_columns: [127]arena_plan.Binding,
    multiplicities: [4]arena_plan.Binding,
    lookup: arena_plan.Binding,
    segment_start: arena_plan.Binding,
    scratch: arena_plan.Binding,
    row_count: u32,
};

pub const EcOpOutputMode = enum {
    base,
    lookup,
};

pub const EcOpRecipe = struct {
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
        bindings: EcOpBindings,
        output_mode: EcOpOutputMode,
    ) !EcOpRecipe {
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

    pub fn deinit(self: *EcOpRecipe) void {
        self.prepared.deinit();
        self.allocator.free(self.destinations);
        self.* = undefined;
    }

    pub fn makeRecipes(self: *EcOpRecipe, allocator: std.mem.Allocator) ![]recovery.Recipe {
        const recipes = try allocator.alloc(recovery.Recipe, self.destinations.len);
        for (self.destinations, recipes) |destination, *recipe_entry| {
            recipe_entry.* = .{ .logical_id = destination.logical_id, .context = self, .run = run };
        }
        return recipes;
    }

    pub fn execute(self: *EcOpRecipe) !void {
        self.accumulated_gpu_ms += try self.metal.ecOpPrepared(self.arena.buffer, self.prepared);
    }

    fn run(raw: *anyopaque, tick: u16, requested: arena_plan.Binding, _: []u8) !void {
        const self: *EcOpRecipe = @ptrCast(@alignCast(raw));
        if (self.last_tick == tick) return;
        var found = false;
        for (self.destinations) |destination| found = found or destination.logical_id == requested.logical_id;
        if (!found) return recovery.RecoveryError.MissingRecipe;
        try self.execute();
        self.last_tick = tick;
    }
};

pub const CompactBindings = struct {
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

const CompactDescriptorImage = struct {
    allocator: std.mem.Allocator,
    destination: arena_plan.Binding,
    words: []u32,

    fn init(
        allocator: std.mem.Allocator,
        destination: arena_plan.Binding,
        source: []const u32,
    ) !CompactDescriptorImage {
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

    fn deinit(self: *CompactDescriptorImage) void {
        self.allocator.free(self.words);
        self.* = undefined;
    }

    fn rematerialize(self: CompactDescriptorImage, resident_arena: *arena_plan.ResidentArena) !void {
        const destination = try resident_arena.bytes(self.destination);
        const source = std.mem.sliceAsBytes(self.words);
        if (destination.len != source.len) return recovery.RecoveryError.BindingSizeMismatch;
        @memcpy(destination, source);
    }
};

/// Canonical device multiset writer. All radix, scan, and tuple workspaces are
/// sparse arena bindings whose live range is the consumer's witness tick.
pub const CompactRecipe = struct {
    allocator: std.mem.Allocator,
    metal: *runtime.Runtime,
    arena: *arena_plan.ResidentArena,
    destinations: []arena_plan.Binding,
    descriptor_image: CompactDescriptorImage,
    prepared: runtime.CompactPlan,
    last_tick: ?u16 = null,
    accumulated_gpu_ms: f64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        metal: *runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        bindings: CompactBindings,
    ) !CompactRecipe {
        if (bindings.sources.len == 0 or bindings.descriptors.len != bindings.sources.len * 5 or
            bindings.outputs.len == 0 or bindings.tuple_words == 0 or bindings.key_words == 0 or
            bindings.key_words > bindings.tuple_words or bindings.total_rows == 0 or
            bindings.sort_rows < bindings.total_rows or !std.math.isPowerOfTwo(bindings.sort_rows) or
            bindings.consumer_rows < 16 or !std.math.isPowerOfTwo(bindings.consumer_rows) or
            bindings.outputs.len <= bindings.multiplicity_slot or bindings.outputs.len <= bindings.enabler_slot or
            bindings.outputs.len <= bindings.iota_slot)
            return recovery.RecoveryError.BindingSizeMismatch;
        var descriptor_image = try CompactDescriptorImage.init(
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
        var recipe = CompactRecipe{
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

    pub fn deinit(self: *CompactRecipe) void {
        self.prepared.deinit();
        self.allocator.free(self.destinations);
        self.descriptor_image.deinit();
        self.* = undefined;
    }

    pub fn rematerializeDescriptors(self: *CompactRecipe) !void {
        try self.descriptor_image.rematerialize(self.arena);
    }

    /// Clears request-local execution bookkeeping and restores the static
    /// descriptor table overwritten by a full resident-arena clear.
    pub fn resetForRequest(self: *CompactRecipe) !void {
        self.last_tick = null;
        self.accumulated_gpu_ms = 0;
        try self.rematerializeDescriptors();
    }

    pub fn makeRecipes(self: *CompactRecipe, allocator: std.mem.Allocator) ![]recovery.Recipe {
        const recipes = try allocator.alloc(recovery.Recipe, self.destinations.len);
        for (self.destinations, recipes) |destination, *recipe_entry|
            recipe_entry.* = .{ .logical_id = destination.logical_id, .context = self, .run = run };
        return recipes;
    }

    pub fn execute(self: *CompactRecipe) !void {
        self.accumulated_gpu_ms += try self.metal.compactPrepared(self.arena.buffer, self.prepared);
    }

    fn run(raw: *anyopaque, tick: u16, requested: arena_plan.Binding, _: []u8) !void {
        const self: *CompactRecipe = @ptrCast(@alignCast(raw));
        if (self.last_tick == tick) return;
        var found = false;
        for (self.destinations) |destination| found = found or destination.logical_id == requested.logical_id;
        if (!found) return recovery.RecoveryError.MissingRecipe;
        try self.execute();
        self.last_tick = tick;
    }
};

pub const CompositionFinalizeRecipe = struct {
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
    ) !CompositionFinalizeRecipe {
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

    pub fn deinit(self: *CompositionFinalizeRecipe) void {
        self.prepared.deinit();
        self.allocator.free(self.destinations);
        self.* = undefined;
    }

    pub fn makeRecipes(self: *CompositionFinalizeRecipe, allocator: std.mem.Allocator) ![]recovery.Recipe {
        const recipes = try allocator.alloc(recovery.Recipe, self.destinations.len);
        for (self.destinations, recipes) |binding, *entry| entry.* = .{
            .logical_id = binding.logical_id,
            .context = self,
            .run = run,
        };
        return recipes;
    }

    fn run(raw: *anyopaque, tick: u16, requested: arena_plan.Binding, _: []u8) !void {
        const self: *CompositionFinalizeRecipe = @ptrCast(@alignCast(raw));
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
pub const CompositionRecipe = struct {
    allocator: std.mem.Allocator,
    metal: *runtime.Runtime,
    arena: *arena_plan.ResidentArena,
    destinations: []arena_plan.Binding,
    front: runtime.CompositionFrontPlan,
    finalize: runtime.CompositionFinalizePlan,
    last_tick: ?u16 = null,
    accumulated_gpu_ms: f64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        metal: *runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        front: runtime.CompositionFrontPlan,
        finalize: runtime.CompositionFinalizePlan,
        outputs: [8]arena_plan.Binding,
    ) !CompositionRecipe {
        for (outputs) |binding| if (binding.offset_bytes % 4 != 0 or binding.size_bytes == 0)
            return recovery.RecoveryError.BindingSizeMismatch;
        return .{
            .allocator = allocator,
            .metal = metal,
            .arena = resident_arena,
            .destinations = try allocator.dupe(arena_plan.Binding, &outputs),
            .front = front,
            .finalize = finalize,
        };
    }

    pub fn deinit(self: *CompositionRecipe) void {
        self.finalize.deinit();
        self.front.deinit();
        self.allocator.free(self.destinations);
        self.* = undefined;
    }

    pub fn makeRecipes(self: *CompositionRecipe, allocator: std.mem.Allocator) ![]recovery.Recipe {
        const recipes = try allocator.alloc(recovery.Recipe, self.destinations.len);
        for (self.destinations, recipes) |binding, *entry| entry.* = .{
            .logical_id = binding.logical_id,
            .context = self,
            .run = run,
        };
        return recipes;
    }

    pub fn execute(self: *CompositionRecipe) !void {
        self.accumulated_gpu_ms += try self.metal.compositionPrepared(
            self.arena.buffer,
            self.front,
            self.finalize,
        );
    }

    fn run(raw: *anyopaque, tick: u16, requested: arena_plan.Binding, _: []u8) !void {
        const self: *CompositionRecipe = @ptrCast(@alignCast(raw));
        if (self.last_tick == tick) return;
        var found = false;
        for (self.destinations) |binding| found = found or binding.logical_id == requested.logical_id;
        if (!found) return recovery.RecoveryError.MissingRecipe;
        try self.execute();
        self.last_tick = tick;
    }
};

pub const ZeroRecipe = struct {
    pub fn recipe(logical_id: u32) recovery.Recipe {
        return .{ .logical_id = logical_id, .context = undefined, .run = run };
    }

    fn run(_: *anyopaque, _: u16, _: arena_plan.Binding, destination: []u8) !void {
        @memset(destination, 0);
    }
};

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

pub const RelationInstanceBindings = struct {
    rows: u32,
    real_rows: u32,
    source_offset_rows: u32 = 0,
    sources: []const arena_plan.Binding,
    descriptors: []const u32,
    outputs: []const arena_plan.Binding,
    claimed_sum: arena_plan.Binding,
};

/// Exact CommonLookupElements execution over sparse arena columns. The fused
/// fraction chain and normalized coset scan are one prepared Metal command.
pub const RelationRecipe = struct {
    allocator: std.mem.Allocator,
    metal: *runtime.Runtime,
    arena: *arena_plan.ResidentArena,
    destinations: []arena_plan.Binding,
    prepared: runtime.RelationPlan,
    last_tick: ?u16 = null,
    accumulated_gpu_ms: f64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        metal: *runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        instances: []const RelationInstanceBindings,
        alpha_powers: arena_plan.Binding,
        z: arena_plan.Binding,
        scan_scratch: arena_plan.Binding,
    ) !RelationRecipe {
        if (instances.len == 0 or alpha_powers.offset_bytes % 4 != 0 or z.offset_bytes % 4 != 0 or
            scan_scratch.offset_bytes % 4 != 0 or z.size_bytes < 16)
            return recovery.RecoveryError.BindingSizeMismatch;
        var geometry = std.ArrayList(u32).empty;
        defer geometry.deinit(allocator);
        var source_offsets = std.ArrayList(u32).empty;
        defer source_offsets.deinit(allocator);
        var descriptors = std.ArrayList(u32).empty;
        defer descriptors.deinit(allocator);
        var output_offsets = std.ArrayList(u32).empty;
        defer output_offsets.deinit(allocator);
        var destinations = std.ArrayList(arena_plan.Binding).empty;
        errdefer destinations.deinit(allocator);
        var total_blocks: u32 = 0;
        var max_alpha_powers: u32 = 0;
        for (instances, 0..) |instance, instance_index| {
            if (instance.rows == 0 or !std.math.isPowerOfTwo(instance.rows) or instance.real_rows > instance.rows or
                instance.sources.len == 0 or instance.descriptors.len == 0 or instance.descriptors.len % 16 != 0)
                return recovery.RecoveryError.BindingSizeMismatch;
            const columns = instance.descriptors.len / 16;
            if (instance.outputs.len != columns * 4 or instance.claimed_sum.size_bytes < 16 or
                instance.claimed_sum.offset_bytes % 4 != 0)
                return recovery.RecoveryError.BindingSizeMismatch;
            var descriptor_index: usize = 0;
            while (descriptor_index < instance.descriptors.len) : (descriptor_index += 16) {
                const descriptor = instance.descriptors[descriptor_index .. descriptor_index + 16];
                if (descriptor[0] < 1 or descriptor[0] > 2) return recovery.RecoveryError.BindingSizeMismatch;
                max_alpha_powers = @max(max_alpha_powers, descriptor[3]);
                if (descriptor[0] == 2) max_alpha_powers = @max(max_alpha_powers, descriptor[10]);
            }
            const source_base = source_offsets.items.len;
            for (instance.sources) |binding| {
                if (binding.offset_bytes % 4 != 0 or binding.size_bytes < @as(u64, instance.rows) * 4)
                    return recovery.RecoveryError.BindingSizeMismatch;
                try source_offsets.append(allocator, std.math.cast(u32, binding.offset_bytes / 4) orelse {
                    std.debug.print("relation_source_offset_overflow instance={d} logical_id={d} offset={d} size={d}\n", .{
                        instance_index, binding.logical_id, binding.offset_bytes, binding.size_bytes,
                    });
                    return recovery.RecoveryError.BindingSizeMismatch;
                });
            }
            const descriptor_base = descriptors.items.len;
            try descriptors.appendSlice(allocator, instance.descriptors);
            const output_base = output_offsets.items.len;
            for (instance.outputs) |binding| {
                if (binding.offset_bytes % 4 != 0 or binding.size_bytes != @as(u64, instance.rows) * 4)
                    return recovery.RecoveryError.BindingSizeMismatch;
                try output_offsets.append(allocator, std.math.cast(u32, binding.offset_bytes / 4) orelse {
                    std.debug.print("relation_output_offset_overflow instance={d} logical_id={d} offset={d} size={d}\n", .{
                        instance_index, binding.logical_id, binding.offset_bytes, binding.size_bytes,
                    });
                    return recovery.RecoveryError.BindingSizeMismatch;
                });
                try destinations.append(allocator, binding);
            }
            try destinations.append(allocator, instance.claimed_sum);
            const blocks = std.math.divCeil(u32, instance.rows, 256) catch return recovery.RecoveryError.BindingSizeMismatch;
            try geometry.appendSlice(allocator, &.{
                total_blocks,
                blocks,
                instance.rows,
                @intCast(columns),
                instance.real_rows,
                instance.source_offset_rows,
                @intCast(source_base),
                @intCast(descriptor_base),
                @intCast(output_base),
                std.math.cast(u32, instance.claimed_sum.offset_bytes / 4) orelse {
                    std.debug.print("relation_claimed_sum_offset_overflow instance={d} logical_id={d} offset={d}\n", .{
                        instance_index, instance.claimed_sum.logical_id, instance.claimed_sum.offset_bytes,
                    });
                    return recovery.RecoveryError.BindingSizeMismatch;
                },
            });
            total_blocks = std.math.add(u32, total_blocks, blocks) catch return recovery.RecoveryError.BindingSizeMismatch;
        }
        if (scan_scratch.size_bytes < @as(u64, total_blocks) * 16)
            return recovery.RecoveryError.BindingSizeMismatch;
        if (alpha_powers.size_bytes < @as(u64, max_alpha_powers) * 16)
            return recovery.RecoveryError.BindingSizeMismatch;
        const alpha_offset = std.math.cast(u32, alpha_powers.offset_bytes / 4) orelse {
            std.debug.print("relation_alpha_offset_overflow offset={d}\n", .{alpha_powers.offset_bytes});
            return recovery.RecoveryError.BindingSizeMismatch;
        };
        const z_offset = std.math.cast(u32, z.offset_bytes / 4) orelse {
            std.debug.print("relation_z_offset_overflow offset={d}\n", .{z.offset_bytes});
            return recovery.RecoveryError.BindingSizeMismatch;
        };
        const scratch_offset = std.math.cast(u32, scan_scratch.offset_bytes / 4) orelse {
            std.debug.print("relation_scratch_offset_overflow offset={d} size={d}\n", .{ scan_scratch.offset_bytes, scan_scratch.size_bytes });
            return recovery.RecoveryError.BindingSizeMismatch;
        };
        var prepared = try metal.prepareRelation(
            geometry.items,
            source_offsets.items,
            descriptors.items,
            output_offsets.items,
            total_blocks,
            alpha_offset,
            z_offset,
            scratch_offset,
        );
        errdefer prepared.deinit();
        return .{
            .allocator = allocator,
            .metal = metal,
            .arena = resident_arena,
            .destinations = try destinations.toOwnedSlice(allocator),
            .prepared = prepared,
        };
    }

    pub fn deinit(self: *RelationRecipe) void {
        self.prepared.deinit();
        self.allocator.free(self.destinations);
        self.* = undefined;
    }

    pub fn makeRecipes(self: *RelationRecipe, allocator: std.mem.Allocator) ![]recovery.Recipe {
        const recipes = try allocator.alloc(recovery.Recipe, self.destinations.len);
        for (self.destinations, recipes) |binding, *recipe_entry| {
            recipe_entry.* = .{ .logical_id = binding.logical_id, .context = self, .run = run };
        }
        return recipes;
    }

    pub fn execute(self: *RelationRecipe) !void {
        self.accumulated_gpu_ms += try self.metal.relationPrepared(self.arena.buffer, self.prepared);
    }

    fn run(raw: *anyopaque, tick: u16, requested: arena_plan.Binding, _: []u8) !void {
        const self: *RelationRecipe = @ptrCast(@alignCast(raw));
        if (self.last_tick == tick) return;
        var found = false;
        for (self.destinations) |binding| found = found or binding.logical_id == requested.logical_id;
        if (!found) return recovery.RecoveryError.MissingRecipe;
        try self.execute();
        self.last_tick = tick;
    }
};

/// One circle-to-line or line-to-line FRI fold with every operand resident in
/// the shared arena. The challenge and inverse-coordinate column are bindings,
/// so replay never uploads control data or reads the folded column back.
pub const FriFoldRecipe = struct {
    metal: *runtime.Runtime,
    arena: *arena_plan.ResidentArena,
    destination: arena_plan.Binding,
    prepared: runtime.FriFoldPlan,
    last_tick: ?u16 = null,
    accumulated_gpu_ms: f64 = 0,

    pub fn init(
        metal: *runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        source: arena_plan.Binding,
        inverse_coordinates: arena_plan.Binding,
        challenge: arena_plan.Binding,
        destination: arena_plan.Binding,
        source_count: u32,
        circle: bool,
    ) !FriFoldRecipe {
        const destination_count = source_count / 2;
        if (source_count < 2 or source_count & 1 != 0 or
            source.offset_bytes % 4 != 0 or inverse_coordinates.offset_bytes % 4 != 0 or
            challenge.offset_bytes % 4 != 0 or destination.offset_bytes % 4 != 0 or
            source.size_bytes < @as(u64, source_count) * 16 or
            inverse_coordinates.size_bytes < @as(u64, destination_count) * 4 or
            challenge.size_bytes < 16 or destination.size_bytes < @as(u64, destination_count) * 16)
            return recovery.RecoveryError.BindingSizeMismatch;
        return .{
            .metal = metal,
            .arena = resident_arena,
            .destination = destination,
            .prepared = try metal.prepareFriFold(
                std.math.cast(u32, source.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch,
                std.math.cast(u32, inverse_coordinates.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch,
                std.math.cast(u32, challenge.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch,
                std.math.cast(u32, destination.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch,
                source_count,
                circle,
            ),
        };
    }

    pub fn deinit(self: *FriFoldRecipe) void {
        self.prepared.deinit();
        self.* = undefined;
    }

    pub fn recipe(self: *FriFoldRecipe) recovery.Recipe {
        return .{ .logical_id = self.destination.logical_id, .context = self, .run = run };
    }

    fn run(raw: *anyopaque, tick: u16, requested: arena_plan.Binding, _: []u8) !void {
        const self: *FriFoldRecipe = @ptrCast(@alignCast(raw));
        if (requested.logical_id != self.destination.logical_id) return recovery.RecoveryError.MissingRecipe;
        if (self.last_tick == tick) return;
        self.accumulated_gpu_ms += try self.metal.friFoldPrepared(self.arena.buffer, self.prepared);
        self.last_tick = tick;
    }
};

/// Prepared quotient bottom: combine mixed-log secure numerators on the
/// quotient subdomain, interpolate its four coordinates in place, then LDE
/// directly into the full-domain planar buffer consumed by FRI.
pub const QuotientRecipe = struct {
    allocator: std.mem.Allocator,
    metal: *runtime.Runtime,
    arena: *arena_plan.ResidentArena,
    destination: arena_plan.Binding,
    partials: []arena_plan.Binding,
    sample_points: arena_plan.Binding,
    first_linear_terms: arena_plan.Binding,
    subdomain_values: arena_plan.Binding,
    inverse_subdomain_twiddles: arena_plan.Binding,
    subdomain_log: u32,
    quotient_log: u32,
    combine: runtime.QuotientCombinePlan,
    interpolate: runtime.CircleIfftPlan,
    evaluate: runtime.CircleLdePlan,
    last_tick: ?u16 = null,
    accumulated_gpu_ms: f64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        metal: *runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        partials_source_major: []const arena_plan.Binding,
        sample_points: arena_plan.Binding,
        first_linear_terms: arena_plan.Binding,
        denominator_scratch: arena_plan.Binding,
        subdomain_values: arena_plan.Binding,
        quotient_values: arena_plan.Binding,
        inverse_subdomain_twiddles: arena_plan.Binding,
        forward_twiddles: arena_plan.Binding,
    ) !QuotientRecipe {
        if (partials_source_major.len == 0 or partials_source_major.len % 4 != 0 or
            sample_points.offset_bytes % 4 != 0 or first_linear_terms.offset_bytes % 4 != 0 or
            denominator_scratch.offset_bytes % 4 != 0 or subdomain_values.offset_bytes % 4 != 0 or
            quotient_values.offset_bytes % 4 != 0 or inverse_subdomain_twiddles.offset_bytes % 4 != 0 or
            forward_twiddles.offset_bytes % 4 != 0)
            return recovery.RecoveryError.BindingSizeMismatch;
        const sample_count = partials_source_major.len / 4;
        if (sample_points.size_bytes != @as(u64, sample_count) * 8 * 4 or
            first_linear_terms.size_bytes != @as(u64, sample_count) * 4 * 4 or
            subdomain_values.size_bytes % 16 != 0 or quotient_values.size_bytes % 16 != 0)
            return recovery.RecoveryError.BindingSizeMismatch;
        const subdomain_rows = subdomain_values.size_bytes / 16;
        const quotient_rows = quotient_values.size_bytes / 16;
        if (!std.math.isPowerOfTwo(subdomain_rows) or !std.math.isPowerOfTwo(quotient_rows) or quotient_rows <= subdomain_rows)
            return recovery.RecoveryError.BindingSizeMismatch;
        const subdomain_log: u32 = std.math.log2_int(u64, subdomain_rows);
        const quotient_log: u32 = std.math.log2_int(u64, quotient_rows);
        if (denominator_scratch.size_bytes != subdomain_rows * sample_count * 8 or
            inverse_subdomain_twiddles.size_bytes < subdomain_rows / 2 * 4 or
            forward_twiddles.size_bytes < quotient_rows / 2 * 4)
            return recovery.RecoveryError.BindingSizeMismatch;

        const offsets = try allocator.alloc(u32, partials_source_major.len);
        defer allocator.free(offsets);
        const logs = try allocator.alloc(u32, sample_count);
        defer allocator.free(logs);
        for (0..sample_count) |source| {
            const first = partials_source_major[source * 4];
            if (first.size_bytes < 4 or first.size_bytes % 4 != 0 or !std.math.isPowerOfTwo(first.size_bytes / 4))
                return recovery.RecoveryError.BindingSizeMismatch;
            logs[source] = std.math.log2_int(u64, first.size_bytes / 4);
            if (logs[source] > subdomain_log) return recovery.RecoveryError.BindingSizeMismatch;
            for (0..4) |coordinate| {
                const partial = partials_source_major[source * 4 + coordinate];
                if (partial.size_bytes != first.size_bytes or partial.offset_bytes % 4 != 0)
                    return recovery.RecoveryError.BindingSizeMismatch;
                offsets[coordinate * sample_count + source] = std.math.cast(u32, partial.offset_bytes / 4) orelse
                    return recovery.RecoveryError.BindingSizeMismatch;
            }
        }
        const subdomain_offset = std.math.cast(u32, subdomain_values.offset_bytes / 4) orelse
            return recovery.RecoveryError.BindingSizeMismatch;
        const quotient_offset = quotient_values.offset_bytes / 4;
        const initial_index = @as(u32, 1) << @intCast(30 - quotient_log);
        const step_size = @as(u32, 1) << @intCast(32 - subdomain_log);
        var combine = try metal.prepareQuotientCombine(
            offsets,
            logs,
            std.math.cast(u32, sample_points.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch,
            std.math.cast(u32, first_linear_terms.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch,
            std.math.cast(u32, denominator_scratch.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch,
            subdomain_offset,
            subdomain_log,
            initial_index,
            step_size,
        );
        errdefer combine.deinit();
        var subdomain_offsets: [4]u64 = undefined;
        var quotient_offsets: [4]u64 = undefined;
        for (0..4) |coordinate| {
            subdomain_offsets[coordinate] = subdomain_offset + @as(u64, @intCast(coordinate)) * subdomain_rows;
            quotient_offsets[coordinate] = quotient_offset + @as(u64, @intCast(coordinate)) * quotient_rows;
        }
        const scale = @import("../../core/fields/m31.zig").M31.fromCanonical(@intCast(subdomain_rows)).inv() catch
            return recovery.RecoveryError.BindingSizeMismatch;
        var interpolate = try metal.prepareCircleIfft(
            &subdomain_offsets,
            &subdomain_offsets,
            subdomain_log,
            std.math.cast(u32, inverse_subdomain_twiddles.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch,
            scale.v,
        );
        errdefer interpolate.deinit();
        const forward_words = forward_twiddles.size_bytes / 4;
        const quotient_twiddle_words = quotient_rows / 2;
        const forward_twiddle_offset = std.math.add(
            u64,
            forward_twiddles.offset_bytes / 4,
            forward_words - quotient_twiddle_words,
        ) catch return recovery.RecoveryError.BindingSizeMismatch;
        var evaluate = try metal.prepareCircleLde(
            &subdomain_offsets,
            &quotient_offsets,
            subdomain_log,
            quotient_log,
            std.math.cast(u32, forward_twiddle_offset) orelse return recovery.RecoveryError.BindingSizeMismatch,
        );
        errdefer evaluate.deinit();
        const owned_partials = try allocator.dupe(arena_plan.Binding, partials_source_major);
        errdefer allocator.free(owned_partials);
        return .{
            .allocator = allocator,
            .metal = metal,
            .arena = resident_arena,
            .destination = quotient_values,
            .partials = owned_partials,
            .sample_points = sample_points,
            .first_linear_terms = first_linear_terms,
            .subdomain_values = subdomain_values,
            .inverse_subdomain_twiddles = inverse_subdomain_twiddles,
            .subdomain_log = subdomain_log,
            .quotient_log = quotient_log,
            .combine = combine,
            .interpolate = interpolate,
            .evaluate = evaluate,
        };
    }

    pub fn deinit(self: *QuotientRecipe) void {
        self.evaluate.deinit();
        self.interpolate.deinit();
        self.combine.deinit();
        self.allocator.free(self.partials);
        self.* = undefined;
    }

    pub fn recipe(self: *QuotientRecipe) recovery.Recipe {
        return .{ .logical_id = self.destination.logical_id, .context = self, .run = run };
    }

    pub fn execute(self: *QuotientRecipe) !void {
        if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_STAGE_TIMINGS"))
            try self.validateInverseTwiddles();
        self.accumulated_gpu_ms += try self.metal.quotientCombinePrepared(self.arena.buffer, self.combine);
        if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_STAGE_TIMINGS")) {
            try self.validateCombineSamples();
            self.logDigest("combine", self.subdomain_values) catch {};
        }
        self.accumulated_gpu_ms += try self.metal.circleIfftPrepared(self.arena.buffer, self.interpolate);
        if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_STAGE_TIMINGS")) {
            self.logDigest("ifft", self.subdomain_values) catch {};
            try self.validateIfftAtRow(0);
        }
        self.accumulated_gpu_ms += try self.metal.circleLdePrepared(self.arena.buffer, self.evaluate);
        if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_STAGE_TIMINGS")) {
            self.logDigest("lde", self.destination) catch {};
            try self.validateLdeAtRow(0);
        }
    }

    fn logDigest(self: *QuotientRecipe, stage: []const u8, binding: arena_plan.Binding) !void {
        const bytes = try self.arena.bytes(binding);
        const digest = blake2_hash.Blake2sHasher.hash(bytes);
        const aligned: []align(4) const u8 = @alignCast(bytes);
        const words = std.mem.bytesAsSlice(u32, aligned);
        std.debug.print(
            "quotient stage={s} digest={x} first={},{},{},{}\n",
            .{ stage, digest, words[0], words[1], words[2], words[3] },
        );
    }

    fn validateInverseTwiddles(self: *QuotientRecipe) !void {
        const actual_bytes: []align(4) u8 = @alignCast(try self.arena.bytes(self.inverse_subdomain_twiddles));
        const actual_words = std.mem.bytesAsSlice(u32, actual_bytes);
        var split = try canonic.CanonicCoset.new(self.quotient_log).circleDomain().split(
            self.allocator,
            self.quotient_log - self.subdomain_log,
        );
        defer split.deinit(self.allocator);
        var expected = try twiddles_mod.precomputeM31(self.allocator, split.subdomain.half_coset);
        defer twiddles_mod.deinitM31(self.allocator, &expected);
        if (actual_words.len != expected.itwiddles.len)
            return error.QuotientInverseTwiddleParityMismatch;
        for (actual_words, expected.itwiddles, 0..) |actual, wanted, index| {
            if (actual != wanted.v) {
                std.debug.print(
                    "quotient inverse_twiddles mismatch index={} expected={} actual={}\n",
                    .{ index, wanted.v, actual },
                );
                return error.QuotientInverseTwiddleParityMismatch;
            }
        }
        const actual_digest = blake2_hash.Blake2sHasher.hash(actual_bytes);
        const expected_digest = blake2_hash.Blake2sHasher.hash(std.mem.sliceAsBytes(expected.itwiddles));
        std.debug.print(
            "quotient inverse_twiddles exact words={} digest={x} expected_digest={x} first={},{},{},{} last={} offset_words={}\n",
            .{
                actual_words.len,
                actual_digest,
                expected_digest,
                actual_words[0],
                actual_words[1],
                actual_words[2],
                actual_words[3],
                actual_words[actual_words.len - 1],
                self.inverse_subdomain_twiddles.offset_bytes / 4,
            },
        );
    }

    fn expectedCombineAtRow(self: *QuotientRecipe, row: usize) !QM31 {
        const sample_count = self.partials.len / 4;
        const sample_bytes: []align(4) u8 = @alignCast(try self.arena.bytes(self.sample_points));
        const linear_bytes: []align(4) u8 = @alignCast(try self.arena.bytes(self.first_linear_terms));
        const sample_words = std.mem.bytesAsSlice(u32, sample_bytes);
        const linear_words = std.mem.bytesAsSlice(u32, linear_bytes);
        var split = try canonic.CanonicCoset.new(self.quotient_log).circleDomain().split(
            self.allocator,
            self.quotient_log - self.subdomain_log,
        );
        defer split.deinit(self.allocator);
        const point = split.subdomain.at(core_utils.bitReverseIndex(row, self.subdomain_log));
        var expected = QM31.zero();
        for (0..sample_count) |sample| {
            const sample_base = sample * 8;
            const sample_x = QM31.fromU32Unchecked(
                sample_words[sample_base],
                sample_words[sample_base + 1],
                sample_words[sample_base + 2],
                sample_words[sample_base + 3],
            );
            const sample_y = QM31.fromU32Unchecked(
                sample_words[sample_base + 4],
                sample_words[sample_base + 5],
                sample_words[sample_base + 6],
                sample_words[sample_base + 7],
            );
            const denominator = sample_x.c0.subM31(point.x).mul(sample_y.c1).sub(
                sample_y.c0.subM31(point.y).mul(sample_x.c1),
            );
            const inverse = try denominator.inv();
            const partial_log = std.math.log2_int(u64, self.partials[sample * 4].size_bytes / 4);
            const log_ratio = self.subdomain_log - partial_log;
            const lifted = (row >> @intCast(log_ratio + 1) << 1) + (row & 1);
            var partial_coordinates: [4]M31 = undefined;
            for (0..4) |coordinate| {
                const partial_bytes: []align(4) u8 = @alignCast(try self.arena.bytes(self.partials[sample * 4 + coordinate]));
                const partial_words = std.mem.bytesAsSlice(u32, partial_bytes);
                partial_coordinates[coordinate] = M31.fromCanonical(partial_words[lifted]);
            }
            const linear_base = sample * 4;
            const first = QM31.fromU32Unchecked(
                linear_words[linear_base],
                linear_words[linear_base + 1],
                linear_words[linear_base + 2],
                linear_words[linear_base + 3],
            );
            expected = expected.add(
                QM31.fromM31Array(partial_coordinates).sub(first.mulM31(point.y)).mulCM31(inverse),
            );
        }
        return expected;
    }

    fn validateCombineSamples(self: *QuotientRecipe) !void {
        const output_bytes: []align(4) u8 = @alignCast(try self.arena.bytes(self.subdomain_values));
        const output_words = std.mem.bytesAsSlice(u32, output_bytes);
        const row_count = @as(usize, 1) << @intCast(self.subdomain_log);
        const sample_rows = [_]usize{
            0,                 1,                 2,                 3,                 7,
            row_count / 16,    row_count / 8,     row_count / 4,     row_count / 2 - 1, row_count / 2,
            row_count / 2 + 1, 3 * row_count / 4, 7 * row_count / 8, row_count - 8,     row_count - 4,
            row_count - 2,     row_count - 1,
        };
        for (sample_rows) |row| {
            const expected = try self.expectedCombineAtRow(row);
            const actual = QM31.fromU32Unchecked(
                output_words[row],
                output_words[row_count + row],
                output_words[2 * row_count + row],
                output_words[3 * row_count + row],
            );
            if (!actual.eql(expected)) {
                std.debug.print(
                    "quotient stage=combine mismatch row={} expected={any} actual={any}\n",
                    .{ row, expected.toM31Array(), actual.toM31Array() },
                );
                return error.QuotientCombineParityMismatch;
            }
        }
        std.debug.print("quotient stage=combine cpu_samples=exact rows={}\n", .{sample_rows.len});
    }

    fn coefficientsAtPoint(self: *QuotientRecipe, point: @import("../../core/circle.zig").CirclePointM31) !QM31 {
        const coefficient_bytes: []align(4) u8 = @alignCast(try self.arena.bytes(self.subdomain_values));
        const coefficient_words = std.mem.bytesAsSlice(u32, coefficient_bytes);
        const row_count = @as(usize, 1) << @intCast(self.subdomain_log);
        var partial_evals: [4]QM31 = undefined;
        for (0..4) |coordinate| {
            const words = coefficient_words[coordinate * row_count .. (coordinate + 1) * row_count];
            const coefficients = try self.allocator.alloc(M31, row_count);
            defer self.allocator.free(coefficients);
            for (words, coefficients) |word, *coefficient| coefficient.* = M31.fromCanonical(word);
            const polynomial = try circle_poly.CircleCoefficients.initBorrowed(coefficients);
            partial_evals[coordinate] = polynomial.evalAtPoint(.{
                .x = QM31.fromBase(point.x),
                .y = QM31.fromBase(point.y),
            });
        }
        return QM31.fromPartialEvals(partial_evals);
    }

    fn validateIfftAtRow(self: *QuotientRecipe, row: usize) !void {
        var split = try canonic.CanonicCoset.new(self.quotient_log).circleDomain().split(
            self.allocator,
            self.quotient_log - self.subdomain_log,
        );
        defer split.deinit(self.allocator);
        const point = split.subdomain.at(core_utils.bitReverseIndex(row, self.subdomain_log));
        const expected = try self.expectedCombineAtRow(row);
        const actual = try self.coefficientsAtPoint(point);
        if (!actual.eql(expected)) {
            std.debug.print("quotient stage=ifft mismatch row={} expected={any} actual={any}\n", .{
                row, expected.toM31Array(), actual.toM31Array(),
            });
            return error.QuotientIfftParityMismatch;
        }
        std.debug.print("quotient stage=ifft scalar_eval=exact row={}\n", .{row});
    }

    fn validateLdeAtRow(self: *QuotientRecipe, row: usize) !void {
        const point = canonic.CanonicCoset.new(self.quotient_log).circleDomain().at(
            core_utils.bitReverseIndex(row, self.quotient_log),
        );
        const expected = try self.coefficientsAtPoint(point);
        const output_bytes: []align(4) u8 = @alignCast(try self.arena.bytes(self.destination));
        const output_words = std.mem.bytesAsSlice(u32, output_bytes);
        const row_count = @as(usize, 1) << @intCast(self.quotient_log);
        const actual = QM31.fromU32Unchecked(
            output_words[row],
            output_words[row_count + row],
            output_words[2 * row_count + row],
            output_words[3 * row_count + row],
        );
        if (!actual.eql(expected)) {
            std.debug.print("quotient stage=lde mismatch row={} expected={any} actual={any}\n", .{
                row, expected.toM31Array(), actual.toM31Array(),
            });
            return error.QuotientLdeParityMismatch;
        }
        std.debug.print("quotient stage=lde scalar_eval=exact row={}\n", .{row});
    }

    fn run(raw: *anyopaque, tick: u16, requested: arena_plan.Binding, _: []u8) !void {
        const self: *QuotientRecipe = @ptrCast(@alignCast(raw));
        if (requested.logical_id != self.destination.logical_id) return recovery.RecoveryError.MissingRecipe;
        if (self.last_tick == tick) return;
        try self.execute();
        self.last_tick = tick;
    }
};

fn validateFriCardinalities(
    geometry: FriGeometry,
    retained_count: usize,
    challenge_count: usize,
    merkle_layer_count: usize,
) !void {
    const round_count = std.math.add(usize, retained_count, 1) catch
        return recovery.RecoveryError.BindingSizeMismatch;
    if (round_count != geometry.roundCount() or
        challenge_count != geometry.roundCount() or
        merkle_layer_count != geometry.totalLayerCount() or
        geometry.terminalLog() != geometry.finalLog())
        return recovery.RecoveryError.BindingSizeMismatch;
}

fn validateFriOpeningRound(geometry: FriGeometry, round: usize, leaf_log: u32) !void {
    if (round >= geometry.roundCount() or leaf_log != try geometry.leafLog(round))
        return recovery.RecoveryError.BindingSizeMismatch;
}

test "Metal FRI cardinalities accept seven-round Fib and eight-round SN2 geometry" {
    const sn2 = try FriGeometry.init(24);
    try validateFriCardinalities(sn2, 7, 8, 100);
    try std.testing.expectError(
        recovery.RecoveryError.BindingSizeMismatch,
        validateFriCardinalities(sn2, 6, 8, 100),
    );

    const fib = try FriGeometry.initRuntime(21, .{
        .round_count = 7,
        .fold_step = 3,
        .final_log = 1,
        .packed_log = 2,
    });
    try validateFriCardinalities(fib, 6, 7, 77);
    for (0..fib.roundCount()) |round| try validateFriOpeningRound(fib, round, try fib.leafLog(round));
    try std.testing.expectError(
        recovery.RecoveryError.BindingSizeMismatch,
        validateFriCardinalities(fib, 6, 8, 77),
    );
    try std.testing.expectError(
        recovery.RecoveryError.BindingSizeMismatch,
        validateFriCardinalities(fib, 6, 7, 78),
    );
    try std.testing.expectError(
        recovery.RecoveryError.BindingSizeMismatch,
        validateFriOpeningRound(fib, 6, 2),
    );
    try std.testing.expectError(
        recovery.RecoveryError.BindingSizeMismatch,
        validateFriOpeningRound(fib, 7, 0),
    );
}

/// Exact STWO FRI bottom with planar secure evaluations and four rows per leaf.
/// Transcript control calls
/// `commitTree` and `foldRound` alternately so each device root can be mixed
/// before its resident challenge is consumed.
pub const FriRecipe = struct {
    pub const FinalDegreeError = error{
        FinalDegreeNotComputed,
        FinalDegreeExceeded,
    };

    metal: *runtime.Runtime,
    arena: *arena_plan.ResidentArena,
    rounds: [FriGeometry.max_round_count]runtime.FriRoundPlan,
    trees: [FriGeometry.max_round_count]runtime.FriTreePlan,
    final: runtime.FriFinalPlan,
    roots: [FriGeometry.max_round_count]arena_plan.Binding,
    round_count: usize = FriGeometry.round_count,
    initialized_rounds: usize,
    initialized_trees: usize,
    initialized_final: bool,
    final_degree_error: arena_plan.Binding,
    finalized: bool = false,
    accumulated_gpu_ms: f64 = 0,

    pub fn init(
        metal: *runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        quotient: arena_plan.Binding,
        retained: []const arena_plan.Binding,
        challenges: []const arena_plan.Binding,
        inverse_twiddles: arena_plan.Binding,
        final_evaluation: arena_plan.Binding,
        final_coefficients: arena_plan.Binding,
        final_degree_error: arena_plan.Binding,
        merkle_layers_root_first: []const arena_plan.Binding,
        leaf_seed: [8]u32,
        node_seed: [8]u32,
    ) !FriRecipe {
        if (quotient.offset_bytes % 4 != 0 or quotient.size_bytes < 16 or quotient.size_bytes % 16 != 0 or
            !std.math.isPowerOfTwo(quotient.size_bytes / 16))
            return recovery.RecoveryError.BindingSizeMismatch;
        const geometry = try FriGeometry.init(std.math.log2_int(u64, quotient.size_bytes / 16));
        return initWithGeometry(
            metal,
            resident_arena,
            geometry,
            quotient,
            retained,
            challenges,
            inverse_twiddles,
            final_evaluation,
            final_coefficients,
            final_degree_error,
            merkle_layers_root_first,
            leaf_seed,
            node_seed,
        );
    }

    pub fn initWithGeometry(
        metal: *runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        geometry: FriGeometry,
        quotient: arena_plan.Binding,
        retained: []const arena_plan.Binding,
        challenges: []const arena_plan.Binding,
        inverse_twiddles: arena_plan.Binding,
        final_evaluation: arena_plan.Binding,
        final_coefficients: arena_plan.Binding,
        final_degree_error: arena_plan.Binding,
        merkle_layers_root_first: []const arena_plan.Binding,
        leaf_seed: [8]u32,
        node_seed: [8]u32,
    ) !FriRecipe {
        if (quotient.offset_bytes % 4 != 0 or quotient.size_bytes < 16 or quotient.size_bytes % 16 != 0 or
            !std.math.isPowerOfTwo(quotient.size_bytes / 16) or
            std.math.log2_int(u64, quotient.size_bytes / 16) != geometry.startLog() or
            geometry.finalLog() != 1 or geometry.packedLog() != 2)
            return recovery.RecoveryError.BindingSizeMismatch;
        try validateFriCardinalities(geometry, retained.len, challenges.len, merkle_layers_root_first.len);
        if (inverse_twiddles.offset_bytes % 4 != 0 or inverse_twiddles.size_bytes != geometry.inverseTwiddleWords() * 4)
            return recovery.RecoveryError.BindingSizeMismatch;
        var self = FriRecipe{
            .metal = metal,
            .arena = resident_arena,
            .rounds = undefined,
            .trees = undefined,
            .final = undefined,
            .roots = undefined,
            .round_count = geometry.roundCount(),
            .initialized_rounds = 0,
            .initialized_trees = 0,
            .initialized_final = false,
            .final_degree_error = final_degree_error,
        };
        errdefer self.deinitInitialized();

        var evaluations: [FriGeometry.max_round_count]arena_plan.Binding = undefined;
        evaluations[0] = quotient;
        @memcpy(evaluations[1..geometry.roundCount()], retained);
        var layer_cursor: usize = 0;
        for (evaluations[0..geometry.roundCount()], 0..) |evaluation, tree| {
            const log_size = try geometry.evaluationLog(tree);
            const layer_count = try geometry.layerCount(tree);
            const rows = @as(u64, 1) << @intCast(log_size);
            if (evaluation.offset_bytes % 4 != 0 or evaluation.size_bytes != rows * 16)
                return recovery.RecoveryError.BindingSizeMismatch;
            var layer_offsets: [32]u32 = undefined;
            const group = merkle_layers_root_first[layer_cursor .. layer_cursor + layer_count];
            for (0..layer_count) |bottom_index| {
                const binding = group[layer_count - 1 - bottom_index];
                const expected_hashes = (@as(u64, 1) << @intCast(log_size - 2)) >> @intCast(bottom_index);
                if (binding.offset_bytes % 4 != 0 or binding.size_bytes != expected_hashes * 32)
                    return recovery.RecoveryError.BindingSizeMismatch;
                layer_offsets[bottom_index] = std.math.cast(u32, binding.offset_bytes / 4) orelse
                    return recovery.RecoveryError.BindingSizeMismatch;
            }
            self.roots[tree] = group[0];
            self.trees[tree] = try metal.prepareFriTree(
                std.math.cast(u32, evaluation.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch,
                @intCast(rows),
                @intCast(rows),
                2,
                layer_offsets[0..layer_count],
                leaf_seed,
                node_seed,
            );
            self.initialized_trees += 1;
            layer_cursor += layer_count;
        }

        const twiddle_base = std.math.cast(u32, inverse_twiddles.offset_bytes / 4) orelse
            return recovery.RecoveryError.BindingSizeMismatch;
        const twiddle_words: u32 = @intCast(inverse_twiddles.size_bytes / 4);
        for (0..geometry.roundCount()) |round| {
            const source = evaluations[round];
            const source_rows = @as(u32, 1) << @intCast(try geometry.evaluationLog(round));
            const fold_count = try geometry.roundFold(round);
            const output = if (round + 1 == geometry.roundCount()) final_evaluation else evaluations[round + 1];
            const output_rows = source_rows >> @intCast(fold_count);
            if (challenges[round].offset_bytes % 4 != 0 or challenges[round].size_bytes < 16 or
                output.offset_bytes % 4 != 0 or output.size_bytes < @as(u64, output_rows) * 16)
                return recovery.RecoveryError.BindingSizeMismatch;
            self.rounds[round] = try metal.prepareFriRound(
                twiddle_base,
                twiddle_words,
                std.math.cast(u32, source.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch,
                source_rows,
                std.math.cast(u32, challenges[round].offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch,
                std.math.cast(u32, output.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch,
                output_rows,
                source_rows,
                fold_count,
                round == 0,
            );
            self.initialized_rounds += 1;
        }
        if (final_coefficients.offset_bytes % 4 != 0 or final_coefficients.size_bytes != 32 or
            final_degree_error.offset_bytes % 4 != 0 or final_degree_error.size_bytes != 4)
            return recovery.RecoveryError.BindingSizeMismatch;
        const final_x = @import("../../core/circle.zig").Coset.halfOdds(1).initial.x;
        const inverse_x = final_x.inv() catch return recovery.RecoveryError.BindingSizeMismatch;
        self.final = try metal.prepareFriFinal(
            std.math.cast(u32, final_evaluation.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch,
            2,
            inverse_x.v,
            std.math.cast(u32, final_coefficients.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch,
            std.math.cast(u32, final_degree_error.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch,
        );
        self.initialized_final = true;
        return self;
    }

    fn deinitInitialized(self: *FriRecipe) void {
        if (self.initialized_final) self.final.deinit();
        for (self.rounds[0..self.initialized_rounds]) |*plan| plan.deinit();
        for (self.trees[0..self.initialized_trees]) |*plan| plan.deinit();
    }

    pub fn deinit(self: *FriRecipe) void {
        self.deinitInitialized();
        self.* = undefined;
    }

    pub fn commitTree(self: *FriRecipe, tree: usize) !arena_plan.Binding {
        if (tree >= self.round_count) return recovery.RecoveryError.BindingSizeMismatch;
        self.accumulated_gpu_ms += try self.metal.friTreePrepared(self.arena.buffer, self.trees[tree]);
        return self.roots[tree];
    }

    pub fn foldRound(self: *FriRecipe, round: usize) !void {
        if (round >= self.round_count) return recovery.RecoveryError.BindingSizeMismatch;
        self.accumulated_gpu_ms += try self.metal.friRoundPrepared(self.arena.buffer, self.rounds[round]);
    }

    pub fn finalize(self: *FriRecipe) !void {
        self.accumulated_gpu_ms += try self.metal.friFinalPrepared(self.arena.buffer, self.final);
        self.finalized = true;
        try self.validateFinalDegree();
    }

    pub fn validateFinalDegree(self: *FriRecipe) !void {
        if (!self.finalized) return FinalDegreeError.FinalDegreeNotComputed;
        const bytes = try self.arena.bytes(self.final_degree_error);
        if (bytes.len != @sizeOf(u32)) return recovery.RecoveryError.BindingSizeMismatch;
        const aligned: []align(@alignOf(u32)) u8 = @alignCast(bytes);
        if (std.mem.bytesAsValue(u32, aligned).* != 0)
            return FinalDegreeError.FinalDegreeExceeded;
    }
};

pub const TranscriptBinding = struct {
    ordinal: u32,
    binding: arena_plan.Binding,
};

fn bindingWordOffset(binding: arena_plan.Binding) !u64 {
    if (binding.offset_bytes % 4 != 0) return recovery.RecoveryError.BindingSizeMismatch;
    return binding.offset_bytes / 4;
}

const PendingTraceGather = struct {
    column_offsets: u64,
    column_logs: u64,
    column_count: u32,
    lifting_log: u32,
    first_column: u32,
    stride: u32,
    values: u64,
};

/// Query-normalization and FRI coset preparation for a validated Cairo opening
/// schedule. All FRI trees reuse the same epoch-local workspaces; only their
/// authenticated cumulative fold differs.
pub const DecommitQueryRecipe = struct {
    metal: *runtime.Runtime,
    arena: *arena_plan.ResidentArena,
    raw_queries: arena_plan.Binding,
    unique_queries: arena_plan.Binding,
    mapped_queries: arena_plan.Binding,
    expanded_positions: arena_plan.Binding,
    walk_queries: arena_plan.Binding,
    walk_scratch: arena_plan.Binding,
    sparse_indices: arena_plan.Binding,
    sparse_hashes: arena_plan.Binding,
    counts: arena_plan.Binding,
    assembly: arena_plan.Binding,
    tree_count: u32,
    fri_geometry: FriGeometry,
    pending_trace_gather: ?PendingTraceGather = null,
    accumulated_gpu_ms: f64 = 0,

    pub fn init(
        metal: *runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        raw_queries: arena_plan.Binding,
        unique_queries: arena_plan.Binding,
        mapped_queries: arena_plan.Binding,
        expanded_positions: arena_plan.Binding,
        walk_queries: arena_plan.Binding,
        walk_scratch: arena_plan.Binding,
        sparse_indices: arena_plan.Binding,
        sparse_hashes: arena_plan.Binding,
        counts: arena_plan.Binding,
        assembly: arena_plan.Binding,
        tree_count: u32,
        fri_start_log: u32,
    ) !DecommitQueryRecipe {
        return initWithGeometry(
            metal,
            resident_arena,
            raw_queries,
            unique_queries,
            mapped_queries,
            expanded_positions,
            walk_queries,
            walk_scratch,
            sparse_indices,
            sparse_hashes,
            counts,
            assembly,
            tree_count,
            try FriGeometry.init(fri_start_log),
        );
    }

    pub fn initWithGeometry(
        metal: *runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        raw_queries: arena_plan.Binding,
        unique_queries: arena_plan.Binding,
        mapped_queries: arena_plan.Binding,
        expanded_positions: arena_plan.Binding,
        walk_queries: arena_plan.Binding,
        walk_scratch: arena_plan.Binding,
        sparse_indices: arena_plan.Binding,
        sparse_hashes: arena_plan.Binding,
        counts: arena_plan.Binding,
        assembly: arena_plan.Binding,
        tree_count: u32,
        geometry: FriGeometry,
    ) !DecommitQueryRecipe {
        for ([_]arena_plan.Binding{ raw_queries, unique_queries, mapped_queries, expanded_positions, walk_queries, walk_scratch, sparse_indices, sparse_hashes, counts }) |binding| {
            if (binding.offset_bytes % 4 != 0) return recovery.RecoveryError.BindingSizeMismatch;
        }
        if (raw_queries.size_bytes != 70 * 4 or unique_queries.size_bytes < raw_queries.size_bytes or tree_count == 0 or
            mapped_queries.size_bytes < raw_queries.size_bytes or expanded_positions.size_bytes < 560 * 4 or
            walk_queries.size_bytes < 560 * 4 or walk_scratch.size_bytes < walk_queries.size_bytes or sparse_indices.size_bytes < 560 * 4 or counts.size_bytes < 4 * 4 or
            assembly.offset_bytes % 4 != 0 or assembly.size_bytes / 4 > std.math.maxInt(u32))
            return recovery.RecoveryError.BindingSizeMismatch;
        return .{
            .metal = metal,
            .arena = resident_arena,
            .raw_queries = raw_queries,
            .unique_queries = unique_queries,
            .mapped_queries = mapped_queries,
            .expanded_positions = expanded_positions,
            .walk_queries = walk_queries,
            .walk_scratch = walk_scratch,
            .sparse_indices = sparse_indices,
            .sparse_hashes = sparse_hashes,
            .counts = counts,
            .assembly = assembly,
            .tree_count = tree_count,
            .fri_geometry = geometry,
        };
    }

    pub fn normalize(self: *DecommitQueryRecipe) !void {
        if (self.pending_trace_gather != null) return recovery.RecoveryError.BindingSizeMismatch;
        const count_base = try bindingWordOffset(self.counts);
        self.accumulated_gpu_ms += try self.metal.decommitNormalizeQueries(
            self.arena.buffer,
            try bindingWordOffset(self.raw_queries),
            70,
            self.fri_geometry.start_log,
            try bindingWordOffset(self.unique_queries),
            count_base,
            self.tree_count,
            try bindingWordOffset(self.assembly),
            @intCast(self.assembly.size_bytes / 4),
        );
    }

    pub fn prepareFri(self: *DecommitQueryRecipe, round: usize) !void {
        if (self.pending_trace_gather != null or round >= self.fri_geometry.roundCount())
            return recovery.RecoveryError.BindingSizeMismatch;
        const count_base = try bindingWordOffset(self.counts);
        self.accumulated_gpu_ms += try self.metal.decommitPrepareFriQueries(
            self.arena.buffer,
            try bindingWordOffset(self.unique_queries),
            count_base,
            70,
            try self.fri_geometry.cumulativeFold(round),
            try self.fri_geometry.roundFold(round),
            self.fri_geometry.packedLog(),
            try bindingWordOffset(self.mapped_queries),
            count_base + 1,
            try bindingWordOffset(self.expanded_positions),
            count_base + 3,
            try bindingWordOffset(self.walk_queries),
            count_base + 2,
        );
    }

    /// Encodes query preparation, coordinate gathering, and proof assembly for
    /// one FRI tree into a single command buffer. There is no host dependency
    /// between these kernels; separate encoders preserve their device ordering.
    pub fn executeFriRound(
        self: *DecommitQueryRecipe,
        round: usize,
        tree_index: u32,
        leaf_log: u32,
        coordinate_offsets: arena_plan.Binding,
        retained_offsets: arena_plan.Binding,
        values: arena_plan.Binding,
    ) !void {
        if (self.pending_trace_gather != null) return recovery.RecoveryError.BindingSizeMismatch;
        try validateFriOpeningRound(self.fri_geometry, round, leaf_log);
        if (coordinate_offsets.size_bytes < 8 * @sizeOf(u32) or
            retained_offsets.size_bytes < @as(u64, leaf_log + 1) * 2 * @sizeOf(u32) or
            values.size_bytes < self.expanded_positions.size_bytes * 4)
            return recovery.RecoveryError.BindingSizeMismatch;
        const count_base = try bindingWordOffset(self.counts);
        self.accumulated_gpu_ms += try self.metal.decommitFriRound(
            self.arena.buffer,
            .{
                .unique_base = try bindingWordOffset(self.unique_queries),
                .unique_count_base = count_base,
                .tree_queries_base = try bindingWordOffset(self.mapped_queries),
                .tree_count_base = count_base + 1,
                .expanded_base = try bindingWordOffset(self.expanded_positions),
                .expanded_count_base = count_base + 3,
                .walk_base = try bindingWordOffset(self.walk_queries),
                .walk_count_base = count_base + 2,
                .coordinate_bases = try bindingWordOffset(coordinate_offsets),
                .values_base = try bindingWordOffset(values),
                .walk_scratch_base = try bindingWordOffset(self.walk_scratch),
                .retained_offsets = try bindingWordOffset(retained_offsets),
                .assembly_base = try bindingWordOffset(self.assembly),
                .max_queries = 70,
                .cumulative_fold = try self.fri_geometry.cumulativeFold(round),
                .fold_step = try self.fri_geometry.roundFold(round),
                .packed_log = self.fri_geometry.packedLog(),
                .max_positions = @intCast(self.expanded_positions.size_bytes / @sizeOf(u32)),
                .tree_index = tree_index,
                .leaf_log = leaf_log,
                .assembly_capacity = @intCast(self.assembly.size_bytes / @sizeOf(u32)),
            },
        );
    }

    pub fn prepareTrace(
        self: *DecommitQueryRecipe,
        source_log: u32,
        tree_log: u32,
        leaf_log: u32,
        unretained: u32,
    ) !void {
        if (self.pending_trace_gather != null) return recovery.RecoveryError.BindingSizeMismatch;
        const count_base = try bindingWordOffset(self.counts);
        self.accumulated_gpu_ms += try self.metal.decommitPrepareTraceQueries(
            self.arena.buffer,
            try bindingWordOffset(self.unique_queries),
            count_base,
            70,
            source_log,
            tree_log,
            leaf_log,
            unretained,
            try bindingWordOffset(self.mapped_queries),
            count_base + 1,
            try bindingWordOffset(self.walk_queries),
            count_base + 2,
            try bindingWordOffset(self.sparse_indices),
            count_base + 4,
        );
    }

    pub fn gatherTraceValues(
        self: *DecommitQueryRecipe,
        column_offsets: arena_plan.Binding,
        column_logs: arena_plan.Binding,
        column_count: u32,
        lifting_log: u32,
        first_column: u32,
        stride: u32,
        values: arena_plan.Binding,
    ) !void {
        if (self.pending_trace_gather != null) return recovery.RecoveryError.BindingSizeMismatch;
        if (column_count == 0 or lifting_log >= 31 or stride < 70 or
            column_offsets.size_bytes < @as(u64, column_count) * 4 or
            column_logs.size_bytes < @as(u64, column_count) * 4 or
            values.size_bytes < (@as(u64, first_column) + column_count) * stride * 4)
            return recovery.RecoveryError.BindingSizeMismatch;
        self.pending_trace_gather = .{
            .column_offsets = try bindingWordOffset(column_offsets),
            .column_logs = try bindingWordOffset(column_logs),
            .column_count = column_count,
            .lifting_log = lifting_log,
            .first_column = first_column,
            .stride = stride,
            .values = try bindingWordOffset(values),
        };
    }

    pub fn sparseParent(
        self: *DecommitQueryRecipe,
        distance: u32,
        child_offset: u32,
        child_capacity: u32,
        parent_offset: u32,
        node_seed: [8]u32,
    ) !void {
        if (self.pending_trace_gather != null) return recovery.RecoveryError.BindingSizeMismatch;
        if (distance == 0 or child_capacity < 2 or parent_offset >= self.sparse_indices.size_bytes / 4 or
            @as(u64, child_offset + child_capacity) * 4 > self.sparse_indices.size_bytes or
            @as(u64, child_offset + child_capacity) * 32 > self.sparse_hashes.size_bytes)
            return recovery.RecoveryError.BindingSizeMismatch;
        const count_base = try bindingWordOffset(self.counts);
        self.accumulated_gpu_ms += try self.metal.decommitSparseParent(
            self.arena.buffer,
            try bindingWordOffset(self.sparse_indices) + child_offset,
            try bindingWordOffset(self.sparse_hashes) + child_offset * 8,
            count_base + 4 + distance - 1,
            child_capacity,
            try bindingWordOffset(self.sparse_indices) + parent_offset,
            try bindingWordOffset(self.sparse_hashes) + parent_offset * 8,
            count_base + 4 + distance,
            node_seed,
        );
    }

    pub fn sparseLeaves(
        self: *DecommitQueryRecipe,
        column_offsets: arena_plan.Binding,
        column_logs: arena_plan.Binding,
        column_count: u32,
        leaf_log: u32,
        max_leaf_count: u32,
        leaf_seed: [8]u32,
    ) !void {
        if (self.pending_trace_gather != null) return recovery.RecoveryError.BindingSizeMismatch;
        if (column_offsets.size_bytes < @as(u64, column_count) * 4 or
            column_logs.size_bytes < @as(u64, column_count) * 4 or
            @as(u64, max_leaf_count) * 4 > self.sparse_indices.size_bytes or
            @as(u64, max_leaf_count) * 32 > self.sparse_hashes.size_bytes)
            return recovery.RecoveryError.BindingSizeMismatch;
        const count_base = try bindingWordOffset(self.counts);
        self.accumulated_gpu_ms += try self.metal.decommitSparseLeaves(
            self.arena.buffer,
            try bindingWordOffset(column_offsets),
            try bindingWordOffset(column_logs),
            column_count,
            leaf_log,
            try bindingWordOffset(self.sparse_indices),
            count_base + 4,
            max_leaf_count,
            try bindingWordOffset(self.sparse_hashes),
            leaf_seed,
        );
    }

    pub fn sparseLeafGroup(
        self: *DecommitQueryRecipe,
        column_offsets: arena_plan.Binding,
        column_logs: arena_plan.Binding,
        column_count: u32,
        first_column: u32,
        total_columns: u32,
        lifting_log: u32,
        max_leaf_count: u32,
        leaf_seed: [8]u32,
    ) !void {
        if (column_count == 0 or column_count > 16 or first_column >= total_columns or
            column_count > total_columns - first_column or first_column % 16 != 0 or
            (first_column + column_count < total_columns and column_count % 16 != 0) or
            column_offsets.size_bytes < @as(u64, column_count) * 4 or
            column_logs.size_bytes < @as(u64, column_count) * 4 or
            @as(u64, max_leaf_count) * 4 > self.sparse_indices.size_bytes or
            @as(u64, max_leaf_count) * 32 > self.sparse_hashes.size_bytes)
            return recovery.RecoveryError.BindingSizeMismatch;
        const pending = self.pending_trace_gather orelse return recovery.RecoveryError.BindingSizeMismatch;
        const column_offsets_words = try bindingWordOffset(column_offsets);
        const column_logs_words = try bindingWordOffset(column_logs);
        if (pending.column_offsets != column_offsets_words or pending.column_logs != column_logs_words or
            pending.column_count != column_count or pending.first_column != first_column or
            pending.lifting_log != lifting_log)
            return recovery.RecoveryError.BindingSizeMismatch;
        const count_base = try bindingWordOffset(self.counts);
        self.accumulated_gpu_ms += try self.metal.decommitTraceGroup(
            self.arena.buffer,
            .{
                .column_offsets = pending.column_offsets,
                .column_logs = pending.column_logs,
                .queries = try bindingWordOffset(self.mapped_queries),
                .query_count_at = count_base + 1,
                .values = pending.values,
                .leaf_indices = try bindingWordOffset(self.sparse_indices),
                .leaf_count_at = count_base + 4,
                .output_hashes = try bindingWordOffset(self.sparse_hashes),
                .column_count = column_count,
                .lifting_log = lifting_log,
                .max_queries = 70,
                .first_column = first_column,
                .stride = pending.stride,
                .total_columns = total_columns,
                .max_leaf_count = max_leaf_count,
                .leaf_seed = leaf_seed,
            },
        );
        self.pending_trace_gather = null;
    }

    pub fn assembleTrace(
        self: *DecommitQueryRecipe,
        tree_index: u32,
        role: u32,
        leaf_log: u32,
        unretained: u32,
        column_count: u32,
        retained_offsets: arena_plan.Binding,
        sparse_offsets: arena_plan.Binding,
        values: arena_plan.Binding,
    ) !void {
        if (self.pending_trace_gather != null) return recovery.RecoveryError.BindingSizeMismatch;
        if (unretained > leaf_log or retained_offsets.size_bytes < @as(u64, leaf_log - unretained + 1) * 4 or
            sparse_offsets.size_bytes < @as(u64, unretained) * 4 or values.size_bytes < @as(u64, column_count) * 70 * 4)
            return recovery.RecoveryError.BindingSizeMismatch;
        const count_base = try bindingWordOffset(self.counts);
        self.accumulated_gpu_ms += try self.metal.decommitAssembleTrace(
            self.arena.buffer,
            tree_index,
            role,
            leaf_log,
            leaf_log - unretained,
            column_count,
            try bindingWordOffset(self.mapped_queries),
            count_base + 1,
            70,
            try bindingWordOffset(self.walk_queries),
            try bindingWordOffset(self.walk_scratch),
            count_base + 2,
            try bindingWordOffset(values),
            try bindingWordOffset(retained_offsets),
            try bindingWordOffset(self.sparse_indices),
            try bindingWordOffset(self.sparse_hashes),
            try bindingWordOffset(sparse_offsets),
            count_base + 4,
            unretained,
            try bindingWordOffset(self.assembly),
            @intCast(self.assembly.size_bytes / 4),
        );
    }

    pub fn gatherFriValues(
        self: *DecommitQueryRecipe,
        coordinate_offsets: arena_plan.Binding,
        values: arena_plan.Binding,
    ) !void {
        if (coordinate_offsets.size_bytes < 16 or values.size_bytes < self.expanded_positions.size_bytes * 4)
            return recovery.RecoveryError.BindingSizeMismatch;
        const count_base = try bindingWordOffset(self.counts);
        self.accumulated_gpu_ms += try self.metal.decommitGatherFriValues(
            self.arena.buffer,
            try bindingWordOffset(coordinate_offsets),
            try bindingWordOffset(self.expanded_positions),
            count_base + 3,
            @intCast(self.expanded_positions.size_bytes / 4),
            try bindingWordOffset(values),
        );
    }

    pub fn assembleFri(
        self: *DecommitQueryRecipe,
        tree_index: u32,
        leaf_log: u32,
        coordinate_offsets: arena_plan.Binding,
        retained_offsets: arena_plan.Binding,
        values: arena_plan.Binding,
    ) !void {
        try self.gatherFriValues(coordinate_offsets, values);
        if (retained_offsets.size_bytes < @as(u64, leaf_log + 1) * 4) return recovery.RecoveryError.BindingSizeMismatch;
        const count_base = try bindingWordOffset(self.counts);
        self.accumulated_gpu_ms += try self.metal.decommitAssembleFri(
            self.arena.buffer,
            tree_index,
            leaf_log,
            try bindingWordOffset(self.mapped_queries),
            count_base + 1,
            try bindingWordOffset(self.expanded_positions),
            count_base + 3,
            try bindingWordOffset(values),
            try bindingWordOffset(self.walk_queries),
            try bindingWordOffset(self.walk_scratch),
            count_base + 2,
            try bindingWordOffset(retained_offsets),
            try bindingWordOffset(self.assembly),
            @intCast(self.assembly.size_bytes / 4),
        );
    }
};

/// Exact Cairo transcript controller. Blake2s absorption and rejection-sampled
/// challenge/query draws execute in the resident arena; the host only orders
/// true protocol dependencies and grinds the two proof-of-work nonces.
pub const PowExecutionMode = enum {
    not_run,
    self_ground,
    fixture_forced,
    mixed,
};

/// CPU-only timing around nonce search or validation. Transcript-state
/// readback, nonce absorption, and subsequent Metal draws are deliberately
/// excluded so diagnostic nonce validation cannot masquerade as search cost.
pub const PowTelemetry = struct {
    mode: PowExecutionMode = .not_run,
    pow_bits: u32 = 0,
    invocations: u32 = 0,
    wall_ns: u64 = 0,

    pub fn wallSeconds(self: PowTelemetry) ?f64 {
        if (self.invocations == 0) return null;
        return @as(f64, @floatFromInt(self.wall_ns)) /
            @as(f64, @floatFromInt(std.time.ns_per_s));
    }

    pub fn modeName(self: PowTelemetry) ?[]const u8 {
        return if (self.mode == .not_run) null else @tagName(self.mode);
    }

    fn record(self: *PowTelemetry, mode: PowExecutionMode, pow_bits: u32, elapsed_ns: u64) void {
        if (self.invocations == 0) {
            self.mode = mode;
            self.pow_bits = pow_bits;
        } else if (self.mode != mode or self.pow_bits != pow_bits) {
            self.mode = .mixed;
        }
        self.invocations += 1;
        self.wall_ns +|= elapsed_ns;
    }
};

test "PoW telemetry separates search from forced validation" {
    var telemetry = PowTelemetry{};
    try std.testing.expectEqual(@as(?f64, null), telemetry.wallSeconds());
    try std.testing.expectEqual(@as(?[]const u8, null), telemetry.modeName());

    telemetry.record(.self_ground, 24, std.time.ns_per_ms * 3);
    try std.testing.expectEqualStrings("self_ground", telemetry.modeName().?);
    try std.testing.expectEqual(@as(u32, 24), telemetry.pow_bits);
    try std.testing.expectEqual(@as(u32, 1), telemetry.invocations);
    try std.testing.expectApproxEqAbs(@as(f64, 0.003), telemetry.wallSeconds().?, 1e-12);

    telemetry.record(.self_ground, 24, std.time.ns_per_ms * 2);
    try std.testing.expectEqual(@as(u32, 2), telemetry.invocations);
    try std.testing.expectApproxEqAbs(@as(f64, 0.005), telemetry.wallSeconds().?, 1e-12);

    telemetry.record(.fixture_forced, 24, 1);
    try std.testing.expectEqualStrings("mixed", telemetry.modeName().?);
}

pub const TranscriptRecipe = struct {
    allocator: std.mem.Allocator,
    metal: *runtime.Runtime,
    arena: *arena_plan.ResidentArena,
    state: arena_plan.Binding,
    query_log: u32,
    inputs: []TranscriptBinding,
    outputs: []TranscriptBinding,
    accumulated_gpu_ms: f64 = 0,
    interaction_pow: PowTelemetry = .{},
    query_pow: PowTelemetry = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        metal: *runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        state: arena_plan.Binding,
        query_log: u32,
        inputs: []const TranscriptBinding,
        outputs: []const TranscriptBinding,
    ) !TranscriptRecipe {
        if (state.offset_bytes % 4 != 0 or state.size_bytes < 40 or query_log >= 31 or
            inputs.len == 0 or outputs.len == 0)
            return recovery.RecoveryError.BindingSizeMismatch;
        return .{
            .allocator = allocator,
            .metal = metal,
            .arena = resident_arena,
            .state = state,
            .query_log = query_log,
            .inputs = try allocator.dupe(TranscriptBinding, inputs),
            .outputs = try allocator.dupe(TranscriptBinding, outputs),
        };
    }

    pub fn deinit(self: *TranscriptRecipe) void {
        self.allocator.free(self.inputs);
        self.allocator.free(self.outputs);
        self.* = undefined;
    }

    pub fn initialize(self: *TranscriptRecipe) !void {
        self.accumulated_gpu_ms += try self.metal.transcriptInit(self.arena.buffer, try wordOffset(self.state));
    }

    pub fn publishInput(self: *TranscriptRecipe, ordinal: u32, source: arena_plan.Binding, words: u32) !void {
        const destination = try self.find(self.inputs, ordinal);
        if (source.size_bytes < @as(u64, words) * 4 or destination.size_bytes < @as(u64, words) * 4)
            return recovery.RecoveryError.BindingSizeMismatch;
        const source_bytes = try self.arena.bytes(source);
        const destination_bytes = try self.arena.bytes(destination);
        @memcpy(destination_bytes[0 .. @as(usize, words) * 4], source_bytes[0 .. @as(usize, words) * 4]);
    }

    /// Loads a parity fixture directly into one transcript input binding.
    pub fn loadInputWords(self: *TranscriptRecipe, ordinal: u32, words: []const u32) !void {
        const destination = try self.find(self.inputs, ordinal);
        if (destination.size_bytes != @as(u64, words.len) * 4)
            return recovery.RecoveryError.BindingSizeMismatch;
        const destination_bytes: []align(4) u8 = @alignCast(try self.arena.bytes(destination));
        @memcpy(std.mem.bytesAsSlice(u32, destination_bytes), words);
    }

    /// Fails closed when a resident transcript draw differs from the reference.
    pub fn expectOutputWords(self: TranscriptRecipe, ordinal: u32, expected: []const u32) !void {
        const output_binding = try self.find(self.outputs, ordinal);
        if (output_binding.size_bytes < @as(u64, expected.len) * 4)
            return recovery.RecoveryError.BindingSizeMismatch;
        const output_bytes: []align(4) u8 = @alignCast(try self.arena.bytes(output_binding));
        const actual = std.mem.bytesAsSlice(u32, output_bytes);
        if (!std.mem.eql(u32, actual[0..expected.len], expected)) {
            std.debug.print(
                "transcript output parity mismatch ordinal={} actual={any} expected={any}\n",
                .{ ordinal, actual[0..expected.len], expected },
            );
            return error.TranscriptParityMismatch;
        }
    }

    pub fn expectInputWords(self: TranscriptRecipe, ordinal: u32, expected: []const u32) !void {
        const input_binding = try self.find(self.inputs, ordinal);
        if (input_binding.size_bytes != @as(u64, expected.len) * 4)
            return recovery.RecoveryError.BindingSizeMismatch;
        const input_bytes: []align(4) u8 = @alignCast(try self.arena.bytes(input_binding));
        const actual = std.mem.bytesAsSlice(u32, input_bytes);
        if (!std.mem.eql(u32, actual, expected)) {
            std.debug.print(
                "transcript input parity mismatch ordinal={} actual={any} expected={any}\n",
                .{ ordinal, actual, expected },
            );
            return error.TranscriptParityMismatch;
        }
    }

    pub fn bootstrapThroughBase(self: *TranscriptRecipe) !void {
        for ([_]u32{ 1, 2, 3, 10, 11, 12, 13, 14, 15, 16, 20 }) |input| try self.mixInput(input);
    }

    pub fn interactionPowAndLookup(self: *TranscriptRecipe) !u64 {
        const nonce = try self.grindAndMix(21, 24, &self.interaction_pow);
        try self.drawSecure(1, 2);
        return nonce;
    }

    /// Uses and validates the Rust reference nonce for transcript parity. Rust
    /// and Zig search valid nonces in different orders, so local grinding is
    /// not expected to reproduce the same transcript suffix.
    pub fn interactionPowAndLookupNonce(self: *TranscriptRecipe, nonce: u64) !void {
        try self.validateAndMixNonce(21, 24, nonce, &self.interaction_pow);
        try self.drawSecure(1, 2);
    }

    pub fn interactionAndComposition(self: *TranscriptRecipe) !void {
        try self.mixInput(22);
        try self.mixInput(23);
        try self.drawSecure(2, 1);
    }

    pub fn compositionAndOods(self: *TranscriptRecipe) !void {
        try self.mixInput(24);
        try self.drawSecure(3, 1);
    }

    pub fn oodsAndQuotient(self: *TranscriptRecipe) !void {
        try self.mixInput(25);
        try self.drawSecure(4, 1);
    }

    pub fn friLayer(
        self: *TranscriptRecipe,
        layer: u32,
        root: arena_plan.Binding,
        challenge: arena_plan.Binding,
    ) !void {
        const input_ordinal = 65536 + layer * 4;
        const output_ordinal = input_ordinal + 1;
        try self.publishInput(input_ordinal, root, 8);
        try self.mixInput(input_ordinal);
        try self.drawSecure(output_ordinal, 1);
        const drawn = try self.find(self.outputs, output_ordinal);
        const output_bytes = try self.arena.bytes(drawn);
        const challenge_bytes = try self.arena.bytes(challenge);
        if (challenge_bytes.len < 16) return recovery.RecoveryError.BindingSizeMismatch;
        @memcpy(challenge_bytes[0..16], output_bytes[0..16]);
    }

    pub fn lastLayer(self: *TranscriptRecipe, coefficients: arena_plan.Binding) !void {
        try self.publishInput(30, coefficients, 4);
        try self.mixInput(30);
    }

    pub fn queryPowAndPositions(self: *TranscriptRecipe) !u64 {
        const nonce = try self.grindAndMix(31, 26, &self.query_pow);
        try self.drawQueryPositions();
        return nonce;
    }

    pub fn queryPowAndPositionsNonce(self: *TranscriptRecipe, nonce: u64) !void {
        try self.validateAndMixNonce(31, 26, nonce, &self.query_pow);
        try self.drawQueryPositions();
    }

    fn drawQueryPositions(self: *TranscriptRecipe) !void {
        const queries = try self.find(self.outputs, 5);
        self.accumulated_gpu_ms += try self.metal.transcriptDrawQueries(
            self.arena.buffer,
            try wordOffset(self.state),
            try wordOffset(queries),
            self.query_log,
            70,
        );
    }

    pub fn output(self: TranscriptRecipe, ordinal: u32) !arena_plan.Binding {
        return self.find(self.outputs, ordinal);
    }

    fn mixInput(self: *TranscriptRecipe, ordinal: u32) !void {
        const input = try self.find(self.inputs, ordinal);
        if (input.size_bytes == 0 or input.size_bytes % 4 != 0 or input.size_bytes / 4 > std.math.maxInt(u32))
            return recovery.RecoveryError.BindingSizeMismatch;
        self.accumulated_gpu_ms += try self.metal.transcriptMix(
            self.arena.buffer,
            try wordOffset(self.state),
            try wordOffset(input),
            @intCast(input.size_bytes / 4),
        );
    }

    fn drawSecure(self: *TranscriptRecipe, ordinal: u32, felt_count: u32) !void {
        const output_binding = try self.find(self.outputs, ordinal);
        if (output_binding.size_bytes < @as(u64, felt_count) * 16)
            return recovery.RecoveryError.BindingSizeMismatch;
        self.accumulated_gpu_ms += try self.metal.transcriptDrawSecure(
            self.arena.buffer,
            try wordOffset(self.state),
            try wordOffset(output_binding),
            felt_count,
        );
    }

    fn grindAndMix(
        self: *TranscriptRecipe,
        input_ordinal: u32,
        pow_bits: u32,
        telemetry: *PowTelemetry,
    ) !u64 {
        const channel = try self.channelFromState();
        var timer = try std.time.Timer.start();
        const nonce = channel.grind(pow_bits);
        telemetry.record(.self_ground, pow_bits, timer.read());
        try self.writeAndMixNonce(input_ordinal, nonce);
        return nonce;
    }

    fn validateAndMixNonce(
        self: *TranscriptRecipe,
        input_ordinal: u32,
        pow_bits: u32,
        nonce: u64,
        telemetry: *PowTelemetry,
    ) !void {
        const channel = try self.channelFromState();
        var timer = try std.time.Timer.start();
        const valid = channel.verifyPowNonce(pow_bits, nonce);
        telemetry.record(.fixture_forced, pow_bits, timer.read());
        if (!valid) return error.InvalidReferencePowNonce;
        try self.writeAndMixNonce(input_ordinal, nonce);
    }

    fn writeAndMixNonce(self: *TranscriptRecipe, input_ordinal: u32, nonce: u64) !void {
        const destination = try self.find(self.inputs, input_ordinal);
        const destination_bytes = try self.arena.bytes(destination);
        if (destination_bytes.len < 8) return recovery.RecoveryError.BindingSizeMismatch;
        std.mem.writeInt(u64, destination_bytes[0..8], nonce, .little);
        try self.mixInput(input_ordinal);
    }

    fn channelFromState(self: TranscriptRecipe) !blake2s_channel.Blake2sChannel {
        const state_bytes = try self.arena.bytes(self.state);
        if (state_bytes.len < 9 * 4) return recovery.RecoveryError.BindingSizeMismatch;
        const state_words = std.mem.bytesAsSlice(u32, @as([]align(4) u8, @alignCast(state_bytes)));
        var channel = blake2s_channel.Blake2sChannel{};
        @memcpy(&channel.digest, std.mem.sliceAsBytes(state_words[0..8]));
        channel.n_draws = state_words[8];
        return channel;
    }

    fn find(_: TranscriptRecipe, bindings: []const TranscriptBinding, ordinal: u32) !arena_plan.Binding {
        for (bindings) |binding| if (binding.ordinal == ordinal) return binding.binding;
        return recovery.RecoveryError.MissingRecipe;
    }

    fn wordOffset(binding: arena_plan.Binding) !u32 {
        if (binding.offset_bytes % 4 != 0) return recovery.RecoveryError.BindingSizeMismatch;
        return std.math.cast(u32, binding.offset_bytes / 4) orelse recovery.RecoveryError.BindingSizeMismatch;
    }
};

pub const ProofCopy = struct {
    source: arena_plan.Binding,
    destination_word_offset: u32,
    word_count: u32,
};

/// Seals all proof-visible roots, claims, samples, nonces, final coefficients
/// and compact decommitment words into one resident buffer using one blit
/// command. Only this buffer crosses the host boundary.
pub const ProofAssemblyRecipe = struct {
    allocator: std.mem.Allocator,
    metal: *runtime.Runtime,
    arena: *arena_plan.ResidentArena,
    destination: arena_plan.Binding,
    ranges: []runtime.ArenaCopyRange,
    prepared: runtime.ArenaCopyPlan,
    last_tick: ?u16 = null,
    accumulated_gpu_ms: f64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        metal: *runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        copies: []const ProofCopy,
        destination: arena_plan.Binding,
    ) !ProofAssemblyRecipe {
        if (copies.len == 0 or destination.offset_bytes % 4 != 0) return recovery.RecoveryError.BindingSizeMismatch;
        const ranges = try allocator.alloc(runtime.ArenaCopyRange, copies.len);
        errdefer allocator.free(ranges);
        var expected_destination_words: u64 = 0;
        for (copies, ranges) |copy, *range| {
            if (copy.source.offset_bytes % 4 != 0 or copy.word_count == 0 or
                copy.source.size_bytes < @as(u64, copy.word_count) * 4 or
                copy.destination_word_offset != expected_destination_words)
                return recovery.RecoveryError.BindingSizeMismatch;
            range.* = .{
                .source_word_offset = copy.source.offset_bytes / 4,
                .destination_word_offset = std.math.add(
                    u64,
                    destination.offset_bytes / 4,
                    @as(u64, copy.destination_word_offset),
                ) catch return recovery.RecoveryError.BindingSizeMismatch,
                .word_count = copy.word_count,
            };
            expected_destination_words += copy.word_count;
        }
        if (expected_destination_words * 4 != destination.size_bytes) return recovery.RecoveryError.BindingSizeMismatch;
        return .{
            .allocator = allocator,
            .metal = metal,
            .arena = resident_arena,
            .destination = destination,
            .ranges = ranges,
            .prepared = try metal.prepareArenaCopies(ranges),
        };
    }

    pub fn deinit(self: *ProofAssemblyRecipe) void {
        self.prepared.deinit();
        self.allocator.free(self.ranges);
        self.* = undefined;
    }

    pub fn recipe(self: *ProofAssemblyRecipe) recovery.Recipe {
        return .{ .logical_id = self.destination.logical_id, .context = self, .run = run };
    }

    pub fn execute(self: *ProofAssemblyRecipe) !void {
        self.accumulated_gpu_ms += try self.metal.arenaCopyPrepared(self.arena.buffer, self.prepared);
    }

    pub fn words(self: *ProofAssemblyRecipe) ![]const u32 {
        const bytes = try self.arena.bytes(self.destination);
        const aligned: []align(@alignOf(u32)) u8 = @alignCast(bytes);
        return std.mem.bytesAsSlice(u32, aligned);
    }

    fn run(raw: *anyopaque, tick: u16, requested: arena_plan.Binding, _: []u8) !void {
        const self: *ProofAssemblyRecipe = @ptrCast(@alignCast(raw));
        if (requested.logical_id != self.destination.logical_id) return recovery.RecoveryError.MissingRecipe;
        if (self.last_tick == tick) return;
        try self.execute();
        self.last_tick = tick;
    }
};

test "AOT witness batch request reset preserves prepared ownership" {
    const plans = [_]runtime.WitnessPlan{.{ .handle = undefined }};
    const destinations = [_]arena_plan.Binding{undefined};
    const workspace_writes = [_][]OwnedAotWorkspaceWrite{&.{}};
    var recipe = AotWitnessBatchRecipe{
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

test "fixed table batch request reset preserves prepared ownership" {
    const plans = [_]runtime.FixedTablePlan{.{ .handle = undefined }};
    const single_batches = [_]runtime.FixedTableBatchPlan{.{ .handle = undefined }};
    const destinations = [_]arena_plan.Binding{undefined};
    var recipe = FixedTableBatchRecipe{
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
    var descriptor_image = try CompactDescriptorImage.init(
        std.testing.allocator,
        binding,
        &request_descriptors,
    );
    errdefer descriptor_image.deinit();
    try std.testing.expect(descriptor_image.words.ptr != request_descriptors[0..].ptr);

    const destinations = [_]arena_plan.Binding{binding};
    var recipe = CompactRecipe{
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

test "Metal protocol recovery: copy recipe writes the destination binding" {
    const Access = struct {
        source: []u8,
        fn bytes(raw: *anyopaque, _: arena_plan.Binding) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return self.source;
        }
    };
    var source = [_]u8{ 1, 2, 3, 4 };
    var access_context = Access{ .source = &source };
    const binding = arena_plan.Binding{
        .logical_id = 1,
        .slot = 0,
        .offset_bytes = 0,
        .size_bytes = 4,
        .materialization = .resident,
        .occupied = [_]u64{0} ** (arena_plan.max_ticks / 64),
    };
    var copy = CopyRecipe{ .access = .{ .context = &access_context, .bytes_fn = Access.bytes }, .source = binding };
    var destination = [_]u8{0} ** 4;
    try copy.recipe(2).run(&copy, 1, binding, &destination);
    try std.testing.expectEqualSlices(u8, &source, &destination);
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
