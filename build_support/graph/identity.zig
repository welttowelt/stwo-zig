//! Canonical product identity and retained executable-evidence bindings.

const std = @import("std");
const builtin = @import("builtin");
const build_identity = @import("../build_identity.zig");
const modules = @import("modules.zig");
const encoding = @import("identity/encoding.zig");

const digestBytes = encoding.digestBytes;
const hashBool = encoding.hashBool;
const hashDigest = encoding.hashDigest;
const hashField = encoding.hashField;
const hashInt = encoding.hashInt;
const hashOptionalDigest = encoding.hashOptionalDigest;
const hashOptionalField = encoding.hashOptionalField;

pub const SCHEMA_VERSION: u32 = 2;
pub const EVIDENCE_SCHEMA_VERSION: u32 = 1;
pub const Digest = encoding.Digest;
pub const RuntimeHooks = struct {
    runtime_manifest: []const u8 = "none",
    sdk_manifest: []const u8 = "none",
    aot_manifest: []const u8 = "none",

    pub fn validate(self: RuntimeHooks) !void {
        if (self.runtime_manifest.len == 0) return error.MissingRuntimeManifest;
        if (self.sdk_manifest.len == 0) return error.MissingSdkManifest;
        if (self.aot_manifest.len == 0) return error.MissingAotManifest;
    }
};

pub const CanonicalIdentity = struct {
    schema_version: u32 = SCHEMA_VERSION,
    product: []const u8,
    frontend: []const u8,
    backend: []const u8,
    role: []const u8,
    source_repository: []const u8,
    source_commit: []const u8,
    source_tree: ?[]const u8,
    source_dirty: bool,
    dirty_content_sha256: ?Digest,
    zig_version: []const u8,
    target_arch: []const u8,
    target_os: []const u8,
    target_abi: []const u8,
    cpu_model: []const u8,
    cpu_features_sha256: Digest,
    optimize: []const u8,
    protocol_manifest: []const u8,
    runtime: RuntimeHooks = .{},

    pub fn validate(self: CanonicalIdentity) !void {
        if (self.schema_version != SCHEMA_VERSION) return error.UnsupportedIdentitySchema;
        inline for (.{
            self.product,
            self.frontend,
            self.backend,
            self.role,
            self.source_repository,
            self.source_commit,
            self.zig_version,
            self.target_arch,
            self.target_os,
            self.target_abi,
            self.cpu_model,
            self.optimize,
            self.protocol_manifest,
        }) |field| if (field.len == 0) return error.EmptyIdentityField;
        if (!isLowerHex(self.source_commit, build_identity.COMMIT_HEX_LEN))
            return error.InvalidSourceCommit;
        const tree = self.source_tree orelse return error.MissingSourceTree;
        if (!isLowerHex(tree, build_identity.COMMIT_HEX_LEN)) return error.InvalidSourceTree;
        if (self.source_dirty != (self.dirty_content_sha256 != null))
            return error.InconsistentDirtyIdentity;
        try self.runtime.validate();
    }

    pub fn protocolManifestDigest(self: CanonicalIdentity) Digest {
        return digestBytes(self.protocol_manifest);
    }

    pub fn digest(self: CanonicalIdentity) !Digest {
        try self.validate();
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hashField(&hasher, "stwo-product-identity-v2");
        hashInt(&hasher, self.schema_version);
        hashField(&hasher, self.product);
        hashField(&hasher, self.frontend);
        hashField(&hasher, self.backend);
        hashField(&hasher, self.role);
        hashField(&hasher, self.source_repository);
        hashField(&hasher, self.source_commit);
        hashOptionalField(&hasher, self.source_tree);
        hashBool(&hasher, self.source_dirty);
        hashOptionalDigest(&hasher, self.dirty_content_sha256);
        hashField(&hasher, self.zig_version);
        hashField(&hasher, self.target_arch);
        hashField(&hasher, self.target_os);
        hashField(&hasher, self.target_abi);
        hashField(&hasher, self.cpu_model);
        hashDigest(&hasher, self.cpu_features_sha256);
        hashField(&hasher, self.optimize);
        hashField(&hasher, self.protocol_manifest);
        hashDigest(&hasher, self.protocolManifestDigest());
        hashField(&hasher, self.runtime.runtime_manifest);
        hashField(&hasher, self.runtime.sdk_manifest);
        hashField(&hasher, self.runtime.aot_manifest);
        return hasher.finalResult();
    }
};
pub const EvidenceClass = enum {
    proof_report,
    benchmark,
    profiler_capture,
    cache_record,
    gate_receipt,
};
/// Post-link provenance retained beside an artifact. This type deliberately
/// has no proof-serialization API: identity never enters cryptographic bytes.
pub const RetainedEvidence = struct {
    schema_version: u32 = EVIDENCE_SCHEMA_VERSION,
    class: EvidenceClass,
    product_identity_sha256: Digest,
    executable_sha256: Digest,
    runtime_artifact_sha256: ?Digest = null,

    pub fn digest(self: RetainedEvidence) !Digest {
        if (self.schema_version != EVIDENCE_SCHEMA_VERSION)
            return error.UnsupportedEvidenceSchema;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hashField(&hasher, "stwo-retained-evidence-v1");
        hashInt(&hasher, self.schema_version);
        hashField(&hasher, @tagName(self.class));
        hashDigest(&hasher, self.product_identity_sha256);
        hashDigest(&hasher, self.executable_sha256);
        hashOptionalDigest(&hasher, self.runtime_artifact_sha256);
        return hasher.finalResult();
    }

    pub fn validate(
        self: RetainedEvidence,
        class: EvidenceClass,
        product_identity_sha256: Digest,
        executable_sha256: Digest,
    ) !void {
        _ = try self.digest();
        if (self.class != class) return error.EvidenceClassMismatch;
        if (!std.mem.eql(u8, &self.product_identity_sha256, &product_identity_sha256))
            return error.ProductIdentityMismatch;
        if (!std.mem.eql(u8, &self.executable_sha256, &executable_sha256))
            return error.ExecutableMismatch;
    }
};
pub fn issueReleaseEvidence(
    class: EvidenceClass,
    identity: CanonicalIdentity,
    executable_sha256: Digest,
    runtime_artifact_sha256: ?Digest,
) !RetainedEvidence {
    if (identity.source_dirty) return error.DirtyReleaseIdentity;
    const has_runtime = !std.mem.eql(u8, identity.runtime.runtime_manifest, "none");
    if (has_runtime and runtime_artifact_sha256 == null)
        return error.MissingRuntimeArtifactDigest;
    if (!has_runtime and runtime_artifact_sha256 != null)
        return error.UnexpectedRuntimeArtifactDigest;
    return .{
        .class = class,
        .product_identity_sha256 = try identity.digest(),
        .executable_sha256 = executable_sha256,
        .runtime_artifact_sha256 = runtime_artifact_sha256,
    };
}

