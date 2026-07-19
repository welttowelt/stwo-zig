//! Runtime view of the generated Native Metal product identity.

const native_identity = @import("native_product_identity");
const std = @import("std");

pub const value = native_identity.value;

test "generated Native Metal identity binds runtime and AOT semantics" {
    const actual = value();
    try actual.validate();
    try std.testing.expectEqualStrings("stwo-native-metal", actual.name);
    try std.testing.expectEqualStrings("metal", actual.backend);
    try std.testing.expect(std.mem.indexOf(u8, actual.runtime_manifest, "authenticated-aot") != null);
    try std.testing.expect(std.mem.indexOf(u8, actual.aot_manifest, "metallib-sha256") != null);
}
