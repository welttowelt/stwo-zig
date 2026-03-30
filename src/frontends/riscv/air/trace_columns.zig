//! Trace table column definitions for the RISC-V AIR.
//!
//! Each struct defines the per-row column layout for one opcode family.
//! N_COLUMNS gives the trace width, used for memory allocation and
//! ExprEvaluator.nextTraceMask() call counts.
//!
//! Column ordering must match the order in which evaluate() reads them.
//!
//! Ported from stark-v's define_trace_tables! macro output.
//!
//! Each register access is expanded into 10 columns following stark-v:
//!   addr, prev_0..prev_3, clk_prev, next_0..next_3
//! where prev/next are 4-byte limbs of the register value before/after.

const M31 = @import("../../../core/fields/m31.zig").M31;

/// Base ALU register-register: ADD, SUB, XOR, OR, AND.
/// 7 common + 3x10 register accesses = 37
pub const BaseAluRegColumns = struct {
    // Common (7)
    clk: M31,
    pc: M31,
    is_add: M31,
    is_sub: M31,
    is_xor: M31,
    is_or: M31,
    is_and: M31,
    // rd access (10)
    rd_addr: M31,
    rd_prev_0: M31,
    rd_prev_1: M31,
    rd_prev_2: M31,
    rd_prev_3: M31,
    rd_clk_prev: M31,
    rd_next_0: M31,
    rd_next_1: M31,
    rd_next_2: M31,
    rd_next_3: M31,
    // rs1 access (10)
    rs1_addr: M31,
    rs1_prev_0: M31,
    rs1_prev_1: M31,
    rs1_prev_2: M31,
    rs1_prev_3: M31,
    rs1_clk_prev: M31,
    rs1_next_0: M31,
    rs1_next_1: M31,
    rs1_next_2: M31,
    rs1_next_3: M31,
    // rs2 access (10)
    rs2_addr: M31,
    rs2_prev_0: M31,
    rs2_prev_1: M31,
    rs2_prev_2: M31,
    rs2_prev_3: M31,
    rs2_clk_prev: M31,
    rs2_next_0: M31,
    rs2_next_1: M31,
    rs2_next_2: M31,
    rs2_next_3: M31,

    pub const N_COLUMNS: usize = @typeInfo(@This()).@"struct".fields.len;
};

/// Base ALU immediate: ADDI, XORI, ORI, ANDI.
/// 9 common + 2x10 register accesses = 29
pub const BaseAluImmColumns = struct {
    // Common (9)
    clk: M31,
    pc: M31,
    is_addi: M31,
    is_xori: M31,
    is_ori: M31,
    is_andi: M31,
    imm: M31,
    imm_sign: M31,
    enabler: M31,
    // rd access (10)
    rd_addr: M31,
    rd_prev_0: M31,
    rd_prev_1: M31,
    rd_prev_2: M31,
    rd_prev_3: M31,
    rd_clk_prev: M31,
    rd_next_0: M31,
    rd_next_1: M31,
    rd_next_2: M31,
    rd_next_3: M31,
    // rs1 access (10)
    rs1_addr: M31,
    rs1_prev_0: M31,
    rs1_prev_1: M31,
    rs1_prev_2: M31,
    rs1_prev_3: M31,
    rs1_clk_prev: M31,
    rs1_next_0: M31,
    rs1_next_1: M31,
    rs1_next_2: M31,
    rs1_next_3: M31,

    pub const N_COLUMNS: usize = @typeInfo(@This()).@"struct".fields.len;
};

