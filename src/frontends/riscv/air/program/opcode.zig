//! Pinned Stark-V opcode protocol identifiers.
//!
//! These values are the declaration ordinals of `air::decode::Opcode` at
//! commit d478f783055aa0d73a93768a433a3c6c31c91d1c. They are proof-protocol
//! constants and must never be inferred from the Zig runner's enum order.

pub const Opcode = enum(u8) {
    add = 0,
    sub = 1,
    sll = 2,
    slt = 3,
    sltu = 4,
    xor = 5,
    srl = 6,
    sra = 7,
    @"or" = 8,
    @"and" = 9,
    addi = 10,
    slti = 11,
    sltiu = 12,
    xori = 13,
    ori = 14,
    andi = 15,
    slli = 16,
    srli = 17,
    srai = 18,
    lb = 19,
    lh = 20,
    lw = 21,
    lbu = 22,
    lhu = 23,
    sb = 24,
    sh = 25,
    sw = 26,
    beq = 27,
    bne = 28,
    blt = 29,
    bge = 30,
    bltu = 31,
    bgeu = 32,
    jal = 33,
    jalr = 34,
    lui = 35,
    auipc = 36,
    mul = 37,
    mulh = 38,
    mulhsu = 39,
    mulhu = 40,
    div = 41,
    divu = 42,
    rem = 43,
    remu = 44,

    pub inline fn protocolId(self: Opcode) u32 {
        return @intFromEnum(self);
    }
};

test "program opcode: pinned ids are contiguous and stable" {
    const std = @import("std");
    const fields = @typeInfo(Opcode).@"enum".fields;
    try std.testing.expectEqual(@as(usize, 45), fields.len);
    inline for (fields, 0..) |field, expected| {
        try std.testing.expectEqual(@as(u32, @intCast(expected)), @as(u32, @intCast(field.value)));
    }
    try std.testing.expectEqual(@as(u32, 10), Opcode.addi.protocolId());
    try std.testing.expectEqual(@as(u32, 44), Opcode.remu.protocolId());
}
