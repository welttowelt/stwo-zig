const std = @import("std");
const metal = @import("backends/metal/runtime.zig");
const m31 = @import("core/fields/m31.zig");
const blake2_merkle = @import("core/vcs_lifted/blake2_merkle.zig");
const merkle_prover = @import("prover/vcs_lifted/prover.zig");
const riscv_prover = @import("frontends/riscv/prover.zig");
const trace_mod = @import("frontends/riscv/runner/trace.zig");
const pcs_core = @import("core/pcs/mod.zig");
const MetalProverEngine = @import("backends/metal/prover_engine.zig").MetalProverEngine;
const canonic = @import("core/poly/circle/canonic.zig");
const circle_poly = @import("prover/poly/circle/poly.zig");
const twiddles = @import("prover/poly/twiddles.zig");
const core_fri = @import("core/fri.zig");
const qm31 = @import("core/fields/qm31.zig");
const line = @import("core/poly/line.zig");
const MetalBackend = @import("backends/metal/commit_backend.zig").MetalCommitBackend;

const M31 = m31.M31;
const Hasher = blake2_merkle.Blake2sMerkleHasher;
const QM31 = qm31.QM31;

test "metal: Felt252 Montgomery multiplication and inversion match scalar vectors" {
    var runtime = try metal.Runtime.init();
    defer runtime.deinit();
    const inputs = [_]u32{
        3,          0,          0,          0,          0,          0,          0,  0,          5,          0,          0,          0,          0,          0,          0,  0,
        123456789,  0,          0,          0,          0,          0,          0,  0,          987654321,  0,          0,          0,          0,          0,          0,  0,
        0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 16, 0x08000000, 0xfffffffe, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 16, 0x08000000,
    };
    const expected = [_]u32{
        15,         0,          0,          0,          0,          0,          0,          0,
        1431655766, 1431655765, 1431655765, 1431655765, 1431655765, 1431655765, 2863311536, 44739242,
        4227814277, 28389652,   0,          0,          0,          0,          0,          0,
        4182502465, 3289839419, 2437154633, 1097617667, 246538787,  226687632,  2597573368, 27746315,
        6,          0,          0,          0,          0,          0,          0,          0,
        0,          0,          0,          0,          0,          2147483648, 8,          67108864,
    };
    var outputs: [expected.len]u32 = undefined;
    _ = try runtime.felt252Oracle(&inputs, &outputs);
    try std.testing.expectEqualSlices(u32, &expected, &outputs);
}

