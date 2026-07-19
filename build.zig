const std = @import("std");
const dispatcher = @import("build_support/root_dispatcher.zig");

pub fn build(b: *std.Build) void {
    dispatcher.add(b);
}
