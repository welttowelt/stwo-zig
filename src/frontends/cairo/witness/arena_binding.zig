const std = @import("std");
const arena_plan = @import("../../../backends/metal/arena_plan.zig");
const metal_runtime = @import("../../../backends/metal/runtime.zig");
const protocol_recipes = @import("../../../backends/metal/protocol_recipes.zig");
const composition_bundle_mod = @import("composition_bundle.zig");
const fixed_table_bundle_mod = @import("fixed_table_bundle.zig");
const witness_bundle_mod = @import("bundle.zig");
const witness_codegen = @import("../../../backends/metal/witness_codegen.zig");
const cairo_adapter = @import("../adapter/mod.zig");
const cairo_opcodes = @import("../adapter/opcodes.zig");
const M31 = @import("../../../core/fields/m31.zig").M31;
const twiddles_mod = @import("../../../prover/poly/twiddles.zig");
const circle_mod = @import("../../../core/circle.zig");

pub const Error = error{
    InvalidSchedule,
    DuplicateBinding,
    MissingBinding,
    InvalidCardinality,
    InvalidCompositionCount,
    InvalidQuotientCount,
    InvalidFriChallengeCount,
    InvalidFriRetainedCount,
    InvalidFriLayerCount,
    InvalidExtParamCount,
    InvalidClaimedSumCount,
    InvalidPreprocessedCount,
    InvalidBindingSize,
};

pub const Sn2Counts = struct {
    pub const composition_coefficients = 8;
    pub const quotient_partials = 76;
    pub const fri_challenges = 8;
    pub const fri_retained_evaluations = 7;
    pub const fri_merkle_layers = 100;
};

pub const ProofCopy = struct {
    source: arena_plan.Binding,
    destination_word_offset: u32,
    word_count: u32,
};

pub const CommitmentTelemetry = struct {
    gpu_ms: f64,
    root: arena_plan.Binding,
};

pub const OrdinalBinding = struct {
    ordinal: u32,
    binding: arena_plan.Binding,
};

pub const NamedBinding = struct {
    component: []const u8,
    ordinal: u32,
    binding: arena_plan.Binding,
};

/// Exact logical-to-physical binding set consumed by the prepared composition,
/// quotient, FRI and compact proof-assembly stages. This is deliberately built
/// from the captured schedule and the colored plan; no allocation id or offset
/// is inferred from insertion order.
pub const PreparedProofBindings = struct {
    allocator: std.mem.Allocator,
    composition_coefficients: []arena_plan.Binding,
    composition_descriptors: arena_plan.Binding,
    composition_lde_tile: arena_plan.Binding,
    composition_accumulators: arena_plan.Binding,
    composition_random_powers: arena_plan.Binding,
    preprocessed_coefficients: []arena_plan.Binding,
    base_coefficients: []arena_plan.Binding,
    interaction_coefficients: []arena_plan.Binding,
    named_base_coefficients: []NamedBinding,
    named_interaction_coefficients: []NamedBinding,
    composition_ext_params: []arena_plan.Binding,
    relation_claimed_sums: []arena_plan.Binding,
    relation_alpha_powers: arena_plan.Binding,
    relation_z: arena_plan.Binding,
    quotient_tile: arena_plan.Binding,
    quotient_partials: []arena_plan.Binding,
    quotient_sample_points: arena_plan.Binding,
    quotient_first_linear_terms: arena_plan.Binding,
    quotient_subdomain_values: arena_plan.Binding,
    quotient_denominator_scratch: arena_plan.Binding,
    quotient_inverse_twiddles: arena_plan.Binding,
    forward_twiddles: arena_plan.Binding,
    inverse_twiddles: arena_plan.Binding,
    fri_ping: arena_plan.Binding,
    fri_pong: arena_plan.Binding,
    fri_challenges: []arena_plan.Binding,
    fri_retained_evaluations: []arena_plan.Binding,
    fri_merkle_layers: []arena_plan.Binding,
    fri_final_coefficients: arena_plan.Binding,
    fri_final_degree_error: arena_plan.Binding,
    transcript_state: arena_plan.Binding,
    transcript_inputs: []OrdinalBinding,
    transcript_outputs: []OrdinalBinding,
    decommit_raw_queries: arena_plan.Binding,
    decommit_unique_queries: arena_plan.Binding,
    decommit_mapped_queries: arena_plan.Binding,
    decommit_walk_queries: arena_plan.Binding,
    decommit_walk_scratch: arena_plan.Binding,
    decommit_expanded_positions: arena_plan.Binding,
    decommit_sparse_indices: arena_plan.Binding,
    decommit_sparse_hashes: arena_plan.Binding,
    decommit_counts: arena_plan.Binding,
    decommit_values: arena_plan.Binding,
    decommit_assembly: arena_plan.Binding,
    proof_bytes: arena_plan.Binding,
    proof_copies: []ProofCopy,
    assembly: []arena_plan.Binding,

    pub fn initSn2(
        allocator: std.mem.Allocator,
        schedule: []const std.json.Value,
        plan: arena_plan.Plan,
    ) !PreparedProofBindings {
        const composition_coefficients = try collect(allocator, schedule, plan, "CompositionCoefficients");
        errdefer allocator.free(composition_coefficients);
        const quotient_partials = try collect(allocator, schedule, plan, "QuotientPartialNumerator");
        errdefer allocator.free(quotient_partials);
        const fri_challenges = try collect(allocator, schedule, plan, "FriFoldingChallenge");
        errdefer allocator.free(fri_challenges);
        const fri_retained_evaluations = try collect(allocator, schedule, plan, "FriRetainedEvaluation");
        errdefer allocator.free(fri_retained_evaluations);
        const fri_merkle_layers = try collect(allocator, schedule, plan, "FriMerkleLayer");
        errdefer allocator.free(fri_merkle_layers);
        const assembly = try collectAssembly(allocator, schedule, plan);
        errdefer allocator.free(assembly);
        const proof_copies = try buildProofCopies(allocator, schedule, plan);
        errdefer allocator.free(proof_copies);
        const transcript_inputs = try collectOrdinals(allocator, schedule, plan, "TranscriptInput");
        errdefer allocator.free(transcript_inputs);
        const transcript_outputs = try collectOrdinals(allocator, schedule, plan, "TranscriptOutput");
        errdefer allocator.free(transcript_outputs);
        var decommit_raw_queries: ?arena_plan.Binding = null;
        for (transcript_outputs) |output| {
            if (output.ordinal == 5) decommit_raw_queries = output.binding;
        }
        const preprocessed_coefficients = try collectScheduleOrder(allocator, schedule, plan, "PreprocessedCoefficients");
        errdefer allocator.free(preprocessed_coefficients);
        const base_coefficients = try collectCommitmentOrder(allocator, schedule, plan, "BaseCoefficients");
        errdefer allocator.free(base_coefficients);
        const interaction_coefficients = try collectCommitmentOrder(allocator, schedule, plan, "InteractionCoefficients");
        errdefer allocator.free(interaction_coefficients);
        const named_base_coefficients = try collectNamed(allocator, schedule, plan, "BaseCoefficients");
        errdefer allocator.free(named_base_coefficients);
        const named_interaction_coefficients = try collectNamed(allocator, schedule, plan, "InteractionCoefficients");
        errdefer allocator.free(named_interaction_coefficients);
        const composition_ext_params = try collect(allocator, schedule, plan, "CompositionExtParams");
        errdefer allocator.free(composition_ext_params);
        const relation_claimed_sums = try collect(allocator, schedule, plan, "RelationClaimedSum");
        errdefer allocator.free(relation_claimed_sums);
        var result = PreparedProofBindings{
            .allocator = allocator,
            .composition_coefficients = composition_coefficients,
            .composition_descriptors = try one(schedule, plan, "CompositionDescriptors"),
            .composition_lde_tile = try one(schedule, plan, "CompositionLdeTile"),
            .composition_accumulators = try one(schedule, plan, "CompositionAccumulators"),
            .composition_random_powers = try one(schedule, plan, "CompositionRandomCoefficientPowers"),
            .preprocessed_coefficients = preprocessed_coefficients,
            .base_coefficients = base_coefficients,
            .interaction_coefficients = interaction_coefficients,
            .named_base_coefficients = named_base_coefficients,
            .named_interaction_coefficients = named_interaction_coefficients,
            .composition_ext_params = composition_ext_params,
            .relation_claimed_sums = relation_claimed_sums,
            .relation_alpha_powers = try one(schedule, plan, "RelationAlphaPowers"),
            .relation_z = try one(schedule, plan, "RelationZ"),
            .quotient_tile = try one(schedule, plan, "QuotientTile"),
            .quotient_partials = quotient_partials,
            .quotient_sample_points = try one(schedule, plan, "QuotientSamplePoints"),
            .quotient_first_linear_terms = try one(schedule, plan, "QuotientFirstLinearTerms"),
            .quotient_subdomain_values = try one(schedule, plan, "QuotientSubdomainValues"),
            .quotient_denominator_scratch = try one(schedule, plan, "QuotientDenominatorScratch"),
            .quotient_inverse_twiddles = try one(schedule, plan, "QuotientInverseTwiddles"),
            .forward_twiddles = try one(schedule, plan, "ForwardTwiddles"),
            .inverse_twiddles = try one(schedule, plan, "InverseTwiddles"),
            .fri_ping = try one(schedule, plan, "FriPing"),
            .fri_pong = try one(schedule, plan, "FriPong"),
            .fri_challenges = fri_challenges,
            .fri_retained_evaluations = fri_retained_evaluations,
            .fri_merkle_layers = fri_merkle_layers,
            .fri_final_coefficients = try one(schedule, plan, "FriFinalCoefficients"),
            .fri_final_degree_error = try one(schedule, plan, "FriFinalDegreeError"),
            .transcript_state = try one(schedule, plan, "TranscriptState"),
            .transcript_inputs = transcript_inputs,
            .transcript_outputs = transcript_outputs,
            .decommit_raw_queries = decommit_raw_queries orelse return Error.MissingBinding,
            .decommit_unique_queries = try one(schedule, plan, "DecommitUniqueQueries"),
            .decommit_mapped_queries = try one(schedule, plan, "DecommitMappedQueries"),
            .decommit_walk_queries = try one(schedule, plan, "DecommitWalkQueries"),
            .decommit_walk_scratch = try one(schedule, plan, "DecommitWalkScratch"),
            .decommit_expanded_positions = try one(schedule, plan, "DecommitExpandedPositions"),
            .decommit_sparse_indices = try one(schedule, plan, "DecommitSparseIndices"),
            .decommit_sparse_hashes = try one(schedule, plan, "DecommitSparseHashes"),
            .decommit_counts = try one(schedule, plan, "DecommitCounts"),
            .decommit_values = try one(schedule, plan, "DecommitValues"),
            .decommit_assembly = try one(schedule, plan, "DecommitAssembly"),
            .proof_bytes = try one(schedule, plan, "ProofBytes"),
            .proof_copies = proof_copies,
            .assembly = assembly,
        };
        try result.validateSn2();
        return result;
    }

    pub fn deinit(self: *PreparedProofBindings) void {
        self.allocator.free(self.composition_coefficients);
        self.allocator.free(self.quotient_partials);
        self.allocator.free(self.fri_challenges);
        self.allocator.free(self.fri_retained_evaluations);
        self.allocator.free(self.fri_merkle_layers);
        self.allocator.free(self.proof_copies);
        self.allocator.free(self.transcript_inputs);
        self.allocator.free(self.transcript_outputs);
        self.allocator.free(self.preprocessed_coefficients);
        self.allocator.free(self.base_coefficients);
        self.allocator.free(self.interaction_coefficients);
        self.allocator.free(self.named_base_coefficients);
        self.allocator.free(self.named_interaction_coefficients);
        self.allocator.free(self.composition_ext_params);
        self.allocator.free(self.relation_claimed_sums);
        self.allocator.free(self.assembly);
        self.* = undefined;
    }

    pub fn prepareProofAssembly(
        self: PreparedProofBindings,
        allocator: std.mem.Allocator,
        metal: *metal_runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
    ) !protocol_recipes.ProofAssemblyRecipe {
        const copies = try allocator.alloc(protocol_recipes.ProofCopy, self.proof_copies.len);
        defer allocator.free(copies);
        for (self.proof_copies, copies) |source, *destination| {
            destination.* = .{
                .source = source.source,
                .destination_word_offset = source.destination_word_offset,
                .word_count = source.word_count,
            };
        }
        return protocol_recipes.ProofAssemblyRecipe.init(
            allocator,
            metal,
            resident_arena,
            copies,
            self.proof_bytes,
        );
    }

    pub fn prepareQuotient(
        self: PreparedProofBindings,
        allocator: std.mem.Allocator,
        metal: *metal_runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
    ) !protocol_recipes.QuotientRecipe {
        return protocol_recipes.QuotientRecipe.init(
            allocator,
            metal,
            resident_arena,
            self.quotient_partials,
            self.quotient_sample_points,
            self.quotient_first_linear_terms,
            self.quotient_denominator_scratch,
            self.quotient_subdomain_values,
            self.quotient_tile,
            self.quotient_inverse_twiddles,
            self.forward_twiddles,
        );
    }

    pub fn prepareFri(
        self: PreparedProofBindings,
        metal: *metal_runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        leaf_seed: [8]u32,
        node_seed: [8]u32,
    ) !protocol_recipes.FriRecipe {
        return protocol_recipes.FriRecipe.init(
            metal,
            resident_arena,
            self.quotient_tile,
            self.fri_retained_evaluations,
            self.fri_challenges,
            self.inverse_twiddles,
            self.fri_ping,
            self.fri_final_coefficients,
            self.fri_final_degree_error,
            self.fri_merkle_layers,
            leaf_seed,
            node_seed,
        );
    }

    pub fn prepareTranscript(
        self: PreparedProofBindings,
        metal: *metal_runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
    ) !protocol_recipes.TranscriptRecipe {
        const inputs = try self.allocator.alloc(protocol_recipes.TranscriptBinding, self.transcript_inputs.len);
        defer self.allocator.free(inputs);
        for (self.transcript_inputs, inputs) |source, *destination| destination.* = .{ .ordinal = source.ordinal, .binding = source.binding };
        const outputs = try self.allocator.alloc(protocol_recipes.TranscriptBinding, self.transcript_outputs.len);
        defer self.allocator.free(outputs);
        for (self.transcript_outputs, outputs) |source, *destination| destination.* = .{ .ordinal = source.ordinal, .binding = source.binding };
        return protocol_recipes.TranscriptRecipe.init(
            self.allocator,
            metal,
            resident_arena,
            self.transcript_state,
            inputs,
            outputs,
        );
    }

    pub fn prepareDecommitQueries(
        self: PreparedProofBindings,
        metal: *metal_runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
    ) !protocol_recipes.DecommitQueryRecipe {
        return protocol_recipes.DecommitQueryRecipe.init(
            metal,
            resident_arena,
            self.decommit_raw_queries,
            self.decommit_unique_queries,
            self.decommit_mapped_queries,
            self.decommit_expanded_positions,
            self.decommit_walk_queries,
            self.decommit_walk_scratch,
            self.decommit_sparse_indices,
            self.decommit_sparse_hashes,
            self.decommit_counts,
            self.decommit_assembly,
            12,
        );
    }

    pub fn prepareComposition(
        self: PreparedProofBindings,
        allocator: std.mem.Allocator,
        metal: *metal_runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        bundle: composition_bundle_mod.Bundle,
        metallib_path: []const u8,
    ) !protocol_recipes.CompositionRecipe {
        return prepareCompositionRecipe(self, allocator, metal, resident_arena, bundle, metallib_path);
    }

    pub fn executeCommitment(
        self: PreparedProofBindings,
        metal: *metal_runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        schedule: []const std.json.Value,
        plan: arena_plan.Plan,
        tree_index: u32,
        leaf_seed: [8]u32,
        node_seed: [8]u32,
    ) !CommitmentTelemetry {
        const coefficients = switch (tree_index) {
            0 => self.preprocessed_coefficients,
            1 => self.base_coefficients,
            2 => self.interaction_coefficients,
            3 => self.composition_coefficients,
            else => return Error.InvalidCardinality,
        };
        return executeStreamingCommitment(
            self.allocator, metal, resident_arena, schedule, plan, coefficients,
            tree_index, leaf_seed, node_seed,
        );
    }

    fn validateSn2(self: PreparedProofBindings) !void {
        if (self.composition_coefficients.len != Sn2Counts.composition_coefficients) return Error.InvalidCompositionCount;
        if (self.quotient_partials.len != Sn2Counts.quotient_partials) return Error.InvalidQuotientCount;
        if (self.fri_challenges.len != Sn2Counts.fri_challenges) return Error.InvalidFriChallengeCount;
        if (self.fri_retained_evaluations.len != Sn2Counts.fri_retained_evaluations) return Error.InvalidFriRetainedCount;
        if (self.fri_merkle_layers.len != Sn2Counts.fri_merkle_layers) return Error.InvalidFriLayerCount;
        if (self.composition_ext_params.len != 58) return Error.InvalidExtParamCount;
        if (self.relation_claimed_sums.len != 58) return Error.InvalidClaimedSumCount;
        if (self.preprocessed_coefficients.len != 161) return Error.InvalidPreprocessedCount;
        for (self.composition_coefficients) |binding| {
            if (binding.size_bytes != (@as(u64, 1) << 23) * 4) return Error.InvalidBindingSize;
        }
        if (self.fri_final_coefficients.size_bytes != 8 * 4 or
            self.fri_final_degree_error.size_bytes != 4 or
            self.transcript_state.size_bytes < 10 * 4 or self.transcript_inputs.len != 26 or self.transcript_outputs.len != 13 or
            self.decommit_values.size_bytes == 0 or
            self.decommit_assembly.size_bytes == 0 or self.proof_bytes.size_bytes == 0 or self.assembly.len == 0 or
            self.proof_copies.len != 18)
            return Error.InvalidBindingSize;
        var cursor: u64 = 0;
        for (self.proof_copies) |copy| {
            if (copy.destination_word_offset != cursor or copy.source.size_bytes < @as(u64, copy.word_count) * 4)
                return Error.InvalidBindingSize;
            cursor += copy.word_count;
        }
        if (cursor * 4 != self.proof_bytes.size_bytes) return Error.InvalidBindingSize;
    }
};

