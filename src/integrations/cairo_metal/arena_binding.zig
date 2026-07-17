//! Cairo proving orchestration over the resident Metal arena.

const std = @import("std");
const arena_plan = @import("../../backends/metal/arena_plan.zig");
const schedule_bindings = @import("schedule_bindings.zig");
const metal_runtime = @import("../../backends/metal/runtime.zig");
const protocol_recipes = @import("../../backends/metal/protocol_recipes.zig");
const transcript_fixture = @import("../../backends/metal/cairo/diagnostics/transcript_fixture.zig");
const composition_bundle_mod = @import("../../frontends/cairo/witness/composition_bundle.zig");
const fixed_table_bundle_mod = @import("../../frontends/cairo/witness/fixed_table_bundle.zig");
const feed_bundle_mod = @import("../../frontends/cairo/witness/feed_bundle.zig");
const relation_bundle_mod = @import("../../frontends/cairo/witness/relation_bundle.zig");
const witness_bundle_mod = @import("../../frontends/cairo/witness/bundle.zig");
const witness_program_mod = @import("../../frontends/cairo/witness/program.zig");
const witness_codegen = @import("witness_codegen.zig");
const eval_codegen = @import("eval_codegen.zig");
const cairo_adapter = @import("../../frontends/cairo/adapter/mod.zig");
const cairo_opcodes = @import("../../frontends/cairo/adapter/opcodes.zig");
const cairo_proof_plan = @import("../../frontends/cairo/proof_plan.zig");
const witness_scheduler = @import("../../frontends/cairo/witness_scheduler.zig");
const recipe_requirements = @import("recipe_requirements.zig");
const commitment_telemetry = @import("resident/commitment/telemetry.zig");
const resident_twiddles = @import("resident/twiddles.zig");
const M31 = @import("../../core/fields/m31.zig").M31;
const QM31 = @import("../../core/fields/qm31.zig").QM31;
const circle_poly_mod = @import("../../prover/poly/circle/poly.zig");
const circle_eval_mod = @import("../../prover/poly/circle/evaluation.zig");
const canonic_circle_mod = @import("../../core/poly/circle/canonic.zig");
const CairoMerkleHasher = @import("../../core/vcs_lifted/blake2_merkle.zig").Blake2sPlainMerkleHasher;

const cairo_domain_prefix_bytes = CairoMerkleHasher.domainPrefixBytes();

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
    InvalidBindingAlias,
    TranscriptBootstrapStatementMismatch,
    TranscriptBootstrapCommitmentMismatch,
};

pub const Sn2Counts = schedule_bindings.Sn2Counts;
pub const WitnessRecipeRequirements = recipe_requirements.Requirements;

pub const WitnessRecipes = struct {
    compact_verify: ?*protocol_recipes.CompactRecipe = null,
    compact_pedersen: ?*protocol_recipes.CompactRecipe = null,
    compact_poseidon: ?*protocol_recipes.CompactRecipe = null,
    ec_op: ?*protocol_recipes.EcOpRecipe = null,

    pub fn validate(self: WitnessRecipes, required: WitnessRecipeRequirements) Error!void {
        if (required.verify_instruction and self.compact_verify == null or
            required.pedersen and self.compact_pedersen == null or
            required.poseidon and self.compact_poseidon == null or
            required.ec_op and self.ec_op == null)
            return Error.MissingBinding;
        if (!required.verify_instruction and self.compact_verify != null or
            !required.pedersen and self.compact_pedersen != null or
            !required.poseidon and self.compact_poseidon != null or
            !required.ec_op and self.ec_op != null)
            return Error.InvalidSchedule;
    }
};

pub const ProofCopy = struct {
    source: arena_plan.Binding,
    destination_word_offset: u32,
    word_count: u32,
};

pub const CommitmentTelemetry = struct {
    gpu_ms: f64,
    lde_gpu_ms: f64,
    leaf_gpu_ms: f64,
    parent_gpu_ms: f64,
    root: arena_plan.Binding,
    command_epoch_stats: ?metal_runtime.CommandEpochStats = null,
};

pub const OrdinalBinding = schedule_bindings.OrdinalBinding;
pub const NamedBinding = schedule_bindings.NamedBinding;

pub const DecommitTraceCoefficientBindings = schedule_bindings.DecommitTraceCoefficientBindings;
pub const DecommitTraceGroupBindings = schedule_bindings.DecommitTraceGroupBindings;
pub const DecommitTraceTreeBindings = schedule_bindings.DecommitTraceTreeBindings;
pub const DecommitFriTreeBindings = schedule_bindings.DecommitFriTreeBindings;
pub const TraceTreeRole = schedule_bindings.TraceTreeRole;
pub const TraceTreeGeometry = schedule_bindings.TraceTreeGeometry;
pub const FriTreeGeometry = schedule_bindings.FriTreeGeometry;
pub const ProofDecommitGeometry = schedule_bindings.ProofDecommitGeometry;

const collectDecommitBindings = schedule_bindings.collectDecommitBindings;
const collectSn2DecommitBindings = schedule_bindings.collectSn2DecommitBindings;
const friStartLog = schedule_bindings.friStartLog;

const NamedGroupRange = schedule_bindings.NamedGroupRange;
const purpose = schedule_bindings.purpose;
const logicalId = schedule_bindings.logicalId;
const ordinal = schedule_bindings.ordinal;
const componentName = schedule_bindings.componentName;
const one = schedule_bindings.one;
const oneOrdinal = schedule_bindings.oneOrdinal;
const oneComponent = schedule_bindings.oneComponent;
const oneComponentOrdinal = schedule_bindings.oneComponentOrdinal;
const collect = schedule_bindings.collect;
const collectOrdinals = schedule_bindings.collectOrdinals;
const collectScheduleOrder = schedule_bindings.collectScheduleOrder;
const collectComponent = schedule_bindings.collectComponent;
const collectComponentBindingGroups = schedule_bindings.collectComponentBindingGroups;
const collectNamed = schedule_bindings.collectNamed;
const namedGroupRanges = schedule_bindings.namedGroupRanges;

fn countFixedRelationTraces(traces: []const relation_bundle_mod.Trace) usize {
    var count: usize = 0;
    for (traces) |trace| count += switch (trace.part) {
        .component, .memory_small => 1,
        .each_memory_big => 0,
    };
    return count;
}

fn relationTraceUsesRowEnabler(trace: relation_bundle_mod.Trace) bool {
    var descriptor_index: usize = 0;
    while (descriptor_index < trace.descriptors.len) : (descriptor_index += 16) {
        const descriptor = trace.descriptors[descriptor_index .. descriptor_index + 16];
        for (0..descriptor[0]) |use_index| {
            if (descriptor[1 + use_index * 7 + 4] == 1) return true;
        }
    }
    return false;
}

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
    /// Degree-sorted column order consumed by tree-1 commitment/decommitment.
    base_coefficients: []arena_plan.Binding,
    /// Degree-sorted column order consumed by tree-2 commitment/decommitment.
    interaction_coefficients: []arena_plan.Binding,
    /// Global AIR trace-span order consumed by composition, OODS, and quotient masks.
    canonical_base_coefficients: []arena_plan.Binding,
    /// Global AIR trace-span order consumed by composition, OODS, and quotient masks.
    canonical_interaction_coefficients: []arena_plan.Binding,
    named_base_coefficients: []NamedBinding,
    named_interaction_coefficients: []NamedBinding,
    composition_ext_params: []arena_plan.Binding,
    relation_claimed_sums: []arena_plan.Binding,
    canonical_claimed_sums: []arena_plan.Binding,
    relation_alpha_powers: arena_plan.Binding,
    relation_z: arena_plan.Binding,
    relation_scan_scratch: arena_plan.Binding,
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
    decommit_trace_lde_tile: arena_plan.Binding,
    decommit_trace_groups: []DecommitTraceGroupBindings,
    decommit_trace_trees: []DecommitTraceTreeBindings,
    decommit_fri_trees: []DecommitFriTreeBindings,
    proof_bytes: arena_plan.Binding,
    proof_copies: []ProofCopy,
    assembly: []arena_plan.Binding,

    pub fn initSn2(
        allocator: std.mem.Allocator,
        schedule: []const std.json.Value,
        plan: arena_plan.Plan,
        composition_bundle: composition_bundle_mod.Bundle,
        relation_bundle: relation_bundle_mod.Bundle,
    ) !PreparedProofBindings {
        return initInternal(allocator, schedule, plan, composition_bundle, relation_bundle, null);
    }

    /// Binds the schedule to authenticated runtime proof geometry. The caller
    /// must supply the exact tree metadata committed by its proof bundle.
    pub fn init(
        allocator: std.mem.Allocator,
        schedule: []const std.json.Value,
        plan: arena_plan.Plan,
        composition_bundle: composition_bundle_mod.Bundle,
        relation_bundle: relation_bundle_mod.Bundle,
        geometry: ProofDecommitGeometry,
    ) !PreparedProofBindings {
        try geometry.validate();
        return initInternal(allocator, schedule, plan, composition_bundle, relation_bundle, geometry);
    }

    fn initInternal(
        allocator: std.mem.Allocator,
        schedule: []const std.json.Value,
        plan: arena_plan.Plan,
        composition_bundle: composition_bundle_mod.Bundle,
        relation_bundle: relation_bundle_mod.Bundle,
        geometry: ?ProofDecommitGeometry,
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
        const proof_copies = try buildProofCopies(
            allocator,
            schedule,
            plan,
            if (geometry) |runtime_geometry|
                runtime_geometry.fri_trees.len
            else
                Sn2Counts.decommit_fri_trees,
        );
        errdefer allocator.free(proof_copies);
        const transcript_inputs = try collectOrdinals(allocator, schedule, plan, "TranscriptInput");
        errdefer allocator.free(transcript_inputs);
        const transcript_outputs = try collectOrdinals(allocator, schedule, plan, "TranscriptOutput");
        errdefer allocator.free(transcript_outputs);
        var decommit_raw_queries: ?arena_plan.Binding = null;
        for (transcript_outputs) |output| {
            if (output.ordinal == 5) decommit_raw_queries = output.binding;
        }
        const preprocessed_coefficients = try collectCommitmentOrder(allocator, schedule, plan, "PreprocessedCoefficients");
        errdefer allocator.free(preprocessed_coefficients);
        const named_base_coefficients = try collectNamed(allocator, schedule, plan, "BaseCoefficients");
        errdefer allocator.free(named_base_coefficients);
        const named_interaction_coefficients = try collectNamed(allocator, schedule, plan, "InteractionCoefficients");
        errdefer allocator.free(named_interaction_coefficients);
        const canonical_base_coefficients = try canonicalTraceTree(
            allocator,
            composition_bundle,
            named_base_coefficients,
            1,
        );
        errdefer allocator.free(canonical_base_coefficients);
        const base_coefficients = try commitmentOrderCopy(allocator, canonical_base_coefficients);
        errdefer allocator.free(base_coefficients);
        const canonical_interaction_coefficients = try canonicalTraceTree(
            allocator,
            composition_bundle,
            named_interaction_coefficients,
            2,
        );
        errdefer allocator.free(canonical_interaction_coefficients);
        const interaction_coefficients = try commitmentOrderCopy(allocator, canonical_interaction_coefficients);
        errdefer allocator.free(interaction_coefficients);
        const composition_ext_params = try collect(allocator, schedule, plan, "CompositionExtParams");
        errdefer allocator.free(composition_ext_params);
        const relation_claimed_sums = try collect(allocator, schedule, plan, "RelationClaimedSum");
        errdefer allocator.free(relation_claimed_sums);
        const canonical_claimed_sums = try canonicalClaimedSumBindings(
            allocator,
            composition_bundle,
            relation_bundle,
            relation_claimed_sums,
        );
        errdefer allocator.free(canonical_claimed_sums);
        var decommit_bindings = if (geometry) |runtime_geometry|
            try collectDecommitBindings(allocator, schedule, plan, runtime_geometry)
        else
            try collectSn2DecommitBindings(allocator, schedule, plan);
        errdefer decommit_bindings.deinit(allocator);
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
            .canonical_base_coefficients = canonical_base_coefficients,
            .canonical_interaction_coefficients = canonical_interaction_coefficients,
            .named_base_coefficients = named_base_coefficients,
            .named_interaction_coefficients = named_interaction_coefficients,
            .composition_ext_params = composition_ext_params,
            .relation_claimed_sums = relation_claimed_sums,
            .canonical_claimed_sums = canonical_claimed_sums,
            .relation_alpha_powers = try one(schedule, plan, "RelationAlphaPowers"),
            .relation_z = try one(schedule, plan, "RelationZ"),
            .relation_scan_scratch = try one(schedule, plan, "RelationScanEvalScratch"),
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
            .decommit_trace_lde_tile = try one(schedule, plan, "DecommitTraceLdeTile"),
            .decommit_trace_groups = decommit_bindings.trace_groups,
            .decommit_trace_trees = decommit_bindings.trace_trees,
            .decommit_fri_trees = decommit_bindings.fri_trees,
            .proof_bytes = try one(schedule, plan, "ProofBytes"),
            .proof_copies = proof_copies,
            .assembly = assembly,
        };
        if (geometry) |runtime_geometry|
            try result.validate(runtime_geometry)
        else
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
        self.allocator.free(self.canonical_base_coefficients);
        self.allocator.free(self.canonical_interaction_coefficients);
        self.allocator.free(self.named_base_coefficients);
        self.allocator.free(self.named_interaction_coefficients);
        self.allocator.free(self.composition_ext_params);
        self.allocator.free(self.relation_claimed_sums);
        self.allocator.free(self.canonical_claimed_sums);
        self.allocator.free(self.decommit_trace_groups);
        self.allocator.free(self.decommit_trace_trees);
        self.allocator.free(self.decommit_fri_trees);
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
        return protocol_recipes.FriRecipe.initWithGeometry(
            metal,
            resident_arena,
            try self.runtimeFriGeometry(),
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
            try friStartLog(self.quotient_tile),
            inputs,
            outputs,
        );
    }

    pub fn prepareDecommitQueries(
        self: PreparedProofBindings,
        metal: *metal_runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
    ) !protocol_recipes.DecommitQueryRecipe {
        const tree_count = std.math.add(usize, self.decommit_trace_trees.len, self.decommit_fri_trees.len) catch
            return Error.InvalidCardinality;
        return protocol_recipes.DecommitQueryRecipe.initWithGeometry(
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
            std.math.cast(u32, tree_count) orelse return Error.InvalidCardinality,
            try self.runtimeFriGeometry(),
        );
    }

    pub fn decommitTraceTree(self: PreparedProofBindings, tree_index: u32) !DecommitTraceTreeBindings {
        if (tree_index >= self.decommit_trace_trees.len) return Error.InvalidCardinality;
        const tree = self.decommit_trace_trees[tree_index];
        if (tree.tree_index != tree_index or @intFromEnum(tree.role) != tree_index)
            return Error.InvalidSchedule;
        return tree;
    }

    pub fn decommitFriTree(self: PreparedProofBindings, round: u32) !DecommitFriTreeBindings {
        if (round >= self.decommit_fri_trees.len) return Error.InvalidCardinality;
        const tree = self.decommit_fri_trees[round];
        const tree_index = std.math.add(usize, self.decommit_trace_trees.len, round) catch
            return Error.InvalidCardinality;
        if (tree.round != round or tree.tree_index != tree_index or tree.role != tree_index)
            return Error.InvalidSchedule;
        return tree;
    }

    /// Executes the canonical SN2 trace and FRI opening schedule after query
    /// positions have been drawn. Trace LDEs stream one 16-column group at a
    /// time through the shared tile while sparse leaf hashes retain their
    /// Blake2s state across groups.
    pub fn executeSn2Decommit(
        self: PreparedProofBindings,
        allocator: std.mem.Allocator,
        metal: *metal_runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        schedule: []const std.json.Value,
        plan: arena_plan.Plan,
        recipe: *protocol_recipes.DecommitQueryRecipe,
        leaf_seed: [8]u32,
        node_seed: [8]u32,
    ) !f64 {
        if (self.decommit_trace_trees.len != Sn2Counts.decommit_trace_trees or
            self.decommit_fri_trees.len != Sn2Counts.decommit_fri_trees)
            return Error.InvalidCardinality;
        return self.executeDecommit(
            allocator,
            metal,
            resident_arena,
            schedule,
            plan,
            recipe,
            leaf_seed,
            node_seed,
        );
    }

    /// Executes trace and FRI openings in authenticated runtime tree order.
    pub fn executeDecommit(
        self: PreparedProofBindings,
        allocator: std.mem.Allocator,
        metal: *metal_runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        schedule: []const std.json.Value,
        plan: arena_plan.Plan,
        recipe: *protocol_recipes.DecommitQueryRecipe,
        leaf_seed: [8]u32,
        node_seed: [8]u32,
    ) !f64 {
        var lde_gpu_ms: f64 = 0;
        try recipe.normalize();
        for (0..self.decommit_trace_trees.len) |tree_index| {
            const tree = try self.decommitTraceTree(@intCast(tree_index));
            const coefficients: []const arena_plan.Binding = switch (tree.role) {
                .preprocessed => self.preprocessed_coefficients,
                .base => self.base_coefficients,
                .interaction => self.interaction_coefficients,
                .composition => self.composition_coefficients,
            };
            const canonical_coefficients: []const arena_plan.Binding = switch (tree.role) {
                .preprocessed => self.preprocessed_coefficients,
                .base => self.canonical_base_coefficients,
                .interaction => self.canonical_interaction_coefficients,
                .composition => self.composition_coefficients,
            };
            if (coefficients.len != tree.column_count) return Error.InvalidCardinality;
            const retained = try collectTreePurpose(
                allocator,
                schedule,
                plan,
                "RetainedMerkleLayers",
                tree.tree_index,
            );
            defer allocator.free(retained);
            try populateTraceRetainedPointers(resident_arena, tree, retained);
            try populateSparseOffsets(resident_arena, self.decommit_sparse_indices, tree.sparse_offsets, tree.unretained);
            try recipe.prepareTrace(tree.source_log, tree.tree_log, tree.leaf_log, tree.unretained);

            const max_leaf_count = std.math.cast(u32, 70 * (@as(u64, 1) << @intCast(tree.unretained))) orelse
                return Error.InvalidBindingSize;
            var column_cursor: usize = 0;
            for (tree.groups) |group| {
                if (group.tree_index != tree.tree_index or group.group_index * 16 != column_cursor)
                    return Error.InvalidSchedule;
                const end = std.math.add(usize, column_cursor, group.column_count) catch return Error.InvalidCardinality;
                if (end > coefficients.len) return Error.InvalidCardinality;
                const group_coefficients = coefficients[column_cursor..end];
                lde_gpu_ms += try executeDecommitTraceLdeGroup(
                    metal,
                    resident_arena,
                    self.forward_twiddles,
                    self.decommit_trace_lde_tile,
                    group,
                    group_coefficients,
                );
                try recipe.gatherTraceValues(
                    group.evaluation_pointers,
                    group.evaluation_logs,
                    group.column_count,
                    tree.tree_log,
                    @intCast(column_cursor),
                    70,
                    self.decommit_values,
                );
                try recipe.sparseLeafGroup(
                    group.evaluation_pointers,
                    group.evaluation_logs,
                    group.column_count,
                    @intCast(column_cursor),
                    tree.column_count,
                    tree.leaf_log,
                    max_leaf_count,
                    leaf_seed,
                );
                column_cursor = end;
            }
            if (column_cursor != coefficients.len) return Error.InvalidCardinality;

            var child_offset: u32 = 0;
            var child_capacity = max_leaf_count;
            for (1..tree.unretained) |distance| {
                const parent_offset = std.math.add(u32, child_offset, child_capacity) catch return Error.InvalidBindingSize;
                try recipe.sparseParent(
                    @intCast(distance),
                    child_offset,
                    child_capacity,
                    parent_offset,
                    node_seed,
                );
                child_offset = parent_offset;
                child_capacity >>= 1;
            }
            try reorderTraceQueryValues(
                allocator,
                resident_arena,
                self.decommit_values,
                coefficients,
                canonical_coefficients,
                70,
            );
            try recipe.assembleTrace(
                tree.tree_index,
                @intFromEnum(tree.role),
                tree.leaf_log,
                tree.unretained,
                tree.column_count,
                tree.retained_pointers,
                tree.sparse_offsets,
                self.decommit_values,
            );
        }

        if (self.fri_retained_evaluations.len + 1 != self.decommit_fri_trees.len)
            return Error.InvalidCardinality;
        var fri_layer_cursor: usize = 0;
        for (0..self.decommit_fri_trees.len) |round| {
            const tree = try self.decommitFriTree(@intCast(round));
            const evaluation = if (round == 0) self.quotient_tile else self.fri_retained_evaluations[round - 1];
            try populateFriCoordinatePointers(resident_arena, tree, evaluation);
            const layer_count: usize = tree.leaf_log + 1;
            if (fri_layer_cursor + layer_count > self.fri_merkle_layers.len) return Error.InvalidCardinality;
            try populateFriRetainedPointers(
                resident_arena,
                tree,
                self.fri_merkle_layers[fri_layer_cursor .. fri_layer_cursor + layer_count],
            );
            fri_layer_cursor += layer_count;
            try recipe.executeFriRound(
                round,
                tree.tree_index,
                tree.leaf_log,
                tree.coordinate_pointers,
                tree.retained_pointers,
                self.decommit_values,
            );
        }
        if (fri_layer_cursor != self.fri_merkle_layers.len) return Error.InvalidCardinality;
        const assembly_bytes: []align(4) u8 = @alignCast(try resident_arena.bytes(self.decommit_assembly));
        const assembly_words = std.mem.bytesAsSlice(u32, assembly_bytes);
        const tree_count = std.math.cast(u32, self.decommit_trace_trees.len + self.decommit_fri_trees.len) orelse
            return Error.InvalidCardinality;
        if (assembly_words.len < 8 or assembly_words[0] != 0x4457_5453 or assembly_words[1] != 1 or
            assembly_words[2] != tree_count or assembly_words[7] == 0 or assembly_words[7] > assembly_words.len)
            return Error.InvalidBindingSize;
        return lde_gpu_ms;
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

    pub fn prepareRelations(
        self: PreparedProofBindings,
        allocator: std.mem.Allocator,
        metal: *metal_runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        schedule: []const std.json.Value,
        plan: arena_plan.Plan,
        bundle: relation_bundle_mod.Bundle,
        witness_bundle: witness_bundle_mod.Bundle,
    ) !protocol_recipes.RelationRecipe {
        try validateClaimedSumOrder(schedule, plan, self.relation_claimed_sums);
        const interaction_named = try collectNamed(allocator, schedule, plan, "InteractionTrace");
        defer allocator.free(interaction_named);
        const base_named = try collectNamed(allocator, schedule, plan, "BaseTrace");
        defer allocator.free(base_named);
        var components = std.ArrayList(BoundRelationComponent).empty;
        defer {
            for (components.items) |*component| component.deinit();
            components.deinit(allocator);
        }
        var instances = std.ArrayList(protocol_recipes.RelationInstanceBindings).empty;
        defer instances.deinit(allocator);
        var claimed_index: usize = 0;
        for (bundle.components) |component| {
            var bound = (try bindRelationComponent(
                allocator,
                schedule,
                plan,
                component,
                interaction_named,
                base_named,
                witness_bundle,
                self.relation_claimed_sums,
                claimed_index,
            )) orelse continue;
            errdefer bound.deinit();
            claimed_index = std.math.add(usize, claimed_index, bound.instances.len) catch return Error.InvalidClaimedSumCount;
            try instances.appendSlice(allocator, bound.instances);
            try components.append(allocator, bound);
        }
        if (claimed_index != self.relation_claimed_sums.len) return Error.InvalidClaimedSumCount;
        return protocol_recipes.RelationRecipe.init(
            allocator,
            metal,
            resident_arena,
            instances.items,
            self.relation_alpha_powers,
            self.relation_z,
            self.relationScratchBinding(plan),
        );
    }

    /// Prepares the relation and inverse-circle FFT work as component-local
    /// operations. `executeIndex` always interpolates every interaction output
    /// before returning, so a later component may safely reuse its trace slab.
    pub fn prepareRelationComponents(
        self: PreparedProofBindings,
        allocator: std.mem.Allocator,
        metal: *metal_runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        schedule: []const std.json.Value,
        plan: arena_plan.Plan,
        bundle: relation_bundle_mod.Bundle,
        witness_bundle: witness_bundle_mod.Bundle,
        twiddle_storage: arena_plan.Binding,
    ) !PreparedRelationComponents {
        return prepareRelationComponentBatch(
            self,
            allocator,
            metal,
            resident_arena,
            schedule,
            plan,
            bundle,
            witness_bundle,
            twiddle_storage,
        );
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
            self.allocator,
            metal,
            resident_arena,
            schedule,
            plan,
            coefficients,
            self.commitmentTwiddleBinding(plan, tree_index),
            tree_index,
            leaf_seed,
            node_seed,
        );
    }

    pub fn commitmentScratchBytes(self: PreparedProofBindings, tree_index: u32) u64 {
        const coefficients = switch (tree_index) {
            0 => self.preprocessed_coefficients,
            1 => self.base_coefficients,
            2 => self.interaction_coefficients,
            3 => self.composition_coefficients,
            else => return 0,
        };
        var max_bytes: u64 = 0;
        for (coefficients) |binding| max_bytes = @max(max_bytes, binding.size_bytes);
        return max_bytes;
    }

    pub fn populateCommitmentTwiddles(
        self: PreparedProofBindings,
        allocator: std.mem.Allocator,
        resident_arena: *arena_plan.ResidentArena,
        plan: arena_plan.Plan,
        tree_index: u32,
    ) !void {
        try populateForwardTwiddleBinding(allocator, resident_arena, self.commitmentTwiddleBinding(plan, tree_index));
    }

    pub fn populateCommitmentInverseTwiddles(
        self: PreparedProofBindings,
        allocator: std.mem.Allocator,
        resident_arena: *arena_plan.ResidentArena,
        plan: arena_plan.Plan,
        tree_index: u32,
    ) !void {
        try populateInverseTwiddles(allocator, resident_arena, self.commitmentTwiddleBinding(plan, tree_index));
    }

    pub fn commitmentTwiddleStorage(self: PreparedProofBindings, plan: arena_plan.Plan, tree_index: u32) arena_plan.Binding {
        return self.commitmentTwiddleBinding(plan, tree_index);
    }

    pub fn restoreCommitmentRoot(
        self: PreparedProofBindings,
        resident_arena: *arena_plan.ResidentArena,
        schedule: []const std.json.Value,
        plan: arena_plan.Plan,
        tree_index: u32,
        root: [32]u8,
    ) !void {
        _ = self;
        const transcript_ordinals = [_]u32{ 3, 20, 23, 24 };
        if (tree_index >= transcript_ordinals.len) return Error.InvalidCardinality;
        const destination = try oneOrdinal(schedule, plan, "TranscriptInput", transcript_ordinals[tree_index]);
        @memcpy((try resident_arena.bytes(destination))[0..32], &root);
    }

    pub fn materializeRelationChallenges(
        self: PreparedProofBindings,
        resident_arena: *arena_plan.ResidentArena,
    ) !void {
        var drawn: ?arena_plan.Binding = null;
        for (self.transcript_outputs) |output| if (output.ordinal == 1) {
            drawn = output.binding;
            break;
        };
        const source = drawn orelse return Error.MissingBinding;
        const source_bytes = try resident_arena.bytes(source);
        if (source_bytes.len < 32 or self.relation_z.size_bytes < 16 or self.relation_alpha_powers.size_bytes % 16 != 0)
            return Error.InvalidBindingSize;
        const aligned_source: []align(4) u8 = @alignCast(source_bytes);
        const words = std.mem.bytesAsSlice(u32, aligned_source);
        if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_STAGE_TIMINGS")) std.debug.print(
            "transcript_relation_challenges z={d},{d},{d},{d} alpha={d},{d},{d},{d}\n",
            .{ words[0], words[1], words[2], words[3], words[4], words[5], words[6], words[7] },
        );
        try self.restoreRelationChallenges(
            resident_arena,
            .{ words[0], words[1], words[2], words[3] },
            .{ words[4], words[5], words[6], words[7] },
        );
    }

    pub fn restoreRelationChallenges(
        self: PreparedProofBindings,
        resident_arena: *arena_plan.ResidentArena,
        z: [4]u32,
        alpha_words: [4]u32,
    ) !void {
        const z_bytes: []align(4) u8 = @alignCast(try resident_arena.bytes(self.relation_z));
        const z_destination = std.mem.bytesAsSlice(u32, z_bytes);
        if (z_destination.len < 4 or self.relation_alpha_powers.size_bytes % 16 != 0)
            return Error.InvalidBindingSize;
        @memcpy(z_destination[0..4], &z);
        const alpha = QM31.fromU32Unchecked(alpha_words[0], alpha_words[1], alpha_words[2], alpha_words[3]);
        const powers_bytes = try resident_arena.bytes(self.relation_alpha_powers);
        const aligned_powers: []align(4) u8 = @alignCast(powers_bytes);
        const powers = std.mem.bytesAsSlice(u32, aligned_powers);
        var current = QM31.one();
        var index: usize = 0;
        while (index < powers.len / 4) : (index += 1) {
            const coordinates = current.toM31Array();
            inline for (0..4) |coordinate| powers[index * 4 + coordinate] = coordinates[coordinate].v;
            current = current.mul(alpha);
        }
    }

    pub fn publishInteractionClaim(
        self: PreparedProofBindings,
        resident_arena: *arena_plan.ResidentArena,
        schedule: []const std.json.Value,
        plan: arena_plan.Plan,
    ) !void {
        const destination = try oneOrdinal(schedule, plan, "TranscriptInput", 22);
        if (destination.size_bytes != @as(u64, self.canonical_claimed_sums.len) * 16)
            return Error.InvalidBindingSize;
        const destination_bytes = try resident_arena.bytes(destination);
        for (self.canonical_claimed_sums, 0..) |source, index| {
            if (source.size_bytes != 16) return Error.InvalidBindingSize;
            @memcpy(destination_bytes[index * 16 ..][0..16], (try resident_arena.bytes(source))[0..16]);
        }
    }

    pub fn logRelationDiagnostics(
        self: PreparedProofBindings,
        resident_arena: *arena_plan.ResidentArena,
        relations: PreparedRelationComponents,
    ) !void {
        const z_bytes: []align(4) u8 = @alignCast(try resident_arena.bytes(self.relation_z));
        const alpha_bytes: []align(4) u8 = @alignCast(try resident_arena.bytes(self.relation_alpha_powers));
        const z = std.mem.bytesAsSlice(u32, z_bytes);
        const alpha_powers = std.mem.bytesAsSlice(u32, alpha_bytes);
        if (z.len < 4 or alpha_powers.len < 8) return Error.InvalidBindingSize;
        std.debug.print(
            "relation_challenge z={},{},{},{} alpha={},{},{},{}\n",
            .{ z[0], z[1], z[2], z[3], alpha_powers[4], alpha_powers[5], alpha_powers[6], alpha_powers[7] },
        );
        for (relations.operations) |operation| {
            for (0..operation.claimed_sum_count) |instance_index| {
                const claimed_index = @as(usize, operation.claimed_sum_start) + instance_index;
                if (claimed_index >= self.relation_claimed_sums.len) return Error.InvalidClaimedSumCount;
                const claimed_bytes: []align(4) u8 = @alignCast(
                    try resident_arena.bytes(self.relation_claimed_sums[claimed_index]),
                );
                const claimed = std.mem.bytesAsSlice(u32, claimed_bytes);
                if (claimed.len < 4) return Error.InvalidBindingSize;
                std.debug.print(
                    "relation_claimed ordinal={} component={s} instance={} value={},{},{},{}\n",
                    .{ claimed_index, operation.component, instance_index, claimed[0], claimed[1], claimed[2], claimed[3] },
                );
            }
        }
    }

    fn commitmentTwiddleBinding(self: PreparedProofBindings, plan: arena_plan.Plan, tree_index: u32) arena_plan.Binding {
        _ = plan;
        _ = tree_index;
        return self.forward_twiddles;
    }

    fn relationScratchBinding(self: PreparedProofBindings, plan: arena_plan.Plan) arena_plan.Binding {
        _ = plan;
        return self.relation_scan_scratch;
    }

    fn runtimeFriGeometry(self: PreparedProofBindings) !protocol_recipes.FriGeometry {
        const geometry = protocol_recipes.FriGeometry.initRuntime(
            try friStartLog(self.quotient_tile),
            .{
                .round_count = self.decommit_fri_trees.len,
                .fold_step = protocol_recipes.FriGeometry.fold_step,
                .final_log = protocol_recipes.FriGeometry.final_log,
                .packed_log = protocol_recipes.FriGeometry.packed_log,
            },
        ) catch return Error.InvalidBindingSize;
        for (self.decommit_fri_trees, 0..) |tree, round| {
            if (tree.leaf_log != try geometry.leafLog(round)) return Error.InvalidBindingSize;
        }
        return geometry;
    }

    fn validate(self: PreparedProofBindings, geometry: ProofDecommitGeometry) !void {
        try geometry.validate();
        _ = try self.runtimeFriGeometry();
        if (self.decommit_trace_trees.len != geometry.trace_trees.len or
            self.decommit_fri_trees.len != geometry.fri_trees.len or
            self.decommit_trace_groups.len != try geometry.traceGroupCount())
            return Error.InvalidCardinality;
        if (self.fri_challenges.len != geometry.fri_trees.len) return Error.InvalidFriChallengeCount;
        if (self.fri_retained_evaluations.len + 1 != geometry.fri_trees.len)
            return Error.InvalidFriRetainedCount;
        if (self.fri_merkle_layers.len != try geometry.friLayerCount()) return Error.InvalidFriLayerCount;

        var group_cursor: usize = 0;
        for (self.decommit_trace_trees, geometry.trace_trees) |tree, expected| {
            if (tree.role != expected.role or tree.tree_index != expected.tree_index or
                tree.source_log != expected.source_log or tree.tree_log != expected.tree_log or
                tree.leaf_log != expected.leaf_log or tree.unretained != expected.unretained or
                tree.column_count != expected.column_count or tree.groups.len != expected.groupCount())
                return Error.InvalidCardinality;
            const coefficients: []const arena_plan.Binding = switch (tree.role) {
                .preprocessed => self.preprocessed_coefficients,
                .base => self.base_coefficients,
                .interaction => self.interaction_coefficients,
                .composition => self.composition_coefficients,
            };
            if (coefficients.len != tree.column_count) return Error.InvalidCardinality;
            var column_count: usize = 0;
            for (tree.groups, 0..) |group, group_index| {
                if (group_cursor >= self.decommit_trace_groups.len or
                    group.tree_index != tree.tree_index or group.group_index != group_index or
                    group.column_count == 0 or group.column_count > 16)
                    return Error.InvalidSchedule;
                column_count = std.math.add(usize, column_count, group.column_count) catch
                    return Error.InvalidCardinality;
                group_cursor += 1;
            }
            if (column_count != tree.column_count) return Error.InvalidCardinality;
        }
        if (group_cursor != self.decommit_trace_groups.len) return Error.InvalidCardinality;
        for (self.decommit_fri_trees, geometry.fri_trees) |tree, expected| {
            if (tree.role != expected.role or tree.round != expected.round or
                tree.tree_index != expected.tree_index or tree.leaf_log != expected.leaf_log)
                return Error.InvalidCardinality;
        }
        if (self.canonical_base_coefficients.len != self.base_coefficients.len or
            self.canonical_interaction_coefficients.len != self.interaction_coefficients.len)
            return Error.InvalidCardinality;
        if (self.inverse_twiddles.size_bytes == 0 or
            !std.math.isPowerOfTwo(self.inverse_twiddles.size_bytes / @sizeOf(u32)))
            return Error.InvalidBindingSize;
        try validateDisjointActiveBindings(self.inverse_twiddles, self.composition_accumulators);
        if (self.decommit_values.size_bytes == 0 or self.decommit_assembly.size_bytes == 0 or
            self.decommit_trace_lde_tile.size_bytes == 0 or self.proof_bytes.size_bytes == 0 or
            self.assembly.len == 0 or
            self.proof_copies.len != geometry.fri_trees.len + 10 or
            self.transcript_inputs.len == 0 or self.transcript_outputs.len == 0)
            return Error.InvalidBindingSize;
        var cursor: u64 = 0;
        for (self.proof_copies) |copy| {
            if (copy.destination_word_offset != cursor or copy.source.size_bytes < @as(u64, copy.word_count) * 4)
                return Error.InvalidBindingSize;
            cursor = std.math.add(u64, cursor, copy.word_count) catch return Error.InvalidBindingSize;
        }
        if (cursor * 4 != self.proof_bytes.size_bytes) return Error.InvalidBindingSize;
    }

    fn validateSn2(self: PreparedProofBindings) !void {
        if (self.composition_coefficients.len != Sn2Counts.composition_coefficients) return Error.InvalidCompositionCount;
        if (self.quotient_partials.len == 0 or self.quotient_partials.len % 4 != 0)
            return Error.InvalidQuotientCount;
        const quotient_sample_count = self.quotient_partials.len / 4;
        if (self.quotient_sample_points.size_bytes != quotient_sample_count * 8 * 4 or
            self.quotient_first_linear_terms.size_bytes != quotient_sample_count * 4 * 4)
            return Error.InvalidQuotientCount;
        for (0..quotient_sample_count) |sample| {
            const first = self.quotient_partials[sample * 4];
            if (first.size_bytes == 0 or !std.math.isPowerOfTwo(first.size_bytes / 4))
                return Error.InvalidBindingSize;
            for (self.quotient_partials[sample * 4 ..][0..4]) |partial| {
                if (partial.size_bytes != first.size_bytes) return Error.InvalidBindingSize;
            }
        }
        if (self.fri_challenges.len != Sn2Counts.fri_challenges) return Error.InvalidFriChallengeCount;
        if (self.fri_retained_evaluations.len != Sn2Counts.fri_retained_evaluations) return Error.InvalidFriRetainedCount;
        const fri_geometry = protocol_recipes.FriGeometry.init(try friStartLog(self.quotient_tile)) catch
            return Error.InvalidBindingSize;
        if (self.fri_merkle_layers.len != fri_geometry.totalLayerCount()) return Error.InvalidFriLayerCount;
        if (self.decommit_trace_groups.len != Sn2Counts.decommit_trace_groups) return Error.InvalidCardinality;
        if (self.composition_ext_params.len != 58) return Error.InvalidExtParamCount;
        if (self.relation_claimed_sums.len != 58 or self.canonical_claimed_sums.len != self.relation_claimed_sums.len)
            return Error.InvalidClaimedSumCount;
        if (self.preprocessed_coefficients.len != 161) return Error.InvalidPreprocessedCount;
        if (self.canonical_base_coefficients.len != self.base_coefficients.len or
            self.canonical_interaction_coefficients.len != self.interaction_coefficients.len)
            return Error.InvalidCardinality;
        if (self.inverse_twiddles.size_bytes == 0 or
            !std.math.isPowerOfTwo(self.inverse_twiddles.size_bytes / @sizeOf(u32)))
            return Error.InvalidBindingSize;
        try validateDisjointBindings(self.inverse_twiddles, self.composition_accumulators);
        for (self.composition_coefficients) |binding| {
            if (binding.size_bytes != self.inverse_twiddles.size_bytes) return Error.InvalidBindingSize;
        }
        if (self.fri_final_coefficients.size_bytes != 8 * 4 or
            self.fri_final_degree_error.size_bytes != 4 or
            self.transcript_state.size_bytes < 10 * 4 or self.transcript_inputs.len != 26 or self.transcript_outputs.len != 13 or
            self.decommit_values.size_bytes == 0 or
            self.decommit_assembly.size_bytes == 0 or self.decommit_trace_lde_tile.size_bytes == 0 or
            self.proof_bytes.size_bytes == 0 or self.assembly.len == 0 or
            self.proof_copies.len != 18)
            return Error.InvalidBindingSize;
        if (self.decommit_trace_trees.len != Sn2Counts.decommit_trace_trees or
            self.decommit_fri_trees.len != Sn2Counts.decommit_fri_trees)
            return Error.InvalidCardinality;
        for (self.decommit_trace_trees, Sn2Counts.decommit_trace_groups_by_tree, Sn2Counts.decommit_trace_columns_by_tree, 0..) |tree, group_count, column_count, tree_index| {
            if (tree.tree_index != tree_index or @intFromEnum(tree.role) != tree_index or
                tree.groups.len != group_count or tree.column_count != column_count)
                return Error.InvalidCardinality;
        }
        for (self.decommit_fri_trees, 0..) |tree, round| {
            if (tree.round != round or tree.tree_index != round + Sn2Counts.decommit_trace_trees or
                tree.role != tree.tree_index)
                return Error.InvalidCardinality;
        }
        var cursor: u64 = 0;
        for (self.proof_copies) |copy| {
            if (copy.destination_word_offset != cursor or copy.source.size_bytes < @as(u64, copy.word_count) * 4)
                return Error.InvalidBindingSize;
            cursor += copy.word_count;
        }
        if (cursor * 4 != self.proof_bytes.size_bytes) return Error.InvalidBindingSize;
    }
};

