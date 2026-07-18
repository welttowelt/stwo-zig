//! Exact decoded program-tuple rules from pinned Stark-V.
//!
//! This decoder intentionally does not call the broader Zig execution
//! decoder: the release-gated statement supports RV32IM only, and accepting
//! RV32A, SYSTEM, or FENCE here would create program rows with no sound AIR.

const std = @import("std");
const m31 = @import("../../../../core/fields/m31.zig");
const opcode_manifest = @import("../../opcode_manifest.zig");
const opcode_mod = @import("opcode.zig");

pub const Opcode = opcode_mod.Opcode;
pub const ProgramValues = [4]u32;

pub const Error = error{
    InvalidInstruction,
    UnsupportedInstructionClass,
};

pub const DecodedInstruction = struct {
    opcode: Opcode,
    rd: u5,
    rs1: u5,
    rs2: u5,
    imm: i32,
};

pub fn decodeInstruction(word: u32) Error!DecodedInstruction {
    const opcode_bits: u7 = @truncate(word);
    const rd: u5 = @truncate(word >> 7);
    const funct3: u3 = @truncate(word >> 12);
    const rs1: u5 = @truncate(word >> 15);
    const rs2: u5 = @truncate(word >> 20);
    const funct7: u7 = @truncate(word >> 25);

    return switch (opcode_bits) {
        0b0110011 => .{
            .opcode = try decodeRegisterOpcode(funct3, funct7),
            .rd = rd,
            .rs1 = rs1,
            .rs2 = rs2,
            .imm = 0,
        },
        0b0010011 => blk: {
            const op: Opcode = switch (funct3) {
                0b000 => .addi,
                0b010 => .slti,
                0b011 => .sltiu,
                0b100 => .xori,
                0b110 => .ori,
                0b111 => .andi,
                // Preserve the pinned decoder: SLLI does not inspect funct7,
                // and funct3=101 is SRAI only when funct7 is exactly 0x20.
                0b001 => .slli,
                0b101 => if (funct7 == 0b0100000) .srai else .srli,
            };
            const is_shift = op == .slli or op == .srli or op == .srai;
            break :blk .{
                .opcode = op,
                .rd = rd,
                .rs1 = rs1,
                .rs2 = rs2,
                .imm = if (is_shift) @intCast((word >> 20) & 0x1f) else decodeIImmediate(word),
            };
        },
        0b0000011 => .{
            .opcode = switch (funct3) {
                0b000 => .lb,
                0b001 => .lh,
                0b010 => .lw,
                0b100 => .lbu,
                0b101 => .lhu,
                else => return Error.InvalidInstruction,
            },
            .rd = rd,
            .rs1 = rs1,
            .rs2 = rs2,
            .imm = decodeIImmediate(word),
        },
        0b0100011 => .{
            .opcode = switch (funct3) {
                0b000 => .sb,
                0b001 => .sh,
                0b010 => .sw,
                else => return Error.InvalidInstruction,
            },
            .rd = rd,
            .rs1 = rs1,
            .rs2 = rs2,
            .imm = decodeSImmediate(word),
        },
        0b1100011 => .{
            .opcode = switch (funct3) {
                0b000 => .beq,
                0b001 => .bne,
                0b100 => .blt,
                0b101 => .bge,
                0b110 => .bltu,
                0b111 => .bgeu,
                else => return Error.InvalidInstruction,
            },
            .rd = rd,
            .rs1 = rs1,
            .rs2 = rs2,
            .imm = decodeBImmediate(word),
        },
        0b1101111 => .{ .opcode = .jal, .rd = rd, .rs1 = rs1, .rs2 = rs2, .imm = decodeJImmediate(word) },
        0b1100111 => .{ .opcode = .jalr, .rd = rd, .rs1 = rs1, .rs2 = rs2, .imm = decodeIImmediate(word) },
        0b0110111 => .{ .opcode = .lui, .rd = rd, .rs1 = rs1, .rs2 = rs2, .imm = @bitCast(word & 0xfffff000) },
        0b0010111 => .{ .opcode = .auipc, .rd = rd, .rs1 = rs1, .rs2 = rs2, .imm = @bitCast(word & 0xfffff000) },
        0b0101111, 0b1110011, 0b0001111 => Error.UnsupportedInstructionClass,
        else => Error.InvalidInstruction,
    };
}

