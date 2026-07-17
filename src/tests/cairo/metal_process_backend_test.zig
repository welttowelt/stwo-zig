const std = @import("std");
const backend = @import("../../integrations/cairo_metal/process/backend.zig");
const runner = @import("../../integrations/cairo_metal/process/runner.zig");

test {
    std.testing.refAllDecls(backend);
    std.testing.refAllDecls(runner);
}