/// Binds all 33 canonical witness programs to the captured SN2 arena. The
/// pointer workspaces retain their CUDA-sized allocation but contain native
/// u32 Metal word offsets in the leading half.
pub fn populateExecutionTables(
    allocator: std.mem.Allocator,
    metal: *metal_runtime.Runtime,
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    input: *const cairo_adapter.ProverInput,
) !f64 {
    const raw_address = try one(schedule, plan, "ExecutionTableRawAddressToId");
    const raw_big = try one(schedule, plan, "ExecutionTableRawF252Words");
    const raw_small = try one(schedule, plan, "ExecutionTableRawSmallWords");
    if (raw_address.size_bytes != @as(u64, input.memory.address_to_id.len) * 4 or
        raw_big.size_bytes != @as(u64, input.memory.f252_values.len) * 8 * 4 or
        raw_small.size_bytes != @as(u64, input.memory.small_values.len) * 4 * 4)
        return Error.InvalidBindingSize;

    @memcpy(try resident_arena.bytes(raw_address), std.mem.sliceAsBytes(input.memory.address_to_id));
    @memcpy(try resident_arena.bytes(raw_big), std.mem.sliceAsBytes(input.memory.f252_values));
    const small_bytes = try resident_arena.bytes(raw_small);
    const small_aligned: []align(4) u8 = @alignCast(small_bytes);
    const small_words = std.mem.bytesAsSlice(u32, small_aligned);
    for (input.memory.small_values, 0..) |value, row| {
        inline for (0..4) |word| small_words[row * 4 + word] = @truncate(value >> (word * 32));
    }

    const big = try collect(allocator, schedule, plan, "ExecutionTableBigLimb");
    defer allocator.free(big);
    const small = try collect(allocator, schedule, plan, "ExecutionTableSmallLimb");
    defer allocator.free(small);
    if (big.len != 28 or small.len != 8) return Error.InvalidCardinality;
    const big_rows = std.math.cast(u32, big[0].size_bytes / 4) orelse return Error.InvalidBindingSize;
    const small_rows = std.math.cast(u32, small[0].size_bytes / 4) orelse return Error.InvalidBindingSize;
    var big_offsets: [28]u32 = undefined;
    var small_offsets: [8]u32 = undefined;
    for (big, &big_offsets) |binding, *offset| {
        if (binding.size_bytes != @as(u64, big_rows) * 4) return Error.InvalidBindingSize;
        offset.* = try wordOffset(binding);
    }
    for (small, &small_offsets) |binding, *offset| {
        if (binding.size_bytes != @as(u64, small_rows) * 4) return Error.InvalidBindingSize;
        offset.* = try wordOffset(binding);
    }
    var gpu_ms = try metal.executionTableSplit(
        resident_arena.buffer, try wordOffset(raw_big), @intCast(input.memory.f252_values.len),
        big_rows, 8, &big_offsets,
    );
    gpu_ms += try metal.executionTableSplit(
        resident_arena.buffer, try wordOffset(raw_small), @intCast(input.memory.small_values.len),
        small_rows, 4, &small_offsets,
    );
    return gpu_ms;
}

pub fn populatePreprocessedCoefficients(
    allocator: std.mem.Allocator,
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    fixed_bundle: fixed_table_bundle_mod.Bundle,
    path: []const u8,
) !void {
    const coefficients = try collectScheduleOrder(allocator, schedule, plan, "PreprocessedCoefficients");
    defer allocator.free(coefficients);
    if (coefficients.len != fixed_bundle.preprocessed_identities.len) return Error.InvalidPreprocessedCount;
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    var buffer: [1 << 20]u8 = undefined;
    var reader = file.readerStreaming(&buffer);
    const stream = &reader.interface;
    if (!std.mem.eql(u8, try stream.takeArray(8), "STWZPPC\x00")) return Error.InvalidSchedule;
    if (try stream.takeInt(u32, .little) != 1 or try stream.takeInt(u32, .little) != coefficients.len)
        return Error.InvalidPreprocessedCount;
    for (coefficients, fixed_bundle.preprocessed_identities) |binding, expected_identity| {
        const identity_len = try stream.takeInt(u16, .little);
        if (try stream.takeInt(u16, .little) != 0 or identity_len != expected_identity.len)
            return Error.InvalidSchedule;
        const log_size = try stream.takeInt(u32, .little);
        const value_count = try stream.takeInt(u64, .little);
        if (log_size >= 31 or value_count != @as(u64, 1) << @intCast(log_size) or binding.size_bytes != value_count * 4)
            return Error.InvalidBindingSize;
        const identity = try allocator.alloc(u8, identity_len);
        defer allocator.free(identity);
        try stream.readSliceAll(identity);
        if (!std.mem.eql(u8, identity, expected_identity)) return Error.InvalidSchedule;
        const destination = try resident_arena.bytes(binding);
        try stream.readSliceAll(destination);
        const aligned: []align(4) u8 = @alignCast(destination);
        for (std.mem.bytesAsSlice(u32, aligned)) |value| if (value >= 0x7fffffff) return Error.InvalidSchedule;
    }
    var trailing: [1]u8 = undefined;
    if (try stream.readSliceShort(&trailing) != 0) return Error.InvalidSchedule;
}

pub fn evaluatePreprocessedCoefficients(
    allocator: std.mem.Allocator,
    metal: *metal_runtime.Runtime,
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
) !f64 {
    const twiddles = try one(schedule, plan, "ForwardTwiddles");
    var gpu_ms: f64 = 0;
    for (4..26) |log_size_usize| {
        const log_size: u32 = @intCast(log_size_usize);
        var source_offsets = std.ArrayList(u32).empty;
        defer source_offsets.deinit(allocator);
        var source_logs = std.ArrayList(u32).empty;
        defer source_logs.deinit(allocator);
        var destination_offsets = std.ArrayList(u32).empty;
        defer destination_offsets.deinit(allocator);
        const expected_bytes = (@as(u64, 1) << @intCast(log_size)) * 4;
        for (schedule) |entry| {
            if (!std.mem.eql(u8, try purpose(entry), "PreprocessedEvaluations")) continue;
            const destination = plan.binding(try logicalId(entry)) catch return Error.MissingBinding;
            if (destination.size_bytes != expected_bytes) continue;
            const source = try oneOrdinal(schedule, plan, "PreprocessedCoefficients", try ordinal(entry));
            if (destination.size_bytes != expected_bytes) return Error.InvalidBindingSize;
            try source_offsets.append(allocator, try wordOffset(source));
            try source_logs.append(allocator, log_size);
            try destination_offsets.append(allocator, try wordOffset(destination));
        }
        if (source_offsets.items.len == 0) continue;
        var prepared = try metal.prepareCompositionLde(
            source_offsets.items,
            source_logs.items,
            destination_offsets.items,
            log_size,
            try twiddleOffsetForLog(twiddles, log_size),
        );
        defer prepared.deinit();
        gpu_ms += try metal.compositionLdePrepared(resident_arena.buffer, prepared);
    }
    const seq4 = try oneOrdinal(schedule, plan, "PreprocessedEvaluations", 0);
    const seq4_bytes = try resident_arena.bytes(seq4);
    if (seq4_bytes.len != 16 * 4) return Error.InvalidBindingSize;
    const seq4_aligned: []align(4) u8 = @alignCast(seq4_bytes);
    for (std.mem.bytesAsSlice(u32, seq4_aligned), 0..) |value, expected| {
        if (value != expected) {
            std.log.err("preprocessed seq_4 parity mismatch at row {d}: expected {d}, got {d}", .{ expected, expected, value });
            return Error.InvalidSchedule;
        }
    }
    return gpu_ms;
}

