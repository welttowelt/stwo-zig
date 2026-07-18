//! Exact base ALU committed witnesses.

const w = @import("writer.zig");

pub fn reg(columns: anytype, index: usize, row: anytype) void {
    w.common(columns, index, 0, row);
    w.rd(columns, index, 2, row);
    w.rs1(columns, index, 12, row);
    w.rs2(columns, index, 22, row);
    const flags = [_]bool{
        row.opcode == .ADD, row.opcode == .SUB, row.opcode == .XOR,
        row.opcode == .OR,  row.opcode == .AND,
    };
    for (flags, 0..) |flag, i| w.set(columns, index, 32 + i, w.bit(flag));
}

pub fn immediate(columns: anytype, index: usize, row: anytype) void {
    w.common(columns, index, 0, row);
    w.rd(columns, index, 2, row);
    w.rs1(columns, index, 12, row);
    const bits: u32 = @bitCast(row.imm);
    w.set(columns, index, 22, w.u(bits & 0xff));
    w.set(columns, index, 23, w.u((bits >> 8) & 0x7));
    w.set(columns, index, 24, w.u((bits >> 11) & 1));
    const flags = [_]bool{
        row.opcode == .ADDI, row.opcode == .XORI,
        row.opcode == .ORI,  row.opcode == .ANDI,
    };
    for (flags, 0..) |flag, i| w.set(columns, index, 25 + i, w.bit(flag));
}
