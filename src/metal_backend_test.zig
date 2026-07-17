const std = @import("std");
const metal = @import("backends/metal/runtime.zig");
const m31 = @import("core/fields/m31.zig");
const blake2_merkle = @import("core/vcs_lifted/blake2_merkle.zig");
const blake2_hash = @import("core/vcs/blake2_hash.zig");
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
const prover_line = @import("prover/line.zig");
const MetalBackend = @import("backends/metal/commit_backend.zig").MetalCommitBackend;
const eval_program = @import("frontends/cairo/witness/eval_program.zig");
const eval_codegen = @import("backends/metal/eval_codegen.zig");
const circle_core = @import("core/circle.zig");
const core_utils = @import("core/utils.zig");
const blake2s_channel = @import("core/channel/blake2s.zig");
const protocol_recipes = @import("backends/metal/protocol_recipes.zig");
const arena_plan = @import("backends/metal/arena_plan.zig");
const secure_column = @import("prover/secure_column.zig");
const secure_circle_poly = @import("prover/poly/circle/secure_poly.zig");
const cairo_arena_binding = @import("integrations/cairo_metal/arena_binding.zig");
const cairo_proof_plan = @import("frontends/cairo/proof_plan.zig");
const cairo_witness_bundle = @import("frontends/cairo/witness/bundle.zig");
const cairo_oods = @import("frontends/cairo/witness/oods.zig");
const cairo_quotient_inputs = @import("frontends/cairo/witness/quotient_inputs.zig");

const M31 = m31.M31;
const Hasher = blake2_merkle.Blake2sMerkleHasher;
const QM31 = qm31.QM31;

fn testResidentBinding(logical_id: u32, offset_words: u32, word_count: u32) arena_plan.Binding {
    return .{
        .logical_id = logical_id,
        .slot = logical_id,
        .offset_bytes = @as(u64, offset_words) * @sizeOf(u32),
        .size_bytes = @as(u64, word_count) * @sizeOf(u32),
        .materialization = .resident,
        .occupied = [_]u64{0} ** (arena_plan.max_ticks / 64),
    };
}

test {
    std.testing.refAllDecls(cairo_arena_binding);
    std.testing.refAllDecls(cairo_oods);
    std.testing.refAllDecls(cairo_quotient_inputs);
}