/// Shifts register-register: SLL, SRL, SRA.
/// 24 common/decomposition + 3x10 register accesses = 54
pub const ShiftsRegColumns = struct {
    // Common (6)
    clk: M31,
    pc: M31,
    is_sll: M31,
    is_srl: M31,
    is_sra: M31,
    enabler: M31,
    // Shift decomposition (18)
    shift_amount: M31,
    shift_amount_bound: M31,
    shifted_lo: M31,
    shifted_hi: M31,
    shift_bit_0: M31,
    shift_bit_1: M31,
    shift_bit_2: M31,
    shift_bit_3: M31,
    shift_bit_4: M31,
    shift_mask_lo: M31,
    shift_mask_hi: M31,
    sign_bit: M31,
    sign_extend_lo: M31,
    sign_extend_hi: M31,
    result_lo: M31,
    result_hi: M31,
    carry: M31,
    overflow: M31,
    // rd access (10)
    rd_addr: M31,
    rd_prev_0: M31,
    rd_prev_1: M31,
    rd_prev_2: M31,
    rd_prev_3: M31,
    rd_clk_prev: M31,
    rd_next_0: M31,
    rd_next_1: M31,
    rd_next_2: M31,
    rd_next_3: M31,
    // rs1 access (10)
    rs1_addr: M31,
    rs1_prev_0: M31,
    rs1_prev_1: M31,
    rs1_prev_2: M31,
    rs1_prev_3: M31,
    rs1_clk_prev: M31,
    rs1_next_0: M31,
    rs1_next_1: M31,
    rs1_next_2: M31,
    rs1_next_3: M31,
    // rs2 access (10)
    rs2_addr: M31,
    rs2_prev_0: M31,
    rs2_prev_1: M31,
    rs2_prev_2: M31,
    rs2_prev_3: M31,
    rs2_clk_prev: M31,
    rs2_next_0: M31,
    rs2_next_1: M31,
    rs2_next_2: M31,
    rs2_next_3: M31,

    pub const N_COLUMNS: usize = @typeInfo(@This()).@"struct".fields.len;
};

/// Shifts immediate: SLLI, SRLI, SRAI.
/// 25 common/decomposition + 2x10 register accesses = 45
pub const ShiftsImmColumns = struct {
    // Common (7)
    clk: M31,
    pc: M31,
    is_slli: M31,
    is_srli: M31,
    is_srai: M31,
    enabler: M31,
    imm: M31,
    // Shift decomposition (18)
    shift_amount: M31,
    shift_amount_bound: M31,
    shifted_lo: M31,
    shifted_hi: M31,
    shift_bit_0: M31,
    shift_bit_1: M31,
    shift_bit_2: M31,
    shift_bit_3: M31,
    shift_bit_4: M31,
    shift_mask_lo: M31,
    shift_mask_hi: M31,
    sign_bit: M31,
    sign_extend_lo: M31,
    sign_extend_hi: M31,
    result_lo: M31,
    result_hi: M31,
    carry: M31,
    overflow: M31,
    // rd access (10)
    rd_addr: M31,
    rd_prev_0: M31,
    rd_prev_1: M31,
    rd_prev_2: M31,
    rd_prev_3: M31,
    rd_clk_prev: M31,
    rd_next_0: M31,
    rd_next_1: M31,
    rd_next_2: M31,
    rd_next_3: M31,
    // rs1 access (10)
    rs1_addr: M31,
    rs1_prev_0: M31,
    rs1_prev_1: M31,
    rs1_prev_2: M31,
    rs1_prev_3: M31,
    rs1_clk_prev: M31,
    rs1_next_0: M31,
    rs1_next_1: M31,
    rs1_next_2: M31,
    rs1_next_3: M31,

    pub const N_COLUMNS: usize = @typeInfo(@This()).@"struct".fields.len;
};

