//! Cairo proving orchestration implemented by the resident Metal backend.

pub const arena_binding = @import("arena_binding.zig");
pub const memory_trace = @import("memory_trace.zig");
pub const oods = @import("oods.zig");
pub const eval_codegen = @import("eval_codegen.zig");
pub const witness_codegen = @import("witness_codegen.zig");

test {
    _ = oods;
    _ = eval_codegen;
    _ = witness_codegen;
}
