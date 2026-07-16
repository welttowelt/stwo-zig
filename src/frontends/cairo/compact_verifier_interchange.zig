//! Compact Metal proof interchange consumed by the pinned Rust Cairo verifier.
//!
//! This module owns only the authenticated wire boundary. The statement and
//! proof payloads are produced elsewhere; this code encodes the pinned compact
//! protocol, binds every payload and caller-supplied production identity into
//! canonical provenance JSON, and streams one strict `STWZCVE/1` envelope.

const std = @import("std");

pub const protocol_magic = [_]u8{ 'S', 'T', 'W', 'Z', 'C', 'P', '1', 0 };
pub const protocol_version: u16 = 1;
pub const protocol_header_bytes: usize = 112;
pub const component_enable_count: u32 = 83;
pub const trace_tree_column_counts = [4]u32{ 161, 3449, 2268, 8 };

pub const envelope_magic = [_]u8{ 'S', 'T', 'W', 'Z', 'C', 'V', 'E', 0 };
pub const envelope_version: u16 = 1;
pub const envelope_header_bytes: usize = 32;
pub const section_header_bytes: usize = 48;
pub const section_count: u32 = 4;
pub const section_flag_mandatory: u16 = 1;
pub const max_envelope_bytes: u64 = 1 << 30;

pub const compact_provenance_source = "metal_prover_service_v1";
pub const compact_proof_serialization = "resident_sn2_bundle_v1";
pub const compact_provenance_bytes: usize = 728;

const decommit_header_words: u32 = 8;
const decommit_tree_meta_words: u32 = 16;
const decommit_record_count: u32 = 12;
const query_count: u32 = 70;
const minimum_decommitment_words: u32 = decommit_header_words +
    decommit_record_count * decommit_tree_meta_words + query_count * 2;

pub const Error = error{
    InvalidInteractionClaimWordCount,
    InvalidInteractionSumCount,
    InvalidSampledValueWordCount,
    InvalidDecommitmentCapacity,
    InvalidTraceTreeColumnCounts,
    InvalidIdentityDigest,
    EmptyStatement,
    InvalidStatementFile,
    StatementFileChanged,
    ProofLengthMismatch,
    InvalidProofFile,
    ProofFileChanged,
    SectionTooLarge,
    EnvelopeTooLarge,
    LengthOverflow,
    NoncanonicalProvenanceLength,
};

/// Names and units match the resident runner's `proof_layout` report.
pub const CompactProofLayoutV1 = struct {
    interaction_claim_words: u32,
    sampled_value_words: u32,
    decommitment_capacity_words: u32,

    pub fn protocol(self: CompactProofLayoutV1, channel_salt: u32) Error!CompactProtocolV1 {
        if (self.interaction_claim_words == 0 or self.interaction_claim_words % 4 != 0)
            return Error.InvalidInteractionClaimWordCount;
        const result = CompactProtocolV1{
            .channel_salt = channel_salt,
            .interaction_sum_count = self.interaction_claim_words / 4,
            .sampled_value_words = self.sampled_value_words,
            .decommitment_capacity_words = self.decommitment_capacity_words,
        };
        try result.validate();
        return result;
    }
};

