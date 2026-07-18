//! Versioned proof envelope for the staged Stark-V RV32IM adapter.
//!
//! This is a publication contract, not a release claim. Artifacts using this
//! schema remain explicitly `not_release_gated` until opcode semantics and the
//! Merkle/Poseidon closure are constrained by the RISC-V AIR.

const std = @import("std");
const atomic_file = @import("atomic_file.zig");

pub const SCHEMA_VERSION: u32 = 2;
pub const EXCHANGE_MODE = "riscv_proof_json_wire_v2";
pub const RELEASE_STATUS = "not_release_gated";
pub const GENERATOR = "zig";
pub const AIR = "stark_v_rv32im";
pub const ORACLE_REPOSITORY = "https://github.com/ClementWalter/stark-v";
pub const ORACLE_COMMIT = "d478f783055aa0d73a93768a433a3c6c31c91d1c";
pub const IMPLEMENTATION_REPOSITORY = "https://github.com/teddyjfpender/stwo-zig";
pub const MAX_ARTIFACT_BYTES: usize = 256 * 1024 * 1024;
pub const MAX_PROOF_BYTES: usize = 128 * 1024 * 1024;
pub const MAX_COMPONENTS: usize = 256;
pub const MAX_INFRA_COMPONENTS: usize = 512;
const M31_MODULUS: u32 = 0x7fff_ffff;

pub const Qm31Wire = [4]u32;
pub const MemoryClaimsWire = [4]Qm31Wire;
pub const OpcodeMemoryClaimsWire = [3]Qm31Wire;

pub const FriConfigWire = struct {
    log_blowup_factor: u32,
    log_last_layer_degree_bound: u32,
    n_queries: u64,
    fold_step: u32 = 1,
};

pub const PcsConfigWire = struct {
    pow_bits: u32,
    fri_config: FriConfigWire,
    lifting_log_size: ?u32 = null,
};

pub const SourceWire = struct {
    elf_sha256: []const u8,
    input_sha256: []const u8,
};

pub const ProvenanceWire = struct {
    oracle_repository: []const u8,
    oracle_commit: []const u8,
    implementation_repository: []const u8,
};

pub const OutputWordWire = struct {
    addr: u32,
    value: u32,
    clock: u32,
};

pub const PublicDataWire = struct {
    initial_pc: u32,
    final_pc: u32,
    clock: u32,
    initial_regs: [32]u32,
    final_regs: [32]u32,
    reg_last_clock: [32]u32,
    program_root: ?u32,
    initial_rw_root: ?u32,
    final_rw_root: ?u32,
    input_start: u32,
    input_len: u32,
    input_words: []const u32,
    output_len: u32,
    output_len_addr: u32,
    output_data_addr: u32,
    output_words: []const OutputWordWire,
};

pub const ComponentWire = struct {
    family: u8,
    log_size: u32,
    n_rows: u32,
    n_columns: u32,
};

pub const InfraComponentWire = struct {
    kind: u32,
    log_size: u32,
    n_rows: u32,
    n_columns: u32,
};

pub const StatementWire = struct {
    initial_pc: u32,
    final_pc: u32,
    total_steps: u32,
    components: []const ComponentWire,
    infrastructure: []const InfraComponentWire,
    public_data: PublicDataWire,
};

pub const InteractionClaimWire = struct {
    interaction_pow: u64,
    state_claims: []const Qm31Wire,
    program_claims: []const Qm31Wire,
    opcode_memory_claims: []const OpcodeMemoryClaimsWire,
    rom_claim: Qm31Wire,
    memory_claims: []const MemoryClaimsWire,
};

/// JSON envelope reserved for CPU proofs while the adapter is staged.
/// `proof_bytes_hex` is the canonical Stwo JSON proof wire encoded as hex.
pub const Artifact = struct {
    schema_version: u32,
    exchange_mode: []const u8,
    release_status: []const u8,
    generator: []const u8,
    air: []const u8,
    backend: []const u8,
    protocol: []const u8,
    source: SourceWire,
    provenance: ProvenanceWire,
    pcs_config: PcsConfigWire,
    statement: StatementWire,
    interaction_claim: InteractionClaimWire,
    proof_bytes_hex: []const u8,
};

