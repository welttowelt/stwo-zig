//! Normalized evidence for the pinned signed-MULH relation defect.
//!
//! This diagnostic calls the production family witness writer and relation
//! entry adapter. It reports the exact range-table requests that production
//! source ingestion rejects; it never repairs, drops, or rewrites a request.

const std = @import("std");
const M31 = @import("stwo_core").fields.m31.M31;
const QM31 = @import("stwo_core").fields.qm31.QM31;
const entry = @import("../air/lookups/entry.zig");
const opcode_entries = @import("../air/lookups/opcode_entries.zig");
const table_schema = @import("../air/lookups/tables/schema.zig");
const opcode_manifest = @import("../opcode_manifest.zig");
const decode = @import("../runner/decode.zig");
const trace = @import("../runner/trace.zig");
const witness_layout = @import("../witness_layout.zig");

pub const SCHEMA = "riscv-mulh-limitation-v1";
pub const LIMITATION_ID = "stark-v-signed-mulh";
pub const REJECTION_CLASS = "range_check_8_11_value_out_of_range";
pub const REJECTED_OUTCOME = "preprocessed_registration_rejected";
pub const ADMISSIBLE_OUTCOME = "preprocessed_registration_admissible";

const raw_digest_domain = "riscv/mulh-limitation/raw-stream/v1\x00";
const range_digest_domain = "riscv/mulh-limitation/range811-stream/v1\x00";
const invalid_digest_domain = "riscv/mulh-limitation/invalid-stream/v1\x00";

pub const InvalidRequest = struct {
    /// Zero-based row within the MULH family, not the execution clock.
    row: u32,
    opcode_id: u32,
    /// Raw production relation declaration index. MULH ranges occupy 9..16.
    request_index: u32,
    tuple: [2]u32,
};

pub const Report = struct {
    family_rows: u32,
    signed_rows: u32,
    unsigned_rows: u32,
    raw_nonzero_entries: u64,
    raw_stream_sha256: [32]u8,
    range811_requests: u64,
    range811_stream_sha256: [32]u8,
    invalid_requests_sha256: [32]u8,
    invalid_requests: []InvalidRequest,

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        allocator.free(self.invalid_requests);
        self.* = undefined;
    }

    pub fn outcome(self: Report) []const u8 {
        return if (self.invalid_requests.len == 0) ADMISSIBLE_OUTCOME else REJECTED_OUTCOME;
    }
};

/// Derive exact family-source evidence from production witness and relation
/// entry generation. Only MULH-family rows are observed; their relative order
/// remains the execution filter order used by production sharding.
pub fn derive(allocator: std.mem.Allocator, execution: *const trace.Trace) !Report {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var raw_hasher = Sha256.init(.{});
    raw_hasher.update(raw_digest_domain);
    var range_hasher = Sha256.init(.{});
    range_hasher.update(range_digest_domain);
    var invalid_hasher = Sha256.init(.{});
    invalid_hasher.update(invalid_digest_domain);
    var invalid: std.ArrayList(InvalidRequest) = .{};
    errdefer invalid.deinit(allocator);

    var family_rows: u32 = 0;
    var signed_rows: u32 = 0;
    var unsigned_rows: u32 = 0;
    var raw_nonzero_entries: u64 = 0;
    var range811_requests: u64 = 0;

    for (execution.rows.items) |row| {
        if (try trace.proofOpcodeFamily(row.opcode) != .mulh) continue;
        const opcode = try decode.proofOpcode(row.opcode);
        const opcode_id = opcode.protocolId();
        switch (opcode) {
            .mulh, .mulhsu => signed_rows += 1,
            .mulhu => unsigned_rows += 1,
            else => unreachable,
        }

        var storage: [trace.MAX_FAMILY_COLUMNS][1]M31 =
            .{.{M31.zero()}} ** trace.MAX_FAMILY_COLUMNS;
        var columns: [trace.MAX_FAMILY_COLUMNS][]M31 = undefined;
        for (&columns, &storage) |*column, *values| column.* = values;
        trace.fillFamilyColumns(&columns, 0, row, .mulh);

        var secure: [trace.MAX_FAMILY_COLUMNS]QM31 = undefined;
        const n_columns = trace.nColumnsForFamily(.mulh);
        for (storage[0..n_columns], secure[0..n_columns]) |values, *value| {
            value.* = QM31.fromBase(values[0]);
        }
        const requests = try opcode_entries.fromMain(.mulh, secure[0..n_columns]);
        for (requests.entries[0..requests.len], 0..) |request, request_index| {
            if (request.numerator.isZero()) continue;
            raw_nonzero_entries += 1;
            hashRequest(&raw_hasher, family_rows, opcode_id, request_index, request);
            if (request.domain != .range_check_8_11) continue;

            range811_requests += 1;
            hashRequest(&range_hasher, family_rows, opcode_id, request_index, request);
            _ = table_schema.indexSecure(.range_check_8_11, request.values[0..request.arity]) catch |err| {
                if (err != error.ValueOutOfRange) return error.UnexpectedRangeRejection;
                const record = InvalidRequest{
                    .row = family_rows,
                    .opcode_id = opcode_id,
                    .request_index = @intCast(request_index),
                    .tuple = .{
                        try baseValue(request.values[0]),
                        try baseValue(request.values[1]),
                    },
                };
                try invalid.append(allocator, record);
                hashRequest(&invalid_hasher, family_rows, opcode_id, request_index, request);
            };
        }
        family_rows += 1;
    }
    if (family_rows == 0) return error.MissingMulhFamily;

    return .{
        .family_rows = family_rows,
        .signed_rows = signed_rows,
        .unsigned_rows = unsigned_rows,
        .raw_nonzero_entries = raw_nonzero_entries,
        .raw_stream_sha256 = raw_hasher.finalResult(),
        .range811_requests = range811_requests,
        .range811_stream_sha256 = range_hasher.finalResult(),
        .invalid_requests_sha256 = invalid_hasher.finalResult(),
        .invalid_requests = try invalid.toOwnedSlice(allocator),
    };
}