/// The exact bounded protocol accepted by Rust `CompactProtocolV1::decode`.
pub const CompactProtocolV1 = struct {
    channel_salt: u32 = 0,
    interaction_sum_count: u32,
    sampled_value_words: u32,
    decommitment_capacity_words: u32,
    trace_columns: [4]u32 = trace_tree_column_counts,

    pub fn validate(self: CompactProtocolV1) Error!void {
        if (self.interaction_sum_count == 0 or
            self.interaction_sum_count > component_enable_count)
        {
            return Error.InvalidInteractionSumCount;
        }
        if (self.sampled_value_words == 0 or self.sampled_value_words % 4 != 0)
            return Error.InvalidSampledValueWordCount;
        if (self.decommitment_capacity_words < minimum_decommitment_words)
            return Error.InvalidDecommitmentCapacity;
        if (!std.mem.eql(u32, &self.trace_columns, &trace_tree_column_counts))
            return Error.InvalidTraceTreeColumnCounts;
    }

    pub fn proofWordCount(self: CompactProtocolV1) Error!usize {
        try self.validate();
        var words: usize = 4 * 8; // Four Blake2s commitments.
        words = try addLength(words, try mulLength(self.interaction_sum_count, 4));
        words = try addLength(words, 2); // Interaction PoW nonce.
        words = try addLength(words, self.sampled_value_words);
        words = try addLength(words, 8 * 8); // Eight FRI commitments.
        words = try addLength(words, 4); // One QM31 final-line coefficient.
        words = try addLength(words, 2); // Query PoW nonce.
        words = try addLength(words, self.decommitment_capacity_words);
        return words;
    }

    pub fn proofByteCount(self: CompactProtocolV1) Error!usize {
        return mulLength(try self.proofWordCount(), 4);
    }

    pub fn encode(self: CompactProtocolV1) Error![protocol_header_bytes]u8 {
        try self.validate();
        var bytes = [_]u8{0} ** protocol_header_bytes;
        @memcpy(bytes[0..protocol_magic.len], &protocol_magic);
        putU16(&bytes, 8, protocol_version);
        putU16(&bytes, 10, protocol_header_bytes);
        putU32(&bytes, 16, 1); // Blake2s channel.
        putU32(&bytes, 20, 1); // resident_sn2_bundle_v1 serialization.
        putU32(&bytes, 24, 1); // Canonical preprocessed trace.
        putU32(&bytes, 28, self.channel_salt);
        putU32(&bytes, 32, 26); // Query PoW bits.
        putU32(&bytes, 36, 1); // Log blowup factor.
        putU32(&bytes, 40, query_count);
        putU32(&bytes, 44, 0); // Last-layer degree bound.
        putU32(&bytes, 48, 3); // FRI fold step.
        putU32(&bytes, 52, std.math.maxInt(u32)); // No lifting.
        putU32(&bytes, 56, 24); // Interaction PoW bits.
        putU32(&bytes, 60, 4); // Commitment count.
        putU32(&bytes, 64, 4); // Sampled tree count.
        putU32(&bytes, 68, 8); // FRI tree count.
        putU32(&bytes, 72, 1); // Final line coefficient count.
        putU32(&bytes, 76, decommit_record_count);
        putU32(&bytes, 80, self.interaction_sum_count);
        putU32(&bytes, 84, self.sampled_value_words);
        putU32(&bytes, 88, self.decommitment_capacity_words);
        for (self.trace_columns, 0..) |count, index| {
            putU32(&bytes, 92 + index * 4, count);
        }
        // Flags at 12 and the reserved word at 108 remain canonical zeroes.
        return bytes;
    }
};

/// Hex digests have no defaults by design: the production service must supply
/// the identities measured for the request that produced this proof.
pub const CompactProvenanceIdentities = struct {
    adapted_input_sha256: []const u8,
    artifact_manifest_sha256: []const u8,
    runner_executable_sha256: []const u8,
    backend_executable_sha256: []const u8,

    pub fn validate(self: CompactProvenanceIdentities) Error!void {
        inline for (.{
            self.adapted_input_sha256,
            self.artifact_manifest_sha256,
            self.runner_executable_sha256,
            self.backend_executable_sha256,
        }) |digest| {
            if (!isLowerSha256(digest)) return Error.InvalidIdentityDigest;
        }
    }
};

pub const EnvelopeSummary = struct {
    total_bytes: u64,
    protocol_sha256: [32]u8,
    statement_sha256: [32]u8,
    proof_sha256: [32]u8,
    provenance_sha256: [32]u8,
};

