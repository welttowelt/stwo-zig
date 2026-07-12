const std = @import("std");
const arena = @import("backends/metal/arena_plan.zig");
const witness_bundle_mod = @import("frontends/cairo/witness/bundle.zig");
const feed_bundle_mod = @import("frontends/cairo/witness/feed_bundle.zig");
const relation_bundle_mod = @import("frontends/cairo/witness/relation_bundle.zig");
const fixed_table_bundle_mod = @import("frontends/cairo/witness/fixed_table_bundle.zig");
const composition_bundle_mod = @import("frontends/cairo/witness/composition_bundle.zig");
const arena_binding_mod = @import("frontends/cairo/witness/arena_binding.zig");
const metal_runtime = @import("backends/metal/runtime.zig");
const adapted_input = @import("frontends/cairo/adapter/adapted_input.zig");
const cairo_adapter = @import("frontends/cairo/adapter/mod.zig");
const blake2_merkle = @import("core/vcs_lifted/blake2_merkle.zig");

const epoch_names = [_][]const u8{
    "Ingest",            "Witness", "BaseCommit", "Interaction", "InteractionCommit", "Composition",
    "CompositionCommit", "Oods",    "Quotient",   "Fri",         "Decommit",          "Assemble",
};

const Prepared = struct {
    ranges: [12]arena.LiveRange = [_]arena.LiveRange{.{ .first = 0, .last = 0 }} ** 12,
    range_count: usize = 0,
};

const PhaseList = struct {
    items: [6]u16 = [_]u16{0} ** 6,
    len: usize,

    fn slice(self: *const PhaseList) []const u16 {
        return self.items[0..self.len];
    }
};

const PurposeStat = struct {
    purpose: []const u8,
    buffers: usize = 0,
    bytes: u64 = 0,
};

const Coefficient = struct { id: u32, words: u64 };
const RetainedDestination = struct { id: u32, words: u64 };
const RetentionCandidate = struct {
    tree: usize,
    group: usize,
    words: u64,
    weighted_log: u128,
};

const RelationCoverage = struct { instances: usize, output_buffers: usize, output_bytes: u64 };
const PreprocessedCoverage = struct { sources: []?u32, buffers: usize, bytes: u64 };
const FixedTableCoverage = struct { components: usize, lookup_buffers: usize, lookup_bytes: u64 };
const MerkleParentCoverage = struct { sources: []?u32, buffers: usize, bytes: u64, chains: usize };
const MerkleCommitCoverage = struct { bottoms: []bool, commitments: usize, buffers: usize, bytes: u64 };
const EcOpCoverage = struct { rows: u64, output_buffers: usize, output_bytes: u64 };
const CompositionCoverage = struct { components: usize, parts: usize, output_buffers: usize, output_bytes: u64 };
const ScheduledColumn = struct { ordinal: u32, words: u64 };
const ScheduledGroup = struct { start: usize, len: usize, rows: u64 };

pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 3 or args.len > 8) {
        std.debug.print("usage: metal-arena-plan <arena_preflight.json> <budget-gib> [witness-programs.bin] [multiplicity-feeds.bin] [relation-templates.bin] [fixed-tables.bin] [composition.bin]\n", .{});
        return error.InvalidArguments;
    }
    const budget_gib = try std.fmt.parseFloat(f64, args[2]);
    const budget_bytes: u64 = @intFromFloat(budget_gib * 1024.0 * 1024.0 * 1024.0);
    const input = try std.fs.cwd().readFileAlloc(allocator, args[1], 64 * 1024 * 1024);
    defer allocator.free(input);
    var input_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(input, &input_digest, .{});
    const input_sha256 = std.fmt.bytesToHex(input_digest, .lower);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, input, .{});
    defer parsed.deinit();
    const schedule = parsed.value.object.get("arena").?.object.get("logical_buffer_schedule").?.array.items;
    const retained_sources = try buildRetainedSources(allocator, schedule);
    defer allocator.free(retained_sources);
    const preprocessed_coverage = try buildPreprocessedSources(allocator, schedule);
    defer allocator.free(preprocessed_coverage.sources);
    const merkle_parent_coverage = try buildMerkleParentSources(allocator, schedule);
    defer allocator.free(merkle_parent_coverage.sources);
    const merkle_commit_coverage = try buildMerkleCommitCoverage(allocator, schedule);
    defer allocator.free(merkle_commit_coverage.bottoms);
    const ec_op_coverage = try validateEcOpCoverage(schedule);
    var witness_bundle: ?witness_bundle_mod.Bundle = if (args.len >= 4)
        try witness_bundle_mod.Bundle.readFile(allocator, args[3])
    else
        null;
    defer if (witness_bundle) |*bundle| bundle.deinit();
    var feed_bundle: ?feed_bundle_mod.Bundle = if (args.len >= 5)
        try feed_bundle_mod.Bundle.readFile(allocator, args[4])
    else
        null;
    defer if (feed_bundle) |*bundle| bundle.deinit();
    var relation_bundle: ?relation_bundle_mod.Bundle = if (args.len >= 6)
        try relation_bundle_mod.Bundle.readFile(allocator, args[5])
    else
        null;
    defer if (relation_bundle) |*bundle| bundle.deinit();
    const relation_coverage: ?RelationCoverage = if (relation_bundle) |bundle|
        try validateRelationCoverage(allocator, schedule, bundle)
    else
        null;
    var fixed_table_bundle: ?fixed_table_bundle_mod.Bundle = if (args.len >= 7)
        try fixed_table_bundle_mod.Bundle.readFile(allocator, args[6])
    else
        null;
    defer if (fixed_table_bundle) |*bundle| bundle.deinit();
    var fixed_table_destinations = std.StringHashMap(void).init(allocator);
    defer fixed_table_destinations.deinit();
    const fixed_table_coverage: ?FixedTableCoverage = if (fixed_table_bundle) |bundle|
        try validateFixedTableCoverage(schedule, bundle, &fixed_table_destinations)
    else
        null;
    var composition_bundle: ?composition_bundle_mod.Bundle = if (args.len == 8)
        try composition_bundle_mod.Bundle.readFile(allocator, args[7])
    else
        null;
    defer if (composition_bundle) |*bundle| bundle.deinit();
    const composition_coverage: ?CompositionCoverage = if (composition_bundle) |bundle|
        try validateCompositionCoverage(schedule, bundle)
    else
        null;
    var native_destinations = std.StringHashMap(void).init(allocator);
    defer native_destinations.deinit();
    var missing_components = std.StringHashMap(void).init(allocator);
    defer missing_components.deinit();
    var missing_lookup_components = std.StringHashMap(void).init(allocator);
    defer missing_lookup_components.deinit();
    if (feed_bundle) |bundle| {
        for (bundle.feeds) |feed| for (feed.destinations) |destination| try native_destinations.put(destination.name, {});
    }

    const prepared = try allocator.alloc(Prepared, schedule.len);
    defer allocator.free(prepared);
    @memset(prepared, .{});
    const logical = try allocator.alloc(arena.LogicalBuffer, schedule.len);
    defer allocator.free(logical);
    var component_ids = std.StringHashMap(u16).init(allocator);
    defer component_ids.deinit();
    var next_component: u16 = 0;
    var witness_recipe_buffers: usize = 0;
    var witness_recipe_bytes: u64 = 0;
    var witness_missing_buffers: usize = 0;
    var native_recipe_buffers: usize = 0;
    var native_recipe_bytes: u64 = 0;
    var zero_recipe_buffers: usize = 0;
    var zero_recipe_bytes: u64 = 0;
    var bound_recipe_buffers: usize = 0;
    var bound_recipe_bytes: u64 = 0;
    var circle_recipe_buffers: usize = 0;
    var circle_recipe_bytes: u64 = 0;
    var preprocessed_recipe_buffers: usize = 0;
    var preprocessed_recipe_bytes: u64 = 0;

    for (schedule, 0..) |entry, index| {
        const object = entry.object;
        const purpose = object.get("purpose").?.string;
        const first = epochIndex(object.get("first").?.string) orelse return error.InvalidEpoch;
        const last = epochIndex(object.get("last").?.string) orelse return error.InvalidEpoch;
        var component: ?u16 = null;
        if (object.get("component")) |value| switch (value) {
            .string => |name| {
                const result = try component_ids.getOrPut(name);
                if (!result.found_existing) {
                    if (next_component >= 64) return error.TooManyComponents;
                    result.value_ptr.* = next_component;
                    next_component += 1;
                }
                component = result.value_ptr.*;
            },
            else => {},
        };
        const phases = inferredUsePhases(purpose, first, last);
        for (phases.slice()) |phase| {
            const range: arena.LiveRange = if (component) |id|
                .{ .first = localTick(phase, id), .last = localTick(phase, id) }
            else
                .{ .first = globalTick(phase), .last = globalTick(phase) + 64 };
            prepared[index].ranges[prepared[index].range_count] = range;
            prepared[index].range_count += 1;
        }
        const words: u64 = @intCast(object.get("len_words").?.integer);
        const bytes = std.math.mul(u64, words, 4) catch return error.SizeOverflow;
        var has_recompute_recipe = false;
        if ((std.mem.eql(u8, purpose, "BaseTrace") or
            std.mem.eql(u8, purpose, "LookupInputs") or
            std.mem.eql(u8, purpose, "SubcomponentInputs")) and witness_bundle != null)
        {
            const component_name = object.get("component").?.string;
            const ordinal: u32 = @intCast(object.get("ordinal").?.integer);
            if (witness_bundle.?.find(component_name)) |program_entry| {
                if ((std.mem.eql(u8, purpose, "BaseTrace") and ordinal >= program_entry.program.n_cols) or
                    (std.mem.eql(u8, purpose, "LookupInputs") and program_entry.program.n_lookup_words == 0) or
                    (std.mem.eql(u8, purpose, "SubcomponentInputs") and program_entry.program.n_sub_words == 0))
                    return error.WitnessShapeMismatch;
                witness_recipe_buffers += 1;
                witness_recipe_bytes += bytes;
                has_recompute_recipe = true;
            } else if (std.mem.eql(u8, purpose, "BaseTrace")) {
                if (std.mem.eql(u8, component_name, "ec_op_builtin")) {
                    native_recipe_buffers += 1;
                    native_recipe_bytes += bytes;
                    has_recompute_recipe = true;
                } else if (native_destinations.contains(component_name)) {
                    native_recipe_buffers += 1;
                    native_recipe_bytes += bytes;
                    has_recompute_recipe = true;
                } else if (zeroMultiplicityComponent(component_name)) {
                    zero_recipe_buffers += 1;
                    zero_recipe_bytes += bytes;
                    has_recompute_recipe = true;
                } else {
                    witness_missing_buffers += 1;
                    try missing_components.put(component_name, {});
                }
            } else if (std.mem.eql(u8, purpose, "LookupInputs")) {
                if (std.mem.eql(u8, component_name, "ec_op_builtin")) {
                    native_recipe_buffers += 1;
                    native_recipe_bytes += bytes;
                    has_recompute_recipe = true;
                } else if (fixed_table_destinations.contains(component_name)) {
                    native_recipe_buffers += 1;
                    native_recipe_bytes += bytes;
                    has_recompute_recipe = true;
                } else {
                    try missing_lookup_components.put(component_name, {});
                }
            }
        }
        if (std.mem.eql(u8, purpose, "WitnessInput") and object.get("component") != null and
            object.get("component").? == .string)
        {
            const component_name = object.get("component").?.string;
            const ec_partial = std.mem.eql(u8, component_name, "partial_ec_mul_generic") and
                object.get("ordinal").?.integer < 126;
            if (ec_partial or compactComponent(component_name)) {
                native_recipe_buffers += 1;
                native_recipe_bytes += bytes;
                has_recompute_recipe = true;
            }
        }
        if (std.mem.eql(u8, purpose, "BaseCoefficients") and witness_bundle != null) {
            const component_name = object.get("component").?.string;
            const ordinal: u32 = @intCast(object.get("ordinal").?.integer);
            if (witness_bundle.?.find(component_name)) |program_entry| {
                if (ordinal >= program_entry.program.n_cols) return error.WitnessShapeMismatch;
            }
            circle_recipe_buffers += 1;
            circle_recipe_bytes += bytes;
            has_recompute_recipe = true;
        } else if (std.mem.eql(u8, purpose, "InteractionCoefficients")) {
            circle_recipe_buffers += 1;
            circle_recipe_bytes += bytes;
            has_recompute_recipe = true;
        } else if (std.mem.eql(u8, purpose, "CommitRetainedEvaluation")) {
            if (retained_sources[index] == null) return error.MissingRetainedSource;
            has_recompute_recipe = true;
        } else if (std.mem.eql(u8, purpose, "PreprocessedCoefficients") and preprocessed_coverage.sources[index] != null) {
            preprocessed_recipe_buffers += 1;
            preprocessed_recipe_bytes += bytes;
            has_recompute_recipe = true;
        } else if ((std.mem.eql(u8, purpose, "RetainedMerkleLayers") or std.mem.eql(u8, purpose, "FriMerkleLayer")) and
            (merkle_parent_coverage.sources[index] != null or merkle_commit_coverage.bottoms[index]))
        {
            has_recompute_recipe = true;
        } else if ((std.mem.eql(u8, purpose, "InteractionTrace") or std.mem.eql(u8, purpose, "RelationClaimedSum")) and relation_coverage != null) {
            has_recompute_recipe = true;
        } else if (std.mem.eql(u8, purpose, "CompositionCoefficients") and composition_coverage != null) {
            has_recompute_recipe = true;
        }
        const recoverable = prepared[index].range_count > 1;
        const can_recompute = recoverable and has_recompute_recipe;
        if (can_recompute) {
            bound_recipe_buffers += 1;
            bound_recipe_bytes += bytes;
        }
        logical[index] = .{
            .id = @intCast(object.get("id").?.integer),
            .size_bytes = bytes,
            .live_ranges = prepared[index].ranges[0..prepared[index].range_count],
            .spill_cost_ns = if (recoverable) @max(1, bytes / 20) else null,
            .recompute_cost_ns = if (can_recompute) @max(1, bytes / 100) else null,
        };
    }

    var plan = arena.build(allocator, logical, budget_bytes) catch |err| {
        try writeFailure(err, schedule.len, component_ids.count(), budget_bytes);
        return;
    };
    defer plan.deinit();
    var proof_bindings: ?arena_binding_mod.PreparedProofBindings = if (composition_bundle != null)
        try arena_binding_mod.PreparedProofBindings.initSn2(allocator, schedule, plan)
    else
        null;
    defer if (proof_bindings) |*bindings| bindings.deinit();
    var resident_prepare_gate: []const u8 = "not_requested";
    var populated_direct_witness_lanes: usize = 0;
    var execution_table_split_gpu_ms: f64 = 0;
    var executed_witness_programs: usize = 0;
    var witness_graph_gpu_ms: f64 = 0;
    var populated_preprocessed_coefficients: usize = 0;
    var preprocessed_gpu_ms: f64 = 0;
    var base_interpolation_gpu_ms: f64 = 0;
    var commitment_gpu_ms: f64 = 0;
    var commitment_roots: [4]?[32]u8 = .{ null, null, null, null };
    const requested_commit_tree_count = if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_EXECUTE_COMMITMENTS")) blk: {
        const tree_count = if (std.process.getEnvVarOwned(allocator, "STWO_ZIG_SN2_COMMIT_TREE_COUNT")) |value| value_blk: {
            defer allocator.free(value);
            break :value_blk try std.fmt.parseInt(usize, value, 10);
        } else |err| switch (err) {
            error.EnvironmentVariableNotFound => 1,
            else => return err,
        };
        if (tree_count == 0 or tree_count > 2) return error.InvalidCommitmentTreeCount;
        break :blk tree_count;
    } else 0;
    if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_PREPARE_METAL")) {
        const bindings = if (proof_bindings) |*value| value else return error.MissingPreparedProofBindings;
        var metal = try metal_runtime.Runtime.init();
        defer metal.deinit();
        const restored_preprocessed_path = std.process.getEnvVarOwned(
            allocator,
            "STWO_ZIG_SN2_RESTORE_PREPROCESSED_EVALUATIONS",
        ) catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        };
        defer if (restored_preprocessed_path) |path| allocator.free(path);
        const restoring_tree0 = restored_preprocessed_path != null;
        const staged_tree0 = !restoring_tree0 and requested_commit_tree_count > 0 and
            std.process.hasEnvVarConstant("STWO_ZIG_SN2_EXECUTE_PREPROCESSED") and
            std.process.hasEnvVarConstant("STWO_ZIG_SN2_PREPROCESSED_COEFFS");
        const preprocessed_spill_path = restored_preprocessed_path orelse "/tmp/stwo-zig-sn2-preprocessed-evaluations.spill";
        var staged_tree0_root: ?[32]u8 = null;
        if (restoring_tree0) {
            const root_hex = try std.process.getEnvVarOwned(allocator, "STWO_ZIG_SN2_TREE0_ROOT_HEX");
            defer allocator.free(root_hex);
            if (root_hex.len != 64) return error.InvalidCommitmentRoot;
            var root: [32]u8 = undefined;
            _ = std.fmt.hexToBytes(&root, root_hex) catch return error.InvalidCommitmentRoot;
            staged_tree0_root = root;
            commitment_roots[0] = root;
            populated_preprocessed_coefficients = fixed_table_bundle.?.preprocessed_identities.len;
        }
        if (staged_tree0) {
            var tree0_arena = try arena.ResidentArena.initWithExtra(&metal, plan, bindings.commitmentScratchBytes(0));
            defer tree0_arena.deinit();
            const coefficients_path = try std.process.getEnvVarOwned(allocator, "STWO_ZIG_SN2_PREPROCESSED_COEFFS");
            defer allocator.free(coefficients_path);
            try arena_binding_mod.populatePreprocessedCoefficients(
                allocator,
                &tree0_arena,
                schedule,
                plan,
                fixed_table_bundle.?,
                coefficients_path,
            );
            populated_preprocessed_coefficients = fixed_table_bundle.?.preprocessed_identities.len;
            try bindings.populateCommitmentTwiddles(allocator, &tree0_arena, plan, 0);
            const committed = try bindings.executeCommitment(
                &metal,
                &tree0_arena,
                schedule,
                plan,
                0,
                blake2_merkle.Blake2sMerkleHasher.leafSeed(),
                blake2_merkle.Blake2sMerkleHasher.nodeSeed(),
            );
            commitment_gpu_ms += committed.gpu_ms;
            var root: [32]u8 = undefined;
            @memcpy(&root, (try tree0_arena.bytes(committed.root))[0..32]);
            staged_tree0_root = root;
            commitment_roots[0] = root;
            preprocessed_gpu_ms += try arena_binding_mod.evaluatePreprocessedCoefficients(
                allocator,
                &metal,
                &tree0_arena,
                schedule,
                plan,
                bindings.commitmentTwiddleStorage(plan, 0),
            );
            try arena_binding_mod.spillPreprocessedEvaluations(
                allocator,
                &tree0_arena,
                schedule,
                plan,
                preprocessed_spill_path,
            );
        }
        const needs_twiddle_scratch = std.process.hasEnvVarConstant("STWO_ZIG_SN2_EXECUTE_COMMITMENTS") or
            std.process.hasEnvVarConstant("STWO_ZIG_SN2_EXECUTE_PREPROCESSED") or
            std.process.hasEnvVarConstant("STWO_ZIG_SN2_EXECUTE_BASE_INTERPOLATION");
        const commitment_scratch_bytes = if (needs_twiddle_scratch)
            bindings.commitmentScratchBytes(if (staged_tree0 or restoring_tree0) 1 else 0)
        else
            0;
        var resident_arena = try arena.ResidentArena.initWithExtra(&metal, plan, commitment_scratch_bytes);
        defer resident_arena.deinit();
        if (!staged_tree0 and !restoring_tree0) {
            if (std.process.getEnvVarOwned(allocator, "STWO_ZIG_SN2_PREPROCESSED_COEFFS")) |coefficients_path| {
                defer allocator.free(coefficients_path);
                try arena_binding_mod.populatePreprocessedCoefficients(
                    allocator,
                    &resident_arena,
                    schedule,
                    plan,
                    fixed_table_bundle.?,
                    coefficients_path,
                );
                populated_preprocessed_coefficients = fixed_table_bundle.?.preprocessed_identities.len;
            } else |err| switch (err) {
                error.EnvironmentVariableNotFound => {},
                else => return err,
            }
        }
        if (requested_commit_tree_count > 0 and !staged_tree0 and !restoring_tree0) {
            if (populated_preprocessed_coefficients == 0) return error.CommitmentInputsNotExecuted;
            try bindings.populateCommitmentTwiddles(allocator, &resident_arena, plan, 0);
            const committed = try bindings.executeCommitment(
                &metal,
                &resident_arena,
                schedule,
                plan,
                0,
                blake2_merkle.Blake2sMerkleHasher.leafSeed(),
                blake2_merkle.Blake2sMerkleHasher.nodeSeed(),
            );
            commitment_gpu_ms += committed.gpu_ms;
            var root: [32]u8 = undefined;
            @memcpy(&root, (try resident_arena.bytes(committed.root))[0..32]);
            commitment_roots[0] = root;
        }
        var prover_input: ?cairo_adapter.ProverInput = null;
        defer if (prover_input) |*adapted| adapted.deinit(allocator);
        if (std.process.getEnvVarOwned(allocator, "STWO_ZIG_SN2_POPULATE_INPUT")) |input_path| {
            defer allocator.free(input_path);
            prover_input = try adapted_input.readFile(allocator, input_path);
            const adapted = &prover_input.?;
            execution_table_split_gpu_ms = try arena_binding_mod.populateExecutionTables(
                allocator,
                &metal,
                &resident_arena,
                schedule,
                plan,
                adapted,
            );
            populated_direct_witness_lanes = try arena_binding_mod.populateCasmWitnessInputs(
                allocator,
                &resident_arena,
                schedule,
                plan,
                witness_bundle.?,
                adapted,
            );
            populated_direct_witness_lanes += try arena_binding_mod.populateBuiltinSeedWitnessInputs(
                allocator,
                &resident_arena,
                schedule,
                plan,
                witness_bundle.?,
                adapted,
            );
        } else |err| switch (err) {
            error.EnvironmentVariableNotFound => {},
            else => return err,
        }
        var fixed_tables = try arena_binding_mod.prepareFixedTableBatch(
            allocator,
            &metal,
            &resident_arena,
            schedule,
            plan,
            fixed_table_bundle.?,
        );
        defer fixed_tables.deinit();
        if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_EXECUTE_PREPROCESSED")) {
            if (populated_preprocessed_coefficients == 0) return error.MissingPreprocessedCoefficients;
            if (staged_tree0 or restoring_tree0) {
                try arena_binding_mod.restoreFixedTablePreprocessedEvaluations(
                    allocator,
                    &resident_arena,
                    schedule,
                    plan,
                    fixed_table_bundle.?,
                    preprocessed_spill_path,
                );
            } else {
                if (requested_commit_tree_count == 0)
                    try bindings.populateCommitmentTwiddles(allocator, &resident_arena, plan, 0);
                preprocessed_gpu_ms += try arena_binding_mod.evaluatePreprocessedCoefficients(
                    allocator,
                    &metal,
                    &resident_arena,
                    schedule,
                    plan,
                    bindings.commitmentTwiddleStorage(plan, 0),
                );
            }
            try fixed_tables.execute();
            preprocessed_gpu_ms += fixed_tables.accumulated_gpu_ms;
        }
        var witness = try arena_binding_mod.prepareAotWitnessBatch(
            allocator,
            &metal,
            &resident_arena,
            schedule,
            plan,
            witness_bundle.?,
            fixed_table_bundle.?,
            "vectors/cairo/sn_pie_2_witness.metallib",
        );
        defer witness.deinit();
        var compact_verify = try arena_binding_mod.prepareCompactWitnessInput(
            allocator,
            &metal,
            &resident_arena,
            schedule,
            plan,
            witness_bundle.?,
            "verify_instruction",
        );
        defer compact_verify.deinit();
        var compact_pedersen = try arena_binding_mod.prepareCompactWitnessInput(
            allocator,
            &metal,
            &resident_arena,
            schedule,
            plan,
            witness_bundle.?,
            "pedersen_aggregator_window_bits_18",
        );
        defer compact_pedersen.deinit();
        var compact_poseidon = try arena_binding_mod.prepareCompactWitnessInput(
            allocator,
            &metal,
            &resident_arena,
            schedule,
            plan,
            witness_bundle.?,
            "poseidon_aggregator",
        );
        defer compact_poseidon.deinit();
        if (prover_input) |*adapted| {
            var ec_op = try arena_binding_mod.prepareEcOpWitness(
                allocator,
                &metal,
                &resident_arena,
                schedule,
                plan,
                adapted,
            );
            defer ec_op.deinit();
            if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_EXECUTE_WITNESS")) {
                const recorded = try arena_binding_mod.executeRecordedWitnessGraph(
                    allocator,
                    &metal,
                    &resident_arena,
                    schedule,
                    plan,
                    witness_bundle.?,
                    &witness,
                );
                const native = try arena_binding_mod.executeNativeEcConsumer(witness_bundle.?, &witness, &ec_op);
                executed_witness_programs = recorded.executed_programs + native.executed_programs;
                witness_graph_gpu_ms = recorded.gpu_ms + native.gpu_ms;
            }
        }
        if (std.process.hasEnvVarConstant("STWO_ZIG_SN2_EXECUTE_BASE_INTERPOLATION")) {
            if (executed_witness_programs != witness_bundle.?.entries.len) return error.WitnessGraphNotExecuted;
            try bindings.populateCommitmentInverseTwiddles(allocator, &resident_arena, plan, 1);
            base_interpolation_gpu_ms = try arena_binding_mod.interpolateTraceColumns(
                allocator,
                &metal,
                &resident_arena,
                schedule,
                plan,
                "BaseTrace",
                "BaseCoefficients",
                "InverseTwiddles",
                bindings.commitmentTwiddleStorage(plan, 1),
            );
        }
        if (requested_commit_tree_count > 1) {
            if (base_interpolation_gpu_ms == 0) return error.CommitmentInputsNotExecuted;
            try bindings.populateCommitmentTwiddles(allocator, &resident_arena, plan, 1);
            for (1..requested_commit_tree_count) |tree| {
                const committed = try bindings.executeCommitment(
                    &metal,
                    &resident_arena,
                    schedule,
                    plan,
                    @intCast(tree),
                    blake2_merkle.Blake2sMerkleHasher.leafSeed(),
                    blake2_merkle.Blake2sMerkleHasher.nodeSeed(),
                );
                commitment_gpu_ms += committed.gpu_ms;
                var root: [32]u8 = undefined;
                @memcpy(&root, (try resident_arena.bytes(committed.root))[0..32]);
                commitment_roots[tree] = root;
            }
        }
        if (staged_tree0_root) |root|
            try bindings.restoreCommitmentRoot(&resident_arena, schedule, plan, 0, root);
        const composition_path = args[7];
        if (!std.mem.endsWith(u8, composition_path, ".bin")) return error.InvalidCompositionPath;
        const composition_metallib = try std.fmt.allocPrint(
            allocator,
            "{s}.metallib",
            .{composition_path[0 .. composition_path.len - ".bin".len]},
        );
        defer allocator.free(composition_metallib);
        var composition = try bindings.prepareComposition(
            allocator,
            &metal,
            &resident_arena,
            composition_bundle.?,
            composition_metallib,
        );
        defer composition.deinit();
        var quotient = try bindings.prepareQuotient(allocator, &metal, &resident_arena);
        defer quotient.deinit();
        var fri = try bindings.prepareFri(
            &metal,
            &resident_arena,
            blake2_merkle.Blake2sMerkleHasher.leafSeed(),
            blake2_merkle.Blake2sMerkleHasher.nodeSeed(),
        );
        defer fri.deinit();
        var transcript = try bindings.prepareTranscript(&metal, &resident_arena);
        defer transcript.deinit();
        var decommit_queries = try bindings.prepareDecommitQueries(&metal, &resident_arena);
        try decommit_queries.normalize();
        for (0..8) |round| try decommit_queries.prepareFri(round);
        var assembly = try bindings.prepareProofAssembly(allocator, &metal, &resident_arena);
        defer assembly.deinit();
        resident_prepare_gate = "passed_full_arena_and_protocol_plans";
    }
    const missing_names = try allocator.alloc([]const u8, missing_components.count());
    defer allocator.free(missing_names);
    var missing_iterator = missing_components.keyIterator();
    var missing_index: usize = 0;
    while (missing_iterator.next()) |name| : (missing_index += 1) missing_names[missing_index] = name.*;
    std.mem.sortUnstable([]const u8, missing_names, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.lessThan);
    const missing_lookup_names = try allocator.alloc([]const u8, missing_lookup_components.count());
    defer allocator.free(missing_lookup_names);
    var missing_lookup_iterator = missing_lookup_components.keyIterator();
    var missing_lookup_index: usize = 0;
    while (missing_lookup_iterator.next()) |name| : (missing_lookup_index += 1) missing_lookup_names[missing_lookup_index] = name.*;
    std.mem.sortUnstable([]const u8, missing_lookup_names, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.lessThan);
    var resident: usize = 0;
    var spilled: usize = 0;
    var recomputed: usize = 0;
    var spill_snapshot_bytes: u64 = 0;
    var recompute_snapshot_bytes: u64 = 0;
    var spill_by_purpose = std.ArrayList(PurposeStat).empty;
    defer spill_by_purpose.deinit(allocator);
    for (plan.bindings) |binding| switch (binding.materialization) {
        .resident => resident += 1,
        .spill => {
            spilled += 1;
            spill_snapshot_bytes += binding.size_bytes;
            const purpose = schedule[binding.logical_id].object.get("purpose").?.string;
            var stat: ?*PurposeStat = null;
            for (spill_by_purpose.items) |*candidate| {
                if (std.mem.eql(u8, candidate.purpose, purpose)) {
                    stat = candidate;
                    break;
                }
            }
            if (stat == null) {
                try spill_by_purpose.append(allocator, .{ .purpose = purpose });
                stat = &spill_by_purpose.items[spill_by_purpose.items.len - 1];
            }
            stat.?.buffers += 1;
            stat.?.bytes += binding.size_bytes;
        },
        .recompute => {
            recomputed += 1;
            recompute_snapshot_bytes += binding.size_bytes;
        },
    };
    std.mem.sortUnstable(PurposeStat, spill_by_purpose.items, {}, struct {
        fn lessThan(_: void, lhs: PurposeStat, rhs: PurposeStat) bool {
            if (lhs.bytes != rhs.bytes) return lhs.bytes > rhs.bytes;
            return std.mem.order(u8, lhs.purpose, rhs.purpose) == .lt;
        }
    }.lessThan);
    const result = .{
        .schema_version = 1,
        .planner = "zig-metal-sparse-epochs-v1",
        .schedule_policy = "protocol-purpose-v1-global-phase-conservative",
        .source = args[1],
        .source_sha256 = input_sha256,
        .logical_buffers = plan.bindings.len,
        .component_subepochs = component_ids.count(),
        .canonical_witness_programs = if (witness_bundle) |bundle| bundle.entries.len else 0,
        .native_feed_producers = if (feed_bundle) |bundle| bundle.feeds.len else 0,
        .native_feed_destinations = native_destinations.count(),
        .relation_graph_hash = if (relation_bundle) |bundle| bundle.graph_hash else 0,
        .relation_instances = if (relation_coverage) |coverage| coverage.instances else 0,
        .relation_output_buffers = if (relation_coverage) |coverage| coverage.output_buffers else 0,
        .relation_output_bytes = if (relation_coverage) |coverage| coverage.output_bytes else 0,
        .fixed_table_graph_hash = if (fixed_table_bundle) |bundle| bundle.graph_hash else 0,
        .fixed_table_components = if (fixed_table_coverage) |coverage| coverage.components else 0,
        .fixed_table_lookup_buffers = if (fixed_table_coverage) |coverage| coverage.lookup_buffers else 0,
        .fixed_table_lookup_bytes = if (fixed_table_coverage) |coverage| coverage.lookup_bytes else 0,
        .ec_op_rows = ec_op_coverage.rows,
        .ec_op_output_buffers = ec_op_coverage.output_buffers,
        .ec_op_output_bytes = ec_op_coverage.output_bytes,
        .composition_plan_hash = if (composition_bundle) |bundle| bundle.plan_hash else 0,
        .composition_recipe_components = if (composition_coverage) |coverage| coverage.components else 0,
        .composition_recipe_parts = if (composition_coverage) |coverage| coverage.parts else 0,
        .composition_recipe_buffers = if (composition_coverage) |coverage| coverage.output_buffers else 0,
        .composition_recipe_bytes = if (composition_coverage) |coverage| coverage.output_bytes else 0,
        .prepared_proof_bindings = if (proof_bindings) |bindings| bindings.assembly.len else 0,
        .prepared_proof_copy_ranges = if (proof_bindings) |bindings| bindings.proof_copies.len else 0,
        .prepared_proof_words = if (proof_bindings) |bindings| bindings.proof_bytes.size_bytes / 4 else 0,
        .resident_prepare_gate = resident_prepare_gate,
        .populated_direct_witness_lanes = populated_direct_witness_lanes,
        .execution_table_split_gpu_ms = execution_table_split_gpu_ms,
        .executed_witness_programs = executed_witness_programs,
        .witness_graph_gpu_ms = witness_graph_gpu_ms,
        .populated_preprocessed_coefficients = populated_preprocessed_coefficients,
        .preprocessed_gpu_ms = preprocessed_gpu_ms,
        .base_interpolation_gpu_ms = base_interpolation_gpu_ms,
        .commitment_gpu_ms = commitment_gpu_ms,
        .commitment_roots = commitment_roots,
        .prepared_quotient_partials = if (proof_bindings) |bindings| bindings.quotient_partials.len else 0,
        .prepared_fri_layers = if (proof_bindings) |bindings| bindings.fri_merkle_layers.len else 0,
        .native_recipe_buffers = native_recipe_buffers,
        .native_recipe_bytes = native_recipe_bytes,
        .zero_recipe_buffers = zero_recipe_buffers,
        .zero_recipe_bytes = zero_recipe_bytes,
        .witness_recipe_buffers = witness_recipe_buffers,
        .witness_recipe_bytes = witness_recipe_bytes,
        .witness_missing_buffers = witness_missing_buffers,
        .witness_missing_components = missing_names,
        .lookup_missing_components = missing_lookup_names,
        .bound_recompute_recipe_buffers = bound_recipe_buffers,
        .bound_recompute_recipe_bytes = bound_recipe_bytes,
        .metal_circle_recipe_buffers = circle_recipe_buffers,
        .metal_circle_recipe_bytes = circle_recipe_bytes,
        .preprocessed_ifft_recipe_buffers = preprocessed_recipe_buffers,
        .preprocessed_ifft_recipe_bytes = preprocessed_recipe_bytes,
        .merkle_parent_recipe_chains = merkle_parent_coverage.chains,
        .merkle_parent_recipe_buffers = merkle_parent_coverage.buffers,
        .merkle_parent_recipe_bytes = merkle_parent_coverage.bytes,
        .merkle_commit_recipe_commitments = merkle_commit_coverage.commitments,
        .merkle_commit_recipe_buffers = merkle_commit_coverage.buffers,
        .merkle_commit_recipe_bytes = merkle_commit_coverage.bytes,
        .physical_slots = plan.slots.len,
        .actions = plan.actions.len,
        .resident_buffers = resident,
        .spilled_buffers = spilled,
        .spill_snapshot_bytes = spill_snapshot_bytes,
        .spill_by_purpose = spill_by_purpose.items,
        .recomputed_buffers = recomputed,
        .recompute_snapshot_bytes = recompute_snapshot_bytes,
        .total_bytes = plan.total_bytes,
        .total_gib = @as(f64, @floatFromInt(plan.total_bytes)) / (1024.0 * 1024.0 * 1024.0),
        .peak_live_bytes = plan.peak_live_bytes,
        .peak_logical_bytes = arena.peakLogicalBytes(plan.bindings),
        .budget_bytes = budget_bytes,
        .budget_gib = budget_gib,
        .fits = true,
        .alias_validation = "passed",
        .recovery_gate = "passed_no_unbound_recompute",
        .plan_hash = plan.plan_hash,
    };
    var output: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&output);
    try std.json.Stringify.value(result, .{ .whitespace = .indent_2 }, &writer.interface);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}