test "metal: prepared state restore preserves immutable ranges and clears mutable bytes" {
    var runtime = try metal.Runtime.init();
    defer runtime.deinit();
    var arena = try runtime.allocateResidentBuffer(256);
    defer arena.deinit();
    var snapshot = try runtime.allocateResidentBuffer(32);
    defer snapshot.deinit();
    const arena_bytes: [*]u8 = @ptrCast(arena.contents);
    @memset(arena_bytes[0..arena.byte_length], 0x31);
    for (arena_bytes[32..48], 0..) |*byte, index| byte.* = @intCast(index + 1);
    for (arena_bytes[160..176], 0..) |*byte, index| byte.* = @intCast(index + 33);
    const ranges = [_]metal.PreparedStateRange{
        .{ .arena_byte_offset = 32, .snapshot_byte_offset = 0, .byte_count = 16 },
        .{ .arena_byte_offset = 160, .snapshot_byte_offset = 16, .byte_count = 16 },
    };
    _ = try runtime.preparedStateTransfer(arena, snapshot, &ranges, true, false);
    @memset(arena_bytes[0..arena.byte_length], 0xa7);
    _ = try runtime.preparedStateTransfer(arena, snapshot, &ranges, false, true);

    for (arena_bytes[0..32]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    for (arena_bytes[32..48], 0..) |byte, index| try std.testing.expectEqual(@as(u8, @intCast(index + 1)), byte);
    for (arena_bytes[48..160]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    for (arena_bytes[160..176], 0..) |byte, index| try std.testing.expectEqual(@as(u8, @intCast(index + 33)), byte);
    for (arena_bytes[176..256]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "metal: arena range clear zeros exact disjoint spans" {
    var runtime = try metal.Runtime.init();
    defer runtime.deinit();
    var arena = try runtime.allocateResidentBuffer(256);
    defer arena.deinit();
    const words: [*]u32 = @ptrCast(@alignCast(arena.contents));
    for (words[0..64], 0..) |*word, index| word.* = @intCast(index + 1);

    try runtime.clearArenaRanges(arena, &.{ .{ 4, 3 }, .{ 16, 5 }, .{ 40, 1 } });

    for (words[0..64], 0..) |word, index| {
        const cleared = (index >= 4 and index < 7) or
            (index >= 16 and index < 21) or index == 40;
        try std.testing.expectEqual(if (cleared) @as(u32, 0) else @as(u32, @intCast(index + 1)), word);
    }
}

test "metal: component-local relation APIs fail closed on incomplete layouts" {
    var bindings: cairo_arena_binding.PreparedProofBindings = undefined;
    bindings.relation_claimed_sums = &.{};
    try std.testing.expectError(
        cairo_arena_binding.Error.InvalidClaimedSumCount,
        bindings.prepareRelationComponents(
            std.testing.allocator,
            undefined,
            undefined,
            &.{},
            undefined,
            undefined,
            undefined,
            undefined,
        ),
    );

    var proof: cairo_proof_plan.CairoProofPlan = undefined;
    proof.components = &.{};
    var witness_bundle: cairo_witness_bundle.Bundle = undefined;
    witness_bundle.entries = &.{};
    var relation_operations: [0]cairo_arena_binding.RelationComponentOperation = .{};
    var relations = cairo_arena_binding.PreparedRelationComponents{
        .allocator = std.testing.allocator,
        .operations = &relation_operations,
    };
    try std.testing.expectError(
        cairo_arena_binding.Error.MissingBinding,
        cairo_arena_binding.executeScheduledInteractionGraph(
            std.testing.allocator,
            undefined,
            undefined,
            &.{},
            undefined,
            &proof,
            witness_bundle,
            undefined,
            undefined,
            undefined,
            undefined,
            undefined,
            undefined,
            &relations,
        ),
    );

    var native: cairo_arena_binding.NativeBaseInterpolationBatch = undefined;
    native.fixed = &.{};
    try std.testing.expectError(cairo_arena_binding.Error.MissingBinding, native.materializeFixed("range_check_6"));
}

test "metal: prepared arena gather seals one proof buffer" {
    var runtime = try metal.Runtime.init();
    defer runtime.deinit();
    var arena = try runtime.allocateResidentBuffer(16 * 1024);
    defer arena.deinit();
    const words: [*]u32 = @ptrCast(@alignCast(arena.contents));
    @memcpy(words[16..20], &[_]u32{ 11, 13, 17, 19 });
    @memcpy(words[32..35], &[_]u32{ 23, 29, 31 });
    const ranges = [_]metal.ArenaCopyRange{
        .{ .source_word_offset = 16, .destination_word_offset = 64, .word_count = 4 },
        .{ .source_word_offset = 32, .destination_word_offset = 68, .word_count = 3 },
    };
    var plan = try runtime.prepareArenaCopies(&ranges);
    defer plan.deinit();
    try std.testing.expect(try runtime.arenaCopyPrepared(arena, plan) > 0);
    try std.testing.expectEqualSlices(u32, &.{ 11, 13, 17, 19, 23, 29, 31 }, words[64..71]);
}

test "metal: proof assembly recipe executes prepared resident copies" {
    const allocator = std.testing.allocator;
    var runtime = try metal.Runtime.init();
    defer runtime.deinit();
    var resident = arena_plan.ResidentArena{ .buffer = try runtime.allocateResidentBuffer(16 * 1024) };
    defer resident.deinit();
    const words: [*]u32 = @ptrCast(@alignCast(resident.buffer.contents));
    const first = testResidentBinding(1, 16, 4);
    const second = testResidentBinding(2, 32, 3);
    const destination = testResidentBinding(3, 64, 7);
    @memcpy(words[16..20], &[_]u32{ 11, 13, 17, 19 });
    @memcpy(words[32..35], &[_]u32{ 23, 29, 31 });
    var recipe = try protocol_recipes.ProofAssemblyRecipe.init(
        allocator,
        &runtime,
        &resident,
        &.{
            .{ .source = first, .destination_word_offset = 0, .word_count = 4 },
            .{ .source = second, .destination_word_offset = 4, .word_count = 3 },
        },
        destination,
    );
    defer recipe.deinit();

    try recipe.execute();

    try std.testing.expect(recipe.accumulated_gpu_ms > 0);
    try std.testing.expectEqualSlices(u32, &.{ 11, 13, 17, 19, 23, 29, 31 }, try recipe.words());
}

test "metal: witness edge gather preserves producer and packed padding order" {
    var runtime = try metal.Runtime.init();
    defer runtime.deinit();
    var arena = try runtime.allocateResidentBuffer(16 * 1024);
    defer arena.deinit();
    const words: [*]u32 = @ptrCast(@alignCast(arena.contents));
    const outputs = [_]u32{ 512, 576, 640 };
    const producer_rows: u32 = 16;
    for (0..4) |source_word| {
        for (0..producer_rows) |row|
            words[source_word * producer_rows + row] = @intCast(source_word * 100 + row);
    }
    _ = try runtime.witnessInputGather(
        arena,
        &.{0},
        &.{.{ producer_rows, 0, 2, 2, 0 }},
        2,
        32,
        64,
        &outputs,
        true,
        false,
    );
    for (0..64) |row| {
        const source_row = if (row < 32) row else row & 15;
        const instance = source_row / 16;
        const inner = source_row % 16;
        try std.testing.expectEqual(@as(u32, @intCast(instance * 200 + inner)), words[outputs[0] + row]);
        try std.testing.expectEqual(@as(u32, @intCast(instance * 200 + 100 + inner)), words[outputs[1] + row]);
        try std.testing.expectEqual(@as(u32, @intFromBool(row < 32)), words[outputs[2] + row]);
    }
}

test "metal: fused V1 evaluation program matches scalar field arithmetic" {
    const allocator = std.testing.allocator;
    var base = [_]eval_program.BaseInst{
        .{ .op = .trace_col, .interaction = 0, .dst = 0, .a = 0, .b = 0, .imm = 0 },
        .{ .op = .constant, .interaction = 0, .dst = 1, .a = 7, .b = 0, .imm = 0 },
        .{ .op = .mul, .interaction = 0, .dst = 2, .a = 0, .b = 1, .imm = 0 },
    };
    var ext = [_]eval_program.ExtInst{
        .{ .op = .secure_col, .dst = 0, .a = 2, .b = 1, .c = 0, .d = 1 },
        .{ .op = .param, .dst = 1, .a = 0, .b = 0, .c = 0, .d = 0 },
        .{ .op = .mul, .dst = 2, .a = 0, .b = 1, .c = 0, .d = 0 },
    };
    var roots = [_]u32{2};
    const program = eval_program.Program{
        .allocator = allocator,
        .header = .{ .flags = eval_program.Flag.prefinalized_logup, .semantic_hash = 0x1234, .capability_bits = eval_program.Capability.prefinalized_logup | eval_program.Capability.ext_mul, .n_interactions = 1, .n_base_params = 0, .n_ext_params = 1, .n_constraints = 1, .max_base_regs = 3, .max_ext_regs = 3, .domain_log_size = 7 },
        .base_consts = &.{},
        .ext_consts = &.{},
        .base_insts = &base,
        .ext_insts = &ext,
        .constraint_roots = &roots,
    };
    const source = try eval_codegen.generate(allocator, program);
    defer allocator.free(source);
    const name = try eval_codegen.kernelName(allocator, program.header.semantic_hash);
    defer allocator.free(name);

    const rows: u32 = 256;
    var runtime = try metal.Runtime.init();
    defer runtime.deinit();
    var arena = try runtime.allocateResidentBuffer(16 * 1024);
    defer arena.deinit();
    const words: [*]u32 = @ptrCast(@alignCast(arena.contents));
    var next: u32 = 0;
    const trace = next;
    for (0..rows) |row| words[next + row] = @intCast(row + 1);
    next += rows;
    const trace_offsets = next;
    words[next] = trace;
    next += 1;
    const interaction_offsets = next;
    words[next] = 0;
    next += 1;
    const ext_params = next;
    const ext_value = QM31.fromU32Unchecked(3, 5, 11, 13);
    for (ext_value.toM31Array(), 0..) |value, index| words[next + index] = value.v;
    next += 4;
    const random_coeffs = next;
    const random = QM31.fromU32Unchecked(17, 19, 23, 29);
    for (random.toM31Array(), 0..) |value, index| words[next + index] = value.v;
    next += 4;
    const denom = next;
    words[next] = 31;
    next += 1;
    var coordinates: [4]u32 = undefined;
    for (&coordinates) |*offset| {
        offset.* = next;
        @memset(words[next .. next + rows], 0);
        next += rows;
    }
    var plan = try runtime.prepareEval(source, name, .{
        .trace_offsets = trace_offsets,
        .interaction_offsets = interaction_offsets,
        .base_params = 0,
        .ext_params = ext_params,
        .random_coeffs = random_coeffs,
        .denom_inv = denom,
        .coordinates = coordinates,
        .row_count = rows,
        .trace_log_size = 8,
        .domain_log_size = 7,
        .rc_base = 0,
    });
    defer plan.deinit();
    const gpu_ms = try runtime.evalPrepared(arena, plan);
    try std.testing.expect(gpu_ms > 0);
    for (coordinates) |offset| @memset(words[offset .. offset + rows], 0);
    var batch = try runtime.prepareEvalBatch(&.{plan});
    defer batch.deinit();
    const batch_ms = try runtime.evalBatchPrepared(arena, batch);
    try std.testing.expect(batch_ms > 0);
    for (0..rows) |row| {
        const value = M31.fromCanonical(@intCast(row + 1));
        const seven = M31.fromCanonical(7);
        const root = QM31.fromM31(value.mul(seven), seven, value, seven);
        const expected = root.mul(ext_value).mul(random).mulM31(M31.fromCanonical(31)).toM31Array();
        for (expected, coordinates) |coordinate, offset| try std.testing.expectEqual(coordinate.v, words[offset + row]);
    }
}

test "metal: fused multi-part AIR preserves legacy accumulator order" {
    const allocator = std.testing.allocator;
    var first_base = [_]eval_program.BaseInst{
        .{ .op = .trace_col, .interaction = 0, .dst = 0, .a = 0, .b = 0, .imm = 0 },
        .{ .op = .constant, .interaction = 0, .dst = 1, .a = 7, .b = 0, .imm = 0 },
        .{ .op = .mul, .interaction = 0, .dst = 2, .a = 0, .b = 1, .imm = 0 },
    };
    var second_base = [_]eval_program.BaseInst{
        .{ .op = .trace_col, .interaction = 0, .dst = 0, .a = 0, .b = 0, .imm = 0 },
        .{ .op = .constant, .interaction = 0, .dst = 1, .a = 11, .b = 0, .imm = 0 },
        .{ .op = .add, .interaction = 0, .dst = 2, .a = 0, .b = 1, .imm = 0 },
    };
    var ext = [_]eval_program.ExtInst{
        .{ .op = .secure_col, .dst = 0, .a = 2, .b = 1, .c = 0, .d = 1 },
    };
    var roots = [_]u32{0};
    const first = eval_program.Program{
        .allocator = allocator,
        .header = .{ .flags = eval_program.Flag.prefinalized_logup, .semantic_hash = 0x11112222, .capability_bits = eval_program.Capability.prefinalized_logup, .n_interactions = 1, .n_base_params = 0, .n_ext_params = 0, .n_constraints = 1, .max_base_regs = 3, .max_ext_regs = 1, .domain_log_size = 7 },
        .base_consts = &.{},
        .ext_consts = &.{},
        .base_insts = &first_base,
        .ext_insts = &ext,
        .constraint_roots = &roots,
    };
    var second = first;
    second.header.semantic_hash = 0x33334444;
    second.base_insts = &second_base;
    const fused_parts = [_]eval_codegen.FusedPart{
        .{ .program = first, .rc_base = 0 },
        .{ .program = second, .rc_base = 1 },
    };
    const first_source = try eval_codegen.generate(allocator, first);
    defer allocator.free(first_source);
    const second_source = try eval_codegen.generate(allocator, second);
    defer allocator.free(second_source);
    const fused_source = try eval_codegen.generateFusedKernel(allocator, &fused_parts, true);
    defer allocator.free(fused_source);
    const first_name = try eval_codegen.kernelName(allocator, first.header.semantic_hash);
    defer allocator.free(first_name);
    const second_name = try eval_codegen.kernelName(allocator, second.header.semantic_hash);
    defer allocator.free(second_name);
    const fused_name = try eval_codegen.fusedKernelName(allocator, &fused_parts);
    defer allocator.free(fused_name);

    const rows: u32 = 256;
    var runtime = try metal.Runtime.init();
    defer runtime.deinit();
    var arena = try runtime.allocateResidentBuffer(32 * 1024);
    defer arena.deinit();
    const words: [*]u32 = @ptrCast(@alignCast(arena.contents));
    var next: u32 = 0;
    const trace = next;
    for (0..rows) |row| words[next + row] = @intCast(row + 1);
    next += rows;
    const trace_offsets = next;
    words[next] = trace;
    next += 1;
    const interaction_offsets = next;
    words[next] = 0;
    next += 1;
    const random_coeffs = next;
    words[next..][0..8].* = .{ 2, 3, 5, 7, 11, 13, 17, 19 };
    next += 8;
    const denom = next;
    words[next..][0..2].* = .{ 23, 29 };
    next += 2;
    var legacy_coordinates: [4]u32 = undefined;
    var fused_coordinates: [4]u32 = undefined;
    for (&legacy_coordinates, &fused_coordinates, 0..) |*legacy, *fused, coordinate| {
        legacy.* = next;
        next += rows;
        fused.* = next;
        next += rows;
        for (0..rows) |row| {
            const initial: u32 = @intCast(coordinate * 1000 + row + 29);
            words[legacy.* + row] = initial;
            words[fused.* + row] = initial;
        }
    }
    const layout = struct {
        fn make(
            trace_offsets_: u32,
            interaction_offsets_: u32,
            random_coeffs_: u32,
            denom_: u32,
            coordinates_: [4]u32,
            rc_base_: u32,
        ) metal.EvalLayout {
            return .{
                .trace_offsets = trace_offsets_,
                .interaction_offsets = interaction_offsets_,
                .base_params = 0,
                .ext_params = 0,
                .random_coeffs = random_coeffs_,
                .denom_inv = denom_,
                .coordinates = coordinates_,
                .row_count = rows,
                .trace_log_size = 7,
                .domain_log_size = 7,
                .rc_base = rc_base_,
            };
        }
    }.make;
    var first_plan = try runtime.prepareEval(
        first_source,
        first_name,
        layout(trace_offsets, interaction_offsets, random_coeffs, denom, legacy_coordinates, 0),
    );
    defer first_plan.deinit();
    var second_plan = try runtime.prepareEval(
        second_source,
        second_name,
        layout(trace_offsets, interaction_offsets, random_coeffs, denom, legacy_coordinates, 1),
    );
    defer second_plan.deinit();
    var fused_plan = try runtime.prepareEval(
        fused_source,
        fused_name,
        layout(trace_offsets, interaction_offsets, random_coeffs, denom, fused_coordinates, 0),
    );
    defer fused_plan.deinit();
    _ = try runtime.evalPrepared(arena, first_plan);
    _ = try runtime.evalPrepared(arena, second_plan);
    _ = try runtime.evalPrepared(arena, fused_plan);
    for (legacy_coordinates, fused_coordinates) |legacy, fused|
        try std.testing.expectEqualSlices(u32, words[legacy .. legacy + rows], words[fused .. fused + rows]);
}

test "metal: composition graph interleaves LDE and AIR before finalizing coefficients" {
    const allocator = std.testing.allocator;
    const base_log: u32 = 8;
    const eval_log: u32 = 10;
    const base_rows = @as(usize, 1) << base_log;
    const eval_rows = @as(usize, 1) << eval_log;
    const base_domain = canonic.CanonicCoset.new(base_log).circleDomain();
    const eval_domain = canonic.CanonicCoset.new(eval_log).circleDomain();
    var base_tree = try twiddles.precomputeM31(allocator, base_domain.half_coset);
    defer twiddles.deinitM31(allocator, &base_tree);
    var eval_tree = try twiddles.precomputeM31(allocator, eval_domain.half_coset);
    defer twiddles.deinitM31(allocator, &eval_tree);
    const base_const_tree = twiddles.TwiddleTree([]const M31).init(base_tree.root_coset, base_tree.twiddles, base_tree.itwiddles);
    const eval_const_tree = twiddles.TwiddleTree([]const M31).init(eval_tree.root_coset, eval_tree.twiddles, eval_tree.itwiddles);
    const coefficients = try allocator.alloc(M31, base_rows);
    defer allocator.free(coefficients);
    for (coefficients, 0..) |*value, row| value.* = M31.fromCanonical(@intCast((row * 65537 + 19) % m31.Modulus));
    var expected = try allocator.dupe(M31, coefficients);
    defer allocator.free(expected);
    var base_columns = [_][]M31{expected};
    try circle_poly.interpolateBuffersWithTwiddles(&base_columns, base_domain, base_const_tree);
    const source_coefficients = try allocator.dupe(M31, expected);
    defer allocator.free(source_coefficients);
    expected = try allocator.realloc(expected, eval_rows);
    @memset(expected[base_rows..], M31.zero());
    var eval_columns = [_][]M31{expected};
    try circle_poly.evaluateBuffersWithTwiddles(&eval_columns, eval_domain, eval_const_tree);

    var base_insts = [_]eval_program.BaseInst{
        .{ .op = .trace_col, .interaction = 0, .dst = 0, .a = 0, .b = 0, .imm = 0 },
        .{ .op = .constant, .interaction = 0, .dst = 1, .a = 0, .b = 0, .imm = 0 },
    };
    var ext_insts = [_]eval_program.ExtInst{
        .{ .op = .secure_col, .dst = 0, .a = 0, .b = 1, .c = 1, .d = 1 },
    };
    var roots = [_]u32{0};
    const program = eval_program.Program{
        .allocator = allocator,
        .header = .{ .flags = eval_program.Flag.prefinalized_logup, .semantic_hash = 0x5678, .capability_bits = eval_program.Capability.prefinalized_logup, .n_interactions = 1, .n_base_params = 0, .n_ext_params = 0, .n_constraints = 1, .max_base_regs = 2, .max_ext_regs = 1, .domain_log_size = base_log },
        .base_consts = &.{},
        .ext_consts = &.{},
        .base_insts = &base_insts,
        .ext_insts = &ext_insts,
        .constraint_roots = &roots,
    };
    const source = try eval_codegen.generate(allocator, program);
    defer allocator.free(source);
    const name = try eval_codegen.kernelName(allocator, program.header.semantic_hash);
    defer allocator.free(name);
    var runtime = try metal.Runtime.init();
    defer runtime.deinit();
    var arena = try runtime.allocateResidentBuffer(128 * 1024);
    defer arena.deinit();
    const words: [*]u32 = @ptrCast(@alignCast(arena.contents));
    const coefficient_offset: u32 = 0;
    const tile_offset: u32 = 1024;
    const twiddle_offset: u32 = 4096;
    const trace_offsets: u32 = 8192;
    const interaction_offsets: u32 = 8193;
    const random_offset: u32 = 8194;
    const denom_offset: u32 = 8198;
    const accumulator_offset: u32 = 8202;
    const previous_accumulator_offset: u32 = 6000;
    const inverse_twiddle_offset: u32 = 25_100;
    const output_start: u32 = 26_000;
    var output_offsets: [8]u32 = undefined;
    for (&output_offsets, 0..) |*offset, index| offset.* = output_start + @as(u32, @intCast(index * eval_rows / 2));
    @memcpy(words[coefficient_offset .. coefficient_offset + base_rows], std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(source_coefficients)));
    @memcpy(words[twiddle_offset .. twiddle_offset + eval_tree.twiddles.len], std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(eval_tree.twiddles)));
    @memcpy(words[inverse_twiddle_offset .. inverse_twiddle_offset + eval_tree.itwiddles.len], std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(eval_tree.itwiddles)));
    @memset(words[previous_accumulator_offset .. previous_accumulator_offset + 4 * (@as(usize, 1) << 8)], 0);
    words[trace_offsets] = tile_offset;
    words[interaction_offsets] = 0;
    words[random_offset..][0..4].* = .{ 1, 0, 0, 0 };
    words[denom_offset..][0..4].* = .{ 1, 1, 1, 1 };
    var eval_plan = try runtime.prepareEval(source, name, .{
        .trace_offsets = trace_offsets,
        .interaction_offsets = interaction_offsets,
        .base_params = 0,
        .ext_params = 0,
        .random_coeffs = random_offset,
        .denom_inv = denom_offset,
        .coordinates = .{ accumulator_offset, accumulator_offset + eval_rows, accumulator_offset + 2 * eval_rows, accumulator_offset + 3 * eval_rows },
        .row_count = eval_rows,
        .trace_log_size = base_log,
        .domain_log_size = base_log,
        .rc_base = 0,
    });
    defer eval_plan.deinit();
    var eval_batch = try runtime.prepareEvalBatch(&.{eval_plan});
    defer eval_batch.deinit();
    var lde = try runtime.prepareCompositionLde(&.{coefficient_offset}, &.{base_log}, &.{tile_offset}, eval_log, twiddle_offset);
    defer lde.deinit();
    const dynamic_source: u32 = 25_020;
    words[dynamic_source..][0..4].* = .{ 7, 11, 13, 17 };
    const ext_descriptors = [_]metal.CompositionExtParamDescriptor{
        .{ .destination = 25_000, .kind = 0, .source = 0, .scale = 2, .constant = .{ 3, 5, 19, 23 } },
        .{ .destination = 25_004, .kind = 1, .source = dynamic_source, .scale = 3, .constant = .{ 0, 0, 0, 0 } },
    };
    var inputs = try runtime.prepareCompositionInputs(&ext_descriptors, random_offset, random_offset, 1);
    defer inputs.deinit();
    var front = try runtime.prepareCompositionFront(inputs, &.{lde}, &.{eval_batch}, accumulator_offset, 4 * eval_rows);
    defer front.deinit();
    const scale = try M31.fromCanonical(@intCast(eval_rows)).inv();
    var finalize = try runtime.prepareCompositionFinalize(
        &.{ previous_accumulator_offset, accumulator_offset },
        &.{ 8, eval_log },
        inverse_twiddle_offset,
        output_offsets,
        scale.v,
    );
    defer finalize.deinit();
    var expected_coefficients = try allocator.dupe(M31, expected);
    defer allocator.free(expected_coefficients);
    var expected_columns = [_][]M31{expected_coefficients};
    try circle_poly.interpolateBuffersWithTwiddles(&expected_columns, eval_domain, eval_const_tree);
    const gpu_ms = try runtime.compositionPrepared(arena, front, finalize);
    try std.testing.expect(gpu_ms > 0);
    try std.testing.expectEqualSlices(u32, &.{ 6, 10, 38, 46, 21, 33, 39, 51 }, words[25_000..25_008]);
    for (0..8) |output| {
        const actual_words = words[output_offsets[output] .. output_offsets[output] + eval_rows / 2];
        if ((output & 3) == 0) {
            const half = output >> 2;
            try std.testing.expectEqualSlices(
                u32,
                std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(expected_coefficients[half * eval_rows / 2 ..][0 .. eval_rows / 2])),
                actual_words,
            );
        } else for (actual_words) |value| try std.testing.expectEqual(@as(u32, 0), value);
    }
}

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
        true,
        true,
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

    const untouched: u32 = 0x5a5a5a5a;
    for (trace_offsets) |offset| @memset(words[offset .. offset + rows], untouched);
    for (partial_offsets) |offset| @memset(words[offset .. offset + partial_rows], untouched);
    for (multiplicity_offsets, multiplicity_lengths) |offset, length| @memset(words[offset .. offset + length], untouched);
    @memset(words[lookup_offset .. lookup_offset + expected_lookup.len], 0);
    var lookup_plan = try runtime.prepareEcOp(
        execution_offsets,
        trace_offsets,
        partial_offsets,
        multiplicity_offsets,
        lookup_offset,
        segment_offset,
        scratch_offset,
        rows,
        false,
        true,
    );
    defer lookup_plan.deinit();
    _ = try runtime.ecOpPrepared(arena, lookup_plan);
    try std.testing.expectEqualSlices(u32, expected_lookup, words[lookup_offset .. lookup_offset + expected_lookup.len]);
    for (trace_offsets) |offset| for (words[offset .. offset + rows]) |value| try std.testing.expectEqual(untouched, value);
    for (partial_offsets) |offset| for (words[offset .. offset + partial_rows]) |value| try std.testing.expectEqual(untouched, value);
    for (multiplicity_offsets, multiplicity_lengths) |offset, length| for (words[offset .. offset + length]) |value| try std.testing.expectEqual(untouched, value);
}

