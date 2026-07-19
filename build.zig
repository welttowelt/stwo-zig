const std = @import("std");
const aggregate = @import("build_support/products/aggregate_cli.zig");

pub fn build(b: *std.Build) void {
    aggregate.addProduct(b);
}
