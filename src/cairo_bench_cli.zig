//! Root-level entry point for the Cairo benchmark CLI.
//! Delegates to frontends/cairo/bench.zig.
pub const bench = @import("frontends/cairo/bench.zig");
const CpuBackend = @import("backends/cpu_scalar/mod.zig").CpuBackend;

pub fn main() !void {
    return bench.run(CpuBackend);
}