test "metal: resident EC-op finalizes canonical padding across threadgroups" {
    const allocator = std.testing.allocator;
    const bytes = try std.fs.cwd().readFileAlloc(allocator, "vectors/cairo/ec_op_parity.bin", 16 * 1024 * 1024);
    defer allocator.free(bytes);
    var cursor: usize = 8;
    const Read = struct {
        fn word(data: []const u8, at: *usize) u32 {
            const value = std.mem.readInt(u32, data[at.*..][0..4], .little);
            at.* += 4;
            return value;
        }
    };
    try std.testing.expectEqualSlices(u8, "STWZECO\x00", bytes[0..8]);
    try std.testing.expectEqual(@as(u32, 1), Read.word(bytes, &cursor));
    const fixture_rows = Read.word(bytes, &cursor);
    const segment = Read.word(bytes, &cursor);
    const n_addresses = Read.word(bytes, &cursor);
    const n_big = Read.word(bytes, &cursor);
    const n_small = Read.word(bytes, &cursor);
    try std.testing.expectEqual(@as(u32, 64), fixture_rows);
    const address_bytes: []align(4) const u8 = @alignCast(bytes[cursor .. cursor + @as(usize, n_addresses) * 4]);
    const addresses = std.mem.bytesAsSlice(u32, address_bytes);
    cursor += @as(usize, n_addresses) * 4;
    const big_bytes: []align(4) const u8 = @alignCast(bytes[cursor .. cursor + @as(usize, n_big) * 8 * 4]);
    const big_words = std.mem.bytesAsSlice(u32, big_bytes);
    cursor += @as(usize, n_big) * 8 * 4;
    const small_bytes: []align(4) const u8 = @alignCast(bytes[cursor .. cursor + @as(usize, n_small) * 4 * 4]);
    const small_words = std.mem.bytesAsSlice(u32, small_bytes);
    cursor += @as(usize, n_small) * 4 * 4;
    const trace_bytes: []align(4) const u8 = @alignCast(bytes[cursor .. cursor + @as(usize, fixture_rows) * 273 * 4]);
    const expected_trace = std.mem.bytesAsSlice(u32, trace_bytes);
    cursor += @as(usize, fixture_rows) * 273 * 4;
    cursor += @as(usize, fixture_rows) * 488 * 4;
    const fixture_partial_rows = @as(usize, fixture_rows) * 256;
    const partial_bytes: []align(4) const u8 = @alignCast(bytes[cursor .. cursor + fixture_partial_rows * 127 * 4]);
    const expected_partial = std.mem.bytesAsSlice(u32, partial_bytes);

    const rows: u32 = 512;
    const address_count = @max(addresses.len, @as(usize, segment) + @as(usize, rows) * 7);
    const expanded_addresses = try allocator.alloc(u32, address_count);
    defer allocator.free(expanded_addresses);
    @memset(expanded_addresses, 0);
    @memcpy(expanded_addresses[0..addresses.len], addresses);
    for (0..rows) |row| {
        const source = @as(usize, segment) + (row % fixture_rows) * 7;
        const destination = @as(usize, segment) + row * 7;
        @memcpy(expanded_addresses[destination..][0..7], addresses[source..][0..7]);
    }

    const partial_rows = @as(usize, rows) * 256;
    const total_words = address_count + @as(usize, n_big) * 28 + @as(usize, n_small) * 8 +
        @as(usize, rows) * (273 + 488) + partial_rows * 127 +
        address_count + @as(usize, n_big) + @as(usize, n_small) + 256 + 1;
    var runtime = try metal.Runtime.init();
    defer runtime.deinit();
    var arena = try runtime.allocateResidentBuffer(total_words * 4);
    defer arena.deinit();
    const words: [*]u32 = @ptrCast(@alignCast(arena.contents));
    var next: u32 = 0;
    var execution_offsets: [37]u32 = undefined;
    execution_offsets[0] = next;
    @memcpy(words[next .. next + address_count], expanded_addresses);
    next += @intCast(address_count);
    for (0..28) |limb| {
        execution_offsets[1 + limb] = next;
        const bit = limb * 9;
        const source_limb = bit / 32;
        const shift: u5 = @intCast(bit % 32);
        for (0..n_big) |index| {
            const source = big_words[index * 8 ..][0..8];
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
        next += rows;
    }
    const lookup_offset = next;
    next += rows * 488;
    var partial_offsets: [127]u32 = undefined;
    for (&partial_offsets) |*offset| {
        offset.* = next;
        next += @intCast(partial_rows);
    }
    var multiplicity_offsets: [4]u32 = undefined;
    const multiplicity_lengths = [_]u32{ @intCast(address_count), n_big, n_small, 256 };
    for (&multiplicity_offsets, multiplicity_lengths) |*offset, length| {
        offset.* = next;
        next += length;
    }
    const segment_offset = next;
    words[next] = segment;
    next += 1;
    try std.testing.expect(@as(usize, next) <= total_words);

    var plan = try runtime.prepareEcOp(
        execution_offsets,
        trace_offsets,
        partial_offsets,
        multiplicity_offsets,
        lookup_offset,
        segment_offset,
        partial_offsets[126],
        rows,
        true,
        false,
    );
    defer plan.deinit();
    const poison: u32 = 0xa5a5a5a5;
    for (0..2) |_| {
        for (trace_offsets) |offset| @memset(words[offset .. offset + rows], poison);
        for (partial_offsets) |offset| @memset(words[offset .. offset + partial_rows], poison);
        for (multiplicity_offsets, multiplicity_lengths) |offset, length| @memset(words[offset .. offset + length], 0);
        _ = try runtime.ecOpPrepared(arena, plan);

        for (0..rows) |row| for (trace_offsets, 0..) |offset, column| {
            const source_row = row % fixture_rows;
            try std.testing.expectEqual(expected_trace[source_row * 273 + column], words[offset + row]);
        };
        for ([_]u32{ 0, 1, 251 }) |round| for (partial_offsets[0..126], 0..) |offset, column| for (0..rows) |row| {
            const expected = if (column == 0)
                @as(u32, @intCast(row))
            else
                expected_partial[column * fixture_partial_rows + @as(usize, round) * fixture_rows + row % fixture_rows];
            try std.testing.expectEqual(expected, words[offset + @as(usize, round) * rows + row]);
        };
        for (252..256) |round| for (partial_offsets[0..126], 0..) |offset, column| for (0..rows) |row| {
            const pad = (round - 252) * rows + row;
            const expected = if (column == 125) @as(u32, 0) else expected_partial[column * fixture_partial_rows + (pad & 15)];
            try std.testing.expectEqual(expected, words[offset + round * rows + row]);
        };
        for (words[partial_offsets[126] .. partial_offsets[126] + partial_rows], 0..) |value, index|
            try std.testing.expectEqual(@as(u32, @intCast(index)), value);
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

    var runtime = try metal.Runtime.init();
    defer runtime.deinit();
    var arena = try runtime.allocateResidentBuffer(64 * 1024);
    defer arena.deinit();
    const arena_words: [*]u32 = @ptrCast(@alignCast(arena.contents));
    const source_offset: u32 = 0;
    const inverse_offset: u32 = @intCast(domain.size() * 4);
    const alpha_offset: u32 = inverse_offset + @as(u32, @intCast(line_domain.size()));
    const destination_offset: u32 = alpha_offset + 4;
    const source_words = std.mem.bytesAsSlice(
        u32,
        std.mem.sliceAsBytes(source.columns[0].ptr[0 .. domain.size() * 4]),
    );
    @memcpy(arena_words[source_offset .. source_offset + source_words.len], source_words);
    for (cpu_circle_workspace.inv_py_values[0..line_domain.size()], 0..) |value, row| {
        arena_words[inverse_offset + row] = value.v;
    }
    for (alpha.toM31Array(), 0..) |value, coordinate| arena_words[alpha_offset + coordinate] = value.v;
    var prepared = try runtime.prepareFriFold(
        source_offset,
        inverse_offset,
        alpha_offset,
        destination_offset,
        @intCast(domain.size()),
        true,
    );
    defer prepared.deinit();
    try std.testing.expect(try runtime.friFoldPrepared(arena, prepared) > 0);
    const prepared_values: [*]const QM31 = @ptrCast(@alignCast(arena_words + destination_offset));
    try std.testing.expectEqualSlices(QM31, expected, prepared_values[0..line_domain.size()]);

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

test "metal: prepared resident quotient combine matches canonical scalar formula" {
    const allocator = std.testing.allocator;
    const log_size: u32 = 6;
    const row_count: u32 = @as(u32, 1) << @intCast(log_size);
    var split = try canonic.CanonicCoset.new(log_size + 2).circleDomain().split(allocator, 2);
    defer split.deinit(allocator);
    const domain = split.subdomain;
    const sample_points = [_]circle_core.CirclePointQM31{
        circle_core.SECURE_FIELD_CIRCLE_GEN,
        circle_core.SECURE_FIELD_CIRCLE_GEN.double(),
    };
    const first_terms = [_]QM31{
        QM31.fromU32Unchecked(3, 5, 7, 11),
        QM31.fromU32Unchecked(13, 17, 19, 23),
    };
    const partial_logs = [_]u32{ 5, 6 };

    var runtime = try metal.Runtime.init();
    defer runtime.deinit();
    var arena = try runtime.allocateResidentBuffer(64 * 1024);
    defer arena.deinit();
    const words: [*]u32 = @ptrCast(@alignCast(arena.contents));
    const partial_offsets = [_]u32{ 0, 32, 96, 128, 192, 224, 288, 320 };
    for (0..partial_logs.len) |sample| {
        const length = @as(u32, 1) << @intCast(partial_logs[sample]);
        for (0..4) |coordinate| {
            const offset = partial_offsets[coordinate * partial_logs.len + sample];
            for (0..length) |row| {
                words[offset + row] = @intCast((sample * 100003 + coordinate * 65537 + row * 8191 + 29) % m31.Modulus);
            }
        }
    }
    const sample_offset: u32 = 512;
    for (sample_points, 0..) |point, sample| {
        const x = point.x.toM31Array();
        const y = point.y.toM31Array();
        const base = sample_offset + @as(u32, @intCast(sample)) * 8;
        for (0..4) |coordinate| words[base + coordinate] = x[coordinate].v;
        for (0..4) |coordinate| words[base + 4 + coordinate] = y[coordinate].v;
    }
    const linear_offset: u32 = 544;
    for (first_terms, 0..) |term, sample| {
        for (term.toM31Array(), 0..) |coordinate, index| {
            words[linear_offset + sample * 4 + index] = coordinate.v;
        }
    }
    const scratch_offset: u32 = 576;
    const output_offset: u32 = 1024;
    var prepared = try runtime.prepareQuotientCombine(
        &partial_offsets,
        &partial_logs,
        sample_offset,
        linear_offset,
        scratch_offset,
        output_offset,
        log_size,
        @intCast(domain.half_coset.initial_index.v),
        @intCast(domain.half_coset.step_size.v),
    );
    defer prepared.deinit();
    try std.testing.expect(try runtime.quotientCombinePrepared(arena, prepared) > 0);

    for (0..row_count) |row| {
        const point = domain.at(core_utils.bitReverseIndex(row, log_size));
        var expected = QM31.zero();
        for (sample_points, first_terms, partial_logs, 0..) |sample_point, first, partial_log, sample| {
            const denominator = sample_point.x.c0.subM31(point.x).mul(sample_point.y.c1).sub(
                sample_point.y.c0.subM31(point.y).mul(sample_point.x.c1),
            );
            const inverse = try denominator.inv();
            const log_ratio = log_size - partial_log;
            const lifted = (row >> @intCast(log_ratio + 1) << @intCast(1)) + (row & 1);
            var coordinates: [4]M31 = undefined;
            for (&coordinates, 0..) |*coordinate, index| {
                coordinate.* = M31.fromCanonical(words[partial_offsets[index * partial_logs.len + sample] + lifted]);
            }
            const numerator = QM31.fromM31Array(coordinates).sub(first.mulM31(point.y));
            expected = expected.add(numerator.mulCM31(inverse));
        }
        const actual = QM31.fromU32Unchecked(
            words[output_offset + row],
            words[output_offset + row_count + row],
            words[output_offset + 2 * row_count + row],
            words[output_offset + 3 * row_count + row],
        );
        try std.testing.expect(expected.eql(actual));
    }
}

test "metal: quotient recipe executes combine, interpolation, and LDE" {
    const allocator = std.testing.allocator;
    const subdomain_log: u32 = 6;
    const quotient_log: u32 = 8;
    const subdomain_rows: u32 = @as(u32, 1) << @intCast(subdomain_log);
    const quotient_rows: u32 = @as(u32, 1) << @intCast(quotient_log);
    var split = try canonic.CanonicCoset.new(quotient_log).circleDomain().split(
        allocator,
        quotient_log - subdomain_log,
    );
    defer split.deinit(allocator);
    const subdomain = split.subdomain;
    const quotient_domain = canonic.CanonicCoset.new(quotient_log).circleDomain();
    var runtime = try metal.Runtime.init();
    defer runtime.deinit();
    var resident = arena_plan.ResidentArena{ .buffer = try runtime.allocateResidentBuffer(64 * 1024) };
    defer resident.deinit();
    const words: [*]u32 = @ptrCast(@alignCast(resident.buffer.contents));

    const partials = [_]arena_plan.Binding{
        testResidentBinding(10, 0, subdomain_rows),
        testResidentBinding(11, 64, subdomain_rows),
        testResidentBinding(12, 128, subdomain_rows),
        testResidentBinding(13, 192, subdomain_rows),
    };
    const sample_points = testResidentBinding(14, 256, 8);
    const first_linear_terms = testResidentBinding(15, 264, 4);
    const denominator_scratch = testResidentBinding(16, 268, subdomain_rows * 2);
    const subdomain_values = testResidentBinding(17, 396, subdomain_rows * 4);
    const quotient_values = testResidentBinding(18, 652, quotient_rows * 4);
    const inverse_twiddles = testResidentBinding(19, 1676, subdomain_rows / 2);
    const forward_twiddles = testResidentBinding(20, 1708, @as(u32, 1) << @intCast(quotient_log + 1));

    for (partials, 0..) |partial, coordinate| {
        const base: usize = @intCast(partial.offset_bytes / 4);
        for (0..subdomain_rows) |row|
            words[base + row] = @intCast(1 + coordinate * 257 + row * 17);
    }
    const sample_point = circle_core.SECURE_FIELD_CIRCLE_GEN;
    for (sample_point.x.toM31Array(), 0..) |coordinate, index| words[256 + index] = coordinate.v;
    for (sample_point.y.toM31Array(), 0..) |coordinate, index| words[260 + index] = coordinate.v;
    @memset(words[264..268], 0);

    var subdomain_twiddles = try twiddles.precomputeM31(allocator, subdomain.half_coset);
    defer twiddles.deinitM31(allocator, &subdomain_twiddles);
    @memcpy(words[1676 .. 1676 + subdomain_twiddles.itwiddles.len], std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(subdomain_twiddles.itwiddles)));
    var quotient_twiddles = try twiddles.precomputeM31(allocator, circle_core.Coset.halfOdds(quotient_log + 1));
    defer twiddles.deinitM31(allocator, &quotient_twiddles);
    @memcpy(words[1708 .. 1708 + quotient_twiddles.twiddles.len], std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(quotient_twiddles.twiddles)));

    var expected_subdomain = try secure_column.SecureColumnByCoords.uninitialized(allocator, subdomain_rows);
    defer expected_subdomain.deinit(allocator);
    for (0..subdomain_rows) |row| {
        const point = subdomain.at(core_utils.bitReverseIndex(row, subdomain_log));
        const denominator = sample_point.x.c0.subM31(point.x).mul(sample_point.y.c1).sub(
            sample_point.y.c0.subM31(point.y).mul(sample_point.x.c1),
        );
        const inverse = try denominator.inv();
        const partial = QM31.fromU32Unchecked(
            words[partials[0].offset_bytes / 4 + row],
            words[partials[1].offset_bytes / 4 + row],
            words[partials[2].offset_bytes / 4 + row],
            words[partials[3].offset_bytes / 4 + row],
        );
        expected_subdomain.set(row, partial.mulCM31(inverse));
    }
    var expected_poly = try secure_circle_poly.interpolateFromEvaluation(
        allocator,
        subdomain,
        &expected_subdomain,
    );
    defer expected_poly.deinit(allocator);

    var recipe = try protocol_recipes.QuotientRecipe.init(
        allocator,
        &runtime,
        &resident,
        &partials,
        sample_points,
        first_linear_terms,
        denominator_scratch,
        subdomain_values,
        quotient_values,
        inverse_twiddles,
        forward_twiddles,
    );
    defer recipe.deinit();

    try recipe.execute();

    try std.testing.expect(recipe.accumulated_gpu_ms > 0);
    for (expected_poly.polys, 0..) |coordinate_poly, coordinate| {
        const expected = try coordinate_poly.evaluate(allocator, quotient_domain);
        defer allocator.free(@constCast(expected.values));
        const actual_offset = quotient_values.offset_bytes / 4 + coordinate * quotient_rows;
        for (expected.values, 0..) |expected_value, row| {
            try std.testing.expectEqual(expected_value.v, words[actual_offset + row]);
        }
    }
}

test "metal: fused resident FRI round matches scalar three-fold path" {
    const allocator = std.testing.allocator;
    const log_size: u32 = 6;
    const domain = canonic.CanonicCoset.new(log_size).circleDomain();
    var tree = try twiddles.precomputeM31(allocator, domain.half_coset);
    defer twiddles.deinitM31(allocator, &tree);
    var source = try MetalBackend.allocateSecureColumn(domain.size());
    defer source.deinit(allocator);
    for (source.columns, 0..) |column, coordinate| {
        for (column, 0..) |*value, row| {
            value.* = M31.fromCanonical(@intCast((coordinate * 65537 + row * 8191 + 43) % m31.Modulus));
        }
    }
    const alpha = QM31.fromU32Unchecked(7, 11, 13, 17);
    const first_domain = try line.LineDomain.init(circle_core.Coset.halfOdds(log_size - 1));
    const first_values = try allocator.alloc(QM31, first_domain.size());
    defer allocator.free(first_values);
    @memset(first_values, QM31.zero());
    var circle_workspace = try core_fri.FoldCircleWorkspace.init(allocator, first_values.len);
    defer circle_workspace.deinit(allocator);
    try core_fri.foldCircleColumnsIntoLineWithWorkspace(
        allocator,
        first_values,
        source.columns,
        domain,
        alpha,
        &circle_workspace,
    );
    var line_workspace = try core_fri.FoldLineWorkspace.init(allocator, first_values.len / 2);
    defer line_workspace.deinit(allocator);
    const second = try core_fri.foldLineSingleStep(
        allocator,
        first_values,
        first_domain,
        alpha.square(),
        &line_workspace,
    );
    defer allocator.free(second.values);
    const expected = try core_fri.foldLineSingleStep(
        allocator,
        second.values,
        second.domain,
        alpha.square().square(),
        &line_workspace,
    );
    defer allocator.free(expected.values);

    var runtime = try metal.Runtime.init();
    defer runtime.deinit();
    var arena = try runtime.allocateResidentBuffer(64 * 1024);
    defer arena.deinit();
    const words: [*]u32 = @ptrCast(@alignCast(arena.contents));
    const input_base: u32 = 0;
    const input_stride: u32 = @intCast(domain.size());
    for (source.columns, 0..) |column, coordinate| {
        const offset = input_base + @as(u32, @intCast(coordinate)) * input_stride;
        @memcpy(words[offset .. offset + column.len], std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(column)));
    }
    const twiddle_base: u32 = 512;
    @memcpy(words[twiddle_base .. twiddle_base + tree.itwiddles.len], std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(tree.itwiddles)));
    const alpha_base: u32 = 576;
    for (alpha.toM31Array(), 0..) |coordinate, index| words[alpha_base + index] = coordinate.v;
    const output_base: u32 = 640;
    const output_stride: u32 = 8;
    var prepared = try runtime.prepareFriRound(
        twiddle_base,
        @intCast(tree.itwiddles.len),
        input_base,
        input_stride,
        alpha_base,
        output_base,
        output_stride,
        @intCast(domain.size()),
        3,
        true,
    );
    defer prepared.deinit();
    try std.testing.expect(try runtime.friRoundPrepared(arena, prepared) > 0);
    for (expected.values, 0..) |value, row| {
        const coordinates = value.toM31Array();
        for (coordinates, 0..) |coordinate, index| {
            try std.testing.expectEqual(coordinate.v, words[output_base + index * output_stride + row]);
        }
    }
}