fn validateDisjointBindings(first: arena_plan.Binding, second: arena_plan.Binding) Error!void {
    const first_end = std.math.add(u64, first.offset_bytes, first.size_bytes) catch
        return Error.InvalidBindingSize;
    const second_end = std.math.add(u64, second.offset_bytes, second.size_bytes) catch
        return Error.InvalidBindingSize;
    if (first.offset_bytes < second_end and second.offset_bytes < first_end)
        return Error.InvalidBindingAlias;
}

fn validateDisjointActiveBindings(first: arena_plan.Binding, second: arena_plan.Binding) Error!void {
    if (!bindingHasActiveTick(first) or !bindingHasActiveTick(second)) return;
    return validateDisjointBindings(first, second);
}

fn bindingHasActiveTick(binding: arena_plan.Binding) bool {
    for (binding.occupied) |word| if (word != 0) return true;
    return false;
}

pub const RelationComponentTelemetry = struct {
    relation_gpu_ms: f64,
    interpolation_gpu_ms: f64,
};

pub const RelationComponentOperation = struct {
    component_index: u32,
    component: []const u8,
    claimed_sum_start: u32,
    claimed_sum_count: u32,
    relation: protocol_recipes.RelationRecipe,
    interpolations: []protocol_recipes.CircleIfftRecipe,

    fn deinit(self: *RelationComponentOperation, allocator: std.mem.Allocator) void {
        for (self.interpolations) |*interpolation| interpolation.deinit();
        allocator.free(self.interpolations);
        self.relation.deinit();
        self.* = undefined;
    }

    pub fn execute(self: *RelationComponentOperation) !RelationComponentTelemetry {
        const relation_before = self.relation.accumulated_gpu_ms;
        try self.relation.execute();
        var interpolation_gpu_ms: f64 = 0;
        for (self.interpolations) |*interpolation| {
            const before = interpolation.accumulated_gpu_ms;
            try interpolation.execute();
            interpolation_gpu_ms += interpolation.accumulated_gpu_ms - before;
        }
        return .{
            .relation_gpu_ms = self.relation.accumulated_gpu_ms - relation_before,
            .interpolation_gpu_ms = interpolation_gpu_ms,
        };
    }
};

/// Relation components remain in canonical relation-bundle order. Each entry
/// owns the exact consecutive claimed-sum range produced by its relation plan.
pub const PreparedRelationComponents = struct {
    allocator: std.mem.Allocator,
    operations: []RelationComponentOperation,

    pub fn deinit(self: *PreparedRelationComponents) void {
        for (self.operations) |*operation| operation.deinit(self.allocator);
        self.allocator.free(self.operations);
        self.* = undefined;
    }

    pub fn componentIndex(self: PreparedRelationComponents, name: []const u8) !?u32 {
        var found: ?u32 = null;
        for (self.operations, 0..) |operation, index| {
            if (!std.mem.eql(u8, operation.component, name)) continue;
            if (found != null) return Error.DuplicateBinding;
            found = @intCast(index);
        }
        return found;
    }

    pub fn executeIndex(self: *PreparedRelationComponents, index: u32) !RelationComponentTelemetry {
        if (index >= self.operations.len) return Error.InvalidCardinality;
        return self.operations[index].execute();
    }

    pub fn executeComponent(self: *PreparedRelationComponents, name: []const u8) !RelationComponentTelemetry {
        const index = try self.componentIndex(name) orelse return Error.MissingBinding;
        return self.executeIndex(index);
    }
};

const BoundRelationComponent = struct {
    allocator: std.mem.Allocator,
    instances: []protocol_recipes.RelationInstanceBindings,

    fn deinit(self: *BoundRelationComponent) void {
        for (self.instances) |instance| {
            self.allocator.free(instance.sources);
            self.allocator.free(instance.outputs);
        }
        self.allocator.free(self.instances);
        self.* = undefined;
    }
};

fn canonicalClaimedSumBindings(
    allocator: std.mem.Allocator,
    composition_bundle: composition_bundle_mod.Bundle,
    relation_bundle: relation_bundle_mod.Bundle,
    scheduled: []const arena_plan.Binding,
) ![]arena_plan.Binding {
    if (composition_bundle.components.len != scheduled.len) return Error.InvalidClaimedSumCount;
    const canonical = try allocator.alloc(arena_plan.Binding, scheduled.len);
    errdefer allocator.free(canonical);
    const assigned = try allocator.alloc(bool, scheduled.len);
    defer allocator.free(assigned);
    @memset(assigned, false);

    var scheduled_index: usize = 0;
    for (relation_bundle.components) |relation_component| {
        for (composition_bundle.components, 0..) |component, canonical_index| {
            const relation_label = if (std.mem.eql(u8, component.label, "memory_id_to_small"))
                "memory_id_to_big"
            else
                component.label;
            if (!std.mem.eql(u8, relation_label, relation_component.name)) continue;
            if (scheduled_index >= scheduled.len or assigned[canonical_index])
                return Error.InvalidClaimedSumCount;
            canonical[canonical_index] = scheduled[scheduled_index];
            assigned[canonical_index] = true;
            scheduled_index += 1;
        }
    }
    if (scheduled_index != scheduled.len) return Error.InvalidClaimedSumCount;
    for (assigned) |present| if (!present) return Error.InvalidClaimedSumCount;
    return canonical;
}

fn validateClaimedSumOrder(
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    claimed_sums: []const arena_plan.Binding,
) !void {
    if (claimed_sums.len == 0 or claimed_sums.len > 256) return Error.InvalidClaimedSumCount;
    var seen = [_]bool{false} ** 256;
    var count: usize = 0;
    for (schedule) |entry| {
        if (!std.mem.eql(u8, try purpose(entry), "RelationClaimedSum")) continue;
        const claimed_ordinal = try ordinal(entry);
        if (claimed_ordinal >= claimed_sums.len or seen[claimed_ordinal]) return Error.InvalidClaimedSumCount;
        const binding = plan.binding(try logicalId(entry)) catch return Error.MissingBinding;
        if (!std.meta.eql(binding, claimed_sums[claimed_ordinal])) return Error.InvalidSchedule;
        seen[claimed_ordinal] = true;
        count += 1;
    }
    if (count != claimed_sums.len) return Error.InvalidClaimedSumCount;
}

fn bindRelationComponent(
    allocator: std.mem.Allocator,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    component: relation_bundle_mod.Component,
    interaction_named: []const NamedBinding,
    base_named: []const NamedBinding,
    witness_bundle: witness_bundle_mod.Bundle,
    claimed_sums: []const arena_plan.Binding,
    claimed_start: usize,
) !?BoundRelationComponent {
    var component_outputs = std.ArrayList(NamedBinding).empty;
    defer component_outputs.deinit(allocator);
    for (interaction_named) |item| {
        if (std.mem.eql(u8, item.component, component.name)) try component_outputs.append(allocator, item);
    }
    if (component_outputs.items.len == 0) return null;

    var component_base = std.ArrayList(NamedBinding).empty;
    defer component_base.deinit(allocator);
    for (base_named) |item| {
        if (std.mem.eql(u8, item.component, component.name)) try component_base.append(allocator, item);
    }
    const output_groups = try namedGroupRanges(allocator, component_outputs.items);
    defer allocator.free(output_groups);
    const base_groups = try namedGroupRanges(allocator, component_base.items);
    defer allocator.free(base_groups);

    var instances = std.ArrayList(protocol_recipes.RelationInstanceBindings).empty;
    errdefer {
        for (instances.items) |instance| {
            allocator.free(instance.sources);
            allocator.free(instance.outputs);
        }
        instances.deinit(allocator);
    }
    var output_group_index: usize = 0;
    var big_source_offset: u32 = 0;
    for (component.traces, 0..) |trace, trace_index| {
        const remaining_fixed = countFixedRelationTraces(component.traces[trace_index + 1 ..]);
        if (output_group_index + remaining_fixed > output_groups.len) return Error.InvalidCardinality;
        const trace_instances: usize = switch (trace.part) {
            .component, .memory_small => 1,
            .each_memory_big => output_groups.len - output_group_index - remaining_fixed,
        };
        if (trace_instances == 0) return Error.InvalidCardinality;
        for (0..trace_instances) |instance_index| {
            const claimed_index = std.math.add(usize, claimed_start, instances.items.len) catch return Error.InvalidClaimedSumCount;
            if (output_group_index >= output_groups.len or claimed_index >= claimed_sums.len)
                return Error.InvalidCardinality;
            const output_range = output_groups[output_group_index];
            const output_named = component_outputs.items[output_range.start .. output_range.start + output_range.len];
            if (output_named.len != @as(usize, trace.output_columns) * 4) return Error.InvalidCardinality;
            const outputs = try allocator.alloc(arena_plan.Binding, output_named.len);
            var outputs_owned = true;
            defer if (outputs_owned) allocator.free(outputs);
            for (output_named, outputs) |item, *binding| binding.* = item.binding;
            const rows = std.math.cast(u32, outputs[0].size_bytes / 4) orelse return Error.InvalidBindingSize;
            if (rows == 0 or !std.math.isPowerOfTwo(rows)) return Error.InvalidBindingSize;
            for (outputs) |binding| {
                if (binding.size_bytes != @as(u64, rows) * 4) return Error.InvalidBindingSize;
            }

            const source_group_index: usize = switch (trace.part) {
                .component => 0,
                .each_memory_big => instance_index,
                .memory_small => if (base_groups.len == 0) return Error.InvalidCardinality else base_groups.len - 1,
            };
            const source_count: usize = switch (trace.layout) {
                .lookup_words => 1,
                .memory_address => @as(usize, trace.layout_arg) * 2,
                .memory_big, .memory_small => @as(usize, trace.layout_arg) + 1,
                .bitwise_xor_12 => trace.layout_arg,
            };
            const sources = try allocator.alloc(arena_plan.Binding, source_count);
            var sources_owned = true;
            defer if (sources_owned) allocator.free(sources);
            if (trace.layout == .lookup_words) {
                sources[0] = try oneComponent(schedule, plan, "LookupInputs", component.name);
            } else {
                if (source_group_index >= base_groups.len) return Error.InvalidCardinality;
                const source_range = base_groups[source_group_index];
                if (source_range.len < source_count) return Error.InvalidCardinality;
                for (component_base.items[source_range.start .. source_range.start + source_count], sources) |item, *binding| {
                    binding.* = item.binding;
                }
            }
            for (sources) |binding| {
                if (binding.size_bytes < @as(u64, rows) * 4) return Error.InvalidBindingSize;
            }
            const real_rows = if (relationTraceUsesRowEnabler(trace))
                try gatheredWitnessRealRows(schedule, plan, witness_bundle, component.name)
            else
                rows;
            if (real_rows > rows) return Error.InvalidBindingSize;
            if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_DIFF_ADD_OPCODE_INTERACTION") and
                (std.mem.eql(u8, component.name, "add_ap_opcode") or
                    std.mem.eql(u8, component.name, "add_opcode") or
                    std.mem.eql(u8, component.name, "add_opcode_small")))
            {
                std.debug.print(
                    "relation_binding component={s} rows={} real_rows={} sources={} columns={} source_offset_rows={}\n",
                    .{ component.name, rows, real_rows, sources.len, trace.output_columns, if (trace.part == .each_memory_big) big_source_offset else 0 },
                );
                for (sources, 0..) |binding, source_index| std.debug.print(
                    "relation_range component={s} kind=source ordinal={} words=[{}, {})\n",
                    .{ component.name, source_index, binding.offset_bytes / 4, (binding.offset_bytes + binding.size_bytes) / 4 },
                );
                for (outputs, 0..) |binding, output_index| std.debug.print(
                    "relation_range component={s} kind=output ordinal={} words=[{}, {})\n",
                    .{ component.name, output_index, binding.offset_bytes / 4, (binding.offset_bytes + binding.size_bytes) / 4 },
                );
                const debug_scratch = try one(schedule, plan, "RelationScanEvalScratch");
                std.debug.print(
                    "relation_range component={s} kind=scratch ordinal=0 words=[{}, {})\n",
                    .{ component.name, debug_scratch.offset_bytes / 4, (debug_scratch.offset_bytes + debug_scratch.size_bytes) / 4 },
                );
                std.debug.print(
                    "relation_range component={s} kind=claimed ordinal=0 words=[{}, {})\n",
                    .{ component.name, claimed_sums[claimed_index].offset_bytes / 4, (claimed_sums[claimed_index].offset_bytes + claimed_sums[claimed_index].size_bytes) / 4 },
                );
                var debug_descriptor_index: usize = 0;
                while (debug_descriptor_index < trace.descriptors.len) : (debug_descriptor_index += 16) {
                    const descriptor = trace.descriptors[debug_descriptor_index..][0..16];
                    std.debug.print(
                        "relation_descriptor component={s} column={} uses={} a={},{},{},{},{},{},{} b={},{},{},{},{},{},{}\n",
                        .{
                            component.name,
                            debug_descriptor_index / 16,
                            descriptor[0],
                            descriptor[1],
                            descriptor[2],
                            descriptor[3],
                            descriptor[4],
                            descriptor[5],
                            descriptor[6],
                            descriptor[7],
                            descriptor[8],
                            descriptor[9],
                            descriptor[10],
                            descriptor[11],
                            descriptor[12],
                            descriptor[13],
                            descriptor[14],
                        },
                    );
                }
            }
            try instances.append(allocator, .{
                .rows = rows,
                .real_rows = real_rows,
                .source_offset_rows = if (trace.part == .each_memory_big) big_source_offset else 0,
                .sources = sources,
                .descriptors = trace.descriptors,
                .outputs = outputs,
                .claimed_sum = claimed_sums[claimed_index],
            });
            sources_owned = false;
            outputs_owned = false;
            if (trace.part == .each_memory_big) {
                big_source_offset = std.math.add(u32, big_source_offset, rows) catch return Error.InvalidBindingSize;
            }
            output_group_index += 1;
        }
    }
    if (output_group_index != output_groups.len) return Error.InvalidCardinality;
    return .{ .allocator = allocator, .instances = try instances.toOwnedSlice(allocator) };
}

fn prepareRelationComponentBatch(
    bindings: PreparedProofBindings,
    allocator: std.mem.Allocator,
    metal: *metal_runtime.Runtime,
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    bundle: relation_bundle_mod.Bundle,
    witness_bundle: witness_bundle_mod.Bundle,
    twiddle_storage: arena_plan.Binding,
) !PreparedRelationComponents {
    try validateClaimedSumOrder(schedule, plan, bindings.relation_claimed_sums);
    const interaction_named = try collectNamed(allocator, schedule, plan, "InteractionTrace");
    defer allocator.free(interaction_named);
    const base_named = try collectNamed(allocator, schedule, plan, "BaseTrace");
    defer allocator.free(base_named);
    var operations = std.ArrayList(RelationComponentOperation).empty;
    errdefer {
        for (operations.items) |*operation| operation.deinit(allocator);
        operations.deinit(allocator);
    }
    var claimed_index: usize = 0;
    for (bundle.components, 0..) |component, component_index| {
        if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_STAGE_TIMINGS"))
            std.debug.print("relation_prepare component={s} index={d}\n", .{ component.name, component_index });
        var bound = (try bindRelationComponent(
            allocator,
            schedule,
            plan,
            component,
            interaction_named,
            base_named,
            witness_bundle,
            bindings.relation_claimed_sums,
            claimed_index,
        )) orelse continue;
        defer bound.deinit();
        for (operations.items) |operation| {
            if (std.mem.eql(u8, operation.component, component.name)) return Error.DuplicateBinding;
        }
        var relation = try protocol_recipes.RelationRecipe.init(
            allocator,
            metal,
            resident_arena,
            bound.instances,
            bindings.relation_alpha_powers,
            bindings.relation_z,
            bindings.relationScratchBinding(plan),
        );
        var relation_owned = true;
        defer if (relation_owned) relation.deinit();
        const interpolations = try prepareComponentInterpolationGroupsForPurposes(
            allocator,
            metal,
            resident_arena,
            schedule,
            plan,
            component.name,
            "InteractionTrace",
            "InteractionCoefficients",
            twiddle_storage,
        );
        var interpolations_owned = true;
        defer if (interpolations_owned) {
            for (interpolations) |*interpolation| interpolation.deinit();
            allocator.free(interpolations);
        };
        if (interpolations.len != bound.instances.len) return Error.InvalidCardinality;
        try operations.append(allocator, .{
            .component_index = @intCast(component_index),
            .component = component.name,
            .claimed_sum_start = @intCast(claimed_index),
            .claimed_sum_count = @intCast(bound.instances.len),
            .relation = relation,
            .interpolations = interpolations,
        });
        relation_owned = false;
        interpolations_owned = false;
        claimed_index = std.math.add(usize, claimed_index, bound.instances.len) catch return Error.InvalidClaimedSumCount;
    }
    if (claimed_index != bindings.relation_claimed_sums.len or operations.items.len == 0)
        return Error.InvalidClaimedSumCount;
    return .{ .allocator = allocator, .operations = try operations.toOwnedSlice(allocator) };
}

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
        resident_arena.buffer,
        try wordOffset(raw_big),
        @intCast(input.memory.f252_values.len),
        big_rows,
        8,
        &big_offsets,
    );
    gpu_ms += try metal.executionTableSplit(
        resident_arena.buffer,
        try wordOffset(raw_small),
        @intCast(input.memory.small_values.len),
        small_rows,
        4,
        &small_offsets,
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
    _ = try populatePreprocessedCoefficientsMode(
        allocator,
        resident_arena,
        schedule,
        plan,
        fixed_bundle,
        path,
        .all,
    );
}

pub const PreprocessedCoefficientLoad = struct {
    loaded_columns: usize,
    loaded_bytes: u64,
    reconstructed_columns: usize,
    reconstructed_bytes: u64,
};

/// Validates the complete coefficient artifact while avoiding host copies for
/// columns that the authenticated evaluation artifact will immediately IFFT
/// into the same ordinal and byte shape.
pub fn populateUnreconstructedPreprocessedCoefficients(
    allocator: std.mem.Allocator,
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    fixed_bundle: fixed_table_bundle_mod.Bundle,
    path: []const u8,
) !PreprocessedCoefficientLoad {
    return populatePreprocessedCoefficientsMode(
        allocator,
        resident_arena,
        schedule,
        plan,
        fixed_bundle,
        path,
        .unreconstructed_only,
    );
}

const PreprocessedCoefficientLoadMode = enum { all, unreconstructed_only };

