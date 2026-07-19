//! Installed entry point for the focused Native CPU/SIMD product.

pub const stwo = @import("stwo_native_cpu");

pub fn main() !void {
    return @import("products/native_cpu/app.zig").main();
}
