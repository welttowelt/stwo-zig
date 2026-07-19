//! Canonical source and product identity mutation fleet.

const std = @import("std");
const build_identity = @import("build_identity.zig");
const identity = @import("graph/identity.zig");

test {
    _ = build_identity;
    _ = identity;
}

fn testIdentity() identity.CanonicalIdentity {
    return .{
        .product = "stwo-native-cpu",
        .frontend = "native-examples",
        .backend = "cpu",
        .role = "cli",
        .source_repository = build_identity.IMPLEMENTATION_REPOSITORY,
        .source_commit = "11" ** 20,
        .source_tree = "22" ** 20,
        .source_dirty = false,
        .dirty_content_sha256 = null,
        .zig_version = "0.15.2",
        .target_arch = "aarch64",
        .target_os = "macos",
        .target_abi = "none",
        .cpu_model = "apple_m1",
        .cpu_features_sha256 = .{3} ** 32,
        .optimize = "ReleaseFast",
        .protocol_manifest = "native-examples-v1+lifted-pcs-v1",
    };
}

fn digestBytes(value: []const u8) identity.Digest {
    var result: identity.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(value, &result, .{});
    return result;
}

test "every canonical field mutation changes product identity" {
    const baseline = testIdentity();
    const expected = try baseline.digest();
    var mutations = [_]identity.CanonicalIdentity{
        baseline, baseline, baseline, baseline, baseline, baseline, baseline, baseline,
        baseline, baseline, baseline, baseline, baseline, baseline, baseline, baseline,
        baseline, baseline, baseline, baseline,
    };
    mutations[0].schema_version = 1;
    mutations[1].product = "stwo-aggregate";
    mutations[2].frontend = "aggregate";
    mutations[3].backend = "metal";
    mutations[4].role = "benchmark";
    mutations[5].source_repository = "https://example.invalid/fork";
    mutations[6].source_commit = "33" ** 20;
    mutations[7].source_tree = "44" ** 20;
    mutations[8].source_dirty = true;
    mutations[8].dirty_content_sha256 = .{5} ** 32;
    mutations[9].zig_version = "0.16.0";
    mutations[10].target_arch = "x86_64";
    mutations[11].target_os = "linux";
    mutations[12].target_abi = "gnu";
    mutations[13].cpu_model = "baseline";
    mutations[14].cpu_features_sha256 = .{6} ** 32;
    mutations[15].optimize = "ReleaseSafe";
    mutations[16].protocol_manifest = "substituted-capability";
    mutations[17].runtime.runtime_manifest = "metal-runtime-v2";
    mutations[18].runtime.sdk_manifest = "macosx27-metal4.0";
    mutations[19].runtime.aot_manifest = "shader-archive-v2";
    for (mutations, 0..) |mutation, index| {
        const actual = mutation.digest() catch |err| {
            if (index == 0) {
                try std.testing.expectEqual(error.UnsupportedIdentitySchema, err);
                continue;
            }
            return err;
        };
        try std.testing.expect(!std.mem.eql(u8, &expected, &actual));
    }
}

test "retained evidence rejects surface executable and AOT substitution" {
    const product_digest = try testIdentity().digest();
    const executable_digest = digestBytes("focused executable");
    const evidence = identity.RetainedEvidence{
        .class = .gate_receipt,
        .product_identity_sha256 = product_digest,
        .executable_sha256 = executable_digest,
        .runtime_artifact_sha256 = digestBytes("authenticated metallib"),
    };
    try evidence.validate(.gate_receipt, product_digest, executable_digest);
    try std.testing.expectError(
        error.EvidenceClassMismatch,
        evidence.validate(.benchmark, product_digest, executable_digest),
    );
    try std.testing.expectError(
        error.ProductIdentityMismatch,
        evidence.validate(.gate_receipt, digestBytes("aggregate product"), executable_digest),
    );
    try std.testing.expectError(
        error.ExecutableMismatch,
        evidence.validate(.gate_receipt, product_digest, digestBytes("substituted executable")),
    );
    var substituted_aot = evidence;
    substituted_aot.runtime_artifact_sha256 = digestBytes("substituted metallib");
    try std.testing.expect(!std.mem.eql(u8, &(try evidence.digest()), &(try substituted_aot.digest())));
}

test "dirty identity is all-or-nothing" {
    var product_identity = testIdentity();
    product_identity.source_dirty = true;
    try std.testing.expectError(error.InconsistentDirtyIdentity, product_identity.digest());
    product_identity.dirty_content_sha256 = .{7} ** 32;
    _ = try product_identity.digest();
    try std.testing.expectError(
        error.DirtyReleaseIdentity,
        identity.issueReleaseEvidence(.gate_receipt, product_identity, digestBytes("executable"), null),
    );
}

test "executable evidence uses exact post-link file bytes" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(.{ .sub_path = "candidate", .data = "first executable" });
    const path = try temporary.dir.realpathAlloc(std.testing.allocator, "candidate");
    defer std.testing.allocator.free(path);
    const first = try identity.digestFile(path);
    try temporary.dir.writeFile(.{ .sub_path = "candidate", .data = "second executable" });
    const second = try identity.digestFile(path);
    try std.testing.expect(!std.mem.eql(u8, &first, &second));

    const product_identity = testIdentity();
    inline for (std.meta.tags(identity.EvidenceClass)) |class| {
        const evidence = try identity.issueReleaseEvidence(class, product_identity, second, null);
        try evidence.validate(class, try product_identity.digest(), second);
    }

    var metal = product_identity;
    metal.backend = "metal";
    metal.runtime = .{
        .runtime_manifest = "metal-runtime-v1",
        .sdk_manifest = "metal3.1",
        .aot_manifest = "authenticated-aot-v1",
    };
    try std.testing.expectError(
        error.MissingRuntimeArtifactDigest,
        identity.issueReleaseEvidence(.gate_receipt, metal, second, null),
    );
    _ = try identity.issueReleaseEvidence(.gate_receipt, metal, second, digestBytes("metallib"));
}
