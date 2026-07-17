//! Transaction-level tests for reusable wide Fibonacci prover sessions.

const std = @import("std");
const fri = @import("../../core/fri.zig");
const pcs = @import("../../core/pcs/mod.zig");
const proof_wire = @import("../../interop/proof_wire.zig");
const subject = @import("../wide_fibonacci.zig");

fn testConfig() !pcs.PcsConfig {
    return .{
        .pow_bits = 0,
        .fri_config = try fri.FriConfig.init(0, 1, 3),
    };
}

test "wide Fibonacci session: sequential proofs match compatibility path exactly" {
    const allocator = std.testing.allocator;
    const config = try testConfig();
    const statement = subject.Statement{ .log_n_rows = 5, .sequence_len = 8 };
    const required_log = try subject.requiredTwiddleCircleLog(statement, config);

    var session = try subject.CpuProverEngine.initSession(
        allocator,
        config,
        required_log,
        1 << 20,
    );
    defer session.deinit(allocator);

    var compatibility = try subject.prove(allocator, config, statement);
    defer compatibility.proof.deinit(allocator);

    const first_input = try subject.prepareInput(allocator, statement);
    var first = try subject.provePreparedWithSessionAndEngine(
        subject.CpuProverEngine,
        &session,
        allocator,
        config,
        first_input,
        null,
    );
    defer first.proof.deinit(allocator);

    const second_input = try subject.prepareInput(allocator, statement);
    var second = try subject.provePreparedWithSessionAndEngine(
        subject.CpuProverEngine,
        &session,
        allocator,
        config,
        second_input,
        null,
    );
    defer second.proof.deinit(allocator);

    const expected = try proof_wire.encodeProofBytes(allocator, compatibility.proof);
    defer allocator.free(expected);
    const first_bytes = try proof_wire.encodeProofBytes(allocator, first.proof);
    defer allocator.free(first_bytes);
    const second_bytes = try proof_wire.encodeProofBytes(allocator, second.proof);
    defer allocator.free(second_bytes);

    try std.testing.expectEqualSlices(u8, expected, first_bytes);
    try std.testing.expectEqualSlices(u8, expected, second_bytes);
    try std.testing.expectEqual(@as(u64, 1), session.constructionTelemetry().tower_build_count);
}

test "wide Fibonacci session: request geometry is rejected before proving" {
    const allocator = std.testing.allocator;
    const config = try testConfig();
    const statement = subject.Statement{ .log_n_rows = 5, .sequence_len = 8 };
    const required_log = try subject.requiredTwiddleCircleLog(statement, config);

    var session = try subject.CpuProverEngine.initSession(
        allocator,
        config,
        required_log - 1,
        1 << 20,
    );
    defer session.deinit(allocator);

    const prepared = try subject.prepareInput(allocator, statement);
    try std.testing.expectError(
        error.InvalidCircleLog,
        subject.provePreparedWithSessionAndEngine(
            subject.CpuProverEngine,
            &session,
            allocator,
            config,
            prepared,
            null,
        ),
    );
}
