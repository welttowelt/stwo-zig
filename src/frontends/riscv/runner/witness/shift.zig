//! Exact hot-one shift witnesses from the pinned Stark-V runner.

const w = @import("writer.zig");

const Shift = struct {
    sign: u32,
    bit_markers: [8]u32,
    limb_markers: [4]u32,
    carries: [4]u32,
};

fn compute(value: u32, amount: u5, left: bool, arithmetic: bool) Shift {
    const bit_shift: u3 = @truncate(amount);
    const limb_shift: u2 = @truncate(amount >> 3);
    var result = Shift{
        .sign = if (arithmetic) value >> 31 else 0,
        .bit_markers = .{0} ** 8,
        .limb_markers = .{0} ** 4,
        .carries = .{0} ** 4,
    };
    result.bit_markers[bit_shift] = 1;
    result.limb_markers[limb_shift] = 1;
    for (0..4) |i| {
        const byte: u8 = @truncate(value >> @intCast(8 * i));
        result.carries[i] = if (bit_shift == 0)
            0
        else if (left)
            @as(u32, byte) >> @intCast(8 - @as(u4, bit_shift))
        else
            @as(u32, byte) & ((@as(u32, 1) << bit_shift) - 1);
    }
    return result;
}

fn suffix(columns: anytype, index: usize, start: usize, row: anytype, amount: u5) void {
    const left = row.opcode == .SLL or row.opcode == .SLLI;
    const arithmetic = row.opcode == .SRA or row.opcode == .SRAI;
    const witness = compute(row.rs1_val, amount, left, arithmetic);
    const multiplier = @as(u32, 1) << @truncate(amount);
    w.set(columns, index, start, w.u(witness.sign));
    w.set(columns, index, start + 1, w.bit(left));
    w.set(columns, index, start + 2, w.bit(!left and !arithmetic));
    w.set(columns, index, start + 3, w.bit(arithmetic));
    w.set(columns, index, start + 4, w.u(if (left) multiplier else 0));
    w.set(columns, index, start + 5, w.u(if (left) 0 else multiplier));
    for (witness.bit_markers, 0..) |marker, i| w.set(columns, index, start + 6 + i, w.u(marker));
    for (witness.limb_markers, 0..) |marker, i| w.set(columns, index, start + 14 + i, w.u(marker));
    for (witness.carries, 0..) |carry, i| w.set(columns, index, start + 18 + i, w.u(carry));
}

pub fn reg(columns: anytype, index: usize, row: anytype) void {
    w.common(columns, index, 0, row);
    w.rd(columns, index, 2, row);
    w.rs1(columns, index, 12, row);
    w.rs2(columns, index, 22, row);
    suffix(columns, index, 32, row, @truncate(row.rs2_val));
}

pub fn immediate(columns: anytype, index: usize, row: anytype) void {
    const amount: u5 = @truncate(@as(u32, @bitCast(row.imm)));
    w.common(columns, index, 0, row);
    w.rd(columns, index, 2, row);
    w.rs1(columns, index, 12, row);
    w.set(columns, index, 22, w.u(if (row.opcode == .SRAI) row.rs1_val >> 31 else 0));
    w.set(columns, index, 23, w.u(amount));
    // `suffix` includes rs1_sign, so write its remaining fields shifted by one.
    const left = row.opcode == .SLLI;
    const arithmetic = row.opcode == .SRAI;
    const witness = compute(row.rs1_val, amount, left, arithmetic);
    const multiplier = @as(u32, 1) << @truncate(amount);
    w.set(columns, index, 24, w.bit(left));
    w.set(columns, index, 25, w.bit(!left and !arithmetic));
    w.set(columns, index, 26, w.bit(arithmetic));
    w.set(columns, index, 27, w.u(if (left) multiplier else 0));
    w.set(columns, index, 28, w.u(if (left) 0 else multiplier));
    for (witness.bit_markers, 0..) |marker, i| w.set(columns, index, 29 + i, w.u(marker));
    for (witness.limb_markers, 0..) |marker, i| w.set(columns, index, 37 + i, w.u(marker));
    for (witness.carries, 0..) |carry, i| w.set(columns, index, 41 + i, w.u(carry));
}