test "metal: resident EC-op matches canonical Rust witness ABI" {
    const allocator = std.testing.allocator;
    const bytes = try std.fs.cwd().readFileAlloc(allocator, "vectors/cairo/ec_op_parity.bin", 16 * 1024 * 1024);
    defer allocator.free(bytes);
    var cursor: usize = 0;
    const Read = struct {
        fn word(data: []const u8, at: *usize) u32 {
            const value = std.mem.readInt(u32, data[at.*..][0..4], .little);
            at.* += 4;
            return value;
        }
    };
    try std.testing.expectEqualSlices(u8, "STWZECO\x00", bytes[0..8]);
    cursor = 8;
    try std.testing.expectEqual(@as(u32, 1), Read.word(bytes, &cursor));
    const rows = Read.word(bytes, &cursor);
    const segment = Read.word(bytes, &cursor);
    const n_addresses = Read.word(bytes, &cursor);
    const n_big = Read.word(bytes, &cursor);
    const n_small = Read.word(bytes, &cursor);
    try std.testing.expectEqual(@as(u32, 64), rows);
    const address_bytes: []align(4) const u8 = @alignCast(bytes[cursor .. cursor + @as(usize, n_addresses) * 4]);
    const addresses = std.mem.bytesAsSlice(u32, address_bytes);
    cursor += @as(usize, n_addresses) * 4;
    const big_bytes: []align(4) const u8 = @alignCast(bytes[cursor .. cursor + @as(usize, n_big) * 8 * 4]);
    const big_words = std.mem.bytesAsSlice(u32, big_bytes);
    cursor += @as(usize, n_big) * 8 * 4;
    const small_bytes: []align(4) const u8 = @alignCast(bytes[cursor .. cursor + @as(usize, n_small) * 4 * 4]);
    const small_words = std.mem.bytesAsSlice(u32, small_bytes);
    cursor += @as(usize, n_small) * 4 * 4;
    const trace_bytes: []align(4) const u8 = @alignCast(bytes[cursor .. cursor + @as(usize, rows) * 273 * 4]);
    const expected_trace = std.mem.bytesAsSlice(u32, trace_bytes);
    cursor += @as(usize, rows) * 273 * 4;
    const lookup_bytes: []align(4) const u8 = @alignCast(bytes[cursor .. cursor + @as(usize, rows) * 488 * 4]);
    const expected_lookup = std.mem.bytesAsSlice(u32, lookup_bytes);
    cursor += @as(usize, rows) * 488 * 4;
    const partial_rows = @as(usize, rows) * 256;
    const partial_bytes: []align(4) const u8 = @alignCast(bytes[cursor .. cursor + partial_rows * 127 * 4]);
    const expected_partial = std.mem.bytesAsSlice(u32, partial_bytes);
    cursor += partial_rows * 127 * 4;
    try std.testing.expectEqual(bytes.len, cursor);

    var runtime = try metal.Runtime.init();
    defer runtime.deinit();
    var arena = try runtime.allocateResidentBuffer(12 * 1024 * 1024);
    defer arena.deinit();
    const words: [*]u32 = @ptrCast(@alignCast(arena.contents));
    var next: u32 = 0;
    const address_offset = next;
    @memcpy(words[next .. next + addresses.len], addresses);
    next += @intCast(addresses.len);
    var execution_offsets: [37]u32 = undefined;
    execution_offsets[0] = address_offset;
    for (0..28) |limb| {
        execution_offsets[1 + limb] = next;
        for (0..n_big) |index| {
            const source = big_words[index * 8 ..][0..8];
            const bit = limb * 9;
            const source_limb = bit / 32;
            const shift: u5 = @intCast(bit % 32);
            var value = source[source_limb] >> shift;
            if (shift > 23 and source_limb + 1 < 8) value |= source[source_limb + 1] << @intCast(@as(u6, 32) - shift);
            words[next + index] = value & 0x1ff;
        }
        next += n_big;
    }
    for (0..8) |limb| {
        execution_offsets[29 + limb] = next;
        const bit = limb * 9;
        const source_limb = bit / 32;
        const shift: u5 = @intCast(bit % 32);
        for (0..n_small) |index| {
            const source = small_words[index * 4 ..][0..4];
            var value = source[source_limb] >> shift;
            if (shift > 23 and source_limb + 1 < 4) value |= source[source_limb + 1] << @intCast(@as(u6, 32) - shift);
            words[next + index] = value & 0x1ff;
        }
        next += n_small;
    }
    var trace_offsets: [273]u32 = undefined;
    for (&trace_offsets) |*offset| {
        offset.* = next;
        @memset(words[next .. next + rows], 0);
        next += rows;
    }
    const lookup_offset = next;
    @memset(words[next .. next + rows * 488], 0);
    next += rows * 488;
    var partial_offsets: [127]u32 = undefined;
    for (&partial_offsets) |*offset| {
        offset.* = next;
        @memset(words[next .. next + partial_rows], 0);
        next += @intCast(partial_rows);
    }
    var multiplicity_offsets: [4]u32 = undefined;
    const multiplicity_lengths = [_]u32{ n_addresses, n_big, n_small, 256 };
    for (&multiplicity_offsets, multiplicity_lengths) |*offset, length| {
        offset.* = next;
        @memset(words[next .. next + length], 0);
        next += length;
    }
    const segment_offset = next;
    words[next] = segment;
    next += 1;
    const scratch_offset = partial_offsets[126];
    try std.testing.expect(@as(usize, next) * 4 <= arena.byte_length);

    var plan = try runtime.prepareEcOp(
        execution_offsets,
        trace_offsets,
        partial_offsets,
        multiplicity_offsets,
        lookup_offset,
        segment_offset,
        scratch_offset,
        rows,
    );
    defer plan.deinit();
    const gpu_ms = try runtime.ecOpPrepared(arena, plan);
    try std.testing.expect(gpu_ms > 0);
    for (0..rows) |row| for (trace_offsets, 0..) |offset, column| {
        const expected = expected_trace[row * 273 + column];
        const actual = words[offset + row];
        if (expected != actual) {
            std.debug.print("EC-op trace mismatch at row {}, column {}: expected {}, found {}\n", .{ row, column, expected, actual });
            return error.TestExpectedEqual;
        }
    };
    try std.testing.expectEqualSlices(u32, expected_lookup, words[lookup_offset .. lookup_offset + expected_lookup.len]);
    for (partial_offsets, 0..) |offset, column| {
        try std.testing.expectEqualSlices(u32, expected_partial[column * partial_rows ..][0..partial_rows], words[offset .. offset + partial_rows]);
    }
}

