//! Caller-owned Metal command submission across prepared resident operations.

const std = @import("std");

extern fn stwo_zig_metal_command_epoch_create(
    runtime: *anyopaque,
    arena: *anyopaque,
    error_message: [*]u8,
    error_message_len: usize,
) ?*anyopaque;
extern fn stwo_zig_metal_command_epoch_destroy(epoch: ?*anyopaque) void;
extern fn stwo_zig_metal_command_epoch_encode_circle_ifft(
    epoch: *anyopaque,
    plan: *anyopaque,
    error_message: [*]u8,
    error_message_len: usize,
) bool;
extern fn stwo_zig_metal_command_epoch_encode_circle_lde(
    epoch: *anyopaque,
    plan: *anyopaque,
    error_message: [*]u8,
    error_message_len: usize,
) bool;
extern fn stwo_zig_metal_command_epoch_encode_resident_merkle(
    epoch: *anyopaque,
    plan: *anyopaque,
    error_message: [*]u8,
    error_message_len: usize,
) bool;
extern fn stwo_zig_metal_command_epoch_encode_composition_lde(
    epoch: *anyopaque,
    plan: *anyopaque,
    error_message: [*]u8,
    error_message_len: usize,
) bool;
extern fn stwo_zig_metal_command_epoch_encode_arena_copy(
    epoch: *anyopaque,
    plan: *anyopaque,
    error_message: [*]u8,
    error_message_len: usize,
) bool;
extern fn stwo_zig_metal_command_epoch_encode_compact_leaf(
    epoch: *anyopaque,
    column_offsets: [*]const u32,
    column_logs: [*]const u32,
    column_count: u32,
    source_state_offset: u32,
    source_state_log: u32,
    destination_state_offset: u32,
    destination_log: u32,
    first_column: u32,
    is_final: u32,
    prefix_bytes: u32,
    leaf_seed: *const [8]u32,
    error_message: [*]u8,
    error_message_len: usize,
) bool;
extern fn stwo_zig_metal_command_epoch_encode_merkle_parent_chain(
    epoch: *anyopaque,
    plan: *anyopaque,
    error_message: [*]u8,
    error_message_len: usize,
) bool;
extern fn stwo_zig_metal_command_epoch_submit(
    epoch: *anyopaque,
    error_message: [*]u8,
    error_message_len: usize,
) bool;
extern fn stwo_zig_metal_command_epoch_wait(
    epoch: *anyopaque,
    stats: *Stats,
    error_message: [*]u8,
    error_message_len: usize,
) bool;

pub const Error = error{CommandEpochFailed};

pub const Stats = extern struct {
    command_buffers: u64,
    wait_count: u64,
    intermediate_wait_count: u64,
    compute_encoders: u64,
    blit_encoders: u64,
    dispatches: u64,
    gpu_milliseconds: f64,
};

comptime {
    if (@sizeOf(Stats) != 6 * @sizeOf(u64) + @sizeOf(f64))
        @compileError("Metal command epoch stats ABI drift");
}