fn populatePreprocessedCoefficientsMode(
    allocator: std.mem.Allocator,
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    fixed_bundle: fixed_table_bundle_mod.Bundle,
    path: []const u8,
    mode: PreprocessedCoefficientLoadMode,
) !PreprocessedCoefficientLoad {
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
    var result: PreprocessedCoefficientLoad = .{
        .loaded_columns = 0,
        .loaded_bytes = 0,
        .reconstructed_columns = 0,
        .reconstructed_bytes = 0,
    };
    for (coefficients, fixed_bundle.preprocessed_identities, 0..) |binding, expected_identity, index| {
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
        const evaluation = oneOrdinal(
            schedule,
            plan,
            "PreprocessedEvaluations",
            std.math.cast(u32, index) orelse return Error.InvalidCardinality,
        ) catch null;
        const reconstructed = mode == .unreconstructed_only and log_size >= 4 and log_size < 25 and
            evaluation != null and evaluation.?.size_bytes == binding.size_bytes;
        if (reconstructed) {
            try stream.discardAll64(binding.size_bytes);
            result.reconstructed_columns += 1;
            result.reconstructed_bytes += binding.size_bytes;
        } else {
            const destination = try resident_arena.bytes(binding);
            try stream.readSliceAll(destination);
            const aligned: []align(4) u8 = @alignCast(destination);
            const words = std.mem.bytesAsSlice(u32, aligned);
            for (words) |value| if (value >= 0x7fffffff) return Error.InvalidSchedule;
            if (log_size > 16) canonicalizeSimdCoefficientBlocks(words, log_size);
            result.loaded_columns += 1;
            result.loaded_bytes += binding.size_bytes;
        }
    }
    var trailing: [1]u8 = undefined;
    if (try stream.readSliceShort(&trailing) != 0) return Error.InvalidSchedule;
    return result;
}

fn canonicalizeSimdCoefficientBlocks(words: []u32, log_size: u32) void {
    const log_lanes: u32 = 4;
    std.debug.assert(log_size > 16 and words.len == @as(usize, 1) << @intCast(log_size));
    const log_vectors = log_size - log_lanes;
    const half = log_vectors / 2;
    const outer = @as(usize, 1) << @intCast(half);
    const middle = @as(usize, 1) << @intCast(log_vectors & 1);
    for (0..outer) |a| {
        for (0..middle) |b| {
            for (0..outer) |c| {
                const i = (a << @intCast(log_vectors - half)) | (b << @intCast(half)) | c;
                const j = (c << @intCast(log_vectors - half)) | (b << @intCast(half)) | a;
                if (i >= j) continue;
                const lhs = words[i * 16 ..][0..16];
                const rhs = words[j * 16 ..][0..16];
                for (lhs, rhs) |*left, *right| std.mem.swap(u32, left, right);
            }
        }
    }
}

pub fn evaluatePreprocessedCoefficients(
    allocator: std.mem.Allocator,
    metal: *metal_runtime.Runtime,
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    twiddle_storage: ?arena_plan.Binding,
) !f64 {
    const twiddles = try one(schedule, plan, "ForwardTwiddles");
    var gpu_ms: f64 = 0;
    for (4..26) |log_size_usize| {
        const log_size: u32 = @intCast(log_size_usize);
        var source_offsets = std.ArrayList(u64).empty;
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
            try source_offsets.append(allocator, source.offset_bytes / 4);
            try source_logs.append(allocator, log_size);
            try destination_offsets.append(allocator, try wordOffset(destination));
        }
        if (source_offsets.items.len == 0) continue;
        var prepared = try metal.prepareCompositionLde(
            source_offsets.items,
            source_logs.items,
            destination_offsets.items,
            log_size,
            try twiddleOffsetForLog(if (twiddle_storage) |storage| twiddleBankBinding(storage, log_size) else twiddles, log_size),
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

pub fn spillPreprocessedEvaluations(
    allocator: std.mem.Allocator,
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    path: []const u8,
) !void {
    const evaluations = try collectScheduleOrder(allocator, schedule, plan, "PreprocessedEvaluations");
    defer allocator.free(evaluations);
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    var buffer: [1 << 20]u8 = undefined;
    var file_writer = file.writer(&buffer);
    const writer = &file_writer.interface;
    try writer.writeAll("STWZPEV\x00");
    try writer.writeInt(u32, 1, .little);
    try writer.writeInt(u32, @intCast(evaluations.len), .little);
    for (evaluations) |binding| {
        try writer.writeInt(u64, binding.size_bytes, .little);
        try writer.writeAll(try resident_arena.bytes(binding));
    }
    try writer.flush();
}

pub fn spillRetainedMerkleLayers(
    allocator: std.mem.Allocator,
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    tree_index: u32,
    path: []const u8,
) !void {
    const layers = try collectTreePurpose(allocator, schedule, plan, "RetainedMerkleLayers", tree_index);
    defer allocator.free(layers);
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    var buffer: [1 << 20]u8 = undefined;
    var file_writer = file.writer(&buffer);
    const writer = &file_writer.interface;
    try writer.writeAll("STWZMRK\x00");
    try writer.writeInt(u32, 1, .little);
    try writer.writeInt(u32, tree_index, .little);
    try writer.writeInt(u32, @intCast(layers.len), .little);
    for (layers) |binding| {
        try writer.writeInt(u64, binding.size_bytes, .little);
        try writer.writeAll(try resident_arena.bytes(binding));
    }
    try writer.flush();
}

pub fn restoreRetainedMerkleLayers(
    allocator: std.mem.Allocator,
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    tree_index: u32,
    path: []const u8,
) !void {
    const layers = try collectTreePurpose(allocator, schedule, plan, "RetainedMerkleLayers", tree_index);
    defer allocator.free(layers);
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    var buffer: [1 << 20]u8 = undefined;
    var file_reader = file.reader(&buffer);
    const reader = &file_reader.interface;
    if (!std.mem.eql(u8, try reader.takeArray(8), "STWZMRK\x00") or
        try reader.takeInt(u32, .little) != 1 or
        try reader.takeInt(u32, .little) != tree_index or
        try reader.takeInt(u32, .little) != layers.len)
        return Error.InvalidSchedule;
    for (layers) |binding| {
        if (try reader.takeInt(u64, .little) != binding.size_bytes) return Error.InvalidBindingSize;
        try reader.readSliceAll(try resident_arena.bytes(binding));
    }
    var trailing: [1]u8 = undefined;
    if (try reader.readSliceShort(&trailing) != 0) return Error.InvalidSchedule;
}

pub fn restorePreprocessedEvaluations(
    allocator: std.mem.Allocator,
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    path: []const u8,
) !void {
    const evaluations = try collectScheduleOrder(allocator, schedule, plan, "PreprocessedEvaluations");
    defer allocator.free(evaluations);
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    var buffer: [1 << 20]u8 = undefined;
    var file_reader = file.reader(&buffer);
    const reader = &file_reader.interface;
    if (!std.mem.eql(u8, try reader.takeArray(8), "STWZPEV\x00") or
        try reader.takeInt(u32, .little) != 1 or
        try reader.takeInt(u32, .little) != evaluations.len)
        return Error.InvalidSchedule;
    for (evaluations) |binding| {
        if (try reader.takeInt(u64, .little) != binding.size_bytes) return Error.InvalidBindingSize;
        try reader.readSliceAll(try resident_arena.bytes(binding));
    }
    var trailing: [1]u8 = undefined;
    if (try reader.readSliceShort(&trailing) != 0) return Error.InvalidSchedule;
}

pub fn restoreFixedTablePreprocessedEvaluations(
    allocator: std.mem.Allocator,
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    fixed_bundle: fixed_table_bundle_mod.Bundle,
    path: []const u8,
) !void {
    var wanted = [_]bool{false} ** 161;
    for (fixed_bundle.entries) |entry| {
        const lookups = collectComponent(allocator, schedule, plan, "LookupInputs", entry.component) catch |err| switch (err) {
            schedule_bindings.Error.MissingBinding => continue,
            else => return err,
        };
        allocator.free(lookups);
        for (entry.preprocessed_sources) |identity| {
            const source_ordinal = fixed_bundle.identityOrdinal(identity) orelse return Error.MissingBinding;
            if (source_ordinal >= wanted.len) return Error.InvalidCardinality;
            wanted[source_ordinal] = true;
        }
    }
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    var buffer: [1 << 20]u8 = undefined;
    var file_reader = file.reader(&buffer);
    const reader = &file_reader.interface;
    var evaluation_count: usize = 0;
    for (schedule) |entry| if (std.mem.eql(u8, try purpose(entry), "PreprocessedEvaluations")) {
        evaluation_count += 1;
    };
    if (!std.mem.eql(u8, try reader.takeArray(8), "STWZPEV\x00") or
        try reader.takeInt(u32, .little) != 1 or
        try reader.takeInt(u32, .little) != evaluation_count)
        return Error.InvalidSchedule;
    var seen: usize = 0;
    for (schedule) |entry| {
        if (!std.mem.eql(u8, try purpose(entry), "PreprocessedEvaluations")) continue;
        const binding = plan.binding(try logicalId(entry)) catch return Error.MissingBinding;
        const size_bytes = try reader.takeInt(u64, .little);
        if (size_bytes != binding.size_bytes) return Error.InvalidBindingSize;
        const source_ordinal = try ordinal(entry);
        if (source_ordinal >= wanted.len) return Error.InvalidCardinality;
        if (wanted[source_ordinal])
            try reader.readSliceAll(try resident_arena.bytes(binding))
        else
            try reader.discardAll64(size_bytes);
        seen += 1;
    }
    if (seen != evaluation_count) return Error.InvalidPreprocessedCount;
    var trailing: [1]u8 = undefined;
    if (try reader.readSliceShort(&trailing) != 0) return Error.InvalidSchedule;
}

pub const populateProtocolTwiddles = resident_twiddles.populateProtocolTwiddles;
pub const populateForwardTwiddles = resident_twiddles.populateForwardTwiddles;
pub const populateNamedInverseTwiddles = resident_twiddles.populateNamedInverseTwiddles;
pub const populateQuotientInverseTwiddles = resident_twiddles.populateQuotientInverseTwiddles;

const populateInverseTwiddles = resident_twiddles.populateInverseTwiddles;
const populateForwardTwiddleBinding = resident_twiddles.populateForwardTwiddleBinding;
const twiddleBankBinding = resident_twiddles.twiddleBankBinding;
const twiddleBindingForLog = resident_twiddles.twiddleBindingForLog;
const twiddleOffsetForLog = resident_twiddles.twiddleOffsetForLog;

pub const TranscriptBootstrapValidationOptions = transcript_fixture.TranscriptBootstrapValidationOptions;
pub const validateTranscriptBootstrap = transcript_fixture.validateTranscriptBootstrap;
pub const restoreTranscriptBootstrap = transcript_fixture.restoreTranscriptBootstrap;

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
            schedule_bindings.Error.MissingBinding => continue,
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
    for (fixed_bundle.entries, 0..) |entry, entry_index| {
        const destination = oneComponent(schedule, plan, "LookupInputs", entry.component) catch continue;
        if (destination.offset_bytes >= @as(u64, std.math.maxInt(u32)) * 4) {
            std.debug.print("fixed_table_high_binding index={d} component={s} destination_offset={d} destination_size={d} rows={d}\n", .{
                entry_index, entry.component, destination.offset_bytes, destination.size_bytes, entry.row_count,
            });
        }
    }
    return protocol_recipes.FixedTableBatchRecipe.init(allocator, metal, resident_arena, bindings.items);
}

/// Resolves a component into the filtered plan order used by
/// `prepareFixedTableBatch`. This order is intentionally independent of the
/// fixed BaseTrace-copy subset owned by `NativeBaseInterpolationBatch`.
pub fn fixedLookupIndex(
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    fixed_bundle: fixed_table_bundle_mod.Bundle,
    component: []const u8,
) !?usize {
    var active_index: usize = 0;
    var found: ?usize = null;
    for (fixed_bundle.entries) |entry| {
        _ = oneComponent(schedule, plan, "LookupInputs", entry.component) catch |err| switch (err) {
            schedule_bindings.Error.MissingBinding => continue,
            else => return err,
        };
        if (std.mem.eql(u8, entry.component, component)) {
            if (found != null) return Error.DuplicateBinding;
            found = active_index;
        }
        active_index += 1;
    }
    return found;
}

pub const MultiplicityFeedBatch = struct {
    allocator: std.mem.Allocator,
    bounds: []protocol_recipes.BoundWitnessFeed,
    producers: []const []const u8,
    batch: protocol_recipes.WitnessFeedBatchRecipe,

    pub fn execute(self: *MultiplicityFeedBatch) !void {
        try self.batch.execute();
    }

    pub fn begin(self: *MultiplicityFeedBatch) !void {
        try self.batch.clear();
    }

    pub fn resetForRequest(self: *MultiplicityFeedBatch) void {
        self.batch.resetForRequest();
    }

    pub fn executeProducer(self: *MultiplicityFeedBatch, producer: []const u8) !void {
        for (self.producers, 0..) |candidate, index| {
            if (!std.mem.eql(u8, candidate, producer)) continue;
            try self.batch.executeIndex(index);
            return;
        }
        return Error.MissingBinding;
    }

    pub fn deinit(self: *MultiplicityFeedBatch) void {
        self.batch.deinit();
        for (self.producers) |producer| self.allocator.free(producer);
        self.allocator.free(self.producers);
        for (self.bounds) |*bound| bound.deinit();
        self.allocator.free(self.bounds);
        self.* = undefined;
    }
};

fn runtimeFeedRowCount(source_slab: arena_plan.Binding, sub_words_per_row: u32) !u32 {
    const row_bytes = std.math.mul(u64, sub_words_per_row, @sizeOf(u32)) catch return Error.InvalidBindingSize;
    if (row_bytes == 0 or source_slab.size_bytes == 0 or source_slab.size_bytes % row_bytes != 0)
        return Error.InvalidBindingSize;
    const row_count = std.math.cast(u32, source_slab.size_bytes / row_bytes) orelse return Error.InvalidBindingSize;
    if (!std.math.isPowerOfTwo(row_count)) return Error.InvalidBindingSize;
    return row_count;
}

fn runtimeFeedDestinationColumnBytes(slab: arena_plan.Binding, width: u32) !u64 {
    if (width == 0 or slab.size_bytes == 0 or slab.size_bytes % width != 0)
        return Error.InvalidBindingSize;
    const column_bytes = slab.size_bytes / width;
    if (column_bytes % @sizeOf(u32) != 0 or !std.math.isPowerOfTwo(column_bytes / @sizeOf(u32)))
        return Error.InvalidBindingSize;
    return column_bytes;
}

fn recordFeedDestinationWidth(
    widths: *std.StringHashMap(u32),
    destination: feed_bundle_mod.Destination,
    table_size: u32,
    referenced_columns: u32,
) !void {
    if (table_size == 0 or destination.words == 0 or destination.words % table_size != 0)
        return Error.InvalidCardinality;
    const width = std.math.cast(u32, destination.words / table_size) orelse return Error.InvalidCardinality;
    if (width < referenced_columns) return Error.InvalidCardinality;
    const entry = try widths.getOrPut(destination.name);
    if (entry.found_existing and entry.value_ptr.* != width) return Error.InvalidCardinality;
    entry.value_ptr.* = width;
}

const aot_narrow_address_limit_bytes = (@as(u64, std.math.maxInt(u32)) + 1) * @sizeOf(u32);

fn aotBindingFitsNarrowAddress(binding: arena_plan.Binding) bool {
    if (binding.offset_bytes % @sizeOf(u32) != 0 or binding.size_bytes % @sizeOf(u32) != 0)
        return false;
    return binding.offset_bytes <= aot_narrow_address_limit_bytes and
        binding.size_bytes <= aot_narrow_address_limit_bytes - binding.offset_bytes;
}

fn recordAotHighBinding(
    high_count: *usize,
    component: []const u8,
    binding_purpose: []const u8,
    binding: arena_plan.Binding,
) void {
    if (aotBindingFitsNarrowAddress(binding)) return;
    high_count.* += 1;
    std.debug.print(
        "aot_high_binding component={s} purpose={s} id={} offset={} end={} words={}\n",
        .{
            component,
            binding_purpose,
            binding.logical_id,
            binding.offset_bytes,
            binding.offset_bytes + binding.size_bytes,
            binding.size_bytes / @sizeOf(u32),
        },
    );
}

pub fn prepareMultiplicityFeedBatch(
    allocator: std.mem.Allocator,
    metal: *metal_runtime.Runtime,
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    bundle: feed_bundle_mod.Bundle,
) !MultiplicityFeedBatch {
    var widths = std.StringHashMap(u32).init(allocator);
    defer widths.deinit();
    for (bundle.feeds) |feed| {
        var descriptor_index: usize = 0;
        while (descriptor_index < feed.descriptors.len) : (descriptor_index += 14) {
            const descriptor = feed.descriptors[descriptor_index .. descriptor_index + 14];
            if (descriptor[10] >= feed.destinations.len) return Error.InvalidCardinality;
            const primary_width: u32 = if (descriptor[11] == 3) 16 else descriptor[7] + 1;
            try recordFeedDestinationWidth(
                &widths,
                feed.destinations[descriptor[10]],
                descriptor[8],
                primary_width,
            );
            if (descriptor[11] == 1) {
                if (descriptor[13] >= feed.destinations.len) return Error.InvalidCardinality;
                try recordFeedDestinationWidth(
                    &widths,
                    feed.destinations[descriptor[13]],
                    descriptor[12],
                    descriptor[7] + 1,
                );
            }
        }
    }

    const bounds = try allocator.alloc(protocol_recipes.BoundWitnessFeed, bundle.feeds.len);
    const column_lengths = try allocator.alloc(u32, bundle.feeds.len);
    defer allocator.free(column_lengths);
    var initialized: usize = 0;
    errdefer {
        for (bounds[0..initialized]) |*bound| bound.deinit();
        allocator.free(bounds);
    }
    while (initialized < bundle.feeds.len) : (initialized += 1) {
        const feed = bundle.feeds[initialized];
        const source_slab = try oneComponent(schedule, plan, "SubcomponentInputs", feed.producer);
        const row_count = try runtimeFeedRowCount(source_slab, feed.sub_words_per_row);
        column_lengths[initialized] = row_count;
        const source_column_bytes = @as(u64, row_count) * @sizeOf(u32);
        const source_columns = try allocator.alloc(arena_plan.Binding, feed.sub_words_per_row);
        defer allocator.free(source_columns);
        for (source_columns, 0..) |*column, index| {
            column.* = source_slab;
            column.offset_bytes += @as(u64, @intCast(index)) * source_column_bytes;
            column.size_bytes = source_column_bytes;
            if (column.offset_bytes >= @as(u64, std.math.maxInt(u32)) * 4) {
                std.debug.print("multiplicity_feed_high_source feed={d} producer={s} column={d} offset={d} size={d}\n", .{
                    initialized, feed.producer, index, column.offset_bytes, column.size_bytes,
                });
            }
        }

        const destinations = try allocator.alloc(protocol_recipes.DestinationColumns, feed.destinations.len);
        defer allocator.free(destinations);
        const destination_columns = try allocator.alloc([]arena_plan.Binding, feed.destinations.len);
        defer {
            for (destination_columns) |columns| allocator.free(columns);
            allocator.free(destination_columns);
        }
        for (feed.destinations, destinations, destination_columns) |destination, *bound_destination, *columns| {
            const slab = try multiplicityDestination(schedule, plan, destination.name);
            const width = widths.get(destination.name) orelse return Error.InvalidCardinality;
            if (destination.words == 0 or destination.words % width != 0) return Error.InvalidBindingSize;
            const column_bytes = try runtimeFeedDestinationColumnBytes(slab, width);
            columns.* = try allocator.alloc(arena_plan.Binding, width);
            for (columns.*, 0..) |*column, index| {
                column.* = slab;
                column.offset_bytes += @as(u64, @intCast(index)) * column_bytes;
                column.size_bytes = column_bytes;
                if (column.offset_bytes >= @as(u64, std.math.maxInt(u32)) * 4) {
                    std.debug.print("multiplicity_feed_high_destination feed={d} producer={s} destination={s} column={d} offset={d} size={d}\n", .{
                        initialized, feed.producer, destination.name, index, column.offset_bytes, column.size_bytes,
                    });
                }
            }
            bound_destination.* = .{ .columns = columns.* };
        }
        bounds[initialized] = protocol_recipes.BoundWitnessFeed.init(
            allocator,
            source_columns,
            destinations,
            feed.descriptors,
            feed.luts,
            row_count,
        ) catch |err| {
            std.debug.print(
                "multiplicity_feed_invalid feed={d} producer={s} source_offset={d} source_end={d} source_words={d}\n",
                .{ initialized, feed.producer, source_slab.offset_bytes, source_slab.offset_bytes + source_slab.size_bytes, source_slab.size_bytes / 4 },
            );
            for (feed.destinations, destination_columns) |destination, columns| {
                if (columns.len == 0) continue;
                const first = columns[0];
                const last = columns[columns.len - 1];
                std.debug.print(
                    "multiplicity_feed_invalid_destination name={s} first_offset={d} end={d} columns={d}\n",
                    .{ destination.name, first.offset_bytes, last.offset_bytes + last.size_bytes, columns.len },
                );
            }
            return err;
        };
    }

    const entries = try allocator.alloc(protocol_recipes.WitnessFeedBatchEntry, bounds.len);
    defer allocator.free(entries);
    for (bounds, column_lengths, entries) |*bound, column_length, *entry|
        entry.* = .{ .bound = bound, .column_length = column_length };
    const producers = try allocator.alloc([]const u8, bundle.feeds.len);
    var producers_initialized: usize = 0;
    errdefer {
        for (producers[0..producers_initialized]) |producer| allocator.free(producer);
        allocator.free(producers);
    }
    while (producers_initialized < bundle.feeds.len) : (producers_initialized += 1)
        producers[producers_initialized] = try allocator.dupe(u8, bundle.feeds[producers_initialized].producer);
    return .{
        .allocator = allocator,
        .bounds = bounds,
        .producers = producers,
        .batch = try protocol_recipes.WitnessFeedBatchRecipe.init(allocator, metal, resident_arena, entries),
    };
}

pub fn clearFixedMultiplicities(
    allocator: std.mem.Allocator,
    metal: *metal_runtime.Runtime,
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
) !void {
    const bindings = try collectScheduleOrder(allocator, schedule, plan, "FixedMultiplicity");
    defer allocator.free(bindings);
    const ranges = try allocator.alloc([2]u32, bindings.len);
    defer allocator.free(ranges);
    for (bindings, ranges) |binding, *range| {
        if (binding.size_bytes % 4 != 0) return Error.InvalidBindingSize;
        range.* = .{
            try wordOffset(binding),
            std.math.cast(u32, binding.size_bytes / 4) orelse return Error.InvalidBindingSize,
        };
    }
    try metal.clearArenaRanges(resident_arena.buffer, ranges);
}

fn multiplicityDestination(
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    name: []const u8,
) !arena_plan.Binding {
    if (std.mem.eql(u8, name, "memory_address_to_id"))
        return oneComponentOrdinal(schedule, plan, "RuntimeMultiplicity", "memory_address_to_id", 21);
    if (std.mem.eql(u8, name, "memory_id_to_big"))
        return oneComponentOrdinal(schedule, plan, "RuntimeMultiplicity", "memory_id_to_big", 22);
    if (std.mem.eql(u8, name, "memory_id_to_big#small"))
        return oneComponentOrdinal(schedule, plan, "RuntimeMultiplicity", "memory_id_to_big", 23);
    return oneComponent(schedule, plan, "FixedMultiplicity", name);
}

pub const RecordedBaseInterpolationBatch = struct {
    allocator: std.mem.Allocator,
    resident_arena: *arena_plan.ResidentArena,
    recipes: []protocol_recipes.CircleIfftRecipe,
    ec_op_recipe: ?protocol_recipes.CircleIfftRecipe,
    ec_op_owner: ?u32,

    pub fn deinit(self: *RecordedBaseInterpolationBatch) void {
        if (self.ec_op_recipe) |*recipe| recipe.deinit();
        for (self.recipes) |*recipe| recipe.deinit();
        self.allocator.free(self.recipes);
        self.* = undefined;
    }

    pub fn resetForRequest(self: *RecordedBaseInterpolationBatch) void {
        for (self.recipes) |*recipe| recipe.resetForRequest();
        if (self.ec_op_recipe) |*recipe| recipe.resetForRequest();
    }

    pub fn executeIndex(self: *RecordedBaseInterpolationBatch, component_index: u32) !f64 {
        if (component_index >= self.recipes.len) return Error.InvalidCardinality;
        var gpu_ms: f64 = 0;
        const recipe = &self.recipes[component_index];
        const initial = recipe.accumulated_gpu_ms;
        try recipe.execute();
        gpu_ms += recipe.accumulated_gpu_ms - initial;
        return gpu_ms;
    }

    pub fn interpolateEcOp(self: *RecordedBaseInterpolationBatch, component_index: u32) !f64 {
        if (self.ec_op_owner == null or self.ec_op_owner.? != component_index)
            return Error.InvalidCardinality;
        if (self.ec_op_recipe) |*ec_op| {
            const initial = ec_op.accumulated_gpu_ms;
            try ec_op.execute();
            return ec_op.accumulated_gpu_ms - initial;
        }
        return Error.MissingBinding;
    }
};

const FixedBaseTraceOperation = struct {
    allocator: std.mem.Allocator,
    component: []const u8,
    copy: metal_runtime.ArenaCopyPlan,
    interpolation: protocol_recipes.CircleIfftRecipe,

    fn init(
        allocator: std.mem.Allocator,
        component: []const u8,
        copy: metal_runtime.ArenaCopyPlan,
        interpolation: protocol_recipes.CircleIfftRecipe,
    ) !FixedBaseTraceOperation {
        return .{
            .allocator = allocator,
            .component = try allocator.dupe(u8, component),
            .copy = copy,
            .interpolation = interpolation,
        };
    }

    fn deinit(self: *FixedBaseTraceOperation) void {
        self.interpolation.deinit();
        self.copy.deinit();
        self.allocator.free(self.component);
        self.* = undefined;
    }
};

pub const NativeBaseInterpolationBatch = struct {
    allocator: std.mem.Allocator,
    metal: *metal_runtime.Runtime,
    resident_arena: *arena_plan.ResidentArena,
    memory_address: protocol_recipes.CircleIfftRecipe,
    memory_values: []protocol_recipes.CircleIfftRecipe,
    fixed: []FixedBaseTraceOperation,

    pub fn deinit(self: *NativeBaseInterpolationBatch) void {
        for (self.fixed) |*operation| operation.deinit();
        self.allocator.free(self.fixed);
        for (self.memory_values) |*recipe| recipe.deinit();
        self.allocator.free(self.memory_values);
        self.memory_address.deinit();
        self.* = undefined;
    }

    pub fn resetForRequest(self: *NativeBaseInterpolationBatch) void {
        self.memory_address.resetForRequest();
        for (self.memory_values) |*recipe| recipe.resetForRequest();
        for (self.fixed) |*operation| operation.interpolation.resetForRequest();
    }

    pub fn interpolateMemoryAddress(self: *NativeBaseInterpolationBatch) !f64 {
        const initial = self.memory_address.accumulated_gpu_ms;
        try self.memory_address.execute();
        return self.memory_address.accumulated_gpu_ms - initial;
    }

    pub fn interpolateMemoryValues(self: *NativeBaseInterpolationBatch) !f64 {
        var gpu_ms: f64 = 0;
        for (self.memory_values) |*recipe| {
            const initial = recipe.accumulated_gpu_ms;
            try recipe.execute();
            gpu_ms += recipe.accumulated_gpu_ms - initial;
        }
        return gpu_ms;
    }

    pub fn executeFixed(
        self: *NativeBaseInterpolationBatch,
        schedule: []const std.json.Value,
        plan: arena_plan.Plan,
    ) !f64 {
        var gpu_ms: f64 = 0;
        for (self.fixed) |*operation| {
            gpu_ms += try self.metal.arenaCopyPrepared(self.resident_arena.buffer, operation.copy);
            if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_BASE_EVAL_DIGESTS"))
                try logComponentBaseEvalDigests(
                    self.resident_arena,
                    schedule,
                    plan,
                    operation.component,
                );
            const initial = operation.interpolation.accumulated_gpu_ms;
            try operation.interpolation.execute();
            gpu_ms += operation.interpolation.accumulated_gpu_ms - initial;
        }
        return gpu_ms;
    }

    pub fn fixedIndex(self: NativeBaseInterpolationBatch, component: []const u8) !?u32 {
        var found: ?u32 = null;
        for (self.fixed, 0..) |operation, index| {
            if (!std.mem.eql(u8, operation.component, component)) continue;
            if (found != null) return Error.DuplicateBinding;
            found = @intCast(index);
        }
        return found;
    }

    /// Recreates only the fixed component's BaseTrace evaluations. Interaction
    /// replay consumes them immediately and does not need to rewrite the base
    /// coefficient tree.
    pub fn materializeFixed(self: *NativeBaseInterpolationBatch, component: []const u8) !f64 {
        const index = try self.fixedIndex(component) orelse return Error.MissingBinding;
        return self.metal.arenaCopyPrepared(self.resident_arena.buffer, self.fixed[index].copy);
    }
};

pub fn prepareRecordedBaseInterpolation(
    allocator: std.mem.Allocator,
    metal: *metal_runtime.Runtime,
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    proof: *const cairo_proof_plan.CairoProofPlan,
    twiddle_storage: arena_plan.Binding,
) !RecordedBaseInterpolationBatch {
    const recipes = try allocator.alloc(protocol_recipes.CircleIfftRecipe, proof.components.len);
    var initialized: usize = 0;
    errdefer {
        for (recipes[0..initialized]) |*recipe| recipe.deinit();
        allocator.free(recipes);
    }
    while (initialized < recipes.len) : (initialized += 1) {
        const component = proof.components[initialized];
        recipes[initialized] = try prepareComponentInterpolation(
            allocator,
            metal,
            resident_arena,
            schedule,
            plan,
            component.name,
            twiddle_storage,
        );
    }
    const ec_op_owner = proof.componentIndex("partial_ec_mul_generic");
    var ec_op_recipe: ?protocol_recipes.CircleIfftRecipe = null;
    errdefer if (ec_op_recipe) |*recipe| recipe.deinit();
    if (ec_op_owner != null) {
        ec_op_recipe = try prepareComponentInterpolation(
            allocator,
            metal,
            resident_arena,
            schedule,
            plan,
            "ec_op_builtin",
            twiddle_storage,
        );
    }
    return .{
        .allocator = allocator,
        .resident_arena = resident_arena,
        .recipes = recipes,
        .ec_op_recipe = ec_op_recipe,
        .ec_op_owner = ec_op_owner,
    };
}

pub fn prepareNativeBaseInterpolation(
    allocator: std.mem.Allocator,
    metal: *metal_runtime.Runtime,
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    fixed_bundle: fixed_table_bundle_mod.Bundle,
    twiddle_storage: arena_plan.Binding,
) !NativeBaseInterpolationBatch {
    var memory_address = try prepareComponentInterpolation(
        allocator,
        metal,
        resident_arena,
        schedule,
        plan,
        "memory_address_to_id",
        twiddle_storage,
    );
    errdefer memory_address.deinit();
    const memory_values = try prepareComponentInterpolationGroups(
        allocator,
        metal,
        resident_arena,
        schedule,
        plan,
        "memory_id_to_big",
        twiddle_storage,
    );
    errdefer {
        for (memory_values) |*recipe| recipe.deinit();
        allocator.free(memory_values);
    }

    var operations = std.ArrayList(FixedBaseTraceOperation).empty;
    errdefer {
        for (operations.items) |*operation| operation.deinit();
        operations.deinit(allocator);
    }
    for (fixed_bundle.entries) |entry| {
        const traces = collectComponent(allocator, schedule, plan, "BaseTrace", entry.component) catch |err| switch (err) {
            schedule_bindings.Error.MissingBinding => continue,
            else => return err,
        };
        defer allocator.free(traces);
        if (traces.len != entry.trace_multiplicity_columns.len or traces.len == 0)
            return Error.InvalidCardinality;
        const multiplicity = try oneComponent(schedule, plan, "FixedMultiplicity", entry.component);
        const column_bytes = @as(u64, entry.row_count) * 4;
        if (multiplicity.size_bytes != column_bytes * entry.multiplicity_columns)
            return Error.InvalidBindingSize;
        const ranges = try allocator.alloc(metal_runtime.ArenaCopyRange, traces.len);
        defer allocator.free(ranges);
        for (entry.trace_multiplicity_columns, traces, ranges) |source_column, trace, *range| {
            if (trace.size_bytes != column_bytes) return Error.InvalidBindingSize;
            const source_bytes = multiplicity.offset_bytes + @as(u64, source_column) * column_bytes;
            if (source_bytes % 4 != 0 or trace.offset_bytes % 4 != 0)
                return Error.InvalidBindingSize;
            range.* = .{
                .source_word_offset = std.math.cast(u32, source_bytes / 4) orelse return Error.InvalidBindingSize,
                .destination_word_offset = try wordOffset(trace),
                .word_count = entry.row_count,
            };
        }
        var copy_owner: ?metal_runtime.ArenaCopyPlan = try metal.prepareArenaCopies(ranges);
        errdefer if (copy_owner) |*copy| copy.deinit();
        var interpolation_owner: ?protocol_recipes.CircleIfftRecipe = try prepareComponentInterpolation(
            allocator,
            metal,
            resident_arena,
            schedule,
            plan,
            entry.component,
            twiddle_storage,
        );
        errdefer if (interpolation_owner) |*interpolation| interpolation.deinit();
        var operation = try FixedBaseTraceOperation.init(
            allocator,
            entry.component,
            copy_owner.?,
            interpolation_owner.?,
        );
        copy_owner = null;
        interpolation_owner = null;
        errdefer operation.deinit();
        try operations.append(allocator, operation);
    }
    return .{
        .allocator = allocator,
        .metal = metal,
        .resident_arena = resident_arena,
        .memory_address = memory_address,
        .memory_values = memory_values,
        .fixed = try operations.toOwnedSlice(allocator),
    };
}

fn prepareComponentInterpolation(
    allocator: std.mem.Allocator,
    metal: *metal_runtime.Runtime,
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    component: []const u8,
    twiddle_storage: arena_plan.Binding,
) !protocol_recipes.CircleIfftRecipe {
    const recipes = try prepareComponentInterpolationGroups(
        allocator,
        metal,
        resident_arena,
        schedule,
        plan,
        component,
        twiddle_storage,
    );
    if (recipes.len != 1) {
        for (recipes) |*recipe| recipe.deinit();
        allocator.free(recipes);
        return Error.InvalidCardinality;
    }
    const result = recipes[0];
    allocator.free(recipes);
    return result;
}

fn prepareComponentInterpolationGroups(
    allocator: std.mem.Allocator,
    metal: *metal_runtime.Runtime,
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    component: []const u8,
    twiddle_storage: arena_plan.Binding,
) ![]protocol_recipes.CircleIfftRecipe {
    return prepareComponentInterpolationGroupsForPurposes(
        allocator,
        metal,
        resident_arena,
        schedule,
        plan,
        component,
        "BaseTrace",
        "BaseCoefficients",
        twiddle_storage,
    );
}

fn prepareComponentInterpolationGroupsForPurposes(
    allocator: std.mem.Allocator,
    metal: *metal_runtime.Runtime,
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    component: []const u8,
    source_purpose: []const u8,
    destination_purpose: []const u8,
    twiddle_storage: arena_plan.Binding,
) ![]protocol_recipes.CircleIfftRecipe {
    const source_groups = try collectComponentBindingGroups(allocator, schedule, plan, source_purpose, component);
    defer {
        for (source_groups) |group| allocator.free(group);
        allocator.free(source_groups);
    }
    const destination_groups = try collectComponentBindingGroups(allocator, schedule, plan, destination_purpose, component);
    defer {
        for (destination_groups) |group| allocator.free(group);
        allocator.free(destination_groups);
    }
    if (source_groups.len != destination_groups.len) return Error.InvalidCardinality;
    const recipes = try allocator.alloc(protocol_recipes.CircleIfftRecipe, source_groups.len);
    var initialized: usize = 0;
    errdefer {
        for (recipes[0..initialized]) |*recipe| recipe.deinit();
        allocator.free(recipes);
    }
    while (initialized < recipes.len) : (initialized += 1) {
        const sources = source_groups[initialized];
        const destinations = destination_groups[initialized];
        if (sources.len == 0 or sources.len != destinations.len or sources[0].size_bytes % 4 != 0)
            return Error.InvalidCardinality;
        const rows = sources[0].size_bytes / 4;
        if (rows < 16 or !std.math.isPowerOfTwo(rows)) return Error.InvalidBindingSize;
        for (sources, destinations) |source, destination| {
            if (source.size_bytes / 4 != rows or destination.size_bytes != source.size_bytes)
                return Error.InvalidBindingSize;
        }
        const log_size: u32 = std.math.log2_int(u64, rows);
        recipes[initialized] = try protocol_recipes.CircleIfftRecipe.init(
            allocator,
            metal,
            resident_arena,
            sources,
            destinations,
            try twiddleBindingForLog(twiddle_storage, log_size),
            log_size,
            try M31.fromCanonical(@as(u32, 1) << @intCast(log_size)).inv(),
        );
    }
    return recipes;
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
    twiddle_storage: ?arena_plan.Binding,
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
        var source_offsets = std.ArrayList(u64).empty;
        defer source_offsets.deinit(allocator);
        var destination_offsets = std.ArrayList(u64).empty;
        defer destination_offsets.deinit(allocator);
        for (sources, destinations) |source, destination| {
            if (source.size_bytes != expected_bytes) continue;
            if (destination.size_bytes != expected_bytes) return Error.InvalidBindingSize;
            try source_offsets.append(allocator, source.offset_bytes / 4);
            try destination_offsets.append(allocator, destination.offset_bytes / 4);
        }
        if (source_offsets.items.len == 0) continue;
        const scale = (try M31.fromCanonical(@as(u32, 1) << @intCast(log_size)).inv()).v;
        var prepared = try metal.prepareCircleIfft(
            source_offsets.items,
            destination_offsets.items,
            log_size,
            try twiddleOffsetForLog(if (twiddle_storage) |storage| twiddleBankBinding(storage, log_size) else inverse_twiddles, log_size),
            scale,
        );
        defer prepared.deinit();
        gpu_ms += try metal.circleIfftPrepared(resident_arena.buffer, prepared);
    }
    return gpu_ms;
}

