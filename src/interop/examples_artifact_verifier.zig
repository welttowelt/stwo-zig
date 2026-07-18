//! Bounded verification boundary for versioned Native proof artifacts.

const std = @import("std");
const artifacts = @import("examples_artifact.zig");
const proof_wire = @import("proof_wire.zig");
const blake = @import("../examples/blake.zig");
const plonk = @import("../examples/plonk.zig");
const poseidon = @import("../examples/poseidon.zig");
const state_machine = @import("../examples/state_machine.zig");
const wide_fibonacci = @import("../examples/wide_fibonacci.zig");
const xor = @import("../examples/xor.zig");

pub const Generator = enum { rust, zig };
pub const Example = enum { blake, plonk, poseidon, state_machine, wide_fibonacci, xor };

pub const Verification = struct {
    generator: Generator,
    example: Example,
    proof_bytes: usize,
    proof_sha256: [32]u8,
};

pub fn verifyPath(allocator: std.mem.Allocator, path: []const u8) !Verification {
    var parsed = try artifacts.readArtifact(allocator, path);
    defer parsed.deinit();
    const artifact = parsed.value;
    if (artifact.schema_version != artifacts.SCHEMA_VERSION)
        return error.UnsupportedSchemaVersion;
    if (!std.mem.eql(u8, artifact.exchange_mode, artifacts.EXCHANGE_MODE))
        return error.UnsupportedExchangeMode;
    if (!std.mem.eql(u8, artifact.upstream_commit, artifacts.UPSTREAM_COMMIT))
        return error.UnsupportedUpstreamCommit;
    const generator: Generator = std.meta.stringToEnum(Generator, artifact.generator) orelse
        return error.UnsupportedGenerator;
    if (artifact.prove_mode) |mode| {
        if (!std.mem.eql(u8, mode, "prove") and !std.mem.eql(u8, mode, "prove_ex"))
            return error.UnsupportedProveMode;
    }

    const pcs_config = try artifacts.pcsConfigFromWire(artifact.pcs_config);
    const proof_bytes = try artifacts.hexToBytesAlloc(allocator, artifact.proof_bytes_hex);
    defer allocator.free(proof_bytes);
    const proof_sha256 = digest(proof_bytes);
    var proof = try proof_wire.decodeProofBytes(allocator, proof_bytes);
    if (!artifacts.pcsConfigsEqual(pcs_config, proof.commitment_scheme_proof.config)) {
        proof.deinit(allocator);
        return error.ProofConfigMismatch;
    }

    const example = std.meta.stringToEnum(Example, artifact.example) orelse {
        proof.deinit(allocator);
        return error.UnknownExample;
    };
    switch (example) {
        .blake => {
            const wire = artifact.blake_statement orelse {
                proof.deinit(allocator);
                return error.MissingBlakeStatement;
            };
            try blake.verify(allocator, pcs_config, try artifacts.blakeStatementFromWire(wire), proof);
        },
        .plonk => {
            const wire = artifact.plonk_statement orelse {
                proof.deinit(allocator);
                return error.MissingPlonkStatement;
            };
            try plonk.verify(allocator, pcs_config, try artifacts.plonkStatementFromWire(wire), proof);
        },
        .poseidon => {
            const wire = artifact.poseidon_statement orelse {
                proof.deinit(allocator);
                return error.MissingPoseidonStatement;
            };
            try poseidon.verify(allocator, pcs_config, try artifacts.poseidonStatementFromWire(wire), proof);
        },
        .state_machine => {
            const wire = artifact.state_machine_statement orelse {
                proof.deinit(allocator);
                return error.MissingStateMachineStatement;
            };
            try state_machine.verify(
                allocator,
                pcs_config,
                try artifacts.stateMachineStatementFromWire(wire),
                proof,
            );
        },
        .wide_fibonacci => {
            const wire = artifact.wide_fibonacci_statement orelse {
                proof.deinit(allocator);
                return error.MissingWideFibonacciStatement;
            };
            try wide_fibonacci.verify(
                allocator,
                pcs_config,
                try artifacts.wideFibonacciStatementFromWire(wire),
                proof,
            );
        },
        .xor => {
            const wire = artifact.xor_statement orelse {
                proof.deinit(allocator);
                return error.MissingXorStatement;
            };
            try xor.verify(allocator, pcs_config, try artifacts.xorStatementFromWire(wire), proof);
        },
    }
    return .{
        .generator = generator,
        .example = example,
        .proof_bytes = proof_bytes.len,
        .proof_sha256 = proof_sha256,
    };
}

fn digest(bytes: []const u8) [32]u8 {
    var result: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}
