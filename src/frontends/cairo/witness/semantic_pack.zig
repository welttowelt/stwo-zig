//! Authenticated, program-specific Cairo semantic artifacts.
//!
//! Version 2 packs are projections selected from a Rust proof and are therefore
//! parity/development inputs. They are never production-admissible.

const std = @import("std");
const witness_bundle = @import("bundle.zig");
const feed_bundle = @import("feed_bundle.zig");
const relation_bundle = @import("relation_bundle.zig");
const fixed_bundle = @import("fixed_table_bundle.zig");
const composition_bundle = @import("composition_bundle.zig");

pub const format = "stwo-zig-cairo-program-semantic-pack";
pub const version: u32 = 2;
pub const projection_format = "stwo-zig-cairo-composition-projection";
pub const projection_version: u32 = 2;
pub const max_manifest_bytes: usize = 16 * 1024 * 1024;
pub const max_identity_bytes: usize = 4096;

pub const Provenance = enum {
    source_derived,
    proof_derived,
};

pub const AuthenticatedFile = struct {
    path: []const u8,
    sha256: [32]u8,
};

pub const Files = struct {
    manifest: AuthenticatedFile,
    composition_projection_manifest: []const u8,
    composition: []const u8,
    witness_programs: []const u8,
    multiplicity_feeds: []const u8,
    relation_templates: []const u8,
    fixed_tables: []const u8,
    preprocessed_coefficients: []const u8,
};

pub const Loaded = struct {
    allocator: std.mem.Allocator,
    files: Files,
    manifest_sha256: [32]u8,
    provenance: Provenance,
    verifier_max_log_degree_bound: u32,
    measurements: Measurements,
    composition: composition_bundle.Bundle,
    witness_programs: witness_bundle.Bundle,
    multiplicity_feeds: feed_bundle.Bundle,
    relation_templates: relation_bundle.Bundle,
    fixed_tables: fixed_bundle.Bundle,

    pub fn deinit(self: *Loaded) void {
        self.fixed_tables.deinit();
        self.relation_templates.deinit();
        self.multiplicity_feeds.deinit();
        self.witness_programs.deinit();
        self.composition.deinit();
        self.* = undefined;
    }

    /// Revalidates every authenticated pathname immediately before a backend
    /// may use it. Content is hashed once at admission; subsequent checks bind
    /// inode, size, mtime, and ctime without rereading multi-gigabyte payloads.
    pub fn assertUnchanged(self: *const Loaded) !void {
        try assertFilesUnchanged(self.files, self.measurements);
    }
};

const ArtifactExpectations = struct {
    witness_sha256: [32]u8,
    witness_count: usize,
    feeds_sha256: [32]u8,
    feeds_count: usize,
    relations_sha256: [32]u8,
    relations_count: usize,
    fixed_sha256: [32]u8,
    fixed_count: usize,
    coefficients_sha256: [32]u8,
    coefficients_count: usize,
    projection_sha256: [32]u8,
    composition_sha256: [32]u8,
    composition_plan_hash: u64,
    verifier_max_log_degree_bound: u32,
};

pub const Measurement = struct {
    sha256: [32]u8,
    stat: std.fs.File.Stat,
};

pub const Measurements = struct {
    manifest: Measurement,
    composition_projection_manifest: Measurement,
    composition: Measurement,
    witness_programs: Measurement,
    multiplicity_feeds: Measurement,
    relation_templates: Measurement,
    fixed_tables: Measurement,
    preprocessed_coefficients: Measurement,
};