fn expectResidentFriLineRoundMatchesScalar(source_log_size: u32, fold_count: u32) !void {
    const allocator = std.testing.allocator;
    const twiddle_log_size: u32 = 8;
    const domain = try line.LineDomain.init(circle_core.Coset.halfOdds(source_log_size));
    var tree = try twiddles.precomputeM31(
        allocator,
        circle_core.Coset.halfOdds(twiddle_log_size),
    );
    defer twiddles.deinitM31(allocator, &tree);

    const source = try allocator.alloc(QM31, domain.size());
    defer allocator.free(source);
    for (source, 0..) |*value, row| {
        value.* = QM31.fromU32Unchecked(
            @intCast(3 + row * 17),
            @intCast(5 + row * 29),
            @intCast(7 + row * 43),
            @intCast(11 + row * 61),
        );
    }
    const alpha = QM31.fromU32Unchecked(19, 23, 31, 37);
    var workspace = try core_fri.FoldLineWorkspace.init(allocator, source.len / 2);
    defer workspace.deinit(allocator);
    const expected = try core_fri.foldLineNWithWorkspace(
        allocator,
        source,
        domain,
        alpha,
        &workspace,
        fold_count,
    );
    defer allocator.free(expected.values);

    var runtime = try metal.Runtime.init();
    defer runtime.deinit();
    var arena = try runtime.allocateResidentBuffer(64 * 1024);
    defer arena.deinit();
    const words: [*]u32 = @ptrCast(@alignCast(arena.contents));
    const input_base: u32 = 0;
    const input_stride: u32 = @intCast(source.len);
    for (source, 0..) |value, row| for (value.toM31Array(), 0..) |coordinate, index| {
        words[input_base + index * input_stride + row] = coordinate.v;
    };
    const alpha_base: u32 = 512;
    for (alpha.toM31Array(), 0..) |coordinate, index| words[alpha_base + index] = coordinate.v;
    const twiddle_base: u32 = 1024;
    @memcpy(
        words[twiddle_base .. twiddle_base + tree.itwiddles.len],
        std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(tree.itwiddles)),
    );
    const output_base: u32 = 2048;
    const output_stride: u32 = @intCast(expected.values.len);
    var prepared = try runtime.prepareFriRound(
        twiddle_base,
        @intCast(tree.itwiddles.len),
        input_base,
        input_stride,
        alpha_base,
        output_base,
        output_stride,
        @intCast(source.len),
        fold_count,
        false,
    );
    defer prepared.deinit();
    try std.testing.expect(try runtime.friRoundPrepared(arena, prepared) > 0);
    for (expected.values, 0..) |value, row| for (value.toM31Array(), 0..) |coordinate, index| {
        try std.testing.expectEqual(coordinate.v, words[output_base + index * output_stride + row]);
    };
}

test "metal: resident FRI line round selects the canonical twiddle subdomain" {
    try expectResidentFriLineRoundMatchesScalar(6, 3);
}

test "metal: resident FRI final two-fold round matches scalar path" {
    try expectResidentFriLineRoundMatchesScalar(3, 2);
}

test "metal: packed resident FRI tree matches canonical plain Blake2 root" {
    const evaluation_size: u32 = 8;
    var runtime = try metal.Runtime.init();
    defer runtime.deinit();
    var arena = try runtime.allocateResidentBuffer(16 * 1024);
    defer arena.deinit();
    const words: [*]u32 = @ptrCast(@alignCast(arena.contents));

    const evaluation_base: u32 = 0;
    const coordinate_stride: u32 = evaluation_size;
    var coordinates: [4][evaluation_size]M31 = undefined;
    for (&coordinates, 0..) |*column, coordinate| {
        for (column, 0..) |*value, row| {
            value.* = M31.fromCanonical(@intCast(1 + coordinate * 101 + row * 17));
            words[evaluation_base + coordinate * coordinate_stride + row] = value.v;
        }
    }

    const leaf_offset: u32 = 128;
    const root_offset: u32 = 160;
    const layers = [_]u32{ leaf_offset, root_offset };
    var prepared = try runtime.prepareFriTree(
        evaluation_base,
        coordinate_stride,
        evaluation_size,
        2,
        &layers,
        Hasher.leafSeed(),
        Hasher.nodeSeed(),
    );
    defer prepared.deinit();
    try std.testing.expect(try runtime.friTreePrepared(arena, prepared) > 0);

    var leaves: [2]Hasher.Hash = undefined;
    for (&leaves, 0..) |*digest, leaf| {
        var message: [16]M31 = undefined;
        for (0..4) |offset| for (0..4) |coordinate| {
            message[coordinate + 4 * offset] = coordinates[coordinate][4 * leaf + offset];
        };
        digest.* = blake2_hash.Blake2sHasher.hash(std.mem.sliceAsBytes(&message));
    }
    const expected = blake2_hash.Blake2sHasher.concatAndHash(leaves[0], leaves[1]);
    try std.testing.expectEqualSlices(
        u8,
        &expected,
        std.mem.asBytes(words[root_offset .. root_offset + 8]),
    );
}

test "metal: resident FRI final interpolation matches canonical line polynomial" {
    const allocator = std.testing.allocator;
    const domain = try line.LineDomain.init(circle_core.Coset.halfOdds(1));
    const values = [_]QM31{
        QM31.fromU32Unchecked(11, 13, 17, 19),
        QM31.fromU32Unchecked(23, 29, 31, 37),
    };
    var evaluation = try prover_line.LineEvaluation.initOwned(domain, try allocator.dupe(QM31, &values));
    var polynomial = try evaluation.interpolate(allocator);
    defer polynomial.deinit(allocator);
    const expected = polynomial.intoOrderedCoefficients();

    var runtime = try metal.Runtime.init();
    defer runtime.deinit();
    var arena = try runtime.allocateResidentBuffer(16 * 1024);
    defer arena.deinit();
    const words: [*]u32 = @ptrCast(@alignCast(arena.contents));
    const evaluation_base: u32 = 0;
    const stride: u32 = 2;
    for (values, 0..) |value, row| for (value.toM31Array(), 0..) |coordinate, index| {
        words[evaluation_base + index * stride + row] = coordinate.v;
    };
    const coefficient_base: u32 = 64;
    const error_offset: u32 = 80;
    const inverse_x = try domain.at(0).inv();
    var prepared = try runtime.prepareFriFinal(
        evaluation_base,
        stride,
        inverse_x.v,
        coefficient_base,
        error_offset,
    );
    defer prepared.deinit();
    try std.testing.expect(try runtime.friFinalPrepared(arena, prepared) > 0);
    for (expected, 0..) |coefficient, index| for (coefficient.toM31Array(), 0..) |coordinate, coordinate_index| {
        try std.testing.expectEqual(coordinate.v, words[coefficient_base + index * 4 + coordinate_index]);
    };
    try std.testing.expectEqual(@as(u32, @intFromBool(!expected[1].isZero())), words[error_offset]);
}

test "metal: FRI final-degree validation fails closed" {
    var runtime = try metal.Runtime.init();
    defer runtime.deinit();
    var resident = arena_plan.ResidentArena{ .buffer = try runtime.allocateResidentBuffer(16 * 1024) };
    defer resident.deinit();
    const words: [*]u32 = @ptrCast(@alignCast(resident.buffer.contents));
    const error_binding = testResidentBinding(1, 32, 1);
    var recipe = protocol_recipes.FriRecipe{
        .metal = &runtime,
        .arena = &resident,
        .rounds = undefined,
        .trees = undefined,
        .final = undefined,
        .roots = undefined,
        .initialized_rounds = 0,
        .initialized_trees = 0,
        .initialized_final = false,
        .final_degree_error = error_binding,
    };

    try std.testing.expectError(
        protocol_recipes.FriRecipe.FinalDegreeError.FinalDegreeNotComputed,
        recipe.validateFinalDegree(),
    );
    recipe.finalized = true;
    words[32] = 0;
    try recipe.validateFinalDegree();
    words[32] = 1;
    try std.testing.expectError(
        protocol_recipes.FriRecipe.FinalDegreeError.FinalDegreeExceeded,
        recipe.validateFinalDegree(),
    );
}