pub fn populateProtocolTwiddles(
    allocator: std.mem.Allocator,
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
) !void {
    const forward = try one(schedule, plan, "ForwardTwiddles");
    const preprocessed_inverse = try one(schedule, plan, "PreprocessedInverseTwiddles");
    if (forward.size_bytes != preprocessed_inverse.size_bytes) return Error.InvalidBindingSize;
    try populateTwiddlePair(allocator, resident_arena, forward, preprocessed_inverse);
    const inverse = try one(schedule, plan, "InverseTwiddles");
    try populateInverseTwiddles(allocator, resident_arena, inverse);
    const quotient_inverse = try one(schedule, plan, "QuotientInverseTwiddles");
    try populateInverseTwiddles(allocator, resident_arena, quotient_inverse);
}

fn populateTwiddlePair(
    allocator: std.mem.Allocator,
    resident_arena: *arena_plan.ResidentArena,
    forward: arena_plan.Binding,
    inverse: arena_plan.Binding,
) !void {
    if (forward.size_bytes == 0 or forward.size_bytes % 4 != 0 or !std.math.isPowerOfTwo(forward.size_bytes / 4))
        return Error.InvalidBindingSize;
    const log_words: u32 = std.math.log2_int(u64, forward.size_bytes / 4);
    var tree = try twiddles_mod.precomputeM31(allocator, circle_mod.Coset.halfOdds(log_words));
    defer twiddles_mod.deinitM31(allocator, &tree);
    @memcpy(try resident_arena.bytes(forward), std.mem.sliceAsBytes(tree.twiddles));
    @memcpy(try resident_arena.bytes(inverse), std.mem.sliceAsBytes(tree.itwiddles));
}

fn populateInverseTwiddles(
    allocator: std.mem.Allocator,
    resident_arena: *arena_plan.ResidentArena,
    inverse: arena_plan.Binding,
) !void {
    if (inverse.size_bytes == 0 or inverse.size_bytes % 4 != 0 or !std.math.isPowerOfTwo(inverse.size_bytes / 4))
        return Error.InvalidBindingSize;
    const log_words: u32 = std.math.log2_int(u64, inverse.size_bytes / 4);
    var tree = try twiddles_mod.precomputeM31(allocator, circle_mod.Coset.halfOdds(log_words));
    defer twiddles_mod.deinitM31(allocator, &tree);
    @memcpy(try resident_arena.bytes(inverse), std.mem.sliceAsBytes(tree.itwiddles));
}

pub fn prepareFixedTableBatch(
    allocator: std.mem.Allocator,
    metal: *metal_runtime.Runtime,
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    fixed_bundle: fixed_table_bundle_mod.Bundle,
) !protocol_recipes.FixedTableBatchRecipe {
    var bindings = std.ArrayList(protocol_recipes.FixedTableBindings).empty;
    defer bindings.deinit(allocator);
    var owned_sources = std.ArrayList([]arena_plan.Binding).empty;
    defer {
        for (owned_sources.items) |items| allocator.free(items);
        owned_sources.deinit(allocator);
    }
    var owned_multiplicities = std.ArrayList([]arena_plan.Binding).empty;
    defer {
        for (owned_multiplicities.items) |items| allocator.free(items);
        owned_multiplicities.deinit(allocator);
    }
    for (fixed_bundle.entries) |entry| {
        const destination = oneComponent(schedule, plan, "LookupInputs", entry.component) catch |err| switch (err) {
            Error.MissingBinding => continue,
            else => return err,
        };
        const sources = try allocator.alloc(arena_plan.Binding, entry.preprocessed_sources.len);
        var sources_owned = false;
        errdefer if (!sources_owned) allocator.free(sources);
        for (entry.preprocessed_sources, sources) |identity, *source| {
            const ordinal_value = fixed_bundle.identityOrdinal(identity) orelse return Error.MissingBinding;
            source.* = try oneOrdinal(schedule, plan, "PreprocessedEvaluations", ordinal_value);
        }
        try owned_sources.append(allocator, sources);
        sources_owned = true;
        const multiplicity_slab = try oneComponent(schedule, plan, "FixedMultiplicity", entry.component);
        const multiplicities = try allocator.alloc(arena_plan.Binding, entry.multiplicity_columns);
        var multiplicities_owned = false;
        errdefer if (!multiplicities_owned) allocator.free(multiplicities);
        const column_bytes = @as(u64, entry.row_count) * 4;
        if (multiplicity_slab.size_bytes != column_bytes * entry.multiplicity_columns) return Error.InvalidBindingSize;
        for (multiplicities, 0..) |*column, index| {
            column.* = multiplicity_slab;
            column.offset_bytes += @as(u64, @intCast(index)) * column_bytes;
            column.size_bytes = column_bytes;
        }
        try owned_multiplicities.append(allocator, multiplicities);
        multiplicities_owned = true;
        try bindings.append(allocator, .{
            .row_count = entry.row_count,
            .descriptors = entry.lookup_descriptors,
            .sources = sources,
            .multiplicities = multiplicities,
            .destination = destination,
        });
    }
    return protocol_recipes.FixedTableBatchRecipe.init(allocator, metal, resident_arena, bindings.items);
}

pub fn interpolateTraceColumns(
    allocator: std.mem.Allocator,
    metal: *metal_runtime.Runtime,
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    source_purpose: []const u8,
    destination_purpose: []const u8,
    inverse_twiddle_purpose: []const u8,
) !f64 {
    const sources = try collectScheduleOrder(allocator, schedule, plan, source_purpose);
    defer allocator.free(sources);
    const destinations = try collectScheduleOrder(allocator, schedule, plan, destination_purpose);
    defer allocator.free(destinations);
    if (sources.len != destinations.len) return Error.InvalidCardinality;
    const inverse_twiddles = try one(schedule, plan, inverse_twiddle_purpose);
    var gpu_ms: f64 = 0;
    for (4..25) |log_size_usize| {
        const log_size: u32 = @intCast(log_size_usize);
        const expected_bytes = (@as(u64, 1) << @intCast(log_size)) * 4;
        var source_offsets = std.ArrayList(u32).empty;
        defer source_offsets.deinit(allocator);
        var destination_offsets = std.ArrayList(u32).empty;
        defer destination_offsets.deinit(allocator);
        for (sources, destinations) |source, destination| {
            if (source.size_bytes != expected_bytes) continue;
            if (destination.size_bytes != expected_bytes) return Error.InvalidBindingSize;
            try source_offsets.append(allocator, try wordOffset(source));
            try destination_offsets.append(allocator, try wordOffset(destination));
        }
        if (source_offsets.items.len == 0) continue;
        const scale = (try M31.fromCanonical(@as(u32, 1) << @intCast(log_size)).inv()).v;
        var prepared = try metal.prepareCircleIfft(
            source_offsets.items,
            destination_offsets.items,
            log_size,
            try twiddleOffsetForLog(inverse_twiddles, log_size),
            scale,
        );
        defer prepared.deinit();
        gpu_ms += try metal.circleIfftPrepared(resident_arena.buffer, prepared);
    }
    return gpu_ms;
}

pub fn prepareEcOpWitness(
    allocator: std.mem.Allocator,
    metal: *metal_runtime.Runtime,
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    input: *const cairo_adapter.ProverInput,
) !protocol_recipes.EcOpRecipe {
    var execution: [37]arena_plan.Binding = undefined;
    execution[0] = try one(schedule, plan, "ExecutionTableRawAddressToId");
    const big = try collect(allocator, schedule, plan, "ExecutionTableBigLimb");
    defer allocator.free(big);
    const small = try collect(allocator, schedule, plan, "ExecutionTableSmallLimb");
    defer allocator.free(small);
    if (big.len != 28 or small.len != 8) return Error.InvalidCardinality;
    @memcpy(execution[1..29], big);
    @memcpy(execution[29..37], small);

    const trace = try collectComponent(allocator, schedule, plan, "BaseTrace", "ec_op_builtin");
    defer allocator.free(trace);
    const partial = try collectComponent(allocator, schedule, plan, "WitnessInput", "partial_ec_mul_generic");
    defer allocator.free(partial);
    if (trace.len != 273 or partial.len != 126) return Error.InvalidCardinality;
    var trace_columns: [273]arena_plan.Binding = undefined;
    var partial_columns: [127]arena_plan.Binding = undefined;
    @memcpy(&trace_columns, trace);
    @memcpy(partial_columns[0..126], partial);
    const partial_iota = try oneComponent(schedule, plan, "EcOpPartialIota", "ec_op_builtin");
    partial_columns[126] = partial_iota;
    const segment_start = try oneComponent(schedule, plan, "EcOpSegmentStart", "ec_op_builtin");
    const ec_segment = input.builtin_segments.ec_op_builtin orelse return Error.MissingBinding;
    if (ec_segment.begin_addr > std.math.maxInt(u32)) return Error.InvalidBindingSize;
    const segment_bytes = try resident_arena.bytes(segment_start);
    const segment_aligned: *align(4) u32 = @ptrCast(@alignCast(segment_bytes.ptr));
    segment_aligned.* = @intCast(ec_segment.begin_addr);
    const row_count = std.math.cast(u32, trace[0].size_bytes / 4) orelse return Error.InvalidBindingSize;
    const multiplicities = [4]arena_plan.Binding{
        try oneComponentOrdinal(schedule, plan, "RuntimeMultiplicity", "memory_address_to_id", 21),
        try oneComponentOrdinal(schedule, plan, "RuntimeMultiplicity", "memory_id_to_big", 22),
        try oneComponentOrdinal(schedule, plan, "RuntimeMultiplicity", "memory_id_to_big", 23),
        try oneComponentOrdinal(schedule, plan, "FixedMultiplicity", "range_check_8", 0),
    };
    return protocol_recipes.EcOpRecipe.init(allocator, metal, resident_arena, .{
        .execution_columns = execution,
        .trace_columns = trace_columns,
        .partial_columns = partial_columns,
        .multiplicities = multiplicities,
        .lookup = try oneComponent(schedule, plan, "LookupInputs", "ec_op_builtin"),
        .segment_start = segment_start,
        .scratch = partial_iota,
        .row_count = row_count,
    });
}