test "metal: resident compact writer matches canonical multiset ordering" {
    var runtime = try metal.Runtime.init();
    defer runtime.deinit();
    var arena = try runtime.allocateResidentBuffer(16 * 1024);
    defer arena.deinit();
    const words: [*]u32 = @ptrCast(@alignCast(arena.contents));
    const tuples = [_][3]u32{
        .{ 3, 2, 30 }, .{ 0, 5, 5 },  .{ 2, 2, 22 }, .{ 1, 9, 19 },
        .{ 2, 2, 22 }, .{ 3, 2, 30 }, .{ 0, 5, 5 },  .{ 2, 2, 22 },
        .{ 7, 1, 71 }, .{ 1, 9, 19 }, .{ 2, 2, 22 }, .{ 0, 5, 5 },
        .{ 3, 2, 30 }, .{ 2, 2, 22 }, .{ 0, 5, 5 },  .{ 2, 2, 22 },
    };
    var next: u32 = 0;
    var source_offsets: [2]u32 = undefined;
    for (&source_offsets, 0..) |*offset, source_index| {
        offset.* = next;
        for (0..3) |tuple_word| for (0..8) |row| {
            words[next + tuple_word * 8 + row] = tuples[source_index * 8 + row][tuple_word];
        };
        next += 24;
    }
    const descriptors = [_]u32{
        8, 0, 3, 1, 0,
        8, 0, 3, 1, 8,
    };
    const tuples_offset = next;
    next += 16 * 3;
    const indices_a_offset = next;
    next += 16;
    const indices_b_offset = next;
    next += 16;
    const counts_offset = next;
    next += 16;
    const radix_offsets_offset = next;
    next += 16;
    const bases_offset = next;
    next += 16;
    const heads_offset = next;
    next += 16;
    const positions_offset = next;
    next += 16;
    const block_sums_offset = next;
    next += 1;
    const error_offset = next;
    next += 1;
    const unique_offset = next;
    next += 1;
    var output_offsets: [6]u32 = undefined;
    for (&output_offsets) |*offset| {
        offset.* = next;
        next += 16;
    }
    try std.testing.expect(@as(usize, next) * 4 <= arena.byte_length);
    var plan = try runtime.prepareCompact(&source_offsets, &descriptors, &output_offsets, .{
        .tuple_words = 3,
        .key_words = 2,
        .total_rows = 16,
        .sort_rows = 16,
        .consumer_rows = 16,
        .tuples_offset = tuples_offset,
        .indices_a_offset = indices_a_offset,
        .indices_b_offset = indices_b_offset,
        .counts_offset = counts_offset,
        .radix_offsets_offset = radix_offsets_offset,
        .bases_offset = bases_offset,
        .heads_offset = heads_offset,
        .positions_offset = positions_offset,
        .block_sums_offset = block_sums_offset,
        .error_offset = error_offset,
        .unique_offset = unique_offset,
        .enabler_slot = 3,
        .iota_slot = 4,
        .multiplicity_slot = 5,
    });
    defer plan.deinit();
    const gpu_ms = try runtime.compactPrepared(arena, plan);
    try std.testing.expect(gpu_ms > 0);
    try std.testing.expectEqual(@as(u32, 5), words[unique_offset]);
    const expected = [_][3]u32{ .{ 0, 5, 5 }, .{ 1, 9, 19 }, .{ 2, 2, 22 }, .{ 3, 2, 30 }, .{ 7, 1, 71 } };
    for (0..3) |tuple_word| {
        for (expected, 0..) |tuple, row| try std.testing.expectEqual(tuple[tuple_word], words[output_offsets[tuple_word] + row]);
        for (expected.len..16) |row| try std.testing.expectEqual(expected[0][tuple_word], words[output_offsets[tuple_word] + row]);
    }
    try std.testing.expectEqualSlices(u32, &.{ 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, words[output_offsets[3] .. output_offsets[3] + 16]);
    for (0..16) |row| try std.testing.expectEqual(@as(u32, @intCast(row)), words[output_offsets[4] + row]);
    try std.testing.expectEqualSlices(u32, &.{ 4, 2, 6, 3, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, words[output_offsets[5] .. output_offsets[5] + 16]);

    words[source_offsets[1] + 2 * 8 + 5] = 23;
    _ = try runtime.compactPrepared(arena, plan);
    try std.testing.expectEqual(std.math.maxInt(u32), words[unique_offset]);
}

test "metal: resident witness feed matches scalar histogram" {
    var runtime = try metal.Runtime.init();
    defer runtime.deinit();
    var arena = try runtime.allocateResidentBuffer(16 * 1024);
    defer arena.deinit();
    const words: [*]u32 = @ptrCast(@alignCast(arena.contents));
    const inputs = [_]u32{ 0, 1, 1, 2, 2, 2, 3, 3 };
    @memcpy(words[0..inputs.len], &inputs);
    const count_offset: u32 = 64;
    try runtime.clearArenaRanges(arena, &.{.{ count_offset, 4 }});
    const none = std.math.maxInt(u32);
    const descriptor = [_]u32{
        0, 1, 2, 0, 0, 0, 0, // source word and tuple geometry
        0, 4, none, 0, 0, 0, 0, // relation/table/destination-table index/kind
    };
    var plan = try runtime.prepareWitnessFeed(&descriptor, &.{}, &.{count_offset}, &.{0}, &.{.{ count_offset, 4 }});
    defer plan.deinit();
    const gpu_ms = try runtime.witnessFeedCountsPrepared(arena, inputs.len, plan);
    try std.testing.expect(gpu_ms > 0);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3, 2 }, words[count_offset .. count_offset + 4]);
    _ = try runtime.witnessFeedCountsPrepared(arena, inputs.len, plan);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3, 2 }, words[count_offset .. count_offset + 4]);
}

test "metal: witness feed batch clears shared consumers once" {
    var runtime = try metal.Runtime.init();
    defer runtime.deinit();
    var arena = try runtime.allocateResidentBuffer(16 * 1024);
    defer arena.deinit();
    const words: [*]u32 = @ptrCast(@alignCast(arena.contents));
    @memcpy(words[0..4], &[_]u32{ 0, 1, 1, 2 });
    @memcpy(words[16..20], &[_]u32{ 1, 2, 3, 3 });
    const count_offset: u32 = 64;
    const none = std.math.maxInt(u32);
    const descriptor = [_]u32{
        0, 1, 2,    0, 0, 0, 0,
        0, 4, none, 0, 0, 0, 0,
    };
    const ranges = [_][2]u32{.{ count_offset, 4 }};
    var first = try runtime.prepareWitnessFeed(&descriptor, &.{}, &.{count_offset}, &.{0}, &ranges);
    var second = try runtime.prepareWitnessFeed(&descriptor, &.{}, &.{count_offset}, &.{16}, &ranges);
    const plans = [_]metal.WitnessFeedPlan{ first, second };
    var batch = try runtime.prepareWitnessFeedBatch(&plans, &.{ 4, 4 }, &ranges);
    defer batch.deinit();
    first.deinit();
    second.deinit();

    _ = try runtime.witnessFeedBatchCountsPrepared(arena, batch);
    try std.testing.expectEqualSlices(u32, &.{ 1, 3, 2, 2 }, words[count_offset .. count_offset + 4]);
    _ = try runtime.witnessFeedBatchCountsPrepared(arena, batch);
    try std.testing.expectEqualSlices(u32, &.{ 1, 3, 2, 2 }, words[count_offset .. count_offset + 4]);
}

