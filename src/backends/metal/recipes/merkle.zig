const std = @import("std");

const cairo_merkle = @import("../../../core/vcs_lifted/blake2_merkle.zig").Blake2sPlainMerkleHasher;
const arena_plan = @import("../arena_plan.zig");
const recovery = @import("../recovery.zig");
const runtime = @import("../runtime.zig");

const domain_prefix_bytes = cairo_merkle.domainPrefixBytes();

pub const ParentChainRecipe = struct {
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
    ) !ParentChainRecipe {
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
        var prepared = try metal.prepareMerkleParentChain(
            child_offsets,
            destination_offsets,
            parent_counts,
            node_seed,
            domain_prefix_bytes,
        );
        errdefer prepared.deinit();
        return .{
            .allocator = allocator,
            .metal = metal,
            .arena = resident_arena,
            .destinations = try allocator.dupe(arena_plan.Binding, layers_bottom_up[1..]),
            .prepared = prepared,
        };
    }

    pub fn deinit(self: *ParentChainRecipe) void {
        self.prepared.deinit();
        self.allocator.free(self.destinations);
        self.* = undefined;
    }

    pub fn makeRecipes(self: *ParentChainRecipe, allocator: std.mem.Allocator) ![]recovery.Recipe {
        const recipes = try allocator.alloc(recovery.Recipe, self.destinations.len);
        for (self.destinations, recipes) |destination, *recipe_entry| {
            recipe_entry.* = .{ .logical_id = destination.logical_id, .context = self, .run = run };
        }
        return recipes;
    }

    fn run(raw: *anyopaque, tick: u16, requested: arena_plan.Binding, _: []u8) !void {
        const self: *ParentChainRecipe = @ptrCast(@alignCast(raw));
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
pub const CommitRecipe = struct {
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
    ) !CommitRecipe {
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
            domain_prefix_bytes,
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

    pub fn deinit(self: *CommitRecipe) void {
        self.prepared.deinit();
        self.allocator.free(self.destinations);
        self.* = undefined;
    }

    pub fn makeRecipes(self: *CommitRecipe, allocator: std.mem.Allocator) ![]recovery.Recipe {
        const recipes = try allocator.alloc(recovery.Recipe, self.destinations.len);
        for (self.destinations, recipes) |destination, *recipe_entry|
            recipe_entry.* = .{ .logical_id = destination.logical_id, .context = self, .run = run };
        return recipes;
    }

    fn run(raw: *anyopaque, tick: u16, requested: arena_plan.Binding, _: []u8) !void {
        const self: *CommitRecipe = @ptrCast(@alignCast(raw));
        if (self.last_tick == tick) return;
        var found = false;
        for (self.destinations) |destination| found = found or destination.logical_id == requested.logical_id;
        if (!found) return recovery.RecoveryError.MissingRecipe;
        self.accumulated_gpu_ms += try self.metal.residentMerklePrepared(self.arena.buffer, self.prepared);
        self.last_tick = tick;
    }
};
