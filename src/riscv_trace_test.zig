//! Test shim for RISC-V runner and trace dump tests.
//!
//! Exists as a separate root so that `zig build test-riscv` can compile
//! the RISC-V runner module tree (which uses relative imports to core/)
//! from a source root that spans the full `src/` directory.

const std = @import("std");

pub const runner = @import("frontends/riscv/runner/mod.zig");

test {
    std.testing.refAllDeclsRecursive(runner);
}
