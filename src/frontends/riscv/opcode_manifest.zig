//! Canonical Stark-V opcode protocol and proof-family policy.
//!
//! Execution supports a wider instruction set than the proof statement. Every
//! proof-eligible opcode is listed exactly once here; execution-only opcodes are
//! listed separately and never receive a proof family.

const std = @import("std");

pub const schema_version: u32 = 1;
pub const stark_v_revision = "d478f783055aa0d73a93768a433a3c6c31c91d1c";

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

pub const Family = enum(u8) {
    base_alu_reg,
    base_alu_imm,
    shifts_reg,
    shifts_imm,
    lt_reg,
    lt_imm,
    branch_eq,
    branch_lt,
    lui,
    auipc,
    jalr,
    jal,
    load_store,
    mul,
    mulh,
    div,
};

pub const ProgramShape = enum {
    register,
    immediate,
    shift_immediate,
    load,
    store,
    branch,
    jal,
    jalr,
    lui,
    auipc,
};

pub const Entry = struct {
    opcode: Opcode,
    mnemonic: []const u8,
    family: Family,
    program_shape: ProgramShape,
};

const reg = ProgramShape.register;
const imm = ProgramShape.immediate;

/// Indexed by protocol ID. Order is part of the proof protocol.
pub const entries = [_]Entry{
    .{ .opcode = .add, .mnemonic = "add", .family = .base_alu_reg, .program_shape = reg },
    .{ .opcode = .sub, .mnemonic = "sub", .family = .base_alu_reg, .program_shape = reg },
    .{ .opcode = .sll, .mnemonic = "sll", .family = .shifts_reg, .program_shape = reg },
    .{ .opcode = .slt, .mnemonic = "slt", .family = .lt_reg, .program_shape = reg },
    .{ .opcode = .sltu, .mnemonic = "sltu", .family = .lt_reg, .program_shape = reg },
    .{ .opcode = .xor, .mnemonic = "xor", .family = .base_alu_reg, .program_shape = reg },
    .{ .opcode = .srl, .mnemonic = "srl", .family = .shifts_reg, .program_shape = reg },
    .{ .opcode = .sra, .mnemonic = "sra", .family = .shifts_reg, .program_shape = reg },
    .{ .opcode = .@"or", .mnemonic = "or", .family = .base_alu_reg, .program_shape = reg },
    .{ .opcode = .@"and", .mnemonic = "and", .family = .base_alu_reg, .program_shape = reg },
    .{ .opcode = .addi, .mnemonic = "addi", .family = .base_alu_imm, .program_shape = imm },
    .{ .opcode = .slti, .mnemonic = "slti", .family = .lt_imm, .program_shape = imm },
    .{ .opcode = .sltiu, .mnemonic = "sltiu", .family = .lt_imm, .program_shape = imm },
    .{ .opcode = .xori, .mnemonic = "xori", .family = .base_alu_imm, .program_shape = imm },
    .{ .opcode = .ori, .mnemonic = "ori", .family = .base_alu_imm, .program_shape = imm },
    .{ .opcode = .andi, .mnemonic = "andi", .family = .base_alu_imm, .program_shape = imm },
    .{ .opcode = .slli, .mnemonic = "slli", .family = .shifts_imm, .program_shape = .shift_immediate },
    .{ .opcode = .srli, .mnemonic = "srli", .family = .shifts_imm, .program_shape = .shift_immediate },
    .{ .opcode = .srai, .mnemonic = "srai", .family = .shifts_imm, .program_shape = .shift_immediate },
    .{ .opcode = .lb, .mnemonic = "lb", .family = .load_store, .program_shape = .load },
    .{ .opcode = .lh, .mnemonic = "lh", .family = .load_store, .program_shape = .load },
    .{ .opcode = .lw, .mnemonic = "lw", .family = .load_store, .program_shape = .load },
    .{ .opcode = .lbu, .mnemonic = "lbu", .family = .load_store, .program_shape = .load },
    .{ .opcode = .lhu, .mnemonic = "lhu", .family = .load_store, .program_shape = .load },
    .{ .opcode = .sb, .mnemonic = "sb", .family = .load_store, .program_shape = .store },
    .{ .opcode = .sh, .mnemonic = "sh", .family = .load_store, .program_shape = .store },
    .{ .opcode = .sw, .mnemonic = "sw", .family = .load_store, .program_shape = .store },
    .{ .opcode = .beq, .mnemonic = "beq", .family = .branch_eq, .program_shape = .branch },
    .{ .opcode = .bne, .mnemonic = "bne", .family = .branch_eq, .program_shape = .branch },
    .{ .opcode = .blt, .mnemonic = "blt", .family = .branch_lt, .program_shape = .branch },
    .{ .opcode = .bge, .mnemonic = "bge", .family = .branch_lt, .program_shape = .branch },
    .{ .opcode = .bltu, .mnemonic = "bltu", .family = .branch_lt, .program_shape = .branch },
    .{ .opcode = .bgeu, .mnemonic = "bgeu", .family = .branch_lt, .program_shape = .branch },
    .{ .opcode = .jal, .mnemonic = "jal", .family = .jal, .program_shape = .jal },
    .{ .opcode = .jalr, .mnemonic = "jalr", .family = .jalr, .program_shape = .jalr },
    .{ .opcode = .lui, .mnemonic = "lui", .family = .lui, .program_shape = .lui },
    .{ .opcode = .auipc, .mnemonic = "auipc", .family = .auipc, .program_shape = .auipc },
    .{ .opcode = .mul, .mnemonic = "mul", .family = .mul, .program_shape = reg },
    .{ .opcode = .mulh, .mnemonic = "mulh", .family = .mulh, .program_shape = reg },
    .{ .opcode = .mulhsu, .mnemonic = "mulhsu", .family = .mulh, .program_shape = reg },
    .{ .opcode = .mulhu, .mnemonic = "mulhu", .family = .mulh, .program_shape = reg },
    .{ .opcode = .div, .mnemonic = "div", .family = .div, .program_shape = reg },
    .{ .opcode = .divu, .mnemonic = "divu", .family = .div, .program_shape = reg },
    .{ .opcode = .rem, .mnemonic = "rem", .family = .div, .program_shape = reg },
    .{ .opcode = .remu, .mnemonic = "remu", .family = .div, .program_shape = reg },
};

