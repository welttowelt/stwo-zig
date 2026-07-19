//! Pinned signed-MULH limitation admission and relation diagnostics.

const std = @import("std");
const riscv_cpu = @import("../../integrations/riscv_cpu/mod.zig");
const public_values = @import("../../frontends/riscv/diagnostics/public_values.zig");
const limitation = @import("../../frontends/riscv/diagnostics/mulh_limitation.zig");
const relation_export = @import("../../frontends/riscv/air/relation_export.zig");
const runner = @import("../../frontends/riscv/runner/mod.zig");
const pcs = @import("../../core/pcs/mod.zig");

const TEST_PCS_CONFIG = pcs.PcsConfig{
    .pow_bits = 0,
    .fri_config = .{
        .log_blowup_factor = 1,
        .log_last_layer_degree_bound = 0,
        .n_queries = 3,
    },
};

test "signed MULH diagnostic exposes exact range-table rejection" {
    const allocator = std.testing.allocator;
    const elf = try std.fs.cwd().readFileAlloc(
        allocator,
        "vectors/riscv_elfs/mul_div.elf",
        64 * 1024 * 1024,
    );
    defer allocator.free(elf);
    var run = try runner.run(allocator, elf, 1_000_000);
    defer run.deinit();

    var report = try limitation.derive(allocator, &run.execution_trace);
    defer report.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 3), report.family_rows);
    try std.testing.expectEqual(@as(u32, 2), report.signed_rows);
    try std.testing.expectEqual(@as(u32, 1), report.unsigned_rows);
    try std.testing.expectEqual(@as(u64, 60), report.raw_nonzero_entries);
    try std.testing.expectEqual(@as(u64, 24), report.range811_requests);
    try std.testing.expectEqual(@as(usize, 8), report.invalid_requests.len);
    try std.testing.expectEqualStrings(limitation.REJECTED_OUTCOME, report.outcome());
    try std.testing.expectEqualStrings(
        "9707404ab0682ac5742f66e39e816898549fa612dbb099c7997b62438885c0ee",
        &std.fmt.bytesToHex(report.raw_stream_sha256, .lower),
    );
    try std.testing.expectEqualStrings(
        "82b01832ed9168bf9df6cdfc2a5fd7e25adce8e26b7460ae612264422974472e",
        &std.fmt.bytesToHex(report.range811_stream_sha256, .lower),
    );
    try std.testing.expectEqualStrings(
        "9044b98b3af28ac81faeb37d2d364d96e56f6bc5a13019e38b2cc8fcce513eef",
        &std.fmt.bytesToHex(report.invalid_requests_sha256, .lower),
    );
    const expected_indices = [_]u32{ 12, 13, 14, 16 };
    const expected_tuples = [_][2]u32{
        .{ 255, 1_073_741_827 },
        .{ 235, 12_582_914 },
        .{ 255, 49_154 },
        .{ 255, 1_610_612_738 },
    };
    for (report.invalid_requests, 0..) |request, index| {
        try std.testing.expectEqual(@as(u32, if (index < 4) 0 else 2), request.row);
        try std.testing.expectEqual(@as(u32, if (index < 4) 38 else 39), request.opcode_id);
        try std.testing.expectEqual(expected_indices[index % expected_indices.len], request.request_index);
        try std.testing.expectEqual(expected_tuples[index % expected_tuples.len], request.tuple);
    }

    var owned_public = try public_values.derive(allocator, &run);
    defer owned_public.deinit(allocator);
    try std.testing.expectError(
        error.ValueOutOfRange,
        riscv_cpu.diagnoseRiscVRelations(
            allocator,
            TEST_PCS_CONFIG,
            &run.execution_trace,
            &run.state_chain_tracker,
            &run.rw_memory,
            owned_public.data,
        ),
    );
}

test "MULHU-only source produces nonzero balanced relation evidence but remains proof-ineligible" {
    const allocator = std.testing.allocator;
    const elf = try std.fs.cwd().readFileAlloc(
        allocator,
        "vectors/riscv_elfs/mulhu_only.elf",
        64 * 1024 * 1024,
    );
    defer allocator.free(elf);
    var run = try runner.run(allocator, elf, 1_000_000);
    defer run.deinit();

    var report = try limitation.derive(allocator, &run.execution_trace);
    defer report.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 1), report.family_rows);
    try std.testing.expectEqual(@as(u32, 0), report.signed_rows);
    try std.testing.expectEqual(@as(u32, 1), report.unsigned_rows);
    try std.testing.expectEqual(@as(u64, 20), report.raw_nonzero_entries);
    try std.testing.expectEqual(@as(u64, 8), report.range811_requests);
    try std.testing.expectEqual(@as(usize, 0), report.invalid_requests.len);
    try std.testing.expectEqualStrings(limitation.ADMISSIBLE_OUTCOME, report.outcome());

    var owned_public = try public_values.derive(allocator, &run);
    defer owned_public.deinit(allocator);
    const diagnostic = try riscv_cpu.diagnoseRiscVRelations(
        allocator,
        TEST_PCS_CONFIG,
        &run.execution_trace,
        &run.state_chain_tracker,
        &run.rw_memory,
        owned_public.data,
    );
    try diagnostic.bundle.validate();
    const mulh = diagnostic.bundle.components[@intFromEnum(relation_export.Component.mulh)];
    try std.testing.expect(!mulh.absent);
    try std.testing.expect(mulh.nonzero.entries > 0);
    try std.testing.expect(!mulh.domain_sums[
        @intFromEnum(
            relation_export.Domain.range_check_8_11,
        )
    ].isZero());
    try std.testing.expect(diagnostic.bundle.aggregate.domain_sums[
        @intFromEnum(
            relation_export.Domain.range_check_8_11,
        )
    ].isZero());
}