test "metal: resident FRI folds and coordinate conversion match CPU" {
    const allocator = std.testing.allocator;
    const log_size: u32 = 10;
    const domain = canonic.CanonicCoset.new(log_size).circleDomain();
    var source = try MetalBackend.allocateSecureColumn(domain.size());
    defer source.deinit(allocator);
    for (source.columns, 0..) |column, coordinate| {
        for (column, 0..) |*value, index| {
            value.* = M31.fromCanonical(@intCast((coordinate * 65537 + index * 8191 + 19) % m31.Modulus));
        }
    }
    const alpha = QM31.fromU32Unchecked(7, 11, 13, 17);
    const line_domain = try line.LineDomain.init(@import("core/circle.zig").Coset.halfOdds(log_size - 1));

    const expected = try allocator.alloc(QM31, line_domain.size());
    defer allocator.free(expected);
    @memset(expected, QM31.zero());
    var cpu_circle_workspace = try core_fri.FoldCircleWorkspace.init(allocator, expected.len);
    defer cpu_circle_workspace.deinit(allocator);
    try core_fri.foldCircleColumnsIntoLineWithWorkspace(
        allocator,
        expected,
        source.columns,
        domain,
        alpha,
        &cpu_circle_workspace,
    );

    var resident_line = try MetalBackend.allocateLineEvaluation(line_domain);
    defer resident_line.deinit(allocator);
    var gpu_circle_workspace = try core_fri.FoldCircleWorkspace.init(allocator, expected.len);
    defer gpu_circle_workspace.deinit(allocator);
    try MetalBackend.foldCircleIntoLine(
        allocator,
        @constCast(resident_line.values),
        source.columns,
        domain,
        alpha,
        &gpu_circle_workspace,
    );
    try std.testing.expectEqualSlices(QM31, expected, resident_line.values);

    var coordinates = try MetalBackend.secureColumnFromLine(resident_line);
    defer coordinates.deinit(allocator);
    for (expected, 0..) |value, index| try std.testing.expect(value.eql(coordinates.at(index)));

    var cpu_line_workspace = try core_fri.FoldLineWorkspace.init(allocator, expected.len / 2);
    defer cpu_line_workspace.deinit(allocator);
    const expected_fold = try core_fri.foldLineNWithWorkspace(
        allocator,
        expected,
        line_domain,
        alpha,
        &cpu_line_workspace,
        2,
    );
    defer allocator.free(expected_fold.values);

    var gpu_line_workspace = try core_fri.FoldLineWorkspace.init(allocator, expected.len / 2);
    defer gpu_line_workspace.deinit(allocator);
    var resident_fold = try MetalBackend.foldLineEvaluationN(
        allocator,
        resident_line,
        alpha,
        &gpu_line_workspace,
        2,
    );
    defer resident_fold.deinit(allocator);
    try std.testing.expectEqualSlices(QM31, expected_fold.values, resident_fold.values);
}

test "metal: batched circle IFFT and RFFT match CPU" {
    const allocator = std.testing.allocator;
    var runtime = try metal.Runtime.init();
    defer runtime.deinit();

    for ([_]u32{ 3, 8, 12 }) |log_size| {
        const domain = canonic.CanonicCoset.new(log_size).circleDomain();
        var tree = try twiddles.precomputeM31(allocator, domain.half_coset);
        defer twiddles.deinitM31(allocator, &tree);

        var cpu: [3][]M31 = undefined;
        var gpu: [3][]M31 = undefined;
        defer for (&cpu) |column| allocator.free(column);
        defer for (&gpu) |column| allocator.free(column);
        for (0..cpu.len) |column_index| {
            cpu[column_index] = try allocator.alloc(M31, domain.size());
            gpu[column_index] = try allocator.alloc(M31, domain.size());
            for (cpu[column_index], 0..) |*value, row| {
                value.* = M31.fromCanonical(@intCast((column_index * 3571 + row * 7919 + 23) % m31.Modulus));
            }
            @memcpy(gpu[column_index], cpu[column_index]);
        }

        const const_tree = twiddles.TwiddleTree([]const M31).init(tree.root_coset, tree.twiddles, tree.itwiddles);
        try circle_poly.interpolateBuffersWithTwiddles(&cpu, domain, const_tree);
        _ = try runtime.transformCircle(allocator, &gpu, tree.itwiddles, log_size, true);
        for (cpu, gpu) |cpu_column, gpu_column| {
            try std.testing.expectEqualSlices(M31, cpu_column, gpu_column);
        }

        try circle_poly.evaluateBuffersWithTwiddles(&cpu, domain, const_tree);
        _ = try runtime.transformCircle(allocator, &gpu, tree.twiddles, log_size, false);
        for (cpu, gpu) |cpu_column, gpu_column| {
            try std.testing.expectEqualSlices(M31, cpu_column, gpu_column);
        }
    }
}

