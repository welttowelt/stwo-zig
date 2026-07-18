//! Compatibility export for the canonical Stark-V opcode manifest.

const manifest = @import("../../opcode_manifest.zig");

pub const Opcode = manifest.Opcode;

test "program opcode: pinned ids are contiguous and stable" {
    const std = @import("std");
    try manifest.validate();
    const fields = @typeInfo(Opcode).@"enum".fields;
    try std.testing.expectEqual(@as(usize, 45), fields.len);
    inline for (fields, 0..) |field, expected| {
        try std.testing.expectEqual(@as(u32, @intCast(expected)), @as(u32, @intCast(field.value)));
    }
    try std.testing.expectEqual(@as(u32, 10), Opcode.addi.protocolId());
    try std.testing.expectEqual(@as(u32, 44), Opcode.remu.protocolId());
}