/// Writes one complete envelope without allocating a second proof-sized buffer.
/// All sizes, caller identities, section digests, and provenance are validated
/// before the first byte is written. The caller owns flushing and publication.
pub fn writeEnvelopeV1(
    writer: *std.Io.Writer,
    protocol: CompactProtocolV1,
    statement: []const u8,
    proof: []const u8,
    identities: CompactProvenanceIdentities,
) !EnvelopeSummary {
    const protocol_bytes = try protocol.encode();
    if (statement.len == 0) return Error.EmptyStatement;
    if (proof.len != try protocol.proofByteCount()) return Error.ProofLengthMismatch;
    try identities.validate();
    try validateSectionLength(.protocol, protocol_bytes.len);
    try validateSectionLength(.statement, statement.len);
    try validateSectionLength(.proof, proof.len);

    const protocol_digest = sha256(&protocol_bytes);
    const statement_digest = sha256(statement);
    const proof_digest = sha256(proof);
    const provenance = try encodeCompactProvenanceV1(
        protocol_digest,
        statement_digest,
        proof_digest,
        identities,
    );
    try validateSectionLength(.provenance, provenance.len);
    const provenance_digest = sha256(&provenance);

    var total_bytes: u64 = envelope_header_bytes;
    inline for (.{ protocol_bytes.len, statement.len, proof.len, provenance.len }) |payload_len| {
        total_bytes = try addLengthU64(total_bytes, section_header_bytes);
        total_bytes = try addLengthU64(total_bytes, payload_len);
    }
    if (total_bytes > max_envelope_bytes) return Error.EnvelopeTooLarge;

    var header = [_]u8{0} ** envelope_header_bytes;
    @memcpy(header[0..envelope_magic.len], &envelope_magic);
    putU16(&header, 8, envelope_version);
    putU16(&header, 10, envelope_header_bytes);
    putU32(&header, 16, section_count);
    putU64(&header, 24, total_bytes);

    try writer.writeAll(&header);
    try writeSection(writer, .protocol, &protocol_bytes, protocol_digest);
    try writeSection(writer, .statement, statement, statement_digest);
    try writeSection(writer, .proof, proof, proof_digest);
    try writeSection(writer, .provenance, &provenance, provenance_digest);

    return .{
        .total_bytes = total_bytes,
        .protocol_sha256 = protocol_digest,
        .statement_sha256 = statement_digest,
        .proof_sha256 = proof_digest,
        .provenance_sha256 = provenance_digest,
    };
}