fn buildPreprocessedSources(allocator: std.mem.Allocator, schedule: []const std.json.Value) !PreprocessedCoverage {
    const sources = try allocator.alloc(?u32, schedule.len);
    errdefer allocator.free(sources);
    @memset(sources, null);
    var buffers: usize = 0;
    var bytes: u64 = 0;
    var inverse_twiddle_words: u64 = 0;
    for (schedule) |entry| {
        const object = entry.object;
        if (std.mem.eql(u8, object.get("purpose").?.string, "PreprocessedInverseTwiddles")) {
            inverse_twiddle_words = @max(inverse_twiddle_words, @as(u64, @intCast(object.get("len_words").?.integer)));
        }
    }
    for (schedule) |coefficient_entry| {
        const coefficient = coefficient_entry.object;
        if (!std.mem.eql(u8, coefficient.get("purpose").?.string, "PreprocessedCoefficients")) continue;
        const coefficient_id: u32 = @intCast(coefficient.get("id").?.integer);
        if (coefficient_id >= sources.len) return error.InvalidLogicalId;
        const ordinal = coefficient.get("ordinal").?.integer;
        const words: u64 = @intCast(coefficient.get("len_words").?.integer);
        var matched: ?u32 = null;
        for (schedule) |evaluation_entry| {
            const evaluation = evaluation_entry.object;
            if (!std.mem.eql(u8, evaluation.get("purpose").?.string, "PreprocessedEvaluations") or
                evaluation.get("ordinal").?.integer != ordinal or evaluation.get("len_words").?.integer != words)
                continue;
            if (matched != null) return error.DuplicatePreprocessedEvaluation;
            matched = @intCast(evaluation.get("id").?.integer);
        }
        if (matched) |source_id| {
            if (!std.math.isPowerOfTwo(words) or words < 8 or inverse_twiddle_words < words / 2)
                return error.PreprocessedTransformShapeMismatch;
            sources[coefficient_id] = source_id;
            buffers += 1;
            bytes += words * 4;
        }
    }
    return .{ .sources = sources, .buffers = buffers, .bytes = bytes };
}

