//! Zig 0.15 package-root compatibility facade for the owned Metal arena tool.

pub const stwo = @import("stwo");

pub fn main() !void {
    return @import("tools/metal_arena_plan/main.zig").main();
}