/// File-backed variant for the production runner, whose compact proof is
/// already published to a temporary path. It measures the file before output,
/// then streams and hashes it a second time instead of allocating proof bytes.
/// On any returned error the caller must discard its envelope temporary file.
pub fn writeEnvelopeFromProofPathV1(
    writer: *std.Io.Writer,
    protocol: CompactProtocolV1,
    statement: []const u8,
    proof_path: []const u8,
    identities: CompactProvenanceIdentities,
) !EnvelopeSummary {
    const protocol_bytes = try protocol.encode();
    if (statement.len == 0) return Error.EmptyStatement;
    try identities.validate();
    try validateSectionLength(.protocol, protocol_bytes.len);
    try validateSectionLength(.statement, statement.len);

    const proof_file = try openReadOnly(proof_path);
    defer proof_file.close();
    const initial_stat = try proof_file.stat();
    if (initial_stat.kind != .file) return Error.InvalidProofFile;
    const expected_proof_bytes = try protocol.proofByteCount();
    if (initial_stat.size != expected_proof_bytes) return Error.ProofLengthMismatch;
    try validateSectionLength(.proof, expected_proof_bytes);

    var proof_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var measured_bytes: u64 = 0;
    var scratch: [64 * 1024]u8 = undefined;
    while (true) {
        const count = try proof_file.read(&scratch);
        if (count == 0) break;
        proof_hasher.update(scratch[0..count]);
        measured_bytes = try addLengthU64(measured_bytes, count);
    }
    const measured_stat = try proof_file.stat();
    if (measured_bytes != initial_stat.size or !sameFileIdentity(initial_stat, measured_stat))
        return Error.ProofFileChanged;
    const proof_digest = proof_hasher.finalResult();
    const protocol_digest = sha256(&protocol_bytes);
    const statement_digest = sha256(statement);
    const provenance = try encodeCompactProvenanceV1(
        protocol_digest,
        statement_digest,
        proof_digest,
        identities,
    );
    try validateSectionLength(.provenance, provenance.len);
    const provenance_digest = sha256(&provenance);

    var total_bytes: u64 = envelope_header_bytes;
    inline for (.{ protocol_bytes.len, statement.len, expected_proof_bytes, provenance.len }) |payload_len| {
        total_bytes = try addLengthU64(total_bytes, section_header_bytes);
        total_bytes = try addLengthU64(total_bytes, payload_len);
    }
    if (total_bytes > max_envelope_bytes) return Error.EnvelopeTooLarge;
    if (!sameFileIdentity(initial_stat, try proof_file.stat())) return Error.ProofFileChanged;

    try writeEnvelopeHeader(writer, total_bytes);
    try writeSection(writer, .protocol, &protocol_bytes, protocol_digest);
    try writeSection(writer, .statement, statement, statement_digest);
    try writeSectionHeader(writer, .proof, expected_proof_bytes, proof_digest);
    try proof_file.seekTo(0);
    var streamed_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var streamed_bytes: u64 = 0;
    while (true) {
        const count = try proof_file.read(&scratch);
        if (count == 0) break;
        try writer.writeAll(scratch[0..count]);
        streamed_hasher.update(scratch[0..count]);
        streamed_bytes = try addLengthU64(streamed_bytes, count);
    }
    const final_stat = try proof_file.stat();
    if (streamed_bytes != initial_stat.size or
        !sameFileIdentity(initial_stat, final_stat) or
        !std.mem.eql(u8, &proof_digest, &streamed_hasher.finalResult()))
    {
        return Error.ProofFileChanged;
    }
    try writeSection(writer, .provenance, &provenance, provenance_digest);

    return .{
        .total_bytes = total_bytes,
        .protocol_sha256 = protocol_digest,
        .statement_sha256 = statement_digest,
        .proof_sha256 = proof_digest,
        .provenance_sha256 = provenance_digest,
    };
}

/// Convenience for the runner's exclusive compact-statement output. Only the
/// much smaller statement is snapshotted; the proof remains double-pass
/// streamed by `writeEnvelopeFromProofPathV1`.
pub fn writeEnvelopeFromPathsV1(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    protocol: CompactProtocolV1,
    statement_path: []const u8,
    proof_path: []const u8,
    identities: CompactProvenanceIdentities,
) !EnvelopeSummary {
    const statement_file = try openReadOnly(statement_path);
    defer statement_file.close();
    const initial_stat = try statement_file.stat();
    if (initial_stat.kind != .file) return Error.InvalidStatementFile;
    if (initial_stat.size == 0) return Error.EmptyStatement;
    try validateSectionLength(.statement, std.math.cast(usize, initial_stat.size) orelse
        return Error.SectionTooLarge);
    const statement_len = std.math.cast(usize, initial_stat.size) orelse
        return Error.SectionTooLarge;
    const statement = try allocator.alloc(u8, statement_len);
    defer allocator.free(statement);
    const bytes_read = try statement_file.readAll(statement);
    const final_stat = try statement_file.stat();
    if (bytes_read != statement.len or !sameFileIdentity(initial_stat, final_stat))
        return Error.StatementFileChanged;
    return writeEnvelopeFromProofPathV1(
        writer,
        protocol,
        statement,
        proof_path,
        identities,
    );
}

