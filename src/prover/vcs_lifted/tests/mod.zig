//! Lifted Merkle prover tests grouped by protocol phase.

test {
    _ = @import("protocol.zig");
    _ = @import("commit_paths.zig");
    _ = @import("lazy_and_batched.zig");
    _ = @import("test_utils.zig");
}
