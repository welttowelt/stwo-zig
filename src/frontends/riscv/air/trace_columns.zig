//! Trace table column definitions for the RISC-V AIR.
//!
//! Each struct defines the per-row column layout for one opcode family.
//! N_COLUMNS gives the trace width, used for memory allocation and
//! ExprEvaluator.nextTraceMask() call counts.
//!
//! Column ordering must match the order in which evaluate() reads them.
//!
//! Ported from stark-v's define_trace_tables! macro output.

const M31 = @import("../../../core/fields/m31.zig").M31;

/// Base ALU register-register: ADD, SUB, XOR, OR, AND.
pub const BaseAluRegColumns = struct {
    clk: M31,
    pc: M31,
    rd: M31,
    rs1: M31,
    rs2: M31,
    rd_val: M31,
    rs1_val: M31,
    rs2_val: M31,
    result: M31,
    is_add: M31,
    is_sub: M31,
    is_xor: M31,
    is_or: M31,
    is_and: M31,
    enabler: M31,
    instruction_word: M31,

    pub const N_COLUMNS: usize = 16;
};

/// Base ALU immediate: ADDI, XORI, ORI, ANDI.
pub const BaseAluImmColumns = struct {
    clk: M31,
    pc: M31,
    rd: M31,
    rs1: M31,
    imm: M31,
    rd_val: M31,
    rs1_val: M31,
    result: M31,
    is_addi: M31,
    is_xori: M31,
    is_ori: M31,
    is_andi: M31,
    enabler: M31,
    imm_sign: M31,
    instruction_word: M31,

    pub const N_COLUMNS: usize = 15;
};

/// Shifts register-register: SLL, SRL, SRA.
pub const ShiftsRegColumns = struct {
    clk: M31,
    pc: M31,
    rd: M31,
    rs1: M31,
    rs2: M31,
    rd_val: M31,
    rs1_val: M31,
    rs2_val: M31,
    result: M31,
    is_sll: M31,
    is_srl: M31,
    is_sra: M31,
    enabler: M31,
    shift_amount: M31,
    shift_amount_bound: M31,
    shifted_lo: M31,
    shifted_hi: M31,
    instruction_word: M31,

    pub const N_COLUMNS: usize = 18;
};

/// Shifts immediate: SLLI, SRLI, SRAI.
pub const ShiftsImmColumns = struct {
    clk: M31,
    pc: M31,
    rd: M31,
    rs1: M31,
    imm: M31,
    rd_val: M31,
    rs1_val: M31,
    result: M31,
    is_slli: M31,
    is_srli: M31,
    is_srai: M31,
    enabler: M31,
    shift_amount: M31,
    shift_amount_bound: M31,
    shifted_lo: M31,
    shifted_hi: M31,
    sign_bit: M31,
    instruction_word: M31,

    pub const N_COLUMNS: usize = 18;
};

/// Less-than register: SLT, SLTU.
pub const LtRegColumns = struct {
    clk: M31,
    pc: M31,
    rd: M31,
    rs1: M31,
    rs2: M31,
    rd_val: M31,
    rs1_val: M31,
    rs2_val: M31,
    result: M31,
    is_slt: M31,
    is_sltu: M31,
    enabler: M31,
    diff_lo: M31,
    diff_hi: M31,
    instruction_word: M31,

    pub const N_COLUMNS: usize = 15;
};

/// Less-than immediate: SLTI, SLTIU.
pub const LtImmColumns = struct {
    clk: M31,
    pc: M31,
    rd: M31,
    rs1: M31,
    imm: M31,
    rd_val: M31,
    rs1_val: M31,
    result: M31,
    is_slti: M31,
    is_sltiu: M31,
    enabler: M31,
    diff_lo: M31,
    diff_hi: M31,
    imm_sign: M31,
    instruction_word: M31,

    pub const N_COLUMNS: usize = 15;
};

