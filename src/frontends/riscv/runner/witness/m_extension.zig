//! M-extension witness generation pending exact production AIR placement.

const std = @import("std");
const w = @import("writer.zig");

pub fn mul(columns: anytype, index: usize, row: anytype) void {
    w.common(columns, index, 0, row);
    w.set(columns, index, 2, w.u(1));
    w.rd(columns, index, 3, row);
    w.rs1(columns, index, 13, row);
    w.rs2(columns, index, 23, row);
}

pub fn mulh(columns: anytype, index: usize, row: anytype) void {
    const product = @as(u64, row.rs1_val) *% @as(u64, row.rs2_val);
    w.common(columns, index, 0, row);
    w.set(columns, index, 2, w.bit(row.opcode == .MULH));
    w.set(columns, index, 3, w.bit(row.opcode == .MULHSU));
    w.set(columns, index, 4, w.bit(row.opcode == .MULHU));
    w.set(columns, index, 5, w.u(1));
    w.set(columns, index, 6, w.u(@as(u32, @truncate(product)) & 0xffff));
    w.set(columns, index, 7, w.u(@as(u32, @truncate(product >> 16))));
    w.set(columns, index, 8, w.u(row.rs1_val >> 31));
    w.set(columns, index, 9, w.u(row.rs2_val >> 31));
    w.set(columns, index, 10, w.u(@as(u32, @truncate(product >> 32))));
    w.rd(columns, index, 11, row);
    w.rs1(columns, index, 21, row);
    w.rs2(columns, index, 31, row);
}

fn divResult(row: anytype) struct { quotient: u32, remainder: u32 } {
    if (row.rs2_val == 0) return .{ .quotient = 0, .remainder = row.rs1_val };
    return switch (row.opcode) {
        .DIV, .REM => blk: {
            const lhs: i32 = @bitCast(row.rs1_val);
            const rhs: i32 = @bitCast(row.rs2_val);
            if (lhs == std.math.minInt(i32) and rhs == -1)
                break :blk .{ .quotient = @bitCast(lhs), .remainder = 0 };
            break :blk .{ .quotient = @bitCast(@divTrunc(lhs, rhs)), .remainder = @bitCast(@rem(lhs, rhs)) };
        },
        .DIVU, .REMU => .{ .quotient = row.rs1_val / row.rs2_val, .remainder = row.rs1_val % row.rs2_val },
        else => unreachable,
    };
}

pub fn div(columns: anytype, index: usize, row: anytype) void {
    const result = divResult(row);
    w.common(columns, index, 0, row);
    w.set(columns, index, 2, w.bit(row.opcode == .DIV));
    w.set(columns, index, 3, w.bit(row.opcode == .DIVU));
    w.set(columns, index, 4, w.bit(row.opcode == .REM));
    w.set(columns, index, 5, w.bit(row.opcode == .REMU));
    w.set(columns, index, 6, w.u(1));
    for (w.limbs(result.quotient), 0..) |limb, i| w.set(columns, index, 7 + i, limb);
    for (w.limbs(result.remainder), 0..) |limb, i| w.set(columns, index, 11 + i, limb);
    w.set(columns, index, 15, w.bit(row.rs2_val == 0));
    w.set(columns, index, 16, w.u(row.rs1_val >> 31));
    w.set(columns, index, 17, w.u(row.rs2_val >> 31));
    for (18..35) |column| w.set(columns, index, column, w.u(0));
    w.rd(columns, index, 35, row);
    w.rs1(columns, index, 45, row);
    w.rs2(columns, index, 55, row);
}
