//! Canonical machine-readable result for independent RISC-V verification.

const std = @import("std");

pub const Input = struct {
    artifact_kind: []const u8,
    artifact_schema_version: u32,
    release_status: []const u8,
    security_policy: []const u8,
    statement_sha256: [32]u8,
    proof_bytes: usize,
    proof_sha256: [32]u8,
};

pub fn encode(allocator: std.mem.Allocator, input: Input) ![]u8 {
    const statement_hex = std.fmt.bytesToHex(input.statement_sha256, .lower);
    const proof_hex = std.fmt.bytesToHex(input.proof_sha256, .lower);
    return std.json.Stringify.valueAlloc(allocator, .{
        .schema = "riscv_verify_v1",
        .status = "verified",
        .artifact_kind = input.artifact_kind,
        .artifact_schema_version = input.artifact_schema_version,
        .release_status = input.release_status,
        .security_policy = input.security_policy,
        .statement_sha256 = &statement_hex,
        .proof_bytes = input.proof_bytes,
        .proof_sha256 = &proof_hex,
    }, .{});
}

test "verification receipt is one canonical JSON object" {
    const encoded = try encode(std.testing.allocator, .{
        .artifact_kind = "stwo_riscv_proof",
        .artifact_schema_version = 3,
        .release_status = "not_release_gated",
        .security_policy = "functional",
        .statement_sha256 = [_]u8{0xab} ** 32,
        .proof_bytes = 17,
        .proof_sha256 = [_]u8{0xcd} ** 32,
    });
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqualStrings(
        "{\"schema\":\"riscv_verify_v1\",\"status\":\"verified\"," ++
            "\"artifact_kind\":\"stwo_riscv_proof\",\"artifact_schema_version\":3," ++
            "\"release_status\":\"not_release_gated\",\"security_policy\":\"functional\"," ++
            "\"statement_sha256\":\"" ++ "ab" ** 32 ++ "\",\"proof_bytes\":17," ++
            "\"proof_sha256\":\"" ++ "cd" ** 32 ++ "\"}",
        encoded,
    );

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, encoded, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}