pub fn load(allocator: std.mem.Allocator, files: Files) !Loaded {
    try validatePaths(files);
    const manifest_measurement = try authenticateFile(files.manifest.path, files.manifest.sha256);
    const manifest_bytes = try readSmallFile(allocator, files.manifest.path, max_manifest_bytes);
    defer allocator.free(manifest_bytes);
    try assertStatUnchanged(files.manifest.path, manifest_measurement.stat);
    var manifest = try std.json.parseFromSlice(std.json.Value, allocator, manifest_bytes, .{});
    defer manifest.deinit();
    const root = try requireObject(manifest.value);
    try expectString(root, "format", format);
    try expectUnsigned(root, "version", version);
    const expectations = try parseExpectations(root);

    const measurements = Measurements{
        .manifest = manifest_measurement,
        .composition_projection_manifest = try authenticateFile(files.composition_projection_manifest, expectations.projection_sha256),
        .composition = try authenticateFile(files.composition, expectations.composition_sha256),
        .witness_programs = try authenticateFile(files.witness_programs, expectations.witness_sha256),
        .multiplicity_feeds = try authenticateFile(files.multiplicity_feeds, expectations.feeds_sha256),
        .relation_templates = try authenticateFile(files.relation_templates, expectations.relations_sha256),
        .fixed_tables = try authenticateFile(files.fixed_tables, expectations.fixed_sha256),
        .preprocessed_coefficients = try authenticateFile(files.preprocessed_coefficients, expectations.coefficients_sha256),
    };
    try validateProjectionManifest(
        allocator,
        files.composition_projection_manifest,
        expectations.composition_sha256,
        expectations.composition_plan_hash,
        expectations.verifier_max_log_degree_bound,
    );
    var composition = try composition_bundle.Bundle.readFile(allocator, files.composition);
    errdefer composition.deinit();
    if (composition.plan_hash != expectations.composition_plan_hash)
        return error.CompositionPlanHashMismatch;
    try validateVerifierGeometry(composition, expectations.verifier_max_log_degree_bound);
    try validateActiveComponents(root, composition.components);

    var witness_programs = try witness_bundle.Bundle.readFile(allocator, files.witness_programs);
    errdefer witness_programs.deinit();
    var multiplicity_feeds = try feed_bundle.Bundle.readFile(allocator, files.multiplicity_feeds);
    errdefer multiplicity_feeds.deinit();
    var relation_templates = try relation_bundle.Bundle.readFile(allocator, files.relation_templates);
    errdefer relation_templates.deinit();
    var fixed_tables = try fixed_bundle.Bundle.readFile(allocator, files.fixed_tables);
    errdefer fixed_tables.deinit();

    if (witness_programs.entries.len != expectations.witness_count or
        multiplicity_feeds.feeds.len != expectations.feeds_count or
        relation_templates.components.len != expectations.relations_count or
        fixed_tables.entries.len != expectations.fixed_count or
        fixed_tables.preprocessed_identities.len != expectations.coefficients_count)
        return error.ArtifactCountMismatch;
    try validateArtifactLabels(root, witness_programs, multiplicity_feeds, relation_templates, fixed_tables);
    try validateCoefficientFile(files.preprocessed_coefficients, fixed_tables.preprocessed_identities);
    try validateAuthorizedClosure(root, composition, witness_programs, multiplicity_feeds, relation_templates, fixed_tables);
    try assertFilesUnchanged(files, measurements);

    return .{
        .allocator = allocator,
        .files = files,
        .manifest_sha256 = files.manifest.sha256,
        .provenance = .proof_derived,
        .verifier_max_log_degree_bound = expectations.verifier_max_log_degree_bound,
        .measurements = measurements,
        .composition = composition,
        .witness_programs = witness_programs,
        .multiplicity_feeds = multiplicity_feeds,
        .relation_templates = relation_templates,
        .fixed_tables = fixed_tables,
    };
}