/// Less-than register: SLT, SLTU.
/// 12 common/decomposition + 3x10 register accesses = 42
pub const LtRegColumns = struct {
    // Common (5)
    clk: M31,
    pc: M31,
    is_slt: M31,
    is_sltu: M31,
    enabler: M31,
    // Comparison decomposition (7)
    diff_lo: M31,
    diff_hi: M31,
    rs1_sign: M31,
    rs2_sign: M31,
    is_less_than: M31,
    borrow: M31,
    result: M31,
    // rd access (10)
    rd_addr: M31,
    rd_prev_0: M31,
    rd_prev_1: M31,
    rd_prev_2: M31,
    rd_prev_3: M31,
    rd_clk_prev: M31,
    rd_next_0: M31,
    rd_next_1: M31,
    rd_next_2: M31,
    rd_next_3: M31,
    // rs1 access (10)
    rs1_addr: M31,
    rs1_prev_0: M31,
    rs1_prev_1: M31,
    rs1_prev_2: M31,
    rs1_prev_3: M31,
    rs1_clk_prev: M31,
    rs1_next_0: M31,
    rs1_next_1: M31,
    rs1_next_2: M31,
    rs1_next_3: M31,
    // rs2 access (10)
    rs2_addr: M31,
    rs2_prev_0: M31,
    rs2_prev_1: M31,
    rs2_prev_2: M31,
    rs2_prev_3: M31,
    rs2_clk_prev: M31,
    rs2_next_0: M31,
    rs2_next_1: M31,
    rs2_next_2: M31,
    rs2_next_3: M31,

    pub const N_COLUMNS: usize = @typeInfo(@This()).@"struct".fields.len;
};

/// Less-than immediate: SLTI, SLTIU.
/// 14 common/decomposition + 2x10 register accesses = 34
pub const LtImmColumns = struct {
    // Common (7)
    clk: M31,
    pc: M31,
    is_slti: M31,
    is_sltiu: M31,
    enabler: M31,
    imm: M31,
    imm_sign: M31,
    // Comparison decomposition (7)
    diff_lo: M31,
    diff_hi: M31,
    rs1_sign: M31,
    is_less_than: M31,
    borrow: M31,
    result: M31,
    imm_ext: M31,
    // rd access (10)
    rd_addr: M31,
    rd_prev_0: M31,
    rd_prev_1: M31,
    rd_prev_2: M31,
    rd_prev_3: M31,
    rd_clk_prev: M31,
    rd_next_0: M31,
    rd_next_1: M31,
    rd_next_2: M31,
    rd_next_3: M31,
    // rs1 access (10)
    rs1_addr: M31,
    rs1_prev_0: M31,
    rs1_prev_1: M31,
    rs1_prev_2: M31,
    rs1_prev_3: M31,
    rs1_clk_prev: M31,
    rs1_next_0: M31,
    rs1_next_1: M31,
    rs1_next_2: M31,
    rs1_next_3: M31,

    pub const N_COLUMNS: usize = @typeInfo(@This()).@"struct".fields.len;
};

/// Branch equal: BEQ, BNE.
/// 10 common + 2x10 register accesses = 30
pub const BranchEqColumns = struct {
    // Common (10)
    clk: M31,
    pc: M31,
    is_beq: M31,
    is_bne: M31,
    enabler: M31,
    branch_target: M31,
    diff: M31,
    diff_inv: M31,
    is_equal: M31,
    branch_target_aux: M31,
    // rs1 access (10)
    rs1_addr: M31,
    rs1_prev_0: M31,
    rs1_prev_1: M31,
    rs1_prev_2: M31,
    rs1_prev_3: M31,
    rs1_clk_prev: M31,
    rs1_next_0: M31,
    rs1_next_1: M31,
    rs1_next_2: M31,
    rs1_next_3: M31,
    // rs2 access (10)
    rs2_addr: M31,
    rs2_prev_0: M31,
    rs2_prev_1: M31,
    rs2_prev_2: M31,
    rs2_prev_3: M31,
    rs2_clk_prev: M31,
    rs2_next_0: M31,
    rs2_next_1: M31,
    rs2_next_2: M31,
    rs2_next_3: M31,

    pub const N_COLUMNS: usize = @typeInfo(@This()).@"struct".fields.len;
};