pub fn buildOptions(
    b: *std.Build,
    identity: build_identity.Identity,
) *std.Build.Step.Options {
    const tree = persistTree(b, identity);
    const dirty_digest = persistOptionalHex(b, identity.dirty_content_sha256);
    const options = b.addOptions();
    options.addOption([]const u8, "implementation_repository", identity.implementation_repository);
    options.addOption([]const u8, "implementation_commit", persistCommit(b, identity.implementation_commit));
    options.addOption([]const u8, "implementation_tree", tree);
    options.addOption(bool, "implementation_tree_available", identity.implementation_tree != null);
    options.addOption(bool, "implementation_dirty", identity.implementation_dirty);
    options.addOption([]const u8, "dirty_content_sha256", dirty_digest);
    options.addOption(bool, "dirty_content_sha256_available", identity.dirty_content_sha256 != null);
    return options;
}

pub fn productOptions(
    b: *std.Build,
    identity: build_identity.Identity,
    product: modules.Product,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Options {
    return productOptionsWithRuntime(b, identity, product, target, optimize, .{});
}

pub fn productOptionsWithRuntime(
    b: *std.Build,
    identity: build_identity.Identity,
    product: modules.Product,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    runtime: RuntimeHooks,
) *std.Build.Step.Options {
    product.validate() catch |err| std.debug.panic(
        "invalid product identity {s}: {s}",
        .{ product.name, @errorName(err) },
    );
    const canonical = canonicalIdentity(&identity, product, target.result, optimize, runtime);
    const identity_digest = canonical.digest() catch |err| std.debug.panic(
        "invalid canonical identity {s}: {s}",
        .{ product.name, @errorName(err) },
    );
    return generatedOptions(b, canonical, identity_digest);
}

pub fn canonicalIdentity(
    identity: *const build_identity.Identity,
    product: modules.Product,
    target: std.Target,
    optimize: std.builtin.OptimizeMode,
    runtime: RuntimeHooks,
) CanonicalIdentity {
    return .{
        .product = product.name,
        .frontend = product.frontendManifest(),
        .backend = product.backendManifest(),
        .role = @tagName(product.role),
        .source_repository = identity.implementation_repository,
        .source_commit = &identity.implementation_commit,
        .source_tree = if (identity.implementation_tree) |*tree| tree else null,
        .source_dirty = identity.implementation_dirty,
        .dirty_content_sha256 = identity.dirty_content_sha256,
        .zig_version = builtin.zig_version_string,
        .target_arch = @tagName(target.cpu.arch),
        .target_os = @tagName(target.os.tag),
        .target_abi = @tagName(target.abi),
        .cpu_model = target.cpu.model.name,
        .cpu_features_sha256 = cpuFeaturesDigest(target.cpu),
        .optimize = @tagName(optimize),
        .protocol_manifest = product.protocol_features,
        .runtime = runtime,
    };
}

pub fn digestFile(path: []const u8) !Digest {
    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const count = try file.read(&buffer);
        if (count == 0) break;
        hasher.update(buffer[0..count]);
    }
    return hasher.finalResult();
}

