//! Streaming envelope and provenance codec for compact Cairo proofs.

const std = @import("std");

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

pub const Error = error{
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
    protocol: anytype,
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

    try writeEnvelopeHeader(writer, total_bytes);
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
    protocol: anytype,
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
    protocol: anytype,
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
