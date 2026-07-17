//! Static build policy and measured toolchain identity for the Native metallib.

const std = @import("std");
const manifest = @import("manifest.zig");

pub const TargetPolicy = struct {
    platform: []const u8,
    sdk: []const u8,
    minimum_deployment_target: []const u8,
    gpu_architecture_policy: []const u8,
    device_family_policy: []const u8,
};

/// Metal 3.1 requires the macOS 14 SDK generation. The linked metallib stays
/// portable across compatible Apple GPUs; concrete device identity belongs in
/// runtime PSO/cache keys, not in this reproducible build policy.
pub const target_policy: TargetPolicy = .{
    .platform = "macos",
    .sdk = manifest.compile_profile.sdk,
    .minimum_deployment_target = "14.0",
    .gpu_architecture_policy = "portable-metallib",
    .device_family_policy = "runtime-compatible-metal3",
};

pub const ToolIdentity = struct {
    version: []const u8,
    sha256: []const u8,
    bytes: u64,
};

/// Measured from the selected full-Xcode toolchain at artifact build time.
/// Finalized manifests require every field; source-only manifests omit the
/// complete value rather than publishing an unattested placeholder.
pub const ToolchainIdentity = struct {
    xcode_version: []const u8,
    xcode_build: []const u8,
    metal_toolchain_component: []const u8,
    sdk_version: []const u8,
    sdk_build: []const u8,
    metal: ToolIdentity,
    metallib: ToolIdentity,
};

/// Runtime-only cache dimension. A metallib is not rebuilt for each device,
/// but PSOs and binary archives must never alias across these values.
pub const DeviceCacheIdentity = struct {
    registry_id: u64,
    architecture_name: []const u8,
    metal_family_set_sha256: []const u8,
    os_build: []const u8,
};

pub fn validateToolchainIdentity(identity: ToolchainIdentity) !void {
    if (identity.xcode_version.len == 0 or identity.xcode_build.len == 0 or
        identity.metal_toolchain_component.len == 0 or identity.sdk_version.len == 0 or
        identity.sdk_build.len == 0)
        return error.IncompleteMetalToolchainIdentity;
    try validateTool(identity.metal);
    try validateTool(identity.metallib);
}

pub fn validateDeviceCacheIdentity(identity: DeviceCacheIdentity) !void {
    if (identity.registry_id == 0 or identity.architecture_name.len == 0 or identity.os_build.len == 0)
        return error.IncompleteMetalDeviceIdentity;
    try validateDigest(identity.metal_family_set_sha256);
}

fn validateTool(tool: ToolIdentity) !void {
    if (tool.version.len == 0 or tool.bytes == 0) return error.IncompleteMetalToolIdentity;
    try validateDigest(tool.sha256);
}

fn validateDigest(encoded: []const u8) !void {
    if (encoded.len != 64) return error.InvalidMetalIdentityDigest;
    var decoded: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&decoded, encoded) catch return error.InvalidMetalIdentityDigest;
    const canonical = std.fmt.bytesToHex(decoded, .lower);
    if (!std.mem.eql(u8, encoded, &canonical)) return error.InvalidMetalIdentityDigest;
}

test "Native metallib target policy is explicit and profile-consistent" {
    try std.testing.expectEqualStrings("macos", target_policy.platform);
    try std.testing.expectEqualStrings(manifest.compile_profile.sdk, target_policy.sdk);
    try std.testing.expectEqualStrings("14.0", target_policy.minimum_deployment_target);
    try std.testing.expectEqualStrings("portable-metallib", target_policy.gpu_architecture_policy);
    try std.testing.expectEqualStrings("runtime-compatible-metal3", target_policy.device_family_policy);
}

test "toolchain and device identities fail closed" {
    const valid_tool = ToolIdentity{
        .version = "Metal compiler version 1",
        .sha256 = "ab" ** 32,
        .bytes = 1024,
    };
    try validateToolchainIdentity(.{
        .xcode_version = "16.0",
        .xcode_build = "16A000",
        .metal_toolchain_component = "com.apple.dt.toolchain.Metal@16A000",
        .sdk_version = "15.0",
        .sdk_build = "24A000",
        .metal = valid_tool,
        .metallib = valid_tool,
    });
    try std.testing.expectError(error.IncompleteMetalToolIdentity, validateToolchainIdentity(.{
        .xcode_version = "16.0",
        .xcode_build = "16A000",
        .metal_toolchain_component = "com.apple.dt.toolchain.Metal@16A000",
        .sdk_version = "15.0",
        .sdk_build = "24A000",
        .metal = .{ .version = "", .sha256 = "ab" ** 32, .bytes = 1024 },
        .metallib = valid_tool,
    }));
    try std.testing.expectError(error.IncompleteMetalToolchainIdentity, validateToolchainIdentity(.{
        .xcode_version = "16.0",
        .xcode_build = "16A000",
        .metal_toolchain_component = "",
        .sdk_version = "15.0",
        .sdk_build = "24A000",
        .metal = valid_tool,
        .metallib = valid_tool,
    }));

    try validateDeviceCacheIdentity(.{
        .registry_id = 1,
        .architecture_name = "Apple GPU",
        .metal_family_set_sha256 = "cd" ** 32,
        .os_build = "24A000",
    });
    try std.testing.expectError(error.IncompleteMetalDeviceIdentity, validateDeviceCacheIdentity(.{
        .registry_id = 0,
        .architecture_name = "Apple GPU",
        .metal_family_set_sha256 = "cd" ** 32,
        .os_build = "24A000",
    }));
}
