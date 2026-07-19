//! Upper-immediate and jump committed columns in pinned Stark-V order.

const M31 = @import("stwo_core").fields.m31.M31;

pub const LuiColumns = struct {
    enabler: M31,
    clock: M31,
    pc: M31,
    rd_addr: M31,
    rd_prev_0: M31,
    rd_prev_1: M31,
    rd_prev_2: M31,
    rd_prev_3: M31,
    rd_clock_prev: M31,
    rd_next_0: M31,
    rd_next_1: M31,
    rd_next_2: M31,
    rd_next_3: M31,
    imm_0: M31,
    imm_1: M31,
    imm_2: M31,
    pub const N_COLUMNS = @typeInfo(@This()).@"struct".fields.len;
};

pub const AuipcColumns = struct {
    enabler: M31,
    clock: M31,
    pc: M31,
    rd_addr: M31,
    rd_prev_0: M31,
    rd_prev_1: M31,
    rd_prev_2: M31,
    rd_prev_3: M31,
    rd_clock_prev: M31,
    rd_next_0: M31,
    rd_next_1: M31,
    rd_next_2: M31,
    rd_next_3: M31,
    imm_felt: M31,
    pub const N_COLUMNS = @typeInfo(@This()).@"struct".fields.len;
};

pub const JalrColumns = struct {
    enabler: M31,
    clock: M31,
    pc: M31,
    rd_addr: M31,
    rd_prev_0: M31,
    rd_prev_1: M31,
    rd_prev_2: M31,
    rd_prev_3: M31,
    rd_clock_prev: M31,
    rd_next_0: M31,
    rd_next_1: M31,
    rd_next_2: M31,
    rd_next_3: M31,
    rs1_addr: M31,
    rs1_prev_0: M31,
    rs1_prev_1: M31,
    rs1_prev_2: M31,
    rs1_prev_3: M31,
    rs1_clock_prev: M31,
    rs1_next_0: M31,
    rs1_next_1: M31,
    rs1_next_2: M31,
    rs1_next_3: M31,
    to_pc_over_two: M31,
    to_pc_lsb: M31,
    imm_felt: M31,
    pub const N_COLUMNS = @typeInfo(@This()).@"struct".fields.len;
};

pub const JalColumns = struct {
    enabler: M31,
    clock: M31,
    pc: M31,
    rd_addr: M31,
    rd_prev_0: M31,
    rd_prev_1: M31,
    rd_prev_2: M31,
    rd_prev_3: M31,
    rd_clock_prev: M31,
    rd_next_0: M31,
    rd_next_1: M31,
    rd_next_2: M31,
    rd_next_3: M31,
    imm_felt: M31,
    pub const N_COLUMNS = @typeInfo(@This()).@"struct".fields.len;
};
