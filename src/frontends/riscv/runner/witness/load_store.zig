//! Exact load/store role-separated witness.

const w = @import("writer.zig");

pub fn fill(columns: anytype, index: usize, row: anytype) void {
    w.common(columns, index, 0, row);
    w.loadStoreDst(columns, index, 2, row);
    w.rs1(columns, index, 12, row);
    w.loadStoreSrc(columns, index, 22, row);

    const byte_op = row.opcode == .LB or row.opcode == .LBU or row.opcode == .SB;
    const half_op = row.opcode == .LH or row.opcode == .LHU or row.opcode == .SH;
    const offset = row.mem_addr & 3;
    const shift = if (byte_op) offset else if (half_op) offset & 2 else 0;
    const r2 = if (row.is_load) @as(u32, row.rd) else @as(u32, row.rs2);
    const aligned = row.mem_addr -% shift;
    const src_selector = if (row.is_load) aligned else r2;
    const dst_selector = if (row.is_load) r2 else aligned;
    const selected_msb: u32 = if (row.opcode == .LB)
        (row.rd_val >> 31) & 1
    else if (row.opcode == .LH)
        (row.rd_val >> 31) & 1
    else if (row.opcode == .SB)
        (row.rs2_val >> 7) & 1
    else if (row.opcode == .SH)
        (row.rs2_val >> 15) & 1
    else
        (if (row.is_load) row.mem_next_word else row.rs2_val) >> 31;

    w.set(columns, index, 32, w.u(r2));
    w.set(columns, index, 33, w.signed(row.imm));
    w.set(columns, index, 34, w.u(selected_msb));
    w.set(columns, index, 35, w.u(shift));
    w.set(columns, index, 36, w.u(src_selector));
    w.set(columns, index, 37, w.u(dst_selector));
    for (0..4) |limb| {
        const marked = if (byte_op)
            limb == offset
        else if (half_op)
            (offset < 2 and limb < 2) or (offset >= 2 and limb >= 2)
        else
            false;
        w.set(columns, index, 38 + limb, w.bit(marked));
    }
    const flags = [_]bool{
        row.opcode == .LB, row.opcode == .LH, row.opcode == .LBU, row.opcode == .LHU,
        row.opcode == .LW, row.opcode == .SB, row.opcode == .SH,  row.opcode == .SW,
    };
    for (flags, 0..) |flag, i| w.set(columns, index, 42 + i, w.bit(flag));
}