test "metal: fused circle LDE matches CPU" {
    const allocator = std.testing.allocator;
    var runtime = try metal.Runtime.init();
    defer runtime.deinit();

    const base_log_size: u32 = 12;
    const extended_log_size: u32 = 13;
    const base_domain = canonic.CanonicCoset.new(base_log_size).circleDomain();
    const extended_domain = canonic.CanonicCoset.new(extended_log_size).circleDomain();
    var base_tree = try twiddles.precomputeM31(allocator, base_domain.half_coset);
    defer twiddles.deinitM31(allocator, &base_tree);
    var extended_tree = try twiddles.precomputeM31(allocator, extended_domain.half_coset);
    defer twiddles.deinitM31(allocator, &extended_tree);

    var cpu_base: [3][]M31 = undefined;
    var cpu_extended: [3][]M31 = undefined;
    var gpu_base: [3][]M31 = undefined;
    var gpu_extended: [3][]M31 = undefined;
    defer for (&cpu_base) |column| allocator.free(column);
    defer for (&cpu_extended) |column| allocator.free(column);
    defer for (&gpu_base) |column| allocator.free(column);
    defer for (&gpu_extended) |column| allocator.free(column);
    for (0..cpu_base.len) |column_index| {
        cpu_base[column_index] = try allocator.alloc(M31, base_domain.size());
        cpu_extended[column_index] = try allocator.alloc(M31, extended_domain.size());
        gpu_base[column_index] = try allocator.alloc(M31, base_domain.size());
        gpu_extended[column_index] = try allocator.alloc(M31, extended_domain.size());
        for (cpu_base[column_index], 0..) |*value, row| {
            value.* = M31.fromCanonical(@intCast((column_index * 65537 + row * 8191 + 31) % m31.Modulus));
        }
        @memcpy(gpu_base[column_index], cpu_base[column_index]);
    }

    const base_const_tree = twiddles.TwiddleTree([]const M31).init(base_tree.root_coset, base_tree.twiddles, base_tree.itwiddles);
    const extended_const_tree = twiddles.TwiddleTree([]const M31).init(extended_tree.root_coset, extended_tree.twiddles, extended_tree.itwiddles);
    try circle_poly.interpolateBuffersWithTwiddles(&cpu_base, base_domain, base_const_tree);
    for (cpu_base, cpu_extended) |base, extended| {
        @memcpy(extended[0..base.len], base);
        @memset(extended[base.len..], M31.zero());
    }
    try circle_poly.evaluateBuffersWithTwiddles(&cpu_extended, extended_domain, extended_const_tree);

    _ = try runtime.transformCircleLde(
        allocator,
        &gpu_base,
        &gpu_base,
        &gpu_extended,
        base_tree.itwiddles,
        extended_tree.twiddles,
        base_log_size,
        extended_log_size,
    );
    for (cpu_base, gpu_base) |cpu_column, gpu_column| try std.testing.expectEqualSlices(M31, cpu_column, gpu_column);
    for (cpu_extended, gpu_extended) |cpu_column, gpu_column| try std.testing.expectEqualSlices(M31, cpu_column, gpu_column);
}

test "metal: prepared sparse coefficient LDE matches CPU" {
    const allocator = std.testing.allocator;
    var runtime = try metal.Runtime.init();
    defer runtime.deinit();
    const base_log_size: u32 = 10;
    const extended_log_size: u32 = 11;
    const base_domain = canonic.CanonicCoset.new(base_log_size).circleDomain();
    const extended_domain = canonic.CanonicCoset.new(extended_log_size).circleDomain();
    var base_tree = try twiddles.precomputeM31(allocator, base_domain.half_coset);
    defer twiddles.deinitM31(allocator, &base_tree);
    var extended_tree = try twiddles.precomputeM31(allocator, extended_domain.half_coset);
    defer twiddles.deinitM31(allocator, &extended_tree);
    const extended_const_tree = twiddles.TwiddleTree([]const M31).init(extended_tree.root_coset, extended_tree.twiddles, extended_tree.itwiddles);

    var coefficients: [2][]M31 = undefined;
    var expected: [2][]M31 = undefined;
    defer for (&coefficients) |column| allocator.free(column);
    defer for (&expected) |column| allocator.free(column);
    const base_const_tree = twiddles.TwiddleTree([]const M31).init(base_tree.root_coset, base_tree.twiddles, base_tree.itwiddles);
    for (0..2) |column_index| {
        coefficients[column_index] = try allocator.alloc(M31, base_domain.size());
        expected[column_index] = try allocator.alloc(M31, extended_domain.size());
        for (coefficients[column_index], 0..) |*value, row| {
            value.* = M31.fromCanonical(@intCast((column_index * 31337 + row * 7919 + 17) % m31.Modulus));
        }
    }
    try circle_poly.interpolateBuffersWithTwiddles(&coefficients, base_domain, base_const_tree);
    for (coefficients, expected) |source, destination| {
        @memcpy(destination[0..source.len], source);
        @memset(destination[source.len..], M31.zero());
    }
    try circle_poly.evaluateBuffersWithTwiddles(&expected, extended_domain, extended_const_tree);

    var arena = try runtime.allocateResidentBuffer(128 * 1024);
    defer arena.deinit();
    const words: [*]u32 = @ptrCast(@alignCast(arena.contents));
    const source_offsets = [_]u32{ 0, 4096 };
    const destination_offsets = [_]u32{ 8192, 16384 };
    const twiddle_offset: u32 = 24576;
    for (coefficients, source_offsets) |column, offset| {
        @memcpy(words[offset .. offset + column.len], std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(column)));
    }
    @memcpy(words[twiddle_offset .. twiddle_offset + extended_tree.twiddles.len], std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(extended_tree.twiddles)));
    var plan = try runtime.prepareCircleLde(&source_offsets, &destination_offsets, base_log_size, extended_log_size, twiddle_offset);
    defer plan.deinit();
    _ = try runtime.circleLdePrepared(arena, plan);
    for (expected, destination_offsets) |column, offset| {
        const actual_bytes = std.mem.sliceAsBytes(words[offset .. offset + column.len]);
        const actual: []align(@alignOf(M31)) const u8 = @alignCast(actual_bytes);
        try std.testing.expectEqualSlices(M31, column, std.mem.bytesAsSlice(M31, actual));
    }
}

