//! Exact upper-immediate and jump witnesses.

const w = @import("writer.zig");

fn leading(columns: anytype, index: usize, row: anytype) void {
    w.set(columns, index, 0, w.u(1));
    w.common(columns, index, 1, row);
    w.rd(columns, index, 3, row);
}

pub fn lui(columns: anytype, index: usize, row: anytype) void {
    leading(columns, index, row);
    const immediate = row.rd_val >> 12;
    w.set(columns, index, 13, w.u(immediate & 0xf));
    w.set(columns, index, 14, w.u((immediate >> 4) & 0xff));
    w.set(columns, index, 15, w.u(immediate >> 12));
}

pub fn auipc(columns: anytype, index: usize, row: anytype) void {
    leading(columns, index, row);
    w.set(columns, index, 13, w.signed(row.imm));
}

pub fn jal(columns: anytype, index: usize, row: anytype) void {
    leading(columns, index, row);
    w.set(columns, index, 13, w.signed(row.imm));
}

pub fn jalr(columns: anytype, index: usize, row: anytype) void {
    leading(columns, index, row);
    w.rs1(columns, index, 13, row);
    const unaligned = row.rs1_val +% @as(u32, @bitCast(row.imm));
    w.set(columns, index, 23, w.u((unaligned & ~@as(u32, 1)) / 2));
    w.set(columns, index, 24, w.u(unaligned & 1));
    w.set(columns, index, 25, w.signed(row.imm));
}
