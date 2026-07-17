//! Resident assembly of the final proof-visible word buffer.

const std = @import("std");
const arena_plan = @import("../arena_plan.zig");
const recovery = @import("../recovery.zig");
const runtime = @import("../runtime.zig");

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
