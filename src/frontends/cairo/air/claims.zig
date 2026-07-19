//! Cairo AIR claim and interaction claim types.
//!
//! Each enabled component has a Claim (containing log_size) and an
//! InteractionClaim (containing the logup claimed_sum). The CairoClaim
//! aggregates all component claims into optional fields.

const std = @import("std");
const QM31 = @import("stwo_core").fields.qm31.QM31;
const M31 = @import("stwo_core").fields.m31.M31;
const cpu = @import("../common/cpu.zig");
const opcodes = @import("../adapter/opcodes.zig");

const CasmState = cpu.CasmState;

/// Per-component claim: the component is active with the given log_size.
pub const ComponentClaim = struct {
    log_size: u32,
};

/// Per-component interaction claim: the logup sum for this component.
pub const ComponentInteractionClaim = struct {
    claimed_sum: QM31,
};

/// Public data embedded in the claim (part of the statement).
pub const PublicData = struct {
    initial_state: CasmState,
    final_state: CasmState,
    // public_memory and safe_call_ids will be added when needed.
};

/// Top-level Cairo claim: aggregates optional claims for all ~67 components.
///
/// A component is present iff its claim is non-null, meaning the trace
/// contains rows for that opcode/builtin/memory operation.
pub const CairoClaim = struct {
    public_data: PublicData,

    // Opcode components (20).
    add_opcode: ?ComponentClaim = null,
    add_opcode_small: ?ComponentClaim = null,
    add_ap_opcode: ?ComponentClaim = null,
    assert_eq_opcode: ?ComponentClaim = null,
    assert_eq_opcode_imm: ?ComponentClaim = null,
    assert_eq_opcode_double_deref: ?ComponentClaim = null,
    blake_compress_opcode: ?ComponentClaim = null,
    call_opcode_abs: ?ComponentClaim = null,
    call_opcode_rel_imm: ?ComponentClaim = null,
    generic_opcode: ?ComponentClaim = null,
    jnz_opcode_non_taken: ?ComponentClaim = null,
    jnz_opcode_taken: ?ComponentClaim = null,
    jump_opcode_abs: ?ComponentClaim = null,
    jump_opcode_double_deref: ?ComponentClaim = null,
    jump_opcode_rel: ?ComponentClaim = null,
    jump_opcode_rel_imm: ?ComponentClaim = null,
    mul_opcode: ?ComponentClaim = null,
    mul_opcode_small: ?ComponentClaim = null,
    qm_31_add_mul_opcode: ?ComponentClaim = null,
    ret_opcode: ?ComponentClaim = null,

    // Instruction verification.
    verify_instruction: ?ComponentClaim = null,

    // Memory components.
    memory_address_to_id: ?ComponentClaim = null,
    memory_id_to_big: ?ComponentClaim = null,
    memory_id_to_small: ?ComponentClaim = null,

    // Range check components.
    range_check_6: ?ComponentClaim = null,
    range_check_8: ?ComponentClaim = null,
    range_check_11: ?ComponentClaim = null,
    range_check_12: ?ComponentClaim = null,
    range_check_18: ?ComponentClaim = null,
    range_check_20: ?ComponentClaim = null,
    range_check_9_9: ?ComponentClaim = null,
    range_check_7_2_5: ?ComponentClaim = null,
    range_check_4_3: ?ComponentClaim = null,
    range_check_4_4: ?ComponentClaim = null,
    range_check_3_6_6_3: ?ComponentClaim = null,
    range_check_4_4_4_4: ?ComponentClaim = null,
    range_check_3_3_3_3_3: ?ComponentClaim = null,

    /// Populate opcode claims from classified state counts.
    pub fn fromOpcodeStates(
        public_data: PublicData,
        states: *const opcodes.CasmStatesByOpcode,
    ) CairoClaim {
        var claim = CairoClaim{ .public_data = public_data };

        inline for (@typeInfo(opcodes.OpcodeTag).@"enum".fields) |field| {
            const tag: opcodes.OpcodeTag = @enumFromInt(field.value);
            const count = states.getConst(tag).len;
            if (count > 0) {
                const log_size = std.math.log2_int_ceil(usize, count);
                @field(claim, field.name) = .{ .log_size = @intCast(log_size) };
            }
        }

        return claim;
    }
};

/// Top-level Cairo interaction claim (mirrors CairoClaim structure).
pub const CairoInteractionClaim = struct {
    // Same field names as CairoClaim, but ComponentInteractionClaim values.
    add_opcode: ?ComponentInteractionClaim = null,
    add_opcode_small: ?ComponentInteractionClaim = null,
    add_ap_opcode: ?ComponentInteractionClaim = null,
    assert_eq_opcode: ?ComponentInteractionClaim = null,
    assert_eq_opcode_imm: ?ComponentInteractionClaim = null,
    assert_eq_opcode_double_deref: ?ComponentInteractionClaim = null,
    blake_compress_opcode: ?ComponentInteractionClaim = null,
    call_opcode_abs: ?ComponentInteractionClaim = null,
    call_opcode_rel_imm: ?ComponentInteractionClaim = null,
    generic_opcode: ?ComponentInteractionClaim = null,
    jnz_opcode_non_taken: ?ComponentInteractionClaim = null,
    jnz_opcode_taken: ?ComponentInteractionClaim = null,
    jump_opcode_abs: ?ComponentInteractionClaim = null,
    jump_opcode_double_deref: ?ComponentInteractionClaim = null,
    jump_opcode_rel: ?ComponentInteractionClaim = null,
    jump_opcode_rel_imm: ?ComponentInteractionClaim = null,
    mul_opcode: ?ComponentInteractionClaim = null,
    mul_opcode_small: ?ComponentInteractionClaim = null,
    qm_31_add_mul_opcode: ?ComponentInteractionClaim = null,
    ret_opcode: ?ComponentInteractionClaim = null,
    verify_instruction: ?ComponentInteractionClaim = null,
    memory_address_to_id: ?ComponentInteractionClaim = null,
    memory_id_to_big: ?ComponentInteractionClaim = null,
    memory_id_to_small: ?ComponentInteractionClaim = null,
    range_check_6: ?ComponentInteractionClaim = null,
    range_check_8: ?ComponentInteractionClaim = null,
    range_check_11: ?ComponentInteractionClaim = null,
    range_check_12: ?ComponentInteractionClaim = null,
    range_check_18: ?ComponentInteractionClaim = null,
    range_check_20: ?ComponentInteractionClaim = null,
    range_check_9_9: ?ComponentInteractionClaim = null,
    range_check_7_2_5: ?ComponentInteractionClaim = null,
    range_check_4_3: ?ComponentInteractionClaim = null,
    range_check_4_4: ?ComponentInteractionClaim = null,
    range_check_3_6_6_3: ?ComponentInteractionClaim = null,
    range_check_4_4_4_4: ?ComponentInteractionClaim = null,
    range_check_3_3_3_3_3: ?ComponentInteractionClaim = null,
};

/// Size of the common lookup random element vector.
pub const COMMON_LOOKUP_ELEMENTS_SIZE: usize = 128;

/// Relation IDs (hashed from relation names, matching Rust stwo-cairo).
pub const relation_ids = struct {
    pub const MEMORY_ADDRESS_TO_ID: M31 = M31.fromCanonical(1444891767);
    pub const MEMORY_ID_TO_BIG: M31 = M31.fromCanonical(1662111297);
    pub const OPCODES: M31 = M31.fromCanonical(428564188);
    pub const RANGE_CHECK_9_9: M31 = M31.fromCanonical(517791011);
};
