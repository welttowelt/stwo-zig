//! Self-contained RV32IM executor that loads a RISC-V ELF binary,
//! runs it to completion (or ECALL/EBREAK), and dumps the full
//! execution trace as JSON.
//!
//! The JSON output matches the trace schema used by stwo-zig's
//! RISC-V prover so the two can be compared for execution equivalence.

use clap::Parser;
use serde::Serialize;
use std::collections::HashMap;
use std::fs;
use std::process;

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

#[derive(Parser)]
#[command(name = "stark-v-trace-dump")]
#[command(about = "Run a RISC-V ELF and dump execution trace as JSON")]
struct Args {
    /// Path to the RV32IM ELF binary.
    #[arg(long)]
    elf: String,

    /// Path to write the JSON trace output.
    #[arg(long)]
    output: String,

    /// Maximum number of steps before halting (default: 1_000_000).
    #[arg(long, default_value_t = 1_000_000)]
    max_steps: usize,

    /// Initial stack pointer value (default: 0x7FFF0000).
    #[arg(long, default_value_t = 0x7FFF_0000)]
    stack_pointer: u32,
}

// ---------------------------------------------------------------------------
// JSON output schema
// ---------------------------------------------------------------------------

#[derive(Serialize)]
struct TraceStep {
    clk: usize,
    pc: u32,
    opcode: &'static str,
    rd: u8,
    rs1: u8,
    rs2: u8,
    imm: i32,
    rs1_val: u32,
    rs2_val: u32,
    rd_val: u32,
    mem_addr: u32,
    mem_val: u32,
    is_load: bool,
    is_store: bool,
    branch_taken: bool,
    next_pc: u32,
}

#[derive(Serialize)]
struct TraceOutput {
    initial_pc: u32,
    final_pc: u32,
    final_regs: [u32; 32],
    total_steps: usize,
    steps: Vec<TraceStep>,
}

// ---------------------------------------------------------------------------
// Sparse memory (byte-addressable, backed by HashMap)
// ---------------------------------------------------------------------------

struct Memory {
    data: HashMap<u32, u8>,
}

impl Memory {
    fn new() -> Self {
        Self {
            data: HashMap::new(),
        }
    }

    fn read_byte(&self, addr: u32) -> u8 {
        *self.data.get(&addr).unwrap_or(&0)
    }

    fn write_byte(&mut self, addr: u32, val: u8) {
        self.data.insert(addr, val);
    }

    fn read_u16(&self, addr: u32) -> u16 {
        let lo = self.read_byte(addr) as u16;
        let hi = self.read_byte(addr.wrapping_add(1)) as u16;
        (hi << 8) | lo
    }

    fn write_u16(&mut self, addr: u32, val: u16) {
        self.write_byte(addr, val as u8);
        self.write_byte(addr.wrapping_add(1), (val >> 8) as u8);
    }

    fn read_u32(&self, addr: u32) -> u32 {
        let b0 = self.read_byte(addr) as u32;
        let b1 = self.read_byte(addr.wrapping_add(1)) as u32;
        let b2 = self.read_byte(addr.wrapping_add(2)) as u32;
        let b3 = self.read_byte(addr.wrapping_add(3)) as u32;
        (b3 << 24) | (b2 << 16) | (b1 << 8) | b0
    }

    fn write_u32(&mut self, addr: u32, val: u32) {
        self.write_byte(addr, val as u8);
        self.write_byte(addr.wrapping_add(1), (val >> 8) as u8);
        self.write_byte(addr.wrapping_add(2), (val >> 16) as u8);
        self.write_byte(addr.wrapping_add(3), (val >> 24) as u8);
    }

    fn load_segment(&mut self, base: u32, data: &[u8]) {
        for (i, &byte) in data.iter().enumerate() {
            self.write_byte(base.wrapping_add(i as u32), byte);
        }
    }
}

// ---------------------------------------------------------------------------
// ELF32 loader
// ---------------------------------------------------------------------------

const ELF_MAGIC: [u8; 4] = [0x7F, b'E', b'L', b'F'];
const ELFCLASS32: u8 = 1;
const ELFDATA2LSB: u8 = 1;
const EM_RISCV: u16 = 243;
const PT_LOAD: u32 = 1;

struct ElfInfo {
    entry_point: u32,
    segments_loaded: usize,
}

fn read_u16_le(bytes: &[u8]) -> u16 {
    u16::from_le_bytes([bytes[0], bytes[1]])
}

fn read_u32_le(bytes: &[u8]) -> u32 {
    u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]])
}

