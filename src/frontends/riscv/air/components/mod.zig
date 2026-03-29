//! RISC-V AIR opcode-family component wiring.
//!
//! Re-exports all 16 opcode-family component modules so that callers can
//! access them via `components.base_alu_reg`, `components.load_store`, etc.

pub const base_alu_reg = @import("base_alu_reg.zig");
pub const base_alu_imm = @import("base_alu_imm.zig");
pub const shifts_reg = @import("shifts_reg.zig");
pub const shifts_imm = @import("shifts_imm.zig");
pub const lt_reg = @import("lt_reg.zig");
pub const lt_imm = @import("lt_imm.zig");
pub const branch_eq = @import("branch_eq.zig");
pub const branch_lt = @import("branch_lt.zig");
pub const lui = @import("lui.zig");
pub const auipc = @import("auipc.zig");
pub const jalr = @import("jalr.zig");
pub const jal = @import("jal.zig");
pub const load_store = @import("load_store.zig");
pub const mul_comp = @import("mul.zig");
pub const mulh = @import("mulh.zig");
pub const div_comp = @import("div.zig");

// ---- Infrastructure components ----
pub const program = @import("program.zig");
pub const memory_check = @import("memory_check.zig");
pub const clock_update = @import("clock_update.zig");

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
