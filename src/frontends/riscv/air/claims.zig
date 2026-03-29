//! RISC-V AIR claim and interaction claim types.
//!
//! Each enabled component has a ComponentClaim (containing log_size) and a
//! ComponentInteractionClaim (containing the logup claimed_sum). The
//! RiscVClaim aggregates all component claims into optional fields.
//!
//! Ported from stark-v's claim system for RV32IM.

const QM31 = @import("../../../core/fields/qm31.zig").QM31;
const M31 = @import("../../../core/fields/m31.zig").M31;

/// Per-component claim: the component is active with the given log_size.
pub const ComponentClaim = struct {
    log_size: u32,
};

/// Per-component interaction claim: the logup sum for this component.
pub const ComponentInteractionClaim = struct {
    claimed_sum: QM31,
};

/// Top-level RISC-V claim: aggregates optional claims for all components.
///
/// A component is present iff its claim is non-null, meaning the trace
/// contains rows for that opcode family / infrastructure table.
pub const RiscVClaim = struct {
    // ---- Opcode family components (16) ----
    base_alu_reg: ?ComponentClaim = null,
    base_alu_imm: ?ComponentClaim = null,
    shifts_reg: ?ComponentClaim = null,
    shifts_imm: ?ComponentClaim = null,
    lt_reg: ?ComponentClaim = null,
    lt_imm: ?ComponentClaim = null,
    branch_eq: ?ComponentClaim = null,
    branch_lt: ?ComponentClaim = null,
    lui: ?ComponentClaim = null,
    auipc: ?ComponentClaim = null,
    jalr: ?ComponentClaim = null,
    jal: ?ComponentClaim = null,
    load_store: ?ComponentClaim = null,
    mul: ?ComponentClaim = null,
    mulh: ?ComponentClaim = null,
    div: ?ComponentClaim = null,

    // ---- Infrastructure components ----
    program: ?ComponentClaim = null,
    memory: ?ComponentClaim = null,

    // ---- Preprocessed table components ----
    bitwise: ?ComponentClaim = null,
    range_check_20: ?ComponentClaim = null,
    range_check_8_8: ?ComponentClaim = null,
    range_check_8_11: ?ComponentClaim = null,
    range_check_8_8_4: ?ComponentClaim = null,
    range_check_m31: ?ComponentClaim = null,
};

/// Top-level RISC-V interaction claim (mirrors RiscVClaim structure).
pub const RiscVInteractionClaim = struct {
    // ---- Opcode family components (16) ----
    base_alu_reg: ?ComponentInteractionClaim = null,
    base_alu_imm: ?ComponentInteractionClaim = null,
    shifts_reg: ?ComponentInteractionClaim = null,
    shifts_imm: ?ComponentInteractionClaim = null,
    lt_reg: ?ComponentInteractionClaim = null,
    lt_imm: ?ComponentInteractionClaim = null,
    branch_eq: ?ComponentInteractionClaim = null,
    branch_lt: ?ComponentInteractionClaim = null,
    lui: ?ComponentInteractionClaim = null,
    auipc: ?ComponentInteractionClaim = null,
    jalr: ?ComponentInteractionClaim = null,
    jal: ?ComponentInteractionClaim = null,
    load_store: ?ComponentInteractionClaim = null,
    mul: ?ComponentInteractionClaim = null,
    mulh: ?ComponentInteractionClaim = null,
    div: ?ComponentInteractionClaim = null,

    // ---- Infrastructure components ----
    program: ?ComponentInteractionClaim = null,
    memory: ?ComponentInteractionClaim = null,

    // ---- Preprocessed table components ----
    bitwise: ?ComponentInteractionClaim = null,
    range_check_20: ?ComponentInteractionClaim = null,
    range_check_8_8: ?ComponentInteractionClaim = null,
    range_check_8_11: ?ComponentInteractionClaim = null,
    range_check_8_8_4: ?ComponentInteractionClaim = null,
    range_check_m31: ?ComponentInteractionClaim = null,
};

test "claims: default initialization" {
    const claim = RiscVClaim{};
    try @import("std").testing.expect(claim.base_alu_reg == null);
    try @import("std").testing.expect(claim.div == null);
    try @import("std").testing.expect(claim.range_check_m31 == null);
}
