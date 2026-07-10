//! RISC-V RV32IM instruction decoder.
//!
//! Decodes a 32-bit instruction word into an `Opcode`, destination/source
//! register indices, and an immediate value.  Supports all 45 RV32IM
//! instructions (37 RV32I base + 8 RV32M multiply/divide).

const std = @import("std");

/// All RV32IM opcodes.
pub const Opcode = enum(u8) {
    // ---- RV32I: R-type arithmetic ----
    ADD,
    SUB,
    XOR,
    OR,
    AND,
    SLL,
    SRL,
    SRA,
    SLT,
    SLTU,

    // ---- RV32I: I-type arithmetic ----
    ADDI,
    XORI,
    ORI,
    ANDI,
    SLLI,
    SRLI,
    SRAI,
    SLTI,
    SLTIU,

    // ---- RV32I: Loads ----
    LB,
    LBU,
    LH,
    LHU,
    LW,

    // ---- RV32I: Stores ----
    SB,
    SH,
    SW,

    // ---- RV32I: Branches ----
    BEQ,
    BNE,
    BLT,
    BGE,
    BLTU,
    BGEU,

    // ---- RV32I: Jumps ----
    JAL,
    JALR,

    // ---- RV32I: Upper immediates ----
    LUI,
    AUIPC,

    // ---- RV32M: Multiply / Divide ----
    MUL,
    MULH,
    MULHSU,
    MULHU,
    DIV,
    DIVU,
    REM,
    REMU,

    // ---- RV32A: Atomics ----
    LR_W,
    SC_W,
    AMOSWAP_W,
    AMOADD_W,
    AMOAND_W,
    AMOOR_W,
    AMOXOR_W,
    AMOMIN_W,
    AMOMAX_W,
    AMOMINU_W,
    AMOMAXU_W,

    // ---- System / Misc ----
    ECALL,
    EBREAK,
    FENCE,
};