/// Branch less-than: BLT, BLTU, BGE, BGEU.
/// 17 common/decomposition + 2x10 register accesses = 37
pub const BranchLtColumns = struct {
    // Common (8)
    clk: M31,
    pc: M31,
    is_blt: M31,
    is_bltu: M31,
    is_bge: M31,
    is_bgeu: M31,
    enabler: M31,
    branch_target: M31,
    // Comparison/branch decomposition (9)
    diff_lo: M31,
    diff_hi: M31,
    rs1_sign: M31,
    rs2_sign: M31,
    is_less_than: M31,
    borrow: M31,
    branch_target_lo: M31,
    branch_target_hi: M31,
    branch_target_aux: M31,
    // rs1 access (10)
    rs1_addr: M31,
    rs1_prev_0: M31,
    rs1_prev_1: M31,
    rs1_prev_2: M31,
    rs1_prev_3: M31,
    rs1_clk_prev: M31,
    rs1_next_0: M31,
    rs1_next_1: M31,
    rs1_next_2: M31,
    rs1_next_3: M31,
    // rs2 access (10)
    rs2_addr: M31,
    rs2_prev_0: M31,
    rs2_prev_1: M31,
    rs2_prev_2: M31,
    rs2_prev_3: M31,
    rs2_clk_prev: M31,
    rs2_next_0: M31,
    rs2_next_1: M31,
    rs2_next_2: M31,
    rs2_next_3: M31,

    pub const N_COLUMNS: usize = @typeInfo(@This()).@"struct".fields.len;
};

/// LUI (load upper immediate).
/// 6 common + 1x10 register access = 16
pub const LuiColumns = struct {
    // Common (6)
    clk: M31,
    pc: M31,
    imm_u: M31,
    enabler: M31,
    result_lo: M31,
    result_hi: M31,
    // rd access (10)
    rd_addr: M31,
    rd_prev_0: M31,
    rd_prev_1: M31,
    rd_prev_2: M31,
    rd_prev_3: M31,
    rd_clk_prev: M31,
    rd_next_0: M31,
    rd_next_1: M31,
    rd_next_2: M31,
    rd_next_3: M31,

    pub const N_COLUMNS: usize = @typeInfo(@This()).@"struct".fields.len;
};

/// AUIPC (add upper immediate to PC).
/// 4 common + 1x10 register access = 14
pub const AuipcColumns = struct {
    // Common (4)
    clk: M31,
    pc: M31,
    imm_u: M31,
    enabler: M31,
    // rd access (10)
    rd_addr: M31,
    rd_prev_0: M31,
    rd_prev_1: M31,
    rd_prev_2: M31,
    rd_prev_3: M31,
    rd_clk_prev: M31,
    rd_next_0: M31,
    rd_next_1: M31,
    rd_next_2: M31,
    rd_next_3: M31,

    pub const N_COLUMNS: usize = @typeInfo(@This()).@"struct".fields.len;
};

/// JALR (jump and link register).
/// 6 common + 2x10 register accesses = 26
pub const JalrColumns = struct {
    // Common (6)
    clk: M31,
    pc: M31,
    imm: M31,
    enabler: M31,
    target_lo: M31,
    target_hi: M31,
    // rd access (10)
    rd_addr: M31,
    rd_prev_0: M31,
    rd_prev_1: M31,
    rd_prev_2: M31,
    rd_prev_3: M31,
    rd_clk_prev: M31,
    rd_next_0: M31,
    rd_next_1: M31,
    rd_next_2: M31,
    rd_next_3: M31,
    // rs1 access (10)
    rs1_addr: M31,
    rs1_prev_0: M31,
    rs1_prev_1: M31,
    rs1_prev_2: M31,
    rs1_prev_3: M31,
    rs1_clk_prev: M31,
    rs1_next_0: M31,
    rs1_next_1: M31,
    rs1_next_2: M31,
    rs1_next_3: M31,

    pub const N_COLUMNS: usize = @typeInfo(@This()).@"struct".fields.len;
};

