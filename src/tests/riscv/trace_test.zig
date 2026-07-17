//! RISC-V runner and trace dump tests, discovered through the src-wide test root.

const std = @import("std");

pub const runner = @import("../../frontends/riscv/runner/mod.zig");

test {
    std.testing.refAllDeclsRecursive(runner);
}