test "metal: resident Blake2s transcript matches host channel" {
    const allocator = std.testing.allocator;
    var runtime = try metal.Runtime.init();
    defer runtime.deinit();
    var arena = try runtime.allocateResidentBuffer(16 * 1024);
    defer arena.deinit();
    const words: [*]u32 = @ptrCast(@alignCast(arena.contents));
    const state_base_24: u32 = 0;
    const state_base_25: u32 = 16;
    const source_base: u32 = 32;
    const secure_base_24: u32 = 128;
    const secure_base_25: u32 = 144;
    const query_base_24: u32 = 192;
    const query_base_25: u32 = 224;
    const source = [_]QM31{
        QM31.fromU32Unchecked(1, 2, 3, 4),
        QM31.fromU32Unchecked(5, 6, 7, 8),
        QM31.fromU32Unchecked(9, 10, 11, 12),
    };
    @memcpy(words[source_base .. source_base + 12], std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(&source)));

    var channel = blake2s_channel.Blake2sChannel{};
    channel.mixFelts(&source);
    const expected_secure = try channel.drawSecureFelts(allocator, 3);
    defer allocator.free(expected_secure);
    var expected_queries_24: [13]u32 = undefined;
    var expected_queries_25: [13]u32 = undefined;
    var produced: usize = 0;
    while (produced < expected_queries_24.len) {
        const draw = channel.drawU32s();
        for (draw) |word| {
            expected_queries_24[produced] = word & ((@as(u32, 1) << 24) - 1);
            expected_queries_25[produced] = word & ((@as(u32, 1) << 25) - 1);
            produced += 1;
            if (produced == expected_queries_24.len) break;
        }
    }

    _ = try runtime.transcriptInit(arena, state_base_24);
    _ = try runtime.transcriptInit(arena, state_base_25);
    _ = try runtime.transcriptMix(arena, state_base_24, source_base, 12);
    _ = try runtime.transcriptMix(arena, state_base_25, source_base, 12);
    _ = try runtime.transcriptDrawSecure(arena, state_base_24, secure_base_24, 3);
    _ = try runtime.transcriptDrawSecure(arena, state_base_25, secure_base_25, 3);
    _ = try runtime.transcriptDrawQueries(arena, state_base_24, query_base_24, 24, expected_queries_24.len);
    _ = try runtime.transcriptDrawQueries(arena, state_base_25, query_base_25, 25, expected_queries_25.len);
    try std.testing.expectEqualSlices(
        u32,
        std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(expected_secure)),
        words[secure_base_24 .. secure_base_24 + 12],
    );
    try std.testing.expectEqualSlices(
        u32,
        std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(expected_secure)),
        words[secure_base_25 .. secure_base_25 + 12],
    );
    try std.testing.expectEqualSlices(u32, &expected_queries_24, words[query_base_24 .. query_base_24 + expected_queries_24.len]);
    try std.testing.expectEqualSlices(u32, &expected_queries_25, words[query_base_25 .. query_base_25 + expected_queries_25.len]);
}

test "metal: resident decommit query preparation matches canonical mapping" {
    var runtime = try metal.Runtime.init();
    defer runtime.deinit();
    var arena = try runtime.allocateResidentBuffer(16 * 1024);
    defer arena.deinit();
    const words: [*]u32 = @ptrCast(@alignCast(arena.contents));
    const raw_base: u32 = 0;
    const unique_base: u32 = 64;
    const unique_count_base: u32 = 120;
    const tree_base: u32 = 128;
    const tree_count_base: u32 = 184;
    const expanded_base: u32 = 192;
    const expanded_count_base: u32 = 320;
    const walk_base: u32 = 328;
    const walk_count_base: u32 = 456;
    const assembly_base: u32 = 3150;
    const assembly_capacity: u32 = 946;
    const raw = [_]u32{ 0x101, 7, 7, 33, 2, 0x1ff, 65, 16, 17, 18, 19 };
    @memcpy(words[raw_base .. raw_base + raw.len], &raw);
    _ = try runtime.decommitNormalizeQueries(arena, raw_base, raw.len, 8, unique_base, unique_count_base, 12, assembly_base, assembly_capacity);
    try std.testing.expectEqual(@as(u32, 10), words[unique_count_base]);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 7, 16, 17, 18, 19, 33, 65, 255 }, words[unique_base .. unique_base + 10]);
    try std.testing.expectEqualSlices(u32, &.{ 0x44575453, 1, 12, raw.len, 10, 200, 211, 221 }, words[assembly_base .. assembly_base + 8]);
    try std.testing.expectEqualSlices(u32, &.{ 1, 7, 7, 33, 2, 255, 65, 16, 17, 18, 19 }, words[assembly_base + 200 .. assembly_base + 211]);

    _ = try runtime.decommitPrepareFriQueries(
        arena,
        unique_base,
        unique_count_base,
        raw.len,
        3,
        3,
        2,
        tree_base,
        tree_count_base,
        expanded_base,
        expanded_count_base,
        walk_base,
        walk_count_base,
    );
    try std.testing.expectEqual(@as(u32, 5), words[tree_count_base]);
    try std.testing.expectEqualSlices(u32, &.{ 0, 2, 4, 8, 31 }, words[tree_base .. tree_base + 5]);
    try std.testing.expectEqual(@as(u32, 24), words[expanded_count_base]);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4, 5, 6, 7 }, words[expanded_base .. expanded_base + 8]);
    try std.testing.expectEqual(@as(u32, 6), words[walk_count_base]);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 6, 7 }, words[walk_base .. walk_base + 6]);

    _ = try runtime.decommitPrepareTraceQueries(
        arena,
        unique_base,
        unique_count_base,
        raw.len,
        24,
        21,
        21,
        2,
        tree_base,
        tree_count_base,
        walk_base,
        walk_count_base,
        expanded_base,
        expanded_count_base,
    );
    try std.testing.expectEqual(@as(u32, 10), words[tree_count_base]);
    try std.testing.expectEqualSlices(u32, &.{ 1, 0, 1, 2, 3, 2, 3, 5, 9, 31 }, words[tree_base .. tree_base + 10]);
    try std.testing.expectEqual(@as(u32, 7), words[walk_count_base]);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 5, 9, 31 }, words[walk_base .. walk_base + 7]);
    try std.testing.expectEqual(@as(u32, 16), words[expanded_count_base]);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 28, 29, 30, 31 }, words[expanded_base .. expanded_base + 16]);

    const column_offsets_base: u32 = 480;
    const column_logs_base: u32 = 484;
    const trace_values_base: u32 = 1024;
    words[column_offsets_base] = 512;
    words[column_offsets_base + 1] = 0;
    words[column_offsets_base + 2] = 768;
    words[column_offsets_base + 3] = 0;
    words[column_logs_base] = 8;
    words[column_logs_base + 1] = 7;
    for (0..256) |row| words[512 + row] = @intCast(1000 + row);
    for (0..128) |row| words[768 + row] = @intCast(2000 + row);
    const sparse_hashes_base: u32 = 2000;
    _ = try runtime.decommitTraceGroup(
        arena,
        .{
            .column_offsets = column_offsets_base,
            .column_logs = column_logs_base,
            .queries = tree_base,
            .query_count_at = tree_count_base,
            .values = trace_values_base,
            .leaf_indices = expanded_base,
            .leaf_count_at = expanded_count_base,
            .output_hashes = sparse_hashes_base,
            .column_count = 2,
            .lifting_log = 8,
            .max_queries = raw.len,
            .first_column = 0,
            .stride = raw.len,
            .total_columns = 2,
            .max_leaf_count = raw.len << 2,
            .leaf_seed = Hasher.leafSeed(),
        },
    );
    for (words[tree_base .. tree_base + words[tree_count_base]], 0..) |query, index| {
        try std.testing.expectEqual(1000 + query, words[trace_values_base + index]);
        const lifted = ((query >> 2) << 1) + (query & 1);
        try std.testing.expectEqual(2000 + lifted, words[trace_values_base + raw.len + index]);
    }

    _ = try runtime.decommitPrepareFriQueries(
        arena,
        unique_base,
        unique_count_base,
        raw.len,
        3,
        3,
        2,
        tree_base,
        tree_count_base,
        expanded_base,
        expanded_count_base,
        walk_base,
        walk_count_base,
    );
    const coordinate_bases: u32 = 490;
    const fri_values_base: u32 = 3000;
    for (0..4) |coordinate| {
        words[coordinate_bases + coordinate * 2] = @intCast(1600 + coordinate * 256);
        words[coordinate_bases + coordinate * 2 + 1] = 0;
        for (0..256) |row| words[1600 + coordinate * 256 + row] = @intCast(coordinate * 1000 + row);
    }
    _ = try runtime.decommitGatherFriValues(
        arena,
        coordinate_bases,
        expanded_base,
        expanded_count_base,
        128,
        fri_values_base,
    );
    for (words[expanded_base .. expanded_base + words[expanded_count_base]], 0..) |position, index| {
        for (0..4) |coordinate| try std.testing.expectEqual(
            @as(u32, @intCast(coordinate * 1000)) + position,
            words[fri_values_base + index * 4 + coordinate],
        );
    }
    const retained_offsets: u32 = 3100;
    words[retained_offsets] = 0;
    words[retained_offsets + 1] = 0;
    words[retained_offsets + 2] = 2890;
    words[retained_offsets + 3] = 0;
    words[retained_offsets + 4] = 2922;
    words[retained_offsets + 5] = 0;
    for (0..32) |index| words[2890 + index] = @intCast(0x1000 + index);
    for (0..64) |index| words[2922 + index] = @intCast(0x2000 + index);
    _ = try runtime.decommitAssembleFri(
        arena,
        4,
        2,
        tree_base,
        tree_count_base,
        expanded_base,
        expanded_count_base,
        fri_values_base,
        walk_base,
        900,
        walk_count_base,
        retained_offsets,
        assembly_base,
        assembly_capacity,
    );
    try std.testing.expect(words[assembly_base + 7] > 221);
    try std.testing.expectEqual(@as(u32, 1), words[assembly_base + 8 + 4 * 16]);
    try std.testing.expectEqual(@as(u32, 4), words[assembly_base + 8 + 4 * 16 + 1]);
}

test "metal: trace sparse parents and assembly are resident and fail closed" {
    var runtime = try metal.Runtime.init();
    defer runtime.deinit();
    var arena = try runtime.allocateResidentBuffer(64 * 1024);
    defer arena.deinit();
    const words: [*]u32 = @ptrCast(@alignCast(arena.contents));
    const counts: u32 = 100;
    const mapped: u32 = 128;
    const walk: u32 = 256;
    const scratch: u32 = 320;
    const values: u32 = 384;
    const sparse_indices: u32 = 512;
    const sparse_hashes: u32 = 640;
    const sparse_offsets: u32 = 800;
    const retained_offsets: u32 = 820;
    const retained_level_one: u32 = 832;
    const parent_indices: u32 = 900;
    const parent_hashes: u32 = 920;
    const assembly: u32 = 1024;
    const capacity: u32 = 2048;

    words[mapped] = 0;
    words[mapped + 1] = 1;
    words[counts + 1] = 2;
    words[walk] = 0;
    words[walk + 1] = 1;
    words[counts + 2] = 2;
    words[counts + 4] = 2;
    words[values] = 11;
    words[values + 1] = 12;
    words[sparse_indices] = 0;
    words[sparse_indices + 1] = 1;
    words[sparse_offsets] = 0;
    const column_offsets: u32 = 1180;
    const column_logs: u32 = 1184;
    const column_zero: u32 = 1200;
    const column_one: u32 = 1210;
    words[column_offsets] = column_zero;
    words[column_offsets + 1] = 0;
    words[column_offsets + 2] = column_one;
    words[column_offsets + 3] = 0;
    words[column_logs] = 2;
    words[column_logs + 1] = 2;
    for (0..4) |row| {
        words[column_zero + row] = @intCast(10 + row);
        words[column_one + row] = @intCast(20 + row);
    }
    _ = try runtime.decommitSparseLeaves(
        arena,
        column_offsets,
        column_logs,
        2,
        2,
        sparse_indices,
        counts + 4,
        2,
        sparse_hashes,
        Hasher.leafSeed(),
    );
    for (0..2) |row| {
        var leaf = Hasher.defaultWithInitialState();
        leaf.updateLeaf(&.{ M31.fromCanonical(@intCast(10 + row)), M31.fromCanonical(@intCast(20 + row)) });
        const expected = leaf.finalize();
        try std.testing.expectEqualSlices(
            u8,
            &expected,
            std.mem.sliceAsBytes(words[sparse_hashes + row * 8 .. sparse_hashes + (row + 1) * 8]),
        );
    }

    const streamed_offsets: u32 = 1500;
    const streamed_logs: u32 = 1570;
    const streamed_columns: u32 = 1620;
    const streamed_hashes: u32 = 1800;
    for (0..33) |column| {
        words[streamed_offsets + column * 2] = @intCast(streamed_columns + column * 4);
        words[streamed_offsets + column * 2 + 1] = 0;
        words[streamed_logs + column] = 2;
        for (0..4) |row| words[streamed_columns + column * 4 + row] = @intCast(100 + column * 10 + row);
    }
    _ = try runtime.decommitSparseLeafGroup(
        arena,
        streamed_offsets,
        streamed_logs,
        16,
        0,
        33,
        2,
        sparse_indices,
        counts + 4,
        2,
        streamed_hashes,
        Hasher.leafSeed(),
    );
    _ = try runtime.decommitSparseLeafGroup(
        arena,
        streamed_offsets + 32,
        streamed_logs + 16,
        16,
        16,
        33,
        2,
        sparse_indices,
        counts + 4,
        2,
        streamed_hashes,
        Hasher.leafSeed(),
    );
    _ = try runtime.decommitSparseLeafGroup(
        arena,
        streamed_offsets + 64,
        streamed_logs + 32,
        1,
        32,
        33,
        2,
        sparse_indices,
        counts + 4,
        2,
        streamed_hashes,
        Hasher.leafSeed(),
    );
    for (0..2) |row| {
        var evaluations: [33]M31 = undefined;
        for (&evaluations, 0..) |*value, column| value.* = M31.fromCanonical(@intCast(100 + column * 10 + row));
        var leaf = Hasher.defaultWithInitialState();
        leaf.updateLeaf(&evaluations);
        const expected = leaf.finalize();
        try std.testing.expectEqualSlices(
            u8,
            &expected,
            std.mem.sliceAsBytes(words[streamed_hashes + row * 8 .. streamed_hashes + (row + 1) * 8]),
        );
    }
    words[retained_offsets] = 0;
    words[retained_offsets + 1] = 0;
    words[retained_offsets + 2] = retained_level_one;
    words[retained_offsets + 3] = 0;
    for (0..16) |index| words[retained_level_one + index] = @intCast(0x200 + index);

    words[assembly] = 0x44575453;
    words[assembly + 1] = 1;
    words[assembly + 2] = 1;
    words[assembly + 7] = 24;
    _ = try runtime.decommitAssembleTrace(
        arena,
        0,
        0,
        2,
        1,
        1,
        mapped,
        counts + 1,
        70,
        walk,
        scratch,
        counts + 2,
        values,
        retained_offsets,
        sparse_indices,
        sparse_hashes,
        sparse_offsets,
        counts + 4,
        1,
        assembly,
        capacity,
    );
    try std.testing.expect(words[assembly + 7] > 24);
    try std.testing.expectEqual(@as(u32, 0), words[assembly + 8]);
    try std.testing.expect(words[assembly + 8 + 15] != 0);

    words[sparse_indices + 2] = 2;
    words[sparse_indices + 3] = 3;
    words[counts + 4] = 4;
    for (16..32) |index| words[sparse_hashes + index] = @intCast(0x100 + index);
    _ = try runtime.decommitSparseParent(
        arena,
        sparse_indices,
        sparse_hashes,
        counts + 4,
        4,
        parent_indices,
        parent_hashes,
        counts + 5,
        Hasher.nodeSeed(),
    );
    try std.testing.expectEqual(@as(u32, 2), words[counts + 5]);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1 }, words[parent_indices .. parent_indices + 2]);
    var nonzero = false;
    for (words[parent_hashes .. parent_hashes + 16]) |word| nonzero = nonzero or word != 0;
    try std.testing.expect(nonzero);
}