fn load_elf(elf_bytes: &[u8], mem: &mut Memory) -> Result<ElfInfo, String> {
    if elf_bytes.len() < 52 {
        return Err("ELF too small".into());
    }
    if elf_bytes[0..4] != ELF_MAGIC {
        return Err("Invalid ELF magic".into());
    }
    if elf_bytes[4] != ELFCLASS32 {
        return Err("Not 32-bit ELF".into());
    }
    if elf_bytes[5] != ELFDATA2LSB {
        return Err("Not little-endian ELF".into());
    }
    let e_machine = read_u16_le(&elf_bytes[18..20]);
    if e_machine != EM_RISCV {
        return Err(format!("Not RISC-V (e_machine={})", e_machine));
    }

    let e_entry = read_u32_le(&elf_bytes[24..28]);
    let e_phoff = read_u32_le(&elf_bytes[28..32]) as usize;
    let e_phnum = read_u16_le(&elf_bytes[44..46]) as usize;

    let mut segments_loaded = 0usize;
    for i in 0..e_phnum {
        let ph_offset = e_phoff + i * 32;
        if ph_offset + 32 > elf_bytes.len() {
            return Err("Program header out of bounds".into());
        }
        let phdr = &elf_bytes[ph_offset..ph_offset + 32];
        let p_type = read_u32_le(&phdr[0..4]);
        if p_type != PT_LOAD {
            continue;
        }
        let p_offset = read_u32_le(&phdr[4..8]) as usize;
        let p_vaddr = read_u32_le(&phdr[8..12]);
        let p_filesz = read_u32_le(&phdr[16..20]) as usize;

        if p_offset + p_filesz > elf_bytes.len() {
            return Err("Segment data out of bounds".into());
        }

        let segment_data = &elf_bytes[p_offset..p_offset + p_filesz];
        mem.load_segment(p_vaddr, segment_data);
        segments_loaded += 1;
    }

    Ok(ElfInfo {
        entry_point: e_entry,
        segments_loaded,
    })
}

// ---------------------------------------------------------------------------
// RV32IM opcodes
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Opcode {
    // R-type arithmetic
    ADD, SUB, XOR, OR, AND, SLL, SRL, SRA, SLT, SLTU,
    // I-type arithmetic
    ADDI, XORI, ORI, ANDI, SLLI, SRLI, SRAI, SLTI, SLTIU,
    // Loads
    LB, LBU, LH, LHU, LW,
    // Stores
    SB, SH, SW,
    // Branches
    BEQ, BNE, BLT, BGE, BLTU, BGEU,
    // Jumps
    JAL, JALR,
    // Upper immediates
    LUI, AUIPC,
    // RV32M
    MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, REMU,
    // System
    ECALL, EBREAK,
}

impl Opcode {
    fn name(self) -> &'static str {
        match self {
            Opcode::ADD => "ADD", Opcode::SUB => "SUB",
            Opcode::XOR => "XOR", Opcode::OR => "OR",
            Opcode::AND => "AND", Opcode::SLL => "SLL",
            Opcode::SRL => "SRL", Opcode::SRA => "SRA",
            Opcode::SLT => "SLT", Opcode::SLTU => "SLTU",
            Opcode::ADDI => "ADDI", Opcode::XORI => "XORI",
            Opcode::ORI => "ORI", Opcode::ANDI => "ANDI",
            Opcode::SLLI => "SLLI", Opcode::SRLI => "SRLI",
            Opcode::SRAI => "SRAI", Opcode::SLTI => "SLTI",
            Opcode::SLTIU => "SLTIU",
            Opcode::LB => "LB", Opcode::LBU => "LBU",
            Opcode::LH => "LH", Opcode::LHU => "LHU",
            Opcode::LW => "LW",
            Opcode::SB => "SB", Opcode::SH => "SH", Opcode::SW => "SW",
            Opcode::BEQ => "BEQ", Opcode::BNE => "BNE",
            Opcode::BLT => "BLT", Opcode::BGE => "BGE",
            Opcode::BLTU => "BLTU", Opcode::BGEU => "BGEU",
            Opcode::JAL => "JAL", Opcode::JALR => "JALR",
            Opcode::LUI => "LUI", Opcode::AUIPC => "AUIPC",
            Opcode::MUL => "MUL", Opcode::MULH => "MULH",
            Opcode::MULHSU => "MULHSU", Opcode::MULHU => "MULHU",
            Opcode::DIV => "DIV", Opcode::DIVU => "DIVU",
            Opcode::REM => "REM", Opcode::REMU => "REMU",
            Opcode::ECALL => "ECALL", Opcode::EBREAK => "EBREAK",
        }
    }

    fn is_load(self) -> bool {
        matches!(self, Opcode::LB | Opcode::LBU | Opcode::LH | Opcode::LHU | Opcode::LW)
    }

    fn is_store(self) -> bool {
        matches!(self, Opcode::SB | Opcode::SH | Opcode::SW)
    }
}

// ---------------------------------------------------------------------------
// Decoded instruction
// ---------------------------------------------------------------------------

struct DecodedInst {
    opcode: Opcode,
    rd: u8,
    rs1: u8,
    rs2: u8,
    imm: i32,
}

// ---------------------------------------------------------------------------
// Immediate extraction helpers
// ---------------------------------------------------------------------------

fn decode_i_imm(inst: u32) -> i32 {
    (inst as i32) >> 20 // arithmetic shift preserves sign
}

fn decode_s_imm(inst: u32) -> i32 {
    let hi = inst >> 25;
    let lo = (inst >> 7) & 0x1F;
    let combined = (hi << 5) | lo;
    sign_extend(combined, 12)
}

fn decode_b_imm(inst: u32) -> i32 {
    let bit_31 = (inst >> 31) & 1;
    let bit_7 = (inst >> 7) & 1;
    let bits_30_25 = (inst >> 25) & 0x3F;
    let bits_11_8 = (inst >> 8) & 0xF;
    let combined = (bit_31 << 12) | (bit_7 << 11) | (bits_30_25 << 5) | (bits_11_8 << 1);
    sign_extend(combined, 13)
}

fn decode_u_imm(inst: u32) -> i32 {
    (inst & 0xFFFFF000) as i32
}