pub fn encodeCompactProvenanceV1(
    protocol_sha256: [32]u8,
    statement_sha256: [32]u8,
    proof_sha256: [32]u8,
    identities: CompactProvenanceIdentities,
) ![compact_provenance_bytes]u8 {
    try identities.validate();
    const protocol_hex = std.fmt.bytesToHex(protocol_sha256, .lower);
    const statement_hex = std.fmt.bytesToHex(statement_sha256, .lower);
    const proof_hex = std.fmt.bytesToHex(proof_sha256, .lower);
    var bytes: [compact_provenance_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try writer.writeAll("{\"schema_version\":1,\"source\":\"");
    try writer.writeAll(compact_provenance_source);
    try writer.writeAll("\",\"proof_serialization\":\"");
    try writer.writeAll(compact_proof_serialization);
    try writer.writeAll("\",\"protocol_sha256\":\"");
    try writer.writeAll(&protocol_hex);
    try writer.writeAll("\",\"statement_sha256\":\"");
    try writer.writeAll(&statement_hex);
    try writer.writeAll("\",\"proof_sha256\":\"");
    try writer.writeAll(&proof_hex);
    try writer.writeAll("\",\"adapted_input_sha256\":\"");
    try writer.writeAll(identities.adapted_input_sha256);
    try writer.writeAll("\",\"artifact_manifest_sha256\":\"");
    try writer.writeAll(identities.artifact_manifest_sha256);
    try writer.writeAll("\",\"runner_executable_sha256\":\"");
    try writer.writeAll(identities.runner_executable_sha256);
    try writer.writeAll("\",\"backend_executable_sha256\":\"");
    try writer.writeAll(identities.backend_executable_sha256);
    try writer.writeAll("\"}");
    if (writer.buffered().len != compact_provenance_bytes)
        return Error.NoncanonicalProvenanceLength;
    return bytes;
}

const SectionKind = enum(u16) {
    protocol = 1,
    statement = 2,
    proof = 3,
    provenance = 4,
};

fn writeSection(
    writer: *std.Io.Writer,
    kind: SectionKind,
    payload: []const u8,
    digest: [32]u8,
) !void {
    try writeSectionHeader(writer, kind, payload.len, digest);
    try writer.writeAll(payload);
}

fn writeSectionHeader(
    writer: *std.Io.Writer,
    kind: SectionKind,
    payload_len: usize,
    digest: [32]u8,
) !void {
    var header = [_]u8{0} ** section_header_bytes;
    putU16(&header, 0, @intFromEnum(kind));
    putU16(&header, 2, section_flag_mandatory);
    putU64(&header, 8, @intCast(payload_len));
    @memcpy(header[16..48], &digest);
    try writer.writeAll(&header);
}

fn writeEnvelopeHeader(writer: *std.Io.Writer, total_bytes: u64) !void {
    var header = [_]u8{0} ** envelope_header_bytes;
    @memcpy(header[0..envelope_magic.len], &envelope_magic);
    putU16(&header, 8, envelope_version);
    putU16(&header, 10, envelope_header_bytes);
    putU32(&header, 16, section_count);
    putU64(&header, 24, total_bytes);
    try writer.writeAll(&header);
}

fn validateSectionLength(kind: SectionKind, len: usize) Error!void {
    if (len == 0) return switch (kind) {
        .statement => Error.EmptyStatement,
        else => Error.SectionTooLarge,
    };
    const maximum: u64 = switch (kind) {
        .protocol => 4 << 20,
        .statement => 256 << 20,
        .proof => 512 << 20,
        .provenance => 16 << 20,
    };
    if (len > maximum) return Error.SectionTooLarge;
}

fn sha256(payload: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &digest, .{});
    return digest;
}

fn openReadOnly(path: []const u8) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) return std.fs.openFileAbsolute(path, .{});
    return std.fs.cwd().openFile(path, .{});
}

fn sameFileIdentity(left: std.fs.File.Stat, right: std.fs.File.Stat) bool {
    return left.inode == right.inode and
        left.size == right.size and
        left.mtime == right.mtime and
        left.ctime == right.ctime;
}

