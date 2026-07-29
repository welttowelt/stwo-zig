//! Lifted Merkle parallel and streaming commitment tests.

const std = @import("std");
const m31 = @import("stwo_core").fields.m31;
const qm31 = @import("stwo_core").fields.qm31;
const secure_column = @import("stwo_prover_engine").secure_column;
const prover_mod = @import("stwo_prover_engine").vcs_lifted.prover;

const M31 = m31.M31;
const QM31 = qm31.QM31;
const MerkleProverLifted = prover_mod.MerkleProverLifted;

test "prover vcs_lifted: root is stable across large-layer worker-count overrides" {
    const Hasher = @import("stwo_core").vcs_lifted.blake2_merkle.Blake2sMerkleHasher;
    const Prover = MerkleProverLifted(Hasher);
    const alloc = std.testing.allocator;
    const log_size: u32 = 14;
    const n = @as(usize, 1) << @intCast(log_size);

    var col0 = try alloc.alloc(M31, n);
    defer alloc.free(col0);
    var col1 = try alloc.alloc(M31, n);
    defer alloc.free(col1);

    for (0..n) |i| {
        col0[i] = M31.fromU64(@as(u64, @intCast(i + 1)));
        col1[i] = M31.fromU64(@as(u64, @intCast((i * 17) + 3)));
    }

    const columns = [_][]const M31{
        col0,
        col1,
    };

    var prover_auto = try Prover.testing.commitWithWorkerOverride(alloc, columns[0..], null);
    defer prover_auto.deinit(alloc);
    var prover_single = try Prover.testing.commitWithWorkerOverride(alloc, columns[0..], 1);
    defer prover_single.deinit(alloc);
    var prover_two = try Prover.testing.commitWithWorkerOverride(alloc, columns[0..], 2);
    defer prover_two.deinit(alloc);
    var prover_four = try Prover.testing.commitWithWorkerOverride(alloc, columns[0..], 4);
    defer prover_four.deinit(alloc);
    var prover_eight = try Prover.testing.commitWithWorkerOverride(alloc, columns[0..], 8);
    defer prover_eight.deinit(alloc);

    const root_auto = prover_auto.root();
    const root_single = prover_single.root();
    const root_two = prover_two.root();
    const root_four = prover_four.root();
    const root_eight = prover_eight.root();
    try std.testing.expect(std.mem.eql(u8, std.mem.asBytes(&root_auto), std.mem.asBytes(&root_single)));
    try std.testing.expect(std.mem.eql(u8, std.mem.asBytes(&root_auto), std.mem.asBytes(&root_two)));
    try std.testing.expect(std.mem.eql(u8, std.mem.asBytes(&root_auto), std.mem.asBytes(&root_four)));
    try std.testing.expect(std.mem.eql(u8, std.mem.asBytes(&root_auto), std.mem.asBytes(&root_eight)));
}

test "prover vcs_lifted: streaming committer produces identical root — single batch" {
    const Hasher = @import("stwo_core").vcs_lifted.blake2_merkle.Blake2sMerkleHasher;
    const Prover = MerkleProverLifted(Hasher);
    const alloc = std.testing.allocator;

    const columns = [_][]const M31{
        &[_]M31{
            M31.fromCanonical(1),
            M31.fromCanonical(2),
            M31.fromCanonical(3),
            M31.fromCanonical(4),
            M31.fromCanonical(5),
            M31.fromCanonical(6),
            M31.fromCanonical(7),
            M31.fromCanonical(8),
        },
        &[_]M31{
            M31.fromCanonical(9),
            M31.fromCanonical(10),
            M31.fromCanonical(11),
            M31.fromCanonical(12),
        },
        &[_]M31{
            M31.fromCanonical(13),
            M31.fromCanonical(14),
            M31.fromCanonical(15),
            M31.fromCanonical(16),
            M31.fromCanonical(17),
            M31.fromCanonical(18),
            M31.fromCanonical(19),
            M31.fromCanonical(20),
        },
    };

    // Reference: full commit.
    var prover_ref = try Prover.commit(alloc, columns[0..]);
    defer prover_ref.deinit(alloc);
    const expected_root = prover_ref.root();

    // Sort columns the same way commit() does internally.
    const sorted = try Prover.sortColumnsByLogSizeAsc(alloc, columns[0..]);
    defer alloc.free(sorted);

    // Streaming: feed all sorted columns in one batch.
    var streaming = Prover.StreamingCommitter.init(alloc);
    errdefer streaming.deinit();
    try streaming.addColumns(sorted);
    var streaming_prover = try streaming.finalize();
    defer streaming_prover.deinit(alloc);

    try std.testing.expectEqualSlices(u8, expected_root[0..], streaming_prover.root()[0..]);
}