pub const UnsupportedClass = enum { system, fence, rv32a };

pub const UnsupportedEntry = struct {
    mnemonic: []const u8,
    class: UnsupportedClass,
    execution_supported: bool,
};

/// Instructions understood by the runner but excluded from the Stark-V proof statement.
pub const unsupported_entries = [_]UnsupportedEntry{
    .{ .mnemonic = "ecall", .class = .system, .execution_supported = true },
    .{ .mnemonic = "ebreak", .class = .system, .execution_supported = true },
    .{ .mnemonic = "fence", .class = .fence, .execution_supported = true },
    .{ .mnemonic = "fence.i", .class = .fence, .execution_supported = true },
    .{ .mnemonic = "lr.w", .class = .rv32a, .execution_supported = true },
    .{ .mnemonic = "sc.w", .class = .rv32a, .execution_supported = true },
    .{ .mnemonic = "amoswap.w", .class = .rv32a, .execution_supported = true },
    .{ .mnemonic = "amoadd.w", .class = .rv32a, .execution_supported = true },
    .{ .mnemonic = "amoand.w", .class = .rv32a, .execution_supported = true },
    .{ .mnemonic = "amoor.w", .class = .rv32a, .execution_supported = true },
    .{ .mnemonic = "amoxor.w", .class = .rv32a, .execution_supported = true },
    .{ .mnemonic = "amomin.w", .class = .rv32a, .execution_supported = true },
    .{ .mnemonic = "amomax.w", .class = .rv32a, .execution_supported = true },
    .{ .mnemonic = "amominu.w", .class = .rv32a, .execution_supported = true },
    .{ .mnemonic = "amomaxu.w", .class = .rv32a, .execution_supported = true },
};

