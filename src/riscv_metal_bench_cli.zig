const benchmark = @import("riscv_bench_cli.zig");
const MetalProverEngine = @import("backends/metal/prover_engine.zig").MetalProverEngine;

pub fn main() !void {
    return benchmark.mainWithEngine(MetalProverEngine);
}