/// Return the four values following `pc` in Stark-V's `program_access`
/// relation. Signed immediates use their canonical M31 representation.
pub fn decodeProgramWord(word: u32) Error!ProgramValues {
    const inst = try decodeInstruction(word);
    const id = inst.opcode.protocolId();
    return switch (opcode_manifest.entry(inst.opcode).program_shape) {
        .register => .{ id, inst.rd, inst.rs1, inst.rs2 },
        .store => .{ id, inst.rs1, inst.rs2, immediateToFelt(inst.imm) },
        .load => .{ id, inst.rs1, inst.rd, immediateToFelt(inst.imm) },
        .shift_immediate => .{ id, inst.rd, inst.rs1, @as(u32, @bitCast(inst.imm)) & 0x1f },
        .immediate => .{
            id,
            inst.rd,
            inst.rs1,
            @as(u32, @bitCast(inst.imm)) & 0xfff,
        },
        .jalr => .{ id, inst.rd, inst.rs1, immediateToFelt(inst.imm) },
        .lui => .{ id, inst.rd, (word >> 12) & 0xfffff, 0 },
        .auipc, .jal => .{ id, inst.rd, immediateToFelt(inst.imm), 0 },
        .branch => .{
            id,
            inst.rs1,
            inst.rs2,
            immediateToFelt(inst.imm),
        },
    };
}

pub fn immediateToFelt(immediate: i32) u32 {
    const signed: i64 = immediate;
    const modulus: i64 = m31.Modulus;
    return @intCast(@mod(signed, modulus));
}

fn decodeRegisterOpcode(funct3: u3, funct7: u7) Error!Opcode {
    return switch (funct7) {
        0b0000000 => switch (funct3) {
            0b000 => .add,
            0b001 => .sll,
            0b010 => .slt,
            0b011 => .sltu,
            0b100 => .xor,
            0b101 => .srl,
            0b110 => .@"or",
            0b111 => .@"and",
        },
        0b0100000 => if (funct3 == 0b000)
            .sub
        else if (funct3 == 0b101)
            .sra
        else
            Error.InvalidInstruction,
        0b0000001 => switch (funct3) {
            0b000 => .mul,
            0b001 => .mulh,
            0b010 => .mulhsu,
            0b011 => .mulhu,
            0b100 => .div,
            0b101 => .divu,
            0b110 => .rem,
            0b111 => .remu,
        },
        else => Error.InvalidInstruction,
    };
}

fn decodeIImmediate(word: u32) i32 {
    return @as(i32, @bitCast(word)) >> 20;
}

fn decodeSImmediate(word: u32) i32 {
    const value = ((word >> 25) << 5) | ((word >> 7) & 0x1f);
    return signExtend(value, 12);
}

fn decodeBImmediate(word: u32) i32 {
    const value = ((word >> 31) << 12) |
        (((word >> 7) & 1) << 11) |
        (((word >> 25) & 0x3f) << 5) |
        (((word >> 8) & 0xf) << 1);
    return signExtend(value, 13);
}

fn decodeJImmediate(word: u32) i32 {
    const value = ((word >> 31) << 20) |
        (((word >> 12) & 0xff) << 12) |
        (((word >> 20) & 1) << 11) |
        (((word >> 21) & 0x3ff) << 1);
    return signExtend(value, 21);
}

fn signExtend(value: u32, comptime bits: u5) i32 {
    const shift: u5 = @intCast(32 - @as(u6, bits));
    return @as(i32, @bitCast(value << shift)) >> shift;
}

fn encodeR(funct7: u32, funct3: u32) u32 {
    return (funct7 << 25) | (3 << 20) | (2 << 15) | (funct3 << 12) | (1 << 7) | 0x33;
}

fn encodeI(immediate: i32, funct3: u32, instruction_opcode: u32) u32 {
    const encoded: u32 = @bitCast(immediate);
    return ((encoded & 0xfff) << 20) | (2 << 15) | (funct3 << 12) | (1 << 7) | instruction_opcode;
}

fn encodeS(funct3: u32) u32 {
    return (3 << 20) | (2 << 15) | (funct3 << 12) | 0x23;
}

fn encodeB(funct3: u32) u32 {
    return (3 << 20) | (2 << 15) | (funct3 << 12) | (4 << 8) | 0x63;
}

