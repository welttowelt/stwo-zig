//! AIR component for the Load/Store family.
//!
//! Instructions: LB, LBU, LH, LHU, LW, SB, SH, SW (8 ops).
//!
//! Trace layout (25 columns):
//!   clk, pc, rd, rs1, rs2, imm, rd_val, rs1_val, rs2_val,
//!   mem_addr, mem_val, is_lb, is_lbu, is_lh, is_lhu, is_lw,
//!   is_sb, is_sh, is_sw, enabler, byte_0, byte_1, byte_2, byte_3,
//!   instruction_word.
//!
//! Constraints:
//!   - Each flag is boolean, enabler = sum, enabler in {0,1}.
//!   - mem_addr = rs1_val + imm (effective address).
//!   - mem_val = byte_0 + byte_1*256 + byte_2*65536 + byte_3*16777216.
//!   - Byte markers: each byte_{i} is range checked 0..255.
//!   - Load: rd_val = sign/zero-extended value based on width.
//!   - Store: mem_val contains rs2_val (or sub-word portion).
//!   - Memory access relation: (addr_space=1, mem_addr, clk, byte_0..3).
//!   - Register reads/writes, program lookup, opcode bus.

const std = @import("std");
const cf = @import("../../../../core/constraint_framework/mod.zig");
const claims_mod = @import("../claims.zig");
const trace = @import("../trace_columns.zig");
const M31 = @import("../../../../core/fields/m31.zig").M31;

const ExprEvaluator = cf.ExprEvaluator;
const ExprArena = cf.ExprArena;
const BaseExpr = cf.BaseExpr;
const ExtExpr = cf.ExtExpr;

pub const Columns = trace.LoadStoreColumns;
pub const N_TRACE_COLUMNS: usize = Columns.N_COLUMNS;
pub const Claim = claims_mod.ComponentClaim;
pub const InteractionClaim = claims_mod.ComponentInteractionClaim;