pub fn interpolateAvailablePreprocessedColumns(
    allocator: std.mem.Allocator,
    metal: *metal_runtime.Runtime,
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
) !f64 {
    const inverse_twiddles = try one(schedule, plan, "PreprocessedInverseTwiddles");
    var gpu_ms: f64 = 0;
    for (4..25) |log_size_usize| {
        const log_size: u32 = @intCast(log_size_usize);
        const expected_bytes = (@as(u64, 1) << @intCast(log_size)) * 4;
        var source_offsets = std.ArrayList(u64).empty;
        defer source_offsets.deinit(allocator);
        var destination_offsets = std.ArrayList(u64).empty;
        defer destination_offsets.deinit(allocator);
        for (schedule) |entry| {
            if (!std.mem.eql(u8, try purpose(entry), "PreprocessedEvaluations")) continue;
            const source = plan.binding(try logicalId(entry)) catch return Error.MissingBinding;
            if (source.size_bytes != expected_bytes) continue;
            const destination = try oneOrdinal(
                schedule,
                plan,
                "PreprocessedCoefficients",
                try ordinal(entry),
            );
            if (destination.size_bytes != source.size_bytes) return Error.InvalidBindingSize;
            try source_offsets.append(allocator, source.offset_bytes / 4);
            try destination_offsets.append(allocator, destination.offset_bytes / 4);
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
    output_mode: protocol_recipes.EcOpOutputMode,
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
    }, output_mode);
}

pub fn prepareAotWitnessBatch(
    allocator: std.mem.Allocator,
    metal: *metal_runtime.Runtime,
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    witness_bundle: witness_bundle_mod.Bundle,
    fixed_bundle: fixed_table_bundle_mod.Bundle,
) !protocol_recipes.AotWitnessBatchRecipe {
    return prepareAotWitnessBatchForMode(
        allocator,
        metal,
        resident_arena,
        schedule,
        plan,
        witness_bundle,
        fixed_bundle,
        .base,
    );
}

/// Prepares lookup-only witness replay for the interaction epoch. Generated
/// kernels suppress base columns and multiplicities, but retain subcomponent
/// words so the proof-plan DAG can reconstruct gathered and compacted inputs.
pub fn prepareAotInteractionBatch(
    allocator: std.mem.Allocator,
    metal: *metal_runtime.Runtime,
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    witness_bundle: witness_bundle_mod.Bundle,
    fixed_bundle: fixed_table_bundle_mod.Bundle,
) !protocol_recipes.AotWitnessBatchRecipe {
    return prepareAotWitnessBatchForMode(
        allocator,
        metal,
        resident_arena,
        schedule,
        plan,
        witness_bundle,
        fixed_bundle,
        .interaction,
    );
}

const FixedDeductionRequirements = struct {
    pedersen: bool = false,
    poseidon: bool = false,
};

fn fixedDeductionRequirements(bundle: witness_bundle_mod.Bundle) FixedDeductionRequirements {
    var result = FixedDeductionRequirements{};
    for (bundle.entries) |entry| {
        for (entry.program.insts) |inst| {
            if (@as(witness_program_mod.Op, @enumFromInt(inst.op)) != .deduce_call) continue;
            switch (inst.imm) {
                2, 3 => result.pedersen = true,
                8, 10, 11 => result.poseidon = true,
                else => {},
            }
        }
    }
    return result;
}

fn prepareAotWitnessBatchForMode(
    allocator: std.mem.Allocator,
    metal: *metal_runtime.Runtime,
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    witness_bundle: witness_bundle_mod.Bundle,
    fixed_bundle: fixed_table_bundle_mod.Bundle,
    mode: witness_codegen.KernelMode,
) !protocol_recipes.AotWitnessBatchRecipe {
    if (mode == .all) return Error.InvalidCardinality;
    const table_pointers_planned = try one(schedule, plan, "ExecutionTablePointers");
    const table_strides_planned = try one(schedule, plan, "ExecutionTableStrides");
    const table_pointers = table_pointers_planned;
    const table_strides = table_strides_planned;
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
    const stride_bytes = try resident_arena.bytes(table_strides);
    if (stride_bytes.len != 12) return Error.InvalidBindingSize;
    const strides = [3]u32{
        @intCast(execution_tables.items[0].size_bytes / 4),
        @intCast(big[0].size_bytes / 4),
        @intCast(small[0].size_bytes / 4),
    };

    const deduction_requirements = fixedDeductionRequirements(witness_bundle);
    const pedersen_entry = if (deduction_requirements.pedersen)
        fixed_bundle.find("pedersen_points_table_window_bits_18") orelse return Error.MissingBinding
    else
        null;
    const poseidon_entry = if (deduction_requirements.poseidon)
        fixed_bundle.find("poseidon_round_keys") orelse return Error.MissingBinding
    else
        null;
    const pedersen_pointers = if (pedersen_entry) |entry|
        try oneComponent(schedule, plan, "FixedTableSourcePointers", entry.component)
    else
        table_pointers;
    const poseidon_pointers = if (poseidon_entry) |entry|
        try oneComponent(schedule, plan, "FixedTableSourcePointers", entry.component)
    else
        table_pointers;
    const pedersen_sources = if (pedersen_entry) |entry|
        try collectPreprocessedBindings(allocator, schedule, plan, fixed_bundle, entry.preprocessed_sources)
    else
        try allocator.alloc(arena_plan.Binding, 0);
    defer allocator.free(pedersen_sources);
    const poseidon_sources = if (poseidon_entry) |entry|
        try collectPreprocessedBindings(allocator, schedule, plan, fixed_bundle, entry.preprocessed_sources)
    else
        try allocator.alloc(arena_plan.Binding, 0);
    defer allocator.free(poseidon_sources);

    var high_bindings: usize = 0;
    recordAotHighBinding(&high_bindings, "shared", "ExecutionTablePointers", table_pointers);
    recordAotHighBinding(&high_bindings, "shared", "ExecutionTableStrides", table_strides);
    if (pedersen_entry != null)
        recordAotHighBinding(&high_bindings, "shared", "PedersenSourcePointers", pedersen_pointers);
    if (poseidon_entry != null)
        recordAotHighBinding(&high_bindings, "shared", "PoseidonSourcePointers", poseidon_pointers);
    for (execution_tables.items) |binding|
        recordAotHighBinding(&high_bindings, "shared", "ExecutionTable", binding);
    for (pedersen_sources) |binding|
        recordAotHighBinding(&high_bindings, "shared", "PedersenSource", binding);
    for (poseidon_sources) |binding|
        recordAotHighBinding(&high_bindings, "shared", "PoseidonSource", binding);
    for (witness_bundle.entries) |entry| {
        const inputs = try collectComponent(allocator, schedule, plan, "WitnessInput", entry.label);
        defer allocator.free(inputs);
        const outputs = try collectComponent(allocator, schedule, plan, "BaseTrace", entry.label);
        defer allocator.free(outputs);
        for (inputs) |binding| recordAotHighBinding(&high_bindings, entry.label, "WitnessInput", binding);
        for (outputs) |binding| recordAotHighBinding(&high_bindings, entry.label, "BaseTrace", binding);
        recordAotHighBinding(
            &high_bindings,
            entry.label,
            "LookupInputs",
            try oneComponent(schedule, plan, "LookupInputs", entry.label),
        );
        recordAotHighBinding(
            &high_bindings,
            entry.label,
            "SubcomponentInputs",
            try oneComponent(schedule, plan, "SubcomponentInputs", entry.label),
        );
        recordAotHighBinding(
            &high_bindings,
            entry.label,
            "WitnessInputPointers",
            try oneComponent(schedule, plan, "WitnessInputPointers", entry.label),
        );
        recordAotHighBinding(
            &high_bindings,
            entry.label,
            "WitnessOutputPointers",
            try oneComponent(schedule, plan, "WitnessOutputPointers", entry.label),
        );
        recordAotHighBinding(
            &high_bindings,
            entry.label,
            "WitnessMultiplicityPointers",
            try oneComponent(schedule, plan, "WitnessMultiplicityPointers", entry.label),
        );
    }
    if (high_bindings != 0) {
        std.debug.print("aot_high_binding_summary count={} limit_bytes={}\n", .{ high_bindings, aot_narrow_address_limit_bytes });
        return Error.InvalidBindingSize;
    }

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
    const owned_inputs = try allocator.alloc([]arena_plan.Binding, witness_bundle.entries.len);
    var inputs_initialized: usize = 0;
    defer {
        for (owned_inputs[0..inputs_initialized]) |inputs| allocator.free(inputs);
        allocator.free(owned_inputs);
    }
    const owned_trace_outputs = try allocator.alloc([]arena_plan.Binding, witness_bundle.entries.len);
    var trace_outputs_initialized: usize = 0;
    defer {
        for (owned_trace_outputs[0..trace_outputs_initialized]) |outputs| allocator.free(outputs);
        allocator.free(owned_trace_outputs);
    }
    const owned_workspaces = try allocator.alloc([]protocol_recipes.AotWorkspaceWrite, witness_bundle.entries.len);
    var workspaces_initialized: usize = 0;
    defer {
        for (owned_workspaces[0..workspaces_initialized]) |writes| allocator.free(writes);
        allocator.free(owned_workspaces);
    }
    const kernel_modes = try allocator.alloc(witness_codegen.KernelMode, witness_bundle.entries.len);
    defer allocator.free(kernel_modes);

    for (witness_bundle.entries, invocations, names, owned_destinations, owned_inputs, owned_trace_outputs, owned_workspaces, kernel_modes) |entry, *invocation, *name, *owned, *input_storage, *output_storage, *workspace_storage, *kernel_mode| {
        const inputs = try collectComponent(allocator, schedule, plan, "WitnessInput", entry.label);
        input_storage.* = inputs;
        inputs_initialized += 1;
        const outputs = try collectComponent(allocator, schedule, plan, "BaseTrace", entry.label);
        output_storage.* = outputs;
        trace_outputs_initialized += 1;
        if (inputs.len != entry.program.n_inputs or outputs.len != entry.program.n_cols or outputs.len == 0)
            return Error.InvalidCardinality;
        const row_count = std.math.cast(u32, outputs[0].size_bytes / 4) orelse return Error.InvalidBindingSize;
        if (row_count == 0 or !std.math.isPowerOfTwo(row_count)) return Error.InvalidBindingSize;
        for (inputs) |binding| if (binding.size_bytes != @as(u64, row_count) * 4) return Error.InvalidBindingSize;
        for (outputs) |binding| if (binding.size_bytes != @as(u64, row_count) * 4) return Error.InvalidBindingSize;

        const input_pointers_planned = try oneComponent(schedule, plan, "WitnessInputPointers", entry.label);
        const output_pointers_planned = try oneComponent(schedule, plan, "WitnessOutputPointers", entry.label);
        const multiplicity_pointers_planned = try oneComponent(schedule, plan, "WitnessMultiplicityPointers", entry.label);
        if (input_pointers_planned.size_bytes > 2048 or output_pointers_planned.size_bytes > 8192 or
            multiplicity_pointers_planned.size_bytes > 2048)
            return Error.InvalidBindingSize;
        if (entry.program.n_mult_tables != 0) return Error.InvalidCardinality;
        const input_pointers = input_pointers_planned;
        const output_pointers = output_pointers_planned;
        const multiplicity_pointers = multiplicity_pointers_planned;

        const lookup = try oneComponent(schedule, plan, "LookupInputs", entry.label);
        const sub = try oneComponent(schedule, plan, "SubcomponentInputs", entry.label);
        if (lookup.size_bytes != @as(u64, row_count) * entry.program.n_lookup_words * 4 or
            sub.size_bytes != @as(u64, row_count) * entry.program.n_sub_words * 4)
            return Error.InvalidBindingSize;
        const retain_lookup = cairo_proof_plan.retainsLookupInputs(entry.label);
        kernel_mode.* = if (mode == .base and retain_lookup)
            .base_lookup
        else if (mode == .interaction and cairo_proof_plan.retainedLookupReplaysSubwords(entry.label))
            .interaction_subwords
        else
            mode;
        const destination_count: usize = switch (mode) {
            .base => outputs.len + 1 + @intFromBool(kernel_mode.* == .base_lookup),
            .interaction => if (kernel_mode.* == .interaction_subwords) 1 else 2,
            .all, .base_lookup, .interaction_subwords => unreachable,
        };
        owned.* = try allocator.alloc(arena_plan.Binding, destination_count);
        destinations_initialized += 1;
        switch (mode) {
            .base => {
                @memcpy(owned.*[0..outputs.len], outputs);
                owned.*[outputs.len] = sub;
                if (kernel_mode.* == .base_lookup) owned.*[outputs.len + 1] = lookup;
            },
            .interaction => {
                if (kernel_mode.* == .interaction_subwords) {
                    owned.*[0] = sub;
                } else {
                    owned.*[0] = lookup;
                    owned.*[1] = sub;
                }
            },
            .all, .base_lookup, .interaction_subwords => unreachable,
        }
        const workspace_count: usize = 5 +
            @as(usize, @intFromBool(pedersen_entry != null)) +
            @as(usize, @intFromBool(poseidon_entry != null));
        workspace_storage.* = try allocator.alloc(protocol_recipes.AotWorkspaceWrite, workspace_count);
        workspaces_initialized += 1;
        var workspace_index: usize = 0;
        workspace_storage.*[workspace_index] = .{ .destination = table_pointers, .binding_offsets = execution_tables.items };
        workspace_index += 1;
        workspace_storage.*[workspace_index] = .{ .destination = table_strides, .words = &strides };
        workspace_index += 1;
        if (pedersen_entry != null) {
            workspace_storage.*[workspace_index] = .{ .destination = pedersen_pointers, .binding_offsets = pedersen_sources };
            workspace_index += 1;
        }
        if (poseidon_entry != null) {
            workspace_storage.*[workspace_index] = .{ .destination = poseidon_pointers, .binding_offsets = poseidon_sources };
            workspace_index += 1;
        }
        workspace_storage.*[workspace_index] = .{ .destination = input_pointers, .binding_offsets = inputs };
        workspace_index += 1;
        workspace_storage.*[workspace_index] = .{ .destination = output_pointers, .binding_offsets = outputs };
        workspace_index += 1;
        workspace_storage.*[workspace_index] = .{ .destination = multiplicity_pointers };
        name.* = try witness_codegen.kernelNameForMode(allocator, entry.semantic_hash, kernel_mode.*);
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
                .pedersen_rows = if (pedersen_entry) |fixed_entry| fixed_entry.row_count else 1,
                .poseidon_keys = try wordOffset(poseidon_pointers) + 1,
            },
            .destinations = owned.*,
            .workspace_writes = workspace_storage.*,
        };
    }
    const source = try witness_codegen.generateBatchForModes(allocator, witness_bundle.entries, kernel_modes);
    defer allocator.free(source);
    return protocol_recipes.AotWitnessBatchRecipe.initSource(
        allocator,
        metal,
        resident_arena,
        source,
        invocations,
    );
}

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
    for (cairo_opcodes.direct_witness_lanes) |lane| {
        if (witness_bundle.find(lane.label) == null) continue;
        if (!try populateDirectWitnessInput(allocator, resident_arena, schedule, plan, witness_bundle, input, lane.label))
            return Error.MissingBinding;
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
    const lanes = [_][]const u8{ "bitwise_builtin", "range_check_builtin", "pedersen_builtin", "poseidon_builtin" };
    var populated: usize = 0;
    for (lanes) |lane| {
        if (witness_bundle.find(lane) == null) continue;
        if (!try populateDirectWitnessInput(allocator, resident_arena, schedule, plan, witness_bundle, input, lane))
            return Error.MissingBinding;
        populated += 1;
    }
    return populated;
}

/// Recreates one directly seeded recorded component in its aliased interaction
/// input slab. Returns false for gather/compact consumers, whose inputs must be
/// reconstructed from producer sub-words instead.
pub fn populateDirectWitnessInput(
    allocator: std.mem.Allocator,
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    witness_bundle: witness_bundle_mod.Bundle,
    input: *const cairo_adapter.ProverInput,
    component: []const u8,
) !bool {
    const entry = witness_bundle.find(component) orelse return Error.MissingBinding;
    for (cairo_opcodes.direct_witness_lanes) |lane| {
        if (!std.mem.eql(u8, lane.label, component)) continue;
        const states = input.state_transitions.casm_states_by_opcode.getConst(lane.tag);
        if (states.len == 0) return Error.MissingBinding;
        const bindings = try collectComponent(allocator, schedule, plan, "WitnessInput", component);
        defer allocator.free(bindings);
        const expected_columns: usize = if (lane.includes_iota) 5 else 4;
        if (entry.program.n_inputs != expected_columns or bindings.len != expected_columns)
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
        return true;
    }

    const segment = if (std.mem.eql(u8, component, "bitwise_builtin"))
        input.builtin_segments.bitwise_builtin
    else if (std.mem.eql(u8, component, "range_check_builtin"))
        input.builtin_segments.range_check_builtin
    else if (std.mem.eql(u8, component, "pedersen_builtin"))
        input.builtin_segments.pedersen_builtin
    else if (std.mem.eql(u8, component, "poseidon_builtin"))
        input.builtin_segments.poseidon_builtin
    else
        return false;
    const addresses = segment orelse return Error.MissingBinding;
    if (addresses.begin_addr > std.math.maxInt(u32)) return Error.InvalidCardinality;
    const bindings = try collectComponent(allocator, schedule, plan, "WitnessInput", component);
    defer allocator.free(bindings);
    if (entry.program.n_inputs != 3 or bindings.len != 3) return Error.InvalidCardinality;
    const row_count = bindings[0].size_bytes / 4;
    if (row_count < 16 or !std.math.isPowerOfTwo(row_count)) return Error.InvalidBindingSize;
    for (bindings, 0..) |binding, column| {
        const bytes = try resident_arena.bytes(binding);
        if (bytes.len != row_count * 4) return Error.InvalidBindingSize;
        const aligned: []align(4) u8 = @alignCast(bytes);
        const destination = std.mem.bytesAsSlice(u32, aligned);
        for (destination, 0..) |*value, row| value.* = switch (column) {
            0 => @intCast(addresses.begin_addr),
            1 => 1,
            2 => @intCast(row),
            else => unreachable,
        };
    }
    return true;
}

pub const WitnessEdge = cairo_proof_plan.ProducerEdge;