pub fn prepareAotWitnessBatch(
    allocator: std.mem.Allocator,
    metal: *metal_runtime.Runtime,
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    witness_bundle: witness_bundle_mod.Bundle,
    fixed_bundle: fixed_table_bundle_mod.Bundle,
    metallib_path: []const u8,
) !protocol_recipes.AotWitnessBatchRecipe {
    const table_pointers = try one(schedule, plan, "ExecutionTablePointers");
    const table_strides = try one(schedule, plan, "ExecutionTableStrides");
    var execution_tables = std.ArrayList(arena_plan.Binding).empty;
    defer execution_tables.deinit(allocator);
    try execution_tables.append(allocator, try one(schedule, plan, "ExecutionTableRawAddressToId"));
    const big = try collect(allocator, schedule, plan, "ExecutionTableBigLimb");
    defer allocator.free(big);
    const small = try collect(allocator, schedule, plan, "ExecutionTableSmallLimb");
    defer allocator.free(small);
    if (big.len != 28 or small.len != 8) return Error.InvalidCardinality;
    try execution_tables.appendSlice(allocator, big);
    try execution_tables.appendSlice(allocator, small);
    try writeBindingOffsets(resident_arena, table_pointers, execution_tables.items);
    const stride_bytes = try resident_arena.bytes(table_strides);
    if (stride_bytes.len != 12) return Error.InvalidBindingSize;
    const stride_aligned: []align(4) u8 = @alignCast(stride_bytes);
    const strides = std.mem.bytesAsSlice(u32, stride_aligned);
    strides[0] = @intCast(execution_tables.items[0].size_bytes / 4);
    strides[1] = @intCast(big[0].size_bytes / 4);
    strides[2] = @intCast(small[0].size_bytes / 4);

    const pedersen_entry = fixed_bundle.find("pedersen_points_table_window_bits_18") orelse return Error.MissingBinding;
    const poseidon_entry = fixed_bundle.find("poseidon_round_keys") orelse return Error.MissingBinding;
    const pedersen_pointers = try oneComponent(schedule, plan, "FixedTableSourcePointers", pedersen_entry.component);
    const poseidon_pointers = try oneComponent(schedule, plan, "FixedTableSourcePointers", poseidon_entry.component);
    try writePreprocessedOffsets(resident_arena, schedule, plan, fixed_bundle, pedersen_entry.preprocessed_sources, pedersen_pointers);
    try writePreprocessedOffsets(resident_arena, schedule, plan, fixed_bundle, poseidon_entry.preprocessed_sources, poseidon_pointers);

    const invocations = try allocator.alloc(protocol_recipes.AotWitnessInvocation, witness_bundle.entries.len);
    defer allocator.free(invocations);
    const names = try allocator.alloc([]u8, witness_bundle.entries.len);
    var names_initialized: usize = 0;
    defer {
        for (names[0..names_initialized]) |name| allocator.free(name);
        allocator.free(names);
    }
    const owned_destinations = try allocator.alloc([]arena_plan.Binding, witness_bundle.entries.len);
    var destinations_initialized: usize = 0;
    defer {
        for (owned_destinations[0..destinations_initialized]) |destinations| allocator.free(destinations);
        allocator.free(owned_destinations);
    }

    for (witness_bundle.entries, invocations, names, owned_destinations) |entry, *invocation, *name, *owned| {
        const inputs = try collectComponent(allocator, schedule, plan, "WitnessInput", entry.label);
        defer allocator.free(inputs);
        const outputs = try collectComponent(allocator, schedule, plan, "BaseTrace", entry.label);
        defer allocator.free(outputs);
        if (inputs.len != entry.program.n_inputs or outputs.len != entry.program.n_cols or outputs.len == 0)
            return Error.InvalidCardinality;
        const row_count = std.math.cast(u32, outputs[0].size_bytes / 4) orelse return Error.InvalidBindingSize;
        if (row_count == 0 or !std.math.isPowerOfTwo(row_count)) return Error.InvalidBindingSize;
        for (inputs) |binding| if (binding.size_bytes != @as(u64, row_count) * 4) return Error.InvalidBindingSize;
        for (outputs) |binding| if (binding.size_bytes != @as(u64, row_count) * 4) return Error.InvalidBindingSize;

        const input_pointers = try oneComponent(schedule, plan, "WitnessInputPointers", entry.label);
        const output_pointers = try oneComponent(schedule, plan, "WitnessOutputPointers", entry.label);
        const multiplicity_pointers = try oneComponent(schedule, plan, "WitnessMultiplicityPointers", entry.label);
        try writeBindingOffsets(resident_arena, input_pointers, inputs);
        try writeBindingOffsets(resident_arena, output_pointers, outputs);
        const multiplicity_dummy = try oneComponent(schedule, plan, "WitnessMultiplicityDummy", entry.label);
        try writeBindingOffsets(resident_arena, multiplicity_pointers, &.{multiplicity_dummy});

        const lookup = try oneComponent(schedule, plan, "LookupInputs", entry.label);
        const sub = try oneComponent(schedule, plan, "SubcomponentInputs", entry.label);
        if (lookup.size_bytes != @as(u64, row_count) * entry.program.n_lookup_words * 4 or
            sub.size_bytes != @as(u64, row_count) * entry.program.n_sub_words * 4)
            return Error.InvalidBindingSize;
        owned.* = try allocator.alloc(arena_plan.Binding, outputs.len + 2);
        destinations_initialized += 1;
        @memcpy(owned.*[0..outputs.len], outputs);
        owned.*[outputs.len] = lookup;
        owned.*[outputs.len + 1] = sub;
        name.* = try witness_codegen.kernelName(allocator, entry.semantic_hash);
        names_initialized += 1;
        invocation.* = .{
            .kernel_name = name.*,
            .layout = .{
                .input_offsets = try wordOffset(input_pointers),
                .table_offsets = try wordOffset(table_pointers),
                .table_strides = try wordOffset(table_strides),
                .output_offsets = try wordOffset(output_pointers),
                .multiplicity_offsets = try wordOffset(multiplicity_pointers),
                .lookup_words = try wordOffset(lookup),
                .sub_words = try wordOffset(sub),
                .row_count = row_count,
                .pedersen_offsets = try wordOffset(pedersen_pointers) + 1,
                .pedersen_rows = pedersen_entry.row_count,
                .poseidon_keys = try wordOffset(poseidon_pointers) + 1,
            },
            .destinations = owned.*,
        };
    }
    return protocol_recipes.AotWitnessBatchRecipe.init(
        allocator,
        metal,
        resident_arena,
        metallib_path,
        invocations,
    );
}

const CasmLane = struct {
    label: []const u8,
    tag: cairo_opcodes.OpcodeTag,
    iota: bool = false,
};

const casm_lanes = [_]CasmLane{
    .{ .label = "add_ap_opcode", .tag = .add_ap_opcode },
    .{ .label = "add_opcode", .tag = .add_opcode },
    .{ .label = "add_opcode_small", .tag = .add_opcode_small },
    .{ .label = "assert_eq_opcode", .tag = .assert_eq_opcode },
    .{ .label = "assert_eq_opcode_double_deref", .tag = .assert_eq_opcode_double_deref },
    .{ .label = "assert_eq_opcode_imm", .tag = .assert_eq_opcode_imm },
    .{ .label = "call_opcode_abs", .tag = .call_opcode_abs },
    .{ .label = "call_opcode_rel_imm", .tag = .call_opcode_rel_imm },
    .{ .label = "jnz_opcode_non_taken", .tag = .jnz_opcode_non_taken },
    .{ .label = "jnz_opcode_taken", .tag = .jnz_opcode_taken },
    .{ .label = "jump_opcode_abs", .tag = .jump_opcode_abs },
    .{ .label = "jump_opcode_double_deref", .tag = .jump_opcode_double_deref },
    .{ .label = "jump_opcode_rel", .tag = .jump_opcode_rel },
    .{ .label = "jump_opcode_rel_imm", .tag = .jump_opcode_rel_imm },
    .{ .label = "mul_opcode", .tag = .mul_opcode },
    .{ .label = "mul_opcode_small", .tag = .mul_opcode_small },
    .{ .label = "ret_opcode", .tag = .ret_opcode },
    .{ .label = "blake_compress_opcode", .tag = .blake_compress_opcode, .iota = true },
    .{ .label = "qm_31_add_mul_opcode", .tag = .qm_31_add_mul_opcode },
};

/// Materializes the direct adapted-input lanes without an intermediate packed
/// matrix. Padding repeats row zero exactly as stwo-cairo's `casm_slot_columns`.
pub fn populateCasmWitnessInputs(
    allocator: std.mem.Allocator,
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    witness_bundle: witness_bundle_mod.Bundle,
    input: *const cairo_adapter.ProverInput,
) !usize {
    var populated: usize = 0;
    for (casm_lanes) |lane| {
        const program_entry = witness_bundle.find(lane.label) orelse continue;
        const states = input.state_transitions.casm_states_by_opcode.getConst(lane.tag);
        if (states.len == 0) return Error.MissingBinding;
        const bindings = try collectComponent(allocator, schedule, plan, "WitnessInput", lane.label);
        defer allocator.free(bindings);
        const expected_columns: usize = if (lane.iota) 5 else 4;
        if (program_entry.program.n_inputs != expected_columns or bindings.len != expected_columns)
            return Error.InvalidCardinality;
        const row_count = bindings[0].size_bytes / 4;
        const expected_rows = @max(std.math.ceilPowerOfTwo(usize, states.len) catch return Error.InvalidBindingSize, 16);
        if (row_count != expected_rows) return Error.InvalidBindingSize;
        for (bindings, 0..) |binding, column| {
            const bytes = try resident_arena.bytes(binding);
            if (bytes.len != row_count * 4) return Error.InvalidBindingSize;
            const aligned: []align(4) u8 = @alignCast(bytes);
            const destination = std.mem.bytesAsSlice(u32, aligned);
            for (destination, 0..) |*value, row| {
                const state = states[if (row < states.len) row else 0];
                value.* = switch (column) {
                    0 => state.pc.v,
                    1 => state.ap.v,
                    2 => state.fp.v,
                    3 => @intFromBool(row < states.len),
                    4 => @intCast(row),
                    else => unreachable,
                };
            }
        }
        populated += 1;
    }
    return populated;
}

pub fn populateBuiltinSeedWitnessInputs(
    allocator: std.mem.Allocator,
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    witness_bundle: witness_bundle_mod.Bundle,
    input: *const cairo_adapter.ProverInput,
) !usize {
    const SeedLane = struct { label: []const u8, segment: ?cairo_adapter.MemorySegmentAddresses };
    const lanes = [_]SeedLane{
        .{ .label = "bitwise_builtin", .segment = input.builtin_segments.bitwise_builtin },
        .{ .label = "range_check_builtin", .segment = input.builtin_segments.range_check_builtin },
        .{ .label = "pedersen_builtin", .segment = input.builtin_segments.pedersen_builtin },
        .{ .label = "poseidon_builtin", .segment = input.builtin_segments.poseidon_builtin },
    };
    var populated: usize = 0;
    for (lanes) |lane| {
        const entry = witness_bundle.find(lane.label) orelse continue;
        const segment = lane.segment orelse return Error.MissingBinding;
        const bindings = try collectComponent(allocator, schedule, plan, "WitnessInput", lane.label);
        defer allocator.free(bindings);
        if (entry.program.n_inputs != 3 or bindings.len != 3 or segment.begin_addr > std.math.maxInt(u32))
            return Error.InvalidCardinality;
        const row_count = bindings[0].size_bytes / 4;
        if (row_count < 16 or !std.math.isPowerOfTwo(row_count)) return Error.InvalidBindingSize;
        for (bindings, 0..) |binding, column| {
            const bytes = try resident_arena.bytes(binding);
            if (bytes.len != row_count * 4) return Error.InvalidBindingSize;
            const aligned: []align(4) u8 = @alignCast(bytes);
            const destination = std.mem.bytesAsSlice(u32, aligned);
            for (destination, 0..) |*value, row| value.* = switch (column) {
                0 => @intCast(segment.begin_addr),
                1 => 1,
                2 => @intCast(row),
                else => unreachable,
            };
        }
        populated += 1;
    }
    return populated;
}

pub const WitnessEdge = struct {
    producer: []const u8,
    word_base: u32,
    words_per_instance: u32,
    instances: u32,
};

const edge_blake_round = [_]WitnessEdge{.{ .producer = "blake_compress_opcode", .word_base = 110, .words_per_instance = 19, .instances = 10 }};
const edge_blake_g = [_]WitnessEdge{.{ .producer = "blake_round", .word_base = 81, .words_per_instance = 6, .instances = 8 }};
const edge_triple_xor = [_]WitnessEdge{.{ .producer = "blake_compress_opcode", .word_base = 300, .words_per_instance = 3, .instances = 8 }};
const edge_partial_w18 = [_]WitnessEdge{.{ .producer = "pedersen_aggregator_window_bits_18", .word_base = 7, .words_per_instance = 72, .instances = 28 }};
const edge_cube = [_]WitnessEdge{
    .{ .producer = "poseidon_aggregator", .word_base = 282, .words_per_instance = 10, .instances = 2 },
    .{ .producer = "poseidon_3_partial_rounds_chain", .word_base = 1, .words_per_instance = 10, .instances = 3 },
    .{ .producer = "poseidon_full_round_chain", .word_base = 0, .words_per_instance = 10, .instances = 3 },
};
const edge_range_252 = [_]WitnessEdge{
    .{ .producer = "poseidon_aggregator", .word_base = 262, .words_per_instance = 10, .instances = 2 },
    .{ .producer = "poseidon_3_partial_rounds_chain", .word_base = 61, .words_per_instance = 10, .instances = 3 },
};
const edge_poseidon_full = [_]WitnessEdge{.{ .producer = "poseidon_aggregator", .word_base = 6, .words_per_instance = 32, .instances = 8 }};
const edge_poseidon_partial = [_]WitnessEdge{.{ .producer = "poseidon_aggregator", .word_base = 342, .words_per_instance = 42, .instances = 27 }};
const compact_verify_edges = [_]WitnessEdge{
    .{ .producer = "add_opcode", .word_base = 0, .words_per_instance = 7, .instances = 1 },
    .{ .producer = "add_opcode_small", .word_base = 0, .words_per_instance = 7, .instances = 1 },
    .{ .producer = "add_ap_opcode", .word_base = 0, .words_per_instance = 7, .instances = 1 },
    .{ .producer = "assert_eq_opcode", .word_base = 0, .words_per_instance = 7, .instances = 1 },
    .{ .producer = "assert_eq_opcode_imm", .word_base = 0, .words_per_instance = 7, .instances = 1 },
    .{ .producer = "assert_eq_opcode_double_deref", .word_base = 0, .words_per_instance = 7, .instances = 1 },
    .{ .producer = "blake_compress_opcode", .word_base = 0, .words_per_instance = 7, .instances = 1 },
    .{ .producer = "call_opcode_abs", .word_base = 0, .words_per_instance = 7, .instances = 1 },
    .{ .producer = "call_opcode_rel_imm", .word_base = 0, .words_per_instance = 7, .instances = 1 },
    .{ .producer = "generic_opcode", .word_base = 0, .words_per_instance = 7, .instances = 1 },
    .{ .producer = "jnz_opcode_non_taken", .word_base = 0, .words_per_instance = 7, .instances = 1 },
    .{ .producer = "jnz_opcode_taken", .word_base = 0, .words_per_instance = 7, .instances = 1 },
    .{ .producer = "jump_opcode_abs", .word_base = 0, .words_per_instance = 7, .instances = 1 },
    .{ .producer = "jump_opcode_double_deref", .word_base = 0, .words_per_instance = 7, .instances = 1 },
    .{ .producer = "jump_opcode_rel", .word_base = 0, .words_per_instance = 7, .instances = 1 },
    .{ .producer = "jump_opcode_rel_imm", .word_base = 0, .words_per_instance = 7, .instances = 1 },
    .{ .producer = "mul_opcode", .word_base = 0, .words_per_instance = 7, .instances = 1 },
    .{ .producer = "mul_opcode_small", .word_base = 0, .words_per_instance = 7, .instances = 1 },
    .{ .producer = "qm_31_add_mul_opcode", .word_base = 0, .words_per_instance = 7, .instances = 1 },
    .{ .producer = "ret_opcode", .word_base = 0, .words_per_instance = 7, .instances = 1 },
};
const compact_pedersen_edges = [_]WitnessEdge{.{ .producer = "pedersen_builtin", .word_base = 3, .words_per_instance = 3, .instances = 1 }};
const compact_poseidon_edges = [_]WitnessEdge{.{ .producer = "poseidon_builtin", .word_base = 6, .words_per_instance = 6, .instances = 1 }};