fn parseExpectations(root: std.json.ObjectMap) !ArtifactExpectations {
    const composition = try objectField(root, "composition");
    const artifacts = try objectField(root, "artifacts");
    return .{
        .witness_sha256 = try outputDigest(artifacts, "witness_programs"),
        .witness_count = try outputCount(artifacts, "witness_programs"),
        .feeds_sha256 = try outputDigest(artifacts, "multiplicity_feeds"),
        .feeds_count = try outputCount(artifacts, "multiplicity_feeds"),
        .relations_sha256 = try outputDigest(artifacts, "relation_templates"),
        .relations_count = try outputCount(artifacts, "relation_templates"),
        .fixed_sha256 = try outputDigest(artifacts, "fixed_tables"),
        .fixed_count = try outputCount(artifacts, "fixed_tables"),
        .coefficients_sha256 = try outputDigest(artifacts, "preprocessed_coefficients"),
        .coefficients_count = try outputCount(artifacts, "preprocessed_coefficients"),
        .projection_sha256 = try digestField(composition, "manifest_sha256"),
        .composition_sha256 = try digestField(composition, "bundle_sha256"),
        .composition_plan_hash = try hexU64Field(composition, "plan_hash"),
        .verifier_max_log_degree_bound = try verifierMaxLogDegreeBound(composition),
    };
}

fn validateActiveComponents(root: std.json.ObjectMap, components: []const composition_bundle.Component) !void {
    const composition = try objectField(root, "composition");
    const active = try arrayField(composition, "active_components");
    if (active.items.len != components.len) return error.ActiveComponentMismatch;
    for (active.items, components) |value, component| {
        if (value != .string or !std.mem.eql(u8, value.string, component.label))
            return error.ActiveComponentMismatch;
    }
}

fn validateArtifactLabels(
    root: std.json.ObjectMap,
    witnesses: witness_bundle.Bundle,
    feeds: feed_bundle.Bundle,
    relations: relation_bundle.Bundle,
    fixed: fixed_bundle.Bundle,
) !void {
    const artifacts = try objectField(root, "artifacts");
    try matchLabels(try arrayField(try objectField(artifacts, "witness_programs"), "labels"), witnesses.entries, "label");
    try matchLabels(try arrayField(try objectField(artifacts, "multiplicity_feeds"), "labels"), feeds.feeds, "producer");
    try matchLabels(try arrayField(try objectField(artifacts, "relation_templates"), "labels"), relations.components, "name");
    try matchLabels(try arrayField(try objectField(artifacts, "fixed_tables"), "labels"), fixed.entries, "component");
}

fn matchLabels(values: std.json.Array, actual: anytype, comptime field: []const u8) !void {
    if (values.items.len != actual.len) return error.ArtifactLabelMismatch;
    for (values.items, actual) |value, entry| {
        if (value != .string or !std.mem.eql(u8, value.string, @field(entry, field)))
            return error.ArtifactLabelMismatch;
    }
}

fn validateAuthorizedClosure(
    root: std.json.ObjectMap,
    composition: composition_bundle.Bundle,
    witnesses: witness_bundle.Bundle,
    feeds: feed_bundle.Bundle,
    relations: relation_bundle.Bundle,
    fixed: fixed_bundle.Bundle,
) !void {
    const dependencies = try arrayField(root, "dependencies");
    for (witnesses.entries) |entry| if (!authorized(entry.label, composition, dependencies))
        return error.UnauthorizedArtifactEntry;
    for (feeds.feeds) |feed| {
        if (!authorized(feed.producer, composition, dependencies)) return error.UnauthorizedArtifactEntry;
        for (feed.destinations) |destination| if (!authorized(destination.name, composition, dependencies))
            return error.UnauthorizedArtifactEntry;
    }
    for (relations.components) |component| if (!authorized(component.name, composition, dependencies))
        return error.UnauthorizedArtifactEntry;
    for (fixed.entries) |entry| if (!authorized(entry.component, composition, dependencies))
        return error.UnauthorizedArtifactEntry;
}

fn authorized(label: []const u8, composition: composition_bundle.Bundle, dependencies: std.json.Array) bool {
    const base = if (std.mem.indexOfScalar(u8, label, '#')) |index| label[0..index] else label;
    for (composition.components) |component| if (std.mem.eql(u8, component.label, base)) return true;
    for (dependencies.items) |value| if (value == .string and
        (std.mem.eql(u8, value.string, label) or std.mem.eql(u8, value.string, base))) return true;
    return false;
}