test "prover vcs_lifted: constant-column fast path matches streaming committer" {
    const Hasher = @import("stwo_core").vcs_lifted.blake2_merkle.Blake2sMerkleHasher;
    const Prover = MerkleProverLifted(Hasher);
    const alloc = std.testing.allocator;

    const values4 = [_]M31{M31.fromCanonical(7)} ** 4;
    const values8_a = [_]M31{M31.fromCanonical(11)} ** 8;
    const values8_b = [_]M31{M31.fromCanonical(13)} ** 8;
    const columns = [_][]const M31{ values4[0..], values8_a[0..], values8_b[0..] };

    var fast = try Prover.commit(alloc, columns[0..]);
    defer fast.deinit(alloc);

    const sorted = try Prover.sortColumnsByLogSizeAsc(alloc, columns[0..]);
    defer alloc.free(sorted);
    var streaming = Prover.StreamingCommitter.init(alloc);
    errdefer streaming.deinit();
    try streaming.addColumns(sorted);
    var reference = try streaming.finalize();
    defer reference.deinit(alloc);

    try std.testing.expectEqualSlices(u8, reference.root()[0..], fast.root()[0..]);
}

test "prover vcs_lifted: streaming committer produces identical root — column-by-column" {
    const Hasher = @import("stwo_core").vcs_lifted.blake2_merkle.Blake2sMerkleHasher;
    const Prover = MerkleProverLifted(Hasher);
    const alloc = std.testing.allocator;

    const columns = [_][]const M31{
        &[_]M31{
            M31.fromCanonical(1),
            M31.fromCanonical(2),
            M31.fromCanonical(3),
            M31.fromCanonical(4),
            M31.fromCanonical(5),
            M31.fromCanonical(6),
            M31.fromCanonical(7),
            M31.fromCanonical(8),
        },
        &[_]M31{
            M31.fromCanonical(9),
            M31.fromCanonical(10),
            M31.fromCanonical(11),
            M31.fromCanonical(12),
        },
        &[_]M31{
            M31.fromCanonical(13),
            M31.fromCanonical(14),
            M31.fromCanonical(15),
            M31.fromCanonical(16),
            M31.fromCanonical(17),
            M31.fromCanonical(18),
            M31.fromCanonical(19),
            M31.fromCanonical(20),
        },
    };

    var prover_ref = try Prover.commit(alloc, columns[0..]);
    defer prover_ref.deinit(alloc);
    const expected_root = prover_ref.root();

    // Sort, then feed one column at a time.
    const sorted = try Prover.sortColumnsByLogSizeAsc(alloc, columns[0..]);
    defer alloc.free(sorted);

    var streaming = Prover.StreamingCommitter.init(alloc);
    errdefer streaming.deinit();
    for (sorted) |col| {
        const single = [_]Prover.ColumnRef{col};
        try streaming.addColumns(single[0..]);
    }
    var streaming_prover = try streaming.finalize();
    defer streaming_prover.deinit(alloc);

    try std.testing.expectEqualSlices(u8, expected_root[0..], streaming_prover.root()[0..]);
}

test "prover vcs_lifted: streaming committer produces identical root — many columns batched" {
    const Hasher = @import("stwo_core").vcs_lifted.blake2_merkle.Blake2sMerkleHasher;
    const Prover = MerkleProverLifted(Hasher);
    const alloc = std.testing.allocator;

    const large_count: usize = 32;
    const small_count: usize = 8;
    const total = large_count + small_count;
    const large_len: usize = 1 << 6;
    const small_len: usize = 1 << 4;

    const columns_storage = try alloc.alloc([]M31, total);
    defer {
        for (columns_storage) |column| alloc.free(column);
        alloc.free(columns_storage);
    }
    const columns = try alloc.alloc([]const M31, total);
    defer alloc.free(columns);

    for (0..large_count) |i| {
        const values = try alloc.alloc(M31, large_len);
        columns_storage[i] = values;
        columns[i] = values;
        for (values, 0..) |*v, j| {
            v.* = M31.fromU64(@as(u64, @intCast((i + 1) * 1009 + (j + 3) * 37)));
        }
    }
    for (0..small_count) |offset| {
        const i = large_count + offset;
        const values = try alloc.alloc(M31, small_len);
        columns_storage[i] = values;
        columns[i] = values;
        for (values, 0..) |*v, j| {
            v.* = M31.fromU64(@as(u64, @intCast((i + 5) * 1223 + (j + 7) * 19)));
        }
    }

    var prover_ref = try Prover.commit(alloc, columns);
    defer prover_ref.deinit(alloc);
    const expected_root = prover_ref.root();

    const sorted = try Prover.sortColumnsByLogSizeAsc(alloc, columns);
    defer alloc.free(sorted);

    // Feed in batches of 5 (not aligned with group boundaries).
    var streaming = Prover.StreamingCommitter.init(alloc);
    errdefer streaming.deinit();
    var batch_start: usize = 0;
    while (batch_start < sorted.len) {
        // Must split batches at log_size boundaries to maintain ordering invariant.
        var batch_end = batch_start + 1;
        while (batch_end < sorted.len and
            batch_end - batch_start < 5 and
            sorted[batch_end].log_size == sorted[batch_start].log_size)
        {
            batch_end += 1;
        }
        // If next column has a different log_size, that's fine — it'll be in the next batch.
        // But within a batch, all columns must have non-decreasing log_size.
        try streaming.addColumns(sorted[batch_start..batch_end]);
        batch_start = batch_end;
    }
    var streaming_prover = try streaming.finalize();
    defer streaming_prover.deinit(alloc);

    try std.testing.expectEqualSlices(u8, expected_root[0..], streaming_prover.root()[0..]);
}

