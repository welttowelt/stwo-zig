//! Focused Stark-V RV32IM CPU/SIMD proof command root.

pub fn main() !void {
    return @import("products/riscv_cpu/app.zig").main();
}
