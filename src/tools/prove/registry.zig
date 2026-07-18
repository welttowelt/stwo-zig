//! Compiled AIR registry and deferred adapter status.

const builtin = @import("builtin");

/// The single typed admission switch for the Stark-V adapter. RF-01 flips this
/// in the same commit as the artifact release status after every gate passes.
pub const RISCV_ADAPTER_RELEASE_GATED = false;

pub fn requireRiscVAdmission(experimental: bool) !void {
    if (RISCV_ADAPTER_RELEASE_GATED) {
        if (experimental) return error.ExperimentalFlagAfterPromotion;
    } else if (!experimental) {
        return error.ExperimentalFlagRequired;
    }
}

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
    );
    if (RISCV_ADAPTER_RELEASE_GATED) try writer.writeAll(
        \\,{"adapter":"stark-v-rv32im-elf","air":"stark_v_rv32im","status":"release_gated","isa":"rv32im","backends":["cpu"]}
    );
    try writer.writeAll(
        \\],"deferred_adapters":[
    );
    if (!RISCV_ADAPTER_RELEASE_GATED) try writer.writeAll(
        \\  {"adapter":"stark-v-rv32im-elf","status":"not_release_gated","isa":"rv32im","backends":["cpu"],"reason":"RISC-V release contract is not yet fully satisfied"}
    );
    try writer.writeAll(
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
    try std.testing.expectEqual(
        @as(usize, 6) + @as(usize, @intFromBool(RISCV_ADAPTER_RELEASE_GATED)),
        root.get("applications").?.array.items.len,
    );
    try std.testing.expectEqual(
        @as(usize, 1) - @as(usize, @intFromBool(RISCV_ADAPTER_RELEASE_GATED)),
        root.get("deferred_adapters").?.array.items.len,
    );
}

test "staged RISC-V admission is explicit and fail closed" {
    const std = @import("std");
    if (RISCV_ADAPTER_RELEASE_GATED) {
        try requireRiscVAdmission(false);
        try std.testing.expectError(error.ExperimentalFlagAfterPromotion, requireRiscVAdmission(true));
    } else {
        try requireRiscVAdmission(true);
        try std.testing.expectError(error.ExperimentalFlagRequired, requireRiscVAdmission(false));
    }
}