fn validateFixedTableCoverage(
    schedule: []const std.json.Value,
    bundle: fixed_table_bundle_mod.Bundle,
    destinations: *std.StringHashMap(void),
) !FixedTableCoverage {
    var components: usize = 0;
    var lookup_buffers: usize = 0;
    var lookup_bytes: u64 = 0;
    for (bundle.entries) |entry| {
        const lookup = findScheduled(schedule, "LookupInputs", entry.component, null) orelse continue;
        const lookup_words: u64 = @intCast(lookup.get("len_words").?.integer);
        if (lookup_words != @as(u64, entry.row_count) * entry.lookupCount()) return error.FixedTableShapeMismatch;
        const multiplicity = findScheduled(schedule, "FixedMultiplicity", entry.component, null) orelse return error.FixedTableShapeMismatch;
        if (multiplicity.get("len_words").?.integer != @as(i64, entry.row_count) * entry.multiplicity_columns)
            return error.FixedTableShapeMismatch;
        var trace_columns: usize = 0;
        for (schedule) |scheduled| {
            const object = scheduled.object;
            if (std.mem.eql(u8, object.get("purpose").?.string, "BaseTrace") and
                object.get("component") != null and object.get("component").? == .string and
                std.mem.eql(u8, object.get("component").?.string, entry.component))
            {
                if (object.get("len_words").?.integer != entry.row_count) return error.FixedTableShapeMismatch;
                trace_columns += 1;
            }
        }
        if (trace_columns != entry.trace_multiplicity_columns.len) return error.FixedTableShapeMismatch;
        for (entry.preprocessed_sources) |identity| {
            const ordinal = bundle.identityOrdinal(identity) orelse return error.FixedTableIdentityMismatch;
            const evaluation = findScheduled(schedule, "PreprocessedEvaluations", null, ordinal) orelse return error.FixedTableIdentityMismatch;
            if (evaluation.get("len_words").?.integer != entry.row_count) return error.FixedTableIdentityMismatch;
        }
        const descriptor = findScheduled(schedule, "FixedTableLookupDescriptors", entry.component, null) orelse return error.FixedTableShapeMismatch;
        const source_pointers = findScheduled(schedule, "FixedTableSourcePointers", entry.component, null);
        const multiplicity_pointers = findScheduled(schedule, "FixedTableMultiplicityPointers", entry.component, null) orelse return error.FixedTableShapeMismatch;
        const output_pointers = findScheduled(schedule, "FixedTableLookupOutputPointers", entry.component, null) orelse return error.FixedTableShapeMismatch;
        if (descriptor.get("len_words").?.integer != entry.lookup_descriptors.len or
            multiplicity_pointers.get("len_words").?.integer != @as(i64, entry.multiplicity_columns) * 2 or
            output_pointers.get("len_words").?.integer != @as(i64, @intCast(entry.lookupCount())) * 2 or
            (entry.preprocessed_sources.len == 0 and source_pointers != null) or
            (entry.preprocessed_sources.len != 0 and (source_pointers == null or
                source_pointers.?.get("len_words").?.integer != @as(i64, @intCast(entry.preprocessed_sources.len)) * 2)))
            return error.FixedTableShapeMismatch;
        try destinations.put(entry.component, {});
        components += 1;
        lookup_buffers += 1;
        lookup_bytes += lookup_words * 4;
    }
    if (components != 21 or lookup_buffers != 21) return error.FixedTableCoverageMismatch;
    return .{ .components = components, .lookup_buffers = lookup_buffers, .lookup_bytes = lookup_bytes };
}