pub const RejectionKind = enum {
    unsupported_instruction_class,
    invalid_instruction,
};

pub const RejectionVector = struct {
    name: []const u8,
    word: u32,
    kind: RejectionKind,
};

/// Canonical words that must fail before proof construction.
///
/// The first fifteen entries correspond one-for-one with
/// `unsupported_entries`. The remaining entries cover unsupported extension
/// primary opcodes and malformed encodings within otherwise admitted classes.
pub const proof_rejection_vectors = [_]RejectionVector{
    .{ .name = "ecall", .word = 0x00000073, .kind = .unsupported_instruction_class },
    .{ .name = "ebreak", .word = 0x00100073, .kind = .unsupported_instruction_class },
    .{ .name = "fence", .word = 0x0000000f, .kind = .unsupported_instruction_class },
    .{ .name = "fence.i", .word = 0x0000100f, .kind = .unsupported_instruction_class },
    .{ .name = "lr.w", .word = atomicWord(0b00010, 0), .kind = .unsupported_instruction_class },
    .{ .name = "sc.w", .word = atomicWord(0b00011, 3), .kind = .unsupported_instruction_class },
    .{ .name = "amoswap.w", .word = atomicWord(0b00001, 3), .kind = .unsupported_instruction_class },
    .{ .name = "amoadd.w", .word = atomicWord(0b00000, 3), .kind = .unsupported_instruction_class },
    .{ .name = "amoand.w", .word = atomicWord(0b01100, 3), .kind = .unsupported_instruction_class },
    .{ .name = "amoor.w", .word = atomicWord(0b01000, 3), .kind = .unsupported_instruction_class },
    .{ .name = "amoxor.w", .word = atomicWord(0b00100, 3), .kind = .unsupported_instruction_class },
    .{ .name = "amomin.w", .word = atomicWord(0b10000, 3), .kind = .unsupported_instruction_class },
    .{ .name = "amomax.w", .word = atomicWord(0b10100, 3), .kind = .unsupported_instruction_class },
    .{ .name = "amominu.w", .word = atomicWord(0b11000, 3), .kind = .unsupported_instruction_class },
    .{ .name = "amomaxu.w", .word = atomicWord(0b11100, 3), .kind = .unsupported_instruction_class },
    .{ .name = "csrrw", .word = 0x300110f3, .kind = .unsupported_instruction_class },
    .{ .name = "load-fp", .word = 0x00002087, .kind = .invalid_instruction },
    .{ .name = "store-fp", .word = 0x00112027, .kind = .invalid_instruction },
    .{ .name = "op-fp", .word = 0x003100d3, .kind = .invalid_instruction },
    .{ .name = "vector", .word = 0x02000057, .kind = .invalid_instruction },
    .{ .name = "compressed", .word = 0x00000001, .kind = .invalid_instruction },
    .{ .name = "custom-0", .word = 0x0000000b, .kind = .invalid_instruction },
    .{ .name = "r-type-reserved-funct7", .word = registerWord(0b0000010, 0), .kind = .invalid_instruction },
    .{ .name = "r-type-invalid-sub-shape", .word = registerWord(0b0100000, 1), .kind = .invalid_instruction },
    .{ .name = "load-reserved-funct3", .word = 0x00003083, .kind = .invalid_instruction },
    .{ .name = "store-reserved-funct3", .word = 0x00113023, .kind = .invalid_instruction },
    .{ .name = "branch-reserved-funct3", .word = 0x0020a063, .kind = .invalid_instruction },
    .{ .name = "invalid-primary-opcode", .word = 0x00000000, .kind = .invalid_instruction },
};

pub const PinnedPermissiveEncoding = struct {
    name: []const u8,
    word: u32,
    opcode: Opcode,
};