/// JAL (jump and link).
/// 4 common + 1x10 register access = 14
pub const JalColumns = struct {
    // Common (4)
    clk: M31,
    pc: M31,
    imm_j: M31,
    enabler: M31,
    // rd access (10)
    rd_addr: M31,
    rd_prev_0: M31,
    rd_prev_1: M31,
    rd_prev_2: M31,
    rd_prev_3: M31,
    rd_clk_prev: M31,
    rd_next_0: M31,
    rd_next_1: M31,
    rd_next_2: M31,
    rd_next_3: M31,

    pub const N_COLUMNS: usize = @typeInfo(@This()).@"struct".fields.len;
};

/// Load/Store: LB, LBU, LH, LHU, LW, SB, SH, SW.
/// 20 common/flags + 2x10 register accesses + 1x10 memory access = 50
pub const LoadStoreColumns = struct {
    // Common/flags (20)
    clk: M31,
    pc: M31,
    imm: M31,
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
    mem_addr: M31,
    mem_val: M31,
    rs2_val: M31,
    sign_extend: M31,
    // rd access (10) -- destination for loads, source data for stores
    rd_addr: M31,
    rd_prev_0: M31,
    rd_prev_1: M31,
    rd_prev_2: M31,
    rd_prev_3: M31,
    rd_clk_prev: M31,
    rd_next_0: M31,
    rd_next_1: M31,
    rd_next_2: M31,
    rd_next_3: M31,
    // rs1 access (10) -- base address register
    rs1_addr: M31,
    rs1_prev_0: M31,
    rs1_prev_1: M31,
    rs1_prev_2: M31,
    rs1_prev_3: M31,
    rs1_clk_prev: M31,
    rs1_next_0: M31,
    rs1_next_1: M31,
    rs1_next_2: M31,
    rs1_next_3: M31,
    // memory access (10)
    mem_access_addr: M31,
    mem_access_prev_0: M31,
    mem_access_prev_1: M31,
    mem_access_prev_2: M31,
    mem_access_prev_3: M31,
    mem_access_clk_prev: M31,
    mem_access_next_0: M31,
    mem_access_next_1: M31,
    mem_access_next_2: M31,
    mem_access_next_3: M31,

    pub const N_COLUMNS: usize = @typeInfo(@This()).@"struct".fields.len;
};

/// MUL (multiply low 32 bits).
/// 3 common + 3x10 register accesses = 33
pub const MulColumns = struct {
    // Common (3)
    clk: M31,
    pc: M31,
    enabler: M31,
    // rd access (10)
    rd_addr: M31,
    rd_prev_0: M31,
    rd_prev_1: M31,
    rd_prev_2: M31,
    rd_prev_3: M31,
    rd_clk_prev: M31,
    rd_next_0: M31,
    rd_next_1: M31,
    rd_next_2: M31,
    rd_next_3: M31,
    // rs1 access (10)
    rs1_addr: M31,
    rs1_prev_0: M31,
    rs1_prev_1: M31,
    rs1_prev_2: M31,
    rs1_prev_3: M31,
    rs1_clk_prev: M31,
    rs1_next_0: M31,
    rs1_next_1: M31,
    rs1_next_2: M31,
    rs1_next_3: M31,
    // rs2 access (10)
    rs2_addr: M31,
    rs2_prev_0: M31,
    rs2_prev_1: M31,
    rs2_prev_2: M31,
    rs2_prev_3: M31,
    rs2_clk_prev: M31,
    rs2_next_0: M31,
    rs2_next_1: M31,
    rs2_next_2: M31,
    rs2_next_3: M31,

    pub const N_COLUMNS: usize = @typeInfo(@This()).@"struct".fields.len;
};

