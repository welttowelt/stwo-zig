//! Compositional opcode semantic evaluators.
//!
//! Direct polynomial constraints and sibling lookup requests live together per
//! family, while transcript orchestration and LogUp accumulation remain in the
//! component layer. This keeps semantic review independent of PCS machinery.

pub const common = @import("common.zig");
pub const base_alu_reg = @import("base_alu_reg.zig");
pub const base_alu_imm = @import("base_alu_imm.zig");

test {
    @import("std").testing.refAllDeclsRecursive(@This());
}
