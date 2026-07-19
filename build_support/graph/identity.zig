//! Stable generated options for source and focused product identities.

const std = @import("std");
const build_identity = @import("../build_identity.zig");
const modules = @import("modules.zig");

pub fn buildOptions(
    b: *std.Build,
    identity: build_identity.Identity,
) *std.Build.Step.Options {
    const implementation_tree = persistTree(b, identity);
    const options = b.addOptions();
    options.addOption([]const u8, "implementation_commit", &identity.implementation_commit);
    options.addOption([]const u8, "implementation_tree", implementation_tree);
    options.addOption(bool, "implementation_tree_available", identity.implementation_tree != null);
    options.addOption(bool, "implementation_dirty", identity.implementation_dirty);
    return options;
}

pub fn productOptions(
    b: *std.Build,
    identity: build_identity.Identity,
    product: modules.Product,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Options {
    product.validate() catch |err| std.debug.panic(
        "invalid product identity {s}: {s}",
        .{ product.name, @errorName(err) },
    );
    const cpu_features = cpuFeaturesDigest(target.result.cpu);
    const digest = productDigest(identity, product, target.result, optimize, cpu_features);
    const cpu_features_hex = persistHex(b, cpu_features);
    const identity_hex = persistHex(b, digest);
    const implementation_tree = persistTree(b, identity);

    const options = b.addOptions();
    options.addOption(u32, "schema_version", 1);
    options.addOption([]const u8, "product", product.name);
    options.addOption([]const u8, "frontend", product.frontendManifest());
    options.addOption([]const u8, "backend", product.backendManifest());
    options.addOption([]const u8, "role", @tagName(product.role));
    options.addOption([]const u8, "protocol_features", product.protocol_features);
    options.addOption([]const u8, "implementation_commit", &identity.implementation_commit);
    options.addOption([]const u8, "implementation_tree", implementation_tree);
    options.addOption(bool, "implementation_tree_available", identity.implementation_tree != null);
    options.addOption(bool, "implementation_dirty", identity.implementation_dirty);
    options.addOption([]const u8, "target_arch", @tagName(target.result.cpu.arch));
    options.addOption([]const u8, "target_os", @tagName(target.result.os.tag));
    options.addOption([]const u8, "target_abi", @tagName(target.result.abi));
    options.addOption([]const u8, "cpu_model", target.result.cpu.model.name);
    options.addOption([]const u8, "cpu_features_sha256", cpu_features_hex);
    options.addOption([]const u8, "optimize", @tagName(optimize));
    options.addOption([]const u8, "identity_sha256", identity_hex);
    return options;
}

fn cpuFeaturesDigest(cpu: std.Target.Cpu) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (cpu.arch.allFeaturesList()) |feature| {
        if (!cpu.features.isEnabled(feature.index)) continue;
        hashField(&hasher, feature.name);
    }
    return hasher.finalResult();
}

fn productDigest(
    identity: build_identity.Identity,
    product: modules.Product,
    target: std.Target,
    optimize: std.builtin.OptimizeMode,
    cpu_features: [32]u8,
) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashField(&hasher, "stwo-product-identity-v1");
    hashField(&hasher, &identity.implementation_commit);
    if (identity.implementation_tree) |tree|
        hashField(&hasher, &tree)
    else
        hashField(&hasher, "unavailable");
    hashField(&hasher, if (identity.implementation_dirty) "dirty" else "clean");
    hashField(&hasher, product.name);
    hashField(&hasher, product.frontendManifest());
    hashField(&hasher, product.backendManifest());
    hashField(&hasher, @tagName(product.role));
    hashField(&hasher, product.protocol_features);
    hashField(&hasher, @tagName(target.cpu.arch));
    hashField(&hasher, @tagName(target.os.tag));
    hashField(&hasher, @tagName(target.abi));
    hashField(&hasher, target.cpu.model.name);
    hasher.update(&cpu_features);
    hashField(&hasher, @tagName(optimize));
    return hasher.finalResult();
}

fn hashField(hasher: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, value.len, .big);
    hasher.update(&length);
    hasher.update(value);
}

fn persistHex(b: *std.Build, digest: [32]u8) []const u8 {
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return b.allocator.dupe(u8, &encoded) catch @panic("out of memory");
}

fn persistTree(b: *std.Build, identity: build_identity.Identity) []const u8 {
    if (identity.implementation_tree) |tree|
        return b.allocator.dupe(u8, &tree) catch @panic("out of memory");
    return "unavailable";
}