/// MULH variants: MULH, MULHSU, MULHU.
/// 11 common/decomposition + 3x10 register accesses = 41
pub const MulhColumns = struct {
    // Common (6)
    clk: M31,
    pc: M31,
    is_mulh: M31,
    is_mulhsu: M31,
    is_mulhu: M31,
    enabler: M31,
    // Product decomposition (5)
    prod_lo: M31,
    prod_hi: M31,
    rs1_sign: M31,
    rs2_sign: M31,
    carry: M31,
    // rd access (10)
    rd_addr: M31,
    rd_prev_0: M31,
    rd_prev_1: M31,
    rd_prev_2: M31,
    rd_prev_3: M31,
    rd_clk_prev: M31,
    rd_next_0: M31,
    rd_next_1: M31,
    rd_next_2: M31,
    rd_next_3: M31,
    // rs1 access (10)
    rs1_addr: M31,
    rs1_prev_0: M31,
    rs1_prev_1: M31,
    rs1_prev_2: M31,
    rs1_prev_3: M31,
    rs1_clk_prev: M31,
    rs1_next_0: M31,
    rs1_next_1: M31,
    rs1_next_2: M31,
    rs1_next_3: M31,
    // rs2 access (10)
    rs2_addr: M31,
    rs2_prev_0: M31,
    rs2_prev_1: M31,
    rs2_prev_2: M31,
    rs2_prev_3: M31,
    rs2_clk_prev: M31,
    rs2_next_0: M31,
    rs2_next_1: M31,
    rs2_next_2: M31,
    rs2_next_3: M31,

    pub const N_COLUMNS: usize = @typeInfo(@This()).@"struct".fields.len;
};

/// DIV/REM: DIV, DIVU, REM, REMU.
/// 35 common/decomposition + 3x10 register accesses = 65
pub const DivColumns = struct {
    // Common (7)
    clk: M31,
    pc: M31,
    is_div: M31,
    is_divu: M31,
    is_rem: M31,
    is_remu: M31,
    enabler: M31,
    // Quotient/remainder decomposition (28)
    quotient_0: M31,
    quotient_1: M31,
    quotient_2: M31,
    quotient_3: M31,
    remainder_0: M31,
    remainder_1: M31,
    remainder_2: M31,
    remainder_3: M31,
    rs2_is_zero: M31,
    rs1_sign: M31,
    rs2_sign: M31,
    quotient_sign: M31,
    remainder_sign: M31,
    abs_rs1_0: M31,
    abs_rs1_1: M31,
    abs_rs1_2: M31,
    abs_rs1_3: M31,
    abs_rs2_0: M31,
    abs_rs2_1: M31,
    abs_rs2_2: M31,
    abs_rs2_3: M31,
    prod_lo_0: M31,
    prod_lo_1: M31,
    prod_hi_0: M31,
    prod_hi_1: M31,
    carry_0: M31,
    carry_1: M31,
    overflow: M31,
    // rd access (10)
    rd_addr: M31,
    rd_prev_0: M31,
    rd_prev_1: M31,
    rd_prev_2: M31,
    rd_prev_3: M31,
    rd_clk_prev: M31,
    rd_next_0: M31,
    rd_next_1: M31,
    rd_next_2: M31,
    rd_next_3: M31,
    // rs1 access (10)
    rs1_addr: M31,
    rs1_prev_0: M31,
    rs1_prev_1: M31,
    rs1_prev_2: M31,
    rs1_prev_3: M31,
    rs1_clk_prev: M31,
    rs1_next_0: M31,
    rs1_next_1: M31,
    rs1_next_2: M31,
    rs1_next_3: M31,
    // rs2 access (10)
    rs2_addr: M31,
    rs2_prev_0: M31,
    rs2_prev_1: M31,
    rs2_prev_2: M31,
    rs2_prev_3: M31,
    rs2_clk_prev: M31,
    rs2_next_0: M31,
    rs2_next_1: M31,
    rs2_next_2: M31,
    rs2_next_3: M31,

    pub const N_COLUMNS: usize = @typeInfo(@This()).@"struct".fields.len;
};