fn buildMerkleParentSources(allocator: std.mem.Allocator, schedule: []const std.json.Value) !MerkleParentCoverage {
    const sources = try allocator.alloc(?u32, schedule.len);
    errdefer allocator.free(sources);
    @memset(sources, null);
    var buffers: usize = 0;
    var bytes: u64 = 0;
    var chains: usize = 0;
    var previous: ?std.json.ObjectMap = null;
    for (schedule) |entry| {
        const object = entry.object;
        const purpose = object.get("purpose").?.string;
        if (!std.mem.eql(u8, purpose, "RetainedMerkleLayers") and !std.mem.eql(u8, purpose, "FriMerkleLayer")) continue;
        const words: u64 = @intCast(object.get("len_words").?.integer);
        var chained = false;
        if (previous) |parent_source| {
            chained = std.mem.eql(u8, parent_source.get("purpose").?.string, purpose) and
                std.mem.eql(u8, parent_source.get("first").?.string, object.get("first").?.string) and
                std.mem.eql(u8, parent_source.get("last").?.string, object.get("last").?.string) and
                @as(u64, @intCast(parent_source.get("len_words").?.integer)) == words * 2;
            if (chained) {
                const id: u32 = @intCast(object.get("id").?.integer);
                if (id >= sources.len) return error.InvalidLogicalId;
                sources[id] = @intCast(parent_source.get("id").?.integer);
                buffers += 1;
                bytes += words * 4;
            }
        }
        if (!chained) chains += 1;
        previous = object;
    }
    return .{ .sources = sources, .buffers = buffers, .bytes = bytes, .chains = chains };
}