fn generatedOptions(
    b: *std.Build,
    canonical: CanonicalIdentity,
    identity_digest: Digest,
) *std.Build.Step.Options {
    const options = b.addOptions();
    options.addOption(u32, "schema_version", canonical.schema_version);
    options.addOption([]const u8, "product", canonical.product);
    options.addOption([]const u8, "frontend", canonical.frontend);
    options.addOption([]const u8, "backend", canonical.backend);
    options.addOption([]const u8, "role", canonical.role);
    options.addOption([]const u8, "protocol_features", canonical.protocol_manifest);
    options.addOption([]const u8, "protocol_manifest_sha256", persistHex(b, canonical.protocolManifestDigest()));
    options.addOption([]const u8, "implementation_repository", canonical.source_repository);
    options.addOption([]const u8, "implementation_commit", persistBytes(b, canonical.source_commit));
    options.addOption(
        []const u8,
        "implementation_tree",
        if (canonical.source_tree) |tree| persistBytes(b, tree) else "unavailable",
    );
    options.addOption(bool, "implementation_tree_available", canonical.source_tree != null);
    options.addOption(bool, "implementation_dirty", canonical.source_dirty);
    options.addOption([]const u8, "dirty_content_sha256", persistOptionalHex(b, canonical.dirty_content_sha256));
    options.addOption(bool, "dirty_content_sha256_available", canonical.dirty_content_sha256 != null);
    options.addOption([]const u8, "zig_version", canonical.zig_version);
    options.addOption([]const u8, "target_arch", canonical.target_arch);
    options.addOption([]const u8, "target_os", canonical.target_os);
    options.addOption([]const u8, "target_abi", canonical.target_abi);
    options.addOption([]const u8, "cpu_model", canonical.cpu_model);
    options.addOption([]const u8, "cpu_features_sha256", persistHex(b, canonical.cpu_features_sha256));
    options.addOption([]const u8, "optimize", canonical.optimize);
    options.addOption([]const u8, "runtime_manifest", canonical.runtime.runtime_manifest);
    options.addOption([]const u8, "sdk_manifest", canonical.runtime.sdk_manifest);
    options.addOption([]const u8, "aot_manifest", canonical.runtime.aot_manifest);
    options.addOption([]const u8, "identity_sha256", persistHex(b, identity_digest));
    return options;
}

fn cpuFeaturesDigest(cpu: std.Target.Cpu) Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (cpu.arch.allFeaturesList()) |feature| {
        if (!cpu.features.isEnabled(feature.index)) continue;
        hashField(&hasher, feature.name);
    }
    return hasher.finalResult();
}

fn isLowerHex(value: []const u8, expected_len: usize) bool {
    if (value.len != expected_len) return false;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
}

fn persistHex(b: *std.Build, digest: Digest) []const u8 {
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return b.allocator.dupe(u8, &encoded) catch @panic("out of memory");
}

fn persistCommit(b: *std.Build, commit: [build_identity.COMMIT_HEX_LEN]u8) []const u8 {
    return persistBytes(b, &commit);
}

fn persistBytes(b: *std.Build, value: []const u8) []const u8 {
    return b.allocator.dupe(u8, value) catch @panic("out of memory");
}

fn persistOptionalHex(b: *std.Build, digest: ?Digest) []const u8 {
    return if (digest) |present| persistHex(b, present) else "unavailable";
}

fn persistTree(b: *std.Build, identity: build_identity.Identity) []const u8 {
    if (identity.implementation_tree) |tree|
        return b.allocator.dupe(u8, &tree) catch @panic("out of memory");
    return "unavailable";
}