fn witnessEdges(label: []const u8) ?[]const WitnessEdge {
    if (std.mem.eql(u8, label, "blake_round")) return &edge_blake_round;
    if (std.mem.eql(u8, label, "blake_g")) return &edge_blake_g;
    if (std.mem.eql(u8, label, "triple_xor_32")) return &edge_triple_xor;
    if (std.mem.eql(u8, label, "partial_ec_mul_window_bits_18")) return &edge_partial_w18;
    if (std.mem.eql(u8, label, "cube_252")) return &edge_cube;
    if (std.mem.eql(u8, label, "range_check_252_width_27")) return &edge_range_252;
    if (std.mem.eql(u8, label, "poseidon_full_round_chain")) return &edge_poseidon_full;
    if (std.mem.eql(u8, label, "poseidon_3_partial_rounds_chain")) return &edge_poseidon_partial;
    return null;
}

const CompactGeometry = struct {
    edges: []const WitnessEdge,
    tuple_words: u32,
    key_words: u32,
    enabler_slot: u32,
    iota_slot: u32,
    multiplicity_slot: u32,
};

fn compactGeometry(label: []const u8) ?CompactGeometry {
    if (std.mem.eql(u8, label, "verify_instruction")) return .{ .edges = &compact_verify_edges, .tuple_words = 7, .key_words = 1, .enabler_slot = 7, .iota_slot = 8, .multiplicity_slot = 9 };
    if (std.mem.eql(u8, label, "pedersen_aggregator_window_bits_18")) return .{ .edges = &compact_pedersen_edges, .tuple_words = 3, .key_words = 2, .enabler_slot = 3, .iota_slot = 4, .multiplicity_slot = 5 };
    if (std.mem.eql(u8, label, "poseidon_aggregator")) return .{ .edges = &compact_poseidon_edges, .tuple_words = 6, .key_words = 3, .enabler_slot = 6, .iota_slot = 7, .multiplicity_slot = 8 };
    return null;
}

pub fn prepareCompactWitnessInput(
    allocator: std.mem.Allocator,
    metal: *metal_runtime.Runtime,
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    witness_bundle: witness_bundle_mod.Bundle,
    consumer: []const u8,
) !protocol_recipes.CompactRecipe {
    const geometry = compactGeometry(consumer) orelse return Error.MissingBinding;
    const outputs = try collectComponent(allocator, schedule, plan, "WitnessInput", consumer);
    defer allocator.free(outputs);
    if (outputs.len <= geometry.multiplicity_slot) return Error.InvalidCardinality;
    const consumer_rows = std.math.cast(u32, outputs[0].size_bytes / 4) orelse return Error.InvalidBindingSize;
    var sources = std.ArrayList(arena_plan.Binding).empty;
    defer sources.deinit(allocator);
    var descriptors = std.ArrayList(u32).empty;
    defer descriptors.deinit(allocator);
    var total_rows: u32 = 0;
    for (geometry.edges) |edge| {
        const producer_entry = witness_bundle.find(edge.producer) orelse continue;
        const source = try oneComponent(schedule, plan, "SubcomponentInputs", edge.producer);
        const producer_rows = std.math.cast(u32, source.size_bytes / 4 / producer_entry.program.n_sub_words) orelse return Error.InvalidBindingSize;
        try sources.append(allocator, source);
        try descriptors.appendSlice(allocator, &.{ producer_rows, edge.word_base, edge.words_per_instance, edge.instances, total_rows });
        total_rows = std.math.add(u32, total_rows, std.math.mul(u32, producer_rows, edge.instances) catch return Error.InvalidBindingSize) catch return Error.InvalidBindingSize;
    }
    const descriptor_binding = try oneComponent(schedule, plan, "WitnessInputCompactDescriptors", consumer);
    if (descriptor_binding.size_bytes != descriptors.items.len * 4) return Error.InvalidCardinality;
    @memcpy(try resident_arena.bytes(descriptor_binding), std.mem.sliceAsBytes(descriptors.items));
    const key_a = try oneComponentOrdinal(schedule, plan, "WitnessInputCompactSortKey", consumer, 0);
    const key_b = try oneComponentOrdinal(schedule, plan, "WitnessInputCompactSortKey", consumer, 1);
    const index_a = try oneComponentOrdinal(schedule, plan, "WitnessInputCompactSortIndex", consumer, 0);
    const index_b = try oneComponentOrdinal(schedule, plan, "WitnessInputCompactSortIndex", consumer, 1);
    const sort_rows = std.math.cast(u32, key_a.size_bytes / 4) orelse return Error.InvalidBindingSize;
    return protocol_recipes.CompactRecipe.init(allocator, metal, resident_arena, .{
        .sources = sources.items,
        .descriptors = descriptors.items,
        .outputs = outputs,
        .tuple_words = geometry.tuple_words,
        .key_words = geometry.key_words,
        .total_rows = total_rows,
        .sort_rows = sort_rows,
        .consumer_rows = consumer_rows,
        .enabler_slot = geometry.enabler_slot,
        .multiplicity_slot = geometry.multiplicity_slot,
        .iota_slot = geometry.iota_slot,
        .tuples = try oneComponent(schedule, plan, "WitnessInputCompactTupleScratch", consumer),
        .keys_a = key_a,
        .keys_b = key_b,
        .indices_a = index_a,
        .indices_b = index_b,
        .heads = try oneComponent(schedule, plan, "WitnessInputCompactRunHeads", consumer),
        .positions = try oneComponent(schedule, plan, "WitnessInputCompactRunPositions", consumer),
        .unique = try oneComponent(schedule, plan, "WitnessInputCompactUniqueCount", consumer),
        .sort_temp = try oneComponent(schedule, plan, "WitnessInputCompactSortTemp", consumer),
        .scan_temp = try oneComponent(schedule, plan, "WitnessInputCompactScanTemp", consumer),
    });
}

pub const WitnessExecutionTelemetry = struct {
    executed_programs: usize,
    gpu_ms: f64,
};

fn witnessIndex(bundle: witness_bundle_mod.Bundle, label: []const u8) ?usize {
    for (bundle.entries, 0..) |entry, index| if (std.mem.eql(u8, entry.label, label)) return index;
    return null;
}

fn dependenciesReady(bundle: witness_bundle_mod.Bundle, executed: []const bool, edges: []const WitnessEdge) bool {
    for (edges) |edge| {
        const index = witnessIndex(bundle, edge.producer) orelse continue;
        if (!executed[index]) return false;
    }
    return true;
}

/// Runs every recorded witness program whose inputs are produced by the AOT,
/// gather, seed, or compact routes. The sole native EC-op lane is deliberately
/// left to `EcOpRecipe`, which owns its 126 wide partial-input columns.
pub fn executeRecordedWitnessGraph(
    allocator: std.mem.Allocator,
    metal: *metal_runtime.Runtime,
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    witness_bundle: witness_bundle_mod.Bundle,
    batch: *protocol_recipes.AotWitnessBatchRecipe,
) !WitnessExecutionTelemetry {
    var compact_verify = try prepareCompactWitnessInput(allocator, metal, resident_arena, schedule, plan, witness_bundle, "verify_instruction");
    defer compact_verify.deinit();
    var compact_pedersen = try prepareCompactWitnessInput(allocator, metal, resident_arena, schedule, plan, witness_bundle, "pedersen_aggregator_window_bits_18");
    defer compact_pedersen.deinit();
    var compact_poseidon = try prepareCompactWitnessInput(allocator, metal, resident_arena, schedule, plan, witness_bundle, "poseidon_aggregator");
    defer compact_poseidon.deinit();
    const executed = try allocator.alloc(bool, witness_bundle.entries.len);
    defer allocator.free(executed);
    @memset(executed, false);
    var count: usize = 0;
    const initial_gpu_ms = batch.accumulated_gpu_ms;

    for (witness_bundle.entries, 0..) |entry, index| {
        var direct = false;
        for (casm_lanes) |lane| direct = direct or std.mem.eql(u8, lane.label, entry.label);
        direct = direct or std.mem.eql(u8, entry.label, "bitwise_builtin") or
            std.mem.eql(u8, entry.label, "range_check_builtin") or
            std.mem.eql(u8, entry.label, "pedersen_builtin") or
            std.mem.eql(u8, entry.label, "poseidon_builtin");
        if (!direct) continue;
        try batch.executeIndex(index);
        executed[index] = true;
        count += 1;
    }

    var compact_gpu_ms: f64 = 0;
    var gather_gpu_ms: f64 = 0;
    var progress = true;
    while (progress) {
        progress = false;
        for (witness_bundle.entries, 0..) |entry, index| {
            if (executed[index] or std.mem.eql(u8, entry.label, "partial_ec_mul_generic")) continue;
            if (compactGeometry(entry.label)) |geometry| {
                if (!dependenciesReady(witness_bundle, executed, geometry.edges)) continue;
                if (std.mem.eql(u8, entry.label, "verify_instruction")) {
                    try compact_verify.execute();
                    compact_gpu_ms += compact_verify.accumulated_gpu_ms;
                    compact_verify.accumulated_gpu_ms = 0;
                } else if (std.mem.eql(u8, entry.label, "pedersen_aggregator_window_bits_18")) {
                    try compact_pedersen.execute();
                    compact_gpu_ms += compact_pedersen.accumulated_gpu_ms;
                    compact_pedersen.accumulated_gpu_ms = 0;
                } else {
                    try compact_poseidon.execute();
                    compact_gpu_ms += compact_poseidon.accumulated_gpu_ms;
                    compact_poseidon.accumulated_gpu_ms = 0;
                }
            } else if (witnessEdges(entry.label)) |edges| {
                if (!dependenciesReady(witness_bundle, executed, edges)) continue;
                gather_gpu_ms += try gatherWitnessInput(allocator, metal, resident_arena, schedule, plan, witness_bundle, entry.label);
            } else continue;
            try batch.executeIndex(index);
            executed[index] = true;
            count += 1;
            progress = true;
        }
    }
    if (count + 1 != witness_bundle.entries.len) return Error.InvalidCardinality;
    const native_index = witnessIndex(witness_bundle, "partial_ec_mul_generic") orelse return Error.MissingBinding;
    if (executed[native_index]) return Error.InvalidCardinality;
    return .{ .executed_programs = count, .gpu_ms = batch.accumulated_gpu_ms - initial_gpu_ms + compact_gpu_ms + gather_gpu_ms };
}

pub fn executeNativeEcConsumer(
    witness_bundle: witness_bundle_mod.Bundle,
    batch: *protocol_recipes.AotWitnessBatchRecipe,
    ec_op: *protocol_recipes.EcOpRecipe,
) !WitnessExecutionTelemetry {
    const index = witnessIndex(witness_bundle, "partial_ec_mul_generic") orelse return Error.MissingBinding;
    const initial_batch_ms = batch.accumulated_gpu_ms;
    const initial_ec_ms = ec_op.accumulated_gpu_ms;
    try ec_op.execute();
    try batch.executeIndex(index);
    return .{
        .executed_programs = 1,
        .gpu_ms = batch.accumulated_gpu_ms - initial_batch_ms + ec_op.accumulated_gpu_ms - initial_ec_ms,
    };
}