test "decoded program: all 45 RV32IM words map to pinned protocol ids" {
    const Case = struct { word: u32, opcode: Opcode };
    const cases = [_]Case{
        .{ .word = encodeR(0x00, 0), .opcode = .add },
        .{ .word = encodeR(0x20, 0), .opcode = .sub },
        .{ .word = encodeR(0x00, 1), .opcode = .sll },
        .{ .word = encodeR(0x00, 2), .opcode = .slt },
        .{ .word = encodeR(0x00, 3), .opcode = .sltu },
        .{ .word = encodeR(0x00, 4), .opcode = .xor },
        .{ .word = encodeR(0x00, 5), .opcode = .srl },
        .{ .word = encodeR(0x20, 5), .opcode = .sra },
        .{ .word = encodeR(0x00, 6), .opcode = .@"or" },
        .{ .word = encodeR(0x00, 7), .opcode = .@"and" },
        .{ .word = encodeI(-1, 0, 0x13), .opcode = .addi },
        .{ .word = encodeI(-1, 2, 0x13), .opcode = .slti },
        .{ .word = encodeI(-1, 3, 0x13), .opcode = .sltiu },
        .{ .word = encodeI(-1, 4, 0x13), .opcode = .xori },
        .{ .word = encodeI(-1, 6, 0x13), .opcode = .ori },
        .{ .word = encodeI(-1, 7, 0x13), .opcode = .andi },
        .{ .word = encodeI(3, 1, 0x13), .opcode = .slli },
        .{ .word = encodeI(3, 5, 0x13), .opcode = .srli },
        .{ .word = encodeI(0x403, 5, 0x13), .opcode = .srai },
        .{ .word = encodeI(-4, 0, 0x03), .opcode = .lb },
        .{ .word = encodeI(-4, 1, 0x03), .opcode = .lh },
        .{ .word = encodeI(-4, 2, 0x03), .opcode = .lw },
        .{ .word = encodeI(-4, 4, 0x03), .opcode = .lbu },
        .{ .word = encodeI(-4, 5, 0x03), .opcode = .lhu },
        .{ .word = encodeS(0), .opcode = .sb },
        .{ .word = encodeS(1), .opcode = .sh },
        .{ .word = encodeS(2), .opcode = .sw },
        .{ .word = encodeB(0), .opcode = .beq },
        .{ .word = encodeB(1), .opcode = .bne },
        .{ .word = encodeB(4), .opcode = .blt },
        .{ .word = encodeB(5), .opcode = .bge },
        .{ .word = encodeB(6), .opcode = .bltu },
        .{ .word = encodeB(7), .opcode = .bgeu },
        .{ .word = 0x000000ef, .opcode = .jal },
        .{ .word = encodeI(-1, 0, 0x67), .opcode = .jalr },
        .{ .word = 0x123450b7, .opcode = .lui },
        .{ .word = 0x12345097, .opcode = .auipc },
        .{ .word = encodeR(0x01, 0), .opcode = .mul },
        .{ .word = encodeR(0x01, 1), .opcode = .mulh },
        .{ .word = encodeR(0x01, 2), .opcode = .mulhsu },
        .{ .word = encodeR(0x01, 3), .opcode = .mulhu },
        .{ .word = encodeR(0x01, 4), .opcode = .div },
        .{ .word = encodeR(0x01, 5), .opcode = .divu },
        .{ .word = encodeR(0x01, 6), .opcode = .rem },
        .{ .word = encodeR(0x01, 7), .opcode = .remu },
    };
    try std.testing.expectEqual(@as(usize, 45), cases.len);
    for (cases) |case| {
        const decoded = try decodeInstruction(case.word);
        try std.testing.expectEqual(case.opcode, decoded.opcode);
        try std.testing.expectEqual(case.opcode.protocolId(), (try decodeProgramWord(case.word))[0]);
    }
}

test "decoded program: pinned numeric tuple vectors" {
    const cases = [_]struct { word: u32, expected: ProgramValues }{
        .{ .word = 0x002081b3, .expected = .{ 0, 3, 1, 2 } },
        .{ .word = 0xfff30293, .expected = .{ 10, 5, 6, 4095 } },
        .{ .word = 0x00311093, .expected = .{ 16, 1, 2, 3 } },
        .{ .word = 0x0082a203, .expected = .{ 21, 5, 4, 8 } },
        .{ .word = 0x0042a623, .expected = .{ 26, 5, 4, 12 } },
        .{ .word = 0xabcde3b7, .expected = .{ 35, 7, 0xabcde, 0 } },
        .{ .word = 0x10000417, .expected = .{ 36, 8, 0x10000000, 0 } },
        .{ .word = 0x010000ef, .expected = .{ 33, 1, 16, 0 } },
        .{ .word = 0x00208463, .expected = .{ 27, 1, 2, 8 } },
    };
    for (cases) |case| try std.testing.expectEqual(case.expected, try decodeProgramWord(case.word));
}

test "decoded program: negative signed immediates use canonical M31" {
    const jalr = try decodeProgramWord(0xfff080e7);
    try std.testing.expectEqual(m31.Modulus - 1, jalr[3]);
    const branch = try decodeProgramWord(0xfe208ee3);
    try std.testing.expectEqual(m31.Modulus - 4, branch[3]);
}

test "decoded program: rejects instruction classes outside RV32IM" {
    try std.testing.expectError(Error.UnsupportedInstructionClass, decodeProgramWord(0x00000073));
    try std.testing.expectError(Error.UnsupportedInstructionClass, decodeProgramWord(0x00100073));
    try std.testing.expectError(Error.UnsupportedInstructionClass, decodeProgramWord(0x0000000f));
    try std.testing.expectError(Error.UnsupportedInstructionClass, decodeProgramWord(0x100020af));
    try std.testing.expectError(Error.InvalidInstruction, decodeProgramWord(0));
}