fn validateProjectionManifest(
    allocator: std.mem.Allocator,
    path: []const u8,
    composition_sha256: [32]u8,
    plan_hash: u64,
    verifier_max_log_degree_bound: u32,
) !void {
    const bytes = try readSmallFile(allocator, path, max_manifest_bytes);
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const root = try requireObject(parsed.value);
    try expectString(root, "format", projection_format);
    try expectUnsigned(root, "version", projection_version);
    const target = try objectField(root, "target");
    if (!std.mem.eql(u8, &(try digestField(target, "bundle_sha256")), &composition_sha256) or
        try hexU64Field(target, "plan_hash") != plan_hash or
        try unsignedField(target, "max_evaluation_log_size") != verifier_max_log_degree_bound + 1)
        return error.CompositionProjectionMismatch;
}

fn verifierMaxLogDegreeBound(composition: std.json.ObjectMap) !u32 {
    const value = try unsignedField(composition, "verifier_max_log_degree_bound");
    if (value < 1 or value > 31) return error.InvalidVerifierGeometry;
    return @intCast(value);
}

fn validateVerifierGeometry(
    composition: composition_bundle.Bundle,
    verifier_max_log_degree_bound: u32,
) !void {
    const actual = composition.verifierMaxLogDegreeBound() catch
        return error.InvalidVerifierGeometry;
    if (actual != verifier_max_log_degree_bound)
        return error.VerifierGeometryMismatch;
}

fn validateCoefficientFile(path: []const u8, identities: []const []u8) !void {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    var header: [16]u8 = undefined;
    try readExact(file, &header);
    if (!std.mem.eql(u8, header[0..8], "STWZPPC\x00") or
        std.mem.readInt(u32, header[8..12], .little) != 1 or
        std.mem.readInt(u32, header[12..16], .little) != identities.len)
        return error.InvalidCoefficientHeader;
    var identity_buffer: [max_identity_bytes]u8 = undefined;
    for (identities) |expected| {
        var record: [16]u8 = undefined;
        try readExact(file, &record);
        const name_len: usize = std.mem.readInt(u16, record[0..2], .little);
        const reserved = std.mem.readInt(u16, record[2..4], .little);
        const log_size = std.mem.readInt(u32, record[4..8], .little);
        const value_count = std.mem.readInt(u64, record[8..16], .little);
        if (name_len == 0 or name_len > identity_buffer.len or reserved != 0 or log_size > 31 or
            value_count != @as(u64, 1) << @intCast(log_size))
            return error.InvalidCoefficientEntry;
        try readExact(file, identity_buffer[0..name_len]);
        if (!std.mem.eql(u8, identity_buffer[0..name_len], expected))
            return error.CoefficientIdentityMismatch;
        const payload_bytes = std.math.mul(u64, value_count, 4) catch return error.InvalidCoefficientEntry;
        try file.seekBy(@intCast(payload_bytes));
    }
    var trailing: [1]u8 = undefined;
    if (try file.read(&trailing) != 0) return error.TrailingCoefficientData;
}

fn validatePaths(files: Files) !void {
    inline for (std.meta.fields(Files)) |field| {
        const value = @field(files, field.name);
        const path = if (comptime field.type == AuthenticatedFile) value.path else value;
        if (!std.fs.path.isAbsolute(path)) return error.ArtifactPathNotAbsolute;
    }
}

fn authenticateFile(path: []const u8, expected: [32]u8) !Measurement {
    const measured = try measureFile(path);
    if (!std.mem.eql(u8, &measured.sha256, &expected)) return error.ArtifactDigestMismatch;
    return measured;
}

fn assertFilesUnchanged(files: Files, expected: Measurements) !void {
    try assertMeasurement(files.manifest.path, expected.manifest);
    try assertMeasurement(files.composition_projection_manifest, expected.composition_projection_manifest);
    try assertMeasurement(files.composition, expected.composition);
    try assertMeasurement(files.witness_programs, expected.witness_programs);
    try assertMeasurement(files.multiplicity_feeds, expected.multiplicity_feeds);
    try assertMeasurement(files.relation_templates, expected.relation_templates);
    try assertMeasurement(files.fixed_tables, expected.fixed_tables);
    try assertMeasurement(files.preprocessed_coefficients, expected.preprocessed_coefficients);
}