fn decode_j_imm(inst: u32) -> i32 {
    let bit_31 = (inst >> 31) & 1;
    let bits_19_12 = (inst >> 12) & 0xFF;
    let bit_20 = (inst >> 20) & 1;
    let bits_30_21 = (inst >> 21) & 0x3FF;
    let combined = (bit_31 << 20) | (bits_19_12 << 12) | (bit_20 << 11) | (bits_30_21 << 1);
    sign_extend(combined, 21)
}

fn sign_extend(value: u32, bits: u32) -> i32 {
    let shift = 32 - bits;
    ((value << shift) as i32) >> shift
}

// ---------------------------------------------------------------------------
// Decoder
// ---------------------------------------------------------------------------

fn decode(inst: u32) -> Result<DecodedInst, String> {
    let opcode_field = inst & 0x7F;
    let rd = ((inst >> 7) & 0x1F) as u8;
    let funct3 = (inst >> 12) & 0x7;
    let rs1 = ((inst >> 15) & 0x1F) as u8;
    let rs2 = ((inst >> 20) & 0x1F) as u8;
    let funct7 = (inst >> 25) & 0x7F;

    match opcode_field {
        // R-type (OP = 0b0110011)
        0b0110011 => {
            if funct7 == 0b0000001 {
                // RV32M
                let op = match funct3 {
                    0b000 => Opcode::MUL,
                    0b001 => Opcode::MULH,
                    0b010 => Opcode::MULHSU,
                    0b011 => Opcode::MULHU,
                    0b100 => Opcode::DIV,
                    0b101 => Opcode::DIVU,
                    0b110 => Opcode::REM,
                    0b111 => Opcode::REMU,
                    _ => unreachable!(),
                };
                Ok(DecodedInst { opcode: op, rd, rs1, rs2, imm: 0 })
            } else {
                let op = match funct3 {
                    0b000 => if funct7 == 0b0100000 { Opcode::SUB } else { Opcode::ADD },
                    0b001 => Opcode::SLL,
                    0b010 => Opcode::SLT,
                    0b011 => Opcode::SLTU,
                    0b100 => Opcode::XOR,
                    0b101 => if funct7 == 0b0100000 { Opcode::SRA } else { Opcode::SRL },
                    0b110 => Opcode::OR,
                    0b111 => Opcode::AND,
                    _ => unreachable!(),
                };
                Ok(DecodedInst { opcode: op, rd, rs1, rs2, imm: 0 })
            }
        }

        // I-type arithmetic (OP-IMM = 0b0010011)
        0b0010011 => {
            let op = match funct3 {
                0b000 => Opcode::ADDI,
                0b001 => Opcode::SLLI,
                0b010 => Opcode::SLTI,
                0b011 => Opcode::SLTIU,
                0b100 => Opcode::XORI,
                0b101 => if funct7 == 0b0100000 { Opcode::SRAI } else { Opcode::SRLI },
                0b110 => Opcode::ORI,
                0b111 => Opcode::ANDI,
                _ => unreachable!(),
            };
            Ok(DecodedInst { opcode: op, rd, rs1, rs2: 0, imm: decode_i_imm(inst) })
        }

        // I-type loads (LOAD = 0b0000011)
        0b0000011 => {
            let op = match funct3 {
                0b000 => Opcode::LB,
                0b001 => Opcode::LH,
                0b010 => Opcode::LW,
                0b100 => Opcode::LBU,
                0b101 => Opcode::LHU,
                _ => return Err(format!("Illegal load funct3={}", funct3)),
            };
            Ok(DecodedInst { opcode: op, rd, rs1, rs2: 0, imm: decode_i_imm(inst) })
        }

        // S-type stores (STORE = 0b0100011)
        0b0100011 => {
            let op = match funct3 {
                0b000 => Opcode::SB,
                0b001 => Opcode::SH,
                0b010 => Opcode::SW,
                _ => return Err(format!("Illegal store funct3={}", funct3)),
            };
            Ok(DecodedInst { opcode: op, rd: 0, rs1, rs2, imm: decode_s_imm(inst) })
        }

        // B-type branches (BRANCH = 0b1100011)
        0b1100011 => {
            let op = match funct3 {
                0b000 => Opcode::BEQ,
                0b001 => Opcode::BNE,
                0b100 => Opcode::BLT,
                0b101 => Opcode::BGE,
                0b110 => Opcode::BLTU,
                0b111 => Opcode::BGEU,
                _ => return Err(format!("Illegal branch funct3={}", funct3)),
            };
            Ok(DecodedInst { opcode: op, rd: 0, rs1, rs2, imm: decode_b_imm(inst) })
        }

        // JAL (J-type, 0b1101111)
        0b1101111 => {
            Ok(DecodedInst { opcode: Opcode::JAL, rd, rs1: 0, rs2: 0, imm: decode_j_imm(inst) })
        }

        // JALR (I-type, 0b1100111)
        0b1100111 => {
            Ok(DecodedInst { opcode: Opcode::JALR, rd, rs1, rs2: 0, imm: decode_i_imm(inst) })
        }

        // LUI (U-type, 0b0110111)
        0b0110111 => {
            Ok(DecodedInst { opcode: Opcode::LUI, rd, rs1: 0, rs2: 0, imm: decode_u_imm(inst) })
        }

        // AUIPC (U-type, 0b0010111)
        0b0010111 => {
            Ok(DecodedInst { opcode: Opcode::AUIPC, rd, rs1: 0, rs2: 0, imm: decode_u_imm(inst) })
        }

        // SYSTEM (0b1110011)
        0b1110011 => {
            let op = if inst == 0x00000073 { Opcode::ECALL } else { Opcode::EBREAK };
            Ok(DecodedInst { opcode: op, rd: 0, rs1: 0, rs2: 0, imm: 0 })
        }

        _ => Err(format!("Illegal instruction: 0x{:08X}", inst)),
    }
}