fn gatheredWitnessRealRows(
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    witness_bundle: witness_bundle_mod.Bundle,
    consumer: []const u8,
) !u32 {
    const edges = cairo_proof_plan.gatheredProducerEdges(consumer) orelse return Error.MissingBinding;
    var real_rows: u32 = 0;
    for (edges) |edge| {
        const producer = witness_bundle.find(edge.producer) orelse return Error.MissingBinding;
        const source = try oneComponent(schedule, plan, "SubcomponentInputs", edge.producer);
        if (producer.program.n_sub_words == 0 or source.size_bytes % (@as(u64, producer.program.n_sub_words) * 4) != 0)
            return Error.InvalidBindingSize;
        const producer_rows = std.math.cast(u32, source.size_bytes / 4 / producer.program.n_sub_words) orelse
            return Error.InvalidBindingSize;
        const contributed = std.math.mul(u32, producer_rows, edge.instances) catch return Error.InvalidBindingSize;
        real_rows = std.math.add(u32, real_rows, contributed) catch return Error.InvalidBindingSize;
    }
    return real_rows;
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
    const geometry = cairo_proof_plan.compactGeometry(consumer) orelse return Error.MissingBinding;
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
    const descriptor_bytes = std.math.mul(u64, descriptors.items.len, @sizeOf(u32)) catch
        return Error.InvalidCardinality;
    if (descriptor_bytes == 0 or descriptor_binding.size_bytes < descriptor_bytes)
        return Error.InvalidCardinality;
    var descriptor_destination = descriptor_binding;
    descriptor_destination.size_bytes = descriptor_bytes;
    const key_a = try oneComponentOrdinal(schedule, plan, "WitnessInputCompactSortKey", consumer, 0);
    const key_b = try oneComponentOrdinal(schedule, plan, "WitnessInputCompactSortKey", consumer, 1);
    const index_a = try oneComponentOrdinal(schedule, plan, "WitnessInputCompactSortIndex", consumer, 0);
    const index_b = try oneComponentOrdinal(schedule, plan, "WitnessInputCompactSortIndex", consumer, 1);
    const sort_rows = std.math.cast(u32, key_a.size_bytes / 4) orelse return Error.InvalidBindingSize;
    return protocol_recipes.CompactRecipe.init(allocator, metal, resident_arena, .{
        .sources = sources.items,
        .descriptors = descriptors.items,
        .descriptor_destination = descriptor_destination,
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
    writer_gpu_ms: f64 = 0,
    input_gpu_ms: f64 = 0,
    interpolation_gpu_ms: f64 = 0,
    feed_gpu_ms: f64 = 0,
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
        for (cairo_opcodes.direct_witness_lanes) |lane| direct = direct or std.mem.eql(u8, lane.label, entry.label);
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
            if (cairo_proof_plan.compactGeometry(entry.label)) |geometry| {
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
            } else if (cairo_proof_plan.gatheredProducerEdges(entry.label)) |edges| {
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

/// Executes the recorded Cairo witness DAG with the same ownership boundary
/// used by the staged arena: construct one input, refresh its aliased pointer
/// tables, write its trace, interpolate it, then consume its producer feed.
pub fn executeScheduledWitnessGraph(
    allocator: std.mem.Allocator,
    metal: *metal_runtime.Runtime,
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    arena: arena_plan.Plan,
    proof: *const cairo_proof_plan.CairoProofPlan,
    witness_bundle: witness_bundle_mod.Bundle,
    batch: *protocol_recipes.AotWitnessBatchRecipe,
    recipes: WitnessRecipes,
    interpolation: *RecordedBaseInterpolationBatch,
    feeds: *MultiplicityFeedBatch,
) !WitnessExecutionTelemetry {
    if (proof.components.len != witness_bundle.entries.len) return Error.InvalidCardinality;
    try recipes.validate(WitnessRecipeRequirements.fromBundle(witness_bundle));

    const Context = struct {
        allocator: std.mem.Allocator,
        metal: *metal_runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        schedule: []const std.json.Value,
        arena: arena_plan.Plan,
        proof: *const cairo_proof_plan.CairoProofPlan,
        witness_bundle: witness_bundle_mod.Bundle,
        batch: *protocol_recipes.AotWitnessBatchRecipe,
        recipes: WitnessRecipes,
        interpolation: *RecordedBaseInterpolationBatch,
        feeds: *MultiplicityFeedBatch,
        writer_gpu_ms: f64 = 0,
        input_gpu_ms: f64 = 0,
        interpolation_gpu_ms: f64 = 0,
        feed_gpu_ms: f64 = 0,

        fn run(raw: *anyopaque, component_index: u32, stage: witness_scheduler.Stage) !f64 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (component_index >= self.proof.components.len) return Error.InvalidCardinality;
            const component = self.proof.components[component_index].name;
            const gpu_ms = switch (stage) {
                .seed => 0,
                .gather => try gatherWitnessInput(
                    self.allocator,
                    self.metal,
                    self.resident_arena,
                    self.schedule,
                    self.arena,
                    self.witness_bundle,
                    component,
                ),
                .compact => try self.executeCompact(component),
                .writer => try self.executeWriter(component_index, component),
                .interpolate => try self.interpolation.executeIndex(component_index),
                .feed => try self.executeFeed(component),
            };
            if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_RC99_DIGESTS")) {
                try self.logRc99Digest(component, @tagName(stage));
            }
            if (stage == .writer and std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_BASE_EVAL_DIGESTS"))
                try logComponentBaseEvalDigests(
                    self.resident_arena,
                    self.schedule,
                    self.arena,
                    component,
                );
            if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_ADD_OPCODE_COEFF_DIGESTS") and
                ((std.mem.eql(u8, component, "add_opcode") and stage == .interpolate) or
                    std.mem.eql(u8, component, "add_opcode_small") or stage == .feed))
            {
                try self.logAddOpcodeCoefficientDigests(component, @tagName(stage));
            }
            switch (stage) {
                .seed, .gather, .compact => self.input_gpu_ms += gpu_ms,
                .writer => {},
                .interpolate => self.interpolation_gpu_ms += gpu_ms,
                .feed => self.feed_gpu_ms += gpu_ms,
            }
            return gpu_ms;
        }

        fn executeCompact(self: *@This(), component: []const u8) !f64 {
            const recipe = if (std.mem.eql(u8, component, "verify_instruction"))
                self.recipes.compact_verify
            else if (std.mem.eql(u8, component, "pedersen_aggregator_window_bits_18"))
                self.recipes.compact_pedersen
            else if (std.mem.eql(u8, component, "poseidon_aggregator"))
                self.recipes.compact_poseidon
            else
                null;
            const required = recipe orelse return Error.MissingBinding;
            const initial = required.accumulated_gpu_ms;
            try required.execute();
            return required.accumulated_gpu_ms - initial;
        }

        fn executeWriter(self: *@This(), component_index: u32, component: []const u8) !f64 {
            const index = witnessIndex(self.witness_bundle, component) orelse return Error.MissingBinding;
            var writer_gpu_ms: f64 = 0;
            var interpolation_gpu_ms: f64 = 0;
            if (std.mem.eql(u8, component, "partial_ec_mul_generic")) {
                const ec_op = self.recipes.ec_op orelse return Error.MissingBinding;
                const ec_initial = ec_op.accumulated_gpu_ms;
                try ec_op.execute();
                writer_gpu_ms += ec_op.accumulated_gpu_ms - ec_initial;
                if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_BASE_EVAL_DIGESTS"))
                    try logComponentBaseEvalDigests(
                        self.resident_arena,
                        self.schedule,
                        self.arena,
                        "ec_op_builtin",
                    );
                if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_RC99_DIGESTS"))
                    try self.logRc99Digest(component, "native_ec");
                interpolation_gpu_ms = try self.interpolation.interpolateEcOp(component_index);
                self.interpolation_gpu_ms += interpolation_gpu_ms;
                if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_RC99_DIGESTS"))
                    try self.logRc99Digest(component, "native_ec_interpolate");
            }
            const initial = self.batch.accumulated_gpu_ms;
            try self.batch.executeIndex(index);
            writer_gpu_ms += self.batch.accumulated_gpu_ms - initial;
            if (std.mem.eql(u8, component, "blake_g") and
                std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_BLAKE_G_EVAL_DIGESTS"))
            {
                const bindings = try collectComponent(
                    self.allocator,
                    self.schedule,
                    self.arena,
                    "BaseTrace",
                    component,
                );
                defer self.allocator.free(bindings);
                const coefficient_bindings = try collectComponent(
                    self.allocator,
                    self.schedule,
                    self.arena,
                    "BaseCoefficients",
                    component,
                );
                defer self.allocator.free(coefficient_bindings);
                if (coefficient_bindings.len != bindings.len) return Error.InvalidCardinality;
                for (bindings, 0..) |binding, column_ordinal| {
                    const bytes = try self.resident_arena.bytes(binding);
                    var digest: u64 = 0xcbf29ce484222325;
                    for (bytes) |byte| {
                        digest ^= byte;
                        digest *%= 0x100000001b3;
                    }
                    std.debug.print(
                        "blake_g_eval_digest ordinal={} source_offset={} destination_offset={} words={} first={x:0>8} last={x:0>8} fnv64={x:0>16}\n",
                        .{
                            column_ordinal,
                            binding.offset_bytes,
                            coefficient_bindings[column_ordinal].offset_bytes,
                            bytes.len / 4,
                            std.mem.readInt(u32, bytes[0..4], .little),
                            std.mem.readInt(u32, bytes[bytes.len - 4 ..][0..4], .little),
                            digest,
                        },
                    );
                }
            }
            if (std.mem.eql(u8, component, "add_opcode") and
                std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_ADD_OPCODE_EVAL_DIGESTS"))
            {
                const bindings = try collectComponent(
                    self.allocator,
                    self.schedule,
                    self.arena,
                    "BaseTrace",
                    component,
                );
                defer self.allocator.free(bindings);
                for ([_]usize{ 62, 65, 80 }) |column_ordinal| {
                    if (column_ordinal >= bindings.len) return Error.InvalidCardinality;
                    const bytes = try self.resident_arena.bytes(bindings[column_ordinal]);
                    var digest: u64 = 0xcbf29ce484222325;
                    for (bytes) |byte| {
                        digest ^= byte;
                        digest *%= 0x100000001b3;
                    }
                    std.debug.print(
                        "add_opcode_eval_digest ordinal={} words={} first={x:0>8} last={x:0>8} fnv64={x:0>16}\n",
                        .{
                            column_ordinal,
                            bytes.len / 4,
                            std.mem.readInt(u32, bytes[0..4], .little),
                            std.mem.readInt(u32, bytes[bytes.len - 4 ..][0..4], .little),
                            digest,
                        },
                    );
                }
            }
            self.writer_gpu_ms += writer_gpu_ms;
            return writer_gpu_ms + interpolation_gpu_ms;
        }

        fn logRc99Digest(self: *@This(), component: []const u8, stage: []const u8) !void {
            var digest: u64 = 0xcbf29ce484222325;
            for ([_]u32{ 89, 90 }) |fixed_ordinal| {
                const binding = try oneOrdinal(
                    self.schedule,
                    self.arena,
                    "PreprocessedEvaluations",
                    fixed_ordinal,
                );
                for (try self.resident_arena.bytes(binding)) |byte| {
                    digest ^= byte;
                    digest *%= 0x100000001b3;
                }
            }
            std.debug.print(
                "rc99_digest component={s} stage={s} fnv64={x:0>16}\n",
                .{ component, stage, digest },
            );
        }

        fn logAddOpcodeCoefficientDigests(self: *@This(), component: []const u8, stage: []const u8) !void {
            const bindings = try collectComponent(
                self.allocator,
                self.schedule,
                self.arena,
                "BaseCoefficients",
                "add_opcode",
            );
            defer self.allocator.free(bindings);
            for ([_]usize{ 62, 64, 65, 79, 80 }) |column_ordinal| {
                if (column_ordinal >= bindings.len) return Error.InvalidCardinality;
                const bytes = try self.resident_arena.bytes(bindings[column_ordinal]);
                var digest: u64 = 0xcbf29ce484222325;
                for (bytes) |byte| {
                    digest ^= byte;
                    digest *%= 0x100000001b3;
                }
                std.debug.print(
                    "add_opcode_coeff_digest component={s} stage={s} ordinal={} first={x:0>8} last={x:0>8} fnv64={x:0>16}\n",
                    .{
                        component,
                        stage,
                        column_ordinal,
                        std.mem.readInt(u32, bytes[0..4], .little),
                        std.mem.readInt(u32, bytes[bytes.len - 4 ..][0..4], .little),
                        digest,
                    },
                );
            }
        }

        fn executeFeed(self: *@This(), component: []const u8) !f64 {
            const initial = self.feeds.batch.accumulated_gpu_ms;
            try self.feeds.executeProducer(component);
            return self.feeds.batch.accumulated_gpu_ms - initial;
        }
    };

    var context = Context{
        .allocator = allocator,
        .metal = metal,
        .resident_arena = resident_arena,
        .schedule = schedule,
        .arena = arena,
        .proof = proof,
        .witness_bundle = witness_bundle,
        .batch = batch,
        .recipes = recipes,
        .interpolation = interpolation,
        .feeds = feeds,
    };
    const hook = witness_scheduler.Hook{ .context = &context, .run_fn = Context.run };
    const operations = try allocator.alloc(witness_scheduler.ComponentOperation, proof.components.len);
    defer allocator.free(operations);
    for (proof.components, operations, 0..) |component, *operation, index| {
        operation.* = .{
            .component_index = @intCast(index),
            .gather = if (component.producer_edges.len != 0 and cairo_proof_plan.compactGeometry(component.name) == null) hook else null,
            .compact = if (cairo_proof_plan.compactGeometry(component.name) != null) hook else null,
            .writer = hook,
            .interpolate = hook,
            .feed = hook,
        };
    }
    var scheduler = try witness_scheduler.CairoWitnessScheduler.init(allocator, proof, operations);
    defer scheduler.deinit();
    const initial_feed_gpu_ms = feeds.batch.accumulated_gpu_ms;
    try feeds.begin();
    const feed_clear_gpu_ms = feeds.batch.accumulated_gpu_ms - initial_feed_gpu_ms;
    context.feed_gpu_ms += feed_clear_gpu_ms;
    const result = try scheduler.execute(allocator);
    defer allocator.free(result.components);
    return .{
        .executed_programs = proof.components.len,
        .gpu_ms = result.gpu_ms + feed_clear_gpu_ms,
        .writer_gpu_ms = context.writer_gpu_ms,
        .input_gpu_ms = context.input_gpu_ms,
        .interpolation_gpu_ms = context.interpolation_gpu_ms,
        .feed_gpu_ms = context.feed_gpu_ms,
    };
}

pub const InteractionExecutionTelemetry = struct {
    executed_programs: usize,
    executed_relations: usize,
    gpu_ms: f64,
    writer_gpu_ms: f64,
    input_gpu_ms: f64,
    relation_gpu_ms: f64,
    interpolation_gpu_ms: f64,
};

fn logInteractionWriterCpuSample(
    allocator: std.mem.Allocator,
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    witness_bundle: witness_bundle_mod.Bundle,
    component: []const u8,
) !void {
    const entry = witness_bundle.find(component) orelse return Error.MissingBinding;
    const input_bindings = try collectComponent(allocator, schedule, plan, "WitnessInput", component);
    defer allocator.free(input_bindings);
    if (input_bindings.len != entry.program.n_inputs or input_bindings.len == 0)
        return Error.InvalidCardinality;

    const lookup_binding = try oneComponent(schedule, plan, "LookupInputs", component);
    const interaction_bindings = try collectComponent(allocator, schedule, plan, "InteractionTrace", component);
    defer allocator.free(interaction_bindings);
    const row_count = input_bindings[0].size_bytes / @sizeOf(u32);
    if (row_count == 0 or row_count > std.math.maxInt(u32) or
        lookup_binding.size_bytes != row_count * entry.program.n_lookup_words * @sizeOf(u32))
        return Error.InvalidBindingSize;
    for (input_bindings) |binding| if (binding.size_bytes != row_count * @sizeOf(u32))
        return Error.InvalidBindingSize;

    const arena_bytes: [*]align(4) const u8 = @ptrCast(@alignCast(resident_arena.buffer.contents));
    const arena_words = std.mem.bytesAsSlice(u32, arena_bytes[0..resident_arena.buffer.byte_length]);
    const table_pointer_binding = try one(schedule, plan, "ExecutionTablePointers");
    const table_stride_binding = try one(schedule, plan, "ExecutionTableStrides");
    const table_pointer_offset = try wordOffset(table_pointer_binding);
    const table_stride_offset = try wordOffset(table_stride_binding);
    if (table_pointer_binding.size_bytes < 37 * @sizeOf(u32) or
        table_stride_binding.size_bytes < 3 * @sizeOf(u32))
        return Error.InvalidBindingSize;
    const table_pointers = arena_words[table_pointer_offset..][0..37];
    const table_strides = arena_words[table_stride_offset..][0..3];

    const TableReader = struct {
        arena: []const u32,
        pointers: []const u32,
        strides: []const u32,

        pub fn tableLimb(self: @This(), table: u32, row: u32, limb: u32) u32 {
            if (table == 0) {
                if (row >= self.strides[0]) return 0;
                return self.arena[self.pointers[0] + row];
            }
            if (table != 1) return 0;
            const tag = row >> 30;
            const value = row & 0x3fff_ffff;
            if (tag == 1) {
                if (limb >= 28 or value >= self.strides[1]) return 0;
                return self.arena[self.pointers[1 + limb] + value];
            }
            if (limb >= 8 or value >= self.strides[2]) return 0;
            return self.arena[self.pointers[29 + limb] + value];
        }
    };
    const table_reader = TableReader{
        .arena = arena_words,
        .pointers = table_pointers,
        .strides = table_strides,
    };
    const lookup_offset = try wordOffset(lookup_binding);
    for (interaction_bindings, 0..) |binding, trace_ordinal| {
        const lookup_end = lookup_binding.offset_bytes + lookup_binding.size_bytes;
        const interaction_end = binding.offset_bytes + binding.size_bytes;
        if (lookup_binding.offset_bytes < interaction_end and binding.offset_bytes < lookup_end) {
            std.debug.print(
                "interaction_writer_alias component={s} lookup=[{}, {}) trace_ordinal={} trace=[{}, {})\n",
                .{ component, lookup_binding.offset_bytes / 4, lookup_end / 4, trace_ordinal, binding.offset_bytes / 4, interaction_end / 4 },
            );
        }
    }
    const input_offsets = try allocator.alloc(u32, input_bindings.len);
    defer allocator.free(input_offsets);
    for (input_bindings, input_offsets) |binding, *offset| offset.* = try wordOffset(binding);
    const row_count_usize: usize = @intCast(row_count);
    const sample_rows = [_]usize{ 0, @min(1, row_count_usize - 1), row_count_usize / 2, row_count_usize - 1 };
    const inputs = try allocator.alloc(u32, input_bindings.len);
    defer allocator.free(inputs);
    for (sample_rows) |row| {
        for (input_offsets, inputs) |offset, *value| value.* = arena_words[offset + row];
        var expected = try witness_program_mod.interpretCore(allocator, entry.program, inputs, table_reader);
        defer expected.deinit(allocator);
        var mismatch_count: usize = 0;
        var first_word: usize = 0;
        var first_expected: u32 = 0;
        var first_actual: u32 = 0;
        for (expected.lookup_words, 0..) |expected_word, word| {
            const actual_word = arena_words[lookup_offset + word * row_count_usize + row];
            if (actual_word == expected_word) continue;
            if (mismatch_count == 0) {
                first_word = word;
                first_expected = expected_word;
                first_actual = actual_word;
            }
            mismatch_count += 1;
        }
        std.debug.print(
            "interaction_writer_diff component={s} row={} mismatches={} first_word={} cpu={} metal={}\n",
            .{ component, row, mismatch_count, first_word, first_expected, first_actual },
        );
    }
    try logLookupRelationCpuClaim(
        allocator,
        resident_arena,
        schedule,
        plan,
        component,
        lookup_binding,
        @intCast(row_count),
        null,
    );
}

fn logLookupRelationCpuClaim(
    allocator: std.mem.Allocator,
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    component: []const u8,
    source: arena_plan.Binding,
    rows: u32,
    output_bindings: ?[]const arena_plan.Binding,
) !void {
    var bundle = try relation_bundle_mod.Bundle.readFile(allocator, "vectors/cairo/cairo_relation_templates.bin");
    defer bundle.deinit();
    const relation_component = bundle.find(component) orelse return Error.MissingBinding;
    if (relation_component.traces.len != 1 or relation_component.traces[0].layout != .lookup_words)
        return Error.InvalidCardinality;
    const trace = relation_component.traces[0];
    const column_count = trace.descriptors.len / 16;
    const numerators = try allocator.alloc(QM31, column_count);
    defer allocator.free(numerators);
    const denominators = try allocator.alloc(QM31, column_count);
    defer allocator.free(denominators);
    const prefixes = try allocator.alloc(QM31, column_count);
    defer allocator.free(prefixes);
    const last_column_values = if (output_bindings != null)
        try allocator.alloc(QM31, rows)
    else
        null;
    defer if (last_column_values) |values| allocator.free(values);
    if (output_bindings) |outputs| {
        if (outputs.len != column_count * 4) return Error.InvalidCardinality;
        for (outputs) |binding| if (binding.size_bytes != @as(u64, rows) * 4)
            return Error.InvalidBindingSize;
    }

    const arena_bytes: [*]align(4) const u8 = @ptrCast(@alignCast(resident_arena.buffer.contents));
    const arena_words = std.mem.bytesAsSlice(u32, arena_bytes[0..resident_arena.buffer.byte_length]);
    const source_offset = try wordOffset(source);
    const alpha_binding = try one(schedule, plan, "RelationAlphaPowers");
    const z_binding = try one(schedule, plan, "RelationZ");
    const alpha_offset = try wordOffset(alpha_binding);
    const z_offset = try wordOffset(z_binding);
    const alpha_count = alpha_binding.size_bytes / 16;
    const Field = struct {
        fn loadQm31(words: []const u32, offset: usize) QM31 {
            return QM31.fromU32Unchecked(words[offset], words[offset + 1], words[offset + 2], words[offset + 3]);
        }

        fn combine(
            words: []const u32,
            source_word_offset: u32,
            row_count: u32,
            row: u32,
            use: []const u32,
            alpha_word_offset: u32,
            alpha_power_count: u64,
            z: QM31,
        ) !QM31 {
            if (use[0] != 0 or use[2] > alpha_power_count) return Error.InvalidCardinality;
            var accumulator = z.neg();
            var word: u32 = 0;
            while (word < use[2]) : (word += 1) {
                const source_word = if (word == 0)
                    use[3]
                else
                    words[source_word_offset + (use[1] + word) * row_count + row];
                if (source_word >= @import("../../core/fields/m31.zig").Modulus)
                    return Error.InvalidCardinality;
                const alpha = loadQm31(words, alpha_word_offset + @as(usize, word) * 4);
                accumulator = accumulator.add(alpha.mulM31(M31.fromCanonical(source_word)));
            }
            return accumulator;
        }

        fn multiplicity(
            words: []const u32,
            source_word_offset: u32,
            row_count: u32,
            row: u32,
            use: []const u32,
        ) !M31 {
            const raw = switch (use[4]) {
                0 => 1,
                2 => words[source_word_offset + use[5] * row_count + row],
                else => return Error.InvalidCardinality,
            };
            if (raw >= @import("../../core/fields/m31.zig").Modulus)
                return Error.InvalidCardinality;
            const value = M31.fromCanonical(raw);
            return if (use[6] != 0) value.neg() else value;
        }
    };
    const z = Field.loadQm31(arena_words, z_offset);
    var total = QM31.zero();
    var raw_mismatch_count: usize = 0;
    var first_raw_mismatch: [4]usize = .{ 0, 0, 0, 0 };
    var first_raw_expected: u32 = 0;
    var first_raw_actual: u32 = 0;
    var timer = try std.time.Timer.start();
    for (0..rows) |row_usize| {
        const row: u32 = @intCast(row_usize);
        var product = QM31.one();
        var descriptor_index: usize = 0;
        while (descriptor_index < trace.descriptors.len) : (descriptor_index += 16) {
            const descriptor = trace.descriptors[descriptor_index..][0..16];
            const column = descriptor_index / 16;
            const a = descriptor[1..8];
            const da = try Field.combine(arena_words, source_offset, rows, row, a, alpha_offset, alpha_count, z);
            const ma = try Field.multiplicity(arena_words, source_offset, rows, row, a);
            if (descriptor[0] == 2) {
                const b = descriptor[8..15];
                const db = try Field.combine(arena_words, source_offset, rows, row, b, alpha_offset, alpha_count, z);
                const mb = try Field.multiplicity(arena_words, source_offset, rows, row, b);
                numerators[column] = da.mulM31(mb).add(db.mulM31(ma));
                denominators[column] = da.mul(db);
            } else {
                numerators[column] = QM31.fromBase(ma);
                denominators[column] = da;
            }
            prefixes[column] = product;
            product = product.mul(denominators[column]);
        }
        var running_inverse = try product.inv();
        var column = column_count;
        while (column != 0) {
            column -= 1;
            numerators[column] = numerators[column].mul(running_inverse.mul(prefixes[column]));
            running_inverse = running_inverse.mul(denominators[column]);
        }
        var row_total = QM31.zero();
        for (numerators, 0..) |fraction, relation_column| {
            row_total = row_total.add(fraction);
            if (output_bindings) |outputs| if (relation_column + 1 < column_count) {
                const coordinates = row_total.toM31Array();
                for (0..4) |coordinate| {
                    const output_offset = try wordOffset(outputs[relation_column * 4 + coordinate]);
                    const actual = arena_words[output_offset + row];
                    if (actual == coordinates[coordinate].v) continue;
                    if (raw_mismatch_count == 0) {
                        first_raw_mismatch = .{ row, relation_column, coordinate, 0 };
                        first_raw_expected = coordinates[coordinate].v;
                        first_raw_actual = actual;
                    }
                    raw_mismatch_count += 1;
                }
            };
        }
        if (last_column_values) |values| values[row] = row_total;
        total = total.add(row_total);
    }
    const coordinates = total.toM31Array();
    std.debug.print(
        "interaction_relation_cpu component={s} rows={} elapsed_ms={d:.3} value={},{},{},{}\n",
        .{ component, rows, @as(f64, @floatFromInt(timer.read())) / std.time.ns_per_ms, coordinates[0].v, coordinates[1].v, coordinates[2].v, coordinates[3].v },
    );
    if (output_bindings) |outputs| {
        const row_count_inverse = M31.fromCanonical(rows).inv() catch return Error.InvalidCardinality;
        const shift = total.mulM31(row_count_inverse);
        var prefix = QM31.zero();
        var scan_mismatch_count: usize = 0;
        var first_scan_mismatch: [4]usize = .{ 0, 0, 0, 0 };
        var first_scan_expected: u32 = 0;
        var first_scan_actual: u32 = 0;
        const log_rows = std.math.log2_int(u32, rows);
        for (0..rows) |scan_index| {
            const circle_index = if ((scan_index & 1) == 0)
                scan_index / 2
            else
                rows - 1 - scan_index / 2;
            const row = @bitReverse(@as(u32, @intCast(circle_index))) >>
                @intCast(@as(u32, 32) - @as(u32, log_rows));
            prefix = prefix.add(last_column_values.?[row]).sub(shift);
            const expected = prefix.toM31Array();
            for (0..4) |coordinate| {
                const output_offset = try wordOffset(outputs[(column_count - 1) * 4 + coordinate]);
                const actual = arena_words[output_offset + row];
                if (actual == expected[coordinate].v) continue;
                if (scan_mismatch_count == 0) {
                    first_scan_mismatch = .{ scan_index, row, coordinate, 0 };
                    first_scan_expected = expected[coordinate].v;
                    first_scan_actual = actual;
                }
                scan_mismatch_count += 1;
            }
        }
        std.debug.print(
            "interaction_relation_trace_diff component={s} raw_mismatches={} raw_first_row={} raw_first_column={} raw_first_coordinate={} raw_cpu={} raw_metal={} scan_mismatches={} scan_first_index={} scan_first_row={} scan_first_coordinate={} scan_cpu={} scan_metal={}\n",
            .{
                component,
                raw_mismatch_count,
                first_raw_mismatch[0],
                first_raw_mismatch[1],
                first_raw_mismatch[2],
                first_raw_expected,
                first_raw_actual,
                scan_mismatch_count,
                first_scan_mismatch[0],
                first_scan_mismatch[1],
                first_scan_mismatch[2],
                first_scan_expected,
                first_scan_actual,
            },
        );
    }
}

pub fn logComponentInteractionDigests(
    allocator: std.mem.Allocator,
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    component: []const u8,
) !void {
    _ = allocator;
    var local_index: usize = 0;
    for (schedule) |entry| {
        if (!std.mem.eql(u8, try purpose(entry), "InteractionTrace") or
            !std.mem.eql(u8, try componentName(entry), component)) continue;
        const output = plan.binding(try logicalId(entry)) catch return Error.MissingBinding;
        const bytes = try resident_arena.bytes(output);
        if (bytes.len < 4 or bytes.len % 4 != 0 or !std.math.isPowerOfTwo(bytes.len / 4))
            return Error.InvalidBindingSize;
        var digest: u64 = 0xcbf29ce484222325;
        for (bytes) |byte| {
            digest ^= byte;
            digest *%= 0x100000001b3;
        }
        const words: []align(1) const u32 = std.mem.bytesAsSlice(u32, bytes);
        std.debug.print(
            "interaction_eval_digest component={s} local_index={} logical_id={} log_size={} first={} last={} fnv64={x:0>16}\n",
            .{ component, local_index, output.logical_id, std.math.log2_int(usize, words.len), words[0], words[words.len - 1], digest },
        );
        local_index += 1;
    }
    if (local_index == 0) return Error.MissingBinding;
}

pub fn logComponentBaseEvalDigests(
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    component: []const u8,
) !void {
    var local_index: usize = 0;
    for (schedule) |entry| {
        if (!std.mem.eql(u8, try purpose(entry), "BaseTrace") or
            !std.mem.eql(u8, try componentName(entry), component)) continue;
        const output = plan.binding(try logicalId(entry)) catch return Error.MissingBinding;
        const bytes = try resident_arena.bytes(output);
        if (bytes.len < 4 or bytes.len % 4 != 0 or !std.math.isPowerOfTwo(bytes.len / 4))
            return Error.InvalidBindingSize;
        var digest: u64 = 0xcbf29ce484222325;
        for (bytes) |byte| {
            digest ^= byte;
            digest *%= 0x100000001b3;
        }
        const words: []align(1) const u32 = std.mem.bytesAsSlice(u32, bytes);
        std.debug.print(
            "base_eval_digest component={s} local_index={} logical_id={} ordinal={} log_size={} first={} last={} fnv64={x:0>16}\n",
            .{
                component,
                local_index,
                output.logical_id,
                try ordinal(entry),
                std.math.log2_int(usize, words.len),
                words[0],
                words[words.len - 1],
                digest,
            },
        );
        if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_DUMP_BASE_EVAL_LOGICAL_ID")) {
            const wanted_text = try std.process.getEnvVarOwned(
                std.heap.page_allocator,
                "STWO_ZIG_SN2_DUMP_BASE_EVAL_LOGICAL_ID",
            );
            defer std.heap.page_allocator.free(wanted_text);
            const wanted = std.fmt.parseInt(u32, wanted_text, 10) catch return Error.InvalidSchedule;
            if (wanted == output.logical_id) {
                const path = try std.process.getEnvVarOwned(
                    std.heap.page_allocator,
                    "STWO_ZIG_SN2_DUMP_BASE_EVAL_PATH",
                );
                defer std.heap.page_allocator.free(path);
                const file = try std.fs.createFileAbsolute(path, .{});
                defer file.close();
                try file.writeAll(bytes);
                std.debug.print(
                    "base_eval_dump logical_id={} path={s} words={}\n",
                    .{ output.logical_id, path, words.len },
                );
            }
        }
        local_index += 1;
    }
    if (local_index == 0) return Error.MissingBinding;
}

pub fn logInteractionCoefficientDigests(
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    stage: []const u8,
) !void {
    var count: usize = 0;
    for (schedule) |entry| {
        if (!std.mem.eql(u8, try purpose(entry), "InteractionCoefficients")) continue;
        const binding = plan.binding(try logicalId(entry)) catch return Error.MissingBinding;
        const bytes = try resident_arena.bytes(binding);
        if (bytes.len < 4 or bytes.len % 4 != 0 or !std.math.isPowerOfTwo(bytes.len / 4))
            return Error.InvalidBindingSize;
        const words: []align(1) const u32 = std.mem.bytesAsSlice(u32, bytes);
        var raw_digest: u64 = 0xcbf29ce484222325;
        var canonical_digest: u64 = 0xcbf29ce484222325;
        for (words) |word| {
            for (0..4) |byte_index| {
                raw_digest ^= @as(u8, @truncate(word >> @intCast(byte_index * 8)));
                raw_digest *%= 0x100000001b3;
            }
            const canonical = word % 0x7fffffff;
            for (0..4) |byte_index| {
                canonical_digest ^= @as(u8, @truncate(canonical >> @intCast(byte_index * 8)));
                canonical_digest *%= 0x100000001b3;
            }
        }
        std.debug.print(
            "interaction_coeff_digest stage={s} component={s} ordinal={} logical_id={} log_size={} first={} last={} canonical_first={} canonical_last={} raw_fnv64={x:0>16} fnv64={x:0>16}\n",
            .{
                stage,
                try componentName(entry),
                try ordinal(entry),
                binding.logical_id,
                std.math.log2_int(usize, words.len),
                words[0],
                words[words.len - 1],
                words[0] % 0x7fffffff,
                words[words.len - 1] % 0x7fffffff,
                raw_digest,
                canonical_digest,
            },
        );
        count += 1;
    }
    if (count == 0) return Error.MissingBinding;
}

pub fn logLogicalBindingDigest(
    resident_arena: *arena_plan.ResidentArena,
    plan: arena_plan.Plan,
    logical_id: u32,
    stage: []const u8,
) !void {
    const binding = plan.binding(logical_id) catch return Error.MissingBinding;
    const bytes = try resident_arena.bytes(binding);
    if (bytes.len < 4 or bytes.len % 4 != 0) return Error.InvalidBindingSize;
    var digest: u64 = 0xcbf29ce484222325;
    for (bytes) |byte| {
        digest ^= byte;
        digest *%= 0x100000001b3;
    }
    const words: []align(1) const u32 = std.mem.bytesAsSlice(u32, bytes);
    std.debug.print(
        "logical_binding_digest stage={s} logical_id={} words={} first={x:0>8} last={x:0>8} fnv64={x:0>16}\n",
        .{ stage, logical_id, words.len, words[0], words[words.len - 1], digest },
    );
}

fn logCpuColumnLdeDigest(
    allocator: std.mem.Allocator,
    resident_arena: *arena_plan.ResidentArena,
    plan: arena_plan.Plan,
    logical_id: u32,
    log_size: u32,
) !void {
    const binding = plan.binding(logical_id) catch return Error.MissingBinding;
    const bytes = try resident_arena.bytes(binding);
    if (bytes.len != (@as(usize, 1) << @intCast(log_size)) * 4) return Error.InvalidBindingSize;
    const words: []align(1) const u32 = std.mem.bytesAsSlice(u32, bytes);
    const values = try allocator.alloc(M31, words.len);
    defer allocator.free(values);
    for (words, values) |word, *value| value.* = M31.fromCanonical(word % 0x7fffffff);

    const domain = canonic_circle_mod.CanonicCoset.new(log_size).circleDomain();
    const evaluation = try circle_eval_mod.CircleEvaluation.init(domain, values);
    var coefficients = try circle_poly_mod.interpolateFromEvaluation(allocator, evaluation);
    defer coefficients.deinit(allocator);
    {
        const file = try std.fs.createFileAbsolute("/tmp/sn2-column613-cpu-coeff.u32le", .{});
        defer file.close();
        try file.writeAll(std.mem.sliceAsBytes(coefficients.coefficients()));
    }
    const lde_domain = canonic_circle_mod.CanonicCoset.new(log_size + 1).circleDomain();
    const lde = try coefficients.evaluate(allocator, lde_domain);
    defer allocator.free(@constCast(lde.values));
    {
        const file = try std.fs.createFileAbsolute("/tmp/sn2-column613-cpu-lde.u32le", .{});
        defer file.close();
        try file.writeAll(std.mem.sliceAsBytes(lde.values));
    }
    var digest: u64 = 0xcbf29ce484222325;
    for (lde.values) |value| {
        for (0..4) |byte_index| {
            digest ^= @as(u8, @truncate(value.v >> @intCast(byte_index * 8)));
            digest *%= 0x100000001b3;
        }
    }
    std.debug.print(
        "cpu_column_lde_digest source_id={} log_size={} lde_log_size={} first={x:0>8} last={x:0>8} fnv64={x:0>16}\n",
        .{ logical_id, log_size, log_size + 1, lde.values[0].v, lde.values[lde.values.len - 1].v, digest },
    );
}

/// Replays the recorded witness DAG into lookup/subcomponent slabs and consumes
/// each lookup in its relation before advancing to the next aliased component.
/// Multiplicity feeds are deliberately absent: their base-epoch counts remain
/// resident and are only read by the relation kernels.
pub fn executeScheduledInteractionGraph(
    allocator: std.mem.Allocator,
    metal: *metal_runtime.Runtime,
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    arena: arena_plan.Plan,
    proof: *const cairo_proof_plan.CairoProofPlan,
    witness_bundle: witness_bundle_mod.Bundle,
    input: *const cairo_adapter.ProverInput,
    batch: *protocol_recipes.AotWitnessBatchRecipe,
    recipes: WitnessRecipes,
    relations: *PreparedRelationComponents,
) !InteractionExecutionTelemetry {
    if (proof.components.len != witness_bundle.entries.len) return Error.InvalidCardinality;
    const requirements = WitnessRecipeRequirements.fromBundle(witness_bundle);
    try recipes.validate(requirements);
    for (proof.components) |component| {
        if (try relations.componentIndex(component.name) == null) return Error.MissingBinding;
    }
    if (requirements.ec_op and try relations.componentIndex("ec_op_builtin") == null)
        return Error.MissingBinding;
    const execution_table_gpu_ms = try populateExecutionTables(
        allocator,
        metal,
        resident_arena,
        schedule,
        arena,
        input,
    );

    const Context = struct {
        allocator: std.mem.Allocator,
        metal: *metal_runtime.Runtime,
        resident_arena: *arena_plan.ResidentArena,
        schedule: []const std.json.Value,
        arena: arena_plan.Plan,
        proof: *const cairo_proof_plan.CairoProofPlan,
        witness_bundle: witness_bundle_mod.Bundle,
        input: *const cairo_adapter.ProverInput,
        batch: *protocol_recipes.AotWitnessBatchRecipe,
        recipes: WitnessRecipes,
        relations: *PreparedRelationComponents,
        ec_completed: bool = false,
        executed_writers: usize = 0,
        executed_relations: usize = 0,
        writer_gpu_ms: f64 = 0,
        input_gpu_ms: f64 = 0,
        relation_gpu_ms: f64 = 0,
        interpolation_gpu_ms: f64 = 0,

        fn run(raw: *anyopaque, component_index: u32, stage: witness_scheduler.Stage) !f64 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (component_index >= self.proof.components.len) return Error.InvalidCardinality;
            const component = self.proof.components[component_index].name;
            const gpu_ms = switch (stage) {
                .seed => blk: {
                    if (!try populateDirectWitnessInput(
                        self.allocator,
                        self.resident_arena,
                        self.schedule,
                        self.arena,
                        self.witness_bundle,
                        self.input,
                        component,
                    )) return Error.MissingBinding;
                    break :blk 0;
                },
                .gather => try gatherWitnessInput(
                    self.allocator,
                    self.metal,
                    self.resident_arena,
                    self.schedule,
                    self.arena,
                    self.witness_bundle,
                    component,
                ),
                .compact => try self.executeCompact(component),
                .writer => try self.executeWriter(component),
                .interpolate => try self.executeRelation(component),
                .feed => return Error.InvalidSchedule,
            };
            switch (stage) {
                .seed, .gather, .compact => self.input_gpu_ms += gpu_ms,
                .writer => {},
                .interpolate => {},
                .feed => unreachable,
            }
            return gpu_ms;
        }

        fn executeCompact(self: *@This(), component: []const u8) !f64 {
            const recipe = if (std.mem.eql(u8, component, "verify_instruction"))
                self.recipes.compact_verify
            else if (std.mem.eql(u8, component, "pedersen_aggregator_window_bits_18"))
                self.recipes.compact_pedersen
            else if (std.mem.eql(u8, component, "poseidon_aggregator"))
                self.recipes.compact_poseidon
            else
                null;
            const required = recipe orelse return Error.MissingBinding;
            const initial = required.accumulated_gpu_ms;
            try required.execute();
            return required.accumulated_gpu_ms - initial;
        }

        fn executeWriter(self: *@This(), component: []const u8) !f64 {
            var gpu_ms: f64 = 0;
            if (std.mem.eql(u8, component, "partial_ec_mul_generic")) {
                if (self.ec_completed) return Error.InvalidSchedule;
                const ec_lookup = self.recipes.ec_op orelse return Error.MissingBinding;
                const initial = ec_lookup.accumulated_gpu_ms;
                try ec_lookup.execute();
                const ec_gpu_ms = ec_lookup.accumulated_gpu_ms - initial;
                self.writer_gpu_ms += ec_gpu_ms;
                gpu_ms += ec_gpu_ms;
                const relation_gpu_ms = try self.executeRelation("ec_op_builtin");
                gpu_ms += relation_gpu_ms;
                self.ec_completed = true;
            }
            const index = witnessIndex(self.witness_bundle, component) orelse return Error.MissingBinding;
            const initial = self.batch.accumulated_gpu_ms;
            try self.batch.executeIndex(index);
            const writer_gpu_ms = self.batch.accumulated_gpu_ms - initial;
            if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_DIFF_ADD_OPCODE_INTERACTION") and
                std.mem.eql(u8, component, "add_opcode"))
                try logInteractionWriterCpuSample(
                    self.allocator,
                    self.resident_arena,
                    self.schedule,
                    self.arena,
                    self.witness_bundle,
                    component,
                );
            self.writer_gpu_ms += writer_gpu_ms;
            self.executed_writers += 1;
            return gpu_ms + writer_gpu_ms;
        }

        fn executeRelation(self: *@This(), component: []const u8) !f64 {
            const index = try self.relations.componentIndex(component) orelse return Error.MissingBinding;
            const diff_add_opcode = std.process.hasEnvVarConstant("STWO_ZIG_SN2_DIFF_ADD_OPCODE_INTERACTION") and
                std.mem.eql(u8, component, "add_opcode");
            const log_interaction_evals = std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_INTERACTION_EVAL_DIGESTS");
            const trace_column_613 = std.process.hasEnvVarConstant("STWO_ZIG_SN2_TRACE_COLUMN_613");
            if (diff_add_opcode or log_interaction_evals or trace_column_613) {
                const operation = &self.relations.operations[index];
                const relation_before = operation.relation.accumulated_gpu_ms;
                try operation.relation.execute();
                const relation_gpu_ms = operation.relation.accumulated_gpu_ms - relation_before;
                if (log_interaction_evals) try logComponentInteractionDigests(
                    self.allocator,
                    self.resident_arena,
                    self.schedule,
                    self.arena,
                    component,
                );
                if (diff_add_opcode) {
                    const source = try oneComponent(self.schedule, self.arena, "LookupInputs", component);
                    const outputs = try collectComponent(
                        self.allocator,
                        self.schedule,
                        self.arena,
                        "InteractionTrace",
                        component,
                    );
                    defer self.allocator.free(outputs);
                    try logLookupRelationCpuClaim(
                        self.allocator,
                        self.resident_arena,
                        self.schedule,
                        self.arena,
                        component,
                        source,
                        @intCast(source.size_bytes / 4 / self.witness_bundle.find(component).?.program.n_lookup_words),
                        outputs,
                    );
                }
                if (trace_column_613 and std.mem.eql(u8, component, "blake_g"))
                    try logCpuColumnLdeDigest(
                        self.allocator,
                        self.resident_arena,
                        self.arena,
                        1701,
                        23,
                    );
                var interpolation_gpu_ms: f64 = 0;
                for (operation.interpolations) |*interpolation| {
                    const before = interpolation.accumulated_gpu_ms;
                    try interpolation.execute();
                    interpolation_gpu_ms += interpolation.accumulated_gpu_ms - before;
                }
                if (trace_column_613 and std.mem.eql(u8, component, "blake_g")) {
                    try logLogicalBindingDigest(
                        self.resident_arena,
                        self.arena,
                        1737,
                        "after_blake_g_batch_ifft",
                    );
                    {
                        const file = try std.fs.createFileAbsolute("/tmp/sn2-column613-metal-coeff.u32le", .{});
                        defer file.close();
                        try file.writeAll(try self.resident_arena.bytes(self.arena.binding(1737) catch return Error.MissingBinding));
                    }
                    if (operation.interpolations.len != 1) return Error.InvalidCardinality;
                    interpolation_gpu_ms += try operation.interpolations[0].executeColumn(13);
                    try logLogicalBindingDigest(
                        self.resident_arena,
                        self.arena,
                        1737,
                        "after_blake_g_single_ifft",
                    );
                }
                self.relation_gpu_ms += relation_gpu_ms;
                self.interpolation_gpu_ms += interpolation_gpu_ms;
                self.executed_relations += 1;
                return relation_gpu_ms + interpolation_gpu_ms;
            }
            const telemetry = try self.relations.executeIndex(index);
            self.relation_gpu_ms += telemetry.relation_gpu_ms;
            self.interpolation_gpu_ms += telemetry.interpolation_gpu_ms;
            self.executed_relations += 1;
            return telemetry.relation_gpu_ms + telemetry.interpolation_gpu_ms;
        }
    };

    var context = Context{
        .allocator = allocator,
        .metal = metal,
        .resident_arena = resident_arena,
        .schedule = schedule,
        .arena = arena,
        .proof = proof,
        .witness_bundle = witness_bundle,
        .input = input,
        .batch = batch,
        .recipes = recipes,
        .relations = relations,
        .input_gpu_ms = execution_table_gpu_ms,
    };
    const hook = witness_scheduler.Hook{ .context = &context, .run_fn = Context.run };
    const operations = try allocator.alloc(witness_scheduler.ComponentOperation, proof.components.len);
    defer allocator.free(operations);
    for (proof.components, operations, 0..) |component, *operation, index|
        operation.* = interactionOperation(component, @intCast(index), hook);
    var scheduler = try witness_scheduler.CairoWitnessScheduler.init(allocator, proof, operations);
    defer scheduler.deinit();
    const result = try scheduler.execute(allocator);
    defer allocator.free(result.components);
    var expected_writers: usize = 0;
    for (proof.components) |component|
        expected_writers += @intFromBool(!cairo_proof_plan.retainsLookupInputs(component.name) or
            cairo_proof_plan.retainedLookupReplaysSubwords(component.name));
    if (context.ec_completed != requirements.ec_op or
        context.executed_writers != expected_writers or
        context.executed_relations != proof.components.len + @intFromBool(requirements.ec_op))
        return Error.InvalidCardinality;
    return .{
        .executed_programs = context.executed_writers,
        .executed_relations = context.executed_relations,
        .gpu_ms = result.gpu_ms + execution_table_gpu_ms,
        .writer_gpu_ms = context.writer_gpu_ms,
        .input_gpu_ms = context.input_gpu_ms,
        .relation_gpu_ms = context.relation_gpu_ms,
        .interpolation_gpu_ms = context.interpolation_gpu_ms,
    };
}

fn interactionOperation(
    component: cairo_proof_plan.Component,
    component_index: u32,
    hook: witness_scheduler.Hook,
) witness_scheduler.ComponentOperation {
    const compact = cairo_proof_plan.compactGeometry(component.name) != null;
    const retained_ec_input = std.mem.eql(u8, component.name, "partial_ec_mul_generic");
    const retained_lookup = cairo_proof_plan.retainsLookupInputs(component.name);
    const skip_writer = retained_lookup and !cairo_proof_plan.retainedLookupReplaysSubwords(component.name);
    return .{
        .component_index = component_index,
        .seed = if (!skip_writer and !retained_ec_input and !compact and component.producer_edges.len == 0) hook else null,
        .gather = if (!skip_writer and component.producer_edges.len != 0 and !compact) hook else null,
        .compact = if (!skip_writer and compact) hook else null,
        .writer = if (skip_writer) null else hook,
        .interpolate = hook,
    };
}

test "retained interaction lookup runs its relation without rebuilding inputs" {
    const rows = [_]cairo_proof_plan.TracePart{.{ .id = .main, .rows = .{ .real_rows = 16, .padded_rows = 16 } }};
    const edge = [_]cairo_proof_plan.ProducerEdge{.{
        .producer = "producer",
        .word_base = 0,
        .words_per_instance = 1,
        .instances = 1,
    }};
    const Context = struct {
        fn run(_: *anyopaque, _: u32, _: witness_scheduler.Stage) !f64 {
            return 0;
        }
    };
    var context: u8 = 0;
    const hook = witness_scheduler.Hook{ .context = &context, .run_fn = Context.run };
    const retained = interactionOperation(.{
        .name = "cube_252",
        .canonical_ordinal = 0,
        .writer = .recorded_aot,
        .trace_parts = &rows,
        .producer_edges = &edge,
        .capacity_feeds = &.{},
    }, 0, hook);
    try std.testing.expect(retained.seed == null);
    try std.testing.expect(retained.gather == null);
    try std.testing.expect(retained.compact == null);
    try std.testing.expect(retained.writer == null);

    const retained_producer = interactionOperation(.{
        .name = "poseidon_3_partial_rounds_chain",
        .canonical_ordinal = 1,
        .writer = .recorded_aot,
        .trace_parts = &rows,
        .producer_edges = &edge,
        .capacity_feeds = &.{},
    }, 1, hook);
    try std.testing.expect(retained_producer.gather != null);
    try std.testing.expect(retained_producer.writer != null);

    const gathered = interactionOperation(.{
        .name = "blake_g",
        .canonical_ordinal = 2,
        .writer = .recorded_aot,
        .trace_parts = &rows,
        .producer_edges = &edge,
        .capacity_feeds = &.{},
    }, 2, hook);
    try std.testing.expect(gathered.gather != null);
    try std.testing.expect(gathered.writer != null);

    const seeded = interactionOperation(.{
        .name = "add_opcode",
        .canonical_ordinal = 3,
        .writer = .recorded_aot,
        .trace_parts = &rows,
        .producer_edges = &.{},
        .capacity_feeds = &.{},
    }, 3, hook);
    try std.testing.expect(seeded.seed != null);
    try std.testing.expect(seeded.writer != null);
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
    const edges = cairo_proof_plan.gatheredProducerEdges(consumer) orelse return Error.MissingBinding;
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
    if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_STAGE_TIMINGS")) std.debug.print(
        "composition_bindings lde_tile_offset={d} lde_tile_size={d} accumulators_offset={d} accumulators_size={d} random_powers_offset={d} random_powers_size={d} descriptors_offset={d} descriptors_size={d} coefficients_first_offset={d} coefficients_count={d}\n",
        .{
            bindings.composition_lde_tile.offset_bytes,
            bindings.composition_lde_tile.size_bytes,
            bindings.composition_accumulators.offset_bytes,
            bindings.composition_accumulators.size_bytes,
            bindings.composition_random_powers.offset_bytes,
            bindings.composition_random_powers.size_bytes,
            bindings.composition_descriptors.offset_bytes,
            bindings.composition_descriptors.size_bytes,
            bindings.composition_coefficients[0].offset_bytes,
            bindings.composition_coefficients.len,
        },
    );
    if (bundle.components.len != bindings.composition_ext_params.len or
        bundle.components.len != bindings.canonical_claimed_sums.len or bundle.total_constraints * 4 != bindings.composition_random_powers.size_bytes / 4)
        return Error.InvalidCardinality;
    const asOffset = struct {
        fn get(binding: arena_plan.Binding) !u32 {
            if (binding.offset_bytes % 4 != 0) return Error.InvalidBindingSize;
            return std.math.cast(u32, binding.offset_bytes / 4) orelse Error.InvalidBindingSize;
        }
    }.get;
    const asWideOffset = struct {
        fn get(binding: arena_plan.Binding) !u64 {
            if (binding.offset_bytes % 4 != 0) return Error.InvalidBindingSize;
            return binding.offset_bytes / 4;
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

    const fusion_requested = std.process.hasEnvVarConstant("STWO_ZIG_SN2_ENABLE_COMPOSITION_PART_FUSION");
    const source_artifact_present = std.process.hasEnvVarConstant("STWO_ZIG_SN2_COMPOSITION_SOURCE");
    if (fusion_requested and !source_artifact_present)
        return error.FusedCompositionRequiresSourceArtifact;
    const fusion_instruction_cap = if (std.process.getEnvVarOwned(
        allocator,
        "STWO_ZIG_SN2_COMPOSITION_FUSION_CAP",
    )) |encoded_cap| cap: {
        defer allocator.free(encoded_cap);
        if (!fusion_requested) return error.FusionCapRequiresFusedComposition;
        const value = try std.fmt.parseUnsigned(usize, encoded_cap, 10);
        if (value == 0 or value > eval_codegen.max_fused_instruction_cap)
            return error.InvalidFusionInstructionCap;
        break :cap value;
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => eval_codegen.default_fused_instruction_cap,
        else => return err,
    };
    var library = if (std.process.getEnvVarOwned(
        allocator,
        "STWO_ZIG_SN2_COMPOSITION_SOURCE",
    )) |source_path| source: {
        defer allocator.free(source_path);
        const source_bytes = try std.fs.cwd().readFileAlloc(allocator, source_path, 64 * 1024 * 1024);
        defer allocator.free(source_bytes);
        break :source try metal.compileEvalLibrary(source_bytes);
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => try metal.loadEvalLibrary(metallib_path),
        else => return err,
    };
    defer library.deinit();
    const component_limit = if (std.process.getEnvVarOwned(
        allocator,
        "STWO_ZIG_SN2_COMPOSITION_COMPONENT_LIMIT",
    )) |encoded_limit| limit: {
        defer allocator.free(encoded_limit);
        break :limit try compositionComponentLimit(bundle.components.len, encoded_limit);
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => try compositionComponentLimit(bundle.components.len, null),
        else => return err,
    };
    const diagnostic_component: ?usize = if (std.process.getEnvVarOwned(
        allocator,
        "STWO_ZIG_SN2_LOG_COMPOSITION_PART_COMPONENT",
    )) |encoded_component| component: {
        defer allocator.free(encoded_component);
        break :component try std.fmt.parseUnsigned(usize, encoded_component, 10);
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    const fusion_enabled = fusion_requested and diagnostic_component == null;
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

    const lde_plans = try allocator.alloc(metal_runtime.CompositionLdePlan, component_limit);
    defer allocator.free(lde_plans);
    var initialized_ldes: usize = 0;
    defer for (lde_plans[0..initialized_ldes]) |*plan| plan.deinit();
    const eval_batches = try allocator.alloc(metal_runtime.EvalBatchPlan, component_limit);
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

    var composition_original_parts: usize = 0;
    var composition_dispatch_slices: usize = 0;
    for (bundle.components[0..component_limit], 0..) |component, component_index| {
        if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_STAGE_TIMINGS"))
            std.debug.print("composition_prepare component={s} instance={d} index={d} eval_log={d}\n", .{
                component.label, component.instance, component_index, component.evaluation_log_size,
            });
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
        const source_offsets = try allocator.alloc(u64, sources.items.len);
        defer allocator.free(source_offsets);
        const source_logs = try allocator.alloc(u32, sources.items.len);
        defer allocator.free(source_logs);
        const destination_offsets = try allocator.alloc(u32, sources.items.len);
        defer allocator.free(destination_offsets);
        for (sources.items, source_offsets, source_logs, destination_offsets, 0..) |source, *source_offset, *source_log, *destination, index| {
            source_offset.* = try asWideOffset(source);
            source_log.* = try bindingLog(source);
            if (source_log.* > component.evaluation_log_size) {
                std.debug.print(
                    "composition source exceeds domain: {s}[{}] local={} source={} log={} evaluation_log={} spans={any}\n",
                    .{ component.label, component.instance, index, source.logical_id, source_log.*, component.evaluation_log_size, component.trace_spans },
                );
                return Error.InvalidBindingSize;
            }
            destination.* = std.math.add(u32, tile_base, @intCast(index * @as(usize, row_count))) catch return Error.InvalidBindingSize;
            if (diagnostic_component == component_index) std.debug.print(
                "composition_source_binding component_index={} local_index={} logical_id={} source_offset={} source_log={} destination_offset={} evaluation_log={}\n",
                .{ component_index, index, source.logical_id, source_offset.*, source_log.*, destination.*, component.evaluation_log_size },
            );
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
                    break :blk .{ .destination = destination, .kind = 1, .source = try asOffset(bindings.canonical_claimed_sums[component_index]), .scale = scale.v, .constant = .{ 0, 0, 0, 0 } };
                },
            };
            try ext_descriptors.append(allocator, descriptor);
        }

        composition_original_parts += component.parts.len;
        const plans = try allocator.alloc(metal_runtime.EvalPlan, component.parts.len);
        defer allocator.free(plans);
        var plans_initialized: usize = 0;
        defer for (plans[0..plans_initialized]) |*plan| plan.deinit();
        const accumulator_relative_offset = accumulator_relative[component.evaluation_log_size] orelse return Error.InvalidBindingSize;
        const fused_parts = try allocator.alloc(eval_codegen.FusedPart, component.parts.len);
        defer allocator.free(fused_parts);
        for (component.parts, fused_parts) |part, *fused| fused.* = .{
            .program = part.program,
            .rc_base = part.rc_base,
        };
        var part_start: usize = 0;
        while (part_start < component.parts.len) {
            const part_end = if (fusion_enabled)
                try eval_codegen.fusionGroupEnd(
                    fused_parts,
                    part_start,
                    fusion_instruction_cap,
                )
            else
                part_start + 1;
            const part = component.parts[part_start];
            const name = if (part_end - part_start > 1)
                try eval_codegen.fusedKernelName(allocator, fused_parts[part_start..part_end])
            else
                try eval_codegen.kernelName(allocator, part.semantic_hash);
            defer allocator.free(name);
            var slice_operations: usize = 0;
            for (fused_parts[part_start..part_end]) |fused|
                slice_operations += eval_codegen.fusionOperationCount(fused.program);
            var pipeline_timer = try std.time.Timer.start();
            if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_STAGE_TIMINGS")) std.debug.print(
                "composition_prepare_slice component_index={} slice_index={} first_part={} part_count={} operations={} kernel={s} begin\n",
                .{
                    component_index,
                    plans_initialized,
                    part_start,
                    part_end - part_start,
                    slice_operations,
                    name,
                },
            );
            plans[plans_initialized] = try metal.prepareEvalFromLibrary(library, name, .{
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
                .rc_base = try compositionRandomCoefficientBase(
                    component.random_coefficient_offset,
                    part.rc_base,
                ),
            });
            if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_STAGE_TIMINGS")) std.debug.print(
                "composition_prepare_slice component_index={} slice_index={} wall_ms={d:.3} done\n",
                .{
                    component_index,
                    plans_initialized,
                    @as(f64, @floatFromInt(pipeline_timer.read())) / std.time.ns_per_ms,
                },
            );
            plans_initialized += 1;
            part_start = part_end;
        }
        composition_dispatch_slices += plans_initialized;
        eval_batches[component_index] = try metal.prepareEvalBatch(plans[0..plans_initialized]);
        initialized_batches += 1;
    }

    if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_STAGE_TIMINGS")) std.debug.print(
        "composition_fusion enabled={} instruction_cap={} original_parts={} dispatch_slices={}\n",
        .{
            fusion_enabled,
            if (fusion_enabled) fusion_instruction_cap else @as(usize, 0),
            composition_original_parts,
            composition_dispatch_slices,
        },
    );

    // Persist the pipeline states added while resolving either an AOT metallib
    // or a source-compiled library. Without this, every prover process rebuilds
    // every AIR pipeline before composition.
    try library.serialize();

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

