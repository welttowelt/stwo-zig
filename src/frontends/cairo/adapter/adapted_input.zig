//! Versioned streaming import for canonical stwo-cairo adapted prover input.

const std = @import("std");
const M31 = @import("../../../core/fields/m31.zig").M31;
const adapter = @import("mod.zig");
const opcodes = @import("opcodes.zig");
const memory_mod = @import("../common/memory.zig");
const CasmState = @import("../common/cpu.zig").CasmState;

pub const MAGIC = "STWZCPI\x00".*;
pub const VERSION: u32 = 1;
pub const MAX_ITEMS: usize = 1 << 30;

pub const Error = error{
    InvalidMagic,
    UnsupportedVersion,
    InvalidOpcodeCount,
    InvalidBoolean,
    LengthOverflow,
    Truncated,
    TrailingData,
};

const Stream = struct {
    reader: *std.Io.Reader,
    consumed: u64 = 0,

    fn readExact(self: *Stream, destination: []u8) !void {
        self.reader.readSliceAll(destination) catch return Error.Truncated;
        self.consumed += destination.len;
    }

    fn int(self: *Stream, comptime T: type) !T {
        var bytes: [@sizeOf(T)]u8 = undefined;
        try self.readExact(&bytes);
        return std.mem.readInt(T, &bytes, .little);
    }

    fn count(self: *Stream) !usize {
        const value = try self.int(u64);
        if (value > MAX_ITEMS or value > std.math.maxInt(usize)) return Error.LengthOverflow;
        return @intCast(value);
    }
};

fn readState(stream: *Stream) !CasmState {
    return .{
        .pc = M31.fromCanonical(try stream.int(u32)),
        .ap = M31.fromCanonical(try stream.int(u32)),
        .fp = M31.fromCanonical(try stream.int(u32)),
    };
}

fn readSegment(stream: *Stream) !?adapter.MemorySegmentAddresses {
    const present = try stream.int(u8);
    var padding: [7]u8 = undefined;
    try stream.readExact(&padding);
    const begin = try stream.int(u64);
    const stop = try stream.int(u64);
    if (present > 1) return Error.InvalidBoolean;
    if (begin > std.math.maxInt(usize) or stop > std.math.maxInt(usize)) return Error.LengthOverflow;
    if (present == 0) return null;
    return .{ .begin_addr = @intCast(begin), .stop_ptr = @intCast(stop) };
}

pub fn readFile(allocator: std.mem.Allocator, path: []const u8) !adapter.ProverInput {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const file_size = (try file.stat()).size;
    var reader_buffer: [1 << 20]u8 = undefined;
    var file_reader = file.readerStreaming(&reader_buffer);
    var stream = Stream{ .reader = &file_reader.interface };

    var magic: [MAGIC.len]u8 = undefined;
    try stream.readExact(&magic);
    if (!std.mem.eql(u8, &magic, &MAGIC)) return Error.InvalidMagic;
    if (try stream.int(u32) != VERSION) return Error.UnsupportedVersion;
    _ = try stream.int(u32); // flags

    const initial_state = try readState(&stream);
    const final_state = try readState(&stream);
    const pc_count = try stream.count();
    const public_mask = try stream.int(u16);
    _ = try stream.int(u16);
    _ = try stream.int(u32);
    if (try stream.int(u32) != opcodes.N_OPCODES) return Error.InvalidOpcodeCount;
    _ = try stream.int(u32);

    var grouped = opcodes.CasmStatesByOpcode.init(allocator);
    errdefer grouped.deinit(allocator);
    for (&grouped.states) |*states| {
        const len = try stream.count();
        try states.ensureTotalCapacity(allocator, len);
        for (0..len) |_| states.appendAssumeCapacity(try readState(&stream));
    }

    const small_max_low = try stream.int(u64);
    const small_max_high = try stream.int(u64);
    const log_small_value_capacity = try stream.int(u32);
    _ = try stream.int(u32);
    const address_count = try stream.count();
    const f252_count = try stream.count();
    const small_count = try stream.count();

    const address_to_id = try allocator.alloc(memory_mod.EncodedMemoryValueId, address_count);
    errdefer allocator.free(address_to_id);
    for (address_to_id) |*value| value.* = .{ .raw = try stream.int(u32) };
    const f252_values = try allocator.alloc(memory_mod.F252, f252_count);
    errdefer allocator.free(f252_values);
    for (f252_values) |*value| {
        for (value) |*word| word.* = try stream.int(u32);
    }
    const small_values = try allocator.alloc(u128, small_count);
    errdefer allocator.free(small_values);
    for (small_values) |*value| {
        const low = try stream.int(u64);
        const high = try stream.int(u64);
        value.* = @as(u128, high) << 64 | low;
    }

    const public_count = try stream.count();
    const public_memory_addresses = try allocator.alloc(u32, public_count);
    errdefer allocator.free(public_memory_addresses);
    for (public_memory_addresses) |*address| address.* = try stream.int(u32);

    const builtin_segments = adapter.BuiltinSegments{
        .add_mod_builtin = try readSegment(&stream),
        .bitwise_builtin = try readSegment(&stream),
        .output = try readSegment(&stream),
        .mul_mod_builtin = try readSegment(&stream),
        .pedersen_builtin = try readSegment(&stream),
        .poseidon_builtin = try readSegment(&stream),
        .range_check96_builtin = try readSegment(&stream),
        .range_check_builtin = try readSegment(&stream),
        .ec_op_builtin = try readSegment(&stream),
    };
    var public_segment_context: adapter.PublicSegmentContext = undefined;
    for (&public_segment_context, 0..) |*present, bit| present.* = (public_mask & (@as(u16, 1) << @intCast(bit))) != 0;

    if (stream.consumed != file_size) return Error.TrailingData;
    return .{
        .state_transitions = .{
            .initial_state = initial_state,
            .final_state = final_state,
            .casm_states_by_opcode = grouped,
        },
        .memory = .{
            .config = .{
                .small_max = @as(u128, small_max_high) << 64 | small_max_low,
                .log_small_value_capacity = log_small_value_capacity,
            },
            .address_to_id = address_to_id,
            .f252_values = f252_values,
            .small_values = small_values,
        },
        .pc_count = pc_count,
        .public_memory_addresses = public_memory_addresses,
        .builtin_segments = builtin_segments,
        .public_segment_context = public_segment_context,
    };
}