const Header = struct {
    exchange_mode: ?[]const u8 = null,
};

pub fn isRiscVArtifactPath(allocator: std.mem.Allocator, path: []const u8) !bool {
    const raw = try std.fs.cwd().readFileAlloc(allocator, path, MAX_ARTIFACT_BYTES);
    defer allocator.free(raw);
    var parsed = try std.json.parseFromSlice(Header, allocator, raw, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    return if (parsed.value.exchange_mode) |mode|
        std.mem.eql(u8, mode, EXCHANGE_MODE)
    else
        false;
}

pub fn readArtifact(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(Artifact) {
    const raw = try std.fs.cwd().readFileAlloc(allocator, path, MAX_ARTIFACT_BYTES);
    defer allocator.free(raw);
    return std.json.parseFromSlice(Artifact, allocator, raw, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
    });
}

pub fn validatePath(allocator: std.mem.Allocator, path: []const u8) !void {
    var parsed = try readArtifact(allocator, path);
    defer parsed.deinit();
    try validate(parsed.value);
}

pub fn writeArtifact(
    allocator: std.mem.Allocator,
    path: []const u8,
    artifact: Artifact,
) !void {
    try validate(artifact);
    const rendered = try std.json.Stringify.valueAlloc(allocator, artifact, .{});
    defer allocator.free(rendered);
    const output = try std.mem.concat(allocator, u8, &.{ rendered, "\n" });
    defer allocator.free(output);
    try atomic_file.writeExclusive(allocator, path, output);
}

pub fn validate(artifact: Artifact) !void {
    if (artifact.schema_version != SCHEMA_VERSION) return error.UnsupportedSchemaVersion;
    try requireEqual(artifact.exchange_mode, EXCHANGE_MODE, error.UnsupportedExchangeMode);
    try requireEqual(artifact.release_status, RELEASE_STATUS, error.InvalidReleaseStatus);
    try requireEqual(artifact.generator, GENERATOR, error.UnsupportedGenerator);
    try requireEqual(artifact.air, AIR, error.UnsupportedAir);
    try requireEqual(artifact.backend, "cpu", error.UnsupportedBackend);
    if (!isProtocol(artifact.protocol)) return error.UnsupportedProtocol;
    try requireEqual(
        artifact.provenance.oracle_repository,
        ORACLE_REPOSITORY,
        error.UnsupportedOracleRepository,
    );
    try requireEqual(
        artifact.provenance.oracle_commit,
        ORACLE_COMMIT,
        error.UnsupportedOracleCommit,
    );
    try requireEqual(
        artifact.provenance.implementation_repository,
        IMPLEMENTATION_REPOSITORY,
        error.UnsupportedImplementationRepository,
    );
    try validateSha256(artifact.source.elf_sha256);
    try validateSha256(artifact.source.input_sha256);
    try validatePcsConfig(artifact.protocol, artifact.pcs_config);
    try validateStatement(artifact.statement);
    try validateClaims(
        artifact.statement.components.len,
        artifact.statement.infrastructure.len,
        artifact.interaction_claim,
    );
    try validateProofHex(artifact.proof_bytes_hex);
}

fn validatePcsConfig(protocol: []const u8, config: PcsConfigWire) !void {
    const Minimum = struct { pow_bits: u32, n_queries: u64 };
    const minimum: Minimum = if (std.mem.eql(u8, protocol, "secure"))
        .{ .pow_bits = 26, .n_queries = 70 }
    else if (std.mem.eql(u8, protocol, "functional"))
        .{ .pow_bits = 10, .n_queries = 3 }
    else
        .{ .pow_bits = 0, .n_queries = 3 };
    if (config.pow_bits < minimum.pow_bits or
        config.fri_config.n_queries < minimum.n_queries or
        config.fri_config.log_blowup_factor != 1 or
        config.fri_config.log_last_layer_degree_bound != 0 or
        config.fri_config.fold_step != 1 or
        config.lifting_log_size != null)
        return error.InsufficientSecurityPolicy;
}

fn validateStatement(statement: StatementWire) !void {
    if (statement.components.len == 0 or statement.components.len > MAX_COMPONENTS)
        return error.InvalidComponentCount;
    if (statement.infrastructure.len == 0 or
        statement.infrastructure.len > MAX_INFRA_COMPONENTS)
        return error.InvalidInfrastructureCount;
    if (statement.initial_pc != statement.public_data.initial_pc or
        statement.final_pc != statement.public_data.final_pc or
        statement.total_steps != statement.public_data.clock)
        return error.PublicDataMismatch;
    const expected_input_words = std.math.divCeil(usize, statement.public_data.input_len, 4) catch
        unreachable;
    if (statement.public_data.input_words.len != expected_input_words)
        return error.InvalidInputWords;

    var rows: u64 = 0;
    var previous_family: ?u8 = null;
    for (statement.components) |component| {
        if (component.family >= 16 or component.log_size == 0 or component.log_size > 30 or
            component.n_rows == 0 or component.n_columns == 0 or
            component.n_rows > (@as(u32, 1) << @intCast(component.log_size)))
            return error.InvalidComponent;
        if (previous_family) |family| {
            if (component.family < family) return error.InvalidComponentOrder;
        }
        previous_family = component.family;
        rows += component.n_rows;
    }
    if (rows != statement.total_steps) return error.StepCountMismatch;
    for (statement.infrastructure, 0..) |component, index| {
        if (component.kind >= 11 or component.log_size == 0 or component.log_size > 30 or
            component.n_columns == 0 or
            component.n_rows > (@as(u32, 1) << @intCast(component.log_size)))
            return error.InvalidInfrastructureComponent;
        if (index == 0 and (component.kind != 0 or component.n_rows == 0))
            return error.InvalidInfrastructureComponent;
    }
}

fn validateClaims(
    component_count: usize,
    infrastructure_count: usize,
    claims: InteractionClaimWire,
) !void {
    if (claims.state_claims.len != component_count or
        claims.program_claims.len != component_count or
        claims.opcode_memory_claims.len != component_count or
        claims.memory_claims.len != infrastructure_count)
        return error.InvalidInteractionClaimCount;
    for (claims.state_claims) |claim| try validateQm31(claim);
    for (claims.program_claims) |claim| try validateQm31(claim);
    for (claims.opcode_memory_claims) |component_claims| {
        for (component_claims) |claim| try validateQm31(claim);
    }
    try validateQm31(claims.rom_claim);
    for (claims.memory_claims) |component_claims| {
        for (component_claims) |claim| try validateQm31(claim);
    }
}

fn validateQm31(value: Qm31Wire) !void {
    for (value) |coefficient| {
        if (coefficient >= M31_MODULUS) return error.NonCanonicalM31;
    }
}

fn validateSha256(value: []const u8) !void {
    if (value.len != 64) return error.InvalidSha256;
    var decoded: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&decoded, value) catch return error.InvalidSha256;
    const canonical = std.fmt.bytesToHex(decoded, .lower);
    if (!std.mem.eql(u8, value, &canonical)) return error.InvalidSha256;
}

