const std = @import("std");
const transcript_fixture = @import("../../backends/metal/cairo/diagnostics/transcript_fixture.zig");

test {
    std.testing.refAllDecls(transcript_fixture);
}