test "prover vcs_lifted: sparse terminal-block tail matches materialized commitment" {
    const Hasher = @import("stwo_core").vcs_lifted.blake2_merkle.Blake2sMerkleHasher;
    const Prover = MerkleProverLifted(Hasher);
    const alloc = std.testing.allocator;

    var base_storage: [13][16]M31 = undefined;
    var middle_storage: [32]M31 = undefined;
    var final_storage: [64]M31 = undefined;
    var columns: [15][]const M31 = undefined;
    for (&base_storage, 0..) |*values, column_index| {
        for (values, 0..) |*value, row| {
            value.* = M31.fromCanonical(@intCast(1 + column_index * 97 + row * 11));
        }
        columns[column_index] = values;
    }
    for (&middle_storage, 0..) |*value, row| {
        value.* = M31.fromCanonical(@intCast(1701 + row * 13));
    }
    for (&final_storage, 0..) |*value, row| {
        value.* = M31.fromCanonical(@intCast(2903 + row * 17));
    }
    columns[13] = &middle_storage;
    columns[14] = &final_storage;

    var reference = try Prover.commit(alloc, &columns);
    defer reference.deinit(alloc);
    const sorted = try Prover.sortColumnsByLogSizeAsc(alloc, &columns);
    defer alloc.free(sorted);
    var sparse = Prover.StreamingCommitter.init(alloc);
    errdefer sparse.deinit();
    var candidate = try sparse.commitColumnsWithSparseTail(sorted);
    defer candidate.deinit(alloc);

    try std.testing.expectEqualSlices(u8, reference.root()[0..], candidate.root()[0..]);
}

test "prover vcs_lifted: streaming committer empty columns" {
    const Hasher = @import("stwo_core").vcs_lifted.blake2_merkle.Blake2sMerkleHasher;
    const Prover = MerkleProverLifted(Hasher);
    const alloc = std.testing.allocator;

    const no_columns = [_][]const M31{};
    var prover_ref = try Prover.commit(alloc, no_columns[0..]);
    defer prover_ref.deinit(alloc);
    const expected_root = prover_ref.root();

    var streaming = Prover.StreamingCommitter.init(alloc);
    errdefer streaming.deinit();
    // Finalize with no columns added.
    var streaming_prover = try streaming.finalize();
    defer streaming_prover.deinit(alloc);

    try std.testing.expectEqualSlices(u8, expected_root[0..], streaming_prover.root()[0..]);
}

test "prover vcs_lifted: fused secure materialization matches legacy commitment" {
    const Hasher = @import("stwo_core").vcs_lifted.blake2_merkle.Blake2sMerkleHasher;
    const Prover = MerkleProverLifted(Hasher);
    const alloc = std.testing.allocator;

    for ([_]usize{ 4, 1 << 11 }) |value_count| {
        const values = try alloc.alloc(QM31, value_count);
        defer alloc.free(values);
        for (values, 0..) |*value, row| {
            value.* = QM31.fromU32Unchecked(
                @intCast(1 + (row * 17) % 1_000_003),
                @intCast(3 + (row * 29) % 1_000_033),
                @intCast(5 + (row * 43) % 1_000_037),
                @intCast(7 + (row * 61) % 1_000_081),
            );
        }

        var legacy_column = try secure_column.SecureColumnByCoords.fromSecureSlice(alloc, values);
        defer legacy_column.deinit(alloc);
        const legacy_columns = [_][]const M31{
            legacy_column.columns[0],
            legacy_column.columns[1],
            legacy_column.columns[2],
            legacy_column.columns[3],
        };
        var legacy_tree = try Prover.commit(alloc, &legacy_columns);
        defer legacy_tree.deinit(alloc);

        var fused_column = try secure_column.SecureColumnByCoords.uninitialized(alloc, value_count);
        defer fused_column.deinit(alloc);
        var fused_tree = try Prover.commitWithSecureValues(alloc, values, &fused_column);
        defer fused_tree.deinit(alloc);

        inline for (0..qm31.SECURE_EXTENSION_DEGREE) |coordinate| {
            try std.testing.expectEqualSlices(
                M31,
                legacy_column.columns[coordinate],
                fused_column.columns[coordinate],
            );
        }
        try std.testing.expectEqual(legacy_tree.layers.len, fused_tree.layers.len);
        for (legacy_tree.layers, fused_tree.layers) |legacy_layer, fused_layer| {
            try std.testing.expectEqualSlices(Hasher.Hash, legacy_layer, fused_layer);
        }
    }
}
