//! Machine-readable capability registry for the Native CPU/SIMD product.

const std = @import("std");
const identity = @import("identity.zig");

const Application = struct {
    air: []const u8,
    status: []const u8 = "release_gated",
    backends: []const []const u8 = &.{"cpu"},
};

const applications = [_]Application{
    .{ .air = "wide_fibonacci" },
    .{ .air = "xor" },
    .{ .air = "plonk" },
    .{ .air = "state_machine" },
    .{ .air = "blake" },
    .{ .air = "poseidon" },
};

pub fn write(writer: anytype) !void {
    try std.json.Stringify.value(.{
        .schema_version = @as(u32, 1),
        .product = identity.value(),
        .backend_availability = .{ .cpu = true },
        .applications = &applications,
        .deferred_adapters = &[_]Application{},
    }, .{}, writer);
}

test "registry exposes only Native examples and CPU" {
    var storage: [8192]u8 = undefined;
    var output = std.Io.Writer.fixed(&storage);
    try write(&output);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        output.buffered(),
        .{},
    );
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqual(@as(usize, applications.len), root.get("applications").?.array.items.len);
    try std.testing.expect(root.get("backend_availability").?.object.get("cpu").?.bool);
    const encoded = output.buffered();
    inline for (.{ "metal", "cuda", "cairo", "riscv", "stark-v" }) |forbidden|
        try std.testing.expect(std.mem.indexOf(u8, encoded, forbidden) == null);
}