test "metal: prepared sparse evaluation IFFT matches CPU" {
    const allocator = std.testing.allocator;
    var runtime = try metal.Runtime.init();
    defer runtime.deinit();
    const log_size: u32 = 10;
    const domain = canonic.CanonicCoset.new(log_size).circleDomain();
    var tree = try twiddles.precomputeM31(allocator, domain.half_coset);
    defer twiddles.deinitM31(allocator, &tree);
    const const_tree = twiddles.TwiddleTree([]const M31).init(tree.root_coset, tree.twiddles, tree.itwiddles);

    var evaluations: [2][]M31 = undefined;
    var expected: [2][]M31 = undefined;
    defer for (&evaluations) |column| allocator.free(column);
    defer for (&expected) |column| allocator.free(column);
    for (0..evaluations.len) |column_index| {
        evaluations[column_index] = try allocator.alloc(M31, domain.size());
        expected[column_index] = try allocator.alloc(M31, domain.size());
        for (evaluations[column_index], 0..) |*value, row| {
            value.* = M31.fromCanonical(@intCast((column_index * 2137 + row * 65537 + 29) % m31.Modulus));
        }
        @memcpy(expected[column_index], evaluations[column_index]);
    }
    try circle_poly.interpolateBuffersWithTwiddles(&expected, domain, const_tree);

    var arena = try runtime.allocateResidentBuffer(64 * 1024);
    defer arena.deinit();
    const words: [*]u32 = @ptrCast(@alignCast(arena.contents));
    const source_offsets = [_]u32{ 0, 2048 };
    const destination_offsets = [_]u32{ 4096, 8192 };
    const twiddle_offset: u32 = 12288;
    for (evaluations, source_offsets) |column, offset| {
        @memcpy(words[offset .. offset + column.len], std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(column)));
    }
    @memcpy(words[twiddle_offset .. twiddle_offset + tree.itwiddles.len], std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(tree.itwiddles)));
    const scale = try M31.fromCanonical(@intCast(domain.size())).inv();
    var plan = try runtime.prepareCircleIfft(&source_offsets, &destination_offsets, log_size, twiddle_offset, scale.v);
    defer plan.deinit();
    _ = try runtime.circleIfftPrepared(arena, plan);
    for (expected, destination_offsets) |column, offset| {
        const actual_bytes = std.mem.sliceAsBytes(words[offset .. offset + column.len]);
        const actual: []align(@alignOf(M31)) const u8 = @alignCast(actual_bytes);
        try std.testing.expectEqualSlices(M31, column, std.mem.bytesAsSlice(M31, actual));
    }
}

test "metal: prepared fixed-table lookup batch matches scalar materialization" {
    var runtime = try metal.Runtime.init();
    defer runtime.deinit();
    var arena = try runtime.allocateResidentBuffer(32 * 1024);
    defer arena.deinit();
    const words: [*]u32 = @ptrCast(@alignCast(arena.contents));
    const rows: u32 = 64;
    const source_offsets = [_]u32{128};
    const multiplicity_offsets = [_]u32{ 256, 320, 384, 448 };
    const destination_offset: u32 = 1024;
    for (words[128 .. 128 + rows], 0..) |*value, row| value.* = @intCast(row * 7 + 3);
    for (multiplicity_offsets, 0..) |offset, column| {
        for (words[offset .. offset + rows], 0..) |*value, row| value.* = @intCast(column * 1000 + row);
    }
    const descriptors = [_]u32{
        0, 123, 0, 0,
        1, 0,   0, 0,
        2, 2,   0, 0,
        3, 3,   3, 1,
        4, 3,   3, 1,
        5, 3,   3, 1,
    };
    var fixed = try runtime.prepareFixedTable(&descriptors, &source_offsets, &multiplicity_offsets, destination_offset, rows);
    defer fixed.deinit();
    var batch = try runtime.prepareFixedTableBatch(&.{fixed});
    defer batch.deinit();
    _ = try runtime.fixedTableBatchPrepared(arena, batch);
    for (0..descriptors.len / 4) |output| for (0..rows) |row| {
        const descriptor = descriptors[output * 4 ..][0..4];
        const expected: u32 = switch (descriptor[0]) {
            0 => descriptor[1],
            1 => words[source_offsets[descriptor[1]] + row],
            2 => words[multiplicity_offsets[descriptor[1]] + row],
            3, 4, 5 => blk: {
                const column = descriptor[1];
                const a = ((column >> 1) << 3) | (@as(u32, @intCast(row)) >> 3);
                const b = ((column & 1) << 3) | (@as(u32, @intCast(row)) & 7);
                break :blk if (descriptor[0] == 3) a else if (descriptor[0] == 4) b else a ^ b;
            },
            else => unreachable,
        };
        try std.testing.expectEqual(expected, words[destination_offset + output * rows + row]);
    };
}

test "metal: prepared sparse Merkle parent chain matches CPU" {
    var runtime = try metal.Runtime.init();
    defer runtime.deinit();
    var arena = try runtime.allocateResidentBuffer(32 * 1024);
    defer arena.deinit();
    const words: [*]u32 = @ptrCast(@alignCast(arena.contents));
    const child_offset: u32 = 0;
    const middle_offset: u32 = 256;
    const root_offset: u32 = 512;
    var children: [16]Hasher.Hash = undefined;
    for (&children, 0..) |*hash, child| {
        for (hash, 0..) |*byte, index| byte.* = @intCast((child * 37 + index * 13 + 11) & 0xff);
    }
    @memcpy(std.mem.sliceAsBytes(words[child_offset .. child_offset + 16 * 8]), std.mem.sliceAsBytes(&children));
    var middle: [8]Hasher.Hash = undefined;
    for (&middle, 0..) |*hash, index| hash.* = Hasher.hashChildrenWithSeed(Hasher.nodeSeed(), .{ .left = children[index * 2], .right = children[index * 2 + 1] });
    var roots: [4]Hasher.Hash = undefined;
    for (&roots, 0..) |*hash, index| hash.* = Hasher.hashChildrenWithSeed(Hasher.nodeSeed(), .{ .left = middle[index * 2], .right = middle[index * 2 + 1] });
    var plan = try runtime.prepareMerkleParentChain(&.{ child_offset, middle_offset }, &.{ middle_offset, root_offset }, &.{ 8, 4 }, Hasher.nodeSeed());
    defer plan.deinit();
    _ = try runtime.merkleParentChainPrepared(arena, plan);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&middle), std.mem.sliceAsBytes(words[middle_offset .. middle_offset + 8 * 8]));
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&roots), std.mem.sliceAsBytes(words[root_offset .. root_offset + 4 * 8]));
}

