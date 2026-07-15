const std = @import("std");
const adapted_input = @import("frontends/cairo/adapter/adapted_input.zig");
const OpcodeTag = @import("frontends/cairo/adapter/opcodes.zig").OpcodeTag;

pub fn main() !void {
    const allocator = std.heap.smp_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 2) {
        std.debug.print("usage: cairo-input <adapted-input.stwzcpi>\n", .{});
        return error.InvalidArgument;
    }
    var input = try adapted_input.readFile(allocator, args[1]);
    defer input.deinit(allocator);

    const cycles = input.state_transitions.casm_states_by_opcode.totalCount();
    std.debug.print("Cairo adapted prover input\n", .{});
    std.debug.print("cycles: {d}\n", .{cycles});
    std.debug.print("pc_count: {d}\n", .{input.pc_count});
    std.debug.print("memory_address_to_id: {d}\n", .{input.memory.address_to_id.len});
    std.debug.print("memory_id_to_big: {d}\n", .{input.memory.f252_values.len});
    std.debug.print("memory_id_to_small: {d}\n", .{input.memory.small_values.len});
    std.debug.print("public_memory_addresses: {d}\n", .{input.public_memory_addresses.len});
    inline for (@typeInfo(OpcodeTag).@"enum".fields) |field| {
        const tag: OpcodeTag = @enumFromInt(field.value);
        const count = input.state_transitions.casm_states_by_opcode.getConst(tag).len;
        if (count != 0) std.debug.print("opcode {s}: {d}\n", .{ field.name, count });
    }
}