/// Launches one canonical producer-edge gather immediately before its consumer
/// witness program. Producer sub-word slabs and consumer columns never leave
/// the resident arena.
pub fn gatherWitnessInput(
    allocator: std.mem.Allocator,
    metal: *metal_runtime.Runtime,
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    witness_bundle: witness_bundle_mod.Bundle,
    consumer: []const u8,
) !f64 {
    const edges = witnessEdges(consumer) orelse return Error.MissingBinding;
    const consumer_entry = witness_bundle.find(consumer) orelse return Error.MissingBinding;
    const input_width = edges[0].words_per_instance;
    const consumer_bindings = try collectComponent(allocator, schedule, plan, "WitnessInput", consumer);
    defer allocator.free(consumer_bindings);
    if (consumer_entry.program.n_inputs != input_width + 1 or consumer_bindings.len != input_width + 1)
        return Error.InvalidCardinality;
    const consumer_rows = std.math.cast(u32, consumer_bindings[0].size_bytes / 4) orelse return Error.InvalidBindingSize;
    const producer_offsets = try allocator.alloc(u32, edges.len);
    defer allocator.free(producer_offsets);
    const descriptors = try allocator.alloc([5]u32, edges.len);
    defer allocator.free(descriptors);
    var real_rows: u32 = 0;
    for (edges, producer_offsets, descriptors) |edge, *producer_offset, *descriptor| {
        if (edge.words_per_instance != input_width) return Error.InvalidCardinality;
        const producer_entry = witness_bundle.find(edge.producer) orelse return Error.MissingBinding;
        const source = try oneComponent(schedule, plan, "SubcomponentInputs", edge.producer);
        const producer_rows = std.math.cast(u32, source.size_bytes / 4 / producer_entry.program.n_sub_words) orelse return Error.InvalidBindingSize;
        if (producer_rows == 0 or source.size_bytes != @as(u64, producer_rows) * producer_entry.program.n_sub_words * 4)
            return Error.InvalidBindingSize;
        producer_offset.* = try wordOffset(source);
        descriptor.* = .{ producer_rows, edge.word_base, edge.words_per_instance, edge.instances, real_rows };
        real_rows = std.math.add(u32, real_rows, std.math.mul(u32, producer_rows, edge.instances) catch return Error.InvalidBindingSize) catch return Error.InvalidBindingSize;
    }
    if (real_rows > consumer_rows) return Error.InvalidBindingSize;
    const consumer_offsets = try allocator.alloc(u32, consumer_bindings.len);
    defer allocator.free(consumer_offsets);
    for (consumer_bindings, consumer_offsets) |binding, *offset| {
        if (binding.size_bytes != @as(u64, consumer_rows) * 4) return Error.InvalidBindingSize;
        offset.* = try wordOffset(binding);
    }
    return metal.witnessInputGather(
        resident_arena.buffer,
        producer_offsets,
        descriptors,
        input_width,
        real_rows,
        consumer_rows,
        consumer_offsets,
        true,
        false,
    );
}

fn prepareCompositionRecipe(
    bindings: PreparedProofBindings,
    allocator: std.mem.Allocator,
    metal: *metal_runtime.Runtime,
    resident_arena: *arena_plan.ResidentArena,
    bundle: composition_bundle_mod.Bundle,
    metallib_path: []const u8,
) !protocol_recipes.CompositionRecipe {
    if (bundle.components.len != bindings.composition_ext_params.len or
        bundle.components.len != bindings.relation_claimed_sums.len or bundle.total_constraints * 4 != bindings.composition_random_powers.size_bytes / 4)
        return Error.InvalidCardinality;
    const asOffset = struct {
        fn get(binding: arena_plan.Binding) !u32 {
            if (binding.offset_bytes % 4 != 0) return Error.InvalidBindingSize;
            return std.math.cast(u32, binding.offset_bytes / 4) orelse Error.InvalidBindingSize;
        }
    }.get;
    const bindingLog = struct {
        fn get(binding: arena_plan.Binding) !u32 {
            if (binding.size_bytes < 4 or binding.size_bytes % 4 != 0 or !std.math.isPowerOfTwo(binding.size_bytes / 4))
                return Error.InvalidBindingSize;
            return std.math.log2_int(u64, binding.size_bytes / 4);
        }
    }.get;
    const transcriptOutput = struct {
        fn get(items: []const OrdinalBinding, wanted: u32) !arena_plan.Binding {
            for (items) |item| if (item.ordinal == wanted) return item.binding;
            return Error.MissingBinding;
        }
    }.get;

    var library = try metal.loadEvalLibrary(metallib_path);
    defer library.deinit();
    const descriptor_bytes = try resident_arena.bytes(bindings.composition_descriptors);
    const descriptor_aligned: []align(4) u8 = @alignCast(descriptor_bytes);
    const descriptor_words = std.mem.bytesAsSlice(u32, descriptor_aligned);
    @memset(descriptor_words, 0);
    var descriptor_cursor: usize = 0;

    var log_present = [_]bool{false} ** 31;
    for (bundle.components) |component| log_present[component.evaluation_log_size] = true;
    var accumulator_logs = std.ArrayList(u32).empty;
    defer accumulator_logs.deinit(allocator);
    var accumulator_offsets = std.ArrayList(u32).empty;
    defer accumulator_offsets.deinit(allocator);
    var accumulator_relative = [_]?u32{null} ** 31;
    var accumulator_words: u64 = 0;
    for (log_present, 0..) |present, log_size| {
        if (!present) continue;
        accumulator_relative[log_size] = @intCast(accumulator_words);
        try accumulator_logs.append(allocator, @intCast(log_size));
        try accumulator_offsets.append(
            allocator,
            std.math.add(u32, try asOffset(bindings.composition_accumulators), @intCast(accumulator_words)) catch return Error.InvalidBindingSize,
        );
        accumulator_words += @as(u64, 4) << @intCast(log_size);
    }
    if (accumulator_words * 4 != bindings.composition_accumulators.size_bytes) return Error.InvalidBindingSize;

    const lde_plans = try allocator.alloc(metal_runtime.CompositionLdePlan, bundle.components.len);
    defer allocator.free(lde_plans);
    var initialized_ldes: usize = 0;
    defer for (lde_plans[0..initialized_ldes]) |*plan| plan.deinit();
    const eval_batches = try allocator.alloc(metal_runtime.EvalBatchPlan, bundle.components.len);
    defer allocator.free(eval_batches);
    var initialized_batches: usize = 0;
    defer for (eval_batches[0..initialized_batches]) |*plan| plan.deinit();
    var ext_descriptors = std.ArrayList(metal_runtime.CompositionExtParamDescriptor).empty;
    defer ext_descriptors.deinit(allocator);

    const canonical_base = try canonicalTraceTree(allocator, bundle, bindings.named_base_coefficients, 1);
    defer allocator.free(canonical_base);
    const canonical_interaction = try canonicalTraceTree(allocator, bundle, bindings.named_interaction_coefficients, 2);
    defer allocator.free(canonical_interaction);
    const trees = [_][]const arena_plan.Binding{
        bindings.preprocessed_coefficients,
        canonical_base,
        canonical_interaction,
    };
    const tile_base = try asOffset(bindings.composition_lde_tile);
    const accumulator_base = try asOffset(bindings.composition_accumulators);
    const random_powers = try asOffset(bindings.composition_random_powers);
    const relation_z = try asOffset(bindings.relation_z);
    const relation_alpha = try asOffset(bindings.relation_alpha_powers);

    for (bundle.components, 0..) |component, component_index| {
        var sources = std.ArrayList(arena_plan.Binding).empty;
        defer sources.deinit(allocator);
        for (component.preprocessed_indices) |column| {
            if (column >= trees[0].len) return Error.InvalidBindingSize;
            try sources.append(allocator, trees[0][column]);
        }
        for ([_]u32{ 1, 2 }) |tree| {
            var found = false;
            for (component.trace_spans) |span| {
                if (span.tree != tree) continue;
                if (found or span.start > span.end or span.end > trees[tree].len) return Error.InvalidBindingSize;
                found = true;
                try sources.appendSlice(allocator, trees[tree][span.start..span.end]);
            }
            if (!found) return Error.InvalidBindingSize;
        }
        const row_count = @as(u32, 1) << @intCast(component.evaluation_log_size);
        const source_offsets = try allocator.alloc(u32, sources.items.len);
        defer allocator.free(source_offsets);
        const source_logs = try allocator.alloc(u32, sources.items.len);
        defer allocator.free(source_logs);
        const destination_offsets = try allocator.alloc(u32, sources.items.len);
        defer allocator.free(destination_offsets);
        for (sources.items, source_offsets, source_logs, destination_offsets, 0..) |source, *source_offset, *source_log, *destination, index| {
            source_offset.* = try asOffset(source);
            source_log.* = try bindingLog(source);
            if (source_log.* > component.evaluation_log_size) {
                std.debug.print(
                    "composition source exceeds domain: {s}[{}] local={} source={} log={} evaluation_log={} spans={any}\n",
                    .{ component.label, component.instance, index, source.logical_id, source_log.*, component.evaluation_log_size, component.trace_spans },
                );
                return Error.InvalidBindingSize;
            }
            destination.* = std.math.add(u32, tile_base, @intCast(index * @as(usize, row_count))) catch return Error.InvalidBindingSize;
        }
        if (@as(u64, sources.items.len) * row_count * 4 > bindings.composition_lde_tile.size_bytes)
            return Error.InvalidBindingSize;
        lde_plans[component_index] = try metal.prepareCompositionLde(
            source_offsets,
            source_logs,
            destination_offsets,
            component.evaluation_log_size,
            try twiddleOffsetForLog(bindings.forward_twiddles, component.evaluation_log_size),
        );
        initialized_ldes += 1;

        const trace_offsets_at = descriptor_cursor;
        descriptor_cursor += sources.items.len;
        const interaction_offsets_at = descriptor_cursor;
        descriptor_cursor += 3;
        const denominators_at = descriptor_cursor;
        descriptor_cursor += component.denominator_inverses.len;
        if (descriptor_cursor > descriptor_words.len) return Error.InvalidBindingSize;
        @memcpy(descriptor_words[trace_offsets_at .. trace_offsets_at + sources.items.len], destination_offsets);
        const preprocessed_count = component.preprocessed_indices.len;
        var base_count: usize = 0;
        for (component.trace_spans) |span| {
            if (span.tree == 1) base_count = @intCast(span.end - span.start);
        }
        descriptor_words[interaction_offsets_at] = 0;
        descriptor_words[interaction_offsets_at + 1] = @intCast(preprocessed_count);
        descriptor_words[interaction_offsets_at + 2] = @intCast(preprocessed_count + base_count);
        @memcpy(descriptor_words[denominators_at .. denominators_at + component.denominator_inverses.len], component.denominator_inverses);

        const ext_binding = bindings.composition_ext_params[component_index];
        if (ext_binding.size_bytes < @as(u64, component.ext_sources.len) * 16) return Error.InvalidBindingSize;
        for (component.ext_sources, 0..) |source, slot| {
            const destination = std.math.add(u32, try asOffset(ext_binding), @intCast(slot * 4)) catch return Error.InvalidBindingSize;
            const descriptor: metal_runtime.CompositionExtParamDescriptor = switch (source) {
                .constant => |value| .{ .destination = destination, .kind = 0, .source = 0, .scale = 1, .constant = value },
                .lookup_z => .{ .destination = destination, .kind = 1, .source = relation_z, .scale = 1, .constant = .{ 0, 0, 0, 0 } },
                .lookup_alpha_power => |power| .{ .destination = destination, .kind = 1, .source = relation_alpha + power * 4, .scale = 1, .constant = .{ 0, 0, 0, 0 } },
                .lookup_alpha_power_scaled => |scaled| .{ .destination = destination, .kind = 1, .source = relation_alpha + scaled.power * 4, .scale = scaled.scale, .constant = .{ 0, 0, 0, 0 } },
                .claimed_sum_scaled => blk: {
                    const scale = M31.fromCanonical(@as(u32, 1) << @intCast(component.trace_log_size)).inv() catch return Error.InvalidBindingSize;
                    break :blk .{ .destination = destination, .kind = 1, .source = try asOffset(bindings.relation_claimed_sums[component_index]), .scale = scale.v, .constant = .{ 0, 0, 0, 0 } };
                },
            };
            try ext_descriptors.append(allocator, descriptor);
        }

        const plans = try allocator.alloc(metal_runtime.EvalPlan, component.parts.len);
        defer allocator.free(plans);
        var plans_initialized: usize = 0;
        defer for (plans[0..plans_initialized]) |*plan| plan.deinit();
        const accumulator_relative_offset = accumulator_relative[component.evaluation_log_size] orelse return Error.InvalidBindingSize;
        for (component.parts, plans) |part, *eval_plan| {
            const name = try @import("../../../backends/metal/eval_codegen.zig").kernelName(allocator, part.semantic_hash);
            defer allocator.free(name);
            eval_plan.* = try metal.prepareEvalFromLibrary(library, name, .{
                .trace_offsets = try descriptorWordOffset(bindings.composition_descriptors, trace_offsets_at),
                .interaction_offsets = try descriptorWordOffset(bindings.composition_descriptors, interaction_offsets_at),
                .base_params = 0,
                .ext_params = try asOffset(ext_binding),
                .random_coeffs = random_powers,
                .denom_inv = try descriptorWordOffset(bindings.composition_descriptors, denominators_at),
                .coordinates = .{
                    accumulator_base + accumulator_relative_offset,
                    accumulator_base + accumulator_relative_offset + row_count,
                    accumulator_base + accumulator_relative_offset + row_count * 2,
                    accumulator_base + accumulator_relative_offset + row_count * 3,
                },
                .row_count = row_count,
                .trace_log_size = component.trace_log_size,
                .domain_log_size = component.trace_log_size,
                .rc_base = part.rc_base,
            });
            plans_initialized += 1;
        }
        eval_batches[component_index] = try metal.prepareEvalBatch(plans);
        initialized_batches += 1;
    }

    var inputs = try metal.prepareCompositionInputs(
        ext_descriptors.items,
        try asOffset(try transcriptOutput(bindings.transcript_outputs, 2)),
        random_powers,
        @intCast(bundle.total_constraints),
    );
    defer inputs.deinit();
    var front = try metal.prepareCompositionFront(
        inputs,
        lde_plans,
        eval_batches,
        accumulator_base,
        @intCast(accumulator_words),
    );
    errdefer front.deinit();
    var output_offsets: [8]u32 = undefined;
    var output_bindings: [8]arena_plan.Binding = undefined;
    for (bindings.composition_coefficients, &output_offsets, &output_bindings) |binding, *offset, *output_binding| {
        offset.* = try asOffset(binding);
        output_binding.* = binding;
    }
    const max_rows = @as(u32, 1) << @intCast(bundle.max_evaluation_log_size);
    const scale = M31.fromCanonical(max_rows).inv() catch return Error.InvalidBindingSize;
    var finalize = try metal.prepareCompositionFinalize(
        accumulator_offsets.items,
        accumulator_logs.items,
        try asOffset(bindings.inverse_twiddles),
        output_offsets,
        scale.v,
    );
    errdefer finalize.deinit();
    return protocol_recipes.CompositionRecipe.init(
        allocator,
        metal,
        resident_arena,
        front,
        finalize,
        output_bindings,
    );
}