fn compositionRandomCoefficientBase(component_offset: u32, part_offset: u32) !u32 {
    return std.math.add(u32, component_offset, part_offset) catch Error.InvalidBindingSize;
}

fn compositionComponentLimit(total: usize, encoded: ?[]const u8) !usize {
    if (total == 0) return Error.InvalidCardinality;
    const text = encoded orelse return total;
    const value = std.fmt.parseInt(usize, text, 10) catch return Error.InvalidCardinality;
    if (value == 0 or value > total) return Error.InvalidCardinality;
    return value;
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

fn writeWideWordOffset(words: []u32, index: usize, offset_words: u64) !void {
    const base = std.math.mul(usize, index, 2) catch return Error.InvalidBindingSize;
    if (base + 2 > words.len) return Error.InvalidBindingSize;
    words[base] = @truncate(offset_words);
    words[base + 1] = @truncate(offset_words >> 32);
}

fn writeWideBindingOffsets(
    resident_arena: *arena_plan.ResidentArena,
    destination: arena_plan.Binding,
    sources: []const arena_plan.Binding,
) !void {
    const bytes = try resident_arena.bytes(destination);
    if (bytes.len % 4 != 0 or bytes.len < sources.len * 2 * @sizeOf(u32))
        return Error.InvalidBindingSize;
    const aligned: []align(4) u8 = @alignCast(bytes);
    const words = std.mem.bytesAsSlice(u32, aligned);
    @memset(words, 0);
    for (sources, 0..) |source, index| {
        if (source.offset_bytes % 4 != 0) return Error.InvalidBindingSize;
        try writeWideWordOffset(words, index, source.offset_bytes / 4);
    }
}

test "Cairo decommit pointer entries preserve word offsets above 16 GiB" {
    var words = [_]u32{0} ** 4;
    const high_offset = (@as(u64, 1) << 32) + 0x12345678;
    try writeWideWordOffset(&words, 1, high_offset);
    try std.testing.expectEqual(@as(u32, 0x12345678), words[2]);
    try std.testing.expectEqual(@as(u32, 1), words[3]);
}

fn writePreprocessedOffsets(
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    fixed_bundle: fixed_table_bundle_mod.Bundle,
    identities: []const []u8,
    destination: arena_plan.Binding,
) !void {
    const sources = try collectPreprocessedBindings(fixed_bundle.allocator, schedule, plan, fixed_bundle, identities);
    defer fixed_bundle.allocator.free(sources);
    try writeBindingOffsets(resident_arena, destination, sources);
}

fn collectPreprocessedBindings(
    allocator: std.mem.Allocator,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    fixed_bundle: fixed_table_bundle_mod.Bundle,
    identities: []const []u8,
) ![]arena_plan.Binding {
    const sources = try allocator.alloc(arena_plan.Binding, identities.len);
    errdefer allocator.free(sources);
    for (identities, sources) |identity, *source| {
        const wanted = fixed_bundle.identityOrdinal(identity) orelse return Error.MissingBinding;
        source.* = try oneOrdinal(schedule, plan, "PreprocessedEvaluations", wanted);
    }
    return sources;
}

fn bindingWords(
    resident_arena: *arena_plan.ResidentArena,
    binding: arena_plan.Binding,
) ![]u32 {
    const bytes = try resident_arena.bytes(binding);
    if (bytes.len % 4 != 0) return Error.InvalidBindingSize;
    const aligned: []align(4) u8 = @alignCast(bytes);
    return std.mem.bytesAsSlice(u32, aligned);
}

fn populateTraceRetainedPointers(
    resident_arena: *arena_plan.ResidentArena,
    tree: DecommitTraceTreeBindings,
    retained_bottom_first: []const arena_plan.Binding,
) !void {
    const first_retained_log = tree.leaf_log - tree.unretained;
    if (retained_bottom_first.len != first_retained_log + 1) return Error.InvalidCardinality;
    const words = try bindingWords(resident_arena, tree.retained_pointers);
    if (words.len < (tree.leaf_log + 1) * 2) return Error.InvalidBindingSize;
    @memset(words, 0);
    for (0..first_retained_log + 1) |level| {
        const retained_index = first_retained_log - level;
        const retained = retained_bottom_first[retained_index];
        if (retained.offset_bytes % 4 != 0) return Error.InvalidBindingSize;
        try writeWideWordOffset(words, level, retained.offset_bytes / 4);
    }
}

fn populateFriRetainedPointers(
    resident_arena: *arena_plan.ResidentArena,
    tree: DecommitFriTreeBindings,
    retained_root_first: []const arena_plan.Binding,
) !void {
    if (retained_root_first.len != tree.leaf_log + 1) return Error.InvalidCardinality;
    try writeWideBindingOffsets(resident_arena, tree.retained_pointers, retained_root_first);
}

fn populateFriCoordinatePointers(
    resident_arena: *arena_plan.ResidentArena,
    tree: DecommitFriTreeBindings,
    evaluation: arena_plan.Binding,
) !void {
    const rows = @as(u64, 1) << @intCast(tree.leaf_log + 2);
    if (evaluation.size_bytes != rows * 16) return Error.InvalidBindingSize;
    const words = try bindingWords(resident_arena, tree.coordinate_pointers);
    if (words.len < 8) return Error.InvalidBindingSize;
    @memset(words, 0);
    if (evaluation.offset_bytes % 4 != 0) return Error.InvalidBindingSize;
    const base = evaluation.offset_bytes / 4;
    for (0..4) |coordinate| {
        const offset = std.math.add(u64, base, @as(u64, coordinate) * rows) catch
            return Error.InvalidBindingSize;
        try writeWideWordOffset(words, coordinate, offset);
    }
}

fn populateSparseOffsets(
    resident_arena: *arena_plan.ResidentArena,
    sparse_indices: arena_plan.Binding,
    sparse_offsets: arena_plan.Binding,
    unretained: u32,
) !void {
    if (unretained == 0 or unretained > 4) return Error.InvalidBindingSize;
    const words = try bindingWords(resident_arena, sparse_offsets);
    if (words.len < unretained) return Error.InvalidBindingSize;
    @memset(words, 0);
    var offset: u64 = 0;
    var capacity: u64 = 70 * (@as(u64, 1) << @intCast(unretained));
    for (0..unretained) |distance| {
        words[distance] = std.math.cast(u32, offset) orelse return Error.InvalidBindingSize;
        offset += capacity;
        capacity >>= 1;
    }
    if (offset * 4 > sparse_indices.size_bytes) return Error.InvalidBindingSize;
}

fn executeDecommitTraceLdeGroup(
    metal: *metal_runtime.Runtime,
    resident_arena: *arena_plan.ResidentArena,
    twiddles: arena_plan.Binding,
    tile: arena_plan.Binding,
    group: DecommitTraceGroupBindings,
    coefficients: []const arena_plan.Binding,
) !f64 {
    if (coefficients.len != group.column_count or coefficients.len == 0 or coefficients.len > 16)
        return Error.InvalidCardinality;
    var source_offsets: [16]u64 = undefined;
    var source_logs: [16]u32 = undefined;
    var output_offsets: [16]u32 = undefined;
    var output_logs: [16]u32 = undefined;
    var tile_cursor: u64 = 0;
    var max_evaluation_log: u32 = 0;
    for (coefficients, 0..) |source, index| {
        if (source.size_bytes < 32 or source.size_bytes % 4 != 0 or
            !std.math.isPowerOfTwo(source.size_bytes / 4))
            return Error.InvalidBindingSize;
        const source_log: u32 = std.math.log2_int(u64, source.size_bytes / 4);
        const evaluation_log = source_log + 1;
        const evaluation_words = @as(u64, 1) << @intCast(evaluation_log);
        if (tile_cursor + evaluation_words > tile.size_bytes / 4) return Error.InvalidBindingSize;
        source_offsets[index] = source.offset_bytes / 4;
        source_logs[index] = source_log;
        output_offsets[index] = std.math.cast(u32, tile.offset_bytes / 4 + tile_cursor) orelse
            return Error.InvalidBindingSize;
        output_logs[index] = evaluation_log;
        max_evaluation_log = @max(max_evaluation_log, evaluation_log);
        tile_cursor += evaluation_words;
    }

    const evaluation_pointer_words = try bindingWords(resident_arena, group.evaluation_pointers);
    const evaluation_log_words = try bindingWords(resident_arena, group.evaluation_logs);
    if (evaluation_pointer_words.len < coefficients.len * 2 or evaluation_log_words.len < coefficients.len)
        return Error.InvalidBindingSize;
    @memset(evaluation_pointer_words, 0);
    @memset(evaluation_log_words, 0);
    for (output_offsets[0..coefficients.len], 0..) |offset, index|
        try writeWideWordOffset(evaluation_pointer_words, index, offset);
    @memcpy(evaluation_log_words[0..coefficients.len], output_logs[0..coefficients.len]);
    if (group.coefficients) |coefficient_bindings| {
        try writeWideBindingOffsets(resident_arena, coefficient_bindings.pointers, coefficients);
        const size_words = try bindingWords(resident_arena, coefficient_bindings.sizes);
        const output_pointer_words = try bindingWords(resident_arena, coefficient_bindings.lde_output_pointers);
        if (size_words.len < coefficients.len or output_pointer_words.len < coefficients.len * 2)
            return Error.InvalidBindingSize;
        @memset(size_words, 0);
        @memset(output_pointer_words, 0);
        for (coefficients, size_words[0..coefficients.len]) |source, *size|
            size.* = std.math.cast(u32, source.size_bytes / 4) orelse return Error.InvalidBindingSize;
        for (output_offsets[0..coefficients.len], 0..) |offset, index|
            try writeWideWordOffset(output_pointer_words, index, offset);
    }

    var gpu_ms: f64 = 0;
    for (4..max_evaluation_log + 1) |evaluation_log_usize| {
        const evaluation_log: u32 = @intCast(evaluation_log_usize);
        var filtered_sources: [16]u64 = undefined;
        var filtered_logs: [16]u32 = undefined;
        var filtered_outputs: [16]u32 = undefined;
        var filtered_count: usize = 0;
        for (output_logs[0..coefficients.len], 0..) |candidate_log, index| {
            if (candidate_log != evaluation_log) continue;
            filtered_sources[filtered_count] = source_offsets[index];
            filtered_logs[filtered_count] = source_logs[index];
            filtered_outputs[filtered_count] = output_offsets[index];
            filtered_count += 1;
        }
        if (filtered_count == 0) continue;
        const evaluation_twiddles = twiddleBankBinding(twiddles, evaluation_log);
        var lde = try metal.prepareCompositionLde(
            filtered_sources[0..filtered_count],
            filtered_logs[0..filtered_count],
            filtered_outputs[0..filtered_count],
            evaluation_log,
            try twiddleOffsetForLog(evaluation_twiddles, evaluation_log),
        );
        defer lde.deinit();
        gpu_ms += try metal.compositionLdePrepared(resident_arena.buffer, lde);
    }
    return gpu_ms;
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
            if (lhs.binding.size_bytes != rhs.binding.size_bytes) return lhs.binding.size_bytes < rhs.binding.size_bytes;
            return lhs.schedule_index < rhs.schedule_index;
        }
    }.lessThan);
    const result = try allocator.alloc(arena_plan.Binding, items.items.len);
    for (items.items, result) |item, *binding| binding.* = item.binding;
    return result;
}