/// A fully-decoded RV32IM instruction.
pub const DecodedInst = struct {
    opcode: Opcode,
    rd: u5,
    rs1: u5,
    rs2: u5,
    imm: i32,

    /// Decode a 32-bit RISC-V instruction word.
    pub fn decode(inst: u32) !DecodedInst {
        const opcode_field: u7 = @truncate(inst);
        const rd: u5 = @truncate(inst >> 7);
        const funct3: u3 = @truncate(inst >> 12);
        const rs1: u5 = @truncate(inst >> 15);
        const rs2: u5 = @truncate(inst >> 20);
        const funct7: u7 = @truncate(inst >> 25);

        return switch (opcode_field) {
            // ----- R-type (OP = 0b0110011) -----
            0b0110011 => blk: {
                if (funct7 == 0b0000001) {
                    // RV32M extension
                    break :blk .{
                        .opcode = switch (funct3) {
                            0b000 => .MUL,
                            0b001 => .MULH,
                            0b010 => .MULHSU,
                            0b011 => .MULHU,
                            0b100 => .DIV,
                            0b101 => .DIVU,
                            0b110 => .REM,
                            0b111 => .REMU,
                        },
                        .rd = rd,
                        .rs1 = rs1,
                        .rs2 = rs2,
                        .imm = 0,
                    };
                }
                break :blk .{
                    .opcode = switch (funct3) {
                        0b000 => if (funct7 == 0b0100000) Opcode.SUB else Opcode.ADD,
                        0b001 => .SLL,
                        0b010 => .SLT,
                        0b011 => .SLTU,
                        0b100 => .XOR,
                        0b101 => if (funct7 == 0b0100000) Opcode.SRA else Opcode.SRL,
                        0b110 => .OR,
                        0b111 => .AND,
                    },
                    .rd = rd,
                    .rs1 = rs1,
                    .rs2 = rs2,
                    .imm = 0,
                };
            },

            // ----- I-type arithmetic (OP-IMM = 0b0010011) -----
            0b0010011 => .{
                .opcode = switch (funct3) {
                    0b000 => .ADDI,
                    0b001 => .SLLI,
                    0b010 => .SLTI,
                    0b011 => .SLTIU,
                    0b100 => .XORI,
                    0b101 => if (funct7 == 0b0100000) Opcode.SRAI else Opcode.SRLI,
                    0b110 => .ORI,
                    0b111 => .ANDI,
                },
                .rd = rd,
                .rs1 = rs1,
                .rs2 = 0,
                .imm = decodeIImm(inst),
            },

            // ----- I-type loads (LOAD = 0b0000011) -----
            0b0000011 => .{
                .opcode = switch (funct3) {
                    0b000 => .LB,
                    0b001 => .LH,
                    0b010 => .LW,
                    0b100 => .LBU,
                    0b101 => .LHU,
                    else => return error.IllegalInstruction,
                },
                .rd = rd,
                .rs1 = rs1,
                .rs2 = 0,
                .imm = decodeIImm(inst),
            },

            // ----- S-type stores (STORE = 0b0100011) -----
            0b0100011 => .{
                .opcode = switch (funct3) {
                    0b000 => .SB,
                    0b001 => .SH,
                    0b010 => .SW,
                    else => return error.IllegalInstruction,
                },
                .rd = 0,
                .rs1 = rs1,
                .rs2 = rs2,
                .imm = decodeSImm(inst),
            },

            // ----- B-type branches (BRANCH = 0b1100011) -----
            0b1100011 => .{
                .opcode = switch (funct3) {
                    0b000 => .BEQ,
                    0b001 => .BNE,
                    0b100 => .BLT,
                    0b101 => .BGE,
                    0b110 => .BLTU,
                    0b111 => .BGEU,
                    else => return error.IllegalInstruction,
                },
                .rd = 0,
                .rs1 = rs1,
                .rs2 = rs2,
                .imm = decodeBImm(inst),
            },

            // ----- JAL (J-type, 0b1101111) -----
            0b1101111 => .{
                .opcode = .JAL,
                .rd = rd,
                .rs1 = 0,
                .rs2 = 0,
                .imm = decodeJImm(inst),
            },

            // ----- JALR (I-type, 0b1100111) -----
            0b1100111 => .{
                .opcode = .JALR,
                .rd = rd,
                .rs1 = rs1,
                .rs2 = 0,
                .imm = decodeIImm(inst),
            },

            // ----- LUI (U-type, 0b0110111) -----
            0b0110111 => .{
                .opcode = .LUI,
                .rd = rd,
                .rs1 = 0,
                .rs2 = 0,
                .imm = decodeUImm(inst),
            },

            // ----- AUIPC (U-type, 0b0010111) -----
            0b0010111 => .{
                .opcode = .AUIPC,
                .rd = rd,
                .rs1 = 0,
                .rs2 = 0,
                .imm = decodeUImm(inst),
            },

            // ----- RV32A: Atomic memory operations (AMO = 0b0101111) -----
            0b0101111 => blk: {
                if (funct3 != 0b010) return error.IllegalInstruction;
                const funct5: u5 = @truncate(inst >> 27);
                break :blk .{
                    .opcode = switch (funct5) {
                        0b00010 => .LR_W,
                        0b00011 => .SC_W,
                        0b00001 => .AMOSWAP_W,
                        0b00000 => .AMOADD_W,
                        0b01100 => .AMOAND_W,
                        0b01000 => .AMOOR_W,
                        0b00100 => .AMOXOR_W,
                        0b10000 => .AMOMIN_W,
                        0b10100 => .AMOMAX_W,
                        0b11000 => .AMOMINU_W,
                        0b11100 => .AMOMAXU_W,
                        else => return error.IllegalInstruction,
                    },
                    .rd = rd,
                    .rs1 = rs1,
                    .rs2 = rs2,
                    .imm = 0,
                };
            },

            // ----- SYSTEM (0b1110011) -----
            0b1110011 => .{
                .opcode = if (inst == 0x00000073) Opcode.ECALL else Opcode.EBREAK,
                .rd = 0,
                .rs1 = 0,
                .rs2 = 0,
                .imm = 0,
            },

            // ----- FENCE (0b0001111) -----
            // Memory ordering fence — no-op in single-threaded zkVM.
            0b0001111 => .{
                .opcode = .FENCE,
                .rd = 0,
                .rs1 = 0,
                .rs2 = 0,
                .imm = 0,
            },

            else => return error.IllegalInstruction,
        };
    }
};

// ---------------------------------------------------------------------------
// Immediate-field extraction helpers
// ---------------------------------------------------------------------------

/// I-type immediate: inst[31:20], sign-extended.
fn decodeIImm(inst: u32) i32 {
    const raw: i32 = @bitCast(inst);
    return raw >> 20; // arithmetic shift preserves sign
}

/// S-type immediate: { inst[31:25], inst[11:7] }, sign-extended.
fn decodeSImm(inst: u32) i32 {
    const hi: u32 = inst >> 25;
    const lo: u32 = (inst >> 7) & 0x1F;
    const combined: u32 = (hi << 5) | lo;
    // Sign-extend from 12 bits.
    return signExtend(combined, 12);
}

/// B-type immediate: { inst[31], inst[7], inst[30:25], inst[11:8], 0 }.
fn decodeBImm(inst: u32) i32 {
    const bit_31: u32 = (inst >> 31) & 1;
    const bit_7: u32 = (inst >> 7) & 1;
    const bits_30_25: u32 = (inst >> 25) & 0x3F;
    const bits_11_8: u32 = (inst >> 8) & 0xF;
    const combined: u32 = (bit_31 << 12) | (bit_7 << 11) | (bits_30_25 << 5) | (bits_11_8 << 1);
    return signExtend(combined, 13);
}

