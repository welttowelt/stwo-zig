//! Cross-module tests that do not belong to one public package surface.

const std = @import("std");

test {
    _ = @import("tests/metal/cairo_transcript_fixture_test.zig");
    std.testing.refAllDecls(@This());
}
