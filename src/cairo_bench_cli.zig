//! Root-level entry point for the Cairo benchmark CLI.
//! Delegates to frontends/cairo/bench.zig.
pub const bench = @import("frontends/cairo/bench.zig");

pub fn main() !void {
    return bench.main();
}