fn validateProofHex(value: []const u8) !void {
    if (value.len == 0 or (value.len & 1) != 0 or value.len > MAX_PROOF_BYTES * 2)
        return error.InvalidProofPayload;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f'))
            return error.InvalidProofPayload;
    }
}

fn isProtocol(value: []const u8) bool {
    return std.mem.eql(u8, value, "secure") or
        std.mem.eql(u8, value, "functional") or
        std.mem.eql(u8, value, "smoke");
}

fn requireEqual(actual: []const u8, expected: []const u8, comptime err: anyerror) !void {
    if (!std.mem.eql(u8, actual, expected)) return err;
}

fn fixture() Artifact {
    return .{
        .schema_version = SCHEMA_VERSION,
        .exchange_mode = EXCHANGE_MODE,
        .release_status = RELEASE_STATUS,
        .generator = GENERATOR,
        .air = AIR,
        .backend = "cpu",
        .protocol = "functional",
        .source = .{ .elf_sha256 = "00" ** 32, .input_sha256 = "11" ** 32 },
        .provenance = .{
            .oracle_repository = ORACLE_REPOSITORY,
            .oracle_commit = ORACLE_COMMIT,
            .implementation_repository = IMPLEMENTATION_REPOSITORY,
        },
        .pcs_config = .{
            .pow_bits = 10,
            .fri_config = .{
                .log_blowup_factor = 1,
                .log_last_layer_degree_bound = 0,
                .n_queries = 3,
            },
        },
        .statement = .{
            .initial_pc = 4,
            .final_pc = 8,
            .total_steps = 1,
            .components = &.{.{
                .family = 0,
                .log_size = 1,
                .n_rows = 1,
                .n_columns = 4,
            }},
            .infrastructure = &.{.{
                .kind = 0,
                .log_size = 1,
                .n_rows = 1,
                .n_columns = 4,
            }},
            .public_data = .{
                .initial_pc = 4,
                .final_pc = 8,
                .clock = 1,
                .initial_regs = .{0} ** 32,
                .final_regs = .{0} ** 32,
                .reg_last_clock = .{0} ** 32,
                .program_root = null,
                .initial_rw_root = null,
                .final_rw_root = null,
                .input_start = 0,
                .input_len = 0,
                .input_words = &.{},
                .output_len = 0,
                .output_len_addr = 0,
                .output_data_addr = 0,
                .output_words = &.{},
            },
        },
        .interaction_claim = .{
            .interaction_pow = 0,
            .state_claims = &.{.{ 0, 0, 0, 0 }},
            .program_claims = &.{.{ 0, 0, 0, 0 }},
            .opcode_memory_claims = &.{.{
                .{ 0, 0, 0, 0 },
                .{ 0, 0, 0, 0 },
                .{ 0, 0, 0, 0 },
            }},
            .rom_claim = .{ 0, 0, 0, 0 },
            .memory_claims = &.{.{
                .{ 0, 0, 0, 0 },
                .{ 0, 0, 0, 0 },
                .{ 0, 0, 0, 0 },
                .{ 0, 0, 0, 0 },
            }},
        },
        .proof_bytes_hex = "00",
    };
}

