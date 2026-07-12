const std = @import("std");
const M31 = @import("../../core/fields/m31.zig").M31;
const arena_plan = @import("arena_plan.zig");
const recovery = @import("recovery.zig");
const runtime = @import("runtime.zig");
const blake2s_channel = @import("../../core/channel/blake2s.zig");

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
    last_tick: ?u16 = null,
    accumulated_gpu_ms: f64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        metal: *runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        metallib_path: []const u8,
        invocations: []const AotWitnessInvocation,
    ) !AotWitnessBatchRecipe {
        if (invocations.len == 0) return recovery.RecoveryError.BindingSizeMismatch;
        var library = try metal.loadEvalLibrary(metallib_path);
        defer library.deinit();
        const plans = try allocator.alloc(runtime.WitnessPlan, invocations.len);
        var initialized: usize = 0;
        errdefer {
            for (plans[0..initialized]) |*plan| plan.deinit();
            allocator.free(plans);
        }
        var destinations = std.ArrayList(arena_plan.Binding).empty;
        errdefer destinations.deinit(allocator);
        for (invocations, plans) |invocation, *plan| {
            if (invocation.kernel_name.len == 0 or invocation.destinations.len == 0 or
                invocation.layout.row_count == 0 or !std.math.isPowerOfTwo(invocation.layout.row_count))
                return recovery.RecoveryError.BindingSizeMismatch;
            plan.* = try metal.prepareWitnessFromLibrary(library, invocation.kernel_name, invocation.layout);
            initialized += 1;
            for (invocation.destinations) |destination| {
                for (destinations.items) |existing| if (existing.logical_id == destination.logical_id)
                    return recovery.RecoveryError.BindingSizeMismatch;
                try destinations.append(allocator, destination);
            }
        }
        try library.serialize();
        return .{
            .allocator = allocator,
            .metal = metal,
            .arena = resident_arena,
            .plans = plans,
            .destinations = try destinations.toOwnedSlice(allocator),
        };
    }

    pub fn deinit(self: *AotWitnessBatchRecipe) void {
        for (self.plans) |*plan| plan.deinit();
        self.allocator.free(self.plans);
        self.allocator.free(self.destinations);
        self.* = undefined;
    }

    pub fn execute(self: *AotWitnessBatchRecipe) !void {
        for (self.plans) |plan| self.accumulated_gpu_ms += try self.metal.witnessPrepared(self.arena.buffer, plan);
    }

    pub fn executeIndex(self: *AotWitnessBatchRecipe, index: usize) !void {
        if (index >= self.plans.len) return recovery.RecoveryError.BindingSizeMismatch;
        self.accumulated_gpu_ms += try self.metal.witnessPrepared(self.arena.buffer, self.plans[index]);
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
        const source_offsets = try allocator.alloc(u32, sources.len);
        defer allocator.free(source_offsets);
        const destination_offsets = try allocator.alloc(u32, destinations.len);
        defer allocator.free(destination_offsets);
        for (sources, destinations, source_offsets, destination_offsets) |source, destination, *source_offset, *destination_offset| {
            if (source.offset_bytes % 4 != 0 or destination.offset_bytes % 4 != 0 or
                source.size_bytes != base_bytes or destination.size_bytes != extended_bytes)
                return recovery.RecoveryError.BindingSizeMismatch;
            source_offset.* = std.math.cast(u32, source.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch;
            destination_offset.* = std.math.cast(u32, destination.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch;
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
    destinations: []arena_plan.Binding,
    prepared: runtime.CircleIfftPlan,
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
        const source_offsets = try allocator.alloc(u32, sources.len);
        defer allocator.free(source_offsets);
        const destination_offsets = try allocator.alloc(u32, destinations.len);
        defer allocator.free(destination_offsets);
        for (sources, destinations, source_offsets, destination_offsets) |source, destination, *source_offset, *destination_offset| {
            if (source.offset_bytes % 4 != 0 or destination.offset_bytes % 4 != 0 or
                source.size_bytes != column_bytes or destination.size_bytes != column_bytes)
                return recovery.RecoveryError.BindingSizeMismatch;
            source_offset.* = std.math.cast(u32, source.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch;
            destination_offset.* = std.math.cast(u32, destination.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch;
        }
        var prepared = try metal.prepareCircleIfft(
            source_offsets,
            destination_offsets,
            log_size,
            std.math.cast(u32, inverse_twiddles.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch,
            scale_factor.v,
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

    pub fn deinit(self: *CircleIfftRecipe) void {
        self.prepared.deinit();
        self.allocator.free(self.destinations);
        self.* = undefined;
    }

    pub fn makeRecipes(self: *CircleIfftRecipe, allocator: std.mem.Allocator) ![]recovery.Recipe {
        const recipes = try allocator.alloc(recovery.Recipe, self.destinations.len);
        for (self.destinations, recipes) |binding, *recipe_entry| {
            recipe_entry.* = .{ .logical_id = binding.logical_id, .context = self, .run = run };
        }
        return recipes;
    }

    fn run(raw: *anyopaque, tick: u16, requested: arena_plan.Binding, _: []u8) !void {
        const self: *CircleIfftRecipe = @ptrCast(@alignCast(raw));
        if (self.last_tick == tick) return;
        var found = false;
        for (self.destinations) |binding| found = found or binding.logical_id == requested.logical_id;
        if (!found) return recovery.RecoveryError.MissingRecipe;
        self.accumulated_gpu_ms += try self.metal.circleIfftPrepared(self.arena.buffer, self.prepared);
        self.last_tick = tick;
    }
};

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
        for (bindings, plans, destinations) |binding, *plan, *destination| {
            if (binding.row_count == 0 or binding.descriptors.len == 0 or binding.descriptors.len % 4 != 0 or
                binding.multiplicities.len == 0 or binding.destination.offset_bytes % 4 != 0 or
                binding.destination.size_bytes != @as(u64, binding.row_count) * (binding.descriptors.len / 4) * 4)
                return recovery.RecoveryError.BindingSizeMismatch;
            const source_offsets = try allocator.alloc(u32, binding.sources.len);
            defer allocator.free(source_offsets);
            const multiplicity_offsets = try allocator.alloc(u32, binding.multiplicities.len);
            defer allocator.free(multiplicity_offsets);
            for (binding.sources, source_offsets) |source, *offset| {
                if (source.offset_bytes % 4 != 0 or source.size_bytes != @as(u64, binding.row_count) * 4)
                    return recovery.RecoveryError.BindingSizeMismatch;
                offset.* = std.math.cast(u32, source.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch;
            }
            for (binding.multiplicities, multiplicity_offsets) |multiplicity, *offset| {
                if (multiplicity.offset_bytes % 4 != 0 or multiplicity.size_bytes != @as(u64, binding.row_count) * 4)
                    return recovery.RecoveryError.BindingSizeMismatch;
                offset.* = std.math.cast(u32, multiplicity.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch;
            }
            plan.* = try metal.prepareFixedTable(
                binding.descriptors,
                source_offsets,
                multiplicity_offsets,
                std.math.cast(u32, binding.destination.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch,
                binding.row_count,
            );
            initialized += 1;
            destination.* = binding.destination;
        }
        var batch = try metal.prepareFixedTableBatch(plans);
        errdefer batch.deinit();
        return .{ .allocator = allocator, .metal = metal, .arena = resident_arena, .plans = plans, .batch = batch, .destinations = destinations };
    }

    pub fn deinit(self: *FixedTableBatchRecipe) void {
        self.batch.deinit();
        for (self.plans) |*plan| plan.deinit();
        self.allocator.free(self.plans);
        self.allocator.free(self.destinations);
        self.* = undefined;
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
    ) !EcOpRecipe {
        if (bindings.row_count < 16 or !std.math.isPowerOfTwo(bindings.row_count))
            return recovery.RecoveryError.BindingSizeMismatch;
        const column_bytes = @as(u64, bindings.row_count) * 4;
        const partial_bytes = column_bytes * 256;
        const asOffset = struct {
            fn get(binding: arena_plan.Binding) !u32 {
                if (binding.offset_bytes % 4 != 0) return recovery.RecoveryError.BindingSizeMismatch;
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
        );
        errdefer prepared.deinit();
        const destinations = try allocator.alloc(arena_plan.Binding, 273 + 1 + 127);
        @memcpy(destinations[0..273], &bindings.trace_columns);
        destinations[273] = bindings.lookup;
        @memcpy(destinations[274..], &bindings.partial_columns);
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

/// Canonical device multiset writer. All radix, scan, and tuple workspaces are
/// sparse arena bindings whose live range is the consumer's witness tick.
pub const CompactRecipe = struct {
    allocator: std.mem.Allocator,
    metal: *runtime.Runtime,
    arena: *arena_plan.ResidentArena,
    destinations: []arena_plan.Binding,
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
        return .{
            .allocator = allocator,
            .metal = metal,
            .arena = resident_arena,
            .destinations = try allocator.dupe(arena_plan.Binding, bindings.outputs),
            .prepared = prepared,
        };
    }

    pub fn deinit(self: *CompactRecipe) void {
        self.prepared.deinit();
        self.allocator.free(self.destinations);
        self.* = undefined;
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
        self.accumulated_gpu_ms += try self.metal.compositionFrontPrepared(self.arena.buffer, self.front);
        self.accumulated_gpu_ms += try self.metal.compositionFinalizePrepared(self.arena.buffer, self.finalize);
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
            for (primary[0..primary_columns]) |binding| if (binding.size_bytes < @as(u64, e[8]) * 4)
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
    last_tick: ?u16 = null,
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
        };
    }

    pub fn deinit(self: *WitnessFeedBatchRecipe) void {
        self.prepared.deinit();
        self.allocator.free(self.destinations);
        self.* = undefined;
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
        for (instances) |instance| {
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
                try source_offsets.append(allocator, std.math.cast(u32, binding.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch);
            }
            const descriptor_base = descriptors.items.len;
            try descriptors.appendSlice(allocator, instance.descriptors);
            const output_base = output_offsets.items.len;
            for (instance.outputs) |binding| {
                if (binding.offset_bytes % 4 != 0 or binding.size_bytes != @as(u64, instance.rows) * 4)
                    return recovery.RecoveryError.BindingSizeMismatch;
                try output_offsets.append(allocator, std.math.cast(u32, binding.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch);
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
                std.math.cast(u32, instance.claimed_sum.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch,
            });
            total_blocks = std.math.add(u32, total_blocks, blocks) catch return recovery.RecoveryError.BindingSizeMismatch;
        }
        if (scan_scratch.size_bytes < @as(u64, total_blocks) * 16)
            return recovery.RecoveryError.BindingSizeMismatch;
        if (alpha_powers.size_bytes < @as(u64, max_alpha_powers) * 16)
            return recovery.RecoveryError.BindingSizeMismatch;
        var prepared = try metal.prepareRelation(
            geometry.items,
            source_offsets.items,
            descriptors.items,
            output_offsets.items,
            total_blocks,
            std.math.cast(u32, alpha_powers.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch,
            std.math.cast(u32, z.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch,
            std.math.cast(u32, scan_scratch.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch,
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
    metal: *runtime.Runtime,
    arena: *arena_plan.ResidentArena,
    destination: arena_plan.Binding,
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
        const quotient_offset = std.math.cast(u32, quotient_values.offset_bytes / 4) orelse
            return recovery.RecoveryError.BindingSizeMismatch;
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
        var subdomain_offsets: [4]u32 = undefined;
        var quotient_offsets: [4]u32 = undefined;
        for (0..4) |coordinate| {
            subdomain_offsets[coordinate] = subdomain_offset + @as(u32, @intCast(coordinate)) * @as(u32, @intCast(subdomain_rows));
            quotient_offsets[coordinate] = quotient_offset + @as(u32, @intCast(coordinate)) * @as(u32, @intCast(quotient_rows));
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
        var evaluate = try metal.prepareCircleLde(
            &subdomain_offsets,
            &quotient_offsets,
            subdomain_log,
            quotient_log,
            std.math.cast(u32, forward_twiddles.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch,
        );
        errdefer evaluate.deinit();
        return .{
            .metal = metal,
            .arena = resident_arena,
            .destination = quotient_values,
            .combine = combine,
            .interpolate = interpolate,
            .evaluate = evaluate,
        };
    }

    pub fn deinit(self: *QuotientRecipe) void {
        self.evaluate.deinit();
        self.interpolate.deinit();
        self.combine.deinit();
        self.* = undefined;
    }

    pub fn recipe(self: *QuotientRecipe) recovery.Recipe {
        return .{ .logical_id = self.destination.logical_id, .context = self, .run = run };
    }

    fn run(raw: *anyopaque, tick: u16, requested: arena_plan.Binding, _: []u8) !void {
        const self: *QuotientRecipe = @ptrCast(@alignCast(raw));
        if (requested.logical_id != self.destination.logical_id) return recovery.RecoveryError.MissingRecipe;
        if (self.last_tick == tick) return;
        self.accumulated_gpu_ms += try self.metal.quotientCombinePrepared(self.arena.buffer, self.combine);
        self.accumulated_gpu_ms += try self.metal.circleIfftPrepared(self.arena.buffer, self.interpolate);
        self.accumulated_gpu_ms += try self.metal.circleLdePrepared(self.arena.buffer, self.evaluate);
        self.last_tick = tick;
    }
};

/// Exact STWO FRI bottom with planar secure evaluations, four rows per leaf,
/// and the canonical 3,3,3,3,3,3,3,2 fold schedule. Transcript control calls
/// `commitTree` and `foldRound` alternately so each device root can be mixed
/// before its resident challenge is consumed.
pub const FriRecipe = struct {
    metal: *runtime.Runtime,
    arena: *arena_plan.ResidentArena,
    rounds: [8]runtime.FriRoundPlan,
    trees: [8]runtime.FriTreePlan,
    final: runtime.FriFinalPlan,
    roots: [8]arena_plan.Binding,
    initialized_rounds: usize,
    initialized_trees: usize,
    initialized_final: bool,
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
        if (retained.len != 7 or challenges.len != 8 or merkle_layers_root_first.len != 100 or
            inverse_twiddles.offset_bytes % 4 != 0 or inverse_twiddles.size_bytes != (@as(u64, 1) << 23) * 4)
            return recovery.RecoveryError.BindingSizeMismatch;
        var self = FriRecipe{
            .metal = metal,
            .arena = resident_arena,
            .rounds = undefined,
            .trees = undefined,
            .final = undefined,
            .roots = undefined,
            .initialized_rounds = 0,
            .initialized_trees = 0,
            .initialized_final = false,
        };
        errdefer self.deinitInitialized();

        var evaluations: [8]arena_plan.Binding = undefined;
        evaluations[0] = quotient;
        @memcpy(evaluations[1..], retained);
        const evaluation_logs = [_]u32{ 24, 21, 18, 15, 12, 9, 6, 3 };
        const layer_counts = [_]usize{ 23, 20, 17, 14, 11, 8, 5, 2 };
        var layer_cursor: usize = 0;
        for (evaluations, evaluation_logs, layer_counts, 0..) |evaluation, log_size, layer_count, tree| {
            const rows = @as(u64, 1) << @intCast(log_size);
            if (evaluation.offset_bytes % 4 != 0 or evaluation.size_bytes != rows * 16)
                return recovery.RecoveryError.BindingSizeMismatch;
            var layer_offsets: [23]u32 = undefined;
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
        for (0..8) |round| {
            const source = evaluations[round];
            const source_rows = @as(u32, 1) << @intCast(evaluation_logs[round]);
            const fold_count: u32 = if (round == 7) 2 else 3;
            const output = if (round == 7) final_evaluation else evaluations[round + 1];
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
        if (tree >= self.trees.len) return recovery.RecoveryError.BindingSizeMismatch;
        self.accumulated_gpu_ms += try self.metal.friTreePrepared(self.arena.buffer, self.trees[tree]);
        return self.roots[tree];
    }

    pub fn foldRound(self: *FriRecipe, round: usize) !void {
        if (round >= self.rounds.len) return recovery.RecoveryError.BindingSizeMismatch;
        self.accumulated_gpu_ms += try self.metal.friRoundPrepared(self.arena.buffer, self.rounds[round]);
    }

    pub fn finalize(self: *FriRecipe) !void {
        self.accumulated_gpu_ms += try self.metal.friFinalPrepared(self.arena.buffer, self.final);
    }
};

pub const TranscriptBinding = struct {
    ordinal: u32,
    binding: arena_plan.Binding,
};

fn bindingWordOffset(binding: arena_plan.Binding) !u32 {
    if (binding.offset_bytes % 4 != 0) return recovery.RecoveryError.BindingSizeMismatch;
    return std.math.cast(u32, binding.offset_bytes / 4) orelse recovery.RecoveryError.BindingSizeMismatch;
}

/// Query-normalization and FRI coset preparation for the canonical Cairo
/// opening schedule. All eight FRI trees reuse the same epoch-local workspaces;
/// only their cumulative fold differs.
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
        };
    }

    pub fn normalize(self: *DecommitQueryRecipe) !void {
        const count_base = try bindingWordOffset(self.counts);
        self.accumulated_gpu_ms += try self.metal.decommitNormalizeQueries(
            self.arena.buffer,
            try bindingWordOffset(self.raw_queries),
            70,
            24,
            try bindingWordOffset(self.unique_queries),
            count_base,
            self.tree_count,
            try bindingWordOffset(self.assembly),
            @intCast(self.assembly.size_bytes / 4),
        );
    }

    pub fn prepareFri(self: *DecommitQueryRecipe, round: usize) !void {
        if (round >= 8) return recovery.RecoveryError.BindingSizeMismatch;
        const cumulative_folds = [_]u32{ 0, 3, 6, 9, 12, 15, 18, 21 };
        const fold_steps = [_]u32{ 3, 3, 3, 3, 3, 3, 3, 2 };
        const count_base = try bindingWordOffset(self.counts);
        self.accumulated_gpu_ms += try self.metal.decommitPrepareFriQueries(
            self.arena.buffer,
            try bindingWordOffset(self.unique_queries),
            count_base,
            70,
            cumulative_folds[round],
            fold_steps[round],
            2,
            try bindingWordOffset(self.mapped_queries),
            count_base + 1,
            try bindingWordOffset(self.expanded_positions),
            count_base + 3,
            try bindingWordOffset(self.walk_queries),
            count_base + 2,
        );
    }

    pub fn prepareTrace(
        self: *DecommitQueryRecipe,
        source_log: u32,
        tree_log: u32,
        leaf_log: u32,
        unretained: u32,
    ) !void {
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
        if (column_offsets.size_bytes < @as(u64, column_count) * 4 or
            column_logs.size_bytes < @as(u64, column_count) * 4 or
            values.size_bytes < (@as(u64, first_column) + column_count) * stride * 4)
            return recovery.RecoveryError.BindingSizeMismatch;
        const count_base = try bindingWordOffset(self.counts);
        self.accumulated_gpu_ms += try self.metal.decommitGatherTraceValues(
            self.arena.buffer,
            try bindingWordOffset(column_offsets),
            try bindingWordOffset(column_logs),
            column_count,
            lifting_log,
            try bindingWordOffset(self.mapped_queries),
            count_base + 1,
            70,
            first_column,
            stride,
            try bindingWordOffset(values),
        );
    }

    pub fn sparseParent(
        self: *DecommitQueryRecipe,
        distance: u32,
        child_offset: u32,
        child_capacity: u32,
        parent_offset: u32,
        node_seed: [8]u32,
    ) !void {
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
pub const TranscriptRecipe = struct {
    allocator: std.mem.Allocator,
    metal: *runtime.Runtime,
    arena: *arena_plan.ResidentArena,
    state: arena_plan.Binding,
    inputs: []TranscriptBinding,
    outputs: []TranscriptBinding,
    accumulated_gpu_ms: f64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        metal: *runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        state: arena_plan.Binding,
        inputs: []const TranscriptBinding,
        outputs: []const TranscriptBinding,
    ) !TranscriptRecipe {
        if (state.offset_bytes % 4 != 0 or state.size_bytes < 40 or inputs.len == 0 or outputs.len == 0)
            return recovery.RecoveryError.BindingSizeMismatch;
        return .{
            .allocator = allocator,
            .metal = metal,
            .arena = resident_arena,
            .state = state,
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

    pub fn bootstrapThroughBase(self: *TranscriptRecipe) !void {
        for ([_]u32{ 1, 2, 3, 10, 11, 12, 13, 14, 15, 16, 20 }) |input| try self.mixInput(input);
    }

    pub fn interactionPowAndLookup(self: *TranscriptRecipe) !u64 {
        const nonce = try self.grindAndMix(21, 24);
        try self.drawSecure(1, 2);
        return nonce;
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
        const nonce = try self.grindAndMix(31, 26);
        const queries = try self.find(self.outputs, 5);
        self.accumulated_gpu_ms += try self.metal.transcriptDrawQueries(
            self.arena.buffer,
            try wordOffset(self.state),
            try wordOffset(queries),
            24,
            70,
        );
        return nonce;
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

    fn grindAndMix(self: *TranscriptRecipe, input_ordinal: u32, pow_bits: u32) !u64 {
        const state_bytes = try self.arena.bytes(self.state);
        const state_words = std.mem.bytesAsSlice(u32, @as([]align(4) u8, @alignCast(state_bytes)));
        var channel = blake2s_channel.Blake2sChannel{};
        @memcpy(&channel.digest, std.mem.sliceAsBytes(state_words[0..8]));
        channel.n_draws = state_words[8];
        const nonce = channel.grind(pow_bits);
        const destination = try self.find(self.inputs, input_ordinal);
        const destination_bytes = try self.arena.bytes(destination);
        if (destination_bytes.len < 8) return recovery.RecoveryError.BindingSizeMismatch;
        std.mem.writeInt(u64, destination_bytes[0..8], nonce, .little);
        try self.mixInput(input_ordinal);
        return nonce;
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
                .source_word_offset = std.math.cast(u32, copy.source.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch,
                .destination_word_offset = std.math.add(
                    u32,
                    std.math.cast(u32, destination.offset_bytes / 4) orelse return recovery.RecoveryError.BindingSizeMismatch,
                    copy.destination_word_offset,
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

    pub fn words(self: *ProofAssemblyRecipe) ![]const u32 {
        const bytes = try self.arena.bytes(self.destination);
        const aligned: []align(@alignOf(u32)) u8 = @alignCast(bytes);
        return std.mem.bytesAsSlice(u32, aligned);
    }

    fn run(raw: *anyopaque, tick: u16, requested: arena_plan.Binding, _: []u8) !void {
        const self: *ProofAssemblyRecipe = @ptrCast(@alignCast(raw));
        if (requested.logical_id != self.destination.logical_id) return recovery.RecoveryError.MissingRecipe;
        if (self.last_tick == tick) return;
        self.accumulated_gpu_ms += try self.metal.arenaCopyPrepared(self.arena.buffer, self.prepared);
        self.last_tick = tick;
    }
};

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
