//! Oracle-aligned register access ordering for RV32IM trace witnesses.

const decode = @import("decode.zig");
const state_chain = @import("state_chain.zig");

const DecodedInst = decode.DecodedInst;
const Opcode = decode.Opcode;

const Plan = struct {
    reads_rs1: bool,
    reads_rs2: bool,
    writes_rd: bool,
};

pub const Witness = struct {
    rs1_prev_clock: u32,
    rs2_prev_clock: u32,
    rd_prev_clock: u32,
    plan: Plan,

    pub fn recordRegisters(
        self: Witness,
        tracker: *state_chain.StateChainTracker,
        inst: DecodedInst,
        clock: u32,
        rs1_value: u32,
        rs2_value: u32,
        rd_previous_value: u32,
        rd_value: u32,
    ) !void {
        if (self.plan.reads_rs1) try tracker.recordRegAccess(inst.rs1, clock, rs1_value);
        if (self.plan.reads_rs2) try tracker.recordRegAccess(inst.rs2, clock, rs2_value);
        if (self.plan.writes_rd) {
            try tracker.recordRegTransition(
                inst.rd,
                clock,
                rd_previous_value,
                rd_value,
            );
        }
    }
};

/// Capture previous clocks in the same operand order as pinned Stark-V:
/// source reads first, followed by the destination write, all at one clock.
pub fn capture(
    tracker: *const state_chain.StateChainTracker,
    inst: DecodedInst,
    clock: u32,
) Witness {
    const plan = planFor(inst.opcode);
    const rs1_prev = state_chain.StateChainTracker.effectivePreviousClock(
        tracker.reg_last_clk[inst.rs1],
        clock,
    );
    const rs2_prev = if (plan.reads_rs1 and inst.rs2 == inst.rs1)
        clock
    else
        state_chain.StateChainTracker.effectivePreviousClock(
            tracker.reg_last_clk[inst.rs2],
            clock,
        );
    const rd_prev = if ((plan.reads_rs1 and inst.rd == inst.rs1) or
        (plan.reads_rs2 and inst.rd == inst.rs2))
        clock
    else
        state_chain.StateChainTracker.effectivePreviousClock(
            tracker.reg_last_clk[inst.rd],
            clock,
        );
    return .{
        .rs1_prev_clock = rs1_prev,
        .rs2_prev_clock = rs2_prev,
        .rd_prev_clock = rd_prev,
        .plan = plan,
    };
}

fn planFor(opcode: Opcode) Plan {
    return switch (opcode) {
        .ADD,
        .SUB,
        .XOR,
        .OR,
        .AND,
        .SLL,
        .SRL,
        .SRA,
        .SLT,
        .SLTU,
        .MUL,
        .MULH,
        .MULHSU,
        .MULHU,
        .DIV,
        .DIVU,
        .REM,
        .REMU,
        => .{ .reads_rs1 = true, .reads_rs2 = true, .writes_rd = true },

        .ADDI,
        .XORI,
        .ORI,
        .ANDI,
        .SLLI,
        .SRLI,
        .SRAI,
        .SLTI,
        .SLTIU,
        .LB,
        .LBU,
        .LH,
        .LHU,
        .LW,
        .JALR,
        => .{ .reads_rs1 = true, .reads_rs2 = false, .writes_rd = true },

        .SB,
        .SH,
        .SW,
        .BEQ,
        .BNE,
        .BLT,
        .BGE,
        .BLTU,
        .BGEU,
        => .{ .reads_rs1 = true, .reads_rs2 = true, .writes_rd = false },

        .LUI,
        .AUIPC,
        .JAL,
        => .{ .reads_rs1 = false, .reads_rs2 = false, .writes_rd = true },

        // RV32A is outside the release-gated RV32IM statement. Preserve its
        // executor bookkeeping without implying that its AIR is supported.
        .LR_W,
        .SC_W,
        .AMOSWAP_W,
        .AMOADD_W,
        .AMOAND_W,
        .AMOOR_W,
        .AMOXOR_W,
        .AMOMIN_W,
        .AMOMAX_W,
        .AMOMINU_W,
        .AMOMAXU_W,
        => .{ .reads_rs1 = true, .reads_rs2 = true, .writes_rd = true },

        .ECALL,
        .EBREAK,
        .FENCE,
        => .{ .reads_rs1 = false, .reads_rs2 = false, .writes_rd = false },
    };
}

test "access witness: aliased ADDI chains source before destination" {
    const std = @import("std");
    var tracker = state_chain.StateChainTracker.init(std.testing.allocator);
    defer tracker.deinit();
    tracker.reg_last_clk[1] = 7;

    const inst = try DecodedInst.decode(0x0010_8093); // ADDI x1, x1, 1
    const witness = capture(&tracker, inst, 8);
    try std.testing.expectEqual(@as(u32, 7), witness.rs1_prev_clock);
    try std.testing.expectEqual(@as(u32, 8), witness.rd_prev_clock);
    try witness.recordRegisters(&tracker, inst, 8, 5, 0, 5, 6);
    try std.testing.expectEqual(@as(usize, 2), tracker.accesses.items.len);
    try std.testing.expectEqual(@as(u32, 8), tracker.accesses.items[1].clk_prev);
}

test "access witness: store reads two sources and does not write rd" {
    const std = @import("std");
    var tracker = state_chain.StateChainTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const inst = try DecodedInst.decode(0x0011_2023); // SW x1, 0(x2)
    const witness = capture(&tracker, inst, 3);
    try witness.recordRegisters(&tracker, inst, 3, 0x100, 0x55, 0, 0);
    try std.testing.expectEqual(@as(usize, 2), tracker.accesses.items.len);
    try std.testing.expectEqual(@as(u32, 2), tracker.accesses.items[0].addr);
    try std.testing.expectEqual(@as(u32, 1), tracker.accesses.items[1].addr);
}