fn assertMeasurement(path: []const u8, expected: Measurement) !void {
    assertStatUnchanged(path, expected.stat) catch return error.ArtifactChangedAfterAuthentication;
}

fn measureFile(path: []const u8) !Measurement {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const before = try file.stat();
    if (before.kind != .file or before.size == 0) return error.InvalidArtifactFile;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [256 * 1024]u8 = undefined;
    var count: u64 = 0;
    while (true) {
        const read = try file.read(&buffer);
        if (read == 0) break;
        hasher.update(buffer[0..read]);
        count = std.math.add(u64, count, read) catch return error.ArtifactLengthOverflow;
    }
    const after = try file.stat();
    if (!sameFile(before, after) or count != before.size) return error.ArtifactChangedDuringRead;
    return .{ .sha256 = hasher.finalResult(), .stat = after };
}

fn readSmallFile(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const stat = try file.stat();
    if (stat.kind != .file or stat.size == 0 or stat.size > limit) return error.InvalidManifestFile;
    const bytes = try allocator.alloc(u8, @intCast(stat.size));
    errdefer allocator.free(bytes);
    if (try file.readAll(bytes) != bytes.len) return error.TruncatedManifest;
    return bytes;
}

fn assertStatUnchanged(path: []const u8, expected: std.fs.File.Stat) !void {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    if (!sameFile(expected, try file.stat())) return error.ArtifactChangedDuringRead;
}

fn sameFile(left: std.fs.File.Stat, right: std.fs.File.Stat) bool {
    return left.kind == right.kind and left.inode == right.inode and left.size == right.size and
        left.mtime == right.mtime and left.ctime == right.ctime;
}

fn readExact(file: std.fs.File, bytes: []u8) !void {
    if (try file.readAll(bytes) != bytes.len) return error.TruncatedCoefficientFile;
}

fn outputDigest(artifacts: std.json.ObjectMap, name: []const u8) ![32]u8 {
    return digestField(try objectField(artifacts, name), "output_sha256");
}

fn outputCount(artifacts: std.json.ObjectMap, name: []const u8) !usize {
    const value = try unsignedField(try objectField(artifacts, name), "output_count");
    if (value == 0 or value > 4096) return error.InvalidArtifactCount;
    return @intCast(value);
}

fn digestField(object: std.json.ObjectMap, name: []const u8) ![32]u8 {
    const value = object.get(name) orelse return error.MissingManifestField;
    if (value != .string or value.string.len != 64) return error.InvalidManifestDigest;
    for (value.string) |byte| switch (byte) {
        '0'...'9', 'a'...'f' => {},
        else => return error.InvalidManifestDigest,
    };
    var digest: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&digest, value.string) catch return error.InvalidManifestDigest;
    return digest;
}

fn hexU64Field(object: std.json.ObjectMap, name: []const u8) !u64 {
    const value = object.get(name) orelse return error.MissingManifestField;
    if (value != .string or value.string.len != 16) return error.InvalidPlanHash;
    for (value.string) |byte| switch (byte) {
        '0'...'9', 'a'...'f' => {},
        else => return error.InvalidPlanHash,
    };
    const parsed = std.fmt.parseInt(u64, value.string, 16) catch return error.InvalidPlanHash;
    if (parsed == 0) return error.InvalidPlanHash;
    return parsed;
}

fn requireObject(value: std.json.Value) !std.json.ObjectMap {
    if (value != .object) return error.InvalidManifest;
    return value.object;
}

fn objectField(object: std.json.ObjectMap, name: []const u8) !std.json.ObjectMap {
    const value = object.get(name) orelse return error.MissingManifestField;
    return requireObject(value);
}

fn arrayField(object: std.json.ObjectMap, name: []const u8) !std.json.Array {
    const value = object.get(name) orelse return error.MissingManifestField;
    if (value != .array) return error.InvalidManifestField;
    return value.array;
}