/// Branch equal: BEQ, BNE.
pub const BranchEqColumns = struct {
    clk: M31,
    pc: M31,
    rs1: M31,
    rs2: M31,
    rs1_val: M31,
    rs2_val: M31,
    is_beq: M31,
    is_bne: M31,
    enabler: M31,
    branch_target: M31,
    diff: M31,
    diff_inv: M31,
    is_equal: M31,
    instruction_word: M31,

    pub const N_COLUMNS: usize = 14;
};

/// Branch less-than: BLT, BLTU, BGE, BGEU.
pub const BranchLtColumns = struct {
    clk: M31,
    pc: M31,
    rs1: M31,
    rs2: M31,
    rs1_val: M31,
    rs2_val: M31,
    is_blt: M31,
    is_bltu: M31,
    is_bge: M31,
    is_bgeu: M31,
    enabler: M31,
    branch_target: M31,
    diff_lo: M31,
    diff_hi: M31,
    is_less_than: M31,
    instruction_word: M31,

    pub const N_COLUMNS: usize = 16;
};

/// LUI (load upper immediate).
pub const LuiColumns = struct {
    clk: M31,
    pc: M31,
    rd: M31,
    rd_val: M31,
    imm_u: M31,
    result: M31,
    enabler: M31,
    result_lo: M31,
    result_hi: M31,
    instruction_word: M31,

    pub const N_COLUMNS: usize = 10;
};

/// AUIPC (add upper immediate to PC).
pub const AuipcColumns = struct {
    clk: M31,
    pc: M31,
    rd: M31,
    rd_val: M31,
    imm_u: M31,
    result: M31,
    enabler: M31,
    result_lo: M31,
    result_hi: M31,
    instruction_word: M31,

    pub const N_COLUMNS: usize = 10;
};

/// JALR (jump and link register).
pub const JalrColumns = struct {
    clk: M31,
    pc: M31,
    rd: M31,
    rs1: M31,
    imm: M31,
    rd_val: M31,
    rs1_val: M31,
    target: M31,
    enabler: M31,
    target_lo: M31,
    target_hi: M31,
    instruction_word: M31,

    pub const N_COLUMNS: usize = 12;
};

/// JAL (jump and link).
pub const JalColumns = struct {
    clk: M31,
    pc: M31,
    rd: M31,
    rd_val: M31,
    imm_j: M31,
    target: M31,
    enabler: M31,
    target_lo: M31,
    target_hi: M31,
    instruction_word: M31,

    pub const N_COLUMNS: usize = 10;
};

/// Load/Store: LB, LBU, LH, LHU, LW, SB, SH, SW.
pub const LoadStoreColumns = struct {
    clk: M31,
    pc: M31,
    rd: M31,
    rs1: M31,
    rs2: M31,
    imm: M31,
    rd_val: M31,
    rs1_val: M31,
    rs2_val: M31,
    mem_addr: M31,
    mem_val: M31,
    is_lb: M31,
    is_lbu: M31,
    is_lh: M31,
    is_lhu: M31,
    is_lw: M31,
    is_sb: M31,
    is_sh: M31,
    is_sw: M31,
    enabler: M31,
    byte_0: M31,
    byte_1: M31,
    byte_2: M31,
    byte_3: M31,
    instruction_word: M31,

    pub const N_COLUMNS: usize = 25;
};

/// MUL (multiply low 32 bits).
pub const MulColumns = struct {
    clk: M31,
    pc: M31,
    rd: M31,
    rs1: M31,
    rs2: M31,
    rd_val: M31,
    rs1_val: M31,
    rs2_val: M31,
    result: M31,
    enabler: M31,
    prod_lo: M31,
    prod_hi: M31,
    carry: M31,
    instruction_word: M31,

    pub const N_COLUMNS: usize = 14;
};

/// MULH variants: MULH, MULHSU, MULHU.
pub const MulhColumns = struct {
    clk: M31,
    pc: M31,
    rd: M31,
    rs1: M31,
    rs2: M31,
    rd_val: M31,
    rs1_val: M31,
    rs2_val: M31,
    result: M31,
    is_mulh: M31,
    is_mulhsu: M31,
    is_mulhu: M31,
    enabler: M31,
    prod_lo: M31,
    prod_hi: M31,
    rs1_sign: M31,
    rs2_sign: M31,
    instruction_word: M31,

    pub const N_COLUMNS: usize = 18;
};