/// Program ROM: verifies fetched instructions match the committed program.
/// Columns: enabler, addr (pc), value_0..3 (byte decomposition), multiplicity, root.
pub const ProgramColumns = struct {
    enabler: M31,
    addr: M31,
    value_0: M31,
    value_1: M31,
    value_2: M31,
    value_3: M31,
    multiplicity: M31,
    root: M31,

    pub const N_COLUMNS: usize = 8;
};

/// Memory integrity check: clock-ordered memory access consistency.
/// Columns: enabler, addr, clk, value_0..3 (byte decomposition), multiplicity, root.
pub const MemoryCheckColumns = struct {
    enabler: M31,
    addr: M31,
    clk: M31,
    value_0: M31,
    value_1: M31,
    value_2: M31,
    value_3: M31,
    multiplicity: M31,
    root: M31,

    pub const N_COLUMNS: usize = 9;
};

/// Memory clock update: gap-filling for memory access clock ordering.
/// Columns: enabler, addr, clk, clk_prev, value_0, value_1, value_2.
pub const MemClockUpdateColumns = struct {
    enabler: M31,
    addr: M31,
    clk: M31,
    clk_prev: M31,
    value_0: M31,
    value_1: M31,
    value_2: M31,

    pub const N_COLUMNS: usize = 7;
};

/// Register clock update: gap-filling for register access clock ordering.
/// Columns: enabler, addr, clk_prev, value_0, value_1, value_2, value_3.
pub const RegClockUpdateColumns = struct {
    enabler: M31,
    addr: M31,
    clk_prev: M31,
    value_0: M31,
    value_1: M31,
    value_2: M31,
    value_3: M31,

    pub const N_COLUMNS: usize = 7;
};

/// Merkle tree verification component.
/// Columns: enabler, index, depth, lhs, rhs, cur, lhs_mult, rhs_mult, cur_mult, root.
pub const MerkleColumns = struct {
    enabler: M31,
    index: M31,
    depth: M31,
    lhs: M31,
    rhs: M31,
    cur: M31,
    lhs_mult: M31,
    rhs_mult: M31,
    cur_mult: M31,
    root: M31,

    pub const N_COLUMNS: usize = 10;
};

/// Multiplicity tracking for bitwise lookup table (1 column).
pub const BitwiseMultiplicity = struct {
    multiplicity: M31,

    pub const N_COLUMNS: usize = 1;
};

/// Multiplicity tracking for range_check_20 lookup table (1 column).
pub const RangeCheck20Multiplicity = struct {
    multiplicity: M31,

    pub const N_COLUMNS: usize = 1;
};

/// Multiplicity tracking for range_check_8_8 lookup table (1 column).
pub const RangeCheck8_8Multiplicity = struct {
    multiplicity: M31,

    pub const N_COLUMNS: usize = 1;
};

/// Multiplicity tracking for range_check_8_11 lookup table (1 column).
pub const RangeCheck8_11Multiplicity = struct {
    multiplicity: M31,

    pub const N_COLUMNS: usize = 1;
};

/// Multiplicity tracking for range_check_8_8_4 lookup table (1 column).
pub const RangeCheck8_8_4Multiplicity = struct {
    multiplicity: M31,

    pub const N_COLUMNS: usize = 1;
};

/// Multiplicity tracking for range_check_m31 lookup table (1 column).
pub const RangeCheckM31Multiplicity = struct {
    multiplicity: M31,

    pub const N_COLUMNS: usize = 1;
};

/// Poseidon2 permutation: full trace of a Poseidon2 hash invocation.
///
/// The 443 columns are not broken into named struct fields because the
/// layout is repetitive (rounds x state elements).  N_COLUMNS is the
/// authoritative width; see poseidon2_comp.zig for the column layout
/// description.
pub const Poseidon2Columns = struct {
    pub const N_COLUMNS: usize = 443;
};