fn descriptorWordOffset(binding: arena_plan.Binding, relative: usize) !u32 {
    if (binding.offset_bytes % 4 != 0) return Error.InvalidBindingSize;
    return std.math.add(u32, std.math.cast(u32, binding.offset_bytes / 4) orelse return Error.InvalidBindingSize, @intCast(relative)) catch Error.InvalidBindingSize;
}

fn purpose(entry: std.json.Value) ![]const u8 {
    if (entry != .object) return Error.InvalidSchedule;
    const value = entry.object.get("purpose") orelse return Error.InvalidSchedule;
    if (value != .string) return Error.InvalidSchedule;
    return value.string;
}

fn logicalId(entry: std.json.Value) !u32 {
    const value = entry.object.get("id") orelse return Error.InvalidSchedule;
    if (value != .integer or value.integer < 0 or value.integer > std.math.maxInt(u32)) return Error.InvalidSchedule;
    return @intCast(value.integer);
}

fn wordOffset(binding: arena_plan.Binding) !u32 {
    if (binding.offset_bytes % 4 != 0) return Error.InvalidBindingSize;
    return std.math.cast(u32, binding.offset_bytes / 4) orelse Error.InvalidBindingSize;
}

fn twiddleOffsetForLog(binding: arena_plan.Binding, transform_log: u32) !u32 {
    if (transform_log == 0 or binding.offset_bytes % 4 != 0 or binding.size_bytes % 4 != 0)
        return Error.InvalidBindingSize;
    const required_words = @as(u64, 1) << @intCast(transform_log - 1);
    const available_words = binding.size_bytes / 4;
    if (required_words > available_words) return Error.InvalidBindingSize;
    return std.math.cast(u32, binding.offset_bytes / 4 + available_words - required_words) orelse Error.InvalidBindingSize;
}

fn writeBindingOffsets(
    resident_arena: *arena_plan.ResidentArena,
    destination: arena_plan.Binding,
    sources: []const arena_plan.Binding,
) !void {
    const bytes = try resident_arena.bytes(destination);
    if (bytes.len % 4 != 0 or bytes.len < sources.len * 4) return Error.InvalidBindingSize;
    const aligned: []align(4) u8 = @alignCast(bytes);
    const words = std.mem.bytesAsSlice(u32, aligned);
    @memset(words, 0);
    for (sources, words[0..sources.len]) |source, *offset| offset.* = try wordOffset(source);
}

fn oneComponent(
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    name: []const u8,
    component: []const u8,
) !arena_plan.Binding {
    var found: ?arena_plan.Binding = null;
    for (schedule) |entry| {
        if (!std.mem.eql(u8, try purpose(entry), name) or
            !std.mem.eql(u8, try componentName(entry), component)) continue;
        if (found != null) return Error.DuplicateBinding;
        found = plan.binding(try logicalId(entry)) catch return Error.MissingBinding;
    }
    return found orelse Error.MissingBinding;
}

fn oneComponentOrdinal(
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    name: []const u8,
    component: []const u8,
    wanted_ordinal: u32,
) !arena_plan.Binding {
    var found: ?arena_plan.Binding = null;
    for (schedule) |entry| {
        if (!std.mem.eql(u8, try purpose(entry), name) or
            !std.mem.eql(u8, try componentName(entry), component) or
            try ordinal(entry) != wanted_ordinal) continue;
        if (found != null) return Error.DuplicateBinding;
        found = plan.binding(try logicalId(entry)) catch return Error.MissingBinding;
    }
    return found orelse Error.MissingBinding;
}

fn collectComponent(
    allocator: std.mem.Allocator,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    name: []const u8,
    component: []const u8,
) ![]arena_plan.Binding {
    var ordered = std.ArrayList(OrderedBinding).empty;
    defer ordered.deinit(allocator);
    for (schedule) |entry| {
        if (!std.mem.eql(u8, try purpose(entry), name) or
            !std.mem.eql(u8, try componentName(entry), component)) continue;
        try ordered.append(allocator, .{
            .ordinal = try ordinal(entry),
            .binding = plan.binding(try logicalId(entry)) catch return Error.MissingBinding,
        });
    }
    if (ordered.items.len == 0) return Error.MissingBinding;
    std.mem.sortUnstable(OrderedBinding, ordered.items, {}, struct {
        fn lessThan(_: void, lhs: OrderedBinding, rhs: OrderedBinding) bool {
            return lhs.ordinal < rhs.ordinal;
        }
    }.lessThan);
    for (ordered.items, 0..) |item, index| if (item.ordinal != index) return Error.InvalidSchedule;
    const result = try allocator.alloc(arena_plan.Binding, ordered.items.len);
    for (ordered.items, result) |item, *binding| binding.* = item.binding;
    return result;
}

fn writePreprocessedOffsets(
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    fixed_bundle: fixed_table_bundle_mod.Bundle,
    identities: []const []u8,
    destination: arena_plan.Binding,
) !void {
    const sources = try fixed_bundle.allocator.alloc(arena_plan.Binding, identities.len);
    defer fixed_bundle.allocator.free(sources);
    for (identities, sources) |identity, *source| {
        const wanted = fixed_bundle.identityOrdinal(identity) orelse return Error.MissingBinding;
        source.* = try oneOrdinal(schedule, plan, "PreprocessedEvaluations", wanted);
    }
    try writeBindingOffsets(resident_arena, destination, sources);
}

fn ordinal(entry: std.json.Value) !u32 {
    const value = entry.object.get("ordinal") orelse return 0;
    if (value != .integer or value.integer < 0 or value.integer > std.math.maxInt(u32)) return Error.InvalidSchedule;
    return @intCast(value.integer);
}

fn one(schedule: []const std.json.Value, plan: arena_plan.Plan, name: []const u8) !arena_plan.Binding {
    var found: ?arena_plan.Binding = null;
    for (schedule) |entry| {
        if (!std.mem.eql(u8, try purpose(entry), name)) continue;
        if (found != null) return Error.DuplicateBinding;
        found = plan.binding(try logicalId(entry)) catch return Error.MissingBinding;
    }
    return found orelse Error.MissingBinding;
}

const OrderedBinding = struct { ordinal: u32, binding: arena_plan.Binding };

fn collectOrdinals(
    allocator: std.mem.Allocator,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    name: []const u8,
) ![]OrdinalBinding {
    const bindings = try collect(allocator, schedule, plan, name);
    errdefer allocator.free(bindings);
    var ordinals = std.ArrayList(u32).empty;
    defer ordinals.deinit(allocator);
    for (schedule) |entry| if (std.mem.eql(u8, try purpose(entry), name)) try ordinals.append(allocator, try ordinal(entry));
    std.mem.sortUnstable(u32, ordinals.items, {}, std.sort.asc(u32));
    if (ordinals.items.len != bindings.len) return Error.InvalidCardinality;
    const result = try allocator.alloc(OrdinalBinding, bindings.len);
    for (bindings, ordinals.items, result) |binding, binding_ordinal, *item| item.* = .{ .ordinal = binding_ordinal, .binding = binding };
    allocator.free(bindings);
    return result;
}

fn collectScheduleOrder(
    allocator: std.mem.Allocator,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    name: []const u8,
) ![]arena_plan.Binding {
    var result = std.ArrayList(arena_plan.Binding).empty;
    errdefer result.deinit(allocator);
    for (schedule) |entry| {
        if (std.mem.eql(u8, try purpose(entry), name))
            try result.append(allocator, plan.binding(try logicalId(entry)) catch return Error.MissingBinding);
    }
    if (result.items.len == 0) return Error.MissingBinding;
    return result.toOwnedSlice(allocator);
}

fn collectCommitmentOrder(
    allocator: std.mem.Allocator,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    name: []const u8,
) ![]arena_plan.Binding {
    const Item = struct { schedule_index: usize, binding: arena_plan.Binding };
    var items = std.ArrayList(Item).empty;
    defer items.deinit(allocator);
    for (schedule, 0..) |entry, schedule_index| {
        if (std.mem.eql(u8, try purpose(entry), name)) try items.append(allocator, .{
            .schedule_index = schedule_index,
            .binding = plan.binding(try logicalId(entry)) catch return Error.MissingBinding,
        });
    }
    if (items.items.len == 0) return Error.MissingBinding;
    std.mem.sortUnstable(Item, items.items, {}, struct {
        fn lessThan(_: void, lhs: Item, rhs: Item) bool {
            if (lhs.binding.size_bytes != rhs.binding.size_bytes) return lhs.binding.size_bytes > rhs.binding.size_bytes;
            return lhs.schedule_index < rhs.schedule_index;
        }
    }.lessThan);
    const result = try allocator.alloc(arena_plan.Binding, items.items.len);
    for (items.items, result) |item, *binding| binding.* = item.binding;
    return result;
}

fn componentName(entry: std.json.Value) ![]const u8 {
    if (entry != .object) return Error.InvalidSchedule;
    const value = entry.object.get("component") orelse return Error.InvalidSchedule;
    if (value != .string or value.string.len == 0) return Error.InvalidSchedule;
    return value.string;
}

/// Preserve capture order here. Several Cairo component families have multiple
/// instances whose column ordinals restart at zero, and the capture records
/// those instances consecutively under the same component label.
fn collectNamed(
    allocator: std.mem.Allocator,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    name: []const u8,
) ![]NamedBinding {
    var result = std.ArrayList(NamedBinding).empty;
    errdefer result.deinit(allocator);
    for (schedule) |entry| {
        if (!std.mem.eql(u8, try purpose(entry), name)) continue;
        try result.append(allocator, .{
            .component = try componentName(entry),
            .ordinal = try ordinal(entry),
            .binding = plan.binding(try logicalId(entry)) catch return Error.MissingBinding,
        });
    }
    if (result.items.len == 0) return Error.MissingBinding;
    return result.toOwnedSlice(allocator);
}

fn canonicalTraceTree(
    allocator: std.mem.Allocator,
    bundle: composition_bundle_mod.Bundle,
    named: []const NamedBinding,
    tree_index: u32,
) ![]arena_plan.Binding {
    var column_count: usize = 0;
    for (bundle.components) |component| {
        var found = false;
        for (component.trace_spans) |span| {
            if (span.tree != tree_index) continue;
            if (found or span.start > span.end) return Error.InvalidBindingSize;
            found = true;
            column_count = @max(column_count, span.end);
        }
        if (!found) return Error.InvalidBindingSize;
    }
    if (column_count != named.len) return Error.InvalidCardinality;

    const result = try allocator.alloc(arena_plan.Binding, column_count);
    errdefer allocator.free(result);
    var assigned = try allocator.alloc(bool, column_count);
    defer allocator.free(assigned);
    @memset(assigned, false);

    var cursors = std.StringHashMap(usize).init(allocator);
    defer cursors.deinit();
    for (bundle.components) |component| {
        const captured_label = if (std.mem.eql(u8, component.label, "memory_id_to_small"))
            "memory_id_to_big"
        else
            component.label;
        var wanted: ?composition_bundle_mod.TraceSpan = null;
        for (component.trace_spans) |span| {
            if (span.tree != tree_index) continue;
            if (wanted != null) return Error.InvalidBindingSize;
            wanted = span;
        }
        const span = wanted orelse return Error.InvalidBindingSize;
        const count: usize = span.end - span.start;
        const skipped = cursors.get(captured_label) orelse 0;
        var seen: usize = 0;
        var copied: usize = 0;
        for (named) |item| {
            if (!std.mem.eql(u8, item.component, captured_label)) continue;
            if (seen < skipped) {
                seen += 1;
                continue;
            }
            if (copied == count) break;
            if (item.ordinal != copied) return Error.InvalidSchedule;
            const destination: usize = span.start + copied;
            if (destination >= result.len or assigned[destination]) return Error.DuplicateBinding;
            result[destination] = item.binding;
            assigned[destination] = true;
            copied += 1;
            seen += 1;
        }
        if (copied != count) {
            std.debug.print(
                "canonical tree {} missing {s}[{}]: span={}..{} skipped={} copied={}\n",
                .{ tree_index, component.label, component.instance, span.start, span.end, skipped, copied },
            );
            return Error.MissingBinding;
        }
        try cursors.put(captured_label, skipped + count);
    }
    for (assigned) |present| if (!present) return Error.MissingBinding;
    for (named) |item| {
        const consumed = cursors.get(item.component) orelse 0;
        var available: usize = 0;
        for (named) |candidate| if (std.mem.eql(u8, candidate.component, item.component)) {
            available += 1;
        };
        if (consumed != available) return Error.InvalidCardinality;
    }
    return result;
}