test "metal: exact Cairo transcript controller binds resident ordinals" {
    var runtime = try metal.Runtime.init();
    defer runtime.deinit();
    var resident = arena_plan.ResidentArena{ .buffer = try runtime.allocateResidentBuffer(16 * 1024) };
    defer resident.deinit();
    const words: [*]u32 = @ptrCast(@alignCast(resident.buffer.contents));
    const occupied = [_]u64{0} ** (arena_plan.max_ticks / 64);
    const input_ordinals = [_]u32{ 1, 2, 3, 10, 11, 12, 13, 14, 15, 16, 20 };
    const input_lengths = [_]u32{ 4, 8, 8, 4, 4, 4, 4, 4, 8, 8, 8 };
    var inputs: [input_ordinals.len]protocol_recipes.TranscriptBinding = undefined;
    var next: u32 = 64;
    var channel = blake2s_channel.Blake2sChannel{};
    for (input_ordinals, input_lengths, &inputs) |binding_ordinal, length, *input| {
        for (0..length) |index| words[next + index] = @intCast(1 + binding_ordinal * 19 + index);
        channel.mixU32s(words[next .. next + length]);
        input.* = .{
            .ordinal = binding_ordinal,
            .binding = .{
                .logical_id = binding_ordinal,
                .slot = binding_ordinal,
                .offset_bytes = @as(u64, next) * 4,
                .size_bytes = @as(u64, length) * 4,
                .materialization = .resident,
                .occupied = occupied,
            },
        };
        next += length;
    }
    const state = arena_plan.Binding{
        .logical_id = 1000,
        .slot = 1000,
        .offset_bytes = 0,
        .size_bytes = 64,
        .materialization = .resident,
        .occupied = occupied,
    };
    const dummy_output = protocol_recipes.TranscriptBinding{
        .ordinal = 1,
        .binding = .{
            .logical_id = 1001,
            .slot = 1001,
            .offset_bytes = 1024,
            .size_bytes = 32,
            .materialization = .resident,
            .occupied = occupied,
        },
    };
    var recipe = try protocol_recipes.TranscriptRecipe.init(
        std.testing.allocator,
        &runtime,
        &resident,
        state,
        24,
        &inputs,
        &.{dummy_output},
    );
    defer recipe.deinit();
    try recipe.initialize();
    try recipe.bootstrapThroughBase();
    try std.testing.expectEqualSlices(u8, &channel.digest, std.mem.sliceAsBytes(words[0..8]));
    try std.testing.expectEqual(@as(u32, 0), words[8]);
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
    const source_offsets = [_]u64{ 0, 4096 };
    const destination_offsets = [_]u64{ 8192, 16384 };
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
    const source_offsets = [_]u64{ 0, 2048 };
    const destination_offsets = [_]u64{ 4096, 8192 };
    const twiddle_offset: u32 = 12288;
    for (evaluations, source_offsets) |column, offset| {
        const word_offset: usize = @intCast(offset);
        @memcpy(words[word_offset .. word_offset + column.len], std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(column)));
    }
    @memcpy(words[twiddle_offset .. twiddle_offset + tree.itwiddles.len], std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(tree.itwiddles)));
    const scale = try M31.fromCanonical(@intCast(domain.size())).inv();
    var plan = try runtime.prepareCircleIfft(&source_offsets, &destination_offsets, log_size, twiddle_offset, scale.v);
    defer plan.deinit();
    _ = try runtime.circleIfftPrepared(arena, plan);
    for (expected, destination_offsets) |column, offset| {
        const word_offset: usize = @intCast(offset);
        const actual_bytes = std.mem.sliceAsBytes(words[word_offset .. word_offset + column.len]);
        const actual: []align(@alignOf(M31)) const u8 = @alignCast(actual_bytes);
        try std.testing.expectEqualSlices(M31, column, std.mem.bytesAsSlice(M31, actual));
    }
}

fn expectPreparedSparseIfftDeterministic(log_size: u32, repetitions: usize) !void {
    const allocator = std.testing.allocator;
    var runtime = try metal.Runtime.init();
    defer runtime.deinit();
    const domain = canonic.CanonicCoset.new(log_size).circleDomain();
    const rows = domain.size();
    var tree = try twiddles.precomputeM31(allocator, domain.half_coset);
    defer twiddles.deinitM31(allocator, &tree);
    const const_tree = twiddles.TwiddleTree([]const M31).init(
        tree.root_coset,
        tree.twiddles,
        tree.itwiddles,
    );

    var evaluations: [2][]M31 = undefined;
    var expected: [2][]M31 = undefined;
    defer for (&evaluations) |column| allocator.free(column);
    defer for (&expected) |column| allocator.free(column);
    for (&evaluations, &expected, 0..) |*evaluation, *coefficient, column_index| {
        evaluation.* = try allocator.alloc(M31, rows);
        coefficient.* = try allocator.alloc(M31, rows);
        for (evaluation.*, 0..) |*value, row| value.* = M31.fromCanonical(
            @intCast((column_index * 0x1f123 + row * 0x10101 + row * row * 17 + 29) % m31.Modulus),
        );
        @memcpy(coefficient.*, evaluation.*);
    }
    try circle_poly.interpolateBuffersWithTwiddles(&expected, domain, const_tree);

    const source_offsets = [_]u64{ 0, rows };
    const destination_offsets = [_]u64{ 2 * rows, 3 * rows };
    const twiddle_offset: u32 = @intCast(4 * rows);
    const arena_words = 4 * rows + tree.itwiddles.len;
    var arena = try runtime.allocateResidentBuffer(arena_words * @sizeOf(u32));
    defer arena.deinit();
    const words: [*]u32 = @ptrCast(@alignCast(arena.contents));
    @memcpy(
        words[twiddle_offset .. twiddle_offset + tree.itwiddles.len],
        std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(tree.itwiddles)),
    );
    const scale = try M31.fromCanonical(@intCast(rows)).inv();
    var plan = try runtime.prepareCircleIfft(
        &source_offsets,
        &destination_offsets,
        log_size,
        twiddle_offset,
        scale.v,
    );
    defer plan.deinit();

    for (0..repetitions) |_| {
        for (evaluations, source_offsets) |column, offset| {
            const start: usize = @intCast(offset);
            @memcpy(
                words[start .. start + rows],
                std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(column)),
            );
        }
        _ = try runtime.circleIfftPrepared(arena, plan);
        for (expected, destination_offsets) |column, offset| {
            const start: usize = @intCast(offset);
            try std.testing.expectEqualSlices(
                u32,
                std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(column)),
                words[start .. start + rows],
            );
        }
    }
}

test "metal: prepared sparse evaluation IFFT is deterministic across command submissions" {
    // Log 10 is the smallest domain whose 512 butterflies span more than one
    // 256-thread group, so it exercises cross-group visibility at every layer.
    try expectPreparedSparseIfftDeterministic(10, 16);
}

test "metal: prepared sparse evaluation IFFT log-24 stress gate" {
    const allocator = std.testing.allocator;
    const enabled = std.process.getEnvVarOwned(
        allocator,
        "STWO_ZIG_METAL_IFFT_LOG24_STRESS",
    ) catch return error.SkipZigTest;
    defer allocator.free(enabled);
    if (!std.mem.eql(u8, enabled, "1")) return error.SkipZigTest;
    try expectPreparedSparseIfftDeterministic(24, 2);
}

fn expectPreparedCompositionFinalizeChainMatchesCpu(logs: []const u32, repetitions: usize) !void {
    const allocator = std.testing.allocator;
    if (logs.len < 3 or repetitions == 0) return error.InvalidTestFixture;
    for (logs[1..], logs[0 .. logs.len - 1]) |current, previous| {
        if (current <= previous) return error.InvalidTestFixture;
    }

    var runtime = try metal.Runtime.init();
    defer runtime.deinit();
    const max_log = logs[logs.len - 1];
    const max_rows = @as(usize, 1) << @intCast(max_log);
    const domain = canonic.CanonicCoset.new(max_log).circleDomain();
    var tree = try twiddles.precomputeM31(allocator, domain.half_coset);
    defer twiddles.deinitM31(allocator, &tree);
    const const_tree = twiddles.TwiddleTree([]const M31).init(
        tree.root_coset,
        tree.twiddles,
        tree.itwiddles,
    );

    const accumulator_offsets = try allocator.alloc(u32, logs.len);
    defer allocator.free(accumulator_offsets);
    var accumulator_words: usize = 0;
    for (logs, accumulator_offsets) |log_size, *offset| {
        offset.* = @intCast(accumulator_words);
        accumulator_words += 4 * (@as(usize, 1) << @intCast(log_size));
    }
    const initial = try allocator.alloc(u32, accumulator_words);
    defer allocator.free(initial);
    for (logs, accumulator_offsets, 0..) |log_size, offset, level| {
        const rows = @as(usize, 1) << @intCast(log_size);
        for (0..4) |coordinate| for (0..rows) |row| {
            initial[@as(usize, offset) + coordinate * rows + row] = @intCast(
                (level * 0x20b31 + coordinate * 0x1031 + row * 37 + row * row * 3 + 11) % m31.Modulus,
            );
        };
    }

    var lifted: [4][]M31 = undefined;
    defer for (&lifted) |column| allocator.free(column);
    const first_rows = @as(usize, 1) << @intCast(logs[0]);
    for (&lifted, 0..) |*column, coordinate| {
        column.* = try allocator.alloc(M31, first_rows);
        const start = @as(usize, accumulator_offsets[0]) + coordinate * first_rows;
        for (initial[start .. start + first_rows], column.*) |value, *destination|
            destination.* = M31.fromCanonical(value);
    }
    for (logs[1..], accumulator_offsets[1..]) |current_log, offset| {
        const previous_log: u32 = @intCast(std.math.log2_int(usize, lifted[0].len));
        const log_ratio = current_log - previous_log;
        const rows = @as(usize, 1) << @intCast(current_log);
        var next: [4][]M31 = undefined;
        var initialized: usize = 0;
        errdefer for (next[0..initialized]) |column| allocator.free(column);
        for (&next, 0..) |*column, coordinate| {
            column.* = try allocator.alloc(M31, rows);
            initialized += 1;
            const start = @as(usize, offset) + coordinate * rows;
            for (initial[start .. start + rows], column.*, 0..) |value, *destination, row| {
                const source = (row >> @intCast(log_ratio + 1) << 1) + (row & 1);
                destination.* = M31.fromCanonical(value).add(lifted[coordinate][source]);
            }
        }
        for (&lifted, &next) |*previous, column| {
            allocator.free(previous.*);
            previous.* = column;
        }
    }
    try circle_poly.interpolateBuffersWithTwiddles(&lifted, domain, const_tree);

    const twiddle_offset: u32 = @intCast(accumulator_words);
    const output_start = accumulator_words + tree.itwiddles.len;
    var output_offsets: [8]u32 = undefined;
    for (&output_offsets, 0..) |*offset, index| offset.* = @intCast(output_start + index * max_rows / 2);
    var arena = try runtime.allocateResidentBuffer((output_start + 4 * max_rows) * @sizeOf(u32));
    defer arena.deinit();
    const words: [*]u32 = @ptrCast(@alignCast(arena.contents));
    @memcpy(
        words[twiddle_offset .. twiddle_offset + tree.itwiddles.len],
        std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(tree.itwiddles)),
    );
    const scale = try M31.fromCanonical(@intCast(max_rows)).inv();
    var plan = try runtime.prepareCompositionFinalize(
        accumulator_offsets,
        logs,
        twiddle_offset,
        output_offsets,
        scale.v,
    );
    defer plan.deinit();

    for (0..repetitions) |_| {
        @memcpy(words[0..initial.len], initial);
        _ = try runtime.compositionFinalizePrepared(arena, plan);
        for (0..8) |output| {
            const coordinate = output & 3;
            const half = output >> 2;
            const expected = lifted[coordinate][half * max_rows / 2 ..][0 .. max_rows / 2];
            const start: usize = output_offsets[output];
            try std.testing.expectEqualSlices(
                u32,
                std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(expected)),
                words[start .. start + max_rows / 2],
            );
        }
    }
}

test "metal: multi-level composition lift and IFFT is deterministic" {
    try expectPreparedCompositionFinalizeChainMatchesCpu(&.{ 3, 5, 7, 10 }, 16);
}