// ---------------------------------------------------------------------------
// CPU state
// ---------------------------------------------------------------------------

struct Cpu {
    regs: [u32; 32],
    pc: u32,
}

impl Cpu {
    fn new(entry_point: u32, stack_pointer: u32) -> Self {
        let mut regs = [0u32; 32];
        regs[2] = stack_pointer; // x2 = sp
        Self {
            regs,
            pc: entry_point,
        }
    }

    fn read_reg(&self, r: u8) -> u32 {
        if r == 0 { 0 } else { self.regs[r as usize] }
    }

    fn write_reg(&mut self, r: u8, val: u32) {
        if r != 0 {
            self.regs[r as usize] = val;
        }
    }
}

// ---------------------------------------------------------------------------
// Executor
// ---------------------------------------------------------------------------

enum ExecResult {
    Continue,
    Halt,
}

fn execute(cpu: &mut Cpu, mem: &mut Memory, inst: &DecodedInst) -> ExecResult {
    let rs1_v = cpu.read_reg(inst.rs1);
    let rs2_v = cpu.read_reg(inst.rs2);

    match inst.opcode {
        // -- R-type arithmetic --
        Opcode::ADD  => cpu.write_reg(inst.rd, rs1_v.wrapping_add(rs2_v)),
        Opcode::SUB  => cpu.write_reg(inst.rd, rs1_v.wrapping_sub(rs2_v)),
        Opcode::XOR  => cpu.write_reg(inst.rd, rs1_v ^ rs2_v),
        Opcode::OR   => cpu.write_reg(inst.rd, rs1_v | rs2_v),
        Opcode::AND  => cpu.write_reg(inst.rd, rs1_v & rs2_v),
        Opcode::SLL  => cpu.write_reg(inst.rd, rs1_v << (rs2_v & 0x1F)),
        Opcode::SRL  => cpu.write_reg(inst.rd, rs1_v >> (rs2_v & 0x1F)),
        Opcode::SRA  => {
            let signed = rs1_v as i32;
            cpu.write_reg(inst.rd, (signed >> (rs2_v & 0x1F)) as u32);
        }
        Opcode::SLT  => {
            let a = rs1_v as i32;
            let b = rs2_v as i32;
            cpu.write_reg(inst.rd, if a < b { 1 } else { 0 });
        }
        Opcode::SLTU => {
            cpu.write_reg(inst.rd, if rs1_v < rs2_v { 1 } else { 0 });
        }

        // -- I-type arithmetic --
        Opcode::ADDI  => cpu.write_reg(inst.rd, rs1_v.wrapping_add(inst.imm as u32)),
        Opcode::XORI  => cpu.write_reg(inst.rd, rs1_v ^ (inst.imm as u32)),
        Opcode::ORI   => cpu.write_reg(inst.rd, rs1_v | (inst.imm as u32)),
        Opcode::ANDI  => cpu.write_reg(inst.rd, rs1_v & (inst.imm as u32)),
        Opcode::SLLI  => cpu.write_reg(inst.rd, rs1_v << (inst.imm as u32 & 0x1F)),
        Opcode::SRLI  => cpu.write_reg(inst.rd, rs1_v >> (inst.imm as u32 & 0x1F)),
        Opcode::SRAI  => {
            let signed = rs1_v as i32;
            cpu.write_reg(inst.rd, (signed >> (inst.imm as u32 & 0x1F)) as u32);
        }
        Opcode::SLTI  => {
            let a = rs1_v as i32;
            cpu.write_reg(inst.rd, if a < inst.imm { 1 } else { 0 });
        }
        Opcode::SLTIU => {
            cpu.write_reg(inst.rd, if rs1_v < (inst.imm as u32) { 1 } else { 0 });
        }

        // -- Loads --
        Opcode::LB => {
            let addr = rs1_v.wrapping_add(inst.imm as u32);
            let byte = mem.read_byte(addr);
            let signed = byte as i8;
            cpu.write_reg(inst.rd, signed as i32 as u32);
        }
        Opcode::LBU => {
            let addr = rs1_v.wrapping_add(inst.imm as u32);
            cpu.write_reg(inst.rd, mem.read_byte(addr) as u32);
        }
        Opcode::LH => {
            let addr = rs1_v.wrapping_add(inst.imm as u32);
            let half = mem.read_u16(addr);
            let signed = half as i16;
            cpu.write_reg(inst.rd, signed as i32 as u32);
        }
        Opcode::LHU => {
            let addr = rs1_v.wrapping_add(inst.imm as u32);
            cpu.write_reg(inst.rd, mem.read_u16(addr) as u32);
        }
        Opcode::LW => {
            let addr = rs1_v.wrapping_add(inst.imm as u32);
            cpu.write_reg(inst.rd, mem.read_u32(addr));
        }

        // -- Stores --
        Opcode::SB => {
            let addr = rs1_v.wrapping_add(inst.imm as u32);
            mem.write_byte(addr, rs2_v as u8);
        }
        Opcode::SH => {
            let addr = rs1_v.wrapping_add(inst.imm as u32);
            mem.write_u16(addr, rs2_v as u16);
        }
        Opcode::SW => {
            let addr = rs1_v.wrapping_add(inst.imm as u32);
            mem.write_u32(addr, rs2_v);
        }

        // -- Branches --
        Opcode::BEQ => {
            if rs1_v == rs2_v {
                cpu.pc = cpu.pc.wrapping_add(inst.imm as u32);
                return ExecResult::Continue;
            }
        }
        Opcode::BNE => {
            if rs1_v != rs2_v {
                cpu.pc = cpu.pc.wrapping_add(inst.imm as u32);
                return ExecResult::Continue;
            }
        }
        Opcode::BLT => {
            if (rs1_v as i32) < (rs2_v as i32) {
                cpu.pc = cpu.pc.wrapping_add(inst.imm as u32);
                return ExecResult::Continue;
            }
        }
        Opcode::BGE => {
            if (rs1_v as i32) >= (rs2_v as i32) {
                cpu.pc = cpu.pc.wrapping_add(inst.imm as u32);
                return ExecResult::Continue;
            }
        }
        Opcode::BLTU => {
            if rs1_v < rs2_v {
                cpu.pc = cpu.pc.wrapping_add(inst.imm as u32);
                return ExecResult::Continue;
            }
        }
        Opcode::BGEU => {
            if rs1_v >= rs2_v {
                cpu.pc = cpu.pc.wrapping_add(inst.imm as u32);
                return ExecResult::Continue;
            }
        }

        // -- Jumps --
        Opcode::JAL => {
            cpu.write_reg(inst.rd, cpu.pc.wrapping_add(4));
            cpu.pc = cpu.pc.wrapping_add(inst.imm as u32);
            return ExecResult::Continue;
        }
        Opcode::JALR => {
            let target = (rs1_v.wrapping_add(inst.imm as u32)) & 0xFFFF_FFFE;
            cpu.write_reg(inst.rd, cpu.pc.wrapping_add(4));
            cpu.pc = target;
            return ExecResult::Continue;
        }

        // -- Upper immediates --
        Opcode::LUI   => cpu.write_reg(inst.rd, inst.imm as u32),
        Opcode::AUIPC => cpu.write_reg(inst.rd, cpu.pc.wrapping_add(inst.imm as u32)),

        // -- RV32M: Multiply --
        Opcode::MUL => {
            let result = (rs1_v as i32 as i64).wrapping_mul(rs2_v as i32 as i64) as u64;
            cpu.write_reg(inst.rd, result as u32);
        }
        Opcode::MULH => {
            let a = rs1_v as i32 as i64;
            let b = rs2_v as i32 as i64;
            let product = a.wrapping_mul(b) as u64;
            cpu.write_reg(inst.rd, (product >> 32) as u32);
        }
        Opcode::MULHSU => {
            let a = rs1_v as i32 as i64;
            let b = rs2_v as u64 as i64;
            let product = a.wrapping_mul(b) as u64;
            cpu.write_reg(inst.rd, (product >> 32) as u32);
        }
        Opcode::MULHU => {
            let a = rs1_v as u64;
            let b = rs2_v as u64;
            let product = a.wrapping_mul(b);
            cpu.write_reg(inst.rd, (product >> 32) as u32);
        }

        // -- RV32M: Divide --
        Opcode::DIV => {
            let a = rs1_v as i32;
            let b = rs2_v as i32;
            if b == 0 {
                cpu.write_reg(inst.rd, (-1i32) as u32);
            } else if a == i32::MIN && b == -1 {
                cpu.write_reg(inst.rd, a as u32);
            } else {
                cpu.write_reg(inst.rd, a.wrapping_div(b) as u32);
            }
        }
        Opcode::DIVU => {
            let a = rs1_v;
            let b = rs2_v;
            if b == 0 {
                cpu.write_reg(inst.rd, 0xFFFF_FFFF);
            } else {
                cpu.write_reg(inst.rd, a / b);
            }
        }
        Opcode::REM => {
            let a = rs1_v as i32;
            let b = rs2_v as i32;
            if b == 0 {
                cpu.write_reg(inst.rd, a as u32);
            } else if a == i32::MIN && b == -1 {
                cpu.write_reg(inst.rd, 0);
            } else {
                cpu.write_reg(inst.rd, a.wrapping_rem(b) as u32);
            }
        }
        Opcode::REMU => {
            let a = rs1_v;
            let b = rs2_v;
            if b == 0 {
                cpu.write_reg(inst.rd, a);
            } else {
                cpu.write_reg(inst.rd, a % b);
            }
        }

        // -- System --
        Opcode::ECALL  => return ExecResult::Halt,
        Opcode::EBREAK => return ExecResult::Halt,
    }

    // Default: advance PC by 4 (branches/jumps return early).
    cpu.pc = cpu.pc.wrapping_add(4);
    ExecResult::Continue
}

