//! Zig 0.15 package-root compatibility facade for the RISC-V Metal benchmark.

pub fn main() !void {
    return @import("tools/riscv/metal_bench/main.zig").main();
}
