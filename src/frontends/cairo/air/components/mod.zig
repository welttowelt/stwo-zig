//! Cairo AIR component constraint definitions.
//!
//! Each component implements an `evaluate(eval: *ExprEvaluator)` function
//! that reads trace columns and emits polynomial constraints + logup relations.
//!
//! Components are named after their opcode/builtin/memory operation.
//! The full Cairo AIR has ~70 components; we start with the core opcodes.

pub const ret_opcode = @import("ret_opcode.zig");

// Future components (to be added incrementally):
// pub const add_opcode = @import("add_opcode.zig");
// pub const assert_eq_opcode = @import("assert_eq_opcode.zig");
// pub const call_opcode_abs = @import("call_opcode_abs.zig");
// pub const jump_opcode_rel_imm = @import("jump_opcode_rel_imm.zig");
// ... ~65 more