fn isLowerSha256(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| switch (byte) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

fn addLength(left: anytype, right: anytype) Error!usize {
    const right_usize = std.math.cast(usize, right) orelse return Error.LengthOverflow;
    return std.math.add(usize, left, right_usize) catch Error.LengthOverflow;
}

fn mulLength(left: anytype, right: anytype) Error!usize {
    const left_usize = std.math.cast(usize, left) orelse return Error.LengthOverflow;
    const right_usize = std.math.cast(usize, right) orelse return Error.LengthOverflow;
    return std.math.mul(usize, left_usize, right_usize) catch Error.LengthOverflow;
}

fn addLengthU64(left: u64, right: anytype) Error!u64 {
    const right_u64 = std.math.cast(u64, right) orelse return Error.LengthOverflow;
    return std.math.add(u64, left, right_u64) catch Error.LengthOverflow;
}

fn putU16(bytes: []u8, offset: usize, value: anytype) void {
    std.mem.writeInt(u16, bytes[offset..][0..2], @intCast(value), .little);
}

fn putU32(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}

fn putU64(bytes: []u8, offset: usize, value: u64) void {
    std.mem.writeInt(u64, bytes[offset..][0..8], value, .little);
}

fn digestFromHex(encoded: []const u8) ![32]u8 {
    var digest: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&digest, encoded);
    return digest;
}

test "compact protocol matches the Rust-accepted SN2 golden bytes" {
    const protocol = try (CompactProofLayoutV1{
        .interaction_claim_words = 58 * 4,
        .sampled_value_words = 24_440,
        .decommitment_capacity_words = 2_077_800,
    }).protocol(0);
    const encoded = try protocol.encode();
    const encoded_hex = std.fmt.bytesToHex(encoded, .lower);
    try std.testing.expectEqualStrings(
        "5354575a43503100010070000000000001000000010000000100000000000000" ++
            "1a00000001000000460000000000000003000000ffffffff1800000004000000" ++
            "0400000008000000010000000c0000003a000000785f000068b41f00a1000000" ++
            "790d0000dc0800000800000000000000",
        &encoded_hex,
    );
    const digest_hex = std.fmt.bytesToHex(sha256(&encoded), .lower);
    try std.testing.expectEqualStrings(
        "539751a53034c0b279bd023a04a54b203cda5a9a4acdbba83159a9790dc1cfa4",
        &digest_hex,
    );
    try std.testing.expectEqual(@as(usize, 2_102_576), try protocol.proofWordCount());
    try std.testing.expectEqual(@as(usize, 8_410_304), try protocol.proofByteCount());
}

test "runner proof layout rejects a partial interaction sum" {
    try std.testing.expectError(
        Error.InvalidInteractionClaimWordCount,
        (CompactProofLayoutV1{
            .interaction_claim_words = 231,
            .sampled_value_words = 24_440,
            .decommitment_capacity_words = 2_077_800,
        }).protocol(0),
    );
}

test "compact provenance exactly matches the Rust diagnostic envelope" {
    const diagnostic_identity =
        "1497eb76b21031ce730621b4be360b634fbf99e528d2827e479e63823fbabbc3";
    const provenance = try encodeCompactProvenanceV1(
        try digestFromHex("539751a53034c0b279bd023a04a54b203cda5a9a4acdbba83159a9790dc1cfa4"),
        try digestFromHex("36c41bd4fd5bb256dcef94d15084e46dc1c30c1b99f82de1036162dfb9fb2623"),
        try digestFromHex("5c9fe8577d83aac0c9a42d3e482e471c653e3d459304cb9310c411b283aa9052"),
        .{
            .adapted_input_sha256 = diagnostic_identity,
            .artifact_manifest_sha256 = diagnostic_identity,
            .runner_executable_sha256 = diagnostic_identity,
            .backend_executable_sha256 = diagnostic_identity,
        },
    );
    try std.testing.expectEqualStrings(
        "{\"schema_version\":1,\"source\":\"metal_prover_service_v1\"," ++
            "\"proof_serialization\":\"resident_sn2_bundle_v1\"," ++
            "\"protocol_sha256\":\"539751a53034c0b279bd023a04a54b203cda5a9a4acdbba83159a9790dc1cfa4\"," ++
            "\"statement_sha256\":\"36c41bd4fd5bb256dcef94d15084e46dc1c30c1b99f82de1036162dfb9fb2623\"," ++
            "\"proof_sha256\":\"5c9fe8577d83aac0c9a42d3e482e471c653e3d459304cb9310c411b283aa9052\"," ++
            "\"adapted_input_sha256\":\"1497eb76b21031ce730621b4be360b634fbf99e528d2827e479e63823fbabbc3\"," ++
            "\"artifact_manifest_sha256\":\"1497eb76b21031ce730621b4be360b634fbf99e528d2827e479e63823fbabbc3\"," ++
            "\"runner_executable_sha256\":\"1497eb76b21031ce730621b4be360b634fbf99e528d2827e479e63823fbabbc3\"," ++
            "\"backend_executable_sha256\":\"1497eb76b21031ce730621b4be360b634fbf99e528d2827e479e63823fbabbc3\"}",
        &provenance,
    );
    const digest_hex = std.fmt.bytesToHex(sha256(&provenance), .lower);
    try std.testing.expectEqualStrings(
        "d136a422d855fa43c287410cf19f9402d17ceb038442fe2f26aacf7636d46b65",
        &digest_hex,
    );
}