test "metal: prepared relation graph matches scalar logup" {
    var runtime = try metal.Runtime.init();
    defer runtime.deinit();
    var arena = try runtime.allocateResidentBuffer(64 * 1024);
    defer arena.deinit();
    const words: [*]u32 = @ptrCast(@alignCast(arena.contents));
    const rows: u32 = 256;
    const source_offset: u32 = 0;
    const output_offsets = [_]u32{ 1024, 2048, 3072, 4096 };
    const alpha_offset: u32 = 5120;
    const z_offset: u32 = 5140;
    const scratch_offset: u32 = 5160;
    const claimed_offset: u32 = 5180;
    for (words[source_offset + rows .. source_offset + 2 * rows], 0..) |*value, row| value.* = @intCast(row + 1);
    const alphas = [_]QM31{
        QM31.fromU32Unchecked(3, 0, 0, 0),
        QM31.fromU32Unchecked(5, 0, 0, 0),
    };
    const z = QM31.fromU32Unchecked(7, 0, 0, 0);
    for (alphas, 0..) |alpha, index| {
        const coordinates = alpha.toM31Array();
        for (coordinates, 0..) |coordinate, coordinate_index| words[alpha_offset + index * 4 + coordinate_index] = coordinate.v;
    }
    for (z.toM31Array(), 0..) |coordinate, index| words[z_offset + index] = coordinate.v;
    const descriptor = [_]u32{
        1,
        0,
        0,
        2,
        11,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
    };
    const geometry = [_]u32{
        0, 1, rows, 1, rows, 0, 0, 0, 0, claimed_offset,
    };
    var plan = try runtime.prepareRelation(
        &geometry,
        &.{source_offset},
        &descriptor,
        &output_offsets,
        1,
        alpha_offset,
        z_offset,
        scratch_offset,
    );
    defer plan.deinit();
    _ = try runtime.relationPrepared(arena, plan);
    var fractions: [rows]QM31 = undefined;
    var total = QM31.zero();
    for (&fractions, 0..) |*fraction, row| {
        const denominator = alphas[0].mulM31(M31.fromCanonical(11))
            .add(alphas[1].mulM31(M31.fromCanonical(@intCast(row + 1))))
            .sub(z);
        fraction.* = try denominator.inv();
        total = total.add(fraction.*);
    }
    const shift = total.mulM31(try M31.fromCanonical(rows).inv());
    var accumulated = QM31.zero();
    var expected: [rows]QM31 = undefined;
    for (0..rows) |scan_index| {
        const circle_index = if ((scan_index & 1) == 0) scan_index / 2 else rows - 1 - scan_index / 2;
        const row = @bitReverse(@as(u32, @intCast(circle_index))) >> (32 - @ctz(rows));
        accumulated = accumulated.add(fractions[row].sub(shift));
        expected[row] = accumulated;
    }
    for (expected, 0..) |value, row| {
        const coordinates = value.toM31Array();
        for (coordinates, output_offsets) |coordinate, offset| try std.testing.expectEqual(coordinate.v, words[offset + row]);
    }
    for (total.toM31Array(), 0..) |coordinate, index| try std.testing.expectEqual(coordinate.v, words[claimed_offset + index]);
}

test "metal: resident lifted Merkle root matches CPU" {
    const allocator = std.testing.allocator;
    var runtime = try metal.Runtime.init();
    defer runtime.deinit();

    const log_sizes = [_]u32{ 10, 9, 10, 8, 9, 10, 7, 10, 8, 10, 9, 10, 6, 10, 9, 10, 8 };
    var owned: [log_sizes.len][]M31 = undefined;
    var initialized: usize = 0;
    defer {
        for (owned[0..initialized]) |column| allocator.free(column);
    }
    var cpu_columns: [log_sizes.len][]const M31 = undefined;
    var gpu_columns: [log_sizes.len][]const u32 = undefined;
    for (log_sizes, 0..) |log_size, column_index| {
        const column = try allocator.alloc(M31, @as(usize, 1) << @intCast(log_size));
        owned[column_index] = column;
        initialized += 1;
        for (column, 0..) |*value, row| {
            value.* = M31.fromCanonical(@intCast((column_index * 7919 + row * 104729 + 17) % m31.Modulus));
        }
        cpu_columns[column_index] = column;
        gpu_columns[column_index] = std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(column));
    }

    const CpuTree = merkle_prover.MerkleProverLifted(Hasher);
    var cpu_tree = try CpuTree.commit(allocator, &cpu_columns);
    defer cpu_tree.deinit(allocator);

    var gpu_tree = try runtime.commitColumns(
        allocator,
        &gpu_columns,
        &log_sizes,
        10,
        Hasher.leafSeed(),
        Hasher.nodeSeed(),
    );
    defer gpu_tree.deinit();
    const result = try gpu_tree.root();

    try std.testing.expectEqualSlices(u8, &cpu_tree.root(), &result.hash);
    try std.testing.expect(result.gpu_ms > 0);

    var compatible_tree = try CpuTree.commitMetal(&runtime, allocator, &cpu_columns);
    defer compatible_tree.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &cpu_tree.root(), &compatible_tree.root());
}