test "metal: multi-level composition finalize log-24 stress gate" {
    const allocator = std.testing.allocator;
    const enabled = std.process.getEnvVarOwned(
        allocator,
        "STWO_ZIG_METAL_IFFT_LOG24_STRESS",
    ) catch return error.SkipZigTest;
    defer allocator.free(enabled);
    if (!std.mem.eql(u8, enabled, "1")) return error.SkipZigTest;
    try expectPreparedCompositionFinalizeChainMatchesCpu(&.{ 5, 10, 17, 24 }, 2);
}

fn expectPreparedCompositionFinalizeMatchesCpu(previous_log: u32, current_log: u32) !void {
    const allocator = std.testing.allocator;
    var runtime = try metal.Runtime.init();
    defer runtime.deinit();
    const previous_rows = @as(usize, 1) << @intCast(previous_log);
    const current_rows = @as(usize, 1) << @intCast(current_log);
    const domain = canonic.CanonicCoset.new(current_log).circleDomain();
    var tree = try twiddles.precomputeM31(allocator, domain.half_coset);
    defer twiddles.deinitM31(allocator, &tree);
    const const_tree = twiddles.TwiddleTree([]const M31).init(tree.root_coset, tree.twiddles, tree.itwiddles);
    var expected: [4][]M31 = undefined;
    defer for (&expected) |column| allocator.free(column);
    const previous_offset: u32 = 0;
    const current_offset: u32 = @intCast(4 * previous_rows);
    const twiddle_offset: u32 = current_offset + @as(u32, @intCast(4 * current_rows));
    const output_start: u32 = twiddle_offset + @as(u32, @intCast(tree.itwiddles.len));
    var output_offsets: [8]u32 = undefined;
    for (&output_offsets, 0..) |*offset, index| offset.* = output_start + @as(u32, @intCast(index * current_rows / 2));
    var arena = try runtime.allocateResidentBuffer((@as(usize, output_start) + 8 * current_rows / 2) * 4);
    defer arena.deinit();
    const words: [*]u32 = @ptrCast(@alignCast(arena.contents));
    for (0..4) |coordinate| {
        expected[coordinate] = try allocator.alloc(M31, current_rows);
        for (0..previous_rows) |row| words[@as(usize, previous_offset) + coordinate * previous_rows + row] = @intCast((coordinate * 1237 + row * 17 + 3) % m31.Modulus);
        for (0..current_rows) |row| {
            const value: u32 = @intCast((coordinate * 3571 + row * 29 + 11) % m31.Modulus);
            words[@as(usize, current_offset) + coordinate * current_rows + row] = value;
            const lifted = (row >> @intCast(current_log - previous_log + 1) << 1) + (row & 1);
            expected[coordinate][row] = M31.fromCanonical(value).add(M31.fromCanonical(words[@as(usize, previous_offset) + coordinate * previous_rows + lifted]));
        }
    }
    try circle_poly.interpolateBuffersWithTwiddles(&expected, domain, const_tree);
    @memcpy(words[@as(usize, twiddle_offset) .. @as(usize, twiddle_offset) + tree.itwiddles.len], std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(tree.itwiddles)));
    const scale = try M31.fromCanonical(@intCast(current_rows)).inv();
    var plan = try runtime.prepareCompositionFinalize(
        &.{ previous_offset, current_offset },
        &.{ previous_log, current_log },
        twiddle_offset,
        output_offsets,
        scale.v,
    );
    defer plan.deinit();
    const gpu_ms = try runtime.compositionFinalizePrepared(arena, plan);
    try std.testing.expect(gpu_ms > 0);
    for (0..8) |output| {
        const coordinate = output & 3;
        const half = output >> 2;
        const source = expected[coordinate][half * current_rows / 2 ..][0 .. current_rows / 2];
        const output_offset: usize = output_offsets[output];
        const actual_bytes = std.mem.sliceAsBytes(words[output_offset .. output_offset + current_rows / 2]);
        const actual: []align(@alignOf(M31)) const u8 = @alignCast(actual_bytes);
        try std.testing.expectEqualSlices(M31, source, std.mem.bytesAsSlice(M31, actual));
    }
}

test "metal: prepared composition lift interpolate and split matches CPU" {
    try expectPreparedCompositionFinalizeMatchesCpu(8, 10);
}

test "metal: prepared composition finalize matches CPU above SIMD transpose threshold" {
    try expectPreparedCompositionFinalizeMatchesCpu(13, 17);
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

    const MetalTree = @import("backends/metal/merkle_tree.zig").MetalMerkleTree(Hasher);
    var compatible_tree = try MetalTree.commit(&runtime, allocator, &cpu_columns);
    defer compatible_tree.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &cpu_tree.root(), &compatible_tree.root());

    const query_positions = [_]usize{ 3, 255, 510 };
    var cpu_decommitment = try cpu_tree.decommit(allocator, &query_positions, &cpu_columns);
    defer cpu_decommitment.deinit(allocator);
    var metal_decommitment = try compatible_tree.decommit(allocator, &query_positions, &cpu_columns);
    defer metal_decommitment.deinit(allocator);

    for (cpu_decommitment.queried_values, metal_decommitment.queried_values) |cpu_values, metal_values| {
        try std.testing.expectEqualSlices(M31, cpu_values, metal_values);
    }
    const cpu_witness = cpu_decommitment.decommitment.decommitment.hash_witness;
    const metal_witness = metal_decommitment.decommitment.decommitment.hash_witness;
    try std.testing.expectEqual(cpu_witness.len, metal_witness.len);
    for (cpu_witness, metal_witness) |cpu_hash, metal_hash| {
        try std.testing.expectEqualSlices(u8, &cpu_hash, &metal_hash);
    }

    const cpu_layers = cpu_decommitment.decommitment.aux.all_node_values;
    const metal_layers = metal_decommitment.decommitment.aux.all_node_values;
    try std.testing.expectEqual(cpu_layers.len, metal_layers.len);
    for (cpu_layers, metal_layers) |cpu_layer, metal_layer| {
        try std.testing.expectEqual(cpu_layer.len, metal_layer.len);
        for (cpu_layer, metal_layer) |cpu_node, metal_node| {
            try std.testing.expectEqual(cpu_node.index, metal_node.index);
            try std.testing.expectEqualSlices(u8, &cpu_node.hash, &metal_node.hash);
        }
    }
}

test "metal: incremental leaf absorption matches monolithic lifted leaves" {
    var runtime = try metal.Runtime.init();
    defer runtime.deinit();
    const lifting_log: u32 = 6;
    const rows: u32 = 1 << lifting_log;
    var arena = try runtime.allocateResidentBuffer(32768);
    defer arena.deinit();
    const words: [*]u32 = @ptrCast(@alignCast(arena.contents));
    var offsets: [20]u32 = undefined;
    var logs: [20]u32 = undefined;
    var cursor: u32 = 0;
    for (&offsets, &logs, 0..) |*offset, *log_size, column| {
        log_size.* = if (column < 16) 5 else 6;
        offset.* = cursor;
        const length = @as(u32, 1) << @intCast(log_size.*);
        for (words[cursor .. cursor + length], 0..) |*value, row| value.* = @intCast((column * 313 + row * 17 + 9) % m31.Modulus);
        cursor += length;
    }
    const monolithic: u32 = 4096;
    const incremental: u32 = monolithic + rows * 8;
    var leaves = try runtime.prepareMerkleLeaves(&offsets, &logs, lifting_log, monolithic, Hasher.leafSeed());
    defer leaves.deinit();
    _ = try runtime.merkleLeavesPrepared(arena, leaves);
    _ = try runtime.leafAbsorb(arena, offsets[0..16], logs[0..16], incremental, lifting_log, 0, false, 0, Hasher.leafSeed());
    _ = try runtime.leafAbsorb(arena, offsets[16..20], logs[16..20], incremental, lifting_log, 16, true, 0, Hasher.leafSeed());
    try std.testing.expectEqualSlices(u32, words[monolithic .. monolithic + rows * 8], words[incremental .. incremental + rows * 8]);
}

test "metal: compact leaf absorption expands mixed logs and preserves the Merkle root" {
    var runtime = try metal.Runtime.init();
    defer runtime.deinit();
    const lifting_log: u32 = 8;
    const rows: u32 = 1 << lifting_log;
    var arena = try runtime.allocateResidentBuffer(128 * 1024);
    defer arena.deinit();
    const words: [*]u32 = @ptrCast(@alignCast(arena.contents));
    var offsets: [24]u32 = undefined;
    var logs: [24]u32 = undefined;
    var cursor: u32 = 0;
    for (&offsets, &logs, 0..) |*offset, *log_size, column| {
        log_size.* = if (column < 8)
            (if (column % 2 == 0) 4 else 5)
        else if (column < 16)
            (if (column % 2 == 0) 5 else 7)
        else
            (if (column % 2 == 0) 7 else 8);
        offset.* = cursor;
        const length = @as(u32, 1) << @intCast(log_size.*);
        for (words[cursor .. cursor + length], 0..) |*value, row|
            value.* = @intCast((column * 313 + row * 17 + 9) % m31.Modulus);
        cursor += length;
    }
    const full_state: u32 = 8192;
    const compact_state: u32 = full_state + rows * 8;
    const snapshot: u32 = compact_state + rows * 8;
    _ = try runtime.leafAbsorb(arena, offsets[0..8], logs[0..8], full_state, lifting_log, 0, false, 0, Hasher.leafSeed());
    _ = try runtime.leafAbsorb(arena, offsets[8..16], logs[8..16], full_state, lifting_log, 8, false, 0, Hasher.leafSeed());
    _ = try runtime.leafAbsorb(arena, offsets[16..24], logs[16..24], full_state, lifting_log, 16, true, 0, Hasher.leafSeed());

    _ = try runtime.leafAbsorbCompact(arena, offsets[0..8], logs[0..8], compact_state, 5, compact_state, 5, 0, false, 0, Hasher.leafSeed());
    {
        var copy = try runtime.prepareArenaCopies(&.{.{
            .source_word_offset = compact_state,
            .destination_word_offset = snapshot,
            .word_count = (1 << 5) * 8,
        }});
        defer copy.deinit();
        _ = try runtime.arenaCopyPrepared(arena, copy);
    }
    _ = try runtime.leafAbsorbCompact(arena, offsets[8..16], logs[8..16], snapshot, 5, compact_state, 7, 8, false, 0, Hasher.leafSeed());
    {
        var copy = try runtime.prepareArenaCopies(&.{.{
            .source_word_offset = compact_state,
            .destination_word_offset = snapshot,
            .word_count = (1 << 7) * 8,
        }});
        defer copy.deinit();
        _ = try runtime.arenaCopyPrepared(arena, copy);
    }
    _ = try runtime.leafAbsorbCompact(arena, offsets[16..24], logs[16..24], snapshot, 7, compact_state, lifting_log, 16, true, 0, Hasher.leafSeed());
    try std.testing.expectEqualSlices(u32, words[full_state .. full_state + rows * 8], words[compact_state .. compact_state + rows * 8]);

    var full_children: [8]u32 = undefined;
    var full_destinations: [8]u32 = undefined;
    var compact_children: [8]u32 = undefined;
    var compact_destinations: [8]u32 = undefined;
    var parent_counts: [8]u32 = undefined;
    var full_parent_cursor: u32 = 16384;
    var compact_parent_cursor: u32 = 20480;
    var parent_count = rows / 2;
    for (0..8) |level| {
        full_children[level] = if (level == 0) full_state else full_destinations[level - 1];
        compact_children[level] = if (level == 0) compact_state else compact_destinations[level - 1];
        full_destinations[level] = full_parent_cursor;
        compact_destinations[level] = compact_parent_cursor;
        parent_counts[level] = parent_count;
        full_parent_cursor += parent_count * 8;
        compact_parent_cursor += parent_count * 8;
        parent_count /= 2;
    }
    var full_chain = try runtime.prepareMerkleParentChain(&full_children, &full_destinations, &parent_counts, Hasher.nodeSeed());
    defer full_chain.deinit();
    var compact_chain = try runtime.prepareMerkleParentChain(&compact_children, &compact_destinations, &parent_counts, Hasher.nodeSeed());
    defer compact_chain.deinit();
    _ = try runtime.merkleParentChainPrepared(arena, full_chain);
    _ = try runtime.merkleParentChainPrepared(arena, compact_chain);
    try std.testing.expectEqualSlices(u32, words[full_destinations[7] .. full_destinations[7] + 8], words[compact_destinations[7] .. compact_destinations[7] + 8]);
}

test "metal: compact leaf absorption expands a partial final group to the full domain" {
    var runtime = try metal.Runtime.init();
    defer runtime.deinit();
    const lifting_log: u32 = 8;
    const rows: u32 = 1 << lifting_log;
    var arena = try runtime.allocateResidentBuffer(64 * 1024);
    defer arena.deinit();
    const words: [*]u32 = @ptrCast(@alignCast(arena.contents));
    var offsets: [16]u32 = undefined;
    var logs: [16]u32 = undefined;
    var cursor: u32 = 0;
    for (&offsets, &logs, 0..) |*offset, *log_size, column| {
        log_size.* = if (column < 8)
            (if (column % 2 == 0) 4 else 5)
        else
            (if (column % 2 == 0) 6 else 7);
        offset.* = cursor;
        const length = @as(u32, 1) << @intCast(log_size.*);
        for (words[cursor .. cursor + length], 0..) |*value, row|
            value.* = @intCast((column * 199 + row * 29 + 3) % m31.Modulus);
        cursor += length;
    }
    const full_state: u32 = 4096;
    const compact_state: u32 = full_state + rows * 8;
    const snapshot: u32 = compact_state + rows * 8;
    _ = try runtime.leafAbsorb(arena, offsets[0..8], logs[0..8], full_state, lifting_log, 0, false, 0, Hasher.leafSeed());
    _ = try runtime.leafAbsorb(arena, offsets[8..16], logs[8..16], full_state, lifting_log, 8, true, 0, Hasher.leafSeed());
    _ = try runtime.leafAbsorbCompact(arena, offsets[0..8], logs[0..8], compact_state, 5, compact_state, 5, 0, false, 0, Hasher.leafSeed());
    var copy = try runtime.prepareArenaCopies(&.{.{
        .source_word_offset = compact_state,
        .destination_word_offset = snapshot,
        .word_count = (1 << 5) * 8,
    }});
    defer copy.deinit();
    _ = try runtime.arenaCopyPrepared(arena, copy);
    _ = try runtime.leafAbsorbCompact(arena, offsets[8..16], logs[8..16], snapshot, 5, compact_state, lifting_log, 8, true, 0, Hasher.leafSeed());
    try std.testing.expectEqualSlices(u32, words[full_state .. full_state + rows * 8], words[compact_state .. compact_state + rows * 8]);
}