test "envelope writer emits canonical ordered mandatory sections" {
    const protocol = CompactProtocolV1{
        .interaction_sum_count = 1,
        .sampled_value_words = 4,
        .decommitment_capacity_words = minimum_decommitment_words,
    };
    const proof = [_]u8{0x5a} ** (try protocol.proofByteCount());
    const statement = "compact-statement";
    const identities = CompactProvenanceIdentities{
        .adapted_input_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .artifact_manifest_sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .runner_executable_sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        .backend_executable_sha256 = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
    };
    const expected_len = envelope_header_bytes + 4 * section_header_bytes +
        protocol_header_bytes + statement.len + proof.len + compact_provenance_bytes;
    var encoded: [expected_len]u8 = undefined;
    var writer = std.Io.Writer.fixed(&encoded);
    const summary = try writeEnvelopeV1(&writer, protocol, statement, &proof, identities);
    try std.testing.expectEqual(expected_len, writer.buffered().len);
    try std.testing.expectEqual(@as(u64, expected_len), summary.total_bytes);
    try std.testing.expectEqualSlices(u8, &envelope_magic, encoded[0..8]);
    try std.testing.expectEqual(envelope_version, std.mem.readInt(u16, encoded[8..10], .little));
    try std.testing.expectEqual(@as(u16, envelope_header_bytes), std.mem.readInt(u16, encoded[10..12], .little));
    try std.testing.expectEqual(section_count, std.mem.readInt(u32, encoded[16..20], .little));
    try std.testing.expectEqual(@as(u64, expected_len), std.mem.readInt(u64, encoded[24..32], .little));

    const protocol_payload = try protocol.encode();
    const provenance_payload = try encodeCompactProvenanceV1(
        summary.protocol_sha256,
        summary.statement_sha256,
        summary.proof_sha256,
        identities,
    );
    const payloads = [_][]const u8{ &protocol_payload, statement, &proof, &provenance_payload };
    var cursor: usize = envelope_header_bytes;
    for (payloads, 1..) |payload, kind| {
        try std.testing.expectEqual(@as(u16, @intCast(kind)), std.mem.readInt(u16, encoded[cursor..][0..2], .little));
        try std.testing.expectEqual(section_flag_mandatory, std.mem.readInt(u16, encoded[cursor + 2 ..][0..2], .little));
        try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, encoded[cursor + 4 ..][0..4], .little));
        try std.testing.expectEqual(@as(u64, payload.len), std.mem.readInt(u64, encoded[cursor + 8 ..][0..8], .little));
        try std.testing.expectEqualSlices(u8, &sha256(payload), encoded[cursor + 16 .. cursor + 48]);
        cursor += section_header_bytes;
        try std.testing.expectEqualSlices(u8, payload, encoded[cursor .. cursor + payload.len]);
        cursor += payload.len;
    }
    try std.testing.expectEqual(encoded.len, cursor);
}