test "metal: prepared sparse Merkle leaves match committed tree" {
    const allocator = std.testing.allocator;
    var runtime = try metal.Runtime.init();
    defer runtime.deinit();
    const log_sizes = [_]u32{ 10, 9, 10, 8, 9, 10, 7, 10, 8, 10, 9, 10, 6, 10, 9, 10, 8 };
    var owned: [log_sizes.len][]M31 = undefined;
    var initialized: usize = 0;
    defer for (owned[0..initialized]) |column| allocator.free(column);
    var gpu_columns: [log_sizes.len][]const u32 = undefined;
    var total_words: u32 = 0;
    for (log_sizes, 0..) |log_size, column_index| {
        const column = try allocator.alloc(M31, @as(usize, 1) << @intCast(log_size));
        owned[column_index] = column;
        initialized += 1;
        for (column, 0..) |*value, row| value.* = M31.fromCanonical(@intCast((column_index * 7919 + row * 104729 + 17) % m31.Modulus));
        gpu_columns[column_index] = std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(column));
        total_words += @intCast(column.len);
    }
    var reference = try runtime.commitColumns(allocator, &gpu_columns, &log_sizes, 10, Hasher.leafSeed(), Hasher.nodeSeed());
    defer reference.deinit();
    const reference_layers = try reference.copyLayers(&runtime, allocator, 10);
    defer allocator.free(reference_layers);

    const destination_offset = std.mem.alignForward(u32, total_words, 64);
    const scratch_offset = destination_offset + 1024 * 8;
    var arena = try runtime.allocateResidentBuffer(@as(usize, scratch_offset + 512 * 8) * 4);
    defer arena.deinit();
    const words: [*]u32 = @ptrCast(@alignCast(arena.contents));
    var column_offsets: [log_sizes.len]u32 = undefined;
    var next: u32 = 0;
    for (owned, &column_offsets) |column, *offset| {
        offset.* = next;
        @memcpy(words[next .. next + column.len], std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(column)));
        next += @intCast(column.len);
    }
    var order: [log_sizes.len]usize = undefined;
    for (&order, 0..) |*index, value| index.* = value;
    std.sort.heap(usize, &order, log_sizes, struct {
        fn lessThan(sizes: [log_sizes.len]u32, lhs: usize, rhs: usize) bool {
            return sizes[lhs] < sizes[rhs] or (sizes[lhs] == sizes[rhs] and lhs < rhs);
        }
    }.lessThan);
    var sorted_offsets: [log_sizes.len]u32 = undefined;
    var sorted_logs: [log_sizes.len]u32 = undefined;
    for (order, 0..) |source, destination| {
        sorted_offsets[destination] = column_offsets[source];
        sorted_logs[destination] = log_sizes[source];
    }
    var plan = try runtime.prepareMerkleLeaves(&sorted_offsets, &sorted_logs, 10, destination_offset, Hasher.leafSeed());
    defer plan.deinit();
    const gpu_ms = try runtime.merkleLeavesPrepared(arena, plan);
    try std.testing.expect(gpu_ms > 0);
    try std.testing.expectEqualSlices(
        u8,
        std.mem.sliceAsBytes(reference_layers[reference_layers.len - 1024 ..]),
        std.mem.sliceAsBytes(words[destination_offset .. destination_offset + 1024 * 8]),
    );
    var layer_offsets: [11]u32 = undefined;
    for (&layer_offsets, 0..) |*offset, level| offset.* = if (level % 2 == 0) destination_offset else scratch_offset;
    var resident = try runtime.prepareResidentMerkle(
        &sorted_offsets,
        &sorted_logs,
        10,
        &layer_offsets,
        Hasher.leafSeed(),
        Hasher.nodeSeed(),
    );
    defer resident.deinit();
    _ = try runtime.residentMerklePrepared(arena, resident);
    try std.testing.expectEqualSlices(u8, &reference_layers[0], std.mem.sliceAsBytes(words[layer_offsets[10] .. layer_offsets[10] + 8]));
}

test "metal: transaction engine proves and CPU verifier accepts" {
    const allocator = std.testing.allocator;
    var trace = trace_mod.Trace.init(allocator);
    defer trace.deinit();
    trace.initial_pc = 0x1000;
    for (0..8) |row| {
        try trace.append(.{
            .clk = @intCast(row),
            .pc = @intCast(0x1000 + row * 4),
            .opcode = .ADDI,
            .rd = 1,
            .rs1 = 0,
            .rs2 = 0,
            .imm = 1,
            .rs1_val = 0,
            .rs2_val = 0,
            .rd_val = @intCast(row + 1),
            .mem_addr = 0,
            .mem_val = 0,
            .is_load = false,
            .is_store = false,
            .branch_taken = false,
            .next_pc = @intCast(0x1000 + (row + 1) * 4),
        });
    }
    trace.final_pc = 0x1020;
    const config = pcs_core.PcsConfig{
        .pow_bits = 0,
        .fri_config = .{
            .log_blowup_factor = 1,
            .log_last_layer_degree_bound = 0,
            .n_queries = 3,
        },
    };
    const output = try riscv_prover.proveRiscVWithEngine(
        MetalProverEngine,
        allocator,
        config,
        &trace,
        null,
        null,
    );
    try riscv_prover.verifyRiscV(allocator, config, output.statement, output.proof);
}
