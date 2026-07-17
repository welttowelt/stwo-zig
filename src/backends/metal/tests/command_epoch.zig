const std = @import("std");
const runtime_mod = @import("../runtime.zig");
const m31 = @import("../../../core/fields/m31.zig");
const blake2_merkle = @import("../../../core/vcs_lifted/blake2_merkle.zig");
const canonic = @import("../../../core/poly/circle/canonic.zig");
const circle_poly = @import("../../../prover/poly/circle/poly.zig");
const twiddles = @import("../../../prover/poly/twiddles.zig");
const merkle_prover = @import("../../../prover/vcs_lifted/prover.zig");

const M31 = m31.M31;
const Hasher = blake2_merkle.Blake2sMerkleHasher;

test "metal: resident commitment epoch owns one submit and wait" {
    const allocator = std.testing.allocator;
    var runtime = try runtime_mod.Runtime.init();
    defer runtime.deinit();

    const base_log: u32 = 10;
    const extended_log: u32 = 11;
    const base_domain = canonic.CanonicCoset.new(base_log).circleDomain();
    const extended_domain = canonic.CanonicCoset.new(extended_log).circleDomain();
    var base_tree = try twiddles.precomputeM31(allocator, base_domain.half_coset);
    defer twiddles.deinitM31(allocator, &base_tree);
    var extended_tree = try twiddles.precomputeM31(allocator, extended_domain.half_coset);
    defer twiddles.deinitM31(allocator, &extended_tree);
    const base_twiddles = twiddles.TwiddleTree([]const M31).init(
        base_tree.root_coset,
        base_tree.twiddles,
        base_tree.itwiddles,
    );
    const extended_twiddles = twiddles.TwiddleTree([]const M31).init(
        extended_tree.root_coset,
        extended_tree.twiddles,
        extended_tree.itwiddles,
    );

    var inputs: [2][]M31 = undefined;
    var expected_coefficients: [2][]M31 = undefined;
    var expected_evaluations: [2][]M31 = undefined;
    defer for (&inputs) |column| allocator.free(column);
    defer for (&expected_coefficients) |column| allocator.free(column);
    defer for (&expected_evaluations) |column| allocator.free(column);
    for (&inputs, &expected_coefficients, &expected_evaluations, 0..) |*input, *coefficient, *evaluation, column_index| {
        input.* = try allocator.alloc(M31, base_domain.size());
        coefficient.* = try allocator.alloc(M31, base_domain.size());
        evaluation.* = try allocator.alloc(M31, extended_domain.size());
        for (input.*, 0..) |*value, row| {
            value.* = M31.fromCanonical(@intCast((column_index * 31337 + row * 7919 + 41) % m31.Modulus));
        }
        @memcpy(coefficient.*, input.*);
    }
    try circle_poly.interpolateBuffersWithTwiddles(&expected_coefficients, base_domain, base_twiddles);
    for (expected_coefficients, expected_evaluations) |coefficient, evaluation| {
        @memcpy(evaluation[0..coefficient.len], coefficient);
        @memset(evaluation[coefficient.len..], M31.zero());
    }
    try circle_poly.evaluateBuffersWithTwiddles(&expected_evaluations, extended_domain, extended_twiddles);

    const base_rows: u32 = @intCast(base_domain.size());
    const extended_rows: u32 = @intCast(extended_domain.size());
    const source_offsets = [_]u64{ 0, base_rows };
    const coefficient_offsets = [_]u64{ 2 * base_rows, 3 * base_rows };
    const evaluation_offsets = [_]u64{ 4 * base_rows, 4 * base_rows + extended_rows };
    const inverse_twiddle_offset: u32 = 4 * base_rows + 2 * extended_rows;
    const forward_twiddle_offset: u32 = inverse_twiddle_offset + @as(u32, @intCast(base_tree.itwiddles.len));
    var layer_cursor = std.mem.alignForward(
        u32,
        forward_twiddle_offset + @as(u32, @intCast(extended_tree.twiddles.len)),
        64,
    );
    var layer_offsets: [extended_log + 1]u32 = undefined;
    var layer_hashes: u32 = extended_rows;
    for (&layer_offsets) |*offset| {
        offset.* = layer_cursor;
        layer_cursor = std.mem.alignForward(u32, layer_cursor + layer_hashes * 8, 64);
        layer_hashes >>= 1;
    }

    var arena = try runtime.allocateResidentBuffer(@as(usize, layer_cursor) * @sizeOf(u32));
    defer arena.deinit();
    const words: [*]u32 = @ptrCast(@alignCast(arena.contents));
    for (inputs, source_offsets) |column, offset_value| {
        const offset: usize = @intCast(offset_value);
        @memcpy(words[offset .. offset + column.len], std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(column)));
    }
    @memcpy(
        words[inverse_twiddle_offset .. inverse_twiddle_offset + base_tree.itwiddles.len],
        std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(base_tree.itwiddles)),
    );
    @memcpy(
        words[forward_twiddle_offset .. forward_twiddle_offset + extended_tree.twiddles.len],
        std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(extended_tree.twiddles)),
    );

    const scale = try M31.fromCanonical(base_rows).inv();
    var ifft = try runtime.prepareCircleIfft(
        &source_offsets,
        &coefficient_offsets,
        base_log,
        inverse_twiddle_offset,
        scale.v,
    );
    defer ifft.deinit();
    var lde = try runtime.prepareCircleLde(
        &coefficient_offsets,
        &evaluation_offsets,
        base_log,
        extended_log,
        forward_twiddle_offset,
    );
    defer lde.deinit();
    const merkle_offsets = [_]u32{
        @intCast(evaluation_offsets[0]),
        @intCast(evaluation_offsets[1]),
    };
    const merkle_logs = [_]u32{ extended_log, extended_log };
    var merkle = try runtime.prepareResidentMerkle(
        &merkle_offsets,
        &merkle_logs,
        extended_log,
        &layer_offsets,
        Hasher.leafSeed(),
        Hasher.nodeSeed(),
    );
    defer merkle.deinit();

    var epoch = try runtime.beginCommandEpoch(arena);
    defer epoch.deinit();
    try epoch.encodeCircleIfft(ifft);
    try epoch.encodeCircleLde(lde);
    try epoch.encodeResidentMerkle(merkle);
    try epoch.submit();
    try std.testing.expectError(runtime_mod.MetalError.CommandEpochFailed, epoch.submit());
    const stats = try epoch.wait();
    try std.testing.expectError(runtime_mod.MetalError.CommandEpochFailed, epoch.wait());
    try std.testing.expectError(runtime_mod.MetalError.CommandEpochFailed, epoch.encodeCircleLde(lde));

    try std.testing.expectEqual(@as(u64, 1), stats.command_buffers);
    try std.testing.expectEqual(@as(u64, 1), stats.wait_count);
    try std.testing.expectEqual(@as(u64, 0), stats.intermediate_wait_count);
    try std.testing.expectEqual(stats.compute_encoders, stats.dispatches);
    try std.testing.expectEqual(@as(u64, 0), stats.blit_encoders);
    try std.testing.expect(stats.gpu_milliseconds > 0);

    for (expected_coefficients, coefficient_offsets) |expected, offset_value| {
        const offset: usize = @intCast(offset_value);
        try std.testing.expectEqualSlices(
            u32,
            std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(expected)),
            words[offset .. offset + expected.len],
        );
    }
    for (expected_evaluations, evaluation_offsets) |expected, offset_value| {
        const offset: usize = @intCast(offset_value);
        try std.testing.expectEqualSlices(
            u32,
            std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(expected)),
            words[offset .. offset + expected.len],
        );
    }

    const cpu_columns = [_][]const M31{
        expected_evaluations[0],
        expected_evaluations[1],
    };
    const CpuTree = merkle_prover.MerkleProverLifted(Hasher);
    var cpu_tree = try CpuTree.commit(allocator, &cpu_columns);
    defer cpu_tree.deinit(allocator);
    const root_words = words[layer_offsets[layer_offsets.len - 1]..][0..8];
    try std.testing.expectEqualSlices(u8, &cpu_tree.root(), std.mem.sliceAsBytes(root_words));
}

test "metal: empty command epoch fails closed before submission" {
    var runtime = try runtime_mod.Runtime.init();
    defer runtime.deinit();
    var arena = try runtime.allocateResidentBuffer(4096);
    defer arena.deinit();
    var epoch = try runtime.beginCommandEpoch(arena);
    defer epoch.deinit();
    try std.testing.expectError(runtime_mod.MetalError.CommandEpochFailed, epoch.submit());
    try std.testing.expectEqual(runtime_mod.CommandEpoch.State.failed, epoch.state);
}