test "proof-path writer streams the same canonical envelope as proof bytes" {
    const protocol = try (CompactProofLayoutV1{
        .interaction_claim_words = 4,
        .sampled_value_words = 4,
        .decommitment_capacity_words = minimum_decommitment_words,
    }).protocol(0);
    const proof = [_]u8{0x73} ** 1808;
    try std.testing.expectEqual(proof.len, try protocol.proofByteCount());
    const statement = "compact-statement";
    const identities = CompactProvenanceIdentities{
        .adapted_input_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .artifact_manifest_sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .runner_executable_sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        .backend_executable_sha256 = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
    };
    const expected_len = envelope_header_bytes + 4 * section_header_bytes +
        protocol_header_bytes + statement.len + proof.len + compact_provenance_bytes;
    var direct_bytes: [expected_len]u8 = undefined;
    var direct_writer = std.Io.Writer.fixed(&direct_bytes);
    const direct_summary = try writeEnvelopeV1(
        &direct_writer,
        protocol,
        statement,
        &proof,
        identities,
    );

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    {
        const file = try temporary.dir.createFile("proof.bin", .{ .exclusive = true });
        defer file.close();
        try file.writeAll(&proof);
        try file.sync();
    }
    {
        const file = try temporary.dir.createFile("statement.bin", .{ .exclusive = true });
        defer file.close();
        try file.writeAll(statement);
        try file.sync();
    }
    const proof_path = try temporary.dir.realpathAlloc(std.testing.allocator, "proof.bin");
    defer std.testing.allocator.free(proof_path);
    var streamed_bytes: [expected_len]u8 = undefined;
    var streamed_writer = std.Io.Writer.fixed(&streamed_bytes);
    const streamed_summary = try writeEnvelopeFromProofPathV1(
        &streamed_writer,
        protocol,
        statement,
        proof_path,
        identities,
    );
    try std.testing.expectEqual(direct_summary, streamed_summary);
    try std.testing.expectEqualSlices(u8, &direct_bytes, &streamed_bytes);

    const statement_path = try temporary.dir.realpathAlloc(std.testing.allocator, "statement.bin");
    defer std.testing.allocator.free(statement_path);
    var path_bytes: [expected_len]u8 = undefined;
    var path_writer = std.Io.Writer.fixed(&path_bytes);
    const path_summary = try writeEnvelopeFromPathsV1(
        std.testing.allocator,
        &path_writer,
        protocol,
        statement_path,
        proof_path,
        identities,
    );
    try std.testing.expectEqual(direct_summary, path_summary);
    try std.testing.expectEqualSlices(u8, &direct_bytes, &path_bytes);
}

test "interchange rejects invalid geometry and provenance before writing" {
    const bad_protocol = CompactProtocolV1{
        .interaction_sum_count = 0,
        .sampled_value_words = 4,
        .decommitment_capacity_words = minimum_decommitment_words,
    };
    try std.testing.expectError(Error.InvalidInteractionSumCount, bad_protocol.encode());

    const protocol = CompactProtocolV1{
        .interaction_sum_count = 1,
        .sampled_value_words = 4,
        .decommitment_capacity_words = minimum_decommitment_words,
    };
    var encoded: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&encoded);
    try std.testing.expectError(Error.ProofLengthMismatch, writeEnvelopeV1(
        &writer,
        protocol,
        "statement",
        "short-proof",
        .{
            .adapted_input_sha256 = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            .artifact_manifest_sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            .runner_executable_sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
            .backend_executable_sha256 = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        },
    ));
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);

    const proof = [_]u8{0} ** (try protocol.proofByteCount());
    try std.testing.expectError(Error.InvalidIdentityDigest, writeEnvelopeV1(
        &writer,
        protocol,
        "statement",
        &proof,
        .{
            .adapted_input_sha256 = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            .artifact_manifest_sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            .runner_executable_sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
            .backend_executable_sha256 = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        },
    ));
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
}