fn buildMerkleCommitCoverage(allocator: std.mem.Allocator, schedule: []const std.json.Value) !MerkleCommitCoverage {
    const bottoms = try allocator.alloc(bool, schedule.len);
    errdefer allocator.free(bottoms);
    @memset(bottoms, false);
    var commitments: usize = 0;
    var buffers: usize = 0;
    var bytes: u64 = 0;
    var previous: ?std.json.ObjectMap = null;
    for (schedule) |entry| {
        const object = entry.object;
        if (!std.mem.eql(u8, object.get("purpose").?.string, "RetainedMerkleLayers")) continue;
        const words: u64 = @intCast(object.get("len_words").?.integer);
        const chained = if (previous) |child|
            std.mem.eql(u8, child.get("first").?.string, object.get("first").?.string) and
                std.mem.eql(u8, child.get("last").?.string, object.get("last").?.string) and
                @as(u64, @intCast(child.get("len_words").?.integer)) == words * 2
        else
            false;
        previous = object;
        if (chained) continue;
        const ordinal: u32 = @intCast(object.get("ordinal").?.integer);
        const commitment = ordinal >> 20;
        if (commitment > 3 or (ordinal & 0xfffff) != 3) return error.InvalidRetainedTree;
        const base = commitment << 20;
        const leaf = findScheduled(schedule, "MerkleLeafState", null, base + 1) orelse return error.InvalidRetainedTree;
        const parent = findScheduled(schedule, "MerkleLayerScratch", null, base + 2) orelse return error.InvalidRetainedTree;
        const leaf_words: u64 = @intCast(leaf.get("len_words").?.integer);
        const parent_words: u64 = @intCast(parent.get("len_words").?.integer);
        if (leaf_words != words * 16 or parent_words != leaf_words / 2) return error.InvalidRetainedShape;
        var evaluation_count: usize = 0;
        var maximum_evaluation_words: u64 = 0;
        for (schedule) |candidate_entry| {
            const candidate = candidate_entry.object;
            const candidate_purpose = candidate.get("purpose").?.string;
            const matches = if (commitment == 0)
                std.mem.eql(u8, candidate_purpose, "PreprocessedEvaluations")
            else
                std.mem.eql(u8, candidate_purpose, "CommitRetainedEvaluation") and
                    (@as(u32, @intCast(candidate.get("ordinal").?.integer)) >> 20) == commitment;
            if (!matches) continue;
            evaluation_count += 1;
            maximum_evaluation_words = @max(maximum_evaluation_words, @as(u64, @intCast(candidate.get("len_words").?.integer)));
        }
        if (evaluation_count == 0 or maximum_evaluation_words * 8 > leaf_words or
            !std.math.isPowerOfTwo(leaf_words / (maximum_evaluation_words * 8)))
            return error.InvalidRetainedShape;
        const id: u32 = @intCast(object.get("id").?.integer);
        if (id >= bottoms.len) return error.InvalidLogicalId;
        bottoms[id] = true;
        commitments += 1;
        buffers += 1;
        bytes += words * 4;
    }
    if (commitments != 4) return error.InvalidRetainedTree;
    return .{ .bottoms = bottoms, .commitments = commitments, .buffers = buffers, .bytes = bytes };
}

fn validateEcOpCoverage(schedule: []const std.json.Value) !EcOpCoverage {
    var rows: u64 = 0;
    var trace_count: usize = 0;
    var trace_bytes: u64 = 0;
    for (schedule) |entry| {
        const object = entry.object;
        if (!std.mem.eql(u8, object.get("purpose").?.string, "BaseTrace")) continue;
        const component = object.get("component") orelse continue;
        if (component != .string or !std.mem.eql(u8, component.string, "ec_op_builtin")) continue;
        const words: u64 = @intCast(object.get("len_words").?.integer);
        if (rows == 0) rows = words else if (rows != words) return error.EcOpShapeMismatch;
        if (object.get("ordinal").?.integer != trace_count) return error.EcOpShapeMismatch;
        trace_count += 1;
        trace_bytes += words * 4;
    }
    if (rows < 16 or !std.math.isPowerOfTwo(rows) or trace_count != 273) return error.EcOpShapeMismatch;
    const lookup = findScheduled(schedule, "LookupInputs", "ec_op_builtin", 0) orelse return error.EcOpShapeMismatch;
    if (lookup.get("len_words").?.integer != @as(i64, @intCast(rows * 488))) return error.EcOpShapeMismatch;
    var partial_count: usize = 0;
    var partial_bytes: u64 = 0;
    for (schedule) |entry| {
        const object = entry.object;
        if (!std.mem.eql(u8, object.get("purpose").?.string, "WitnessInput")) continue;
        const component = object.get("component") orelse continue;
        if (component != .string or !std.mem.eql(u8, component.string, "partial_ec_mul_generic")) continue;
        if (object.get("ordinal").?.integer != partial_count or object.get("len_words").?.integer != @as(i64, @intCast(rows * 256)))
            return error.EcOpShapeMismatch;
        partial_count += 1;
        partial_bytes += rows * 256 * 4;
    }
    if (partial_count != 126) return error.EcOpShapeMismatch;
    const iota = findScheduled(schedule, "EcOpPartialIota", "ec_op_builtin", 0) orelse return error.EcOpShapeMismatch;
    const segment = findScheduled(schedule, "EcOpSegmentStart", "ec_op_builtin", 0) orelse return error.EcOpShapeMismatch;
    if (iota.get("len_words").?.integer != @as(i64, @intCast(rows * 256)) or segment.get("len_words").?.integer != 1)
        return error.EcOpShapeMismatch;
    if (findScheduled(schedule, "ExecutionTableRawAddressToId", null, 0) == null) return error.EcOpShapeMismatch;
    for (0..28) |ordinal| if (findScheduled(schedule, "ExecutionTableBigLimb", null, @intCast(ordinal)) == null) return error.EcOpShapeMismatch;
    for (0..8) |ordinal| if (findScheduled(schedule, "ExecutionTableSmallLimb", null, @intCast(ordinal)) == null) return error.EcOpShapeMismatch;
    const address_counts = findScheduled(schedule, "RuntimeMultiplicity", "memory_address_to_id", 21) orelse return error.EcOpShapeMismatch;
    const big_counts = findScheduled(schedule, "RuntimeMultiplicity", "memory_id_to_big", 22) orelse return error.EcOpShapeMismatch;
    const small_counts = findScheduled(schedule, "RuntimeMultiplicity", "memory_id_to_big", 23) orelse return error.EcOpShapeMismatch;
    const range_counts = findScheduled(schedule, "FixedMultiplicity", "range_check_8", 0) orelse return error.EcOpShapeMismatch;
    if (address_counts.get("len_words").?.integer == 0 or big_counts.get("len_words").?.integer == 0 or
        small_counts.get("len_words").?.integer == 0 or range_counts.get("len_words").?.integer < 256)
        return error.EcOpShapeMismatch;
    const lookup_bytes = rows * 488 * 4;
    return .{
        .rows = rows,
        .output_buffers = trace_count + 1 + partial_count + 1,
        .output_bytes = trace_bytes + lookup_bytes + partial_bytes + rows * 256 * 4,
    };
}