const ProvenanceWire = struct {
    implementation_commit: []const u8,
    implementation_dirty: bool,
    oracle_commit: []const u8,
    witness_layout_sha256: []const u8,
};

const SourceWire = struct {
    elf_sha256: []const u8,
    input_sha256: []const u8,
};

const InvalidRequestWire = struct {
    row: u32,
    opcode_id: u32,
    request_index: u32,
    tuple: [2]u32,
    classification: []const u8,
};

const DiagnosticWire = struct {
    schema: []const u8,
    limitation_id: []const u8,
    oracle_commit: []const u8,
    family: []const u8,
    family_rows: u32,
    signed_rows: u32,
    unsigned_rows: u32,
    raw_nonzero_entries: u64,
    raw_stream_sha256: []const u8,
    range811_requests: u64,
    range811_stream_sha256: []const u8,
    invalid_request_count: usize,
    invalid_requests_sha256: []const u8,
    invalid_requests: []const InvalidRequestWire,
    outcome: []const u8,
    provenance: ProvenanceWire,
    source: SourceWire,
};

pub fn encode(
    allocator: std.mem.Allocator,
    report: Report,
    implementation_commit: []const u8,
    implementation_dirty: bool,
    elf_bytes: []const u8,
    input_bytes: []const u8,
) ![]u8 {
    var elf_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(elf_bytes, &elf_digest, .{});
    var input_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(input_bytes, &input_digest, .{});
    const elf_hex = std.fmt.bytesToHex(elf_digest, .lower);
    const input_hex = std.fmt.bytesToHex(input_digest, .lower);
    const layout_hex = std.fmt.bytesToHex(witness_layout.digest(), .lower);
    const raw_hex = std.fmt.bytesToHex(report.raw_stream_sha256, .lower);
    const range_hex = std.fmt.bytesToHex(report.range811_stream_sha256, .lower);
    const invalid_hex = std.fmt.bytesToHex(report.invalid_requests_sha256, .lower);
    const invalid = try allocator.alloc(InvalidRequestWire, report.invalid_requests.len);
    defer allocator.free(invalid);
    for (report.invalid_requests, invalid) |source, *destination| {
        destination.* = .{
            .row = source.row,
            .opcode_id = source.opcode_id,
            .request_index = source.request_index,
            .tuple = source.tuple,
            .classification = REJECTION_CLASS,
        };
    }

    return std.json.Stringify.valueAlloc(allocator, DiagnosticWire{
        .schema = SCHEMA,
        .limitation_id = LIMITATION_ID,
        .oracle_commit = opcode_manifest.stark_v_revision,
        .family = "mulh",
        .family_rows = report.family_rows,
        .signed_rows = report.signed_rows,
        .unsigned_rows = report.unsigned_rows,
        .raw_nonzero_entries = report.raw_nonzero_entries,
        .raw_stream_sha256 = &raw_hex,
        .range811_requests = report.range811_requests,
        .range811_stream_sha256 = &range_hex,
        .invalid_request_count = report.invalid_requests.len,
        .invalid_requests_sha256 = &invalid_hex,
        .invalid_requests = invalid,
        .outcome = report.outcome(),
        .provenance = .{
            .implementation_commit = implementation_commit,
            .implementation_dirty = implementation_dirty,
            .oracle_commit = opcode_manifest.stark_v_revision,
            .witness_layout_sha256 = &layout_hex,
        },
        .source = .{ .elf_sha256 = &elf_hex, .input_sha256 = &input_hex },
    }, .{});
}

fn baseValue(value: QM31) !u32 {
    return (value.tryIntoM31() catch return error.NonBaseRangeTuple).toU32();
}

fn hashRequest(
    hasher: *std.crypto.hash.sha2.Sha256,
    row: u32,
    opcode_id: u32,
    request_index: usize,
    request: entry.Entry,
) void {
    hashU32(hasher, row);
    hashU32(hasher, opcode_id);
    hashU32(hasher, @intCast(request_index));
    hasher.update(&.{@intFromEnum(request.domain)});
    hashQm31(hasher, request.numerator);
    hasher.update(&.{request.arity});
    for (request.values[0..request.arity]) |value| hashQm31(hasher, value);
}

fn hashQm31(hasher: *std.crypto.hash.sha2.Sha256, value: QM31) void {
    for (value.toM31Array()) |limb| hashU32(hasher, limb.toU32());
}

fn hashU32(hasher: *std.crypto.hash.sha2.Sha256, value: u32) void {
    var encoded: [4]u8 = undefined;
    std.mem.writeInt(u32, &encoded, value, .little);
    hasher.update(&encoded);
}