fn sortCanonicalCommitmentOrder(
    allocator: std.mem.Allocator,
    bindings: []arena_plan.Binding,
) !void {
    const Item = struct { canonical_index: usize, binding: arena_plan.Binding };
    const items = try allocator.alloc(Item, bindings.len);
    defer allocator.free(items);
    for (bindings, items, 0..) |binding, *item, canonical_index|
        item.* = .{ .canonical_index = canonical_index, .binding = binding };
    std.mem.sortUnstable(Item, items, {}, struct {
        fn lessThan(_: void, lhs: Item, rhs: Item) bool {
            if (lhs.binding.size_bytes != rhs.binding.size_bytes)
                return lhs.binding.size_bytes < rhs.binding.size_bytes;
            return lhs.canonical_index < rhs.canonical_index;
        }
    }.lessThan);
    for (items, bindings) |item, *binding| binding.* = item.binding;
}

fn commitmentOrderCopy(
    allocator: std.mem.Allocator,
    canonical: []const arena_plan.Binding,
) ![]arena_plan.Binding {
    const commitment = try allocator.dupe(arena_plan.Binding, canonical);
    errdefer allocator.free(commitment);
    try sortCanonicalCommitmentOrder(allocator, commitment);
    return commitment;
}

fn reorderTraceQueryValues(
    allocator: std.mem.Allocator,
    resident_arena: *arena_plan.ResidentArena,
    values_binding: arena_plan.Binding,
    commitment: []const arena_plan.Binding,
    canonical: []const arena_plan.Binding,
    query_stride: usize,
) !void {
    if (commitment.len != canonical.len or query_stride == 0) return Error.InvalidCardinality;
    var already_canonical = true;
    for (commitment, canonical) |committed, air| {
        already_canonical = already_canonical and committed.logical_id == air.logical_id;
    }
    if (already_canonical) return;

    const required_words = std.math.mul(usize, commitment.len, query_stride) catch
        return Error.InvalidBindingSize;
    const bytes: []align(4) u8 = @alignCast(try resident_arena.bytes(values_binding));
    const words = std.mem.bytesAsSlice(u32, bytes);
    if (words.len < required_words) return Error.InvalidBindingSize;
    try reorderColumnMajorValues(
        allocator,
        words[0..required_words],
        commitment,
        canonical,
        query_stride,
    );
}

fn reorderColumnMajorValues(
    allocator: std.mem.Allocator,
    values: []u32,
    commitment: []const arena_plan.Binding,
    canonical: []const arena_plan.Binding,
    stride: usize,
) !void {
    if (commitment.len != canonical.len or stride == 0 or
        values.len != std.math.mul(usize, commitment.len, stride) catch return Error.InvalidBindingSize)
        return Error.InvalidCardinality;

    var canonical_indices = std.AutoHashMap(u32, usize).init(allocator);
    defer canonical_indices.deinit();
    for (canonical, 0..) |binding, canonical_index| {
        const result = try canonical_indices.getOrPut(binding.logical_id);
        if (result.found_existing) return Error.DuplicateBinding;
        result.value_ptr.* = canonical_index;
    }

    const reordered = try allocator.alloc(u32, values.len);
    defer allocator.free(reordered);
    var assigned = try allocator.alloc(bool, commitment.len);
    defer allocator.free(assigned);
    @memset(assigned, false);
    for (commitment, 0..) |binding, commitment_index| {
        const canonical_index = canonical_indices.get(binding.logical_id) orelse
            return Error.MissingBinding;
        if (assigned[canonical_index]) return Error.DuplicateBinding;
        assigned[canonical_index] = true;
        @memcpy(
            reordered[canonical_index * stride ..][0..stride],
            values[commitment_index * stride ..][0..stride],
        );
    }
    for (assigned) |present| if (!present) return Error.MissingBinding;
    @memcpy(values, reordered);
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
            if (tree_index == 2 and std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_INTERACTION_EVAL_DIGESTS"))
                std.debug.print(
                    "interaction_canonical_map index={} component={s} instance={} captured_component={s} captured_index={} logical_id={}\n",
                    .{ destination, component.label, component.instance, captured_label, skipped + copied, item.binding.logical_id },
                );
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
        fn lessThan(_: void, lhs: Item, rhs: Item) bool {
            return lhs.ordinal_value < rhs.ordinal_value;
        }
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
    twiddles: arena_plan.Binding,
    tree_index: u32,
    leaf_seed: [8]u32,
    node_seed: [8]u32,
) !CommitmentTelemetry {
    return executeStreamingCommitmentWithMode(
        allocator,
        metal,
        resident_arena,
        schedule,
        plan,
        coefficients,
        twiddles,
        tree_index,
        leaf_seed,
        node_seed,
        .automatic,
    );
}

pub const StreamingCommitmentBenchmarkMode = enum { automatic, synchronous };

/// Bounded benchmark hook for the exact production commitment graph. Normal
/// proving always enters through executeStreamingCommitment in automatic mode.
pub fn executeStreamingCommitmentBenchmark(
    allocator: std.mem.Allocator,
    metal: *metal_runtime.Runtime,
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    coefficients: []const arena_plan.Binding,
    twiddles: arena_plan.Binding,
    tree_index: u32,
    leaf_seed: [8]u32,
    node_seed: [8]u32,
    mode: StreamingCommitmentBenchmarkMode,
) !CommitmentTelemetry {
    return executeStreamingCommitmentWithMode(
        allocator,
        metal,
        resident_arena,
        schedule,
        plan,
        coefficients,
        twiddles,
        tree_index,
        leaf_seed,
        node_seed,
        mode,
    );
}

fn executeStreamingCommitmentWithMode(
    allocator: std.mem.Allocator,
    metal: *metal_runtime.Runtime,
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    coefficients: []const arena_plan.Binding,
    twiddles: arena_plan.Binding,
    tree_index: u32,
    leaf_seed: [8]u32,
    node_seed: [8]u32,
    mode: StreamingCommitmentBenchmarkMode,
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
    if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_STAGE_TIMINGS"))
        std.debug.print("commit_prepare tree={d} coefficients={d} twiddle_offset={d} twiddle_size={d} tile_offset={d} tile_size={d} leaf_offset={d} leaf_size={d}\n", .{
            tree_index, coefficients.len, twiddles.offset_bytes, twiddles.size_bytes, tile.offset_bytes, tile.size_bytes, leaf_state.offset_bytes, leaf_state.size_bytes,
        });
    const scratch_items = collectTreePurpose(allocator, schedule, plan, "MerkleLayerScratch", tree_index) catch &[_]arena_plan.Binding{};
    defer if (scratch_items.len != 0) allocator.free(scratch_items);
    const retained = try collectTreePurpose(allocator, schedule, plan, "RetainedMerkleLayers", tree_index);
    defer allocator.free(retained);
    if (leaf_state.size_bytes % 32 != 0 or !std.math.isPowerOfTwo(leaf_state.size_bytes / 32)) return Error.InvalidBindingSize;
    const lifting_log: u32 = std.math.log2_int(u64, leaf_state.size_bytes / 32);
    var coefficient_cursor: usize = 0;
    var gpu_ms: f64 = 0;
    var lde_gpu_ms: f64 = 0;
    var leaf_gpu_ms: f64 = 0;
    var parent_gpu_ms: f64 = 0;
    const use_compact_leaf_state = !std.process.hasEnvVarConstant("STWO_ZIG_SN2_COMMIT_FULL_LOG_LEAVES") and
        !std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_COMMIT_STEPS");
    if (use_compact_leaf_state and scratch_items.len != 1) return Error.InvalidCardinality;
    const requires_intermediate_visibility = std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_STAGE_TIMINGS") or
        std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_COMMIT_LDE_DIGESTS") or
        std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_COMMIT_STEPS") or
        std.process.hasEnvVarConstant("STWO_ZIG_SN2_REPEAT_COMMIT_LDE") or
        std.process.hasEnvVarConstant("STWO_ZIG_SN2_REPAIR_COLUMN_613_LDE");
    var command_epoch: ?metal_runtime.CommandEpoch = if (mode == .automatic and use_compact_leaf_state and !requires_intermediate_visibility)
        try metal.beginCommandEpoch(resident_arena.buffer)
    else
        null;
    defer if (command_epoch) |*epoch| epoch.deinit();
    var previous_group_log: ?u32 = null;
    var leaf_state_log: ?u32 = null;
    var command_epoch_stats: ?metal_runtime.CommandEpochStats = null;
    for (group_descriptors, 0..) |descriptor, group_index| {
        const width = std.math.cast(usize, descriptor.size_bytes / 4) orelse return Error.InvalidBindingSize;
        if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_STAGE_TIMINGS") and group_index % 32 == 0)
            std.debug.print("commit_progress tree={d} group={d} coefficient_cursor={d} gpu_ms={d:.3}\n", .{
                tree_index, group_index, coefficient_cursor, gpu_ms,
            });
        if (width == 0 or width > 16 or coefficient_cursor + width > coefficients.len) {
            std.debug.print("commit_group_invalid tree={d} group={d} width={d} cursor={d} coefficients={d}\n", .{
                tree_index, group_index, width, coefficient_cursor, coefficients.len,
            });
            return Error.InvalidCardinality;
        }
        const group = coefficients[coefficient_cursor .. coefficient_cursor + width];
        var output_offsets: [16]u32 = undefined;
        var output_logs: [16]u32 = undefined;
        var tile_cursor: u64 = 0;
        for (group, 0..) |source, index| {
            if (source.size_bytes < 64 or !std.math.isPowerOfTwo(source.size_bytes / 4)) {
                std.debug.print("commit_source_size_invalid tree={d} group={d} logical_id={d} offset={d} size={d}\n", .{
                    tree_index, group_index, source.logical_id, source.offset_bytes, source.size_bytes,
                });
                return Error.InvalidBindingSize;
            }
            const coefficient_log: u32 = std.math.log2_int(u64, source.size_bytes / 4);
            const evaluation_log = coefficient_log + 1;
            const evaluation_words = @as(u64, 1) << @intCast(evaluation_log);
            if (tile_cursor + evaluation_words > tile.size_bytes / 4) {
                std.debug.print("commit_tile_size_invalid tree={d} group={d} cursor={d} evaluation_words={d} tile_words={d}\n", .{
                    tree_index, group_index, tile_cursor, evaluation_words, tile.size_bytes / 4,
                });
                return Error.InvalidBindingSize;
            }
            output_offsets[index] = std.math.cast(u32, tile.offset_bytes / 4 + tile_cursor) orelse {
                std.debug.print("commit_tile_offset_overflow tree={d} group={d} index={d} offset={d}\n", .{
                    tree_index, group_index, index, tile.offset_bytes + tile_cursor * 4,
                });
                return Error.InvalidBindingSize;
            };
            output_logs[index] = evaluation_log;
            tile_cursor += evaluation_words;
        }
        if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_COMMIT_SOURCE_DIGESTS"))
            try commitment_telemetry.logCommitSourceDigests(resident_arena, coefficient_cursor, group);
        if (tree_index == 2 and
            std.process.hasEnvVarConstant("STWO_ZIG_SN2_REPAIR_COLUMN_613_LDE") and
            coefficient_cursor <= 2241 and 2241 < coefficient_cursor + width)
        {
            const local_index = 2241 - coefficient_cursor;
            const file = try std.fs.createFileAbsolute("/tmp/sn2-column613-pre-group-source.u32le", .{});
            defer file.close();
            try file.writeAll(try resident_arena.bytes(group[local_index]));
        }
        for (4..lifting_log + 1) |evaluation_log_usize| {
            const evaluation_log: u32 = @intCast(evaluation_log_usize);
            var sources = std.ArrayList(u64).empty;
            defer sources.deinit(allocator);
            var logs = std.ArrayList(u32).empty;
            defer logs.deinit(allocator);
            var outputs = std.ArrayList(u32).empty;
            defer outputs.deinit(allocator);
            for (group, output_offsets[0..width], output_logs[0..width]) |source, output, log_size| {
                if (log_size != evaluation_log) continue;
                try sources.append(allocator, source.offset_bytes / 4);
                try logs.append(allocator, std.math.log2_int(u64, source.size_bytes / 4));
                try outputs.append(allocator, output);
            }
            if (sources.items.len == 0) continue;
            const evaluation_twiddles = twiddleBankBinding(twiddles, evaluation_log);
            const twiddle_offset = twiddleOffsetForLog(evaluation_twiddles, evaluation_log) catch {
                std.debug.print("commit_twiddle_offset_invalid tree={d} group={d} evaluation_log={d} offset={d} size={d}\n", .{
                    tree_index, group_index, evaluation_log, evaluation_twiddles.offset_bytes, evaluation_twiddles.size_bytes,
                });
                return Error.InvalidBindingSize;
            };
            var lde = try metal.prepareCompositionLde(sources.items, logs.items, outputs.items, evaluation_log, twiddle_offset);
            defer lde.deinit();
            const elapsed_gpu_ms = if (command_epoch) |*epoch| epoch_time: {
                try epoch.encodeCompositionLde(lde);
                break :epoch_time 0;
            } else try metal.compositionLdePrepared(resident_arena.buffer, lde);
            gpu_ms += elapsed_gpu_ms;
            lde_gpu_ms += elapsed_gpu_ms;
            if (group_index == 48 and std.process.hasEnvVarConstant("STWO_ZIG_SN2_REPEAT_COMMIT_LDE")) {
                const first_digest = commitment_telemetry.sampleCommitOutputs(resident_arena, outputs.items, evaluation_log);
                const repeated_gpu_ms = try metal.compositionLdePrepared(resident_arena.buffer, lde);
                gpu_ms += repeated_gpu_ms;
                lde_gpu_ms += repeated_gpu_ms;
                const second_digest = commitment_telemetry.sampleCommitOutputs(resident_arena, outputs.items, evaluation_log);
                std.debug.print(
                    "commit_lde_repeat evaluation_log={} first={x:0>16} second={x:0>16}\n",
                    .{ evaluation_log, first_digest, second_digest },
                );
            }
        }
        if (tree_index == 2 and
            std.process.hasEnvVarConstant("STWO_ZIG_SN2_REPAIR_COLUMN_613_LDE") and
            coefficient_cursor <= 2241 and 2241 < coefficient_cursor + width)
        {
            const local_index = 2241 - coefficient_cursor;
            const source = group[local_index];
            const diagnostic_source = group[local_index - 1];
            @memcpy(
                try resident_arena.bytes(diagnostic_source),
                try resident_arena.bytes(source),
            );
            const evaluation_log = output_logs[local_index];
            const evaluation_twiddles = twiddleBankBinding(twiddles, evaluation_log);
            const sources = [_]u64{diagnostic_source.offset_bytes / 4};
            const logs = [_]u32{std.math.log2_int(u64, diagnostic_source.size_bytes / 4)};
            const outputs = [_]u32{output_offsets[local_index]};
            var repair = try metal.prepareCompositionLde(
                &sources,
                &logs,
                &outputs,
                evaluation_log,
                try twiddleOffsetForLog(evaluation_twiddles, evaluation_log),
            );
            defer repair.deinit();
            const repair_gpu_ms = try metal.compositionLdePrepared(resident_arena.buffer, repair);
            gpu_ms += repair_gpu_ms;
            lde_gpu_ms += repair_gpu_ms;
            const lde_words = @as(usize, 1) << @intCast(evaluation_log);
            const arena_bytes: [*]const u8 = @ptrCast(resident_arena.buffer.contents);
            const lde_bytes = arena_bytes[@as(usize, outputs[0]) * 4 ..][0 .. lde_words * 4];
            const file = try std.fs.createFileAbsolute("/tmp/sn2-column613-metal-lde.u32le", .{});
            defer file.close();
            try file.writeAll(lde_bytes);

            const source_bytes = try resident_arena.bytes(source);
            const source_file = try std.fs.createFileAbsolute("/tmp/sn2-column613-commit-source.u32le", .{});
            defer source_file.close();
            try source_file.writeAll(source_bytes);
            const source_words: []align(1) const u32 = std.mem.bytesAsSlice(u32, source_bytes);
            const coefficient_values = try allocator.alloc(M31, source_words.len);
            for (source_words, coefficient_values) |word, *value|
                value.* = M31.fromCanonical(word % 0x7fffffff);
            var cpu_coefficients = try circle_poly_mod.CircleCoefficients.initOwned(coefficient_values);
            defer cpu_coefficients.deinit(allocator);
            const cpu_lde = try cpu_coefficients.evaluate(
                allocator,
                canonic_circle_mod.CanonicCoset.new(evaluation_log).circleDomain(),
            );
            defer allocator.free(@constCast(cpu_lde.values));
            const cpu_file = try std.fs.createFileAbsolute("/tmp/sn2-column613-repair-cpu-lde.u32le", .{});
            defer cpu_file.close();
            try cpu_file.writeAll(std.mem.sliceAsBytes(cpu_lde.values));
            @memcpy(
                @constCast(lde_bytes),
                std.mem.sliceAsBytes(cpu_lde.values),
            );
            const repaired_file = try std.fs.createFileAbsolute("/tmp/sn2-column613-repaired-lde.u32le", .{});
            defer repaired_file.close();
            try repaired_file.writeAll(lde_bytes);
        }
        if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_COMMIT_LDE_DIGESTS"))
            commitment_telemetry.logCommitLdeDigests(
                resident_arena,
                coefficient_cursor,
                group,
                output_offsets[0..width],
                output_logs[0..width],
            );
        var group_log: u32 = 0;
        for (output_logs[0..width]) |output_log| group_log = @max(group_log, output_log);
        if (group_log > lifting_log or (previous_group_log != null and group_log < previous_group_log.?))
            return Error.InvalidBindingSize;
        const is_final = group_index + 1 == group_descriptors.len;
        const elapsed_leaf_gpu_ms = if (use_compact_leaf_state) compact: {
            const destination_log = if (is_final) lifting_log else group_log;
            var source_state_offset = try wordOffset(leaf_state);
            var source_state_log = leaf_state_log orelse destination_log;
            if (leaf_state_log) |materialized_log| {
                if (destination_log < materialized_log) return Error.InvalidBindingSize;
                if (destination_log > materialized_log) {
                    const scratch = scratch_items[0];
                    const snapshot_words = (@as(u64, 1) << @intCast(materialized_log)) * 8;
                    if (snapshot_words > scratch.size_bytes / 4 or snapshot_words > std.math.maxInt(u32))
                        return Error.InvalidBindingSize;
                    const ranges = [_]metal_runtime.ArenaCopyRange{.{
                        .source_word_offset = leaf_state.offset_bytes / 4,
                        .destination_word_offset = scratch.offset_bytes / 4,
                        .word_count = @intCast(snapshot_words),
                    }};
                    var copy = try metal.prepareArenaCopies(&ranges);
                    defer copy.deinit();
                    const copy_gpu_ms = if (command_epoch) |*epoch| epoch_time: {
                        try epoch.encodeArenaCopy(copy);
                        break :epoch_time 0;
                    } else try metal.arenaCopyPrepared(resident_arena.buffer, copy);
                    gpu_ms += copy_gpu_ms;
                    leaf_gpu_ms += copy_gpu_ms;
                    source_state_offset = try wordOffset(scratch);
                    source_state_log = materialized_log;
                }
            }
            const elapsed = if (command_epoch) |*epoch| epoch_time: {
                try epoch.encodeCompactLeaf(
                    output_offsets[0..width],
                    output_logs[0..width],
                    source_state_offset,
                    source_state_log,
                    try wordOffset(leaf_state),
                    destination_log,
                    @intCast(coefficient_cursor),
                    is_final,
                    0,
                    leaf_seed,
                );
                break :epoch_time 0;
            } else try metal.leafAbsorbCompact(
                resident_arena.buffer,
                output_offsets[0..width],
                output_logs[0..width],
                source_state_offset,
                source_state_log,
                try wordOffset(leaf_state),
                destination_log,
                @intCast(coefficient_cursor),
                is_final,
                0,
                leaf_seed,
            );
            leaf_state_log = destination_log;
            break :compact elapsed;
        } else try metal.leafAbsorb(
            resident_arena.buffer,
            output_offsets[0..width],
            output_logs[0..width],
            try wordOffset(leaf_state),
            lifting_log,
            @intCast(coefficient_cursor),
            is_final,
            0,
            leaf_seed,
        );
        gpu_ms += elapsed_leaf_gpu_ms;
        leaf_gpu_ms += elapsed_leaf_gpu_ms;
        if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_COMMIT_STEPS"))
            try commitment_telemetry.logCommitStepSamples(
                resident_arena,
                group_index,
                output_offsets[0..width],
                output_logs[0..width],
                leaf_state,
            );
        previous_group_log = group_log;
        coefficient_cursor += width;
    }
    if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_STAGE_TIMINGS"))
        std.debug.print("commit_progress tree={d} groups_done={d} coefficient_cursor={d} gpu_ms={d:.3}\n", .{
            tree_index, group_descriptors.len, coefficient_cursor, gpu_ms,
        });
    if (coefficient_cursor != coefficients.len) return Error.InvalidCardinality;
    if (use_compact_leaf_state and leaf_state_log != lifting_log) return Error.InvalidBindingSize;
    if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_COMMIT_DIGESTS"))
        try commitment_telemetry.logBindingDigest(resident_arena, "commit_leaf", 0, leaf_state);
    const bottom_hashes = retained[0].size_bytes / 32;
    if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_STAGE_TIMINGS")) {
        std.debug.print("commit_merkle tree={d} scratch_count={d} retained_count={d} bottom_hashes={d}\n", .{
            tree_index, scratch_items.len, retained.len, bottom_hashes,
        });
        for (scratch_items, 0..) |scratch, index| std.debug.print(
            "commit_merkle_scratch tree={d} index={d} offset={d} size={d}\n",
            .{ tree_index, index, scratch.offset_bytes, scratch.size_bytes },
        );
        for (retained, 0..) |layer, index| std.debug.print(
            "commit_merkle_retained tree={d} index={d} offset={d} size={d}\n",
            .{ tree_index, index, layer.offset_bytes, layer.size_bytes },
        );
    }
    var child_offsets = std.ArrayList(u32).empty;
    defer child_offsets.deinit(allocator);
    var destination_offsets = std.ArrayList(u32).empty;
    defer destination_offsets.deinit(allocator);
    var parent_counts = std.ArrayList(u32).empty;
    defer parent_counts.deinit(allocator);
    var retained_copy_targets = std.ArrayList(?arena_plan.Binding).empty;
    defer retained_copy_targets.deinit(allocator);
    var current_offset = wordOffset(leaf_state) catch {
        std.debug.print("commit_leaf_offset_overflow tree={d} offset={d}\n", .{ tree_index, leaf_state.offset_bytes });
        return Error.InvalidBindingSize;
    };
    var current_hashes = leaf_state.size_bytes / 32;
    var ping_is_leaf = true;
    while (current_hashes > bottom_hashes) {
        const next_hashes = current_hashes / 2;
        var copy_target: ?arena_plan.Binding = null;
        const destination = if (next_hashes == bottom_hashes) blk: {
            break :blk wordOffset(retained[0]) catch {
                if (scratch_items.len == 0) return Error.MissingBinding;
                ping_is_leaf = !ping_is_leaf;
                const scratch = if (ping_is_leaf) leaf_state else scratch_items[0];
                copy_target = retained[0];
                break :blk wordOffset(scratch) catch return Error.InvalidBindingSize;
            };
        } else blk: {
            if (scratch_items.len == 0) return Error.MissingBinding;
            ping_is_leaf = !ping_is_leaf;
            const scratch = if (ping_is_leaf) leaf_state else scratch_items[0];
            break :blk wordOffset(scratch) catch {
                std.debug.print("commit_scratch_offset_overflow tree={d} offset={d}\n", .{ tree_index, scratch.offset_bytes });
                return Error.InvalidBindingSize;
            };
        };
        try child_offsets.append(allocator, current_offset);
        try destination_offsets.append(allocator, destination);
        try parent_counts.append(allocator, @intCast(next_hashes));
        try retained_copy_targets.append(allocator, copy_target);
        current_offset = destination;
        current_hashes = next_hashes;
    }
    for (retained[1..], 1..) |layer, layer_index| {
        var copy_target: ?arena_plan.Binding = null;
        const destination = wordOffset(layer) catch blk: {
            if (scratch_items.len == 0) return Error.MissingBinding;
            ping_is_leaf = !ping_is_leaf;
            const scratch = if (ping_is_leaf) leaf_state else scratch_items[0];
            if (scratch.size_bytes < layer.size_bytes) {
                std.debug.print("commit_retained_scratch_too_small tree={d} layer={d} scratch_size={d} layer_size={d}\n", .{
                    tree_index, layer_index, scratch.size_bytes, layer.size_bytes,
                });
                return Error.InvalidBindingSize;
            }
            copy_target = layer;
            break :blk wordOffset(scratch) catch return Error.InvalidBindingSize;
        };
        try child_offsets.append(allocator, current_offset);
        try destination_offsets.append(allocator, destination);
        try parent_counts.append(allocator, @intCast(layer.size_bytes / 32));
        try retained_copy_targets.append(allocator, copy_target);
        current_offset = destination;
    }
    var has_retained_copy = false;
    for (retained_copy_targets.items) |copy_target| has_retained_copy = has_retained_copy or copy_target != null;
    if (!has_retained_copy) {
        var parent_chain = try metal.prepareMerkleParentChain(
            child_offsets.items,
            destination_offsets.items,
            parent_counts.items,
            node_seed,
            cairo_domain_prefix_bytes,
        );
        defer parent_chain.deinit();
        const elapsed_parent_gpu_ms = if (command_epoch) |*epoch| epoch_time: {
            try epoch.encodeMerkleParentChain(parent_chain);
            break :epoch_time 0;
        } else try metal.merkleParentChainPrepared(resident_arena.buffer, parent_chain);
        gpu_ms += elapsed_parent_gpu_ms;
        parent_gpu_ms += elapsed_parent_gpu_ms;
    } else {
        for (child_offsets.items, destination_offsets.items, parent_counts.items, retained_copy_targets.items) |child, destination, count, copy_target| {
            var parent_level = try metal.prepareMerkleParentChain(
                &.{child},
                &.{destination},
                &.{count},
                node_seed,
                cairo_domain_prefix_bytes,
            );
            defer parent_level.deinit();
            const elapsed_parent_gpu_ms = if (command_epoch) |*epoch| epoch_time: {
                try epoch.encodeMerkleParentChain(parent_level);
                break :epoch_time 0;
            } else try metal.merkleParentChainPrepared(resident_arena.buffer, parent_level);
            gpu_ms += elapsed_parent_gpu_ms;
            parent_gpu_ms += elapsed_parent_gpu_ms;
            if (copy_target) |target| {
                const ranges = [_]metal_runtime.ArenaCopyRange{.{
                    .source_word_offset = destination,
                    .destination_word_offset = target.offset_bytes / 4,
                    .word_count = @intCast(target.size_bytes / 4),
                }};
                var copy = try metal.prepareArenaCopies(&ranges);
                defer copy.deinit();
                const copy_gpu_ms = if (command_epoch) |*epoch| epoch_time: {
                    try epoch.encodeArenaCopy(copy);
                    break :epoch_time 0;
                } else try metal.arenaCopyPrepared(resident_arena.buffer, copy);
                gpu_ms += copy_gpu_ms;
                parent_gpu_ms += copy_gpu_ms;
            }
        }
    }
    if (command_epoch) |*epoch| {
        try epoch.submit();
        const epoch_stats = try epoch.wait();
        command_epoch_stats = epoch_stats;
        gpu_ms += epoch_stats.gpu_milliseconds;
    }
    if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_STAGE_TIMINGS"))
        std.debug.print("commit_merkle tree={d} parents_done={d} gpu_ms={d:.3}\n", .{ tree_index, parent_counts.items.len, gpu_ms });
    if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_LOG_COMMIT_DIGESTS")) {
        for (retained, 0..) |layer, layer_index|
            try commitment_telemetry.logBindingDigest(resident_arena, "commit_retained", layer_index, layer);
    }
    const root = retained[retained.len - 1];
    const transcript_ordinals = [_]u32{ 3, 20, 23, 24 };
    const transcript_root = try oneOrdinal(schedule, plan, "TranscriptInput", transcript_ordinals[tree_index]);
    @memcpy((try resident_arena.bytes(transcript_root))[0..32], (try resident_arena.bytes(root))[0..32]);
    return .{
        .gpu_ms = gpu_ms,
        .lde_gpu_ms = lde_gpu_ms,
        .leaf_gpu_ms = leaf_gpu_ms,
        .parent_gpu_ms = parent_gpu_ms,
        .root = root,
        .command_epoch_stats = command_epoch_stats,
    };
}

