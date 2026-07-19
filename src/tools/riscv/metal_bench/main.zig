const benchmark = @import("../bench/main.zig");
const MetalProverEngine = @import("../../../backends/metal/prover_engine.zig").MetalProverEngine;

pub fn main() !void {
    return benchmark.mainWithEngine(MetalProverEngine);
}
