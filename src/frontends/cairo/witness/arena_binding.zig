const std = @import("std");
const arena_plan = @import("../../../backends/metal/arena_plan.zig");
const metal_runtime = @import("../../../backends/metal/runtime.zig");
const protocol_recipes = @import("../../../backends/metal/protocol_recipes.zig");
const composition_bundle_mod = @import("composition_bundle.zig");
const fixed_table_bundle_mod = @import("fixed_table_bundle.zig");
const witness_bundle_mod = @import("bundle.zig");
const witness_codegen = @import("../../../backends/metal/witness_codegen.zig");
const M31 = @import("../../../core/fields/m31.zig").M31;

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
            try asOffset(bindings.forward_twiddles),
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
