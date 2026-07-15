//! Cairo instruction decoding.
//!
//! A Cairo instruction is encoded as a u128. The first 48 bits are three
//! 16-bit signed offsets (biased by 0x8000). Then 15 flag bits. The
//! remaining bits encode the opcode extension.

const std = @import("std");
const M31 = @import("../../../core/fields/m31.zig").M31;

/// Opcode extensions beyond the Stone VM base set.
pub const OpcodeExtension = enum(u2) {
    stone = 0,
    blake = 1,
    blake_finalize = 2,
    qm31_operation = 3,
};

/// A decoded Cairo instruction.
pub const Instruction = struct {
    /// Three signed offsets (biased by 0x8000 in the encoding).
    offset0: i16,
    offset1: i16,
    offset2: i16,

    // 15 flag bits:
    dst_base_fp: bool, //  bit 0
    op0_base_fp: bool, //  bit 1
    op_1_imm: bool, //  bit 2
    op_1_base_fp: bool, //  bit 3
    op_1_base_ap: bool, //  bit 4
    res_add: bool, //  bit 5
    res_mul: bool, //  bit 6
    pc_update_jump: bool, //  bit 7
    pc_update_jump_rel: bool, //  bit 8
    pc_update_jnz: bool, //  bit 9
    ap_update_add: bool, // bit 10
    ap_update_add_1: bool, // bit 11
    opcode_call: bool, // bit 12
    opcode_ret: bool, // bit 13
    opcode_assert_eq: bool, // bit 14

    opcode_extension: OpcodeExtension,

    /// Decode a raw u128 instruction word.
    pub fn decode(encoded: u128) Instruction {
        const BIAS: u16 = 0x8000;

        const w0: u16 = @truncate(encoded);
        const w1: u16 = @truncate(encoded >> 16);
        const w2: u16 = @truncate(encoded >> 32);
        const flags: u15 = @truncate(encoded >> 48);
        const ext_bits: u2 = @truncate(encoded >> 63);

        return .{
            .offset0 = @bitCast(w0 -% BIAS),
            .offset1 = @bitCast(w1 -% BIAS),
            .offset2 = @bitCast(w2 -% BIAS),

            .dst_base_fp = (flags & (1 << 0)) != 0,
            .op0_base_fp = (flags & (1 << 1)) != 0,
            .op_1_imm = (flags & (1 << 2)) != 0,
            .op_1_base_fp = (flags & (1 << 3)) != 0,
            .op_1_base_ap = (flags & (1 << 4)) != 0,
            .res_add = (flags & (1 << 5)) != 0,
            .res_mul = (flags & (1 << 6)) != 0,
            .pc_update_jump = (flags & (1 << 7)) != 0,
            .pc_update_jump_rel = (flags & (1 << 8)) != 0,
            .pc_update_jnz = (flags & (1 << 9)) != 0,
            .ap_update_add = (flags & (1 << 10)) != 0,
            .ap_update_add_1 = (flags & (1 << 11)) != 0,
            .opcode_call = (flags & (1 << 12)) != 0,
            .opcode_ret = (flags & (1 << 13)) != 0,
            .opcode_assert_eq = (flags & (1 << 14)) != 0,

            .opcode_extension = @enumFromInt(ext_bits),
        };
    }

    /// Pack the 15 flag bits into two M31 values as used by the AIR.
    /// flags_a = bits[0..6] << 3, flags_b = bits[6..15].
    pub fn deconstructFlags(self: Instruction) [2]M31 {
        var bits_a: u32 = 0;
        if (self.dst_base_fp) bits_a |= 1 << 0;
        if (self.op0_base_fp) bits_a |= 1 << 1;
        if (self.op_1_imm) bits_a |= 1 << 2;
        if (self.op_1_base_fp) bits_a |= 1 << 3;
        if (self.op_1_base_ap) bits_a |= 1 << 4;
        if (self.res_add) bits_a |= 1 << 5;

        var bits_b: u32 = 0;
        if (self.res_mul) bits_b |= 1 << 0;
        if (self.pc_update_jump) bits_b |= 1 << 1;
        if (self.pc_update_jump_rel) bits_b |= 1 << 2;
        if (self.pc_update_jnz) bits_b |= 1 << 3;
        if (self.ap_update_add) bits_b |= 1 << 4;
        if (self.ap_update_add_1) bits_b |= 1 << 5;
        if (self.opcode_call) bits_b |= 1 << 6;
        if (self.opcode_ret) bits_b |= 1 << 7;
        if (self.opcode_assert_eq) bits_b |= 1 << 8;

        return .{
            M31.fromCanonical(bits_a << 3),
            M31.fromCanonical(bits_b),
        };
    }
};

// ---------------------------------------------------------------
// Tests
// ---------------------------------------------------------------

test "decode: basic ret instruction" {
    // ret = opcode_ret flag set (bit 13), offsets at bias
    const BIAS: u128 = 0x8000;
    const encoded: u128 = BIAS | (BIAS << 16) | (BIAS << 32) | (@as(u128, 1) << (48 + 13));
    const inst = Instruction.decode(encoded);

    try std.testing.expectEqual(@as(i16, 0), inst.offset0);
    try std.testing.expectEqual(@as(i16, 0), inst.offset1);
    try std.testing.expectEqual(@as(i16, 0), inst.offset2);
    try std.testing.expect(inst.opcode_ret);
    try std.testing.expect(!inst.opcode_call);
    try std.testing.expect(!inst.res_add);
}

test "decode: flag deconstruction roundtrip" {
    const BIAS: u128 = 0x8000;
    // Set res_add (bit 5) and opcode_assert_eq (bit 14)
    const flags: u128 = (1 << 5) | (1 << 14);
    const encoded: u128 = BIAS | (BIAS << 16) | (BIAS << 32) | (flags << 48);
    const inst = Instruction.decode(encoded);

    try std.testing.expect(inst.res_add);
    try std.testing.expect(inst.opcode_assert_eq);

    const deconstructed = inst.deconstructFlags();
    // bits_a should have bit 5 set, shifted left by 3 => 5 << 3 = 0b100000 << 3 = 256
    try std.testing.expectEqual(@as(u32, (1 << 5) << 3), deconstructed[0].v);
    // bits_b should have bit 8 set (opcode_assert_eq is bit 14 overall, bit 8 in group b)
    try std.testing.expectEqual(@as(u32, 1 << 8), deconstructed[1].v);
}
