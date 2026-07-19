//! FRI fold-to-next-tree transaction parity and submission accounting.

const std = @import("std");
const runtime_mod = @import("../runtime.zig");
const MetalBackend = @import("../commit_backend.zig").MetalCommitBackend;
const commit_policy = @import("../commit_policy.zig");
const core_fri = @import("stwo_core").fri;
const core_utils = @import("stwo_core").utils;
const fields = @import("stwo_core").fields;
const m31 = @import("stwo_core").fields.m31;
const qm31 = @import("stwo_core").fields.qm31;
const circle = @import("stwo_core").circle;
const line = @import("stwo_core").poly.line;
const secure_column = @import("stwo_prover_impl").secure_column;
const merkle_prover = @import("stwo_prover_impl").vcs_lifted.prover;
const blake2_merkle = @import("stwo_core").vcs_lifted.blake2_merkle;

const M31 = m31.M31;
const QM31 = qm31.QM31;
const Hasher = blake2_merkle.Blake2sMerkleHasher;

test "metal: FRI fold and next tree use one submission with CPU parity" {
    const allocator = std.testing.allocator;
    var runtime = try runtime_mod.Runtime.init();
    defer runtime.deinit();

    // Exercise the low-level transaction at a bounded size; the backend policy
    // applies a higher threshold based on complete-proof measurements.
    const source_log: u32 = 17;
    const source_count: usize = @as(usize, 1) << source_log;
    const destination_count = source_count >> 1;
    const domain = try line.LineDomain.init(circle.Coset.halfOdds(source_log));
    const alpha = QM31.fromU32Unchecked(7, 11, 13, 17);
    const alpha_coordinates = alpha.toM31Array();
    const alpha_words = [_][4]u32{.{
        alpha_coordinates[0].v,
        alpha_coordinates[1].v,
        alpha_coordinates[2].v,
        alpha_coordinates[3].v,
    }};

    const source_values = try allocator.alloc(QM31, source_count);
    defer allocator.free(source_values);
    for (source_values, 0..) |*value, index| {
        value.* = QM31.fromU32Unchecked(
            @intCast((index * 17 + 3) % m31.Modulus),
            @intCast((index * 29 + 5) % m31.Modulus),
            @intCast((index * 43 + 7) % m31.Modulus),
            @intCast((index * 61 + 11) % m31.Modulus),
        );
    }

    const inverse_x = try allocator.alloc(M31, destination_count);
    defer allocator.free(inverse_x);
    const x = try allocator.alloc(M31, destination_count);
    defer allocator.free(x);
    for (x, 0..) |*value, index| {
        value.* = domain.at(core_utils.bitReverseIndex(index << 1, source_log));
    }
    try fields.batchInverseInPlace(M31, x, inverse_x);
    const inverse_words = std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(inverse_x));

    var workspace = try core_fri.FoldLineWorkspace.init(allocator, destination_count);
    defer workspace.deinit(allocator);
    const cpu_fold = try core_fri.foldLineNWithWorkspace(
        allocator,
        source_values,
        domain,
        alpha,
        &workspace,
        1,
    );
    defer allocator.free(cpu_fold.values);

    var cpu_coordinates = try secure_column.SecureColumnByCoords.fromSecureSlice(
        allocator,
        cpu_fold.values,
    );
    defer cpu_coordinates.deinit(allocator);
    const cpu_columns = [_][]const M31{
        cpu_coordinates.columns[0],
        cpu_coordinates.columns[1],
        cpu_coordinates.columns[2],
        cpu_coordinates.columns[3],
    };
    const CpuTree = merkle_prover.MerkleProverLifted(Hasher);
    var cpu_tree = try CpuTree.commit(allocator, &cpu_columns);
    defer cpu_tree.deinit(allocator);

    var source = try runtime.allocateResidentBuffer(source_count * @sizeOf(QM31));
    defer source.deinit();
    const source_resident: [*]QM31 = @ptrCast(@alignCast(source.contents));
    @memcpy(source_resident[0..source_count], source_values);

    var sequential_destination = try runtime.allocateResidentBuffer(destination_count * @sizeOf(QM31));
    defer sequential_destination.deinit();
    const sequential_values: [*]QM31 = @ptrCast(@alignCast(sequential_destination.contents));
    var sequential_coordinates = try runtime.allocateResidentBuffer(destination_count * 4 * @sizeOf(M31));
    defer sequential_coordinates.deinit();
    const sequential_coordinate_words: [*]u32 = @ptrCast(@alignCast(sequential_coordinates.contents));

    var sequential_timer = try std.time.Timer.start();
    _ = try runtime.foldFriLine(
        @ptrCast(source_resident),
        @intCast(source_count),
        inverse_words,
        alpha_words[0],
        @ptrCast(sequential_values),
    );
    _ = try runtime.qm31ToCoordinates(
        @ptrCast(sequential_values),
        @intCast(destination_count),
        sequential_coordinate_words,
    );
    var sequential_word_columns: [4][]const u32 = undefined;
    for (&sequential_word_columns, 0..) |*column, coordinate| {
        column.* = sequential_coordinate_words[coordinate * destination_count .. (coordinate + 1) * destination_count];
    }
    const logs = [_]u32{ source_log - 1, source_log - 1, source_log - 1, source_log - 1 };
    var sequential_tree = try runtime.commitColumns(
        allocator,
        &sequential_word_columns,
        &logs,
        source_log - 1,
        Hasher.leafSeed(),
        Hasher.nodeSeed(),
        Hasher.domainPrefixBytes(),
    );
    defer sequential_tree.deinit();
    const sequential_wall_ns = sequential_timer.read();

    var fused_destination = try runtime.allocateResidentBuffer(destination_count * @sizeOf(QM31));
    defer fused_destination.deinit();
    const fused_values: [*]QM31 = @ptrCast(@alignCast(fused_destination.contents));
    var fused_coordinates = try runtime.allocateResidentBuffer(destination_count * 4 * @sizeOf(M31));
    defer fused_coordinates.deinit();
    var fused_timer = try std.time.Timer.start();
    var fused = try runtime.foldFriLineAndCommit(
        source.handle,
        @intCast(source_count),
        inverse_words,
        &alpha_words,
        fused_destination.handle,
        fused_coordinates.handle,
        Hasher.leafSeed(),
        Hasher.nodeSeed(),
        Hasher.domainPrefixBytes(),
    );
    defer fused.tree.deinit();
    const fused_wall_ns = fused_timer.read();

    try std.testing.expectEqualSlices(QM31, cpu_fold.values, sequential_values[0..destination_count]);
    try std.testing.expectEqualSlices(QM31, cpu_fold.values, fused_values[0..destination_count]);
    const fused_coordinate_words: [*]u32 = @ptrCast(@alignCast(fused_coordinates.contents));
    try std.testing.expectEqualSlices(
        u32,
        sequential_coordinate_words[0 .. destination_count * 4],
        fused_coordinate_words[0 .. destination_count * 4],
    );
    const sequential_root = try sequential_tree.root();
    const fused_root = try fused.tree.root();
    try std.testing.expectEqualSlices(u8, &cpu_tree.root(), &sequential_root.hash);
    try std.testing.expectEqualSlices(u8, &cpu_tree.root(), &fused_root.hash);
    try std.testing.expectEqual(@as(u64, 1), fused.stats.command_buffers);
    try std.testing.expectEqual(@as(u64, 1), fused.stats.wait_count);
    try std.testing.expectEqual(@as(u64, 0), fused.stats.intermediate_wait_count);
    try std.testing.expectEqual(fused.stats.compute_encoders, fused.stats.dispatches);
    try std.testing.expectEqual(@as(u64, source_log + 2), fused.stats.dispatches);

    std.debug.print(
        "\nmetal FRI log {d}: sequential 3 submissions/3 waits {d:.3}ms wall; " ++
            "fused {}/{} {d:.3}ms wall ({d:.3}ms GPU, {} dispatches)\n",
        .{
            source_log,
            @as(f64, @floatFromInt(sequential_wall_ns)) / std.time.ns_per_ms,
            fused.stats.command_buffers,
            fused.stats.wait_count,
            @as(f64, @floatFromInt(fused_wall_ns)) / std.time.ns_per_ms,
            fused.stats.gpu_milliseconds,
            fused.stats.dispatches,
        },
    );
}