test "RISC-V artifact pins the oracle and remains explicitly staged" {
    const artifact = fixture();
    try validate(artifact);
    var drifted = artifact;
    drifted.provenance.oracle_commit = "22" ** 20;
    try std.testing.expectError(error.UnsupportedOracleCommit, validate(drifted));
    var promoted = artifact;
    promoted.release_status = "release_gated";
    try std.testing.expectError(error.InvalidReleaseStatus, validate(promoted));
}

test "RISC-V artifact rejects statement and interaction ambiguity" {
    var artifact = fixture();
    artifact.statement.total_steps = 2;
    try std.testing.expectError(error.PublicDataMismatch, validate(artifact));
    artifact = fixture();
    artifact.interaction_claim.program_claims = &.{};
    try std.testing.expectError(error.InvalidInteractionClaimCount, validate(artifact));
    artifact = fixture();
    artifact.pcs_config.pow_bits = 9;
    try std.testing.expectError(error.InsufficientSecurityPolicy, validate(artifact));
}

test "RISC-V artifact publication is exclusive and format detection is exact" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "riscv.json" });
    defer std.testing.allocator.free(path);

    try writeArtifact(std.testing.allocator, path, fixture());
    try std.testing.expect(try isRiscVArtifactPath(std.testing.allocator, path));
    try validatePath(std.testing.allocator, path);
    try std.testing.expectError(
        error.PathAlreadyExists,
        writeArtifact(std.testing.allocator, path, fixture()),
    );
}