/// DIV/REM: DIV, DIVU, REM, REMU.
pub const DivColumns = struct {
    clk: M31,
    pc: M31,
    rd: M31,
    rs1: M31,
    rs2: M31,
    rd_val: M31,
    rs1_val: M31,
    rs2_val: M31,
    result: M31,
    is_div: M31,
    is_divu: M31,
    is_rem: M31,
    is_remu: M31,
    enabler: M31,
    quotient: M31,
    remainder: M31,
    rs2_is_zero: M31,
    rs1_sign: M31,
    rs2_sign: M31,
    instruction_word: M31,

    pub const N_COLUMNS: usize = 20;
};

/// Program ROM: verifies fetched instructions match the committed program.
pub const ProgramColumns = struct {
    pc: M31,
    instruction_word: M31,
    enabler: M31,

    pub const N_COLUMNS: usize = 3;
};

/// Memory integrity check: clock-ordered memory access consistency.
pub const MemoryCheckColumns = struct {
    addr_space: M31,
    addr: M31,
    clk: M31,
    limb_0: M31,
    limb_1: M31,
    limb_2: M31,
    limb_3: M31,
    prev_clk: M31,
    clk_diff: M31,
    is_first_access: M31,
    is_write: M31,
    enabler: M31,

    pub const N_COLUMNS: usize = 12;
};

/// Clock gap-filling: intermediate dummy accesses for large clock gaps.
pub const ClockUpdateColumns = struct {
    addr_space: M31,
    addr: M31,
    clk: M31,
    prev_clk: M31,
    clk_diff: M31,
    enabler: M31,

    pub const N_COLUMNS: usize = 6;
};

test "column counts match struct field counts" {
    const std = @import("std");
    const expectEqual = std.testing.expectEqual;

    try expectEqual(@as(usize, 16), @typeInfo(BaseAluRegColumns).@"struct".fields.len);
    try expectEqual(@as(usize, 15), @typeInfo(BaseAluImmColumns).@"struct".fields.len);
    try expectEqual(@as(usize, 18), @typeInfo(ShiftsRegColumns).@"struct".fields.len);
    try expectEqual(@as(usize, 18), @typeInfo(ShiftsImmColumns).@"struct".fields.len);
    try expectEqual(@as(usize, 15), @typeInfo(LtRegColumns).@"struct".fields.len);
    try expectEqual(@as(usize, 15), @typeInfo(LtImmColumns).@"struct".fields.len);
    try expectEqual(@as(usize, 14), @typeInfo(BranchEqColumns).@"struct".fields.len);
    try expectEqual(@as(usize, 16), @typeInfo(BranchLtColumns).@"struct".fields.len);
    try expectEqual(@as(usize, 10), @typeInfo(LuiColumns).@"struct".fields.len);
    try expectEqual(@as(usize, 10), @typeInfo(AuipcColumns).@"struct".fields.len);
    try expectEqual(@as(usize, 12), @typeInfo(JalrColumns).@"struct".fields.len);
    try expectEqual(@as(usize, 10), @typeInfo(JalColumns).@"struct".fields.len);
    try expectEqual(@as(usize, 25), @typeInfo(LoadStoreColumns).@"struct".fields.len);
    try expectEqual(@as(usize, 14), @typeInfo(MulColumns).@"struct".fields.len);
    try expectEqual(@as(usize, 18), @typeInfo(MulhColumns).@"struct".fields.len);
    try expectEqual(@as(usize, 20), @typeInfo(DivColumns).@"struct".fields.len);
    try expectEqual(@as(usize, 3), @typeInfo(ProgramColumns).@"struct".fields.len);
    try expectEqual(@as(usize, 12), @typeInfo(MemoryCheckColumns).@"struct".fields.len);
    try expectEqual(@as(usize, 6), @typeInfo(ClockUpdateColumns).@"struct".fields.len);
}