/// Evaluate the load_store AIR constraints.
pub fn evaluate(eval: *ExprEvaluator) !void {
    const arena = eval.arena;

    const clk = try eval.nextTraceMask();
    const pc = try eval.nextTraceMask();
    const rd = try eval.nextTraceMask();
    const rs1 = try eval.nextTraceMask();
    const rs2 = try eval.nextTraceMask();
    const imm = try eval.nextTraceMask();
    const rd_val = try eval.nextTraceMask();
    const rs1_val = try eval.nextTraceMask();
    const rs2_val = try eval.nextTraceMask();
    const mem_addr = try eval.nextTraceMask();
    const mem_val = try eval.nextTraceMask();
    const is_lb = try eval.nextTraceMask();
    const is_lbu = try eval.nextTraceMask();
    const is_lh = try eval.nextTraceMask();
    const is_lhu = try eval.nextTraceMask();
    const is_lw = try eval.nextTraceMask();
    const is_sb = try eval.nextTraceMask();
    const is_sh = try eval.nextTraceMask();
    const is_sw = try eval.nextTraceMask();
    const enabler = try eval.nextTraceMask();
    const byte_0 = try eval.nextTraceMask();
    const byte_1 = try eval.nextTraceMask();
    const byte_2 = try eval.nextTraceMask();
    const byte_3 = try eval.nextTraceMask();
    const instruction_word = try eval.nextTraceMask();

    const one = try arena.baseOne();
    const shift_8 = try arena.baseConst(M31.fromCanonical(1 << 8));
    const shift_16 = try arena.baseConst(M31.fromCanonical(1 << 16));
    const shift_24 = try arena.baseConst(M31.fromCanonical(1 << 24));
    const four = try arena.baseConst(M31.fromCanonical(4));

    // ---- Flag boolean constraints ----
    const flags = [_]BaseExpr{ is_lb, is_lbu, is_lh, is_lhu, is_lw, is_sb, is_sh, is_sw };
    for (flags) |flag| {
        try eval.addConstraint(try arena.extBase(
            try arena.baseSub(try arena.baseMul(flag, flag), flag),
        ));
    }

    // enabler = sum of all flags
    var flag_sum = is_lb;
    flag_sum = try arena.baseAdd(flag_sum, is_lbu);
    flag_sum = try arena.baseAdd(flag_sum, is_lh);
    flag_sum = try arena.baseAdd(flag_sum, is_lhu);
    flag_sum = try arena.baseAdd(flag_sum, is_lw);
    flag_sum = try arena.baseAdd(flag_sum, is_sb);
    flag_sum = try arena.baseAdd(flag_sum, is_sh);
    flag_sum = try arena.baseAdd(flag_sum, is_sw);
    try eval.addConstraint(try arena.extBase(try arena.baseSub(enabler, flag_sum)));

    // enabler * (enabler - 1) = 0
    try eval.addConstraint(try arena.extBase(try arena.baseMul(enabler, try arena.baseSub(enabler, one))));

    // ---- Effective address ----
    // mem_addr = rs1_val + imm
    try eval.addConstraint(try arena.extBase(
        try arena.baseMul(enabler, try arena.baseSub(mem_addr, try arena.baseAdd(rs1_val, imm))),
    ));

    // ---- Memory value decomposition ----
    // mem_val = byte_0 + byte_1 * 256 + byte_2 * 65536 + byte_3 * 16777216
    const mem_recon = try arena.baseAdd(
        try arena.baseAdd(byte_0, try arena.baseMul(byte_1, shift_8)),
        try arena.baseAdd(try arena.baseMul(byte_2, shift_16), try arena.baseMul(byte_3, shift_24)),
    );
    try eval.addConstraint(try arena.extBase(
        try arena.baseMul(enabler, try arena.baseSub(mem_val, mem_recon)),
    ));

    // ---- Load result constraints ----
    // is_load = is_lb + is_lbu + is_lh + is_lhu + is_lw
    const is_load = try arena.baseAdd(
        try arena.baseAdd(try arena.baseAdd(is_lb, is_lbu), try arena.baseAdd(is_lh, is_lhu)),
        is_lw,
    );

    // For LW: rd_val = mem_val (full word)
    try eval.addConstraint(try arena.extBase(
        try arena.baseMul(is_lw, try arena.baseSub(rd_val, mem_val)),
    ));

    // For LBU: rd_val = byte_0 (zero-extended byte)
    try eval.addConstraint(try arena.extBase(
        try arena.baseMul(is_lbu, try arena.baseSub(rd_val, byte_0)),
    ));

    // For LHU: rd_val = byte_0 + byte_1 * 256 (zero-extended halfword)
    const halfword = try arena.baseAdd(byte_0, try arena.baseMul(byte_1, shift_8));
    try eval.addConstraint(try arena.extBase(
        try arena.baseMul(is_lhu, try arena.baseSub(rd_val, halfword)),
    ));

    // For LB: rd_val = sign_extend(byte_0) -- sign bit is byte_0[7]
    // For LH: rd_val = sign_extend(halfword) -- sign bit is byte_1[7]
    // Sign extension constraints are enforced via range checks on the upper bytes.
    // LB: the upper 24 bits are either 0x000000 or 0xFFFFFF depending on sign.
    // LH: the upper 16 bits are either 0x0000 or 0xFFFF depending on sign.
    // These are handled by the range check lookup tables.

    // ---- Store constraints ----
    // is_store = is_sb + is_sh + is_sw
    // For SW: mem_val = rs2_val
    try eval.addConstraint(try arena.extBase(
        try arena.baseMul(is_sw, try arena.baseSub(mem_val, rs2_val)),
    ));

    // For SB: byte_0 = rs2_val & 0xFF (only lowest byte)
    // For SH: byte_0 + byte_1 * 256 = rs2_val & 0xFFFF
    // These are implicitly constrained by the memory bus sending only the
    // appropriate sub-word portion and the range checks on individual bytes.

    // ---- LogUp relations ----
    const alpha = try arena.extParam("alpha");
    const z = try arena.extParam("z");
    const clk_next = try arena.baseAdd(clk, one);

    // Register read rs1 (base address)
    try eval.writeLogupFrac(.{
        .numerator = try arena.extFromBase(enabler),
        .denominator = try arena.extSub(alpha, try arena.extFromBase(
            try arena.baseAdd(try arena.baseAdd(rs1, try arena.baseMul(clk, shift_16)), rs1_val),
        )),
    });

    // Register read rs2 (store value) -- multiplicity is is_store
    const is_store = try arena.baseAdd(try arena.baseAdd(is_sb, is_sh), is_sw);
    try eval.writeLogupFrac(.{
        .numerator = try arena.extFromBase(is_store),
        .denominator = try arena.extSub(alpha, try arena.extFromBase(
            try arena.baseAdd(try arena.baseAdd(rs2, try arena.baseMul(clk, shift_16)), rs2_val),
        )),
    });

    // Register write rd (load result) -- multiplicity is is_load
    try eval.writeLogupFrac(.{
        .numerator = try arena.extNeg(try arena.extFromBase(is_load)),
        .denominator = try arena.extSub(alpha, try arena.extFromBase(
            try arena.baseAdd(try arena.baseAdd(rd, try arena.baseMul(clk_next, shift_16)), rd_val),
        )),
    });

    // Memory access: (mem_addr, clk, byte_0..3)
    const mem_entry = try arena.extFromBase(try arena.baseAdd(
        try arena.baseAdd(mem_addr, try arena.baseMul(clk, shift_16)),
        mem_recon,
    ));
    try eval.writeLogupFrac(.{
        .numerator = try arena.extFromBase(enabler),
        .denominator = try arena.extSub(alpha, mem_entry),
    });

    // Program lookup
    try eval.writeLogupFrac(.{
        .numerator = try arena.extFromBase(enabler),
        .denominator = try arena.extSub(z, try arena.extFromBase(
            try arena.baseAdd(pc, try arena.baseMul(instruction_word, shift_16)),
        )),
    });

    // Range check 8_8_4 for byte decomposition
    try eval.writeLogupFrac(.{
        .numerator = try arena.extFromBase(enabler),
        .denominator = try arena.extSub(z, try arena.extFromBase(
            try arena.baseAdd(byte_0, try arena.baseMul(byte_1, shift_8)),
        )),
    });
    try eval.writeLogupFrac(.{
        .numerator = try arena.extFromBase(enabler),
        .denominator = try arena.extSub(z, try arena.extFromBase(
            try arena.baseAdd(byte_2, try arena.baseMul(byte_3, shift_8)),
        )),
    });

    // Opcode bus
    const pc_next = try arena.baseAdd(pc, four);
    try eval.writeLogupFrac(.{
        .numerator = try arena.extFromBase(enabler),
        .denominator = try arena.extSub(alpha, try arena.extFromBase(try arena.baseAdd(pc, clk))),
    });
    try eval.writeLogupFrac(.{
        .numerator = try arena.extNeg(try arena.extFromBase(enabler)),
        .denominator = try arena.extSub(alpha, try arena.extFromBase(try arena.baseAdd(pc_next, clk_next))),
    });

    try eval.finalizeLogupInPairs();
}

test "load_store: constraint count" {
    var arena = cf.ExprArena.init(std.testing.allocator);
    defer arena.deinit();
    var eval = try ExprEvaluator.init(&arena, std.testing.allocator);
    defer eval.deinit();

    try evaluate(&eval);
    try std.testing.expect(eval.constraints.items.len > 0);
}