/// U-type immediate: inst[31:12] << 12.
fn decodeUImm(inst: u32) i32 {
    return @bitCast(inst & 0xFFFFF000);
}

/// J-type immediate: { inst[31], inst[19:12], inst[20], inst[30:21], 0 }.
fn decodeJImm(inst: u32) i32 {
    const bit_31: u32 = (inst >> 31) & 1;
    const bits_19_12: u32 = (inst >> 12) & 0xFF;
    const bit_20: u32 = (inst >> 20) & 1;
    const bits_30_21: u32 = (inst >> 21) & 0x3FF;
    const combined: u32 = (bit_31 << 20) | (bits_19_12 << 12) | (bit_20 << 11) | (bits_30_21 << 1);
    return signExtend(combined, 21);
}

/// Sign-extend a `bits`-wide unsigned value to i32.
fn signExtend(value: u32, comptime bits: u5) i32 {
    const shift: u5 = @intCast(32 - @as(u6, bits));
    const signed: i32 = @bitCast(value << shift);
    return signed >> shift;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "decode ADD x1, x2, x3 (0x003100B3)" {
    const inst = try DecodedInst.decode(0x003100B3);
    try std.testing.expectEqual(Opcode.ADD, inst.opcode);
    try std.testing.expectEqual(@as(u5, 1), inst.rd);
    try std.testing.expectEqual(@as(u5, 2), inst.rs1);
    try std.testing.expectEqual(@as(u5, 3), inst.rs2);
}

test "decode ADDI x5, x0, 42 (0x02A00293)" {
    const inst = try DecodedInst.decode(0x02A00293);
    try std.testing.expectEqual(Opcode.ADDI, inst.opcode);
    try std.testing.expectEqual(@as(u5, 5), inst.rd);
    try std.testing.expectEqual(@as(u5, 0), inst.rs1);
    try std.testing.expectEqual(@as(i32, 42), inst.imm);
}

test "decode SW x5, 0(x2) (0x00512023)" {
    const inst = try DecodedInst.decode(0x00512023);
    try std.testing.expectEqual(Opcode.SW, inst.opcode);
    try std.testing.expectEqual(@as(u5, 2), inst.rs1);
    try std.testing.expectEqual(@as(u5, 5), inst.rs2);
    try std.testing.expectEqual(@as(i32, 0), inst.imm);
}

test "decode LW x6, 0(x2) (0x00012303)" {
    const inst = try DecodedInst.decode(0x00012303);
    try std.testing.expectEqual(Opcode.LW, inst.opcode);
    try std.testing.expectEqual(@as(u5, 6), inst.rd);
    try std.testing.expectEqual(@as(u5, 2), inst.rs1);
    try std.testing.expectEqual(@as(i32, 0), inst.imm);
}

test "decode BEQ x1, x2, +8 (0x00208463)" {
    const inst = try DecodedInst.decode(0x00208463);
    try std.testing.expectEqual(Opcode.BEQ, inst.opcode);
    try std.testing.expectEqual(@as(u5, 1), inst.rs1);
    try std.testing.expectEqual(@as(u5, 2), inst.rs2);
    try std.testing.expectEqual(@as(i32, 8), inst.imm);
}

test "decode JAL x1, +0 (0x000000EF)" {
    // JAL rd=1, offset=0 encodes as 0x000000EF
    const inst = try DecodedInst.decode(0x000000EF);
    try std.testing.expectEqual(Opcode.JAL, inst.opcode);
    try std.testing.expectEqual(@as(u5, 1), inst.rd);
    try std.testing.expectEqual(@as(i32, 0), inst.imm);
}

test "decode LUI x1, 0x12345000 (0x12345_0B7)" {
    const inst = try DecodedInst.decode(0x123450B7);
    try std.testing.expectEqual(Opcode.LUI, inst.opcode);
    try std.testing.expectEqual(@as(u5, 1), inst.rd);
    try std.testing.expectEqual(@as(i32, 0x12345000), inst.imm);
}

test "decode MUL x1, x2, x3 (0x023100B3)" {
    const inst = try DecodedInst.decode(0x023100B3);
    try std.testing.expectEqual(Opcode.MUL, inst.opcode);
    try std.testing.expectEqual(@as(u5, 1), inst.rd);
    try std.testing.expectEqual(@as(u5, 2), inst.rs1);
    try std.testing.expectEqual(@as(u5, 3), inst.rs2);
}

test "decode ECALL (0x00000073)" {
    const inst = try DecodedInst.decode(0x00000073);
    try std.testing.expectEqual(Opcode.ECALL, inst.opcode);
}

test "decode SUB x1, x2, x3 (0x403100B3)" {
    const inst = try DecodedInst.decode(0x403100B3);
    try std.testing.expectEqual(Opcode.SUB, inst.opcode);
    try std.testing.expectEqual(@as(u5, 1), inst.rd);
    try std.testing.expectEqual(@as(u5, 2), inst.rs1);
    try std.testing.expectEqual(@as(u5, 3), inst.rs2);
}

test "decode ADDI with negative immediate" {
    // ADDI x1, x0, -1  =>  0xFFF00093
    const inst = try DecodedInst.decode(0xFFF00093);
    try std.testing.expectEqual(Opcode.ADDI, inst.opcode);
    try std.testing.expectEqual(@as(u5, 1), inst.rd);
    try std.testing.expectEqual(@as(u5, 0), inst.rs1);
    try std.testing.expectEqual(@as(i32, -1), inst.imm);
}

test "decoder equivalence: Zig decoder vs known RV32IM instruction encodings" {
    // Verify our decoder produces the exact same output as the RISC-V spec
    // for a comprehensive set of known instruction encodings.
    const Expected = struct {
        encoding: u32,
        opcode: Opcode,
        rd: u5,
        rs1: u5,
        rs2: u5,
        imm: i32,
    };

    const cases = [_]Expected{
        // ADD x1, x2, x3
        .{ .encoding = 0x003100B3, .opcode = .ADD, .rd = 1, .rs1 = 2, .rs2 = 3, .imm = 0 },
        // SUB x2, x2, x3
        .{ .encoding = 0x40310133, .opcode = .SUB, .rd = 2, .rs1 = 2, .rs2 = 3, .imm = 0 },
        // ADDI x1, x0, 5
        .{ .encoding = 0x00500093, .opcode = .ADDI, .rd = 1, .rs1 = 0, .rs2 = 0, .imm = 5 },
        // LW x2, 0(x0)
        .{ .encoding = 0x00002103, .opcode = .LW, .rd = 2, .rs1 = 0, .rs2 = 0, .imm = 0 },
        // SW x1, 0(x2)
        .{ .encoding = 0x00112023, .opcode = .SW, .rd = 0, .rs1 = 2, .rs2 = 1, .imm = 0 },
        // BEQ x1, x2, 8
        .{ .encoding = 0x00208463, .opcode = .BEQ, .rd = 0, .rs1 = 1, .rs2 = 2, .imm = 8 },
        // JAL x1, 12
        .{ .encoding = 0x00C000EF, .opcode = .JAL, .rd = 1, .rs1 = 0, .rs2 = 0, .imm = 12 },
        // JALR x1, x1, 0
        .{ .encoding = 0x000080E7, .opcode = .JALR, .rd = 1, .rs1 = 1, .rs2 = 0, .imm = 0 },
        // LUI x3, 1
        .{ .encoding = 0x000011B7, .opcode = .LUI, .rd = 3, .rs1 = 0, .rs2 = 0, .imm = 0x1000 },
        // AUIPC x3, 1
        .{ .encoding = 0x00001197, .opcode = .AUIPC, .rd = 3, .rs1 = 0, .rs2 = 0, .imm = 0x1000 },
        // MUL x0, x1, x2
        .{ .encoding = 0x02208033, .opcode = .MUL, .rd = 0, .rs1 = 1, .rs2 = 2, .imm = 0 },
        // MULH x0, x1, x2
        .{ .encoding = 0x02209033, .opcode = .MULH, .rd = 0, .rs1 = 1, .rs2 = 2, .imm = 0 },
        // DIV x0, x1, x2
        .{ .encoding = 0x0220C033, .opcode = .DIV, .rd = 0, .rs1 = 1, .rs2 = 2, .imm = 0 },
        // SLLI x0, x0, 1
        .{ .encoding = 0x00101013, .opcode = .SLLI, .rd = 0, .rs1 = 0, .rs2 = 0, .imm = 1 },
        // ECALL
        .{ .encoding = 0x00000073, .opcode = .ECALL, .rd = 0, .rs1 = 0, .rs2 = 0, .imm = 0 },
    };

    for (cases) |expected| {
        const inst = try DecodedInst.decode(expected.encoding);
        try std.testing.expectEqual(expected.opcode, inst.opcode);
        try std.testing.expectEqual(expected.rd, inst.rd);
        try std.testing.expectEqual(expected.rs1, inst.rs1);
        try std.testing.expectEqual(expected.rs2, inst.rs2);
        try std.testing.expectEqual(expected.imm, inst.imm);
    }
}
