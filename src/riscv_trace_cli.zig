//! Zig 0.15 package-root compatibility facade for the owned RISC-V trace tool.

pub fn main() !void {
    return @import("tools/riscv/trace/main.zig").main();
}