test "metal: batched decommit FRI round matches three legacy submissions" {
    var runtime = try metal.Runtime.init();
    defer runtime.deinit();
    const arena_words: usize = 65536;
    var legacy = try runtime.allocateResidentBuffer(arena_words * @sizeOf(u32));
    defer legacy.deinit();
    var batched = try runtime.allocateResidentBuffer(arena_words * @sizeOf(u32));
    defer batched.deinit();

    const unique_base: u64 = 64;
    const tree_queries_base: u64 = 256;
    const expanded_base: u64 = 512;
    const walk_base: u64 = 1200;
    const count_base: u64 = 2000;
    const coordinate_bases: u64 = 2100;
    const values_base: u64 = 3000;
    const walk_scratch_base: u64 = 5500;
    const retained_offsets: u64 = 6200;
    const assembly_base: u64 = 8000;
    const assembly_capacity: u32 = 30000;
    const leaf_log: u32 = 4;
    const max_positions: u32 = 560;

    const Fixture = struct {
        fn populate(buffer: metal.ResidentBuffer) void {
            const words: [*]u32 = @ptrCast(@alignCast(buffer.contents));
            @memset(words[0..arena_words], 0);
            const queries = [_]u32{ 0, 1, 5, 6, 17, 31 };
            @memcpy(words[unique_base .. unique_base + queries.len], &queries);
            words[count_base] = queries.len;

            const coordinate_sources = [_]u32{ 2200, 2300, 2400, 2500 };
            for (coordinate_sources, 0..) |source, coordinate| {
                words[coordinate_bases + 2 * coordinate] = source;
                words[coordinate_bases + 2 * coordinate + 1] = 0;
                for (0..64) |row| words[source + row] = @intCast(1000 * coordinate + 17 * row + 3);
            }

            var retained_cursor: u32 = 6400;
            for (0..leaf_log + 1) |level| {
                words[retained_offsets + 2 * level] = retained_cursor;
                words[retained_offsets + 2 * level + 1] = 0;
                const hashes = @as(u32, 1) << @intCast(level);
                for (0..hashes * 8) |word| words[retained_cursor + word] =
                    @intCast(0x10000 + level * 0x1000 + word);
                retained_cursor += hashes * 8;
            }

            words[assembly_base] = 0x4457_5453;
            words[assembly_base + 1] = 1;
            words[assembly_base + 2] = 1;
            words[assembly_base + 7] = 24;
        }
    };
    Fixture.populate(legacy);
    Fixture.populate(batched);

    const legacy_gpu_ms =
        try runtime.decommitPrepareFriQueries(
            legacy,
            unique_base,
            count_base,
            70,
            0,
            2,
            2,
            tree_queries_base,
            count_base + 1,
            expanded_base,
            count_base + 3,
            walk_base,
            count_base + 2,
        ) +
        try runtime.decommitGatherFriValues(
            legacy,
            coordinate_bases,
            expanded_base,
            count_base + 3,
            max_positions,
            values_base,
        ) +
        try runtime.decommitAssembleFri(
            legacy,
            0,
            leaf_log,
            tree_queries_base,
            count_base + 1,
            expanded_base,
            count_base + 3,
            values_base,
            walk_base,
            walk_scratch_base,
            count_base + 2,
            retained_offsets,
            assembly_base,
            assembly_capacity,
        );

    const batched_gpu_ms = try runtime.decommitFriRound(batched, .{
        .unique_base = unique_base,
        .unique_count_base = count_base,
        .tree_queries_base = tree_queries_base,
        .tree_count_base = count_base + 1,
        .expanded_base = expanded_base,
        .expanded_count_base = count_base + 3,
        .walk_base = walk_base,
        .walk_count_base = count_base + 2,
        .coordinate_bases = coordinate_bases,
        .values_base = values_base,
        .walk_scratch_base = walk_scratch_base,
        .retained_offsets = retained_offsets,
        .assembly_base = assembly_base,
        .max_queries = 70,
        .cumulative_fold = 0,
        .fold_step = 2,
        .packed_log = 2,
        .max_positions = max_positions,
        .tree_index = 0,
        .leaf_log = leaf_log,
        .assembly_capacity = assembly_capacity,
    });
    try std.testing.expect(legacy_gpu_ms > 0);
    try std.testing.expect(batched_gpu_ms > 0);
    const legacy_words: [*]const u32 = @ptrCast(@alignCast(legacy.contents));
    const batched_words: [*]const u32 = @ptrCast(@alignCast(batched.contents));
    try std.testing.expectEqualSlices(u32, legacy_words[0..arena_words], batched_words[0..arena_words]);
}

test "metal: sparse LDE reads the canonical suffix of a larger twiddle tower" {
    const allocator = std.testing.allocator;
    var runtime = try metal.Runtime.init();
    defer runtime.deinit();
    const base_log: u32 = 9;
    const eval_log: u32 = 10;
    const tower_log: u32 = 13;
    var base_tree = try twiddles.precomputeM31(allocator, canonic.CanonicCoset.new(base_log).circleDomain().half_coset);
    defer twiddles.deinitM31(allocator, &base_tree);
    var eval_tree = try twiddles.precomputeM31(allocator, canonic.CanonicCoset.new(eval_log).circleDomain().half_coset);
    defer twiddles.deinitM31(allocator, &eval_tree);
    var tower = try twiddles.precomputeM31(allocator, canonic.CanonicCoset.new(tower_log).circleDomain().half_coset);
    defer twiddles.deinitM31(allocator, &tower);
    const coefficients = try allocator.alloc(M31, @as(usize, 1) << base_log);
    defer allocator.free(coefficients);
    const expected = try allocator.alloc(M31, @as(usize, 1) << eval_log);
    defer allocator.free(expected);
    for (coefficients, 0..) |*value, row| value.* = M31.fromCanonical(@intCast((row * 7919 + 17) % m31.Modulus));
    const base_const = twiddles.TwiddleTree([]const M31).init(base_tree.root_coset, base_tree.twiddles, base_tree.itwiddles);
    const eval_const = twiddles.TwiddleTree([]const M31).init(eval_tree.root_coset, eval_tree.twiddles, eval_tree.itwiddles);
    var coefficient_columns = [_][]M31{coefficients};
    try circle_poly.interpolateBuffersWithTwiddles(&coefficient_columns, canonic.CanonicCoset.new(base_log).circleDomain(), base_const);
    @memcpy(expected[0..coefficients.len], coefficients);
    @memset(expected[coefficients.len..], M31.zero());
    var expected_columns = [_][]M31{expected};
    try circle_poly.evaluateBuffersWithTwiddles(&expected_columns, canonic.CanonicCoset.new(eval_log).circleDomain(), eval_const);
    const source: u32 = 0;
    const destination: u32 = 2048;
    const tower_offset: u32 = 4096;
    var arena = try runtime.allocateResidentBuffer(65536);
    defer arena.deinit();
    const words: [*]u32 = @ptrCast(@alignCast(arena.contents));
    @memcpy(words[source .. source + coefficients.len], std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(coefficients)));
    @memcpy(words[tower_offset .. tower_offset + tower.twiddles.len], std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(tower.twiddles)));
    const suffix = tower_offset + @as(u32, @intCast(tower.twiddles.len - eval_tree.twiddles.len));
    var lde = try runtime.prepareCompositionLde(&.{source}, &.{base_log}, &.{destination}, eval_log, suffix);
    defer lde.deinit();
    _ = try runtime.compositionLdePrepared(arena, lde);
    try std.testing.expectEqualSlices(u32, std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(expected)), words[destination .. destination + expected.len]);
}

test "metal: radix-4 sparse LDE matches deterministic CPU domains" {
    const allocator = std.testing.allocator;
    var runtime = try metal.Runtime.init();
    defer runtime.deinit();
    var prng = std.Random.DefaultPrng.init(0x5241_4449_5834_4c44);
    const random = prng.random();

    for ([_][2]u32{ .{ 10, 13 }, .{ 11, 14 } }) |logs| {
        const base_log = logs[0];
        const eval_log = logs[1];
        const base_len = @as(usize, 1) << @intCast(base_log);
        const eval_len = @as(usize, 1) << @intCast(eval_log);
        var base_tree = try twiddles.precomputeM31(
            allocator,
            canonic.CanonicCoset.new(base_log).circleDomain().half_coset,
        );
        defer twiddles.deinitM31(allocator, &base_tree);
        var eval_tree = try twiddles.precomputeM31(
            allocator,
            canonic.CanonicCoset.new(eval_log).circleDomain().half_coset,
        );
        defer twiddles.deinitM31(allocator, &eval_tree);
        const coefficients = try allocator.alloc(m31.M31, base_len);
        defer allocator.free(coefficients);
        for (coefficients) |*value|
            value.* = m31.M31.fromCanonical(random.int(u32) % m31.Modulus);
        var coefficient_columns = [_][]m31.M31{coefficients};
        const base_const = twiddles.TwiddleTree([]const m31.M31).init(
            base_tree.root_coset,
            base_tree.twiddles,
            base_tree.itwiddles,
        );
        try circle_poly.interpolateBuffersWithTwiddles(
            &coefficient_columns,
            canonic.CanonicCoset.new(base_log).circleDomain(),
            base_const,
        );

        const expected = try allocator.alloc(m31.M31, eval_len);
        defer allocator.free(expected);
        @memcpy(expected[0..base_len], coefficients);
        @memset(expected[base_len..], m31.M31.zero());
        var expected_columns = [_][]m31.M31{expected};
        const eval_const = twiddles.TwiddleTree([]const m31.M31).init(
            eval_tree.root_coset,
            eval_tree.twiddles,
            eval_tree.itwiddles,
        );
        try circle_poly.evaluateBuffersWithTwiddles(
            &expected_columns,
            canonic.CanonicCoset.new(eval_log).circleDomain(),
            eval_const,
        );

        const source: u32 = 0;
        const twiddle_offset: u32 = @intCast(base_len);
        const destination_word = base_len + eval_tree.twiddles.len;
        const destination: u32 = @intCast(destination_word);
        var arena = try runtime.allocateResidentBuffer(
            (destination_word + eval_len) * @sizeOf(u32),
        );
        defer arena.deinit();
        const words: [*]u32 = @ptrCast(@alignCast(arena.contents));
        @memcpy(words[source .. source + base_len], std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(coefficients)));
        @memcpy(
            words[twiddle_offset .. twiddle_offset + eval_tree.twiddles.len],
            std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(eval_tree.twiddles)),
        );
        var lde = try runtime.prepareCompositionLdeConfigured(
            &.{source},
            &.{base_log},
            &.{destination},
            eval_log,
            twiddle_offset,
            .{ .radix4 = true },
        );
        defer lde.deinit();
        _ = try runtime.compositionLdePrepared(arena, lde);
        try std.testing.expectEqualSlices(
            u32,
            std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(expected)),
            words[destination_word .. destination_word + eval_len],
        );
    }
}

test "metal: sparse LDE matches Rust seq_4 reference" {
    const allocator = std.testing.allocator;
    var runtime = try metal.Runtime.init();
    defer runtime.deinit();
    const base_log: u32 = 4;
    const eval_log: u32 = 5;
    const coefficients_u32 = [_]u32{ 1073741831, 0, 1943228410, 0, 380597802, 0, 142783525, 0, 2147221503, 0, 69204140, 0, 1551296076, 0, 1518526074, 4 };
    const expected = [_]u32{ 863170483, 863203251, 1007143128, 1007175896, 465131302, 465164070, 1722190238, 1722223006, 1856766077, 1856798845, 946856874, 946889642, 55834652, 55867420, 1672710822, 1672743590, 1641251221, 1641218453, 600224473, 600191705, 58867736, 58834968, 1334657298, 1334624530, 200854279, 200821511, 1606816039, 1606783271, 493042739, 493009971, 506868288, 506835520 };
    var eval_tree = try twiddles.precomputeM31(allocator, canonic.CanonicCoset.new(eval_log).circleDomain().half_coset);
    defer twiddles.deinitM31(allocator, &eval_tree);
    var arena = try runtime.allocateResidentBuffer(4096);
    defer arena.deinit();
    const words: [*]u32 = @ptrCast(@alignCast(arena.contents));
    @memcpy(words[0..coefficients_u32.len], &coefficients_u32);
    @memcpy(words[128 .. 128 + eval_tree.twiddles.len], std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(eval_tree.twiddles)));
    var lde = try runtime.prepareCompositionLde(&.{0}, &.{base_log}, &.{256}, eval_log, 128);
    defer lde.deinit();
    _ = try runtime.compositionLdePrepared(arena, lde);
    try std.testing.expectEqualSlices(u32, &expected, words[256 .. 256 + expected.len]);
}

test "metal: execution tables split compact little-endian values into 9-bit columns" {
    var runtime = try metal.Runtime.init();
    defer runtime.deinit();
    const rows: u32 = 16;
    const source_offset: u32 = 0;
    var offsets: [28]u32 = undefined;
    for (&offsets, 0..) |*offset, limb| offset.* = 64 + @as(u32, @intCast(limb)) * rows;
    var arena = try runtime.allocateResidentBuffer((64 + 28 * rows) * 4);
    defer arena.deinit();
    const words: [*]u32 = @ptrCast(@alignCast(arena.contents));
    const values = [_][8]u32{
        .{ 0xffffffff, 0x01234567, 0x89abcdef, 0x76543210, 1, 2, 3, 4 },
        .{ 511, 0, 0, 0, 0, 0, 0, 0 },
    };
    @memcpy(words[source_offset .. source_offset + values.len * 8], std.mem.bytesAsSlice(u32, std.mem.asBytes(&values)));
    _ = try runtime.executionTableSplit(arena, source_offset, values.len, rows, 8, &offsets);
    for (0..rows) |row| {
        var bit: usize = 0;
        for (offsets) |offset| {
            var expected: u32 = 0;
            if (row < values.len) {
                const word = bit / 32;
                const shift: u5 = @intCast(bit % 32);
                expected = values[row][word] >> shift;
                if (shift > 23 and word + 1 < 8) expected |= values[row][word + 1] << @intCast(32 - @as(u6, shift));
                expected &= 0x1ff;
            }
            try std.testing.expectEqual(expected, words[offset + row]);
            bit += 9;
        }
    }
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
