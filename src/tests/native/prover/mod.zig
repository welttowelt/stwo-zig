//! Native backend prover integration tests.

test {
    _ = @import("fri_test.zig");
    _ = @import("pcs/mod.zig");
    _ = @import("prove_test.zig");
}