// ---------------------------------------------------------------------------
// Main runner
// ---------------------------------------------------------------------------

fn run_elf(
    elf_bytes: &[u8],
    max_steps: usize,
    stack_pointer: u32,
) -> Result<TraceOutput, String> {
    let mut mem = Memory::new();
    let elf_info = load_elf(elf_bytes, &mut mem)?;

    eprintln!(
        "ELF loaded: entry=0x{:08X}, segments={}",
        elf_info.entry_point, elf_info.segments_loaded
    );

    let mut cpu = Cpu::new(elf_info.entry_point, stack_pointer);
    let initial_pc = cpu.pc;
    let mut steps: Vec<TraceStep> = Vec::new();

    for clk in 0..max_steps {
        let pc_before = cpu.pc;
        let inst_word = mem.read_u32(cpu.pc);
        let inst = match decode(inst_word) {
            Ok(i) => i,
            Err(e) => {
                eprintln!("Decode error at PC=0x{:08X}: {}", cpu.pc, e);
                break;
            }
        };

        // Capture pre-execution register values.
        let rs1_val = cpu.read_reg(inst.rs1);
        let rs2_val = cpu.read_reg(inst.rs2);

        // Capture memory address and value for load/store before execution.
        let mut mem_addr: u32 = 0;
        let mut mem_val: u32 = 0;
        let is_load = inst.opcode.is_load();
        let is_store = inst.opcode.is_store();

        if is_load || is_store {
            mem_addr = rs1_val.wrapping_add(inst.imm as u32);
            if is_load {
                mem_val = match inst.opcode {
                    Opcode::LB | Opcode::LBU => mem.read_byte(mem_addr) as u32,
                    Opcode::LH | Opcode::LHU => mem.read_u16(mem_addr) as u32,
                    Opcode::LW => mem.read_u32(mem_addr),
                    _ => 0,
                };
            } else {
                mem_val = rs2_val;
            }
        }

        // Execute.
        let halted = matches!(execute(&mut cpu, &mut mem, &inst), ExecResult::Halt);

        let rd_val = cpu.read_reg(inst.rd);
        let next_pc = cpu.pc;
        let branch_taken = next_pc != pc_before.wrapping_add(4);

        steps.push(TraceStep {
            clk,
            pc: pc_before,
            opcode: inst.opcode.name(),
            rd: inst.rd,
            rs1: inst.rs1,
            rs2: inst.rs2,
            imm: inst.imm,
            rs1_val,
            rs2_val,
            rd_val,
            mem_addr,
            mem_val,
            is_load,
            is_store,
            branch_taken,
            next_pc,
        });

        if halted {
            break;
        }
    }

    let total_steps = steps.len();
    eprintln!("Execution complete: {} steps, final PC=0x{:08X}", total_steps, cpu.pc);

    Ok(TraceOutput {
        initial_pc,
        final_pc: cpu.pc,
        final_regs: cpu.regs,
        total_steps,
        steps,
    })
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

fn main() {
    let args = Args::parse();

    let elf_bytes = match fs::read(&args.elf) {
        Ok(b) => b,
        Err(e) => {
            eprintln!("Failed to read ELF '{}': {}", args.elf, e);
            process::exit(1);
        }
    };

    let trace = match run_elf(&elf_bytes, args.max_steps, args.stack_pointer) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("Execution failed: {}", e);
            process::exit(1);
        }
    };

    let json = match serde_json::to_string_pretty(&trace) {
        Ok(j) => j,
        Err(e) => {
            eprintln!("JSON serialization failed: {}", e);
            process::exit(1);
        }
    };

    match fs::write(&args.output, &json) {
        Ok(()) => {
            eprintln!("Trace written to {}", args.output);
        }
        Err(e) => {
            eprintln!("Failed to write output '{}': {}", args.output, e);
            process::exit(1);
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a minimal ELF with the given instruction words loaded at 0x10000.
    fn make_test_elf(instructions: &[u32]) -> Vec<u8> {
        let code_size = instructions.len() * 4;
        let elf_size = 84 + code_size;
        let mut buf = vec![0u8; elf_size];

        // ELF header
        buf[0] = 0x7F; buf[1] = b'E'; buf[2] = b'L'; buf[3] = b'F';
        buf[4] = 1;    // ELFCLASS32
        buf[5] = 1;    // ELFDATA2LSB
        buf[6] = 1;    // EI_VERSION
        buf[16] = 2;   // e_type = ET_EXEC
        buf[18] = 0xF3; // e_machine = EM_RISCV
        buf[20] = 1;   // e_version
        // e_entry = 0x10000
        buf[24] = 0x00; buf[25] = 0x00; buf[26] = 0x01; buf[27] = 0x00;
        // e_phoff = 52
        buf[28] = 52;
        // e_ehsize = 52
        buf[40] = 52;
        // e_phentsize = 32
        buf[42] = 32;
        // e_phnum = 1
        buf[44] = 1;

        // Program header at offset 52
        buf[52] = 1;  // p_type = PT_LOAD
        buf[56] = 84; // p_offset = 84
        // p_vaddr = 0x10000
        buf[60] = 0x00; buf[61] = 0x00; buf[62] = 0x01; buf[63] = 0x00;
        // p_filesz
        buf[68] = code_size as u8;
        buf[69] = (code_size >> 8) as u8;
        // p_memsz
        buf[72] = code_size as u8;
        buf[73] = (code_size >> 8) as u8;

        // Instructions at offset 84
        for (i, &inst_word) in instructions.iter().enumerate() {
            let offset = 84 + i * 4;
            buf[offset] = inst_word as u8;
            buf[offset + 1] = (inst_word >> 8) as u8;
            buf[offset + 2] = (inst_word >> 16) as u8;
            buf[offset + 3] = (inst_word >> 24) as u8;
        }

        buf
    }

    #[test]
    fn test_addi_ecall() {
        // ADDI x1, x0, 42; ECALL
        let elf = make_test_elf(&[0x02A00093, 0x00000073]);
        let trace = run_elf(&elf, 1000, 0x7FFF_0000).unwrap();
        assert_eq!(trace.total_steps, 2);
        assert_eq!(trace.final_regs[1], 42);
        assert_eq!(trace.steps[0].opcode, "ADDI");
        assert_eq!(trace.steps[1].opcode, "ECALL");
    }

    #[test]
    fn test_add_sub() {
        // ADDI x1, x0, 10; ADDI x2, x0, 20; ADD x3, x1, x2; SUB x4, x2, x1; ECALL
        let elf = make_test_elf(&[
            0x00A00093, // ADDI x1, x0, 10
            0x01400113, // ADDI x2, x0, 20
            0x002081B3, // ADD  x3, x1, x2
            0x40110233, // SUB  x4, x2, x1
            0x00000073, // ECALL
        ]);
        let trace = run_elf(&elf, 1000, 0x7FFF_0000).unwrap();
        assert_eq!(trace.final_regs[1], 10);
        assert_eq!(trace.final_regs[3], 30);
        assert_eq!(trace.final_regs[4], 10);
    }

    #[test]
    fn test_mul() {
        // ADDI x1, x0, 7; ADDI x2, x0, 6; MUL x3, x1, x2; ECALL
        // MUL x3, x1, x2 = funct7=0000001, rs2=x2, rs1=x1, funct3=000, rd=x3, opcode=0110011
        // = 0b0000001_00010_00001_000_00011_0110011 = 0x022081B3
        let elf = make_test_elf(&[
            0x00700093, // ADDI x1, x0, 7
            0x00600113, // ADDI x2, x0, 6
            0x022081B3, // MUL  x3, x1, x2
            0x00000073, // ECALL
        ]);
        let trace = run_elf(&elf, 1000, 0x7FFF_0000).unwrap();
        assert_eq!(trace.final_regs[3], 42);
    }

    #[test]
    fn test_div_by_zero() {
        // ADDI x1, x0, 100; DIV x3, x1, x0; ECALL
        // DIV x3, x1, x0: funct7=0000001, rs2=x0, rs1=x1, funct3=100, rd=x3, opcode=0110011
        // = 0b0000001_00000_00001_100_00011_0110011 = 0x0200C1B3
        let elf = make_test_elf(&[
            0x06400093, // ADDI x1, x0, 100
            0x0200C1B3, // DIV  x3, x1, x0
            0x00000073, // ECALL
        ]);
        let trace = run_elf(&elf, 1000, 0x7FFF_0000).unwrap();
        assert_eq!(trace.final_regs[3], 0xFFFF_FFFF); // -1
    }

    #[test]
    fn test_load_store() {
        // ADDI x1, x0, 0x55; ADDI x2, x0, 0x100; SW x1, 0(x2); LW x3, 0(x2); ECALL
        let elf = make_test_elf(&[
            0x05500093, // ADDI x1, x0, 0x55
            0x10000113, // ADDI x2, x0, 0x100
            0x00112023, // SW   x1, 0(x2)
            0x00012183, // LW   x3, 0(x2)
            0x00000073, // ECALL
        ]);
        let trace = run_elf(&elf, 1000, 0x7FFF_0000).unwrap();
        assert_eq!(trace.final_regs[3], 0x55);
        // Check trace flags
        assert!(trace.steps[2].is_store);
        assert_eq!(trace.steps[2].mem_addr, 0x100);
        assert_eq!(trace.steps[2].mem_val, 0x55);
        assert!(trace.steps[3].is_load);
        assert_eq!(trace.steps[3].mem_addr, 0x100);
        assert_eq!(trace.steps[3].mem_val, 0x55);
    }

    #[test]
    fn test_branch_taken() {
        // ADDI x1, x0, 42; ADDI x2, x0, 42; BEQ x1, x2, +8; ADDI x3, x0, 1; ADDI x4, x0, 2; ECALL
        // If BEQ taken, skip ADDI x3 (at pc+4), land on ADDI x4 (at pc+8).
        let elf = make_test_elf(&[
            0x02A00093, // ADDI x1, x0, 42
            0x02A00113, // ADDI x2, x0, 42
            0x00208463, // BEQ  x1, x2, +8
            0x00100193, // ADDI x3, x0, 1  (skipped)
            0x00200213, // ADDI x4, x0, 2
            0x00000073, // ECALL
        ]);
        let trace = run_elf(&elf, 1000, 0x7FFF_0000).unwrap();
        assert_eq!(trace.final_regs[3], 0); // x3 was skipped
        assert_eq!(trace.final_regs[4], 2); // x4 was executed
        assert!(trace.steps[2].branch_taken);
    }

    #[test]
    fn test_jal() {
        // JAL x1, +8; ADDI x3, x0, 1; ADDI x4, x0, 2; ECALL
        // JAL jumps +8 from current PC, skipping ADDI x3.
        // JAL x1, +8: imm=8, rd=x1
        // Encoding: imm[20|10:1|11|19:12] | rd | 1101111
        // imm=8 = 0b0000_0000_0000_0000_1000
        //   imm[20]    = 0
        //   imm[10:1]  = 0000000100
        //   imm[11]    = 0
        //   imm[19:12] = 00000000
        // inst[31]     = 0                   (imm[20])
        // inst[30:21]  = 0000000100          (imm[10:1])
        // inst[20]     = 0                   (imm[11])
        // inst[19:12]  = 00000000            (imm[19:12])
        // inst[11:7]   = 00001               (rd=x1)
        // inst[6:0]    = 1101111
        // = 0b0_0000001000_0_00000000_00001_1101111
        // = 0x008000EF
        let elf = make_test_elf(&[
            0x008000EF, // JAL x1, +8
            0x00100193, // ADDI x3, x0, 1  (skipped)
            0x00200213, // ADDI x4, x0, 2
            0x00000073, // ECALL
        ]);
        let trace = run_elf(&elf, 1000, 0x7FFF_0000).unwrap();
        assert_eq!(trace.final_regs[3], 0); // x3 skipped
        assert_eq!(trace.final_regs[4], 2); // x4 executed
        // x1 = return address = 0x10000 + 4 = 0x10004
        assert_eq!(trace.final_regs[1], 0x10004);
    }

    #[test]
    fn test_lui() {
        // LUI x1, 0x12345; ECALL
        let elf = make_test_elf(&[
            0x123450B7, // LUI x1, 0x12345
            0x00000073, // ECALL
        ]);
        let trace = run_elf(&elf, 1000, 0x7FFF_0000).unwrap();
        assert_eq!(trace.final_regs[1], 0x12345000);
    }

    #[test]
    fn test_decode_equivalence() {
        // Verify decoder matches the Zig decoder's known-good encodings.
        let cases: &[(u32, &str, u8, u8, u8, i32)] = &[
            (0x003100B3, "ADD",  1, 2, 3, 0),
            (0x40310133, "SUB",  2, 2, 3, 0),
            (0x00500093, "ADDI", 1, 0, 0, 5),
            (0x00002103, "LW",   2, 0, 0, 0),
            (0x00112023, "SW",   0, 2, 1, 0),
            (0x00208463, "BEQ",  0, 1, 2, 8),
            (0x00C000EF, "JAL",  1, 0, 0, 12),
            (0x000080E7, "JALR", 1, 1, 0, 0),
            (0x000011B7, "LUI",  3, 0, 0, 0x1000),
            (0x00001197, "AUIPC",3, 0, 0, 0x1000),
            (0x02208033, "MUL",  0, 1, 2, 0),
            (0x02209033, "MULH", 0, 1, 2, 0),
            (0x0220C033, "DIV",  0, 1, 2, 0),
            (0x00101013, "SLLI", 0, 0, 0, 1),
            (0x00000073, "ECALL",0, 0, 0, 0),
        ];

        for &(encoding, expected_op, exp_rd, exp_rs1, exp_rs2, exp_imm) in cases {
            let inst = decode(encoding).unwrap_or_else(|e| {
                panic!("Failed to decode 0x{:08X}: {}", encoding, e);
            });
            assert_eq!(inst.opcode.name(), expected_op,
                "opcode mismatch for 0x{:08X}", encoding);
            assert_eq!(inst.rd, exp_rd,
                "rd mismatch for 0x{:08X}", encoding);
            assert_eq!(inst.rs1, exp_rs1,
                "rs1 mismatch for 0x{:08X}", encoding);
            assert_eq!(inst.rs2, exp_rs2,
                "rs2 mismatch for 0x{:08X}", encoding);
            assert_eq!(inst.imm, exp_imm,
                "imm mismatch for 0x{:08X}", encoding);
        }
    }

    #[test]
    fn test_executor_equivalence() {
        // Same instruction sequence as the Zig executor equivalence test.
        let elf = make_test_elf(&[
            0x00A00093, // ADDI x1, x0, 10
            0x01400113, // ADDI x2, x0, 20
            0x002081B3, // ADD  x3, x1, x2
            0x40110233, // SUB  x4, x2, x1
            0x022082B3, // MUL  x5, x1, x2
            0x00209333, // SLL  x6, x1, x2
            0x0020A3B3, // SLT  x7, x1, x2
            0x0020C433, // XOR  x8, x1, x2
            0x00000073, // ECALL
        ]);
        let trace = run_elf(&elf, 1000, 0x7FFF_0000).unwrap();

        assert_eq!(trace.final_regs[1], 10);      // x1 = 10
        assert_eq!(trace.final_regs[2], 20);       // x2 = 20 (ADDI x2, x0, 20 overwrites stack pointer)
        assert_eq!(trace.final_regs[3], 30);       // x3 = 30
        assert_eq!(trace.final_regs[4], 10);       // x4 = 10
        assert_eq!(trace.final_regs[5], 200);      // x5 = 200
        assert_eq!(trace.final_regs[6], 10_485_760); // x6 = 10 << 20
        assert_eq!(trace.final_regs[7], 1);        // x7 = 1 (10 < 20)
        assert_eq!(trace.final_regs[8], 30);       // x8 = 10 ^ 20 = 30
        assert_eq!(trace.total_steps, 9);
    }

    #[test]
    fn test_elf_validation() {
        // Bad magic
        let mut bad_magic = make_test_elf(&[0x00000073]);
        bad_magic[0] = 0x00;
        assert!(run_elf(&bad_magic, 100, 0x7FFF_0000).is_err());

        // Not RISC-V
        let mut bad_arch = make_test_elf(&[0x00000073]);
        bad_arch[18] = 0x03; // EM_386
        bad_arch[19] = 0x00;
        assert!(run_elf(&bad_arch, 100, 0x7FFF_0000).is_err());

        // Truncated
        let short = vec![0x7F, b'E', b'L', b'F'];
        assert!(run_elf(&short, 100, 0x7FFF_0000).is_err());
    }
}