fn validateCompositionCoverage(
    schedule: []const std.json.Value,
    bundle: composition_bundle_mod.Bundle,
) !CompositionCoverage {
    if (bundle.components.len == 0 or bundle.total_constraints == 0 or bundle.max_evaluation_log_size >= 31)
        return error.CompositionShapeMismatch;
    var tree_columns = [_]u32{ 0, 0, 0 };
    for (schedule) |entry| {
        const purpose = entry.object.get("purpose").?.string;
        if (std.mem.eql(u8, purpose, "PreprocessedCoefficients")) tree_columns[0] += 1;
        if (std.mem.eql(u8, purpose, "BaseCoefficients")) tree_columns[1] += 1;
        if (std.mem.eql(u8, purpose, "InteractionCoefficients")) tree_columns[2] += 1;
    }
    var parts: usize = 0;
    var accumulator_logs: u32 = 0;
    for (bundle.components, 0..) |component, component_index| {
        if (component.trace_spans.len != 3 or component.random_coefficient_offset >= bundle.total_constraints)
            return error.CompositionShapeMismatch;
        for (component.trace_spans) |span| if (span.end > tree_columns[span.tree]) return error.CompositionShapeMismatch;
        for (component.preprocessed_indices) |index| if (index >= tree_columns[0]) return error.CompositionShapeMismatch;
        const ext = findScheduled(schedule, "CompositionExtParams", null, @intCast(component_index)) orelse
            return error.CompositionShapeMismatch;
        if (ext.get("len_words").?.integer < component.ext_sources.len * 4) return error.CompositionShapeMismatch;
        parts += component.parts.len;
        accumulator_logs |= @as(u32, 1) << @intCast(component.evaluation_log_size);
    }
    var accumulator_words: u64 = 0;
    for (0..31) |log_size| {
        if (accumulator_logs & (@as(u32, 1) << @intCast(log_size)) != 0)
            accumulator_words += @as(u64, 4) << @intCast(log_size);
    }
    const accumulators = findScheduled(schedule, "CompositionAccumulators", null, 0) orelse return error.CompositionShapeMismatch;
    if (accumulators.get("len_words").?.integer != accumulator_words) return error.CompositionShapeMismatch;
    const powers = findScheduled(schedule, "CompositionRandomCoefficientPowers", null, 0) orelse return error.CompositionShapeMismatch;
    if (powers.get("len_words").?.integer != bundle.total_constraints * 4) return error.CompositionShapeMismatch;
    const forward = findScheduled(schedule, "ForwardTwiddles", null, 0) orelse return error.CompositionShapeMismatch;
    const inverse = findScheduled(schedule, "InverseTwiddles", null, 0) orelse return error.CompositionShapeMismatch;
    const required_twiddles = @as(u64, 1) << @intCast(bundle.max_evaluation_log_size - 1);
    if (forward.get("len_words").?.integer < required_twiddles or inverse.get("len_words").?.integer < required_twiddles)
        return error.CompositionShapeMismatch;
    const descriptors = findScheduled(schedule, "CompositionDescriptors", null, 0) orelse return error.CompositionShapeMismatch;
    const tile = findScheduled(schedule, "CompositionLdeTile", null, 0) orelse return error.CompositionShapeMismatch;
    if (descriptors.get("len_words").?.integer == 0 or tile.get("len_words").?.integer == 0)
        return error.CompositionShapeMismatch;
    var output_bytes: u64 = 0;
    const output_words = @as(u64, 1) << @intCast(bundle.max_evaluation_log_size - 1);
    for (0..8) |ordinal| {
        const output = findScheduled(schedule, "CompositionCoefficients", null, @intCast(ordinal)) orelse
            return error.CompositionShapeMismatch;
        if (output.get("len_words").?.integer != output_words) return error.CompositionShapeMismatch;
        output_bytes += output_words * 4;
    }
    return .{ .components = bundle.components.len, .parts = parts, .output_buffers = 8, .output_bytes = output_bytes };
}

fn findScheduled(
    schedule: []const std.json.Value,
    purpose: []const u8,
    component: ?[]const u8,
    ordinal: ?u32,
) ?std.json.ObjectMap {
    var result: ?std.json.ObjectMap = null;
    for (schedule) |entry| {
        const object = entry.object;
        if (!std.mem.eql(u8, object.get("purpose").?.string, purpose)) continue;
        if (component) |name| {
            const value = object.get("component") orelse continue;
            if (value != .string or !std.mem.eql(u8, value.string, name)) continue;
        }
        if (ordinal) |value| if (object.get("ordinal").?.integer != value) continue;
        if (result != null) return null;
        result = object;
    }
    return result;
}

fn buildRetainedSources(allocator: std.mem.Allocator, schedule: []const std.json.Value) ![]?u32 {
    const result = try allocator.alloc(?u32, schedule.len);
    errdefer allocator.free(result);
    @memset(result, null);
    var coefficients = [_]std.ArrayList(Coefficient){ .empty, .empty, .empty };
    defer for (&coefficients) |*list| list.deinit(allocator);
    var destinations = [_]std.ArrayList(RetainedDestination){ .empty, .empty, .empty };
    defer for (&destinations) |*list| list.deinit(allocator);

    for (schedule) |entry| {
        const object = entry.object;
        const purpose = object.get("purpose").?.string;
        const id: u32 = @intCast(object.get("id").?.integer);
        const words: u64 = @intCast(object.get("len_words").?.integer);
        const tree: ?usize = if (std.mem.eql(u8, purpose, "BaseCoefficients"))
            0
        else if (std.mem.eql(u8, purpose, "InteractionCoefficients"))
            1
        else if (std.mem.eql(u8, purpose, "CompositionCoefficients"))
            2
        else
            null;
        if (tree) |index| try coefficients[index].append(allocator, .{ .id = id, .words = words });
        if (std.mem.eql(u8, purpose, "CommitRetainedEvaluation")) {
            const ordinal: u32 = @intCast(object.get("ordinal").?.integer);
            const commitment = ordinal >> 20;
            if (commitment < 1 or commitment > 3) return error.InvalidRetainedTree;
            try destinations[commitment - 1].append(allocator, .{ .id = id, .words = words });
        }
    }
    for (&coefficients) |*list| std.mem.sortUnstable(Coefficient, list.items, {}, struct {
        fn lessThan(_: void, lhs: Coefficient, rhs: Coefficient) bool {
            if (lhs.words != rhs.words) return lhs.words < rhs.words;
            return lhs.id < rhs.id;
        }
    }.lessThan);

    var candidates = std.ArrayList(RetentionCandidate).empty;
    defer candidates.deinit(allocator);
    for (coefficients, 0..) |list, tree| {
        var group: usize = 0;
        while (group * 16 < list.items.len) : (group += 1) {
            const columns = list.items[group * 16 .. @min((group + 1) * 16, list.items.len)];
            var words: u64 = 0;
            var weighted_log: u128 = 0;
            for (columns) |column| {
                const output_words = std.math.mul(u64, column.words, 2) catch return error.SizeOverflow;
                if (!std.math.isPowerOfTwo(output_words)) return error.InvalidRetainedShape;
                words = std.math.add(u64, words, output_words) catch return error.SizeOverflow;
                weighted_log += @as(u128, output_words) * std.math.log2_int(u64, output_words);
            }
            try candidates.append(allocator, .{ .tree = tree, .group = group, .words = words, .weighted_log = weighted_log });
        }
    }
    std.mem.sortUnstable(RetentionCandidate, candidates.items, {}, struct {
        fn lessThan(_: void, lhs: RetentionCandidate, rhs: RetentionCandidate) bool {
            const left_score = rhs.weighted_log * @as(u128, lhs.words);
            const right_score = lhs.weighted_log * @as(u128, rhs.words);
            if (left_score != right_score) return right_score > left_score;
            if (lhs.words != rhs.words) return lhs.words < rhs.words;
            if (lhs.tree != rhs.tree) return lhs.tree < rhs.tree;
            return lhs.group < rhs.group;
        }
    }.lessThan);
    var selected = [_]std.DynamicBitSetUnmanaged{ .{}, .{}, .{} };
    defer for (&selected) |*bits| bits.deinit(allocator);
    for (&selected, coefficients) |*bits, list| bits.* = try std.DynamicBitSetUnmanaged.initEmpty(allocator, (list.items.len + 15) / 16);
    var remaining_words: u64 = (8 * 1024 * 1024 * 1024) / 4;
    for (candidates.items) |candidate| {
        if (candidate.words <= remaining_words) {
            selected[candidate.tree].set(candidate.group);
            remaining_words -= candidate.words;
        }
    }

    for (coefficients, destinations, selected) |sources, outputs, kept| {
        var output_index: usize = 0;
        var group: usize = 0;
        while (group * 16 < sources.items.len) : (group += 1) {
            if (!kept.isSet(group)) continue;
            const columns = sources.items[group * 16 .. @min((group + 1) * 16, sources.items.len)];
            for (columns) |source| {
                if (output_index >= outputs.items.len) return error.MissingRetainedDestination;
                const destination = outputs.items[output_index];
                if (destination.words != source.words * 2) {
                    std.log.err("retained mapping mismatch: source id={d} words={d}, destination id={d} words={d}", .{
                        source.id, source.words, destination.id, destination.words,
                    });
                    return error.InvalidRetainedShape;
                }
                result[destination.id] = source.id;
                output_index += 1;
            }
        }
        if (output_index != outputs.items.len) return error.ExtraRetainedDestination;
    }
    return result;
}