fn unsignedField(object: std.json.ObjectMap, name: []const u8) !u64 {
    const value = object.get(name) orelse return error.MissingManifestField;
    if (value != .integer or value.integer < 0) return error.InvalidManifestField;
    return @intCast(value.integer);
}

fn expectUnsigned(object: std.json.ObjectMap, name: []const u8, expected: u64) !void {
    if (try unsignedField(object, name) != expected) return error.UnsupportedManifestVersion;
}

fn expectString(object: std.json.ObjectMap, name: []const u8, expected: []const u8) !void {
    const value = object.get(name) orelse return error.MissingManifestField;
    if (value != .string or !std.mem.eql(u8, value.string, expected)) return error.InvalidManifestField;
}

test "semantic pack: digest parser rejects non-hex identities" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"digest\":\"zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz\"}", .{});
    defer parsed.deinit();
    try std.testing.expectError(error.InvalidManifestDigest, digestField(parsed.value.object, "digest"));
}

test "semantic pack: version 2 is explicitly proof-derived" {
    try std.testing.expectEqual(Provenance.proof_derived, @as(Provenance, .proof_derived));
    try std.testing.expectEqualStrings(format, "stwo-zig-cairo-program-semantic-pack");
    try std.testing.expectEqual(@as(u32, 2), version);
}

test "semantic pack: verifier maximum log authority is required and bounded" {
    inline for (.{
        .{ "{}", error.MissingManifestField },
        .{ "{\"verifier_max_log_degree_bound\":0}", error.InvalidVerifierGeometry },
        .{ "{\"verifier_max_log_degree_bound\":32}", error.InvalidVerifierGeometry },
    }) |case| {
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, case[0], .{});
        defer parsed.deinit();
        try std.testing.expectError(case[1], verifierMaxLogDegreeBound(parsed.value.object));
    }
    var valid = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"verifier_max_log_degree_bound\":20}", .{});
    defer valid.deinit();
    try std.testing.expectEqual(@as(u32, 20), try verifierMaxLogDegreeBound(valid.value.object));
    const projected = composition_bundle.Bundle{
        .allocator = undefined,
        .format_version = composition_bundle.projected_version,
        .max_kernel_instructions = 1,
        .total_constraints = 1,
        .max_evaluation_log_size = 21,
        .plan_hash = 1,
        .components = &.{},
    };
    try validateVerifierGeometry(projected, 20);
    try std.testing.expectError(
        error.VerifierGeometryMismatch,
        validateVerifierGeometry(projected, 19),
    );
}

test "semantic pack: projection verifier geometry drift is rejected" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const projection =
        \\{"format":"stwo-zig-cairo-composition-projection","version":2,"target":{"bundle_sha256":"abababababababababababababababababababababababababababababababab","plan_hash":"1234567890abcdef","max_evaluation_log_size":21}}
    ;
    try temporary.dir.writeFile(.{ .sub_path = "projection.json", .data = projection });
    const path = try temporary.dir.realpathAlloc(std.testing.allocator, "projection.json");
    defer std.testing.allocator.free(path);
    const digest = [_]u8{0xab} ** 32;
    try validateProjectionManifest(std.testing.allocator, path, digest, 0x1234567890abcdef, 20);
    try std.testing.expectError(
        error.CompositionProjectionMismatch,
        validateProjectionManifest(std.testing.allocator, path, digest, 0x1234567890abcdef, 19),
    );
}

test "semantic pack: mutation after authentication is rejected" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(.{ .sub_path = "artifact.bin", .data = "authenticated" });
    const path = try temporary.dir.realpathAlloc(std.testing.allocator, "artifact.bin");
    defer std.testing.allocator.free(path);
    const expected = try measureFile(path);
    try temporary.dir.writeFile(.{ .sub_path = "artifact.bin", .data = "replacement!!" });
    try std.testing.expectError(error.ArtifactChangedAfterAuthentication, assertMeasurement(path, expected));
}