test "metal: FRI backend hook retains folded coordinates and records fused epoch" {
    const allocator = std.testing.allocator;
    try MetalBackend.warmup();

    const source_log = commit_policy.fri_fold_commit_log_threshold + 1;
    const source_count: usize = @as(usize, 1) << source_log;
    const destination_count = source_count >> 1;
    const domain = try line.LineDomain.init(circle.Coset.halfOdds(source_log));
    const alpha = QM31.fromU32Unchecked(19, 23, 29, 31);

    var source = try MetalBackend.allocateLineEvaluation(domain);
    defer source.deinit(allocator);
    const source_values = @constCast(source.values);
    for (source_values, 0..) |*value, index| {
        value.* = QM31.fromU32Unchecked(
            @intCast((index * 71 + 13) % m31.Modulus),
            @intCast((index * 73 + 17) % m31.Modulus),
            @intCast((index * 79 + 19) % m31.Modulus),
            @intCast((index * 83 + 23) % m31.Modulus),
        );
    }

    var cpu_workspace = try core_fri.FoldLineWorkspace.init(allocator, destination_count);
    defer cpu_workspace.deinit(allocator);
    const cpu_fold = try core_fri.foldLineNWithWorkspace(
        allocator,
        source.values,
        domain,
        alpha,
        &cpu_workspace,
        1,
    );
    defer allocator.free(cpu_fold.values);
    var cpu_coordinates = try secure_column.SecureColumnByCoords.fromSecureSlice(
        allocator,
        cpu_fold.values,
    );
    defer cpu_coordinates.deinit(allocator);
    const cpu_columns = [_][]const M31{
        cpu_coordinates.columns[0],
        cpu_coordinates.columns[1],
        cpu_coordinates.columns[2],
        cpu_coordinates.columns[3],
    };
    const CpuTree = merkle_prover.MerkleProverLifted(Hasher);
    var cpu_tree = try CpuTree.commit(allocator, &cpu_columns);
    defer cpu_tree.deinit(allocator);

    var metal_workspace = try core_fri.FoldLineWorkspace.init(allocator, destination_count);
    defer metal_workspace.deinit(allocator);
    const before = try MetalBackend.telemetrySnapshot();
    var result = try MetalBackend.foldLineAndCommitNext(
        Hasher,
        allocator,
        source,
        alpha,
        &metal_workspace,
        1,
    );
    defer result.evaluation.deinit(allocator);
    defer if (result.column) |*column| column.deinit(allocator);
    defer result.tree.deinit(allocator);
    const after = try MetalBackend.telemetrySnapshot();
    const delta = after.delta(before);

    try std.testing.expectEqual(@as(u64, 1), delta.counters.metal_fri_fold_commit_epochs);
    try std.testing.expectEqual(@as(u64, 1), delta.counters.resident_merkle_commits);
    try std.testing.expectEqualSlices(QM31, cpu_fold.values, result.evaluation.values);
    const coordinates = result.column orelse return error.MissingResidentCoordinates;
    for (cpu_coordinates.columns, coordinates.columns) |expected, actual| {
        try std.testing.expectEqualSlices(M31, expected, actual);
    }
    try std.testing.expectEqualSlices(u8, &cpu_tree.root(), &result.tree.root());
}
