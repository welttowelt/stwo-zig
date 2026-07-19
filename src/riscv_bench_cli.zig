//! Zig 0.15 package-root compatibility facade for the owned RISC-V benchmark.

pub fn main() !void {
    return @import("tools/riscv/bench/main.zig").main();
}