/// Reserved encodings accepted by the pinned Rust decoder.
///
/// These are parity constraints, not ISA endorsements. Rejecting them would
/// silently change the accepted statement while the Stark-V pin is unchanged.
pub const pinned_permissive_encodings = [_]PinnedPermissiveEncoding{
    .{ .name = "slli-reserved-funct7", .word = shiftWord(0b1111111, 31, 0b001), .opcode = .slli },
    .{ .name = "srli-reserved-funct7", .word = shiftWord(0b0000001, 3, 0b101), .opcode = .srli },
    .{ .name = "jalr-nonzero-funct3", .word = 0x001170e7, .opcode = .jalr },
};

fn atomicWord(funct5: u32, rs2: u32) u32 {
    return (funct5 << 27) | (rs2 << 20) | (2 << 15) | (0b010 << 12) | (1 << 7) | 0x2f;
}

fn registerWord(funct7: u32, funct3: u32) u32 {
    return (funct7 << 25) | (3 << 20) | (2 << 15) | (funct3 << 12) | (1 << 7) | 0x33;
}

fn shiftWord(funct7: u32, shamt: u32, funct3: u32) u32 {
    return (funct7 << 25) | (shamt << 20) | (2 << 15) | (funct3 << 12) | (1 << 7) | 0x13;
}

pub fn entry(opcode: Opcode) *const Entry {
    return &entries[@intFromEnum(opcode)];
}

pub fn family(opcode: Opcode) Family {
    return entry(opcode).family;
}

pub const ValidationError = error{
    ProtocolIdMismatch,
    MnemonicMismatch,
    RejectionManifestMismatch,
    DuplicateEncoding,
};

pub fn validate() ValidationError!void {
    if (entries.len != @typeInfo(Opcode).@"enum".fields.len) return error.ProtocolIdMismatch;
    inline for (entries, 0..) |item, expected_id| {
        if (item.opcode.protocolId() != expected_id) return error.ProtocolIdMismatch;
        if (!std.mem.eql(u8, item.mnemonic, @tagName(item.opcode))) return error.MnemonicMismatch;
    }
    if (proof_rejection_vectors.len < unsupported_entries.len)
        return error.RejectionManifestMismatch;
    inline for (unsupported_entries, 0..) |unsupported, index| {
        const rejected = proof_rejection_vectors[index];
        if (!std.mem.eql(u8, unsupported.mnemonic, rejected.name) or
            rejected.kind != .unsupported_instruction_class)
            return error.RejectionManifestMismatch;
    }
    inline for (proof_rejection_vectors, 0..) |lhs, lhs_index| {
        inline for (proof_rejection_vectors[lhs_index + 1 ..]) |rhs| {
            if (lhs.word == rhs.word) return error.DuplicateEncoding;
        }
    }
    inline for (pinned_permissive_encodings, 0..) |lhs, lhs_index| {
        inline for (pinned_permissive_encodings[lhs_index + 1 ..]) |rhs| {
            if (lhs.word == rhs.word) return error.DuplicateEncoding;
        }
        inline for (proof_rejection_vectors) |rejected| {
            if (lhs.word == rejected.word) return error.DuplicateEncoding;
        }
    }
}

test "opcode manifest is complete and indexed by pinned protocol id" {
    try validate();
    try std.testing.expectEqual(@as(usize, 45), entries.len);
    try std.testing.expectEqual(Family.base_alu_imm, family(.addi));
    try std.testing.expectEqual(Family.div, family(.remu));
}

test "execution-only instructions have no proof-family field" {
    try std.testing.expectEqual(@as(usize, 15), unsupported_entries.len);
    inline for (unsupported_entries) |item| {
        try std.testing.expect(item.execution_supported);
        try std.testing.expect(item.mnemonic.len != 0);
    }
}

test "opcode manifest owns a unique fail-closed decoder matrix" {
    try validate();
    try std.testing.expectEqual(@as(usize, 28), proof_rejection_vectors.len);
    try std.testing.expectEqual(@as(usize, 3), pinned_permissive_encodings.len);
}
