//! RISC-V runner and trace dump tests, discovered through the src-wide test root.

const std = @import("std");

pub const runner = @import("../../frontends/riscv/runner/mod.zig");
const infra_trace = @import("../../frontends/riscv/infra_trace.zig");
const StateChainTracker = @import("../../frontends/riscv/runner/state_chain.zig").StateChainTracker;

test {
    std.testing.refAllDeclsRecursive(runner);
}

test "infra_trace: genMemoryColumns caps rows at the domain size" {
    const allocator = std.testing.allocator;
    var chain = StateChainTracker.init(allocator);
    defer chain.deinit();
    try chain.recordRegAccess(1, 0, 42);
    try chain.recordRegAccess(2, 2, 100);
    try chain.recordMemAccess(0x1000, 4, 0xDEADBEEF);
    try chain.recordMemAccess(0x2000, 6, 0xCAFEBABE);
    try chain.recordMemAccess(0x1000, 8, 0x12345678);

    const log_size: u32 = 2; // domain_size = 4 < 5 accesses
    var result = try infra_trace.genMemoryColumns(allocator, &chain, log_size);
    defer infra_trace.freeMemoryColumns(allocator, &result.columns);

    // Callers size shards from access counts; an undersized domain truncates.
    try std.testing.expectEqual(@as(usize, 4), result.n_real_rows);
}