test "column counts match struct field counts" {
    const std = @import("std");
    const expectEqual = std.testing.expectEqual;

    try expectEqual(@as(usize, 37), @typeInfo(BaseAluRegColumns).@"struct".fields.len);
    try expectEqual(@as(usize, 29), @typeInfo(BaseAluImmColumns).@"struct".fields.len);
    try expectEqual(@as(usize, 54), @typeInfo(ShiftsRegColumns).@"struct".fields.len);
    try expectEqual(@as(usize, 45), @typeInfo(ShiftsImmColumns).@"struct".fields.len);
    try expectEqual(@as(usize, 42), @typeInfo(LtRegColumns).@"struct".fields.len);
    try expectEqual(@as(usize, 34), @typeInfo(LtImmColumns).@"struct".fields.len);
    try expectEqual(@as(usize, 30), @typeInfo(BranchEqColumns).@"struct".fields.len);
    try expectEqual(@as(usize, 37), @typeInfo(BranchLtColumns).@"struct".fields.len);
    try expectEqual(@as(usize, 16), @typeInfo(LuiColumns).@"struct".fields.len);
    try expectEqual(@as(usize, 14), @typeInfo(AuipcColumns).@"struct".fields.len);
    try expectEqual(@as(usize, 26), @typeInfo(JalrColumns).@"struct".fields.len);
    try expectEqual(@as(usize, 14), @typeInfo(JalColumns).@"struct".fields.len);
    try expectEqual(@as(usize, 50), @typeInfo(LoadStoreColumns).@"struct".fields.len);
    try expectEqual(@as(usize, 33), @typeInfo(MulColumns).@"struct".fields.len);
    try expectEqual(@as(usize, 41), @typeInfo(MulhColumns).@"struct".fields.len);
    try expectEqual(@as(usize, 65), @typeInfo(DivColumns).@"struct".fields.len);
    try expectEqual(@as(usize, 8), @typeInfo(ProgramColumns).@"struct".fields.len);
    try expectEqual(@as(usize, 9), @typeInfo(MemoryCheckColumns).@"struct".fields.len);
    try expectEqual(@as(usize, 7), @typeInfo(MemClockUpdateColumns).@"struct".fields.len);
    try expectEqual(@as(usize, 7), @typeInfo(RegClockUpdateColumns).@"struct".fields.len);
    try expectEqual(@as(usize, 10), @typeInfo(MerkleColumns).@"struct".fields.len);
    try expectEqual(@as(usize, 1), @typeInfo(BitwiseMultiplicity).@"struct".fields.len);
    try expectEqual(@as(usize, 1), @typeInfo(RangeCheck20Multiplicity).@"struct".fields.len);
    try expectEqual(@as(usize, 1), @typeInfo(RangeCheck8_8Multiplicity).@"struct".fields.len);
    try expectEqual(@as(usize, 1), @typeInfo(RangeCheck8_11Multiplicity).@"struct".fields.len);
    try expectEqual(@as(usize, 1), @typeInfo(RangeCheck8_8_4Multiplicity).@"struct".fields.len);
    try expectEqual(@as(usize, 1), @typeInfo(RangeCheckM31Multiplicity).@"struct".fields.len);
}

test "total opcode family columns is 567" {
    const total = BaseAluRegColumns.N_COLUMNS +
        BaseAluImmColumns.N_COLUMNS +
        ShiftsRegColumns.N_COLUMNS +
        ShiftsImmColumns.N_COLUMNS +
        LtRegColumns.N_COLUMNS +
        LtImmColumns.N_COLUMNS +
        BranchEqColumns.N_COLUMNS +
        BranchLtColumns.N_COLUMNS +
        LuiColumns.N_COLUMNS +
        AuipcColumns.N_COLUMNS +
        JalrColumns.N_COLUMNS +
        JalColumns.N_COLUMNS +
        LoadStoreColumns.N_COLUMNS +
        MulColumns.N_COLUMNS +
        MulhColumns.N_COLUMNS +
        DivColumns.N_COLUMNS;
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 567), total);
}
