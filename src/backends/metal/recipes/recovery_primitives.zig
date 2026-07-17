const std = @import("std");

const arena_plan = @import("../arena_plan.zig");
const recovery = @import("../recovery.zig");

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

pub const ZeroRecipe = struct {
    pub fn recipe(logical_id: u32) recovery.Recipe {
        return .{ .logical_id = logical_id, .context = undefined, .run = run };
    }

    fn run(_: *anyopaque, _: u16, _: arena_plan.Binding, destination: []u8) !void {
        @memset(destination, 0);
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