fn validateRelationCoverage(
    allocator: std.mem.Allocator,
    schedule: []const std.json.Value,
    bundle: relation_bundle_mod.Bundle,
) !RelationCoverage {
    var source_pointer_words = std.ArrayList(u64).empty;
    defer source_pointer_words.deinit(allocator);
    var output_pointer_words = std.ArrayList(u64).empty;
    defer output_pointer_words.deinit(allocator);
    var denominator_words = std.ArrayList(u64).empty;
    defer denominator_words.deinit(allocator);
    var claimed_sums: usize = 0;
    var scheduled_output_buffers: usize = 0;
    for (schedule) |entry| {
        const object = entry.object;
        const purpose = object.get("purpose").?.string;
        const words: u64 = @intCast(object.get("len_words").?.integer);
        if (std.mem.eql(u8, purpose, "RelationSourcePointers")) try source_pointer_words.append(allocator, words);
        if (std.mem.eql(u8, purpose, "RelationOutputPointers")) try output_pointer_words.append(allocator, words);
        if (std.mem.eql(u8, purpose, "RelationDenominators")) try denominator_words.append(allocator, words);
        if (std.mem.eql(u8, purpose, "InteractionTrace")) scheduled_output_buffers += 1;
        if (std.mem.eql(u8, purpose, "RelationClaimedSum")) {
            if (words != 4) return error.RelationShapeMismatch;
            claimed_sums += 1;
        }
    }
    if (source_pointer_words.items.len != output_pointer_words.items.len or
        source_pointer_words.items.len != denominator_words.items.len or source_pointer_words.items.len != claimed_sums)
        return error.RelationShapeMismatch;

    var instance_index: usize = 0;
    var output_buffers: usize = 0;
    var output_bytes: u64 = 0;
    for (bundle.components) |component| {
        var columns = std.ArrayList(ScheduledColumn).empty;
        defer columns.deinit(allocator);
        for (schedule) |entry| {
            const object = entry.object;
            if (!std.mem.eql(u8, object.get("purpose").?.string, "InteractionTrace")) continue;
            const component_value = object.get("component") orelse continue;
            const component_name = switch (component_value) {
                .string => |name| name,
                else => continue,
            };
            if (!std.mem.eql(u8, component_name, component.name)) continue;
            try columns.append(allocator, .{
                .ordinal = @intCast(object.get("ordinal").?.integer),
                .words = @intCast(object.get("len_words").?.integer),
            });
        }
        if (columns.items.len == 0) continue;
        var groups = std.ArrayList(ScheduledGroup).empty;
        defer groups.deinit(allocator);
        var start: usize = 0;
        while (start < columns.items.len) {
            if (columns.items[start].ordinal != 0) return error.RelationShapeMismatch;
            var end = start + 1;
            while (end < columns.items.len and columns.items[end].ordinal != 0) : (end += 1) {}
            const rows = columns.items[start].words;
            for (columns.items[start..end], 0..) |column, ordinal| {
                if (column.ordinal != ordinal or column.words != rows) return error.RelationShapeMismatch;
            }
            try groups.append(allocator, .{ .start = start, .len = end - start, .rows = rows });
            start = end;
        }

        var group_index: usize = 0;
        for (component.traces, 0..) |trace, trace_index| {
            const remaining_fixed = countFixedTraces(component.traces[trace_index + 1 ..]);
            const trace_instances: usize = switch (trace.part) {
                .component, .memory_small => 1,
                .each_memory_big => groups.items.len - group_index - remaining_fixed,
            };
            if (trace_instances == 0) return error.RelationShapeMismatch;
            for (0..trace_instances) |_| {
                if (group_index >= groups.items.len or instance_index >= source_pointer_words.items.len)
                    return error.RelationShapeMismatch;
                const group = groups.items[group_index];
                const expected_outputs = @as(usize, trace.output_columns) * 4;
                const expected_sources: u64 = switch (trace.layout) {
                    .lookup_words => 1,
                    .memory_address => @as(u64, trace.layout_arg) * 2,
                    .memory_big, .memory_small => @as(u64, trace.layout_arg) + 1,
                    .bitwise_xor_12 => trace.layout_arg,
                };
                if (group.len != expected_outputs or source_pointer_words.items[instance_index] != expected_sources * 2 or
                    output_pointer_words.items[instance_index] != @as(u64, expected_outputs) * 2 or
                    denominator_words.items[instance_index] != group.rows * trace.output_columns * 4)
                    return error.RelationShapeMismatch;
                output_buffers += group.len;
                output_bytes += group.rows * group.len * 4;
                group_index += 1;
                instance_index += 1;
            }
        }
        if (group_index != groups.items.len) return error.RelationShapeMismatch;
    }
    if (instance_index != claimed_sums or output_buffers != scheduled_output_buffers) return error.RelationShapeMismatch;
    return .{ .instances = instance_index, .output_buffers = output_buffers, .output_bytes = output_bytes };
}

fn countFixedTraces(traces: []const relation_bundle_mod.Trace) usize {
    var count: usize = 0;
    for (traces) |trace| if (trace.part != .each_memory_big) {
        count += 1;
    };
    return count;
}

fn epochIndex(name: []const u8) ?u16 {
    for (epoch_names, 0..) |candidate, index| if (std.mem.eql(u8, name, candidate)) return @intCast(index);
    return null;
}

fn globalTick(phase: u16) u16 {
    return phase * 65;
}
fn localTick(phase: u16, component: u16) u16 {
    return phase * 65 + 1 + component;
}

fn inferredUsePhases(purpose: []const u8, first: u16, last: u16) PhaseList {
    if (std.mem.eql(u8, purpose, "WitnessInput") or std.mem.startsWith(u8, purpose, "WitnessInputCompact"))
        return .{ .items = .{ 1, 0, 0, 0, 0, 0 }, .len = 1 };
    if (std.mem.eql(u8, purpose, "BaseTrace") or std.mem.eql(u8, purpose, "LookupInputs"))
        return .{ .items = .{ 1, 3, 0, 0, 0, 0 }, .len = 2 };
    if (std.mem.eql(u8, purpose, "BaseCoefficients")) return .{ .items = .{ 1, 2, 5, 7, 8, 10 }, .len = 6 };
    if (std.mem.eql(u8, purpose, "InteractionTrace")) return .{ .items = .{ 3, 5, 0, 0, 0, 0 }, .len = 2 };
    if (std.mem.eql(u8, purpose, "InteractionCoefficients")) return .{ .items = .{ 3, 4, 5, 7, 8, 10 }, .len = 6 };
    if (std.mem.eql(u8, purpose, "PreprocessedCoefficients")) return .{ .items = .{ 0, 5, 7, 8, 10, 0 }, .len = 5 };
    var result = PhaseList{ .len = 1 };
    result.items[0] = first;
    if (last != first) {
        result.items[1] = last;
        result.len = 2;
    }
    return result;
}

fn zeroMultiplicityComponent(component: []const u8) bool {
    return std.mem.eql(u8, component, "range_check_6") or
        std.mem.eql(u8, component, "range_check_12") or
        std.mem.eql(u8, component, "range_check_3_6_6_3");
}

fn compactComponent(component: []const u8) bool {
    return std.mem.eql(u8, component, "verify_instruction") or
        std.mem.eql(u8, component, "pedersen_aggregator_window_bits_18") or
        std.mem.eql(u8, component, "poseidon_aggregator");
}

fn writeFailure(err: anyerror, logical: usize, components: usize, budget: u64) !void {
    const result = .{ .fits = false, .failure = @errorName(err), .logical_buffers = logical, .component_subepochs = components, .budget_bytes = budget };
    var output: [1024]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&output);
    try std.json.Stringify.value(result, .{ .whitespace = .indent_2 }, &writer.interface);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}