fn collect(
    allocator: std.mem.Allocator,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    name: []const u8,
) ![]arena_plan.Binding {
    var ordered = std.ArrayList(OrderedBinding).empty;
    defer ordered.deinit(allocator);
    for (schedule) |entry| {
        if (!std.mem.eql(u8, try purpose(entry), name)) continue;
        try ordered.append(allocator, .{
            .ordinal = try ordinal(entry),
            .binding = plan.binding(try logicalId(entry)) catch return Error.MissingBinding,
        });
    }
    if (ordered.items.len == 0) return Error.MissingBinding;
    std.mem.sortUnstable(OrderedBinding, ordered.items, {}, struct {
        fn lessThan(_: void, lhs: OrderedBinding, rhs: OrderedBinding) bool {
            if (lhs.ordinal != rhs.ordinal) return lhs.ordinal < rhs.ordinal;
            return lhs.binding.logical_id < rhs.binding.logical_id;
        }
    }.lessThan);
    for (ordered.items[1..], ordered.items[0 .. ordered.items.len - 1]) |current, previous| {
        if (current.ordinal == previous.ordinal) return Error.DuplicateBinding;
    }
    const result = try allocator.alloc(arena_plan.Binding, ordered.items.len);
    for (ordered.items, result) |item, *binding| binding.* = item.binding;
    return result;
}

fn collectAssembly(
    allocator: std.mem.Allocator,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
) ![]arena_plan.Binding {
    var result = std.ArrayList(arena_plan.Binding).empty;
    errdefer result.deinit(allocator);
    for (schedule) |entry| {
        const name = try purpose(entry);
        if (!std.mem.startsWith(u8, name, "Decommit") and
            !std.mem.startsWith(u8, name, "Transcript") and
            !std.mem.startsWith(u8, name, "Pow") and
            !std.mem.eql(u8, name, "ProofBytes")) continue;
        try result.append(allocator, plan.binding(try logicalId(entry)) catch return Error.MissingBinding);
    }
    if (result.items.len == 0) return Error.MissingBinding;
    return result.toOwnedSlice(allocator);
}

fn oneOrdinal(
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    name: []const u8,
    wanted_ordinal: u32,
) !arena_plan.Binding {
    var found: ?arena_plan.Binding = null;
    for (schedule) |entry| {
        if (!std.mem.eql(u8, try purpose(entry), name) or try ordinal(entry) != wanted_ordinal) continue;
        if (found != null) return Error.DuplicateBinding;
        found = plan.binding(try logicalId(entry)) catch return Error.MissingBinding;
    }
    return found orelse Error.MissingBinding;
}

fn collectTreePurpose(
    allocator: std.mem.Allocator,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    name: []const u8,
    tree_index: u32,
) ![]arena_plan.Binding {
    const Item = struct { ordinal_value: u32, binding: arena_plan.Binding };
    var items = std.ArrayList(Item).empty;
    defer items.deinit(allocator);
    for (schedule) |entry| {
        if (!std.mem.eql(u8, try purpose(entry), name)) continue;
        const ordinal_value = try ordinal(entry);
        if (ordinal_value >> 20 != tree_index) continue;
        try items.append(allocator, .{ .ordinal_value = ordinal_value, .binding = plan.binding(try logicalId(entry)) catch return Error.MissingBinding });
    }
    if (items.items.len == 0) return Error.MissingBinding;
    std.mem.sortUnstable(Item, items.items, {}, struct {
        fn lessThan(_: void, lhs: Item, rhs: Item) bool { return lhs.ordinal_value < rhs.ordinal_value; }
    }.lessThan);
    const result = try allocator.alloc(arena_plan.Binding, items.items.len);
    for (items.items, result) |item, *binding| binding.* = item.binding;
    return result;
}

fn executeStreamingCommitment(
    allocator: std.mem.Allocator,
    metal: *metal_runtime.Runtime,
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    coefficients: []const arena_plan.Binding,
    tree_index: u32,
    leaf_seed: [8]u32,
    node_seed: [8]u32,
) !CommitmentTelemetry {
    const group_descriptors = try collectTreePurpose(allocator, schedule, plan, "CommitColumnLogSizes", tree_index);
    defer allocator.free(group_descriptors);
    const tile_items = try collectTreePurpose(allocator, schedule, plan, "CommitLdeTile", tree_index);
    defer allocator.free(tile_items);
    const leaf_items = try collectTreePurpose(allocator, schedule, plan, "MerkleLeafState", tree_index);
    defer allocator.free(leaf_items);
    if (tile_items.len != 1 or leaf_items.len != 1) return Error.InvalidCardinality;
    const tile = tile_items[0];
    const leaf_state = leaf_items[0];
    const scratch_items = collectTreePurpose(allocator, schedule, plan, "MerkleLayerScratch", tree_index) catch &[_]arena_plan.Binding{};
    defer if (scratch_items.len != 0) allocator.free(scratch_items);
    const retained = try collectTreePurpose(allocator, schedule, plan, "RetainedMerkleLayers", tree_index);
    defer allocator.free(retained);
    if (leaf_state.size_bytes % 32 != 0 or !std.math.isPowerOfTwo(leaf_state.size_bytes / 32)) return Error.InvalidBindingSize;
    const lifting_log: u32 = std.math.log2_int(u64, leaf_state.size_bytes / 32);
    const twiddles = try one(schedule, plan, "ForwardTwiddles");
    var coefficient_cursor: usize = 0;
    var gpu_ms: f64 = 0;
    for (group_descriptors, 0..) |descriptor, group_index| {
        const width = std.math.cast(usize, descriptor.size_bytes / 4) orelse return Error.InvalidBindingSize;
        if (width == 0 or width > 16 or coefficient_cursor + width > coefficients.len) return Error.InvalidCardinality;
        const group = coefficients[coefficient_cursor .. coefficient_cursor + width];
        var output_offsets: [16]u32 = undefined;
        var output_logs: [16]u32 = undefined;
        var tile_cursor: u64 = 0;
        for (group, 0..) |source, index| {
            if (source.size_bytes < 64 or !std.math.isPowerOfTwo(source.size_bytes / 4)) return Error.InvalidBindingSize;
            const coefficient_log: u32 = std.math.log2_int(u64, source.size_bytes / 4);
            const evaluation_log = coefficient_log + 1;
            const evaluation_words = @as(u64, 1) << @intCast(evaluation_log);
            if (tile_cursor + evaluation_words > tile.size_bytes / 4) return Error.InvalidBindingSize;
            output_offsets[index] = std.math.cast(u32, tile.offset_bytes / 4 + tile_cursor) orelse return Error.InvalidBindingSize;
            output_logs[index] = evaluation_log;
            tile_cursor += evaluation_words;
        }
        for (4..lifting_log + 1) |evaluation_log_usize| {
            const evaluation_log: u32 = @intCast(evaluation_log_usize);
            var sources = std.ArrayList(u32).empty;
            defer sources.deinit(allocator);
            var logs = std.ArrayList(u32).empty;
            defer logs.deinit(allocator);
            var outputs = std.ArrayList(u32).empty;
            defer outputs.deinit(allocator);
            for (group, output_offsets[0..width], output_logs[0..width]) |source, output, log_size| {
                if (log_size != evaluation_log) continue;
                try sources.append(allocator, try wordOffset(source));
                try logs.append(allocator, std.math.log2_int(u64, source.size_bytes / 4));
                try outputs.append(allocator, output);
            }
            if (sources.items.len == 0) continue;
            var lde = try metal.prepareCompositionLde(sources.items, logs.items, outputs.items, evaluation_log, try twiddleOffsetForLog(twiddles, evaluation_log));
            defer lde.deinit();
            gpu_ms += try metal.compositionLdePrepared(resident_arena.buffer, lde);
        }
        gpu_ms += try metal.leafAbsorb(
            resident_arena.buffer, output_offsets[0..width], output_logs[0..width], try wordOffset(leaf_state),
            lifting_log, @intCast(coefficient_cursor), group_index + 1 == group_descriptors.len, 0, leaf_seed,
        );
        coefficient_cursor += width;
    }
    if (coefficient_cursor != coefficients.len) return Error.InvalidCardinality;

    const bottom_hashes = retained[0].size_bytes / 32;
    var child_offsets = std.ArrayList(u32).empty;
    defer child_offsets.deinit(allocator);
    var destination_offsets = std.ArrayList(u32).empty;
    defer destination_offsets.deinit(allocator);
    var parent_counts = std.ArrayList(u32).empty;
    defer parent_counts.deinit(allocator);
    var current_offset = try wordOffset(leaf_state);
    var current_hashes = leaf_state.size_bytes / 32;
    var ping_is_leaf = true;
    while (current_hashes > bottom_hashes) {
        const next_hashes = current_hashes / 2;
        const destination = if (next_hashes == bottom_hashes)
            try wordOffset(retained[0])
        else blk: {
            if (scratch_items.len == 0) return Error.MissingBinding;
            ping_is_leaf = !ping_is_leaf;
            break :blk try wordOffset(if (ping_is_leaf) leaf_state else scratch_items[0]);
        };
        try child_offsets.append(allocator, current_offset);
        try destination_offsets.append(allocator, destination);
        try parent_counts.append(allocator, @intCast(next_hashes));
        current_offset = destination;
        current_hashes = next_hashes;
    }
    for (retained[1..]) |layer| {
        try child_offsets.append(allocator, current_offset);
        try destination_offsets.append(allocator, try wordOffset(layer));
        try parent_counts.append(allocator, @intCast(layer.size_bytes / 32));
        current_offset = try wordOffset(layer);
    }
    _ = node_seed;
    for (child_offsets.items, destination_offsets.items, parent_counts.items) |child, destination, count|
        gpu_ms += try metal.parentPlain(resident_arena.buffer, child, destination, count);
    const root = retained[retained.len - 1];
    const transcript_ordinals = [_]u32{ 3, 20, 23, 24 };
    const transcript_root = try oneOrdinal(schedule, plan, "TranscriptInput", transcript_ordinals[tree_index]);
    @memcpy((try resident_arena.bytes(transcript_root))[0..32], (try resident_arena.bytes(root))[0..32]);
    return .{ .gpu_ms = gpu_ms, .root = root };
}

fn buildProofCopies(
    allocator: std.mem.Allocator,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
) ![]ProofCopy {
    var copies = std.ArrayList(ProofCopy).empty;
    errdefer copies.deinit(allocator);
    var cursor: u32 = 0;
    const append = struct {
        fn binding(list: *std.ArrayList(ProofCopy), alloc: std.mem.Allocator, position: *u32, source: arena_plan.Binding) !void {
            if (source.size_bytes % 4 != 0 or source.size_bytes / 4 > std.math.maxInt(u32)) return Error.InvalidBindingSize;
            const words: u32 = @intCast(source.size_bytes / 4);
            try list.append(alloc, .{ .source = source, .destination_word_offset = position.*, .word_count = words });
            position.* = std.math.add(u32, position.*, words) catch return Error.InvalidBindingSize;
        }
    }.binding;
    for ([_]u32{ 3, 20, 23, 24 }) |input| try append(&copies, allocator, &cursor, try oneOrdinal(schedule, plan, "TranscriptInput", input));
    try append(&copies, allocator, &cursor, try oneOrdinal(schedule, plan, "TranscriptInput", 22));
    try append(&copies, allocator, &cursor, try oneOrdinal(schedule, plan, "TranscriptInput", 21));
    try append(&copies, allocator, &cursor, try oneOrdinal(schedule, plan, "TranscriptInput", 25));
    for (0..8) |tree| {
        try append(&copies, allocator, &cursor, try oneOrdinal(
            schedule,
            plan,
            "TranscriptInput",
            65536 + @as(u32, @intCast(tree)) * 4,
        ));
    }
    try append(&copies, allocator, &cursor, try oneOrdinal(schedule, plan, "TranscriptInput", 30));
    try append(&copies, allocator, &cursor, try oneOrdinal(schedule, plan, "TranscriptInput", 31));
    try append(&copies, allocator, &cursor, try one(schedule, plan, "DecommitAssembly"));
    return copies.toOwnedSlice(allocator);
}
