//! Compiled AIR registry and deferred adapter status.

const builtin = @import("builtin");

pub fn write(writer: anytype) !void {
    try writer.writeAll(
        \\{"schema_version":1,"backend_availability":{"cpu":true,"metal-hybrid":
    );
    try writer.writeAll(if (builtin.os.tag == .macos) "true" else "false");
    try writer.writeAll(
        \\},"applications":[
        \\  {"air":"wide_fibonacci","status":"release_gated","backends":["cpu","metal-hybrid"]},
        \\  {"air":"xor","status":"release_gated","backends":["cpu","metal-hybrid"]},
        \\  {"air":"plonk","status":"release_gated","backends":["cpu","metal-hybrid"]},
        \\  {"air":"state_machine","status":"release_gated","backends":["cpu","metal-hybrid"]},
        \\  {"air":"blake","status":"release_gated","backends":["cpu","metal-hybrid"]},
        \\  {"air":"poseidon","status":"release_gated","backends":["cpu","metal-hybrid"]}
        \\],"deferred_adapters":[
        \\  {"adapter":"stark-v-rv32im-elf","status":"not_release_gated","reason":"RV32IM opcode, memory, and public I/O AIR constraints are incomplete"}
        \\]}
    );
}

test "registry is valid JSON and separates deferred adapters" {
    const std = @import("std");
    var storage: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&storage);
    try write(stream.writer());
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        stream.getWritten(),
        .{},
    );
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqual(@as(usize, 6), root.get("applications").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), root.get("deferred_adapters").?.array.items.len);
}