fn buildProofCopies(
    allocator: std.mem.Allocator,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    fri_round_count: usize,
) ![]ProofCopy {
    const transcript_ordinals = try proofCopyTranscriptOrdinals(allocator, fri_round_count);
    defer allocator.free(transcript_ordinals);
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
    for (transcript_ordinals) |input| try append(
        &copies,
        allocator,
        &cursor,
        try oneOrdinal(schedule, plan, "TranscriptInput", input),
    );
    try append(&copies, allocator, &cursor, try one(schedule, plan, "DecommitAssembly"));
    return copies.toOwnedSlice(allocator);
}

fn proofCopyTranscriptOrdinals(
    allocator: std.mem.Allocator,
    fri_round_count: usize,
) ![]u32 {
    if (fri_round_count == 0 or fri_round_count > 31) return Error.InvalidCardinality;
    const ordinals = try allocator.alloc(u32, fri_round_count + 9);
    const prefix = [_]u32{ 3, 20, 23, 24, 22, 21, 25 };
    @memcpy(ordinals[0..prefix.len], &prefix);
    for (0..fri_round_count) |round| {
        ordinals[prefix.len + round] = 65536 + @as(u32, @intCast(round)) * 4;
    }
    ordinals[ordinals.len - 2] = 30;
    ordinals[ordinals.len - 1] = 31;
    return ordinals;
}

test "Cairo proof assembly uses seven runtime FRI roots" {
    const ordinals = try proofCopyTranscriptOrdinals(std.testing.allocator, 7);
    defer std.testing.allocator.free(ordinals);
    try std.testing.expectEqualSlices(u32, &.{
        3,     20,    23,    24,    22,    21,    25,
        65536, 65540, 65544, 65548, 65552, 65556, 65560,
        30,    31,
    }, ordinals);
}

test "Cairo proof assembly preserves eight-root SN2 order" {
    const ordinals = try proofCopyTranscriptOrdinals(std.testing.allocator, 8);
    defer std.testing.allocator.free(ordinals);
    try std.testing.expectEqualSlices(u32, &.{
        3,     20,    23,    24,    22,    21,    25,
        65536, 65540, 65544, 65548, 65552, 65556, 65560,
        65564, 30,    31,
    }, ordinals);
}

test "Cairo preprocessed SIMD coefficient blocks are canonicalized" {
    const allocator = std.testing.allocator;
    const log_size: u32 = 17;
    const words = try allocator.alloc(u32, @as(usize, 1) << log_size);
    defer allocator.free(words);
    for (words, 0..) |*word, index| word.* = @intCast(index);
    canonicalizeSimdCoefficientBlocks(words, log_size);
    try std.testing.expectEqual(@as(u32, 128 * 16), words[16]);
    try std.testing.expectEqual(@as(u32, 16), words[128 * 16]);
    canonicalizeSimdCoefficientBlocks(words, log_size);
    for (words, 0..) |word, index| try std.testing.expectEqual(@as(u32, @intCast(index)), word);
}

test "Cairo AIR trace order remains separate from commitment degree order" {
    const canonical = [_]arena_plan.Binding{
        .{
            .logical_id = 10,
            .slot = 0,
            .offset_bytes = 0,
            .size_bytes = 64,
            .materialization = .resident,
            .occupied = [_]u64{0} ** (arena_plan.max_ticks / 64),
        },
        .{
            .logical_id = 11,
            .slot = 1,
            .offset_bytes = 64,
            .size_bytes = 16,
            .materialization = .resident,
            .occupied = [_]u64{0} ** (arena_plan.max_ticks / 64),
        },
        .{
            .logical_id = 20,
            .slot = 2,
            .offset_bytes = 80,
            .size_bytes = 4,
            .materialization = .resident,
            .occupied = [_]u64{0} ** (arena_plan.max_ticks / 64),
        },
        .{
            .logical_id = 21,
            .slot = 3,
            .offset_bytes = 84,
            .size_bytes = 64,
            .materialization = .resident,
            .occupied = [_]u64{0} ** (arena_plan.max_ticks / 64),
        },
    };
    const commitment = try commitmentOrderCopy(std.testing.allocator, &canonical);
    defer std.testing.allocator.free(commitment);

    for (canonical, [_]u32{ 10, 11, 20, 21 }) |binding, expected|
        try std.testing.expectEqual(expected, binding.logical_id);
    for (commitment, [_]u32{ 20, 11, 10, 21 }) |binding, expected|
        try std.testing.expectEqual(expected, binding.logical_id);

    var queried_values = [_]u32{ 200, 201, 110, 111, 100, 101, 210, 211 };
    try reorderColumnMajorValues(
        std.testing.allocator,
        &queried_values,
        commitment,
        &canonical,
        2,
    );
    try std.testing.expectEqualSlices(
        u32,
        &.{ 100, 101, 110, 111, 200, 201, 210, 211 },
        &queried_values,
    );

    var missing = canonical;
    missing[3].logical_id = 99;
    try std.testing.expectError(
        Error.MissingBinding,
        reorderColumnMajorValues(
            std.testing.allocator,
            &queried_values,
            commitment,
            &missing,
            2,
        ),
    );
}

test "Cairo schedule-order collection accepts component-local ordinals" {
    var plan_bindings = [_]arena_plan.Binding{
        .{
            .logical_id = 40,
            .slot = 0,
            .offset_bytes = 0,
            .size_bytes = 16,
            .materialization = .resident,
            .occupied = [_]u64{0} ** 16,
        },
        .{
            .logical_id = 41,
            .slot = 1,
            .offset_bytes = 16,
            .size_bytes = 16,
            .materialization = .resident,
            .occupied = [_]u64{0} ** 16,
        },
    };
    var empty_slots: [0]arena_plan.Slot = .{};
    var empty_actions: [0]arena_plan.Action = .{};
    var empty_offsets: [0]usize = .{};
    const plan = arena_plan.Plan{
        .allocator = std.testing.allocator,
        .bindings = &plan_bindings,
        .slots = &empty_slots,
        .actions = &empty_actions,
        .action_offsets = &empty_offsets,
        .total_bytes = 32,
        .peak_live_bytes = 32,
        .plan_hash = 0,
    };
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        \\[
        \\  {"purpose":"FixedMultiplicity","component":"range_check_8","ordinal":0,"id":41},
        \\  {"purpose":"FixedMultiplicity","component":"range_check_6","ordinal":0,"id":40}
        \\]
    ,
        .{},
    );
    defer parsed.deinit();
    const collected = try collectScheduleOrder(
        std.testing.allocator,
        parsed.value.array.items,
        plan,
        "FixedMultiplicity",
    );
    defer std.testing.allocator.free(collected);
    try std.testing.expectEqual(@as(usize, 2), collected.len);
    try std.testing.expectEqual(@as(u32, 41), collected[0].logical_id);
    try std.testing.expectEqual(@as(u32, 40), collected[1].logical_id);
}

test "Cairo relation component groups preserve instance boundaries" {
    const bindings = [_]NamedBinding{
        .{ .component = "memory_id_to_big", .ordinal = 0, .binding = undefined },
        .{ .component = "memory_id_to_big", .ordinal = 1, .binding = undefined },
        .{ .component = "memory_id_to_big", .ordinal = 0, .binding = undefined },
        .{ .component = "memory_id_to_big", .ordinal = 1, .binding = undefined },
        .{ .component = "memory_id_to_big", .ordinal = 2, .binding = undefined },
    };
    const ranges = try namedGroupRanges(std.testing.allocator, &bindings);
    defer std.testing.allocator.free(ranges);
    try std.testing.expectEqual(@as(usize, 2), ranges.len);
    try std.testing.expectEqual(NamedGroupRange{ .start = 0, .len = 2 }, ranges[0]);
    try std.testing.expectEqual(NamedGroupRange{ .start = 2, .len = 3 }, ranges[1]);

    const invalid = [_]NamedBinding{
        .{ .component = "memory_id_to_big", .ordinal = 0, .binding = undefined },
        .{ .component = "memory_id_to_big", .ordinal = 2, .binding = undefined },
    };
    try std.testing.expectError(Error.InvalidSchedule, namedGroupRanges(std.testing.allocator, &invalid));
}

test "Cairo relation claimed sums require contiguous exact bindings" {
    var plan_bindings = [_]arena_plan.Binding{
        .{
            .logical_id = 40,
            .slot = 0,
            .offset_bytes = 0,
            .size_bytes = 16,
            .materialization = .resident,
            .occupied = [_]u64{0} ** 16,
        },
        .{
            .logical_id = 41,
            .slot = 1,
            .offset_bytes = 16,
            .size_bytes = 16,
            .materialization = .resident,
            .occupied = [_]u64{0} ** 16,
        },
    };
    var empty_slots: [0]arena_plan.Slot = .{};
    var empty_actions: [0]arena_plan.Action = .{};
    var empty_offsets: [0]usize = .{};
    const plan = arena_plan.Plan{
        .allocator = std.testing.allocator,
        .bindings = &plan_bindings,
        .slots = &empty_slots,
        .actions = &empty_actions,
        .action_offsets = &empty_offsets,
        .total_bytes = 32,
        .peak_live_bytes = 32,
        .plan_hash = 0,
    };
    const claimed_sums = [_]arena_plan.Binding{ plan_bindings[0], plan_bindings[1] };
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        \\[
        \\  {"purpose":"RelationClaimedSum","ordinal":1,"id":41},
        \\  {"purpose":"RelationClaimedSum","ordinal":0,"id":40}
        \\]
    ,
        .{},
    );
    defer parsed.deinit();
    try validateClaimedSumOrder(parsed.value.array.items, plan, &claimed_sums);

    const swapped = [_]arena_plan.Binding{ plan_bindings[1], plan_bindings[0] };
    try std.testing.expectError(
        Error.InvalidSchedule,
        validateClaimedSumOrder(parsed.value.array.items, plan, &swapped),
    );

    var duplicate = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        \\[
        \\  {"purpose":"RelationClaimedSum","ordinal":0,"id":40},
        \\  {"purpose":"RelationClaimedSum","ordinal":0,"id":41}
        \\]
    ,
        .{},
    );
    defer duplicate.deinit();
    try std.testing.expectError(
        Error.InvalidClaimedSumCount,
        validateClaimedSumOrder(duplicate.value.array.items, plan, &claimed_sums),
    );
}

test "Cairo claimed sums follow Rust interaction claim order" {
    var composition = try composition_bundle_mod.Bundle.readFile(
        std.testing.allocator,
        "vectors/cairo/sn_pie_2_composition.bin",
    );
    defer composition.deinit();
    var relations = try relation_bundle_mod.Bundle.readFile(
        std.testing.allocator,
        "vectors/cairo/cairo_relation_templates.bin",
    );
    defer relations.deinit();

    var scheduled: [58]arena_plan.Binding = undefined;
    for (&scheduled, 0..) |*binding, index| binding.* = .{
        .logical_id = @intCast(index),
        .slot = @intCast(index),
        .offset_bytes = index * 16,
        .size_bytes = 16,
        .materialization = .resident,
        .occupied = [_]u64{0} ** 16,
    };
    const canonical = try canonicalClaimedSumBindings(
        std.testing.allocator,
        composition,
        relations,
        &scheduled,
    );
    defer std.testing.allocator.free(canonical);

    const expected_relation_ordinals = [_]u32{
        1,  2,  0,  3,  5,  4,  7,  11, 12, 15, 16, 17, 18, 19, 23,
        24, 50, 57, 9,  8,  10, 51, 52, 6,  28, 32, 49, 14, 25, 27,
        26, 29, 31, 30, 33, 13, 34, 39, 20, 21, 22, 45, 47, 35, 36,
        37, 38, 42, 43, 48, 46, 41, 44, 40, 53, 54, 55, 56,
    };
    try std.testing.expectEqual(expected_relation_ordinals.len, canonical.len);
    for (canonical, expected_relation_ordinals) |binding, expected|
        try std.testing.expectEqual(expected, binding.logical_id);
}

test "Cairo composition parts address global random coefficient powers" {
    var composition = try composition_bundle_mod.Bundle.readFile(
        std.testing.allocator,
        "vectors/cairo/sn_pie_2_composition.bin",
    );
    defer composition.deinit();

    var saw_nonzero_component_offset = false;
    for (composition.components) |component| {
        saw_nonzero_component_offset = saw_nonzero_component_offset or component.random_coefficient_offset != 0;
        for (component.parts) |part| {
            const base = try compositionRandomCoefficientBase(
                component.random_coefficient_offset,
                part.rc_base,
            );
            try std.testing.expectEqual(component.random_coefficient_offset + part.rc_base, base);
            try std.testing.expect(base + part.program.header.n_constraints <= composition.total_constraints);
        }
    }
    try std.testing.expect(saw_nonzero_component_offset);
    try std.testing.expectError(
        Error.InvalidBindingSize,
        compositionRandomCoefficientBase(std.math.maxInt(u32), 1),
    );
}

test "Cairo diagnostic composition component limit is bounded" {
    try std.testing.expectEqual(@as(usize, 58), try compositionComponentLimit(58, null));
    try std.testing.expectEqual(@as(usize, 7), try compositionComponentLimit(58, "7"));
    try std.testing.expectEqual(@as(usize, 58), try compositionComponentLimit(58, "58"));
    try std.testing.expectError(Error.InvalidCardinality, compositionComponentLimit(0, null));
    try std.testing.expectError(Error.InvalidCardinality, compositionComponentLimit(58, ""));
    try std.testing.expectError(Error.InvalidCardinality, compositionComponentLimit(58, "0"));
    try std.testing.expectError(Error.InvalidCardinality, compositionComponentLimit(58, "59"));
    try std.testing.expectError(Error.InvalidCardinality, compositionComponentLimit(58, "not-a-number"));
}

test "Cairo composition workspace rejects inverse twiddle aliases" {
    var inverse_twiddles = arena_plan.Binding{
        .logical_id = 1,
        .slot = 1,
        .offset_bytes = 469_778_432,
        .size_bytes = 33_554_432,
        .materialization = .resident,
        .occupied = [_]u64{0} ** 16,
    };
    const accumulators = arena_plan.Binding{
        .logical_id = 2,
        .slot = 2,
        .offset_bytes = 16_384,
        .size_bytes = 536_852_992,
        .materialization = .resident,
        .occupied = [_]u64{0} ** 16,
    };
    try std.testing.expectError(
        Error.InvalidBindingAlias,
        validateDisjointBindings(inverse_twiddles, accumulators),
    );
    try validateDisjointActiveBindings(inverse_twiddles, accumulators);

    inverse_twiddles.occupied[0] = 1;
    var active_accumulators = accumulators;
    active_accumulators.occupied[0] = 1;
    try std.testing.expectError(
        Error.InvalidBindingAlias,
        validateDisjointActiveBindings(inverse_twiddles, active_accumulators),
    );

    inverse_twiddles.offset_bytes = accumulators.offset_bytes + accumulators.size_bytes;
    try validateDisjointBindings(inverse_twiddles, accumulators);

    inverse_twiddles.offset_bytes = std.math.maxInt(u64) - inverse_twiddles.size_bytes + 1;
    try std.testing.expectError(
        Error.InvalidBindingSize,
        validateDisjointBindings(inverse_twiddles, accumulators),
    );
}

test "Cairo component-local relation preparation rejects an empty claim layout" {
    var bindings: PreparedProofBindings = undefined;
    bindings.relation_claimed_sums = &.{};
    try std.testing.expectError(
        Error.InvalidClaimedSumCount,
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
}

test "Cairo native fixed trace operations are addressed by component" {
    var operations = [_]FixedBaseTraceOperation{
        .{ .allocator = undefined, .component = "range_check_6", .copy = undefined, .interpolation = undefined },
        .{ .allocator = undefined, .component = "range_check_8", .copy = undefined, .interpolation = undefined },
    };
    var batch: NativeBaseInterpolationBatch = undefined;
    batch.fixed = &operations;
    try std.testing.expectEqual(@as(?u32, 0), try batch.fixedIndex("range_check_6"));
    try std.testing.expectEqual(@as(?u32, 1), try batch.fixedIndex("range_check_8"));
    try std.testing.expectEqual(@as(?u32, null), try batch.fixedIndex("range_check_9_9"));
}

test "Cairo native fixed trace operation owns its component name" {
    var source = [_]u8{ 'r', 'a', 'n', 'g', 'e', '_', 'c', 'h', 'e', 'c', 'k', '_', '6' };
    const operation = try FixedBaseTraceOperation.init(
        std.testing.allocator,
        &source,
        undefined,
        undefined,
    );
    defer std.testing.allocator.free(operation.component);
    source[0] = 'X';
    try std.testing.expectEqualStrings("range_check_6", operation.component);
}

test "Cairo base interpolation batches reset only request bookkeeping" {
    const Helpers = struct {
        fn circle(last_tick: u16, accumulated_gpu_ms: f64) protocol_recipes.CircleIfftRecipe {
            return .{
                .allocator = std.testing.allocator,
                .metal = undefined,
                .arena = undefined,
                .sources = &.{},
                .destinations = &.{},
                .prepared = undefined,
                .log_size = 19,
                .inverse_twiddle_offset_words = 0,
                .scale_factor = 1,
                .last_tick = last_tick,
                .accumulated_gpu_ms = accumulated_gpu_ms,
            };
        }
    };

    var recorded_recipes = [_]protocol_recipes.CircleIfftRecipe{
        Helpers.circle(3, 1.5),
        Helpers.circle(4, 2.5),
    };
    var recorded = RecordedBaseInterpolationBatch{
        .allocator = std.testing.allocator,
        .resident_arena = undefined,
        .recipes = &recorded_recipes,
        .ec_op_recipe = Helpers.circle(5, 3.5),
        .ec_op_owner = 1,
    };
    recorded.resetForRequest();
    for (recorded.recipes) |recipe| {
        try std.testing.expectEqual(@as(?u16, null), recipe.last_tick);
        try std.testing.expectEqual(@as(f64, 0), recipe.accumulated_gpu_ms);
    }
    try std.testing.expectEqual(@as(?u16, null), recorded.ec_op_recipe.?.last_tick);
    try std.testing.expectEqual(@as(f64, 0), recorded.ec_op_recipe.?.accumulated_gpu_ms);

    var memory_values = [_]protocol_recipes.CircleIfftRecipe{Helpers.circle(7, 4.5)};
    var fixed = [_]FixedBaseTraceOperation{.{
        .allocator = undefined,
        .component = "range_check_6",
        .copy = undefined,
        .interpolation = Helpers.circle(8, 5.5),
    }};
    var native = NativeBaseInterpolationBatch{
        .allocator = std.testing.allocator,
        .metal = undefined,
        .resident_arena = undefined,
        .memory_address = Helpers.circle(6, 3.5),
        .memory_values = &memory_values,
        .fixed = &fixed,
    };
    native.resetForRequest();
    try std.testing.expectEqual(@as(?u16, null), native.memory_address.last_tick);
    try std.testing.expectEqual(@as(f64, 0), native.memory_address.accumulated_gpu_ms);
    try std.testing.expectEqual(@as(?u16, null), native.memory_values[0].last_tick);
    try std.testing.expectEqual(@as(f64, 0), native.memory_values[0].accumulated_gpu_ms);
    try std.testing.expectEqual(@as(?u16, null), native.fixed[0].interpolation.last_tick);
    try std.testing.expectEqual(@as(f64, 0), native.fixed[0].interpolation.accumulated_gpu_ms);
}

test "Cairo multiplicity feed geometry follows scheduled runtime rows" {
    const sn2_rows: u32 = 1 << 19;
    const sub_words: u32 = 11;
    for ([_]u32{ sn2_rows, sn2_rows * 2, sn2_rows * 4 }) |rows| {
        const source = arena_plan.Binding{
            .logical_id = 0,
            .slot = 0,
            .offset_bytes = 0,
            .size_bytes = @as(u64, rows) * sub_words * @sizeOf(u32),
            .materialization = .resident,
            .occupied = [_]u64{0} ** 16,
        };
        try std.testing.expectEqual(rows, try runtimeFeedRowCount(source, sub_words));

        const destination = arena_plan.Binding{
            .logical_id = 1,
            .slot = 0,
            .offset_bytes = 0,
            .size_bytes = @as(u64, rows) * 3 * @sizeOf(u32),
            .materialization = .resident,
            .occupied = [_]u64{0} ** 16,
        };
        try std.testing.expectEqual(
            @as(u64, rows) * @sizeOf(u32),
            try runtimeFeedDestinationColumnBytes(destination, 3),
        );
    }

    var invalid: arena_plan.Binding = .{
        .logical_id = 2,
        .slot = 0,
        .offset_bytes = 0,
        .size_bytes = @as(u64, sn2_rows) * sub_words * @sizeOf(u32) - 1,
        .materialization = .resident,
        .occupied = [_]u64{0} ** 16,
    };
    try std.testing.expectError(Error.InvalidBindingSize, runtimeFeedRowCount(invalid, sub_words));
    invalid.size_bytes = @as(u64, sn2_rows) * 3 * @sizeOf(u32) - 4;
    try std.testing.expectError(Error.InvalidBindingSize, runtimeFeedDestinationColumnBytes(invalid, 3));

    var widths = std.StringHashMap(u32).init(std.testing.allocator);
    defer widths.deinit();
    var name = "range_check_18".*;
    const destination = feed_bundle_mod.Destination{ .name = &name, .words = 2 * (1 << 18) };
    try recordFeedDestinationWidth(&widths, destination, 1 << 18, 1);
    try std.testing.expectEqual(@as(?u32, 2), widths.get(&name));
    try recordFeedDestinationWidth(&widths, destination, 1 << 18, 2);
    try std.testing.expectError(Error.InvalidCardinality, recordFeedDestinationWidth(&widths, destination, 1 << 17, 1));

    var narrow_name = "range_check_11".*;
    const narrow_destination = feed_bundle_mod.Destination{ .name = &narrow_name, .words = 1 << 11 };
    try std.testing.expectError(
        Error.InvalidCardinality,
        recordFeedDestinationWidth(&widths, narrow_destination, 1 << 11, 2),
    );
}

test "Cairo AOT witness narrow addresses validate the complete binding extent" {
    const last_word = arena_plan.Binding{
        .logical_id = 0,
        .slot = 0,
        .offset_bytes = aot_narrow_address_limit_bytes - @sizeOf(u32),
        .size_bytes = @sizeOf(u32),
        .materialization = .resident,
        .occupied = [_]u64{0} ** 16,
    };
    try std.testing.expect(aotBindingFitsNarrowAddress(last_word));

    var invalid = last_word;
    invalid.size_bytes += @sizeOf(u32);
    try std.testing.expect(!aotBindingFitsNarrowAddress(invalid));
    invalid = last_word;
    invalid.offset_bytes = aot_narrow_address_limit_bytes;
    try std.testing.expect(!aotBindingFitsNarrowAddress(invalid));
    invalid = last_word;
    invalid.offset_bytes -= 1;
    try std.testing.expect(!aotBindingFitsNarrowAddress(invalid));
}

test "Cairo AOT fixed-table requirements follow witness bytecode capabilities" {
    var bundle = try witness_bundle_mod.Bundle.readFile(
        std.testing.allocator,
        "vectors/cairo/sn_pie_2_witness_programs.bin",
    );
    defer bundle.deinit();

    const complete = fixedDeductionRequirements(bundle);
    try std.testing.expect(complete.pedersen);
    try std.testing.expect(complete.poseidon);

    const add_ap = bundle.find("add_ap_opcode") orelse return error.MissingBinding;
    const arithmetic_only = witness_bundle_mod.Bundle{
        .allocator = std.testing.allocator,
        .entries = @constCast(add_ap)[0..1],
    };
    const reduced = fixedDeductionRequirements(arithmetic_only);
    try std.testing.expect(!reduced.pedersen);
    try std.testing.expect(!reduced.poseidon);
}
