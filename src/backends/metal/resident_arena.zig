//! Metal storage and word-address ABI for a backend-neutral arena plan.

const std = @import("std");
const arena_plan = @import("../../backend/arena_plan.zig");
const runtime = @import("runtime.zig");

pub const narrow_word_address_space_bytes: u64 =
    (@as(u64, std.math.maxInt(u32)) + 1) * @sizeOf(u32);

pub fn validateNarrowWordBinding(binding: arena_plan.Binding) arena_plan.Error!void {
    if (binding.offset_bytes % @sizeOf(u32) != 0 or
        binding.size_bytes % @sizeOf(u32) != 0)
    {
        return arena_plan.Error.InvalidAlignment;
    }
    const end = std.math.add(u64, binding.offset_bytes, binding.size_bytes) catch
        return arena_plan.Error.SizeOverflow;
    if (end > narrow_word_address_space_bytes) {
        return arena_plan.Error.NarrowAddressOverflow;
    }
}

pub fn narrowWordOffset(binding: arena_plan.Binding) arena_plan.Error!u32 {
    try validateNarrowWordBinding(binding);
    return @intCast(binding.offset_bytes / @sizeOf(u32));
}

pub const ResidentArena = struct {
    buffer: runtime.ResidentBuffer,

    pub fn init(metal: *runtime.Runtime, plan: arena_plan.Plan) runtime.MetalError!ResidentArena {
        return .{ .buffer = try metal.allocateResidentBuffer(@intCast(plan.total_bytes)) };
    }

    pub fn initWithExtra(
        metal: *runtime.Runtime,
        plan: arena_plan.Plan,
        extra_bytes: u64,
    ) runtime.MetalError!ResidentArena {
        const byte_length = std.math.add(u64, plan.total_bytes, extra_bytes) catch
            return runtime.MetalError.ColumnTooLarge;
        return .{ .buffer = try metal.allocateResidentBuffer(@intCast(byte_length)) };
    }

    pub fn initByteLength(
        metal: *runtime.Runtime,
        byte_length: u64,
    ) runtime.MetalError!ResidentArena {
        if (byte_length == 0) return runtime.MetalError.ColumnTooLarge;
        return .{ .buffer = try metal.allocateResidentBuffer(@intCast(byte_length)) };
    }

    pub fn deinit(self: *ResidentArena) void {
        self.buffer.deinit();
        self.* = undefined;
    }

    pub fn bytes(
        self: *ResidentArena,
        binding: arena_plan.Binding,
    ) arena_plan.Error![]align(1) u8 {
        const end = std.math.add(u64, binding.offset_bytes, binding.size_bytes) catch
            return arena_plan.Error.BindingOutOfBounds;
        if (end > self.buffer.byte_length) return arena_plan.Error.BindingOutOfBounds;
        const base: [*]u8 = @ptrCast(self.buffer.contents);
        return base[@intCast(binding.offset_bytes)..@intCast(end)];
    }
};

test "metal arena: narrow word bindings validate their complete extent" {
    const last_word = arena_plan.Binding{
        .logical_id = 0,
        .slot = 0,
        .offset_bytes = narrow_word_address_space_bytes - @sizeOf(u32),
        .size_bytes = @sizeOf(u32),
        .materialization = .resident,
        .occupied = [_]u64{0} ** (arena_plan.max_ticks / 64),
    };
    try validateNarrowWordBinding(last_word);
    try std.testing.expectEqual(std.math.maxInt(u32), try narrowWordOffset(last_word));

    var crossing = last_word;
    crossing.size_bytes = 2 * @sizeOf(u32);
    try std.testing.expectError(
        arena_plan.Error.NarrowAddressOverflow,
        validateNarrowWordBinding(crossing),
    );

    var misaligned = last_word;
    misaligned.offset_bytes += 1;
    try std.testing.expectError(
        arena_plan.Error.InvalidAlignment,
        validateNarrowWordBinding(misaligned),
    );
}