/// The Objective-C owner retains the runtime, arena, command buffer, and every
/// encoded plan until completion. Treat this value as move-only.
pub const CommandEpoch = struct {
    handle: *anyopaque,
    arena_byte_length: usize,
    state: State = .encoding,
    encoded_operations: u32 = 0,

    pub const State = enum {
        encoding,
        submitted,
        completed,
        failed,
    };

    pub fn init(runtime: *anyopaque, arena: *anyopaque, arena_byte_length: usize) Error!CommandEpoch {
        var message: [1024]u8 = [_]u8{0} ** 1024;
        const handle = stwo_zig_metal_command_epoch_create(
            runtime,
            arena,
            &message,
            message.len,
        ) orelse {
            std.log.err("Metal command epoch creation failed: {s}", .{std.mem.sliceTo(&message, 0)});
            return Error.CommandEpochFailed;
        };
        return .{ .handle = handle, .arena_byte_length = arena_byte_length };
    }

    pub fn deinit(self: *CommandEpoch) void {
        stwo_zig_metal_command_epoch_destroy(self.handle);
        self.* = undefined;
    }

    pub fn encodeCircleIfft(self: *CommandEpoch, plan: anytype) Error!void {
        try self.requireEncoding();
        var message: [1024]u8 = [_]u8{0} ** 1024;
        if (!stwo_zig_metal_command_epoch_encode_circle_ifft(
            self.handle,
            plan.handle,
            &message,
            message.len,
        )) return self.failEncoding("IFFT", &message);
        self.encoded_operations += 1;
    }

    pub fn encodeCircleLde(self: *CommandEpoch, plan: anytype) Error!void {
        try self.requireEncoding();
        var message: [1024]u8 = [_]u8{0} ** 1024;
        if (!stwo_zig_metal_command_epoch_encode_circle_lde(
            self.handle,
            plan.handle,
            &message,
            message.len,
        )) return self.failEncoding("LDE", &message);
        self.encoded_operations += 1;
    }

    pub fn encodeResidentMerkle(self: *CommandEpoch, plan: anytype) Error!void {
        try self.requireEncoding();
        var message: [1024]u8 = [_]u8{0} ** 1024;
        if (!stwo_zig_metal_command_epoch_encode_resident_merkle(
            self.handle,
            plan.handle,
            &message,
            message.len,
        )) return self.failEncoding("Merkle", &message);
        self.encoded_operations += 1;
    }

    pub fn encodeCompositionLde(self: *CommandEpoch, plan: anytype) Error!void {
        try self.encodePlan(stwo_zig_metal_command_epoch_encode_composition_lde, plan, "composition LDE");
    }

    pub fn encodeArenaCopy(self: *CommandEpoch, plan: anytype) Error!void {
        try self.encodePlan(stwo_zig_metal_command_epoch_encode_arena_copy, plan, "arena copy");
    }

    pub fn encodeCompactLeaf(
        self: *CommandEpoch,
        column_offsets: []const u32,
        column_logs: []const u32,
        source_state_offset: u32,
        source_state_log: u32,
        destination_state_offset: u32,
        destination_log: u32,
        first_column: u32,
        is_final: bool,
        prefix_bytes: u32,
        leaf_seed: [8]u32,
    ) Error!void {
        try self.requireEncoding();
        if (column_offsets.len == 0 or column_offsets.len > 16 or column_offsets.len != column_logs.len or
            (first_column != 0 and source_state_log > destination_log) or
            (prefix_bytes != 0 and prefix_bytes != 64))
            return self.failWithoutLog();
        var message: [1024]u8 = [_]u8{0} ** 1024;
        if (!stwo_zig_metal_command_epoch_encode_compact_leaf(
            self.handle,
            column_offsets.ptr,
            column_logs.ptr,
            @intCast(column_offsets.len),
            source_state_offset,
            source_state_log,
            destination_state_offset,
            destination_log,
            first_column,
            @intFromBool(is_final),
            prefix_bytes,
            &leaf_seed,
            &message,
            message.len,
        )) return self.failEncoding("compact leaf", &message);
        self.encoded_operations += 1;
    }

    pub fn encodeMerkleParentChain(self: *CommandEpoch, plan: anytype) Error!void {
        if (plan.required_arena_bytes > self.arena_byte_length) return self.failWithoutLog();
        try self.encodePlan(stwo_zig_metal_command_epoch_encode_merkle_parent_chain, plan, "Merkle parent chain");
    }

    pub fn submit(self: *CommandEpoch) Error!void {
        if (self.state != .encoding) return Error.CommandEpochFailed;
        if (self.encoded_operations == 0) {
            self.state = .failed;
            return Error.CommandEpochFailed;
        }
        var message: [1024]u8 = [_]u8{0} ** 1024;
        if (!stwo_zig_metal_command_epoch_submit(self.handle, &message, message.len)) {
            self.state = .failed;
            std.log.err("Metal command epoch submission failed: {s}", .{std.mem.sliceTo(&message, 0)});
            return Error.CommandEpochFailed;
        }
        self.state = .submitted;
    }

    pub fn wait(self: *CommandEpoch) Error!Stats {
        if (self.state != .submitted) return Error.CommandEpochFailed;
        var stats: Stats = undefined;
        var message: [1024]u8 = [_]u8{0} ** 1024;
        if (!stwo_zig_metal_command_epoch_wait(self.handle, &stats, &message, message.len)) {
            self.state = .failed;
            std.log.err("Metal command epoch wait failed: {s}", .{std.mem.sliceTo(&message, 0)});
            return Error.CommandEpochFailed;
        }
        self.state = .completed;
        return stats;
    }

    fn requireEncoding(self: CommandEpoch) Error!void {
        if (self.state != .encoding) return Error.CommandEpochFailed;
    }

    fn encodePlan(
        self: *CommandEpoch,
        comptime encode: fn (*anyopaque, *anyopaque, [*]u8, usize) callconv(.c) bool,
        plan: anytype,
        operation: []const u8,
    ) Error!void {
        try self.requireEncoding();
        var message: [1024]u8 = [_]u8{0} ** 1024;
        if (!encode(self.handle, plan.handle, &message, message.len))
            return self.failEncoding(operation, &message);
        self.encoded_operations += 1;
    }

    fn failWithoutLog(self: *CommandEpoch) Error {
        self.state = .failed;
        return Error.CommandEpochFailed;
    }

    fn failEncoding(self: *CommandEpoch, operation: []const u8, message: []const u8) Error {
        self.state = .failed;
        std.log.err("Metal command epoch {s} encoding failed: {s}", .{
            operation,
            std.mem.sliceTo(message, 0),
        });
        return Error.CommandEpochFailed;
    }
};

test "command epoch telemetry ABI is stable" {
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(Stats));
}
