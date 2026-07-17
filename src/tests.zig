//! Cross-module tests that do not belong to one public package surface.

const std = @import("std");
const test_options = @import("test_options");

test {
    if (test_options.riscv_only) {
        _ = @import("tests/riscv/trace_test.zig");
    } else {
        _ = @import("tests/cairo/statement_bootstrap_test.zig");
        _ = @import("tests/metal/arena_plan_test.zig");
        _ = @import("tests/metal/cairo_transcript_fixture_test.zig");
    }
    std.testing.refAllDecls(@This());
}
